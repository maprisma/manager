/// The job engine (plan: "Install / update / remove", "Jobs"): one job at a time (a queue in
/// this process, a lock file against every other Manager and the CLI), phases with a commit
/// boundary, the state on disk, logs, process handling and receipts.
///
/// The commit rule: an install script builds and then copies. Before it runs, the stat signature
/// of every catalog path of the app is taken (type, size, mode, mtime, ctime, link target). While
/// it runs the signatures are compared every [JobEngine.pollEvery]; the first changed path is the
/// start of the commit phase. A cancel first stops the script's process group (SIGSTOP), then
/// compares once more: unchanged → TERM to the group (KILL after [JobEngine.killAfter]), changed →
/// the group continues and the cancel is refused with `not_cancellable`. So a cancel never lands
/// after the script has touched one of the app's files. At the commit boundary (where the script
/// doesn't do it itself) the script is paused, the app's units and processes are stopped, and the
/// script continues.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'bar.dart';
import 'bar_cosmic.dart';
import 'bar_kde.dart';
import 'bar_read.dart';
import 'catalog.dart';
import 'context.dart';
import 'core.dart' show coreVersion;
import 'git.dart' show Relation;
import 'ownership.dart';
import 'paths.dart';
import 'procs.dart';
import 'receipts.dart';
import 'removal.dart';
import 'status.dart';
import 'sysproc.dart';

enum JobKind { install, update, reinstall, remove }

/// Phases in order; a job's `phase` is the last one it reached.
const jobPhases = ['queued', 'prepare', 'build', 'commit', 'verify', 'finish'];

/// A log is cut at this size; the last [maxLogTail] bytes are kept at its end.
const maxLogBytes = 4 * 1024 * 1024;
const maxLogTail = 256 * 1024;

/// What `jobs.log` returns at most per call.
const maxLogRead = 256 * 1024;

/// Finished jobs kept on disk (with their logs).
const keepJobs = 100;

final class JobFailure implements Exception {
  JobFailure(this.code, this.message);
  final String code;
  final String message;
}

final class _Cancelled implements Exception {}

/// A job's log file (bounded) and the same output as a stream of lines for the UI.
final class JobLog {
  JobLog(this.path, {this.max = maxLogBytes, this.tailMax = maxLogTail}) {
    Directory(p.dirname(path)).createSync(recursive: true);
    _raf = File(path).openSync(mode: FileMode.writeOnlyAppend);
    _bytes = const Utf8Decoder(allowMalformed: true).startChunkedConversion(_LineCutter(_lines));
  }

  final String path;
  final int max;
  final int tailMax;
  late final RandomAccessFile _raf;
  late final ByteConversionSink _bytes;
  final _lines = StreamController<String>.broadcast();
  int _written = 0, _dropped = 0;
  List<int> _tail = [];
  bool _closed = false;

  Stream<String> get lines => _lines.stream;

  void add(List<int> data) {
    if (_closed) return;
    _bytes.add(data);
    final room = max - _written;
    if (room >= data.length) {
      _raf.writeFromSync(data);
      _written += data.length;
      return;
    }
    if (room > 0) {
      _raf.writeFromSync(data, 0, room);
      _written += room;
    }
    final rest = room > 0 ? data.sublist(room) : data;
    _dropped += rest.length;
    _tail.addAll(rest);
    if (_tail.length > 2 * tailMax) _tail = _tail.sublist(_tail.length - tailMax);
  }

  /// A line of the engine's own (`» …`).
  void note(String text) => add(utf8.encode('» $text\n'));

  void close() {
    if (_closed) return;
    if (_dropped > 0) {
      var tail = _tail.length > tailMax ? _tail.sublist(_tail.length - tailMax) : _tail;
      final nl = tail.indexOf(10);
      if (nl >= 0 && nl < tail.length - 1) tail = tail.sublist(nl + 1);
      _raf.writeFromSync(utf8.encode('\n» [${_dropped - tail.length} bytes of output left out]\n'));
      _raf.writeFromSync(tail);
    }
    _closed = true;
    _bytes.close();
    _raf.closeSync();
    _lines.close();
  }
}

/// Splits decoded output into lines for the UI; a line longer than [maxLine] characters is
/// handed out in pieces (memory stays bounded whatever the script prints).
final class _LineCutter extends StringConversionSinkBase {
  _LineCutter(this.c);
  static const maxLine = 64 * 1024;
  final StreamController<String> c;
  final _pending = StringBuffer();

  @override
  void addSlice(String str, int start, int end, bool isLast) {
    var from = start;
    while (from < end) {
      final nl = str.indexOf('\n', from);
      final stop = nl < 0 || nl >= end ? end : nl;
      _pending.write(str.substring(from, stop));
      if (stop < end) {
        _emit();
        from = stop + 1;
      } else {
        from = end;
      }
      while (_pending.length > maxLine) {
        final text = _pending.toString();
        c.add(text.substring(0, maxLine));
        _pending
          ..clear()
          ..write(text.substring(maxLine));
      }
    }
    if (isLast) close();
  }

  void _emit() {
    var line = _pending.toString();
    if (line.endsWith('\r')) line = line.substring(0, line.length - 1);
    c.add(line);
    _pending.clear();
  }

  @override
  void close() {
    if (_pending.isNotEmpty) _emit();
  }
}

/// One job while this process runs it.
final class _Run {
  _Run(this.job, this.log);
  final Map<String, dynamic> job;
  final JobLog log;
  final done = Completer<Map<String, dynamic>>();
  AppEntry get app => findApp(job['app'] as String)!;
  JobKind get kind => JobKind.values.byName(job['kind'] as String);
  String get id => job['id'] as String;

  Process? process;
  int? pgid;
  Component? component;
  bool cancelRequested = false;
  bool committed = false;
  Timer? killTimer;
  DateTime? cancelAt;
  int? scriptStart;

  /// The commit transition (stopping the app) while it runs: awaited before the job goes on.
  Future<void>? committing;
  Map<String, String> signatures = const {};
  List<Map<String, dynamic>> newBackups = [];
  Set<String> aliveAtEnd = {};
}

/// The engine of one core process.
final class JobEngine {
  JobEngine(this.ctx) : signaller = ctx.paths.proc == '/proc' ? Signaller() : Signaller.recording();

  final Ctx ctx;
  Paths get paths => ctx.paths;

  /// Sends the signals (tests may record instead). Real only against the real /proc.
  Signaller signaller;

  /// Waits for cosmic-panel after a bar write (CoreService passes its own; tests replace it).
  Future<Map<String, dynamic>> Function(List<ProcInfo> before)? follow;

  Duration pollEvery = const Duration(milliseconds: 150);
  Duration killAfter = const Duration(seconds: 5);
  Duration stopGrace = const Duration(seconds: 5);

  /// How long an applet may take to start again after an install (COSMIC).
  Duration appletWait = const Duration(seconds: 3);

  /// Restarts cosmic-panel when an applet didn't start again (tests replace it).
  Future<Map<String, dynamic>> Function(List<ProcInfo> before)? panelRestart;
  int maxLog = maxLogBytes;

  String get dir => p.join(paths.managerState, 'jobs');
  String get logDir => p.join(paths.managerState, 'logs');
  String get lockPath => p.join(dir, 'lock');

  final _runs = <String, _Run>{};
  final _queue = Queue<_Run>();
  bool _pumping = false;
  RandomAccessFile? _lock;

