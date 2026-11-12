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

import 'translations.dart';


import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'bar.dart';
import 'bar_hypr.dart';
import 'bar_cosmic.dart';
import 'bar_kde.dart';
import 'bar_read.dart';
import 'catalog.dart';
import 'context.dart';
import 'core.dart' show coreVersion;
import 'git.dart' show Git, Relation;
import 'github.dart';
import 'icons.dart';
import 'kde_remove.dart';
import 'ownership.dart';
import 'paths.dart';
import 'procs.dart';
import 'pub_refresh.dart';
import 'receipts.dart';
import 'removal.dart';
import 'run.dart' show isExecutableFile;
import 'sources.dart';
import 'status.dart';
import 'sysproc.dart';
import 'trees.dart';

part 'jobs_pacman.dart';
part 'jobs_self.dart';

enum JobKind { install, update, reinstall, remove, release }

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
      _raf.writeFromSync(utf8.encode(trf('\n» [{0} bytes of output left out]\n', [_dropped - tail.length])));
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

  /// The script's last output (bounded): tells a refusal (the app is busy) from a failure.
  final recent = StringBuffer();
  void remember(List<int> data) {
    recent.write(utf8.decode(data, allowMalformed: true));
    if (recent.length > 16384) {
      final t = recent.toString();
      recent
        ..clear()
        ..write(t.substring(t.length - 8192));
    }
  }
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

  /// How long pkexec may wait for its password dialog before it is ended (Maprisma's pacman steps).
  Duration pkexecWait = const Duration(minutes: 5);

  int maxLog = maxLogBytes;

  /// The self-update: how long the new Manager may take to say it is ready (else the old one
  /// comes back), and how long the helper waits for the running Manager to quit.
  Duration selfReadyTimeout = const Duration(seconds: 20);
  Duration selfQuitTimeout = const Duration(minutes: 10);

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
    if (app == null) throw RouteError('not_found', trf('no app {0}', [appId]));
    final kindName = params['kind'];
    final kind = JobKind.values.where((k) => k.name == kindName).firstOrNull;
    if (kind == null) throw RouteError('bad_params', tr('kind (install, update, reinstall, remove, release)'));
    final rawOptions = params['options'] ?? const {};
    if (rawOptions is! Map) throw RouteError('bad_params', 'options');
    final options = Map<String, dynamic>.from(rawOptions);
    for (final k in ['delete_settings', 'dependents_ok']) {
      if (options[k] != null && options[k] is! bool) throw RouteError('bad_params', 'options.$k');
    }
    if (options['revision'] != null && options['revision'] is! String) throw RouteError('bad_params', 'options.revision');
    // Flags an installer takes (Launcher: force): a bool, and only where a component knows it.
    const known = {'delete_settings', 'dependents_ok', 'revision', 'tag', 'source'};
    for (final k in options.keys) {
      if (known.contains(k)) continue;
      if (!app.components.any((c) => c.flags.containsKey(k))) throw RouteError('bad_params', trf('options.{0}: {1} has no such option', [k, app.name]));
      if (options[k] is! bool) throw RouteError('bad_params', 'options.$k');
      if (kind == JobKind.remove) throw RouteError('bad_params', trf('options.{0} is for installs', [k]));
    }
    if (options['source'] != null) {
      if (options['source'] != 'release' && options['source'] != 'folder') throw RouteError('bad_params', tr('options.source (release or folder)'));
      if (!app.components.any((c) => c.kind == InstallKind.pacman) || kind == JobKind.remove || kind == JobKind.release) {
        throw RouteError('bad_params', tr('options.source is for a pacman package\'s install, update and reinstall'));
      }
    }
    if (params['tag'] != null && options['tag'] == null) options['tag'] = params['tag'];
    if (options['tag'] != null && (options['tag'] is! String || !validTag(options['tag'] as String))) {
      throw RouteError('bad_params', 'tag');
    }
    if (kind == JobKind.remove) {
      checkRemovable(app, ctx.desktop);
    } else if (kind == JobKind.release) {
      final spec = app.release;
      if (spec == null) throw RouteError('unavailable', trf('{0} has no GitHub releases', [app.name]));
      if (!spec.supported) {
        throw RouteError('unsupported_yet', trf('installing a {0} release is not supported yet{1}', [app.name, spec.note == null ? '' : ': ${spec.note}']));
      }
      final c = app.components.where((c) => c.id == spec.component).firstOrNull;
      if (!app.desktops.contains(ctx.desktop) || c == null || !c.desktops.contains(ctx.desktop)) {
        throw RouteError('unavailable', trf('{0} is not for {1}', [app.name, ctx.desktop.name]));
      }
    } else {
      if (app.installation == Support.unsupportedYet) {
        throw RouteError('unsupported_yet', trf('installing {0} is not supported yet{1}', [app.name, app.supportNote == null ? '' : ': ${app.supportNote}']));
      }
      if (!app.desktops.contains(ctx.desktop) || !app.components.any((c) => c.desktops.contains(ctx.desktop))) {
        throw RouteError('unavailable', trf('{0} is not for {1}', [app.name, ctx.desktop.name]));
      }
    }
    if (_exclusive) throw RouteError('busy', tr('a bar icon is being changed: try again in a moment'));
    // While the Manager's update waits to be swapped in, nothing new starts (the window that quits
    // for it would leave the job behind).
    final pending = pendingSelfUpdate(paths);
    if (pending != null) {
      throw RouteError('busy', trf('the Manager\'s update {0} waits to be put in place (helper pid {1}): close Maprisma Manager to finish it', [pending.job, pending.pid]));
    }
    if (_runs.values.any((r) => r.job['app'] == appId && r.job['finished'] != true)) {
      throw RouteError('busy', trf('a job for {0} is already queued or running', [app.name]));
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

  /// The job of this engine with [id] when it has finished (its whole record); null for a job
  /// this engine doesn't run.
  Future<Map<String, dynamic>>? finished(String id) => _runs[id]?.done.future;

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
    return {
      'jobs': [
        for (final j in jobs.take(limit))
          summary(_runs[j['id']] != null && _runs[j['id']]!.job['finished'] != true ? _runs[j['id']]!.job : j),
      ],
    };
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
      if (job['finished'] == true) throw RouteError('finished', tr('the job has ended'));
      throw RouteError('not_owner', trf('the job runs in another Maprisma Manager (pid {0})', [(job['owner'] as Map?)?['pid']]));
    }
    final job = run.job;
    if (job['finished'] == true) throw RouteError('finished', tr('the job has ended'));
    if (job['state'] == 'queued') {
      _queue.remove(run);
      run.log.note(tr('cancelled before it started'));
      _end(run, 'cancelled', {'ok': false, 'code': 'cancelled'});
      return {'id': run.id, 'cancelled': true};
    }
    if (run.committed || !['prepare', 'build'].contains(job['phase'])) {
      throw RouteError('not_cancellable', trf('the job is in its {0} phase (it changes files now)', [job['phase']]));
    }
    if (run.process == null || run.pgid == null) {
      // prepare, or the script is being started: it is ended as soon as its group is known.
      run.cancelRequested = true;
      run.log.note(tr('cancel asked: the job stops before the next step'));
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
      throw RouteError('not_cancellable', tr('the script could not be paused to check it'));
    }
    final changed = firstChanged(run.signatures);
    if (changed != null) {
      try {
        await _enterCommit(run, changed, paused: true);
      } finally {
        _signalGroup(run, sigCont);
      }
      throw RouteError('not_cancellable', trf('the install has started writing its files ({0})', [changed]));
    }
    run.cancelRequested = true;
    run.cancelAt = DateTime.now();
    run.log.note(trf('cancel: TERM to the script\'s process group {0}', [run.pgid]));
    _signalGroup(run, sigTerm);
    _signalGroup(run, sigCont);
    run.killTimer = Timer(killAfter, () {
      if (_signalGroup(run, sigKill)) run.log.note(trf('cancel: KILL to the process group {0}', [run.pgid]));
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
    if (holder != null && holder != this) throw RouteError('busy', tr('another job runs in this process'));
    final f = File(lockPath);
    f.createSync(recursive: true);
    // A script whose Manager is gone may still be writing (an interrupted job's orphan).
    final orphan = loadJobs(paths).where((j) => j['state'] == 'interrupted' && orphanRunning(j)).firstOrNull;
    if (orphan != null) {
      final who = (orphan['pkexec'] ?? orphan['script']) as Map;
      throw RouteError('busy', trf('the {0} of the interrupted job {1} still runs (pid {2}); wait for it to end', [orphan['pkexec'] != null ? 'pkexec/pacman' : 'script', orphan['id'], who['pid']]));
    }
    final raf = f.openSync(mode: FileMode.append);
    try {
      raf.lockSync(FileLock.exclusive);
    } on FileSystemException {
      raf.closeSync();
      final other = loadJobs(paths).where((j) => j['finished'] != true).firstOrNull;
      throw RouteError('busy', other == null ? tr('another Maprisma Manager runs a job') : trf('another Maprisma Manager runs {0} {1} ({2})', [other['kind'], other['app'], other['id']]));
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
    // A finished job's file is the truth (the self-update helper finishes the Manager's later).
    if (live != null && live.job['finished'] != true) return live.job;
    final j = loadJob(paths, id) ?? live?.job;
    if (j == null) throw RouteError('not_found', trf('no job {0}', [id]));
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
    r.log.note(trf('phase: {0}{1}', [phase, component == null ? '' : ' (${component.name})']));
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
    r.log.note('${uiLabel(state)}${result['code'] == null ? '' : ': ${result['code']}'}${result['message'] == null ? '' : ' (${result['message']})'}');
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
    r.log.note(trf('{0} {1} (job {2})', [r.kind.name, r.app.name, r.id]));
    try {
      final pacman = r.app.components.any((c) => c.kind == InstallKind.pacman);
      final result = r.kind == JobKind.remove
          ? await (pacman ? _removePacman(r) : _remove(r))
          : r.app.id == selfApp
          ? await _installSelf(r)
          : await (pacman ? _installPacman(r) : _install(r));
      _end(r, 'succeeded', {'ok': true, ...result});
    } on _Cancelled {
      _dropNewBackups(r);
      _end(r, 'cancelled', {'ok': false, 'code': 'cancelled', 'message': tr('nothing was changed')});
    } on JobFailure catch (f) {
      if (!r.committed) _dropNewBackups(r);
      if (r.committed && r.kind != JobKind.remove) {
        // The installer may have rewritten the autostart file: the wanted bar state still holds.
        try {
          await (Bar(ctx)..follow = follow).applyWanted();
        } on Object catch (e) {
          r.log.note(trf('bar state not applied: {0}', [e]));
        }
      }
      _end(r, 'failed', {
        'ok': false,
        'code': f.code,
        'message': f.message,
        'repair': r.committed,
      });
    } catch (e, st) {
      r.log.note(trf('internal error: {0}\n{1}', [e, st]));
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

  /// The component a release installs: its paths, the release's installer and prerequisites.
  Component _releaseComponent(AppEntry app) {
    final spec = app.release!;
    final base = app.components.firstWhere((c) => c.id == spec.component);
    return Component(
      id: base.id,
      name: base.name,
      repo: base.repo,
      install: spec.install,
      paths: base.paths,
      kind: base.kind,
      desktops: base.desktops,
      prerequisites: spec.prerequisites,
      optionalParts: base.optionalParts,
      stopsOwnProcesses: base.stopsOwnProcesses,
      env: base.env,
      trees: base.trees,
      flags: base.flags,
      busyMarker: base.busyMarker,
      note: base.note,
    );
  }

  /// Components in dependency order (`app/component` and `component` names within the app).
  List<Component> _ordered(AppEntry app, List<Component> comps) {
    final out = <Component>[];
    final seen = <String>{};
    void visit(Component c, Set<String> path) {
      if (seen.contains(c.id) || !path.add(c.id)) return;
      for (final d in c.dependsOn) {
        final parts = d.split('/');
        if (parts.length == 2 && parts[0] != app.id) continue;
        final dep = comps.where((x) => x.id == parts.last).firstOrNull;
        if (dep != null) visit(dep, path);
      }
      if (seen.add(c.id)) out.add(c);
    }

    for (final c in comps) {
      visit(c, {});
    }
    return out;
  }

  /// The prepare phase of an install, update or reinstall: dependencies, prerequisites, every
  /// input present (cloned when missing), an update's pull / fast-forward, the inputs as they are
  /// built; `upToDate` for an update with nothing new.
  Future<({StatusReader status, List<String> repos, List<Map<String, dynamic>> notes, List<Map<String, dynamic>> inputs, bool upToDate})> _prepareInputs(
      _Run r, List<Component> comps, {required bool release}) async {
    final app = r.app;
    _phase(r, 'prepare');
    final status = StatusReader(ctx);

    for (final dep in app.dependsOn) {
      final d = findApp(dep);
      if (d == null) continue;
      final states = [for (final c in _components(d)) (await status.component(d, c)).state];
      if (states.isEmpty || states.any((s) => s != InstallState.installed)) {
        throw JobFailure('missing_dependency', trf('{0} needs {1} installed first', [app.name, d.name]));
      }
    }
    for (final c in comps) {
      for (final pr in c.prerequisites) {
        if (pr.optional || ctx.tool(pr.command) != null) continue;
        if (pr.part != null && c.optionalParts.contains(pr.part)) {
          r.log.note(trf('{0} not found: the {1} is skipped by the installer', [pr.command, pr.part]));
          (r.job['warnings'] ??= <String>[]).add(trf('{0} missing: no {1}', [pr.command, pr.part]));
          continue;
        }
        throw JobFailure('missing_prerequisite', trf('{0} needs {1}', [c.name, pr.command]));
      }
    }
    final repos = release ? [comps.single.repo] : _repos(app, comps);
    final notes = <Map<String, dynamic>>[];
    for (final repo in repos) {
      final folder = ctx.repoFolder(repo);
      final input = app.inputs.firstWhere((i) => i.repo == repo, orElse: () => Input(repo));
      if (FileSystemEntity.typeSync(folder, followLinks: false) == FileSystemEntityType.notFound) {
        await _clone(r, input, folder);
        notes.add({'repo': repo, 'cloned': ctx.github.cloneUrlOf(input)});
      }
      final g = await ctx.git.inspect(repo, folder);
      if (!g.present) throw JobFailure('no_source', trf('{0} is missing', [folder]));
      if (!g.isRepo || g.head == null) throw JobFailure('no_source', '$folder: ${g.error ?? 'not a git repository with a commit'}');
      if (r.kind != JobKind.update) continue;
      // The GitHub remote fetched first (the comparisons below then see what GitHub has now).
      final ghSlug = ctx.github.slugOf(input);
      final gh = ghSlug == null ? null : await githubRemote(ctx, folder, ghSlug, upstreamRemote: g.upstreamRemote);
      if (gh != null) {
        r.log.note(trf('{0}: git fetch {1} (GitHub, {2})', [repo, gh.name, gh.url]));
        final f = await ctx.git.fetch(folder, gh.name);
        if (f.stderr.trim().isNotEmpty) r.log.add(utf8.encode(f.stderr.endsWith('\n') ? f.stderr : '${f.stderr}\n'));
        if (!f.ok) r.log.note(trf('{0}: fetching {1} failed; compared with what was fetched before', [repo, gh.name]));
        _checkCancel(r);
      }
      final g2 = gh == null ? g : await ctx.git.inspect(repo, folder);
      if (g2.upstream == null) {
        r.log.note(trf('{0}: no upstream, built as it is', [repo]));
      } else if (g2.dirty != false) {
        r.log.note(trf('{0}: uncommitted changes, no pull; built as it is', [repo]));
      } else if (g2.relation == Relation.behind) {
        r.log.note(trf('{0}: git pull --ff-only ({1} new from {2})', [repo, g2.behind, g2.upstream]));
        final pull = await ctx.git.pullFfOnly(folder);
        if (pull.stdout.isNotEmpty) r.log.add(utf8.encode(pull.stdout));
        if (pull.stderr.isNotEmpty) r.log.add(utf8.encode(pull.stderr));
        if (!pull.ok) throw JobFailure('pull_failed', trf('{0}: git pull --ff-only failed', [repo]));
      } else {
        r.log.note(trf('{0}: {1} against {2}, no pull', [repo, g2.relation.name, g2.upstream]));
      }
      _checkCancel(r);
      final ff = await _githubUpdate(r, input, folder, fetched: gh != null);
      if (ff != null) notes.add(ff);
      _checkCancel(r);
    }
    if (notes.isNotEmpty) r.job['sources'] = notes;
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
      if (rec != null && !rec.fromRelease && inputs.every(same) && rec.inputs.length == inputs.length) {
        final states = [for (final c in comps) (await status.component(app, c)).state];
        if (states.every((s) => s == InstallState.installed)) {
          r.log.note(trf('already up to date: the installed build is {0}', [inputs.map((i) => '${i['repo']}@${'${i['commit']}'.substring(0, 7)}').join(', ')]));
          return (status: status, repos: repos, notes: notes, inputs: inputs, upToDate: true);
        }
      }
    }

    return (status: status, repos: repos, notes: notes, inputs: inputs, upToDate: false);
  }

  Future<Map<String, dynamic>> _install(_Run r) async {
    final app = r.app;
    final release = r.kind == JobKind.release;
    final comps = release ? [_releaseComponent(app)] : _ordered(app, _components(app));
    final prep = await _prepareInputs(r, comps, release: release);
    if (prep.upToDate) return {'up_to_date': true};
    final (status: status, repos: repos, notes: notes, inputs: inputs, upToDate: _) = prep;

    // A release: the tarball downloaded and checked against its .sha256 before anything else.
    ({Map<String, dynamic> release, String asset, String file, String sha256})? rel;
    if (release) rel = await _downloadRelease(r, app);

    await _seedWantedBar(r);
    _checkCancel(r);

    // Snapshot and displaced files, before anything runs.
    final cat = catalogPaths(paths, comps);
    final norm = normalizedPaths(paths, app);
    final before = {for (final (_, path) in cat) path: pathState(path, normalized: norm.contains(path) ? normalizedHidden : null)};
    final receipt = readReceipt(paths, app.id).receipt;
    final displaced = Displaced.load(paths, app.id);
    final at = ctx.clock();
    // Owned folders: replaced as a whole by their installer, so none of their files is displaced;
    // one that is there before the first install through the Manager may not be only the app's.
    final treeRoots = [for (final c in comps) for (final t in c.trees) (t, paths.expand(t.path))];
    bool inTree(String path) => treeRoots.any((t) => p.isWithin(t.$2, path) || t.$2 == path);
    final preexisting = <String>{
      for (final (t, root) in treeRoots)
        if (t.mayPreexist &&
            (receipt?.tree(root)?['preexisting'] == true ||
                (receipt?.tree(root) == null && FileSystemEntity.typeSync(root, followLinks: false) != FileSystemEntityType.notFound)))
          root,
    };
    for (final root in preexisting) {
      r.log.note(trf('{0} was there before: it stays on remove', [root]));
    }
    // Icons: the Plasma style before a generated one, to switch back to on remove.
    final saved = <String, String>{...?receipt?.saved};
    if (app.removeRecipe == RemoveRecipe.plasmaIcons) {
      final style = plasmaStyle(paths);
      if (!isGeneratedStyle(style)) saved['plasmaTheme'] = style ?? 'default';
    }
    for (final (_, path) in cat) {
      if (inTree(path)) continue;
      final st = before[path]!;
      if (st['exists'] != true || (st['type'] != 'file' && st['type'] != 'link')) continue;
      final owned = receipt?.paths.where((e) => e['path'] == path).firstOrNull;
      final ours = owned != null && ((owned['sha256'] != null && owned['sha256'] == st['sha256']) || (owned['link'] != null && owned['link'] == st['link']));
      if (ours) continue;
      final e = displaced.add(path, st,
          restore: receipt != null,
          reason: receipt == null ? tr('before the Manager') : (owned == null ? tr('not in the receipt') : tr('changed since the install')),
          job: r.id,
          at: at);
      if (e != null) r.newBackups.add(e);
    }
    displaced.save();
    if (r.newBackups.isNotEmpty) r.log.note(trf('backed up {0} file(s) that weren\'t the Manager\'s', [r.newBackups.length]));
    r.signatures = signatures([for (final (_, path) in cat) path]);
    _checkCancel(r);

    if (rel != null) {
      final undo = await _placeTarball(r, ctx.repoFolder(comps.single.repo), app.release!, rel.file, rel.asset, rel.sha256);
      try {
        await _runScript(r, comps.single);
      } finally {
        undo();
      }
    } else {
      for (final c in comps) {
        await _runScript(r, c);
      }
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
        r.log.note(trf('postcondition: {0}: {1}', [f['path'], f['problem']]));
      }
      throw JobFailure('verify_failed', trf('{0} path(s) not as the installer leaves them', [failing.length]));
    }
    if (partial.isNotEmpty) r.log.note(trf('partly installed: no {0}', [partial.join(', ')]));

    _phase(r, 'finish');
    // A bar icon the user changed through the Manager: the installer put the default back.
    try {
      final icon = IconService(ctx, this).reapply(app);
      if (icon != null) r.log.note(icon);
    } on Object catch (e) {
      r.log.note(trf('the chosen bar icon could not be applied again: {0}', [e]));
    }
    await _postSteps(r, app.postSteps);
    // Units stopped at the commit are started again (Narrator's reader).
    final unitsStarted = <String>[];
    for (final u in (r.job['units'] as List? ?? const []).cast<String>()) {
      final s = await ctx.runner.run(['systemctl', '--user', 'start', u], timeout: const Duration(seconds: 60));
      r.log.note(trf('systemctl --user start {0}: {1}', [u, s.ok ? tr('ok') : trf('failed ({0})', [s.stderr.trim()])]));
      if (s.ok) unitsStarted.add(u);
    }
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
    // A release installs one component: what the last receipt says about the others is kept.
    final catSet = {for (final (_, path) in cat) path};
    final otherComps = [for (final c in app.components) if (!comps.any((x) => x.id == c.id)) c];
    final otherPaths = {for (final (_, path) in catalogPaths(paths, otherComps)) path};
    final carried = release && receipt != null
        ? [for (final e in receipt.paths) if (!catSet.contains(e['path']) && otherPaths.contains(e['path'])) e]
        : const <Map<String, dynamic>>[];
    // The owned folders as installed now (a release carries the other components' folders over).
    final trees = <Map<String, dynamic>>[];
    for (final (_, root) in treeRoots) {
      final m = treeManifest(root);
      if (m == null) continue;
      if (preexisting.contains(root)) m['preexisting'] = true;
      trees.add(m);
      r.log.note(m['overflow'] == true ? trf('{0}: too many files to own ({1})', [root, m['files']]) : trf('{0}: {1} files owned', [root, m['files']]));
    }
    final otherRoots = {for (final c in otherComps) for (final t in c.trees) paths.expand(t.path)};
    if (release && receipt != null) {
      trees.addAll([for (final t in receipt.trees) if (otherRoots.contains(t['root']) && !trees.any((x) => x['root'] == t['root'])) t]);
    }
    final carriedInputs = release && receipt != null && carried.isNotEmpty
        ? [for (final i in receipt.inputs) if (!repos.contains(i.repo)) i.toJson()]
        : const <Map<String, dynamic>>[];
    final receiptJson = <String, dynamic>{
      'schema': 1,
      'id': app.id,
      'at': ctx.clock().toUtc().toIso8601String(),
      'version': ?(status.bundleVersion(app) ?? (rel != null ? tagVersion(rel.release['tag'] as String) : status.folderVersion(app))),
      'manager': coreVersion,
      'job': r.id,
      'kind': r.kind.name,
      'components': [for (final c in comps) c.id, if (carried.isNotEmpty) for (final c in otherComps) c.id],
      if (partial.isNotEmpty) 'partial': partial.toList(),
      'source': rel == null
          ? {'kind': 'folder'}
          : {'kind': 'release', 'tag': rel.release['tag'], 'asset': rel.asset, 'sha256': rel.sha256, 'url': ?rel.release['url']},
      'inputs': [...inputs, ...carriedInputs],
      'paths': [
        for (final (_, path) in cat)
          if (pathState(path, normalized: norm.contains(path) ? normalizedHidden : null) case final st when st['exists'] == true)
            switch (st['type']) {
              'file' => {'path': path, 'sha256': st['sha256'], 'mode': st['mode'], 'normalized': ?st['normalized']},
              'link' => {'path': path, 'link': st['link']},
              _ => {'path': path, 'dir': true},
            },
        ...carried,
      ],
      'displaced': [for (final e in d.entries) {'path': e['path'], 'backup': e['backup'], 'restore': e['restore'], 'reason': e['reason']}],
      if (trees.isNotEmpty) 'trees': trees,
      if (saved.isNotEmpty) 'saved': saved,
    };
    Receipt.parse(app.id, jsonDecode(jsonEncode(receiptJson))); // never write one the reader refuses
    atomicWrite(p.join(paths.receipts, '${app.id}.json'), const JsonEncoder.withIndent('  ').convert(receiptJson));
    final keptRecord = File(keptFile(paths, app.id));
    if (keptRecord.existsSync()) keptRecord.deleteSync(); // the receipt says what is the app's now
    r.log.note(trf('receipt written ({0} paths)', [(receiptJson['paths'] as List).length]));
    return {
      if (partial.isNotEmpty) 'partial': partial.toList(),
      if (rel != null) 'release': {'tag': rel.release['tag'], 'asset': rel.asset, 'sha256': rel.sha256},
      if (notes.isNotEmpty) 'sources': notes,
      'stopped': r.job['stopped'] ?? const [],
      if (unitsStarted.isNotEmpty) 'unitsStarted': unitsStarted,
      'bar': bar,
      'receipt': p.join(paths.receipts, '${app.id}.json'),
    };
  }

  /// Clones the input's GitHub repo into [folder] (missing): into a hidden sibling first, renamed
  /// when complete, so a cancelled or failed clone leaves nothing behind. Cancellable.
  Future<void> _clone(_Run r, Input input, String folder) async {
    final slug = ctx.github.slugOf(input);
    if (slug == null) throw JobFailure('no_source', trf('{0} is missing and {1} is not on GitHub', [folder, input.repo]));
    final git = ctx.runner.which('git');
    if (git == null) throw JobFailure('missing_prerequisite', trf('git is needed to clone {0}', [input.repo]));
    final url = ctx.cloneUrlFor(slug);
    final parent = p.dirname(folder);
    Directory(parent).createSync(recursive: true);
    final tmp = p.join(parent, '.${p.basename(folder)}.clone-${r.id}');
    void drop() {
      if (FileSystemEntity.typeSync(tmp, followLinks: false) == FileSystemEntityType.directory) Directory(tmp).deleteSync(recursive: true);
    }

    drop();
    r.log.note(trf('{0}: the folder is missing: git clone {1} {2}', [input.repo, url, folder]));
    final (:code, :stopped, :startFailed) = await cloneInGroup(ctx, git, url, tmp,
        killAfter: killAfter, cancelled: () => r.cancelRequested, onOutput: r.log.add);
    if (startFailed != null) throw JobFailure('clone_failed', trf('git clone could not start: {0}', [startFailed]));
    if (r.cancelRequested) {
      drop();
      r.log.note(tr('clone cancelled; nothing kept'));
      throw _Cancelled();
    }
    if (code != 0 || stopped) {
      drop();
      throw JobFailure('clone_failed', trf('git clone {0} failed ({1})', [url, stopped ? tr('took too long') : trf('exit code {0}', [code])]));
    }
    if (FileSystemEntity.typeSync(folder, followLinks: false) != FileSystemEntityType.notFound) {
      drop();
      throw JobFailure('no_source', trf('{0} appeared while cloning: left as it is', [folder]));
    }
    Directory(tmp).renameSync(folder);
    r.log.note(trf('{0}: cloned into {1}', [input.repo, folder]));
  }

  /// An update of a folder whose configured upstream isn't its GitHub remote (fetched just
  /// before by the caller): HEAD is fast-forwarded to the exact commit of the GitHub branch, only
  /// when the folder is clean, on a branch, and that commit contains HEAD and is ahead - checked
  /// again right before the merge. Otherwise the reason is logged and returned. A configured
  /// upstream on the GitHub remote was followed by the pull (its branch is the user's choice).
  Future<Map<String, dynamic>?> _githubUpdate(_Run r, Input input, String folder, {required bool fetched}) async {
    final slug = ctx.github.slugOf(input);
    if (r.kind != JobKind.update || slug == null) return null;
    final repo = input.repo;
    final g = await ctx.git.inspect(repo, folder);
    final gh = await githubRemote(ctx, folder, slug, upstreamRemote: g.upstreamRemote);
    if (gh == null) {
      final why = trf('no remote of the folder is {0}: GitHub not checked', [githubWebUrl(slug)]);
      r.log.note('$repo: $why');
      return {'repo': repo, 'github': githubWebUrl(slug), 'fastForward': false, 'why': why};
    }
    if (g.upstream != null && gh.name == g.upstreamRemote) return null;
    final ref = '${gh.name}/${githubBranch(ctx.github.facts(slug), g)}';
    String? why;
    if (!fetched) {
      why = trf('fetching {0} failed', [gh.name]);
    } else {
      final c = await ctx.git.compare(folder, ref);
      if (!c.exists) {
        why = trf('{0} does not exist', [ref]);
      } else if (c.relation == Relation.upToDate) {
        why = trf('up to date with {0}', [ref]);
      } else if (c.relation == Relation.ahead) {
        why = trf('the folder is ahead of {0}', [ref]);
      } else if (c.relation == Relation.diverged) {
        why = trf('diverged from {0} ({1} local, {2} there)', [ref, c.ahead, c.behind]);
      } else if (c.relation != Relation.behind) {
        why = trf('could not compare with {0}', [ref]);
      } else {
        // checked again right before the merge: HEAD, branch and a clean tree as compared
        final now = await ctx.git.inspect(repo, folder);
        if (now.branch == null) {
          why = tr('detached HEAD');
        } else if (now.dirty != false) {
          why = tr('uncommitted changes');
        } else if (now.head != g.head || now.branch != g.branch) {
          why = tr('the folder changed while checking');
        } else {
          r.log.note(trf('{0}: git merge --ff-only {1} ({2}, {3} new from GitHub)', [repo, ref, c.commit!.substring(0, 12), c.behind]));
          final m = await ctx.git.mergeFfOnly(folder, c.commit!);
          if (m.stdout.isNotEmpty) r.log.add(utf8.encode(m.stdout));
          if (m.stderr.isNotEmpty) r.log.add(utf8.encode(m.stderr));
          if (!m.ok) throw JobFailure('pull_failed', trf('{0}: git merge --ff-only {1} failed', [repo, ref]));
          return {'repo': repo, 'remote': gh.name, 'ref': ref, 'commit': c.commit, 'fastForward': true, 'new': c.behind};
        }
      }
    }
    r.log.note(trf('{0}: no fast-forward to {1}: {2}', [repo, ref, why]));
    return {'repo': repo, 'remote': gh.name, 'ref': ref, 'fastForward': false, 'why': why};
  }

  /// The release (the tag asked for, else the latest), its tarball downloaded into the cache and
  /// checked against the release's `.sha256` asset: refused when that is missing or differs.
  Future<({Map<String, dynamic> release, String asset, String file, String sha256})> _downloadRelease(_Run r, AppEntry app) async {
    final spec = app.release!;
    final slug = app.mainInput.github;
    if (slug == null) throw JobFailure('no_release', trf('{0} is not on GitHub', [app.name]));
    final tag = (r.job['options'] as Map)['tag'] as String?;
    Map<String, dynamic>? rel;
    try {
      rel = await ctx.github.release(slug, tag: tag);
    } on GitHubError catch (e) {
      throw JobFailure('github_failed', '$slug: ${e.message}');
    } on Object catch (e) {
      throw JobFailure('github_failed', trf('{0}: offline? ({1})', [slug, e]));
    }
    if (rel == null) throw JobFailure('no_release', tag == null ? trf('{0} has no release', [slug]) : trf('{0} has no release {1}', [slug, tag]));
    final relTag = rel['tag'];
    if (relTag is! String || !validTag(relTag)) throw JobFailure('no_release', tr('the release has no usable tag'));
    final asset = spec.asset(tagVersion(relTag));
    final assets = [for (final a in (rel['assets'] as List? ?? const [])) if (a is Map) a];
    final tar = assets.where((a) => a['name'] == asset).firstOrNull;
    final sum = assets.where((a) => a['name'] == '$asset.sha256').firstOrNull;
    if (tar == null || tar['url'] is! String) throw JobFailure('no_asset', trf('release {0} has no {1}', [relTag, asset]));
    if (sum == null || sum['url'] is! String) throw JobFailure('no_checksum', trf('release {0} has no {1}.sha256: not installed', [relTag, asset]));
    r.log.note(trf('release {0} of {1}: {2} ({3} bytes)', [relTag, slug, asset, tar['size'] ?? '?']));
    final dir = p.join(ctx.github.downloads, slug.replaceAll('/', '_'), relTag);
    Directory(dir).createSync(recursive: true);

    Future<void> get(String url, String dest) async {
      final part = '$dest.part';
      try {
        if (File(part).existsSync()) File(part).deleteSync();
        await ctx.github.fetchTo(Uri.parse(url), part, cancelled: () => r.cancelRequested);
      } on Object catch (e) {
        if (File(part).existsSync()) File(part).deleteSync();
        if (r.cancelRequested) throw _Cancelled();
        throw JobFailure('download_failed', '$url: $e');
      }
      if (r.cancelRequested) {
        File(part).deleteSync();
        throw _Cancelled();
      }
      File(part).renameSync(dest);
    }

    final sumFile = p.join(dir, '$asset.sha256');
    await get(sum['url'] as String, sumFile);
    final want = parseSha256File(File(sumFile).readAsStringSync(), asset);
    if (want == null) throw JobFailure('bad_checksum', trf('{0}.sha256 holds no sha256 for {1}: not installed', [asset, asset]));
    final file = p.join(dir, asset);
    if (File(file).existsSync() && await sha256OfFile(file) == want) {
      r.log.note(trf('{0}: already downloaded ({1})', [asset, file]));
    } else {
      r.log.note(trf('downloading {0}', [tar['url']]));
      await get(tar['url'] as String, file);
    }
    final got = await sha256OfFile(file);
    if (got != want) {
      File(file).deleteSync();
      throw JobFailure('checksum_mismatch', trf('{0}: sha256 {1}, its .sha256 says {2}: not installed', [asset, got, want]));
    }
    r.log.note(trf('{0}: sha256 {1} matches {2}.sha256', [asset, got, asset]));
    r.job['release'] = {'tag': relTag, 'asset': asset, 'sha256': got, 'file': file};
    _persist(r.job);
    _checkCancel(r);
    return (release: rel, asset: asset, file: file, sha256: got);
  }

  /// Puts the tarball where the release's installer picks it (the newest matching file in its
  /// dist folder: given an mtime newer than every other match). Returns the undo: a copy placed
  /// here is removed (only while it is still that file), a different file of that name moved aside
  /// is put back (only where the name is free; else both are kept and told), a reused file gets
  /// its mtime back, a dist folder made here is removed when empty. A failure while placing undoes
  /// at once. What was moved aside is in the job's state (`dist`) until it is back.
  Future<void Function()> _placeTarball(_Run r, String folder, ReleaseSpec spec, String file, String asset, String sha) async {
    final dist = p.join(folder, spec.dist);
    final madeDist = !Directory(dist).existsSync();
    Directory(dist).createSync(recursive: true);
    final target = p.join(dist, asset);
    final parts = spec.tarball.split('{version}');
    final pattern = RegExp('^${parts.map(RegExp.escape).join('.*')}\$');
    String? aside;
    DateTime? reusedMtime;
    var placed = false;

    FileSystemEntityType type(String path) => FileSystemEntity.typeSync(path, followLinks: false);
    void undo() {
      try {
        if (placed && type(target) == FileSystemEntityType.file && sha256File(target) == sha) {
          File(target).deleteSync();
        } else if (placed && type(target) != FileSystemEntityType.notFound) {
          r.log.note(trf('{0} was replaced during the install: left as it is', [target]));
        }
        if (aside != null) {
          if (type(target) == FileSystemEntityType.notFound) {
            type(aside) == FileSystemEntityType.link ? Link(aside).renameSync(target) : File(aside).renameSync(target);
            r.job.remove('dist');
            _persist(r.job);
          } else {
            r.log.note(trf('the earlier {0} is kept as {1} ({2} is taken)', [asset, aside, target]));
          }
        }
        if (reusedMtime != null && type(target) == FileSystemEntityType.file) File(target).setLastModifiedSync(reusedMtime);
        if (madeDist && Directory(dist).existsSync() && Directory(dist).listSync().isEmpty) Directory(dist).deleteSync();
      } on FileSystemException catch (e) {
        r.log.note(trf('cleaning up {0}: {1}', [dist, e]));
      }
    }

    try {
      var newest = DateTime.fromMillisecondsSinceEpoch(0);
      for (final e in Directory(dist).listSync(followLinks: false)) {
        if (e.path == target || !pattern.hasMatch(p.basename(e.path))) continue;
        final m = e.statSync().modified;
        if (m.isAfter(newest)) newest = m;
      }
      if (type(target) != FileSystemEntityType.notFound) {
        if (type(target) == FileSystemEntityType.file && await sha256OfFile(target) == sha) {
          reusedMtime = File(target).statSync().modified;
        } else {
          final to = p.join(dist, '.$asset.maprisma-manager-${r.id}');
          r.job['dist'] = {'target': target, 'aside': to};
          _persist(r.job);
          type(target) == FileSystemEntityType.link ? Link(target).renameSync(to) : File(target).renameSync(to);
          aside = to;
          r.log.note(trf('a different {0} in {1}/ was moved aside to {2} for the install', [asset, spec.dist, to]));
        }
      }
      if (reusedMtime == null) {
        final tmp = p.join(dist, '.$asset.maprisma-manager-${r.id}.part');
        File(file).copySync(tmp);
        File(tmp).renameSync(target);
        placed = true;
      }
      final now = DateTime.now();
      final stamp = newest.add(const Duration(seconds: 1)).isAfter(now) ? newest.add(const Duration(seconds: 1)) : now;
      File(target).setLastModifiedSync(stamp);
    } on Object {
      undo();
      rethrow;
    }
    r.log.note(trf('{0} {1} (the newest in {2}/)', [placed ? tr('placed') : tr('using'), target, spec.dist]));
    return undo;
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
    final snap = await BarSnapshot.read(ctx, ctx.processes());
    final st = snap.stateOf(app);
    if (st['state'] != 'in' && st['state'] != 'out') return;
    final area = parseArea(st['zone']);
    // Its exact place too (COSMIC: index within the area and the panel instance; KDE: index within
    // the widget's zone and the widget), so putting it back gives the same order.
    int? index;
    String? panel;
    Map<String, Object>? kdeTarget;
    if (ctx.desktop == DesktopId.kde && st['state'] == 'in' && app.bar.kdeId != null && snap.widget != null) {
      final at = snap.bar.kdeShown(snap.widget!, snap.procs).find(app.bar.kdeId!);
      if (at != null) {
        index = at.index;
        kdeTarget = {'widget': snap.widget!.widget};
      }
    }
    if (ctx.desktop == DesktopId.hyprland && st['state'] == 'in') {
      if (st['group'] == true) {
        kdeTarget = {'group': true}; // in the bar's tray group: back there, no place of its own
      } else {
        final id = hyprBarId(app);
        final f = MaprismaBarFile.read(paths);
        final at = id == null ? null : snap.bar.hyprShown(f, snap.procs, group: false).find(id);
        if (at != null) index = at.index;
      }
    }
    if (ctx.desktop == DesktopId.cosmic && st['state'] == 'in' && app.bar.cosmicApplet != null) {
      for (final i in cosmicInstances(paths)) {
        final at = CosmicPanelConfig.read(paths, i).layout.find(app.bar.cosmicApplet!);
        if (at != null) {
          index = at.index;
          panel = i;
          break;
        }
      }
    }
    await withStateLock(paths, () async {
      final wanted = WantedBar.load(paths);
      if (wanted.of(ctx.desktop, app.id) != null) return;
      wanted.set(ctx.desktop, app.id, placed: st['state'] == 'in', area: area, index: index,
          target: kdeTarget ?? (panel == null || panel == _mainPanel() ? null : {'panel': panel}));
      wanted.save(paths);
    });
    r.log.note('${trf('bar state recorded {0}: ', [r.kind == JobKind.remove ? tr('before the remove (a later install puts it back there)') : tr('before the install')])}'
        '${st['state']}${area == null ? '' : ' (${area.name}${index == null ? '' : ' #$index'}${panel == null ? '' : ', $panel'})'}');
  }

  String _mainPanel() {
    final instances = cosmicInstances(paths);
    return instances.contains('Panel') ? 'Panel' : instances.first;
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

  /// `pub get` with the Manager's Flutter in every package of [folder] whose package cache
  /// points at another or a missing Flutter (or at package folders that are gone): the build
  /// would fail on it and not fetch again by itself. A failed fetch is only noted; the build
  /// then tells what is wrong.
  Future<void> _refreshPackages(_Run r, Component c, String folder) async {
    final flutter = ctx.flutter().exe;
    if (flutter == null) return;
    final root = flutterRootOf(flutter);
    final dart = p.join(p.dirname(flutter), 'dart');
    for (final dir in dartPackages(folder)) {
      if (isWorkspaceMember(dir)) continue;
      final why = stalePackageCache(dir, root);
      if (why == null) continue;
      _checkCancel(r);
      final rel = dir == folder ? '.' : p.relative(dir, from: folder);
      final exe = usesFlutter(dir) || !File(dart).existsSync() ? flutter : dart;
      r.log.note(trf('{0}: the package cache doesn\'t fit ({1}); {2} pub get', [rel, why, p.basename(exe)]));
      final setsid = ctx.runner.which('setsid') ?? '/usr/bin/setsid';
      final Process proc;
      try {
        proc = await Process.start(setsid, [exe, 'pub', 'get'],
            workingDirectory: dir, environment: scriptEnv(c, job: r.id), includeParentEnvironment: false);
      } on ProcessException catch (e) {
        r.log.note(trf('{0}: pub get could not start: {1}', [rel, e.message]));
        continue;
      }
      unawaited(proc.stdin.close().catchError((_) {}));
      final outDone = proc.stdout.listen(r.log.add).asFuture<void>().catchError((_) {});
      final errDone = proc.stderr.listen(r.log.add).asFuture<void>().catchError((_) {});
      int? code;
      unawaited(proc.exitCode.then((v) => code = v));
      final end = DateTime.now().add(const Duration(minutes: 5));
      while (code == null) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        if (code != null) break;
        if (r.cancelRequested || DateTime.now().isAfter(end)) {
          // setsid execs pub: its pid is the group's
          await Process.run('kill', ['-KILL', '--', '-${proc.pid}']).catchError((_) => ProcessResult(0, 1, '', ''));
          proc.kill(ProcessSignal.sigkill);
          await proc.exitCode;
          break;
        }
      }
      await Future.wait([outDone, errDone]).timeout(const Duration(seconds: 2), onTimeout: () => []);
      _checkCancel(r);
      r.log.note(code == 0 ? trf('{0}: pub get ok', [rel]) : trf('{0}: pub get failed ({1})', [rel, '${code ?? tr('no answer in time')}']));
    }
  }

  /// Runs [c]'s install command (or [argv] in [cwd] with [extraEnv]) as the job's script.
  Future<void> _runScript(_Run r, Component c, {List<String>? argv, String? cwd, Map<String, String> extraEnv = const {}}) async {
    if (!r.committed) {
      _phase(r, 'build', component: c);
    } else {
      r.component = c;
      r.job['component'] = c.id;
      _persist(r.job);
    }
    _checkCancel(r);
    final folder = cwd ?? ctx.repoFolder(c.repo);
    final setsid = ctx.runner.which('setsid') ?? '/usr/bin/setsid';
    final options = r.job['options'] as Map? ?? const {};
    argv ??= [...c.install, for (final f in c.flags.entries) if (options[f.key] == true) f.value];
    if (!r.committed && cwd == null) await _refreshPackages(r, c, folder);
    r.log.note(trf('\$ {0}   (in {1})', [argv.join(' '), folder]));
    r.recent.clear();
    final Process proc;
    try {
      proc = await Process.start(setsid, argv,
          workingDirectory: folder, environment: {...scriptEnv(c, job: r.id), ...extraEnv}, includeParentEnvironment: false);
    } on ProcessException catch (e) {
      throw JobFailure('script_failed', trf('could not start {0}: {1}', [argv.first, e.message]));
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
    if (r.pgid == null) r.log.note(tr('the script\'s process group is unknown: it can\'t be cancelled'));
    r.job['script'] = {'pid': proc.pid, 'pgid': r.pgid, 'start': r.scriptStart, 'component': c.id};
    _persist(r.job);
    void out(List<int> d) {
      r.log.add(d);
      r.remember(d);
    }

    final outDone = proc.stdout.listen(out).asFuture<void>();
    final errDone = proc.stderr.listen(out).asFuture<void>();
    // A cancel that came while the script was being started.
    if (r.cancelRequested && r.pgid != null) {
      try {
        await _cancelScript(r);
      } on RouteError catch (e) {
        r.log.note(trf('cancel came too late: {0}', [e.message]));
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
      r.log.note(tr('a child of the script still holds its output; not waited for'));
    }
    if (!r.committed) {
      final changed = firstChanged(r.signatures);
      if (changed != null) await _enterCommit(r, changed, scriptEnded: true);
    }
    r.log.note(trf('exit code {0}', [code]));
    if (r.cancelRequested) {
      if (r.committed) throw JobFailure('cancelled', tr('cancelled, but the script had started writing: repair (reinstall)'));
      throw _Cancelled();
    }
    if (code != 0 && !r.committed && c.busyMarker != null && r.recent.toString().contains(c.busyMarker!)) {
      throw JobFailure('app_busy',
          trf('{0} {1}: let it finish (or close it) and try again{2}; nothing was changed', [c.name, c.busyMarker, c.flags.containsKey('force') ? tr(', or choose "force" (it is ended)') : '']));
    }
    if (code != 0) throw JobFailure('script_failed', trf('{0} exited with {1}', [argv.join(' '), code]));
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
        r.log.note(trf('cancel: KILL to what is left of the process group {0}', [pg]));
      }
      if (now.isAfter(giveUp)) {
        r.log.note(trf('members of the process group {0} are still running', [pg]));
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  /// The commit boundary: from here the job isn't cancellable. The script is paused while the
  /// app's units and processes are stopped (where it doesn't do that itself). One transition per
  /// job: callers await [_Run.committing].
  Future<void> _enterCommit(_Run r, String changed, {bool scriptEnded = false, bool paused = false, String? why}) {
    if (r.committing != null) return r.committing!;
    if (r.committed) return Future.value();
    r.committed = true;
    r.job['committed'] = true;
    r.job['phase'] = 'commit';
    _persist(r.job);
    r.log.note(trf('phase: commit ({0}; not cancellable from here)', [why ?? trf('{0} changed', [changed])]));
    Future<void> body() async {
      final c = r.component;
      if (c != null && c.stopsOwnProcesses) {
        r.log.note(trf('the installer stops {0}\'s processes itself', [r.app.name]));
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
      r.log.note(trf('systemctl --user stop {0}', [u.name]));
      final s = await ctx.runner.run(['systemctl', '--user', 'stop', u.name], timeout: const Duration(seconds: 60));
      if (!s.ok) r.log.note(trf('stopping {0} failed: {1}', [u.name, s.stderr.trim()]));
      (r.job['units'] ??= <String>[]).add(u.name);
    }
    final procs = [
      for (final (pr, _) in matchingProcesses(app, paths, ctx.processes()))
        if (pr.pid != pid && (r.pgid == null || procStat(pr.pid, procRoot: paths.proc)?.pgrp != r.pgid)) pr,
    ];
    if (procs.isEmpty) return;
    r.log.note(trf('stopping {0} process(es) of {1}: {2}', [procs.length, app.name, procs.map((pr) => pr.pid).join(', ')]));
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
        r.log.note(trf('post step "{0}": not run by this version', [step]));
        continue;
      }
      if (ctx.runner.which(argv.first) == null) {
        r.log.note(trf('{0} not found: skipped', [argv.first]));
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
    if (ctx.desktop == DesktopId.other || app.bar.none) return {'note': tr('no bar icon here')};
    try {
      final applied = await (Bar(ctx)..follow = follow).applyWanted();
      out['applied'] = applied['changed'];
      r.log.note(trf('bar state from bar.json applied ({0})', [(applied['changed'] as List).isEmpty ? tr('nothing to change') : (applied['changed'] as List).join(', ')]));
    } on RouteError catch (e) {
      out['error'] = '${e.code}: ${e.message}';
      r.log.note(trf('bar state not applied: {0} {1}', [e.code, e.message ?? '']));
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
        r.log.note(trf('ended the old applet ({0})', [old.map((pr) => pr.pid).join(', ')]));
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
          r.log.note(tr('the applet runs again'));
        } else {
          // Never a restart of cosmic-panel: cosmic-session starts a killed panel again with a
          // delay that doubles with every restart (65 s after a dozen, seen 2026-11-09).
          r.log.note(tr('the applet did not start again: its panel file is written without it and back (the panel rebuilds)'));
          Map<String, dynamic> f;
          try {
            f = await _nudgeApplet(app.bar.cosmicApplet!);
          } on RouteError catch (e) {
            f = {'error': '${e.code}: ${e.message}'};
          }
          out['panel'] = f;
          final back = DateTime.now().add(appletWait * 3);
          while (!running() && DateTime.now().isBefore(back)) {
            await Future<void>.delayed(const Duration(milliseconds: 250));
          }
          out['applet_running'] = running();
          r.log.note(running() ? tr('the panel started the applet again') : trf('the applet is still not running{0}', [f['error'] == null ? '' : ' (${f['error']})']));
        }
      }
    }
    if (traysDesktop(ctx.desktop) && app.bar.kdeTrayExe != null && app.bar.kdeAutostart != null) {
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
        r.log.note(ok ? tr('tray started') : tr('the tray could not be started'));
      } else if (!shown) {
        out['trayStopped'] = stop.length;
        if (stop.isNotEmpty) r.log.note(tr('tray kept stopped (not in the bar)'));
      }
    }
    return out;
  }

  /// Has cosmic-panel start an applet again that it didn't restart (an ended applet stays gone):
  /// the panel file that lists it is written once without it and then back with its exact bytes,
  /// under the state lock; the panel rebuilds after each write (cosmic-panel 1.11, step 2) and
  /// the panel process keeps running. A concurrent change between the writes is never
  /// overwritten (then the wanted state is applied instead). Needs the user's file (a panel on its
  /// system default isn't written for this).
  Future<Map<String, dynamic>> _nudgeApplet(String id) async {
    // never a kill of the panel here: no reaction is only reported
    final follow = this.follow ?? (b) => followPanel(ctx.processes, b, kill: (_) => false);
    final r = await withStateLock(paths, () async {
      for (final instance in cosmicInstances(paths)) {
        final c = CosmicPanelConfig.read(paths, instance);
        final at = c.error == null ? c.layout.find(id) : null;
        if (at == null) continue;
        final file = at.area == Area.center ? c.center : c.wings;
        final original = file.userText;
        if (original == null) return {'panel': instance, 'error': tr('the panel uses its system default: not written')};
        final l = c.layout.copy()..remove(id);
        final before = ctx.processes();
        await writeCosmic(paths, c, l);
        final out = await follow(before);
        final c2 = CosmicPanelConfig.read(paths, instance);
        final file2 = at.area == Area.center ? c2.center : c2.wings;
        if (c2.error != null || c2.layout.find(id) != null || !c2.layout.sameAs(l)) {
          return {'panel': instance, 'out': out, 'error': tr('the panel file changed meanwhile'), 'apply': true};
        }
        final before2 = ctx.processes();
        if (file2.userText != (at.area == Area.center ? c.render(l).center : c.render(l).wings)) {
          return {'panel': instance, 'out': out, 'error': tr('the panel file changed meanwhile'), 'apply': true};
        }
        atomicWrite(file.userPath, original);
        final back = await follow(before2);
        return {'panel': instance, 'file': file.name, 'out': out, 'back': back};
      }
      return {'error': tr('not in a panel')};
    });
    if (r['apply'] == true) await (Bar(ctx)..follow = follow).applyWanted();
    return r;
  }

  bool _exclusive = false;

  /// Runs [f] holding the jobs' lock (no job of this or another Manager runs meanwhile, none
  /// starts): `busy` when a job runs. Bar icon changes (icons.dart).
  Future<T> exclusive<T>(Future<T> Function() f) async {
    if (_exclusive || _lock != null || _pumping) throw RouteError('busy', tr('a job runs: try again when it has ended'));
    _acquire();
    _exclusive = true;
    try {
      return await f();
    } finally {
      _exclusive = false;
      if (!_pumping && _queue.isEmpty) _release();
    }
  }

  /// [_nudgeApplet] for the bar icon change (icons.dart).
  Future<Map<String, dynamic>> nudgeApplet(String id) => _nudgeApplet(id);

  /// A job for [app] that hasn't ended (in this process or another Manager).
  bool activeFor(String app) =>
      _runs.values.any((r) => r.job['app'] == app && r.job['finished'] != true) ||
      loadJobs(paths).any((j) => j['app'] == app && j['finished'] != true);

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
      throw JobFailure('changed', tr('what would be removed changed since the plan was shown'));
    }
    final dependents = plan.json['dependents'] as List;
    if (dependents.isNotEmpty && options['dependents_ok'] != true) {
      throw JobFailure('needed_by', trf('needed by {0}', [dependents.map((d) => d['name']).join(', ')]));
    }
    if (plan.blocked != null) throw JobFailure('blocked', plan.blocked!);
    for (final s in (plan.json['stays'] as List).cast<Map<String, dynamic>>()) {
      r.log.note(trf('stays: {0} ({1})', [s['path'], s['why']]));
    }
    _checkCancel(r);

    _phase(r, 'commit');
    final barId = switch (ctx.desktop) {
      DesktopId.cosmic => app.bar.cosmicApplet,
      DesktopId.kde => app.bar.kdeId,
      DesktopId.hyprland => hyprBarId(app),
      DesktopId.other => null,
    };
    if (barId != null) {
      // where it is now goes to bar.json first (when the user never placed it through the Manager)
      try {
        await _seedWantedBar(r);
      } on Object catch (e) {
        r.log.note(trf('bar state not recorded: {0}', [e]));
      }
      try {
        await (Bar(ctx)..follow = follow).remove({'app': app.id}, remember: false, autostart: false);
        r.log.note(tr('bar icon taken out'));
      } on RouteError catch (e) {
        throw JobFailure('bar_failed', trf('the bar icon could not be taken out ({0}: {1}); nothing was removed', [e.code, e.message]));
      }
    }
    r.committed = true;
    r.job['committed'] = true;
    await _stopApp(r);
    final steps = plan.recipe?.steps ?? const <RecipeStep>[];
    try {
      await runRecipe(ctx, steps, StepWhen.before, r.log.note);
    } on RecipeFailure catch (f) {
      throw JobFailure('step_failed', trf('{0}: {1}; no file was deleted', [f.step, f.message]));
    }

    final deleted = <String>[], kept = <Map<String, dynamic>>[];
    final reach = sharedRoots(paths);
    // The owned folders: each file/link checked again right before it goes; then the folders
    // that are empty, deepest first.
    var treeFiles = 0;
    for (final t in plan.trees) {
      for (final g in t.goes) {
        final unsafe = unsafeReach(g.path, reach);
        if (unsafe != null) {
          kept.add({'path': g.path, 'why': unsafe});
          continue;
        }
        final now = pathState(g.path);
        if (now['exists'] != true) continue;
        if (g.sha256 != null && now['type'] == 'file' && now['sha256'] == g.sha256) {
          File(g.path).deleteSync();
        } else if (g.link != null && now['type'] == 'link' && now['link'] == g.link) {
          Link(g.path).deleteSync();
        } else {
          kept.add({'path': g.path, 'why': tr('changed while removing')});
          continue;
        }
        treeFiles++;
      }
      for (final d in t.dirs) {
        if (unsafeReach(d, reach) == null) _removeIfEmpty(d);
      }
      final gone = FileSystemEntity.typeSync(t.root, followLinks: false) == FileSystemEntityType.notFound;
      r.log.note(trf('{0} {1} ({2} files and links{3})', [gone ? tr('removed') : tr('emptied'), t.root, t.goes.length, gone ? '' : tr('; what stays is listed')]));
      if (gone) deleted.add(t.root);
    }
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
        kept.add({'path': path, 'why': tr('changed while removing')});
        continue;
      }
      deleted.add(path);
      r.log.note(trf('removed {0}', [path]));
    }
    final dirs = plan.goes.where((g) => g['kind'] == 'dir').map((g) => g['path'] as String).toList()
      ..sort((a, b) => p.split(b).length.compareTo(p.split(a).length));
    for (final d in dirs) {
      if (_removeIfEmpty(d)) deleted.add(d);
    }
    for (final path in [...deleted]) {
      _pruneParents(p.dirname(path));
    }
    await runRecipe(ctx, steps, StepWhen.after, r.log.note);
    final displaced = Displaced.load(paths, app.id);
    final restored = <String>[];
    for (final planned in plan.restores) {
      final e = displaced.of(planned['path'] as String);
      if (e == null || e['restore'] != true || unsafeReach(e['path'] as String, reach) != null) continue;
      if (displaced.restoreEntry(e)) {
        restored.add(e['path'] as String);
        r.log.note(trf('restored {0} (it was there before the Manager installed {1})', [e['path'], app.name]));
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
      r.log.note(trf('deleted settings {0}', [path]));
    }

    _phase(r, 'verify');
    final still = [for (final path in deleted) if (!restored.contains(path) && FileSystemEntity.typeSync(path, followLinks: false) != FileSystemEntityType.notFound) path];
    if (still.isNotEmpty) throw JobFailure('verify_failed', trf('still there: {0}', [still.join(', ')]));

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
    r.log.note(trf('receipt dropped{0}', [keptNow.isEmpty ? '' : trf('; {0} kept path(s) recorded', [keptNow.length])]));
    return {
      'deleted': deleted,
      if (treeFiles > 0) 'treeFiles': treeFiles,
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

/// A release tag that can be a folder name and a URL segment.
bool validTag(String tag) => RegExp(r'^[A-Za-z0-9][A-Za-z0-9._+-]{0,99}$').hasMatch(tag) && !tag.contains('..');

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
  if (orphan && script is Map && script['pgid'] is int && paths.proc == '/proc') {
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
      'message': trf('the Manager that ran it ended in the {0} phase{1}', [job['phase'], orphan ? trf('; {0} still runs (pid {1})', [job['pkexec'] != null ? 'pkexec/pacman' : tr('its script'), ((job['pkexec'] ?? script) as Map)['pid']]) : '']),
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
  // pkexec (or the pacman it became, the same pid): waited for, never signalled
  final pk = job['pkexec'];
  if (pk is Map && pk['pid'] is int && pk['start'] is int && sameProcess(pk['pid'] as int, pk['start'] as int)) return true;
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

/// `git clone <url> <tmp>` in its own session and process group (setsid), so that a cancel or the
/// deadline ends git and every helper it started (HTTPS/SSH), and what is left of the group ends
/// before the caller cleans [tmp] up. [cancelled] is asked every 50 ms; output goes to [onOutput].
Future<({int code, bool stopped, String? startFailed})> cloneInGroup(
  Ctx ctx,
  String git,
  String url,
  String tmp, {
  required Duration killAfter,
  bool Function()? cancelled,
  void Function(List<int>)? onOutput,
  Duration deadlineAfter = const Duration(minutes: 30),
}) async {
  final Process proc;
  try {
    proc = await Process.start(ctx.runner.which('setsid') ?? '/usr/bin/setsid', [git, '-c', 'core.fsmonitor=false', 'clone', '--no-progress', '--', url, tmp],
        environment: {...ctx.environment, ...Git.cloneEnv}, includeParentEnvironment: false, workingDirectory: p.dirname(tmp));
  } on ProcessException catch (e) {
    return (code: -1, stopped: false, startFailed: e.message);
  }
  final start = procStat(proc.pid)?.start;
  await proc.stdin.close();
  final outDone = proc.stdout.listen(onOutput ?? (_) {}).asFuture<void>();
  final errDone = proc.stderr.listen(onOutput ?? (_) {}).asFuture<void>();
  // Our own child's group (pgid = its pid once setsid ran): signalled only while it is that one.
  final real = Signaller();
  bool group(int sig) => (sameProcess(proc.pid, start) || groupMembers(proc.pid).isNotEmpty) && real.group(proc.pid, sig);
  var stopped = false;
  DateTime? killAt;
  final deadline = DateTime.now().add(deadlineAfter);
  final timer = Timer.periodic(const Duration(milliseconds: 50), (_) {
    if (!stopped && ((cancelled?.call() ?? false) || DateTime.now().isAfter(deadline))) {
      stopped = true;
      killAt = DateTime.now().add(killAfter);
      if (!group(sigTerm)) proc.kill(ProcessSignal.sigterm);
    } else if (killAt != null && DateTime.now().isAfter(killAt!)) {
      killAt = null;
      if (!group(sigKill)) proc.kill(ProcessSignal.sigkill);
    }
  });
  final code = await proc.exitCode;
  // what is left of the group (a helper that outlived git) ends before the folder is cleaned up
  if (stopped || code != 0) {
    final until = DateTime.now().add(killAfter + const Duration(seconds: 3));
    var killed = false;
    while (groupMembers(proc.pid).isNotEmpty && DateTime.now().isBefore(until)) {
      if (!killed && (killAt == null || DateTime.now().isAfter(killAt!))) {
        killed = group(sigKill);
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }
  timer.cancel();
  try {
    await Future.wait([outDone, errDone]).timeout(const Duration(seconds: 2));
  } on TimeoutException {
    // a helper still holds the output
  }
  return (code: code, stopped: stopped, startFailed: null);
}
