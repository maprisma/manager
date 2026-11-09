// The Manager updates itself (plan: "Self-update", docs/protocol.md "Self-update").
//
// A running Flutter app maps its code from its bundle, so the Manager never replaces the bundle it
// runs from. The job builds into a stage (`tools/install-local --stage <dir>`: the bundle, the
// install script, the helper and the packaging files), checks it (the files a bundle needs, no
// missing libraries, the new core answers `version`), copies the helper to
// `~/.local/state/maprisma-manager/self-update/helper` and starts it detached (`setsid`). The helper
// waits until every running Manager window has quit, swaps the bundle in (the old one kept aside),
// writes the links, desktop entry and icon (`install-local --integrate` from the stage), starts the
// new Manager and waits for its ready file (written after its first frame); no ready file within
// the timeout (20 s) → the new one is ended, the old bundle and files come back and the old Manager
// is started again. It reports through `<job>.status` and, when the job ended before the swap (a
// Manager window was waiting for it), through `maprisma-manager-core self-update-done <job>` of
// whichever core is installed then, which writes the receipt or marks the job failed.
part of 'jobs.dart';

/// Where the self-update keeps its stage, helper, status and log files.
String selfUpdateDir(Paths paths) => p.join(paths.managerState, 'self-update');

/// The helper's status line: `waiting|swapping|starting <pid>`, then `done`, `rolled back: …`,
/// `failed: …` or `aborted: …`.
({String state, int? pid, String? why}) readSelfStatus(String file) {
  String text;
  try {
    text = File(file).readAsStringSync().trim();
  } on FileSystemException {
    return (state: 'missing', pid: null, why: null);
  }
  final colon = text.indexOf(':');
  final head = colon < 0 ? text : text.substring(0, colon);
  final why = colon < 0 ? null : text.substring(colon + 1).trim();
  final parts = head.split(' ');
  if (parts.length == 2 && int.tryParse(parts[1]) != null && ['waiting', 'swapping', 'starting'].contains(parts[0])) {
    return (state: parts[0], pid: int.parse(parts[1]), why: why);
  }
  return (state: head.trim(), pid: null, why: why);
}

/// A helper of an earlier self-update that hasn't finished (its pid still runs).
({String job, int pid})? pendingSelfUpdate(Paths paths) {
  final dir = Directory(selfUpdateDir(paths));
  if (!dir.existsSync()) return null;
  for (final e in dir.listSync()) {
    if (e is! File || !e.path.endsWith('.status')) continue;
    final s = readSelfStatus(e.path);
    if (s.pid != null && procStat(s.pid!) != null && !(procStat(s.pid!)!.zombie)) {
      return (job: p.basenameWithoutExtension(e.path), pid: s.pid!);
    }
  }
  return null;
}

/// What a stage needs (relative to the stage folder) before the helper may swap it in.
const _stageFiles = {
  'bundle/maprisma-manager': true,
  'bundle/lib/libapp.so': false,
  'bundle/lib/libflutter_linux_gtk.so': false,
  'bundle/data/icudtl.dat': false,
  'bundle/data/flutter_assets/version.json': false,
  'bundle/bin/maprisma-manager-core': true,
  'tools/install-local': true,
  'tools/self-update': true,
  'packaging/com.maprisma.Manager.desktop': false,
  'packaging/com.maprisma.Manager.svg': false,
};