  /// Which engine of this process holds a lock file (fcntl locks don't exclude the same process).
  static final _holders = <String, JobEngine>{};

  // ---------- routes ----------

  Map<String, dynamic> start(Map<String, dynamic> params) {
    final appId = params['app'];
    if (appId is! String || appId.isEmpty) throw RouteError('bad_params', 'app');
    final app = findApp(appId);
    if (app == null) throw RouteError('not_found', 'no app $appId');
    final kindName = params['kind'];
    final kind = JobKind.values.where((k) => k.name == kindName).firstOrNull;
    if (kind == null) throw RouteError('bad_params', 'kind (install, update, reinstall, remove)');
    final rawOptions = params['options'] ?? const {};
    if (rawOptions is! Map) throw RouteError('bad_params', 'options');
    final options = Map<String, dynamic>.from(rawOptions);
    for (final k in ['delete_settings', 'dependents_ok']) {
      if (options[k] != null && options[k] is! bool) throw RouteError('bad_params', 'options.$k');
    }
    if (options['revision'] != null && options['revision'] is! String) throw RouteError('bad_params', 'options.revision');
    if (kind == JobKind.remove) {
      checkRemovable(app);
    } else {
      if (app.installation == Support.unsupportedYet) {
        throw RouteError('unsupported_yet', 'installing ${app.name} is not supported yet${app.supportNote == null ? '' : ': ${app.supportNote}'}');
      }
      if (!app.desktops.contains(ctx.desktop) || !app.components.any((c) => c.desktops.contains(ctx.desktop))) {
        throw RouteError('unavailable', '${app.name} is not for ${ctx.desktop.name}');
      }
      if (app.components.any((c) => c.kind != InstallKind.script)) throw RouteError('unsupported_yet', 'only install scripts so far');
    }
    if (_runs.values.any((r) => r.job['app'] == appId && r.job['finished'] != true)) {
      throw RouteError('busy', 'a job for ${app.name} is already queued or running');
    }
    _acquire();
    final now = ctx.clock().toUtc();
    final id = _newId(now, appId, kind);
    final job = <String, dynamic>{
      'id': id,
      'app': appId,
      'kind': kind.name,
      'options': options,
      'state': 'queued',
      'phase': 'queued',
      'created': now.toIso8601String(),
      'owner': {'pid': pid, 'start': procStat(pid)?.start},
      'log': p.join(logDir, '$id.log'),
      'committed': false,
    };
    final run = _Run(job, JobLog(job['log'] as String, max: maxLog));
    _runs[id] = run;
    _persist(job);
    _queue.add(run);
    unawaited(_pump());
    return summary(job);
  }

  Map<String, dynamic> get(Map<String, dynamic> params) {
    final job = _job(params['id']);
    return {...job, 'cancellable': _cancellable(job)};
  }

  Map<String, dynamic> list(Map<String, dynamic> params) {
    final app = params['app'];
    final limit = params['limit'] ?? 50;
    if (app != null && app is! String) throw RouteError('bad_params', 'app');
    if (limit is! int || limit < 1) throw RouteError('bad_params', 'limit');
    final jobs = [for (final j in loadJobs(paths)) if (app == null || j['app'] == app) j];
    return {'jobs': [for (final j in jobs.take(limit)) summary(_runs[j['id']]?.job ?? j)]};
  }

  /// `{id, from}` → `{id, from, next, size, text, finished}`: the log from byte [from] on, at most
  /// [maxLogRead]; while the job runs, cut at the last full line.
  Map<String, dynamic> readLog(Map<String, dynamic> params) {
    final job = _job(params['id']);
    final from = params['from'] ?? 0;
    if (from is! int || from < 0) throw RouteError('bad_params', 'from');
    final file = File(job['log'] as String);
    final size = file.existsSync() ? file.lengthSync() : 0;
    final finished = job['finished'] == true;
    var bytes = <int>[];
    if (from < size) {
      final raf = file.openSync();
      try {
        raf.setPositionSync(from);
        bytes = raf.readSync(size - from > maxLogRead ? maxLogRead : size - from);
      } finally {
        raf.closeSync();
      }
    }
    final whole = from + bytes.length >= size && finished;
    if (!whole) {
      final nl = bytes.lastIndexOf(10);
      if (nl >= 0) {
        bytes = bytes.sublist(0, nl + 1);
      } else if (bytes.length >= maxLogRead || finished) {
        // A line longer than one read: hand it out in pieces, cut at a UTF-8 character boundary.
        var cut = bytes.length;
        while (cut > 0 && cut > bytes.length - 4 && (bytes[cut - 1] & 0xC0) == 0x80) {
          cut--;
        }
        if (cut > 0 && bytes[cut - 1] >= 0xC0) cut--; // a lead byte without its continuation
        bytes = bytes.sublist(0, cut == 0 ? bytes.length : cut);
      } else {
        bytes = <int>[];
      }
    }
    final next = from + bytes.length;
    return {
      'id': job['id'],
      'from': from,
      'next': next,
      'size': size,
      'text': utf8.decode(bytes, allowMalformed: true),
      'finished': finished && next >= size,
    };
  }

  Future<Map<String, dynamic>> cancel(Map<String, dynamic> params) async {
    final id = params['id'];
    final run = id is String ? _runs[id] : null;
    if (run == null) {
      final job = _job(id);
      if (job['finished'] == true) throw RouteError('finished', 'the job has ended');
      throw RouteError('not_owner', 'the job runs in another Maprisma Manager (pid ${(job['owner'] as Map?)?['pid']})');
    }
    final job = run.job;
    if (job['finished'] == true) throw RouteError('finished', 'the job has ended');
    if (job['state'] == 'queued') {
      _queue.remove(run);
      run.log.note('cancelled before it started');
      _end(run, 'cancelled', {'ok': false, 'code': 'cancelled'});
      return {'id': run.id, 'cancelled': true};
    }
    if (run.committed || !['prepare', 'build'].contains(job['phase'])) {
      throw RouteError('not_cancellable', 'the job is in its ${job['phase']} phase (it changes files now)');
    }
    if (run.process == null || run.pgid == null) {
      // prepare, or the script is being started: it is ended as soon as its group is known.
      run.cancelRequested = true;
      run.log.note('cancel asked: the job stops before the next step');
      return {'id': run.id, 'cancelling': true};
    }
    await _cancelScript(run);
    return {'id': run.id, 'cancelling': true};
  }

  /// Signals the job's script group, only while it is still that group: its leader is the
  /// process that started at the recorded time, or (leader gone) members of the session it made.
  bool _signalGroup(_Run r, int sig) {
    final pg = r.pgid;
    if (pg == null) return false;
    if (!sameProcess(pg, r.scriptStart) && groupMembers(pg).isEmpty) return false;
    return signaller.group(pg, sig);
  }

