/// "Let AI do the updates": an installed, signed-in helper (the Ask AI helpers of Maprisma
/// Theme: Claude Code, Codex, pi, Hermes, local models, and every other installed agent of
/// Maprisma's helpers catalog, see ai/helpers_catalog.dart) decides what to update, and the
/// Manager does it.
///
/// The helper has no tools (Codex: a read-only sandbox in a jail): it gets the apps' status and
/// what the steps so far did, and answers with steps from a fixed list. The Manager checks every
/// step and runs it with its own commands only:
///
/// - `update`    an app's update job (pull fast-forward, build, install),
/// - `reinstall` its reinstall job,
/// - `pub_get`   `flutter pub get` / `dart pub get` in the app's folders (a build that can't find
///               the Flutter SDK or its packages).
///
/// No code changes, no push, no password: apps installed with pacman (Maprisma) and the Manager
/// itself (it has to quit to update) are left to their own buttons. One run at a time, at most
/// [maxRounds] answers and [maxSteps] steps; an identical step runs at most twice.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'ai/ask_ai.dart';
import 'ai/shared_helper.dart';
import 'catalog.dart';
import 'context.dart';
import 'jobs.dart';
import 'paths.dart';
import 'pub_refresh.dart';
import 'status.dart';
import 'translations.dart';

const maxRounds = 5;
const maxStepsPerRound = 6;
const maxSteps = 20;
const aiActions = {'update', 'reinstall', 'pub_get'};

/// How long one `pub get` may take.
const pubGetTimeout = Duration(minutes: 5);

/// Cut [text] to its last [max] characters (the end of a log says why it failed).
String tail(String text, int max) => text.length <= max ? text : '…${text.substring(text.length - max)}';

/// The helper's answer: the first `{` to the last `}` (it may wrap it in a code fence or words).
Map<String, dynamic>? parseAnswer(String text) {
  final start = text.indexOf('{'), end = text.lastIndexOf('}');
  if (start < 0 || end <= start) return null;
  try {
    final data = jsonDecode(text.substring(start, end + 1));
    return data is Map<String, dynamic> ? data : null;
  } on FormatException {
    return null;
  }
}

/// Why the AI may not touch [app] here, or null when it may.
String? aiBlocked(AppEntry app, Map<String, dynamic> status) {
  if (app.id == selfApp) return tr('Maprisma Settings updates itself from its own Update button');
  if (app.components.any((c) => c.kind == InstallKind.pacman)) return tr('it is installed with pacman and needs your password');
  if (status['supportedHere'] != true) return tr('not for this desktop');
  if (status['state'] == 'absent') return tr('not installed');
  return null;
}

/// One app as the helper sees it: compact, no paths.
Map<String, dynamic> appFacts(Map<String, dynamic> a) {
  final app = findApp(a['id'] as String)!;
  final updates = (a['updates'] as Map?) ?? const {};
  final versions = (a['versions'] as Map?) ?? const {};
  final job = a['job'] as Map?;
  final blocked = aiBlocked(app, a);
  final upstreamNotes = (updates['upstreamNotes'] as List?) ?? const [];
  return {
    'id': app.id,
    'name': app.name,
    'state': a['state'],
    'version': versions['installed'],
    if (versions['folder'] != null && versions['folder'] != versions['installed']) 'folder_version': versions['folder'],
    'build': switch (updates['sourceDiffers']) {
      true => 'differs from the folder',
      false => 'same as the folder',
      _ => 'unknown',
    },
    'upstream_new_commits': updates['upstreamNew'],
    if (upstreamNotes.any((n) => '$n'.contains('diverged'))) 'upstream_diverged': true,
    if (((a['repos'] as List?) ?? const []).any((r) => r is Map && r['dirty'] == true)) 'folder_has_uncommitted_changes': true,
    if (updates['releaseNew'] is Map) 'newer_release': (updates['releaseNew'] as Map)['tag'],
    if (job != null)
      'last_job': {
        'kind': job['kind'],
        'state': job['state'],
        if ((job['result'] as Map?)?['message'] != null) 'message': tail('${(job['result'] as Map)['message']}', 300),
      },
    'ai_may_act': blocked == null,
    'why_not': ?blocked,
  };
}