extension _SelfUpdate on JobEngine {
  Future<Map<String, dynamic>> _installSelf(_Run r) async {
    final app = r.app;
    final c = app.components.single;
    final prep = await _prepareInputs(r, [c], release: false);
    if (prep.upToDate) return {'up_to_date': true};
    final pending = pendingSelfUpdate(paths);
    if (pending != null) throw JobFailure('busy', 'the self-update ${pending.job} is still being put in place (helper pid ${pending.pid})');
    final dir = selfUpdateDir(paths);
    final stage = p.join(dir, r.id);
    if (FileSystemEntity.typeSync(stage, followLinks: false) != FileSystemEntityType.notFound) Directory(stage).deleteSync(recursive: true);
    Directory(dir).createSync(recursive: true);
    r.job['selfUpdate'] = {'stage': stage, 'state': 'building'};
    _persist(r.job);

    // build (cancellable): nothing of the installed Manager is touched
    await _runScript(r, c, argv: [...c.install, '--stage', stage]);
    _checkCancel(r);

    // the stage checked
    final problems = <String>[];
    for (final e in _stageFiles.entries) {
      final f = p.join(stage, e.key);
      if (FileSystemEntity.typeSync(f) != FileSystemEntityType.file) {
        problems.add('${e.key} missing');
      } else if (e.value && !isExecutableFile(f)) {
        problems.add('${e.key} not executable');
      }
    }
    String? newVersion;
    if (problems.isEmpty) {
      try {
        final v = jsonDecode(File(p.join(stage, 'bundle/data/flutter_assets/version.json')).readAsStringSync());
        newVersion = v is Map && v['version'] is String ? v['version'] as String : null;
      } on Object {
        newVersion = null;
      }
      if (newVersion == null) problems.add('version.json has no version');
      final ldd = ctx.runner.which('ldd');
      if (ldd != null) {
        final l = await ctx.runner.run([ldd, p.join(stage, 'bundle/maprisma-manager')], timeout: const Duration(seconds: 20));
        final missing = [for (final line in l.stdout.split('\n')) if (line.contains('not found')) line.trim()];
        if (missing.isNotEmpty) problems.add('missing libraries: ${missing.join(', ')}');
      }
      final core = await ctx.runner.run([p.join(stage, 'bundle/bin/maprisma-manager-core'), 'version'], timeout: const Duration(seconds: 20));
      if (!core.ok || !core.stdout.startsWith('maprisma-manager-core ')) {
        problems.add('the new core doesn\'t answer `version` (${core.ok ? core.stdout.trim() : core.stderr.trim()})');
      } else {
        r.log.note('the new core: ${core.stdout.trim()}');
      }
    }
    if (problems.isNotEmpty) {
      for (final pr in problems) {
        r.log.note('stage: $pr');
      }
      _dropStage(stage);
      throw JobFailure('bad_stage', 'the new build isn\'t complete: ${problems.first}');
    }
    r.log.note('stage checked: Maprisma Manager $newVersion in $stage');

    // the Manager windows the helper waits for (this one, when the job runs in the app)
    // As written and as /proc reports it (a symlinked HOME or ~/.local/lib).
    final gui = p.join(paths.lib, 'maprisma-manager', 'maprisma-manager');
    final guis = {gui, p.join(_canonical(p.dirname(gui)), 'maprisma-manager')};
    final waitFor = [
      for (final pr in ctx.processes())
        if (guis.contains(pr.exe) && (ctx.uid == null || pr.uid == ctx.uid) && pr.startTicks != null) {'pid': pr.pid, 'start': pr.startTicks},
    ];
    final restart = waitFor.isNotEmpty;

    // commit: from here the helper owns it
    await _enterCommit(r, '', scriptEnded: true, why: 'the self-update helper takes over');
    final helper = p.join(dir, 'helper');
    final tmp = '$helper.${r.id}.tmp';
    File(p.join(stage, 'tools/self-update')).copySync(tmp);
    await ctx.runner.run(['chmod', '755', tmp], timeout: const Duration(seconds: 5));
    File(tmp).renameSync(helper);
    final statusFile = p.join(dir, '${r.id}.status');
    final helperLog = p.join(dir, '${r.id}.log');
    for (final f in [statusFile, p.join(dir, '${r.id}.ready')]) {
      if (File(f).existsSync()) File(f).deleteSync();
    }
    final args = [
      helper,
      '--job', r.id,
      '--stage', stage,
      '--lib', p.join(paths.lib, 'maprisma-manager'),
      '--state', dir,
      '--proc', paths.proc,
      for (final w in waitFor) ...['--wait', '${w['pid']}:${w['start']}'],
      '--restart', restart ? '1' : '0',
      '--ready-timeout', '${selfReadyTimeout.inSeconds}',
      '--wait-timeout', '${selfQuitTimeout.inSeconds}',
    ];
    final env = scriptEnv(c)..remove('MAPRISMA_MANAGER_JOB');
    r.job['selfUpdate'] = {
      'stage': stage,
      'state': 'waiting',
      'status': statusFile,
      'log': helperLog,
      'restart': restart,
      'waitFor': waitFor,
      'version': newVersion,
      'inputs': prep.inputs,
      if (prep.notes.isNotEmpty) 'sources': prep.notes,
    };
    _persist(r.job);
    r.log.note('\$ setsid ${args.join(' ')}');
    try {
      await Process.start(ctx.runner.which('setsid') ?? '/usr/bin/setsid', args,
          mode: ProcessStartMode.detached, environment: env, includeParentEnvironment: false, workingDirectory: paths.home);
    } on ProcessException catch (e) {
      _dropStage(stage);
      throw JobFailure('script_failed', 'the self-update helper didn\'t start: ${e.message}');
    }
    r.log.note('the helper logs to $helperLog');

    if (restart) {
      r.log.note('the helper waits for the Manager (pid ${waitFor.map((w) => w['pid']).join(', ')}) to quit, '
          'swaps the new build in and starts it; without a ready signal in ${selfReadyTimeout.inSeconds} s the old one comes back');
      return {
        'restart': true,
        'selfUpdate': {'state': 'waiting', 'version': newVersion, 'log': helperLog, 'waitFor': [for (final w in waitFor) w['pid']]},
        if (prep.notes.isNotEmpty) 'sources': prep.notes,
      };
    }

    // No Manager window: the helper swaps at once; this job waits for it and finishes itself.
    final until = DateTime.now().add(selfQuitTimeout + selfReadyTimeout + const Duration(seconds: 60));
    ({String state, int? pid, String? why}) s;
    while (true) {
      s = readSelfStatus(statusFile);
      if (s.pid == null && s.state != 'missing') break;
      if (DateTime.now().isAfter(until)) throw JobFailure('self_update_failed', 'the helper didn\'t finish (see $helperLog)');
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    _copyHelperLog(r, helperLog);
    if (s.state != 'done') {
      throw JobFailure('self_update_failed', '${s.state}${s.why == null ? '' : ': ${s.why}'}');
    }
    _phase(r, 'verify');
    final failing = [for (final ip in c.paths) checkPath(paths, ip)].where((ch) => ch['ok'] != true).toList();
    if (failing.isNotEmpty) {
      for (final f in failing) {
        r.log.note('postcondition: ${f['path']}: ${f['problem']}');
      }
      throw JobFailure('verify_failed', '${failing.length} path(s) not as the installer leaves them');
    }
    _phase(r, 'finish');
    _writeSelfReceipt(app, c, prep.inputs, r.id, r.kind.name, paths: paths);
    r.log.note('receipt written');
    r.job['selfUpdate'] = {...(r.job['selfUpdate'] as Map), 'state': 'done'};
    return {
      'selfUpdate': {'state': 'done', 'version': newVersion, 'log': helperLog},
      if (prep.notes.isNotEmpty) 'sources': prep.notes,
      'receipt': p.join(paths.receipts, '${app.id}.json'),
    };
  }

  void _copyHelperLog(_Run r, String helperLog) {
    try {
      for (final line in File(helperLog).readAsLinesSync()) {
        r.log.note('helper: $line');
      }
    } on FileSystemException {
      r.log.note('the helper wrote no log');
    }
  }
}

String _canonical(String dir) {
  try {
    return Directory(dir).resolveSymbolicLinksSync();
  } on FileSystemException {
    // not there yet: its parent may be a link
    final parent = p.dirname(dir);
    if (parent == dir) return dir;
    return p.join(_canonical(parent), p.basename(dir));
  }
}

void _dropStage(String stage) {
  try {
    Directory(stage).deleteSync(recursive: true);
  } on FileSystemException {
    // gone
  }
}

/// The Manager's receipt as it is installed now (after the helper swapped the build in).
void _writeSelfReceipt(AppEntry app, Component c, List inputs, String job, String kind, {required Paths paths}) {
  final norm = normalizedPaths(paths, app);
  final trees = <Map<String, dynamic>>[
    for (final t in c.trees)
      ?treeManifest(paths.expand(t.path)),
  ];
  String? version;
  try {
    final v = jsonDecode(File(paths.expand(app.version.installedJson!)).readAsStringSync());
    version = v is Map && v['version'] is String ? v['version'] as String : null;
  } on Object {
    version = null;
  }
  final receiptJson = <String, dynamic>{
    'schema': 1,
    'id': app.id,
    'at': DateTime.now().toUtc().toIso8601String(),
    'version': ?version,
    'manager': coreVersion,
    'job': job,
    'kind': kind,
    'components': [c.id],
    'source': {'kind': 'folder'},
    'inputs': inputs,
    'paths': [
      for (final (_, path) in catalogPaths(paths, [c]))
        if (pathState(path, normalized: norm.contains(path) ? normalizedHidden : null) case final st when st['exists'] == true)
          switch (st['type']) {
            'file' => {'path': path, 'sha256': st['sha256'], 'mode': st['mode']},
            'link' => {'path': path, 'link': st['link']},
            _ => {'path': path, 'dir': true},
          },
    ],
    'displaced': const [],
    if (trees.isNotEmpty) 'trees': trees,
  };
  Receipt.parse(app.id, jsonDecode(jsonEncode(receiptJson))); // never write one the reader refuses
  atomicWrite(p.join(paths.receipts, '${app.id}.json'), const JsonEncoder.withIndent('  ').convert(receiptJson));
  final kept = File(keptFile(paths, app.id));
  if (kept.existsSync()) kept.deleteSync();
}

/// `maprisma-manager-core self-update-done <job> [--failed <why>]`, run by the helper once the new
/// build is ready (by the new core: the receipt) or rolled back (by the old one: the job failed).
Map<String, dynamic> finishSelfUpdate(Paths paths, String id, {String? failed}) {
  if (!validJobId(id)) throw RouteError('bad_params', 'job');
  final job = loadJob(paths, id);
  if (job == null) throw RouteError('not_found', 'no job $id');
  final app = findApp(selfApp)!;
  final su = job['selfUpdate'];
  // The window may have been closed before the job wrote its result (it is `interrupted` then):
  // what counts is the self-update that waits.
  if (job['app'] != selfApp || su is! Map || su['state'] != 'waiting') {
    throw RouteError('finished', 'job $id has no self-update waiting');
  }
  final result = job['result'] is Map ? job['result'] as Map : const {};
  final c = app.components.single;
  final log = File('${job['log']}');
  void note(String text) {
    try {
      log.writeAsStringSync('[${DateTime.now().toUtc().toIso8601String()}] $text\n', mode: FileMode.append);
    } on FileSystemException {
      // the job file says it too
    }
  }

  final at = DateTime.now().toUtc().toIso8601String();
  if (failed == null) {
    final failing = [for (final ip in c.paths) checkPath(paths, ip)].where((ch) => ch['ok'] != true).toList();
    if (failing.isNotEmpty) failed = 'verify_failed: ${failing.map((f) => '${f['path']}: ${f['problem']}').join('; ')}';
  }
  if (failed == null) {
    _writeSelfReceipt(app, c, (su['inputs'] as List?) ?? const [], id, '${job['kind']}', paths: paths);
    job['selfUpdate'] = {...su, 'state': 'done', 'at': at};
    job['state'] = 'succeeded';
    job['result'] = {
      ...result,
      'ok': true,
      'repair': false,
      'selfUpdate': {...(result['selfUpdate'] as Map? ?? {}), 'state': 'done', 'at': at},
    }
      ..remove('code')
      ..remove('message');
    note('self-update: the new build started and is ready; receipt written');
  } else {
    job['selfUpdate'] = {...su, 'state': 'rolled back', 'at': at, 'why': failed};
    job['state'] = 'failed';
    job['result'] = {
      'ok': false,
      'code': 'self_update_failed',
      'message': failed,
      'repair': false,
      'selfUpdate': {...(result['selfUpdate'] as Map? ?? {}), 'state': 'rolled back', 'at': at},
    };
    note('self-update failed: $failed');
  }
  atomicWrite(p.join(_jobsDir(paths), '$id.json'), const JsonEncoder.withIndent('  ').convert(job));
  return {'id': id, 'state': job['state'], 'selfUpdate': job['selfUpdate']['state']};
}