  /// SIGSTOP to the group, then waits until every member is stopped (a stopped process runs no
  /// code and is in no system call, so nothing it does lands after the check). False when it
  /// could not be paused in time (then it is let go again).
  Future<bool> _pause(_Run r) async {
    if (!_signalGroup(r, sigStop)) return groupMembers(r.pgid!).isEmpty && r.process == null;
    if (!signaller.real) return true; // recording: nothing to wait for
    final until = DateTime.now().add(const Duration(seconds: 1));
    while (DateTime.now().isBefore(until)) {
      if (groupMembers(r.pgid!).every((m) => m.stopped)) return true;
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    _signalGroup(r, sigCont);
    return false;
  }

  /// Ends the script when it hasn't touched the app's files: paused, checked, then TERM (KILL
  /// after [killAfter], until no member of its group is left). Throws `not_cancellable` otherwise.
  Future<void> _cancelScript(_Run run) async {
    run.cancelRequested = false;
    if (!await _pause(run)) {
      throw RouteError('not_cancellable', 'the script could not be paused to check it');
    }
    final changed = firstChanged(run.signatures);
    if (changed != null) {
      try {
        await _enterCommit(run, changed, paused: true);
      } finally {
        _signalGroup(run, sigCont);
      }
      throw RouteError('not_cancellable', 'the install has started writing its files ($changed)');
    }
    run.cancelRequested = true;
    run.cancelAt = DateTime.now();
    run.log.note('cancel: TERM to the script\'s process group ${run.pgid}');
    _signalGroup(run, sigTerm);
    _signalGroup(run, sigCont);
    run.killTimer = Timer(killAfter, () {
      if (_signalGroup(run, sigKill)) run.log.note('cancel: KILL to the process group ${run.pgid}');
    });
  }

  /// The UI's live output of a job run by this process (null: not ours or ended).
  Stream<String>? lines(String id) => _runs[id]?.log.lines;

  /// Completes with the job when it ends (a job of this process).
  Future<Map<String, dynamic>>? done(String id) => _runs[id]?.done.future;

  // ---------- the queue and the lock ----------

  void _acquire() {
    if (_lock != null) return;
    final holder = _holders[lockPath];
    if (holder != null && holder != this) throw RouteError('busy', 'another job runs in this process');
    final f = File(lockPath);
    f.createSync(recursive: true);
    // A script whose Manager is gone may still be writing (an interrupted job's orphan).
    final orphan = loadJobs(paths).where((j) => j['state'] == 'interrupted' && orphanRunning(j)).firstOrNull;
    if (orphan != null) {
      throw RouteError('busy', 'the script of the interrupted job ${orphan['id']} still runs (pid ${(orphan['script'] as Map)['pid']}); wait for it to end');
    }
    final raf = f.openSync(mode: FileMode.append);
    try {
      raf.lockSync(FileLock.exclusive);
    } on FileSystemException {
      raf.closeSync();
      final other = loadJobs(paths).where((j) => j['finished'] != true).firstOrNull;
      throw RouteError('busy', other == null ? 'another Maprisma Manager runs a job' : 'another Maprisma Manager runs ${other['kind']} ${other['app']} (${other['id']})');
    }
    _lock = raf;
    _holders[lockPath] = this;
  }

  void _release() {
    final raf = _lock;
    if (raf == null) return;
    _lock = null;
    _holders.remove(lockPath);
    try {
      raf.unlockSync();
    } on FileSystemException {
      // closing drops it anyway
    }
    raf.closeSync();
  }

  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    try {
      while (_queue.isNotEmpty) {
        await _execute(_queue.removeFirst());
      }
    } finally {
      _pumping = false;
      _release();
      _prune();
    }
  }

  String _newId(DateTime now, String app, JobKind kind) {
    final stamp = now.toIso8601String().replaceAll(RegExp(r'[-:]'), '').replaceAll(RegExp(r'\.\d+'), '');
    var id = '$stamp-$app-${kind.name}';
    for (var n = 2; File(p.join(dir, '$id.json')).existsSync() || _runs.containsKey(id); n++) {
      id = '$stamp-$app-${kind.name}-$n';
    }
    return id;
  }

  Map<String, dynamic> _job(Object? id) {
    if (id is! String || !validJobId(id)) throw RouteError('bad_params', 'id');
    final live = _runs[id];
    if (live != null) return live.job;
    final j = loadJob(paths, id);
    if (j == null) throw RouteError('not_found', 'no job $id');
    return j;
  }

  bool _cancellable(Map<String, dynamic> job) {
    final r = _runs[job['id']];
    return r != null && job['finished'] != true && !r.committed && ['queued', 'prepare', 'build'].contains(job['phase']);
  }

  void _persist(Map<String, dynamic> job) => atomicWrite(p.join(dir, '${job['id']}.json'), const JsonEncoder.withIndent('  ').convert(job));

  void _phase(_Run r, String phase, {Component? component}) {
    r.job['phase'] = phase;
    if (component != null) {
      r.component = component;
      r.job['component'] = component.id;
    }
    _persist(r.job);
    r.log.note('phase: $phase${component == null ? '' : ' (${component.name})'}');
  }

  void _checkCancel(_Run r) {
    if (r.cancelRequested) throw _Cancelled();
  }

  void _end(_Run r, String state, Map<String, dynamic> result) {
    r.job['state'] = state;
    r.job['result'] = result;
    r.job['finished'] = true;
    r.job['ended'] = ctx.clock().toUtc().toIso8601String();
    r.job['committed'] = r.committed;
    _persist(r.job);
    r.log.note('$state${result['code'] == null ? '' : ': ${result['code']}'}${result['message'] == null ? '' : ' (${result['message']})'}');
    r.log.close();
    if (!r.done.isCompleted) r.done.complete(r.job);
  }

  void _prune() {
    final jobs = loadJobs(paths).where((j) => j['finished'] == true).toList();
    for (final j in jobs.skip(keepJobs)) {
      for (final f in [p.join(dir, '${j['id']}.json'), j['log']]) {
        try {
          if (f is String) File(f).deleteSync();
        } on FileSystemException {
          // gone
        }
      }
    }
  }

  Future<void> _execute(_Run r) async {
    r.job['state'] = 'running';
    r.job['started'] = ctx.clock().toUtc().toIso8601String();
    _persist(r.job);
    r.log.note('${r.kind.name} ${r.app.name} (job ${r.id})');
    try {
      final result = r.kind == JobKind.remove ? await _remove(r) : await _install(r);
      _end(r, 'succeeded', {'ok': true, ...result});
    } on _Cancelled {
      _dropNewBackups(r);
      _end(r, 'cancelled', {'ok': false, 'code': 'cancelled', 'message': 'nothing was changed'});
    } on JobFailure catch (f) {
      if (!r.committed) _dropNewBackups(r);
      if (r.committed && r.kind != JobKind.remove) {
        // The installer may have rewritten the autostart file: the wanted bar state still holds.
        try {
          await (Bar(ctx)..follow = follow).applyWanted();
        } on Object catch (e) {
          r.log.note('bar state not applied: $e');
        }
      }
      _end(r, 'failed', {
        'ok': false,
        'code': f.code,
        'message': f.message,
        'repair': r.committed,
      });
    } catch (e, st) {
      r.log.note('internal error: $e\n$st');
      _end(r, 'failed', {'ok': false, 'code': 'internal', 'message': '$e', 'repair': r.committed});
    } finally {
      r.killTimer?.cancel();
    }
  }

  void _dropNewBackups(_Run r) {
    if (r.newBackups.isEmpty) return;
    final d = Displaced.load(paths, r.job['app'] as String);
    for (final e in r.newBackups) {
      final mine = d.of(e['path'] as String);
      if (mine != null && mine['job'] == r.id) d.drop(mine);
    }
    d.save();
    r.newBackups = [];
  }

  // ---------- install / update / reinstall ----------

  List<Component> _components(AppEntry app) => [for (final c in app.components) if (c.desktops.contains(ctx.desktop)) c];