/// The instructions and facts for one round.
String buildPrompt(List<Map<String, dynamic>> apps, List<Map<String, dynamic>> done, String language) {
  final facts = const JsonEncoder.withIndent(' ').convert(apps);
  final history = done.isEmpty ? 'nothing yet' : const JsonEncoder.withIndent(' ').convert(done);
  return '''You are the update assistant of Maprisma Settings, which installs and updates the Maprisma apps on this Linux desktop. Bring the installed apps up to date.

You cannot run anything yourself. Answer with ONE JSON object and nothing else:
{"say": "<one or two short sentences for the user, in $language>", "actions": [<steps>], "done": <true|false>}

The only steps there are (anything else is ignored):
- {"do": "update", "app": "<id>"}: pull the app's folder from its upstream (fast-forward only), then build and install it. It ends early with "up to date" when the installed build already is the newest.
- {"do": "reinstall", "app": "<id>"}: build and install the app's folder again, even if the Manager thinks it is current.
- {"do": "pub_get", "app": "<id>"}: fetch the Flutter/Dart packages of the app's folders again. This fixes builds that fail because the Flutter SDK or packages are not found (errors like "Error when reading .../flutter/lib/material.dart", "'Column' isn't defined", "MethodChannel isn't a type"). Then update or reinstall the app again.

Rules:
- Only apps with "ai_may_act": true.
- An app needs work when it has upstream_new_commits > 0, a folder_version other than its version, or a last_job that failed. "build": "differs from the folder" alone is a weak sign: try "update" once; if it says up to date, leave it.
- At most $maxStepsPerRound steps per answer. They run in order; the next message shows what they did.
- Don't repeat a step that already failed the same way. If something can't be fixed with these steps, say so and stop.
- Set "done": true (with no steps) when nothing more is useful; say what was updated and what is left for the user.

Apps:
$facts

Steps done so far and their results:
$history
''';
}

/// The running or last AI update (one per core).
final class AiUpdater {
  AiUpdater(this.ctx, this.jobs, {required this.fetch, AskRunner? runner})
    : runner = runner ?? AskRunner(home: ctx.paths.home, environment: ctx.environment);

  final Ctx ctx;
  final JobEngine jobs;
  final AskRunner runner;

  /// git fetch of every app's repos (CoreService's git.fetch), before the first round.
  final Future<void> Function() fetch;

  /// The helper's answer for a prompt; tests replace it.
  late Future<String> Function(String helper, String prompt) ask = (helper, prompt) => runner.run(helper, prompt);

  /// Status of all apps (StatusReader); tests replace it.
  late Future<List<Map<String, dynamic>>> Function() readApps = () => StatusReader(ctx).apps();

  Map<String, dynamic>? _run;
  bool _cancel = false;
  String? _job;

  bool get running => _run?['state'] == 'running';

  Future<List<Map<String, dynamic>>> helperList() => helperStates(ctx.paths.home, ctx.environment);

  /// The helpers; `helper` is the choice shared by all Maprisma apps (ai/shared_helper.dart:
  /// "auto" or an id), `chosen` the one used: the shared choice when it is ready, else (automatic,
  /// or one that is unknown or no longer installed) the first ready one in the catalog's order
  /// (`auto`); `fallback`: a chosen helper isn't ready, so the automatic one is used.
  Future<Map<String, dynamic>> helpers() async {
    final settings = Settings.load(ctx.paths);
    final list = await helperList();
    final ready = [for (final h in list) if (h['signed_in'] == true) h['id'] as String];
    final shared = sharedHelper(ctx.paths);
    final chosen = resolveHelper(shared, ready);
    final canSearch = helperCanSearchWeb(chosen);
    return {
      'helpers': list,
      'helper': shared,
      'auto': ready.firstOrNull,
      'chosen': chosen,
      'fallback': shared != sharedAuto && !ready.contains(shared),
      'web_search': readSharedWebSearch(ctx.paths),
      'web_search_supported': canSearch,
      'web_search_reason': canSearch
          ? null
          : chosen == null
          ? tr('No AI helper is installed and signed in')
          : trf('Works with Claude Code; {0} can\'t search the web here', [_name(list, chosen)]),
      'file': sharedAiFile(ctx.paths),
      'enabled': settings.values['ai_updates'] == true,
      'busy': running,
    };
  }

  /// `ai.set_helper` `{helper}`: "auto" or a helper id, for every Maprisma app.
  Future<Map<String, dynamic>> setHelper(Map<String, dynamic> params) async {
    final helper = params['helper'];
    if (!validSharedHelper(helper)) throw RouteError('bad_params', 'helper ("auto" or a helper id)');
    sharedHelper(ctx.paths); // the old setting can't come back over the new choice
    try {
      writeSharedHelper(ctx.paths, helper as String);
    } on FileSystemException catch (e) {
      throw RouteError('write_failed', trf('{0} could not be saved: {1}', [sharedAiFile(ctx.paths), e.message]));
    }
    return helpers();
  }