  /// The repos a build of these components reads: their own and the app's other inputs.
  List<String> _repos(AppEntry app, List<Component> comps) {
    final componentRepos = {for (final c in app.components) c.repo};
    return [
      for (final i in app.inputs)
        if (comps.any((c) => c.repo == i.repo) || !componentRepos.contains(i.repo)) i.repo,
    ];
  }

  Future<Map<String, dynamic>> _install(_Run r) async {
    final app = r.app;
    final comps = _components(app);
    _phase(r, 'prepare');
    final status = StatusReader(ctx);

    for (final dep in app.dependsOn) {
      final d = findApp(dep);
      if (d == null) continue;
      final states = [for (final c in _components(d)) (await status.component(d, c)).state];
      if (states.isEmpty || states.any((s) => s != InstallState.installed)) {
        throw JobFailure('missing_dependency', '${app.name} needs ${d.name} installed first');
      }
    }
    for (final c in comps) {
      for (final pr in c.prerequisites) {
        if (pr.optional || ctx.tool(pr.command) != null) continue;
        if (pr.part != null && c.optionalParts.contains(pr.part)) {
          r.log.note('${pr.command} not found: the ${pr.part} is skipped by the installer');
          (r.job['warnings'] ??= <String>[]).add('${pr.command} missing: no ${pr.part}');
          continue;
        }
        throw JobFailure('missing_prerequisite', '${c.name} needs ${pr.command}');
      }
    }
    final repos = _repos(app, comps);
    for (final repo in repos) {
      final folder = ctx.repoFolder(repo);
      final g = await ctx.git.inspect(repo, folder);
      if (!g.present) throw JobFailure('no_source', '$folder is missing');
      if (!g.isRepo || g.head == null) throw JobFailure('no_source', '$folder: ${g.error ?? 'not a git repository with a commit'}');
      if (r.kind != JobKind.update) continue;
      if (g.upstream == null) {
        r.log.note('$repo: no upstream, built as it is');
      } else if (g.dirty != false) {
        r.log.note('$repo: uncommitted changes, no pull; built as it is');
      } else if (g.relation == Relation.behind) {
        r.log.note('$repo: git pull --ff-only (${g.behind} new from ${g.upstream})');
        final pull = await ctx.git.pullFfOnly(folder);
        if (pull.stdout.isNotEmpty) r.log.add(utf8.encode(pull.stdout));
        if (pull.stderr.isNotEmpty) r.log.add(utf8.encode(pull.stderr));
        if (!pull.ok) throw JobFailure('pull_failed', '$repo: git pull --ff-only failed');
      } else {
        r.log.note('$repo: ${g.relation.name} against ${g.upstream}, no pull');
      }
      _checkCancel(r);
    }
    // The inputs as they are built (after the pull).
    final inputs = <Map<String, dynamic>>[];
    for (final repo in repos) {
      final folder = ctx.repoFolder(repo);
      final g = await ctx.git.inspect(repo, folder);
      inputs.add({
        'repo': repo,
        'commit': g.head,
        'dirty': g.dirty ?? true,
        'fingerprint': ?await ctx.git.fingerprint(folder, (f) => sha256File(f)),
      });
    }
    _checkCancel(r);

    // Update with nothing new: the installed build is the folder as it is now (same commits, clean
    // then and now, every component installed) - nothing is built or replaced.
    if (r.kind == JobKind.update) {
      final rec = readReceipt(paths, app.id).receipt;
      bool same(Map<String, dynamic> now) {
        final then = rec?.inputs.where((i) => i.repo == now['repo']).firstOrNull;
        return then != null && !then.dirty && now['dirty'] == false && then.commit != null && then.commit == now['commit'];
      }
      if (rec != null && inputs.every(same) && rec.inputs.length == inputs.length) {
        final states = [for (final c in comps) (await status.component(app, c)).state];
        if (states.every((s) => s == InstallState.installed)) {
          r.log.note('already up to date: the installed build is ${inputs.map((i) => '${i['repo']}@${'${i['commit']}'.substring(0, 7)}').join(', ')}');
          return {'up_to_date': true};
        }
      }
    }

    await _seedWantedBar(r);
    _checkCancel(r);

    // Snapshot and displaced files, before anything runs.
    final cat = catalogPaths(paths, comps);
    final norm = normalizedPaths(paths, app);
    final before = {for (final (_, path) in cat) path: pathState(path, normalized: norm.contains(path) ? normalizedHidden : null)};
    final receipt = readReceipt(paths, app.id).receipt;
    final displaced = Displaced.load(paths, app.id);
    final at = ctx.clock();
    for (final (_, path) in cat) {
      final st = before[path]!;
      if (st['exists'] != true || (st['type'] != 'file' && st['type'] != 'link')) continue;
      final owned = receipt?.paths.where((e) => e['path'] == path).firstOrNull;
      final ours = owned != null && ((owned['sha256'] != null && owned['sha256'] == st['sha256']) || (owned['link'] != null && owned['link'] == st['link']));
      if (ours) continue;
      final e = displaced.add(path, st,
          restore: receipt != null,
          reason: receipt == null ? 'before the Manager' : (owned == null ? 'not in the receipt' : 'changed since the install'),
          job: r.id,
          at: at);
      if (e != null) r.newBackups.add(e);
    }
    displaced.save();
    if (r.newBackups.isNotEmpty) r.log.note('backed up ${r.newBackups.length} file(s) that weren\'t the Manager\'s');
    r.signatures = signatures([for (final (_, path) in cat) path]);
    _checkCancel(r);

    for (final c in comps) {
      await _runScript(r, c);
    }
    r.aliveAtEnd = {for (final pr in ctx.processes()) '${pr.pid}:${pr.startTicks}'};

    _phase(r, 'verify');
    final failing = <Map<String, dynamic>>[];
    final partial = <String>{};
    for (final c in comps) {
      final checks = [for (final ip in c.paths) checkPath(paths, ip)];
      for (final part in {for (final ch in checks) ch['part'] as String}) {
        final mine = checks.where((ch) => ch['part'] == part).toList();
        final bad = mine.where((ch) => ch['ok'] != true).toList();
        if (bad.isEmpty) continue;
        if (c.optionalParts.contains(part) && bad.length == mine.length) {
          partial.add(part);
        } else {
          failing.addAll(bad);
        }
      }
    }
    if (failing.isNotEmpty) {
      for (final f in failing) {
        r.log.note('postcondition: ${f['path']}: ${f['problem']}');
      }
      throw JobFailure('verify_failed', '${failing.length} path(s) not as the installer leaves them');
    }
    if (partial.isNotEmpty) r.log.note('partly installed: no ${partial.join(', ')}');

    _phase(r, 'finish');
    await _postSteps(r, app.postSteps);
    final bar = await _barFinish(r);
    // Backups of files the script left as they were weren't displaced after all.
    final d = Displaced.load(paths, app.id);
    for (final e in r.newBackups) {
      final path = e['path'] as String;
      final now = pathState(path, normalized: norm.contains(path) ? normalizedHidden : null);
      final was = before[path]!;
      if (now['type'] == was['type'] && now['sha256'] == was['sha256'] && now['link'] == was['link']) {
        final mine = d.of(path);
        if (mine != null && mine['job'] == r.id) d.drop(mine);
      }
    }
    d.save();
    final receiptJson = <String, dynamic>{
      'schema': 1,
      'id': app.id,
      'at': ctx.clock().toUtc().toIso8601String(),
      'version': ?(status.bundleVersion(app) ?? status.folderVersion(app)),
      'manager': coreVersion,
      'job': r.id,
      'kind': r.kind.name,
      'components': [for (final c in comps) c.id],
      if (partial.isNotEmpty) 'partial': partial.toList(),
      'inputs': inputs,
      'paths': [
        for (final (_, path) in cat)
          if (pathState(path, normalized: norm.contains(path) ? normalizedHidden : null) case final st when st['exists'] == true)
            switch (st['type']) {
              'file' => {'path': path, 'sha256': st['sha256'], 'mode': st['mode'], 'normalized': ?st['normalized']},
              'link' => {'path': path, 'link': st['link']},
              _ => {'path': path, 'dir': true},
            },
      ],
      'displaced': [for (final e in d.entries) {'path': e['path'], 'backup': e['backup'], 'restore': e['restore'], 'reason': e['reason']}],
    };
    Receipt.parse(app.id, jsonDecode(jsonEncode(receiptJson))); // never write one the reader refuses
    atomicWrite(p.join(paths.receipts, '${app.id}.json'), const JsonEncoder.withIndent('  ').convert(receiptJson));
    final keptRecord = File(keptFile(paths, app.id));
    if (keptRecord.existsSync()) keptRecord.deleteSync(); // the receipt says what is the app's now
    r.log.note('receipt written (${(receiptJson['paths'] as List).length} paths)');
    return {
      if (partial.isNotEmpty) 'partial': partial.toList(),
      'stopped': r.job['stopped'] ?? const [],
      'bar': bar,
      'receipt': p.join(paths.receipts, '${app.id}.json'),
    };
  }