  static String _name(List<Map<String, dynamic>> list, String id) =>
      '${list.where((h) => h['id'] == id).firstOrNull?['name'] ?? id}';

  /// `ai.set_web_search` `{on}`: whether the shared helper may search the web, for every app.
  Future<Map<String, dynamic>> setWebSearch(Map<String, dynamic> params) async {
    final on = params['on'];
    if (on is! bool) throw RouteError('bad_params', 'on (true or false)');
    sharedHelper(ctx.paths); // seed first, so the old helper setting isn't lost
    try {
      writeSharedWebSearch(ctx.paths, on);
    } on FileSystemException catch (e) {
      throw RouteError('write_failed', trf('{0} could not be saved: {1}', [sharedAiFile(ctx.paths), e.message]));
    }
    return helpers();
  }

  Map<String, dynamic> get() => {'run': _run == null ? null : _view(_run!)};

  Map<String, dynamic> _view(Map<String, dynamic> run) => {
    ...run,
    'steps': [for (final s in run['steps'] as List) Map<String, dynamic>.from(s as Map)],
  };

  Future<Map<String, dynamic>> start(Map<String, dynamic> params) async {
    if (Settings.load(ctx.paths).values['ai_updates'] != true) throw RouteError('off', tr('AI updates are off: turn them on on the AI page'));
    if (running) throw RouteError('busy', tr('the AI is already updating'));
    final wanted = params['helper'];
    if (wanted != null && wanted is! String) throw RouteError('bad_params', 'helper');
    final h = await helpers();
    if (running) throw RouteError('busy', tr('the AI is already updating'));
    final ready = [for (final x in h['helpers'] as List) if ((x as Map)['signed_in'] == true) x];
    final id = (wanted as String?) ?? h['chosen'] as String?;
    final helper = ready.where((x) => x['id'] == id).firstOrNull;
    if (helper == null) throw RouteError('unavailable', tr('no AI helper is installed and signed in'));
    _cancel = false;
    final now = ctx.clock().toUtc();
    final run = _run = {
      'id': 'ai-${now.toIso8601String().replaceAll(RegExp(r'[-:.]'), '')}',
      'helper': helper['id'],
      'helperName': helper['name'],
      'state': 'running',
      'phase': 'checking',
      'started': now.toIso8601String(),
      'steps': <Map<String, dynamic>>[],
    };
    unawaited(_loop(run).catchError((Object e) => _finish(run, 'failed', '$e')));
    return {'run': _view(run)};
  }

  Future<Map<String, dynamic>> cancel() async {
    final run = _run;
    if (run == null || run['state'] != 'running') throw RouteError('finished', tr('the AI is not updating'));
    _cancel = true;
    runner.cancel();
    final job = _job;
    if (job != null) {
      try {
        await jobs.cancel({'id': job});
      } on RouteError {
        // it can't stop any more (already writing): it ends on its own, then the run ends
      }
    }
    return {'run': _view(run)};
  }

  void _step(Map<String, dynamic> run, Map<String, dynamic> step) => (run['steps'] as List).add(step);

  void _finish(Map<String, dynamic> run, String state, [String? message]) {
    if (run['state'] != 'running') return;
    run['state'] = state;
    run['phase'] = 'done';
    run['ended'] = ctx.clock().toUtc().toIso8601String();
    if (message != null) run['message'] = message;
    _job = null;
    _writeLog(run);
  }