  /// The bar state before an install: an app the user never placed through the Manager has no
  /// entry in bar.json; its current state (in the bar, and where, or out) is recorded there first,
  /// so it is put back after the installer rewrote its autostart file.
  Future<void> _seedWantedBar(_Run r) async {
    final app = r.app;
    if (ctx.desktop == DesktopId.other || app.bar.none) return;
    if (WantedBar.load(paths).of(ctx.desktop, app.id) != null) return;
    final installed = app.components.any((c) => c.paths.any((ip) => ip.key && File(paths.expand(ip.path)).existsSync()));
    if (!installed) return;
    final st = (await BarSnapshot.read(ctx, ctx.processes())).stateOf(app);
    if (st['state'] != 'in' && st['state'] != 'out') return;
    final area = parseArea(st['zone']);
    await withStateLock(paths, () async {
      final wanted = WantedBar.load(paths);
      if (wanted.of(ctx.desktop, app.id) != null) return;
      wanted.set(ctx.desktop, app.id, placed: st['state'] == 'in', area: area);
      wanted.save(paths);
    });
    r.log.note('bar state recorded before the install: ${st['state']}${area == null ? '' : ' (${area.name})'}');
  }

  /// The script's environment: explicit, no login shell. PATH gets flutter's folder and
  /// ~/.cargo/bin first; FLUTTER as the installer wants it; the catalog's own variables.
  Map<String, String> scriptEnv(Component c, {String? job}) {
    final e = ctx.environment;
    const keep = {
      'HOME', 'USER', 'LOGNAME', 'LANG', 'LANGUAGE', 'TZ', 'SHELL',
      'XDG_CONFIG_HOME', 'XDG_DATA_HOME', 'XDG_STATE_HOME', 'XDG_CACHE_HOME', 'XDG_RUNTIME_DIR',
      'XDG_CURRENT_DESKTOP', 'XDG_SESSION_TYPE', 'XDG_SESSION_DESKTOP', 'XDG_DATA_DIRS', 'XDG_CONFIG_DIRS',
      'DISPLAY', 'WAYLAND_DISPLAY', 'DBUS_SESSION_BUS_ADDRESS', 'SSH_AUTH_SOCK',
      'CARGO_HOME', 'RUSTUP_HOME', 'PUB_CACHE',
      'GIT_CONFIG_GLOBAL', 'GIT_CONFIG_NOSYSTEM', 'GIT_ALLOW_PROTOCOL',
    };
    final out = <String, String>{
      for (final k in e.keys)
        if (keep.contains(k) || k.startsWith('LC_')) k: e[k]!,
    };
    final flutter = ctx.flutter().exe;
    final cargoBin = p.join(e['CARGO_HOME'] ?? p.join(paths.home, '.cargo'), 'bin');
    out['PATH'] = [?(flutter == null ? null : p.dirname(flutter)), cargoBin, ...(e['PATH'] ?? '/usr/local/bin:/usr/bin:/bin').split(':')]
        .where((d) => d.isNotEmpty)
        .fold<List<String>>([], (l, d) => l.contains(d) ? l : (l..add(d)))
        .join(':');
    out['TERM'] = 'dumb';
    out['CARGO_TERM_COLOR'] = 'never';
    switch (c.flutter) {
      case FlutterEnv.dir:
        if (flutter != null) out['FLUTTER'] = p.dirname(flutter);
      case FlutterEnv.executable:
        if (flutter != null) out['FLUTTER'] = flutter;
      case FlutterEnv.path:
      case FlutterEnv.none:
        break;
    }
    for (final kv in c.env.entries) {
      out[kv.key] = kv.value.contains('{') ? paths.expand(kv.value) : kv.value;
    }
    if (job != null) out['MAPRISMA_MANAGER_JOB'] = job;
    return out;
  }

  Future<void> _runScript(_Run r, Component c) async {
    if (!r.committed) {
      _phase(r, 'build', component: c);
    } else {
      r.component = c;
      r.job['component'] = c.id;
      _persist(r.job);
    }
    _checkCancel(r);
    final folder = ctx.repoFolder(c.repo);
    final setsid = ctx.runner.which('setsid') ?? '/usr/bin/setsid';
    r.log.note('\$ ${c.install.join(' ')}   (in $folder)');
    final Process proc;
    try {
      proc = await Process.start(setsid, c.install,
          workingDirectory: folder, environment: scriptEnv(c, job: r.id), includeParentEnvironment: false);
    } on ProcessException catch (e) {
      throw JobFailure('script_failed', 'could not start ${c.install.first}: ${e.message}');
    }
    r.process = proc;
    // Not reaped yet, so this pid is the script's: its start time is its identity.
    r.scriptStart = procStat(proc.pid)?.start;
    await proc.stdin.close();
    // setsid makes the script the leader of its own session and group (pgid = pid).
    // (A script that has already ended counts as its own group: there is nothing left to signal.)
    final until = DateTime.now().add(const Duration(seconds: 1));
    while (true) {
      final st = procStat(proc.pid);
      if (st == null || st.zombie || (st.pgrp == proc.pid && st.session == proc.pid)) {
        r.pgid = proc.pid;
        break;
      }
      if (DateTime.now().isAfter(until)) break;
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    if (r.pgid == null) r.log.note('the script\'s process group is unknown: it can\'t be cancelled');
    r.job['script'] = {'pid': proc.pid, 'pgid': r.pgid, 'start': r.scriptStart, 'component': c.id};
    _persist(r.job);
    final outDone = proc.stdout.listen(r.log.add).asFuture<void>();
    final errDone = proc.stderr.listen(r.log.add).asFuture<void>();
    // A cancel that came while the script was being started.
    if (r.cancelRequested && r.pgid != null) {
      try {
        await _cancelScript(r);
      } on RouteError catch (e) {
        r.log.note('cancel came too late: ${e.message}');
      }
    }
    final timer = Timer.periodic(pollEvery, (_) {
      if (r.committed || r.committing != null) return;
      final changed = firstChanged(r.signatures);
      if (changed != null) unawaited(_enterCommit(r, changed));
    });
    final code = await proc.exitCode;
    timer.cancel();
    r.process = null;
    // A commit transition still stopping the app is finished before anything goes on.
    await r.committing;
    if (r.cancelRequested) await _reapGroup(r);
    r.killTimer?.cancel();
    try {
      await Future.wait([outDone, errDone]).timeout(const Duration(seconds: 2));
    } on TimeoutException {
      r.log.note('a child of the script still holds its output; not waited for');
    }
    if (!r.committed) {
      final changed = firstChanged(r.signatures);
      if (changed != null) await _enterCommit(r, changed, scriptEnded: true);
    }
    r.log.note('exit code $code');
    if (r.cancelRequested) {
      if (r.committed) throw JobFailure('cancelled', 'cancelled, but the script had started writing: repair (reinstall)');
      throw _Cancelled();
    }
    if (code != 0) throw JobFailure('script_failed', '${c.install.join(' ')} exited with $code');
  }

  /// After a cancelled script's leader ended: its group's other members (a child that ignored
  /// TERM) get KILL once [killAfter] has passed since the cancel; waits until none is left.
  Future<void> _reapGroup(_Run r) async {
    final pg = r.pgid;
    if (pg == null) return;
    final killAt = (r.cancelAt ?? DateTime.now()).add(killAfter);
    final giveUp = killAt.add(const Duration(seconds: 3));
    var killed = false;
    while (groupMembers(pg).isNotEmpty) {
      final now = DateTime.now();
      if (!killed && now.isAfter(killAt)) {
        killed = _signalGroup(r, sigKill);
        r.log.note('cancel: KILL to what is left of the process group $pg');
      }
      if (now.isAfter(giveUp)) {
        r.log.note('members of the process group $pg are still running');
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  /// The commit boundary: from here the job isn't cancellable. The script is paused while the
  /// app's units and processes are stopped (where it doesn't do that itself). One transition per
  /// job: callers await [_Run.committing].
  Future<void> _enterCommit(_Run r, String changed, {bool scriptEnded = false, bool paused = false}) {
    if (r.committing != null) return r.committing!;
    if (r.committed) return Future.value();
    r.committed = true;
    r.job['committed'] = true;
    r.job['phase'] = 'commit';
    _persist(r.job);
    r.log.note('phase: commit ($changed changed; not cancellable from here)');
    Future<void> body() async {
      final c = r.component;
      if (c != null && c.stopsOwnProcesses) {
        r.log.note('the installer stops ${r.app.name}\'s processes itself');
        return;
      }
      final pause = !paused && !scriptEnded && r.process != null && await _pause(r);
      try {
        await _stopApp(r);
      } finally {
        if (pause) _signalGroup(r, sigCont);
      }
    }

    return r.committing = body();
  }

  /// Stops the app's systemd user units, then its processes (exe under its install paths, or
  /// its interpreted helpers by script path; the user's own; not the job's own group).
  Future<void> _stopApp(_Run r) async {
    final app = r.app;
    for (final u in app.units) {
      if (ctx.runner.which('systemctl') == null) break;
      final active = await ctx.runner.run(['systemctl', '--user', 'is-active', '--quiet', u.name], timeout: const Duration(seconds: 10));
      if (!active.ok) continue;
      r.log.note('systemctl --user stop ${u.name}');
      final s = await ctx.runner.run(['systemctl', '--user', 'stop', u.name], timeout: const Duration(seconds: 60));
      if (!s.ok) r.log.note('stopping ${u.name} failed: ${s.stderr.trim()}');
      (r.job['units'] ??= <String>[]).add(u.name);
    }
    final procs = [
      for (final (pr, _) in matchingProcesses(app, paths, ctx.processes()))
        if (pr.pid != pid && (r.pgid == null || procStat(pr.pid, procRoot: paths.proc)?.pgrp != r.pgid)) pr,
    ];
    if (procs.isEmpty) return;
    r.log.note('stopping ${procs.length} process(es) of ${app.name}: ${procs.map((pr) => pr.pid).join(', ')}');
    final res = await stopProcesses(procs, signaller: signaller, procRoot: paths.proc, uid: ctx.uid, grace: stopGrace);
    (r.job['stopped'] ??= <Map<String, dynamic>>[]).addAll(res);
    _persist(r.job);
  }

  Future<void> _postSteps(_Run r, List<String> steps) async {
    for (final step in steps) {
      final argv = switch (step) {
        'gtk-update-icon-cache' => ['gtk-update-icon-cache', '-q', '-t', p.join(paths.data, 'icons/hicolor')],
        'update-desktop-database' => ['update-desktop-database', '-q', paths.apps],
        _ => null,
      };
      if (argv == null) {
        r.log.note('post step "$step": not run by this version');
        continue;
      }
      if (ctx.runner.which(argv.first) == null) {
        r.log.note('${argv.first} not found: skipped');
        continue;
      }
      if (argv.first == 'gtk-update-icon-cache' && !Directory(argv.last).existsSync()) continue;
      final res = await ctx.runner.run(argv, timeout: const Duration(seconds: 60));
      r.log.note('${argv.join(' ')}: ${res.ok ? 'ok' : 'failed (${res.stderr.trim()})'}');
    }
  }

  /// The bar after an install: bar.json put back (installers rewrite autostart files), the bar
  /// icon's process restarted (COSMIC: the old applet ended, the panel starts the new one; KDE:
  /// the tray started again with setsid, or kept stopped when it is out of the bar).
  Future<Map<String, dynamic>> _barFinish(_Run r) async {
    final app = r.app;
    final out = <String, dynamic>{};
    if (ctx.desktop == DesktopId.other || app.bar.none) return {'note': 'no bar icon here'};
    try {
      final applied = await (Bar(ctx)..follow = follow).applyWanted();
      out['applied'] = applied['changed'];
      r.log.note('bar state from bar.json applied (${(applied['changed'] as List).isEmpty ? 'nothing to change' : (applied['changed'] as List).join(', ')})');
    } on RouteError catch (e) {
      out['error'] = '${e.code}: ${e.message}';
      r.log.note('bar state not applied: ${e.code} ${e.message ?? ''}');
    }
    final procs = ctx.processes();
    bool isOld(ProcInfo pr) => r.aliveAtEnd.contains('${pr.pid}:${pr.startTicks}');
    Set<String> targets(String template) {
      final path = paths.expand(template);
      String? res;
      try {
        res = File(path).resolveSymbolicLinksSync();
      } on FileSystemException {
        res = null;
      }
      return {path, ?res};
    }

    if (ctx.desktop == DesktopId.cosmic && app.bar.cosmicApplet != null && app.bar.cosmicAppletExe != null) {
      final exe = targets(app.bar.cosmicAppletExe!);
      final panels = {for (final pr in cosmicPanels(procs)) pr.pid};
      final old = [for (final pr in procs) if (panels.contains(pr.ppid) && pr.exe != null && exe.contains(pr.exe) && isOld(pr)) pr];
      if (old.isNotEmpty) {
        await stopProcesses(old, signaller: signaller, procRoot: paths.proc, uid: ctx.uid, grace: stopGrace);
        out['restarted'] = [for (final pr in old) pr.pid];
        r.log.note('ended the old applet (${old.map((pr) => pr.pid).join(', ')})');
      }
      // cosmic-panel 1.11 does not start an applet again that ended (checked live 2026-11-09):
      // when the applet is in a panel but not running, the panel is restarted once and checked.
      final placed = cosmicInstances(paths).any((i) {
        final c = CosmicPanelConfig.read(paths, i);
        return c.error == null && c.layout.find(app.bar.cosmicApplet!) != null;
      });
      if (placed) {
        bool running() {
          final now = ctx.processes();
          final ps = {for (final pr in cosmicPanels(now)) pr.pid};
          return now.any((pr) => ps.contains(pr.ppid) && pr.exe != null && exe.contains(pr.exe));
        }

        final until = DateTime.now().add(appletWait);
        while (!running() && DateTime.now().isBefore(until)) {
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
        if (running()) {
          r.log.note('the applet runs again');
        } else {
          r.log.note('the applet did not start again: restarting the panel');
          // signals only against the real /proc (tests have a fake one)
          final f = await (panelRestart ??
              (b) => followPanel(ctx.processes, b, wait: Duration.zero, kill: paths.proc == '/proc' ? null : (_) => false))(ctx.processes());
          out['panel'] = f;
          final back = DateTime.now().add(appletWait * 3);
          while (!running() && DateTime.now().isBefore(back)) {
            await Future<void>.delayed(const Duration(milliseconds: 250));
          }
          out['applet_running'] = running();
          r.log.note(running() ? 'panel restarted; the applet runs' : 'the applet is still not running (${f['error'] ?? 'panel restarted'})');
        }
      }
    }
    if (ctx.desktop == DesktopId.kde && app.bar.kdeTrayExe != null && app.bar.kdeAutostart != null) {
      final exe = targets(app.bar.kdeTrayExe!);
      final autostart = paths.expand(app.bar.kdeAutostart!);
      final shown = File(autostart).existsSync() && !desktopHidden(autostart);
      final trays = [for (final pr in procs) if (pr.exe != null && exe.contains(pr.exe)) pr];
      final stop = shown ? trays.where(isOld).toList() : trays;
      if (stop.isNotEmpty) await stopProcesses(stop, signaller: signaller, procRoot: paths.proc, uid: ctx.uid, grace: stopGrace);
      final left = trays.where((t) => !stop.contains(t)).toList();
      if (shown && left.isEmpty) {
        final ok = await startDetached(paths.expand(app.bar.kdeTrayExe!), app.bar.kdeTrayArgs);
        out['trayStarted'] = ok;
        r.log.note(ok ? 'tray started' : 'the tray could not be started');
      } else if (!shown) {
        out['trayStopped'] = stop.length;
        if (stop.isNotEmpty) r.log.note('tray kept stopped (not in the bar)');
      }
    }
    return out;
  }

  /// Starts a program in its own session, detached from this one (KDE trays).
  Future<bool> startDetached(String exe, [List<String> args = const []]) async {
    if (!isExecutableFileOrLink(exe)) return false;
    final env = scriptEnv(const Component(id: 'tray', name: 'tray', repo: '', install: [], paths: []));
    try {
      await Process.start(ctx.runner.which('setsid') ?? '/usr/bin/setsid', [exe, ...args],
          mode: ProcessStartMode.detached, environment: env, includeParentEnvironment: false, workingDirectory: paths.home);
      return true;
    } on ProcessException {
      return false;
    }
  }

  // ---------- remove ----------

  Future<Map<String, dynamic>> _remove(_Run r) async {
    final app = r.app;
    final options = r.job['options'] as Map<String, dynamic>;
    _phase(r, 'prepare');
    final plan = await removePlan(ctx, app, deleteSettings: options['delete_settings'] == true);
    r.job['plan'] = {'revision': plan.revision, 'goes': plan.goes.length, 'stays': (plan.json['stays'] as List).length};
    if (options['revision'] != null && options['revision'] != plan.revision) {
      throw JobFailure('changed', 'what would be removed changed since the plan was shown');
    }
    final dependents = plan.json['dependents'] as List;
    if (dependents.isNotEmpty && options['dependents_ok'] != true) {
      throw JobFailure('needed_by', 'needed by ${dependents.map((d) => d['name']).join(', ')}');
    }
    for (final s in (plan.json['stays'] as List).cast<Map<String, dynamic>>()) {
      r.log.note('stays: ${s['path']} (${s['why']})');
    }
    _checkCancel(r);

    _phase(r, 'commit');
    final barId = switch (ctx.desktop) {
      DesktopId.cosmic => app.bar.cosmicApplet,
      DesktopId.kde => app.bar.kdeId,
      DesktopId.other => null,
    };
    if (barId != null) {
      try {
        await (Bar(ctx)..follow = follow).remove({'app': app.id}, remember: false, autostart: false);
        r.log.note('bar icon taken out');
      } on RouteError catch (e) {
        throw JobFailure('bar_failed', 'the bar icon could not be taken out (${e.code}: ${e.message}); nothing was removed');
      }
    }
    r.committed = true;
    r.job['committed'] = true;
    await _stopApp(r);

    final deleted = <String>[], kept = <Map<String, dynamic>>[];
    final reach = sharedRoots(paths);
    for (final g in plan.goes.where((g) => g['kind'] != 'dir')) {
      final path = g['path'] as String;
      final unsafe = unsafeReach(path, reach); // checked again right before the delete
      if (unsafe != null) {
        kept.add({'path': path, 'why': unsafe});
        continue;
      }
      final now = pathState(path, normalized: g['normalized'] as String?);
      if (now['exists'] != true) continue;
      if (g['kind'] == 'file' && now['type'] == 'file' && now['sha256'] == g['sha256']) {
        File(path).deleteSync();
      } else if (g['kind'] == 'link' && now['type'] == 'link' && now['link'] == g['link']) {
        Link(path).deleteSync();
      } else {
        kept.add({'path': path, 'why': 'changed while removing'});
        continue;
      }
      deleted.add(path);
      r.log.note('removed $path');
    }
    final dirs = plan.goes.where((g) => g['kind'] == 'dir').map((g) => g['path'] as String).toList()
      ..sort((a, b) => p.split(b).length.compareTo(p.split(a).length));
    for (final d in dirs) {
      if (_removeIfEmpty(d)) deleted.add(d);
    }
    for (final path in [...deleted]) {
      _pruneParents(p.dirname(path));
    }
    final displaced = Displaced.load(paths, app.id);
    final restored = <String>[];
    for (final planned in plan.restores) {
      final e = displaced.of(planned['path'] as String);
      if (e == null || e['restore'] != true || unsafeReach(e['path'] as String, reach) != null) continue;
      if (displaced.restoreEntry(e)) {
        restored.add(e['path'] as String);
        r.log.note('restored ${e['path']} (it was there before the Manager installed ${app.name})');
        displaced.drop(e);
      }
    }
    displaced.save();
    final settings = <String>[];
    for (final path in plan.settingsGo) {
      if (unsafeReach(path, reach) != null) continue;
      final t = FileSystemEntity.typeSync(path, followLinks: false);
      if (t == FileSystemEntityType.link) {
        Link(path).deleteSync();
      } else if (t == FileSystemEntityType.directory) {
        Directory(path).deleteSync(recursive: true);
      } else if (t != FileSystemEntityType.notFound) {
        File(path).deleteSync();
      }
      settings.add(path);
      r.log.note('deleted settings $path');
    }

    _phase(r, 'verify');
    final still = [for (final path in deleted) if (!restored.contains(path) && FileSystemEntity.typeSync(path, followLinks: false) != FileSystemEntityType.notFound) path];
    if (still.isNotEmpty) throw JobFailure('verify_failed', 'still there: ${still.join(', ')}');

    _phase(r, 'finish');
    await _postSteps(r, const ['gtk-update-icon-cache', 'update-desktop-database']);
    // What stays is recorded, so a later remove without a receipt never takes it as the app's.
    final keptNow = <Map<String, dynamic>>[];
    final known = {for (final (_, path) in catalogPaths(paths, app.components)) path};
    final oldKept = loadKept(paths, app.id);
    for (final path in {...oldKept.keys, for (final s in [...(plan.json['stays'] as List), ...kept]) s['path'] as String}) {
      if (!known.contains(path)) continue;
      final st = pathState(path, normalized: normalizedPaths(paths, app).contains(path) ? normalizedHidden : null);
      if (st['exists'] != true) continue;
      keptNow.add({'path': path, 'sha256': ?st['sha256'], 'link': ?st['link'], 'type': st['type']});
    }
    if (keptNow.isEmpty) {
      final f = File(keptFile(paths, app.id));
      if (f.existsSync()) f.deleteSync();
    } else {
      atomicWrite(keptFile(paths, app.id), const JsonEncoder.withIndent('  ').convert({'at': ctx.clock().toUtc().toIso8601String(), 'paths': keptNow}));
    }
    final receipt = File(p.join(paths.receipts, '${app.id}.json'));
    if (receipt.existsSync()) receipt.deleteSync();
    r.log.note('receipt dropped${keptNow.isEmpty ? '' : '; ${keptNow.length} kept path(s) recorded'}');
    return {
      'deleted': deleted,
      'kept': [...(plan.json['stays'] as List), ...kept],
      'restored': restored,
      'settingsDeleted': settings,
      'stopped': r.job['stopped'] ?? const [],
    };
  }

  /// Folders that are never removed when they become empty (the shared roots and above).
  late final Set<String> _roots = () {
    final base = {paths.home, ...sharedRoots(paths)};
    final all = <String>{};
    for (final b in base) {
      var d = p.normalize(b);
      while (all.add(d) && d != p.dirname(d)) {
        d = p.dirname(d);
      }
    }
    return all;
  }();

  bool _removeIfEmpty(String dir) {
    try {
      final d = Directory(dir);
      if (FileSystemEntity.typeSync(dir, followLinks: false) != FileSystemEntityType.directory) return false;
      if (d.listSync().isNotEmpty) return false;
      d.deleteSync();
      return true;
    } on FileSystemException {
      return false;
    }
  }

  void _pruneParents(String dir) {
    var d = p.normalize(dir);
    while (!_roots.contains(d) && p.isWithin(paths.home, d) && _removeIfEmpty(d)) {
      d = p.dirname(d);
    }
  }
}

bool isExecutableFileOrLink(String path) {
  try {
    final st = File(path).statSync();
    return st.type == FileSystemEntityType.file && st.mode & 0x49 != 0;
  } on FileSystemException {
    return false;
  }
}

// ---------- the jobs on disk (any process) ----------

bool validJobId(String id) => RegExp(r'^[0-9]{8}T[0-9]{6}Z-[a-z0-9]+-[a-z]+(-[0-9]+)?$').hasMatch(id);

String _jobsDir(Paths paths) => p.join(paths.managerState, 'jobs');

/// A job's state, with an unfinished job of a process that is gone marked `interrupted` (and
/// saved so). A script still running without its Manager is told as `orphan`.
Map<String, dynamic>? loadJob(Paths paths, String id) {
  final f = File(p.join(_jobsDir(paths), '$id.json'));
  Map<String, dynamic> job;
  try {
    final data = jsonDecode(f.readAsStringSync());
    if (data is! Map<String, dynamic> || data['id'] != id) return null;
    job = data;
  } on FileSystemException {
    return null;
  } on FormatException {
    return null;
  }
  if (job['finished'] == true) return job;
  final owner = job['owner'];
  // Identity = pid + start time; without a start time nothing counts as alive.
  final alive = owner is Map && owner['pid'] is int && owner['start'] is int && sameProcess(owner['pid'] as int, owner['start'] as int);
  if (alive) return job;
  final orphan = orphanRunning(job);
  final script = job['script'];
  if (orphan && script is Map && paths.proc == '/proc') {
    // A script paused at the commit boundary must not stay paused without its Manager.
    Signaller().group(script['pgid'] as int, sigCont);
  }
  final committed = job['committed'] == true;
  job
    ..['state'] = 'interrupted'
    ..['finished'] = true
    ..['result'] = {
      'ok': false,
      'code': 'interrupted',
      'message': 'the Manager that ran it ended in the ${job['phase']} phase${orphan ? '; its script still runs (pid ${script['pid']})' : ''}',
      'repair': job['phase'] != 'queued',
      'committed': committed,
      if (orphan) 'orphan': true,
    };
  try {
    atomicWrite(f.path, const JsonEncoder.withIndent('  ').convert(job));
  } on FileSystemException {
    // shown anyway
  }
  return job;
}

/// The job's script (or what is left of its process group) still runs: for an interrupted job,
/// nothing else may change the app until it has ended.
bool orphanRunning(Map<String, dynamic> job) {
  final script = job['script'];
  if (script is! Map || script['pgid'] is! int) return false;
  final pg = script['pgid'] as int;
  if (script['start'] is int && sameProcess(pg, script['start'] as int)) return true;
  return groupMembers(pg).isNotEmpty;
}

/// Every job on disk, newest first.
List<Map<String, dynamic>> loadJobs(Paths paths) {
  final dir = Directory(_jobsDir(paths));
  if (!dir.existsSync()) return const [];
  final ids = [
    for (final e in dir.listSync())
      if (e is File && e.path.endsWith('.json') && validJobId(p.basenameWithoutExtension(e.path))) p.basenameWithoutExtension(e.path),
  ]..sort((a, b) => b.compareTo(a));
  return [for (final id in ids) ?loadJob(paths, id)];
}

/// The short form (jobs.list, status).
Map<String, dynamic> summary(Map<String, dynamic> job) => {
  for (final k in ['id', 'app', 'kind', 'state', 'phase', 'component', 'created', 'started', 'ended', 'committed', 'log', 'result'])
    if (job[k] != null) k: job[k],
};

/// The latest job of each app (for the status): repair is offered after an interrupted job, or a
/// failed one that had started writing.
Map<String, Map<String, dynamic>> latestJobs(Paths paths) {
  final out = <String, Map<String, dynamic>>{};
  for (final j in loadJobs(paths)) {
    final app = j['app'];
    if (app is String) out.putIfAbsent(app, () => summary(j));
  }
  return out;
}

bool repairOffered(Map<String, dynamic>? job) {
  if (job == null) return false;
  final result = job['result'];
  return result is Map && result['repair'] == true && (job['state'] == 'interrupted' || job['state'] == 'failed');
}