  Future<void> _loop(Map<String, dynamic> run) async {
    final done = <Map<String, dynamic>>[];
    final counts = <String, int>{};
    var steps = 0;
    try {
      await fetch();
    } on Object {
      // offline: the status still knows the last fetch
    }
    for (var round = 1; round <= maxRounds; round++) {
      if (_cancel) return _finish(run, 'cancelled');
      run['phase'] = 'checking';
      final apps = [for (final a in await readApps()) appFacts(a)];
      if (_cancel) return _finish(run, 'cancelled'); // Stop while checking: the helper never starts
      run['phase'] = 'asking';
      run['round'] = round;
      String text;
      try {
        text = await ask(run['helper'] as String, buildPrompt(apps, done, languageNames[currentLanguage] ?? 'English'));
      } on AskError catch (e) {
        if (_cancel) return _finish(run, 'cancelled');
        return _finish(run, 'failed', trf('{0} gave no answer: {1}', [run['helperName'], e.message]));
      }
      if (_cancel) return _finish(run, 'cancelled');
      final answer = parseAnswer(text);
      if (answer == null) {
        _step(run, {'kind': 'say', 'text': tail(text.trim(), 600), 'unreadable': true});
        return _finish(run, 'failed', tr('the helper\'s answer was not the expected JSON'));
      }
      final say = answer['say'];
      if (say is String && say.trim().isNotEmpty) _step(run, {'kind': 'say', 'text': tail(say.trim(), 1000)});
      final actions = answer['actions'] is List ? answer['actions'] as List : const [];
      if (actions.isEmpty) return _finish(run, 'succeeded');
      run['phase'] = 'working';
      var ran = 0;
      for (final raw in actions.take(maxStepsPerRound)) {
        if (_cancel) return _finish(run, 'cancelled');
        if (steps >= maxSteps) {
          _step(run, {'kind': 'note', 'text': trf('Stopped after {0} steps', [maxSteps])});
          return _finish(run, 'succeeded');
        }
        final step = _check(raw, apps);
        if (step['ok'] == false) {
          _step(run, step);
          done.add({'action': raw, 'result': 'refused', 'message': step['message']});
          continue;
        }
        final key = '${step['do']} ${step['app']}';
        counts[key] = (counts[key] ?? 0) + 1;
        if (counts[key]! > 2) {
          final refused = {...step, 'ok': false, 'message': tr('already tried twice')};
          _step(run, refused);
          done.add({'action': raw, 'result': 'refused', 'message': refused['message']});
          continue;
        }
        steps++;
        ran++;
        step['state'] = 'running';
        _step(run, step);
        final outcome = await _perform(step);
        step.addAll(outcome);
        done.add({
          'action': {'do': step['do'], 'app': step['app']},
          'result': outcome['state'],
          if (outcome['message'] != null) 'message': outcome['message'],
          if (outcome['log'] != null) 'log_end': outcome['log'],
        });
      }
      if (answer['done'] == true && ran == 0) return _finish(run, 'succeeded');
    }
    _step(run, {'kind': 'note', 'text': trf('Stopped after {0} rounds', [maxRounds])});
    _finish(run, 'succeeded');
  }

  /// A step from the answer, checked: `{kind: action, do, app, name}` or with `ok: false, message`.
  Map<String, dynamic> _check(Object? raw, List<Map<String, dynamic>> apps) {
    final what = raw is Map ? raw['do'] : null;
    // an old id (`manager`) names the app it is now
    final id = raw is Map && raw['app'] is String ? canonicalAppId(raw['app'] as String) : (raw is Map ? raw['app'] : null);
    final step = <String, dynamic>{'kind': 'action', 'do': '$what', 'app': '$id'};
    if (what is! String || !aiActions.contains(what)) return {...step, 'ok': false, 'message': tr('not a step the AI may take')};
    final app = id is String ? findApp(id) : null;
    final facts = apps.where((a) => a['id'] == id).firstOrNull;
    if (app == null || facts == null) return {...step, 'ok': false, 'message': tr('no such app')};
    step['name'] = app.name;
    if (facts['ai_may_act'] != true) return {...step, 'ok': false, 'message': facts['why_not'] ?? tr('not allowed')};
    return step;
  }

  Future<Map<String, dynamic>> _perform(Map<String, dynamic> step) async {
    final app = findApp(step['app'] as String)!;
    if (step['do'] == 'pub_get') return _pubGet(app);
    Map<String, dynamic> started;
    try {
      started = jobs.start({'app': app.id, 'kind': step['do']});
    } on RouteError catch (e) {
      return {'state': 'failed', 'message': e.message ?? e.code};
    }
    final id = started['id'] as String;
    step['job'] = id;
    _job = id;
    final job = await (jobs.finished(id) ?? Future.value(jobs.get({'id': id})));
    _job = null;
    final result = (job['result'] as Map?) ?? const {};
    String? log;
    if (job['state'] != 'succeeded') {
      try {
        final f = File(job['log'] as String);
        if (f.existsSync()) log = tail(f.readAsStringSync(), 1500);
      } on Object {
        // no log: the message says enough
      }
    }
    return {
      'state': job['state'],
      if (result['up_to_date'] == true) 'up_to_date': true,
      if (result['message'] != null) 'message': tail('${result['message']}', 400),
      'log': ?log,
    };
  }

  /// `pub get` in every Dart/Flutter package of the app's folders (pubspec.yaml up to 3 levels,
  /// not in build output or hidden folders), with the Manager's Flutter.
  Future<Map<String, dynamic>> _pubGet(AppEntry app) async {
    final flutter = ctx.flutter().exe;
    if (flutter == null) return {'state': 'failed', 'message': tr('Flutter was not found')};
    final dart = p.join(p.dirname(flutter), 'dart');
    final dirs = [for (final input in app.inputs) ...dartPackages(ctx.repoFolder(input.repo))];
    if (dirs.isEmpty) return {'state': 'succeeded', 'message': tr('no Dart or Flutter packages')};
    // Not while a job builds, updates or removes the app (here or in another Manager).
    if (jobs.activeFor(app.id) || pendingSelfUpdate(ctx.paths) != null) {
      return {'state': 'failed', 'message': trf('a job for {0} is already queued or running', [app.name])};
    }
    final out = StringBuffer();
    var ok = true;
    for (final dir in dirs) {
      if (_cancel) return {'state': 'cancelled'};
      final rel = p.relative(dir, from: ctx.projectsDir);
      if (isWorkspaceMember(dir)) {
        out.writeln('$rel: ${tr('skipped (a pub workspace member)')}');
        continue;
      }
      final exe = usesFlutter(dir) || !File(dart).existsSync() ? flutter : dart;
      final (code, text) = await _runGroup([exe, 'pub', 'get'], dir, {...ctx.environment, 'PATH': '${p.dirname(flutter)}:${ctx.environment['PATH'] ?? ''}'});
      if (code == null) return {'state': 'cancelled', 'message': out.toString().trim()};
      out.writeln('$rel: ${code == 0 ? 'ok' : 'exit $code'}');
      if (code != 0) {
        ok = false;
        out.writeln(tail(text.trim(), 600));
      }
    }
    return {'state': ok ? 'succeeded' : 'failed', 'message': tail(out.toString().trim(), 1200)};
  }

  /// [argv] in its own process group (setsid), ended as a whole on Stop or after
  /// [pubGetTimeout]: (exit code or -1 on time-out, null when stopped; the output's end).
  Future<(int?, String)> _runGroup(List<String> argv, String cwd, Map<String, String> env) async {
    final setsid = ctx.runner.which('setsid') ?? '/usr/bin/setsid';
    final Process proc;
    try {
      proc = await Process.start(setsid, argv, workingDirectory: cwd, environment: env, includeParentEnvironment: false);
    } on ProcessException catch (e) {
      return (127, e.message);
    }
    unawaited(proc.stdin.close().catchError((_) {}));
    final buf = StringBuffer();
    void keep(String s) {
      buf.write(s);
      if (buf.length > 32768) {
        final t = buf.toString();
        buf
          ..clear()
          ..write(t.substring(t.length - 8192));
      }
    }

    final outDone = proc.stdout.transform(utf8.decoder).forEach(keep).catchError((_) {});
    final errDone = proc.stderr.transform(utf8.decoder).forEach(keep).catchError((_) {});
    int? code;
    unawaited(proc.exitCode.then((c) => code = c));
    final end = DateTime.now().add(pubGetTimeout);
    var stopped = false, late = false;
    while (code == null) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      if (code != null) break;
      stopped = _cancel;
      late = DateTime.now().isAfter(end);
      if (stopped || late) {
        // setsid execs the program: its pid is the group's
        await Process.run('kill', ['-KILL', '--', '-${proc.pid}']).catchError((_) => ProcessResult(0, 1, '', ''));
        proc.kill(ProcessSignal.sigkill);
        await proc.exitCode;
        break;
      }
    }
    await Future.wait([outDone, errDone]).timeout(const Duration(seconds: 2), onTimeout: () => []);
    if (stopped) return (null, buf.toString());
    if (late) return (-1, '${buf.toString()}\n${tr('no answer in time')}');
    return (code, buf.toString());
  }

  /// The run as a log under the Manager's state (what the AI said and did).
  void _writeLog(Map<String, dynamic> run) {
    try {
      final dir = Directory(p.join(ctx.paths.managerState, 'ai'))..createSync(recursive: true);
      File(p.join(dir.path, '${run['id']}.json')).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(run));
    } on Object {
      // the run is still shown; only its record is missing
    }
  }
}
