import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'context.dart';
import 'core.dart';
import 'jobs.dart' show finishSelfUpdate;

const usage = '''usage: maprisma-manager-core status [--json] [--desktop cosmic|kde|other] [<id>]
       maprisma-manager-core sources [--json]
       maprisma-manager-core fetch [--force] [<id>]
       maprisma-manager-core github [--force] [<id>]
       maprisma-manager-core new [--json]                 (Maprisma apps the catalog doesn't know)
       maprisma-manager-core clone-new <org/repo>         (clone a new GitHub-only one into the projects folder)
       maprisma-manager-core bar [--json] [--panel <name>]
       maprisma-manager-core bar <id> left|center|right|out [--index <n>] [--panel <name>]
       maprisma-manager-core bar apply
       maprisma-manager-core install|update|reinstall <id> [--force] [--source release|folder]
                             (--force: Launcher's install-local --force; --source: Maprisma's archive)
       maprisma-manager-core release <id> [<tag>]
       maprisma-manager-core remove <id> [--delete-settings] [--yes]
       maprisma-manager-core icon <id> [<name>|<file>|--reset] [--search <text>] [--json]
       maprisma-manager-core ai-helpers                   (the AI helpers for "Let AI do the updates")
       maprisma-manager-core ai-update [<helper>]         (let the AI update the apps; Settings must allow it)
       maprisma-manager-core jobs [<id>]
       maprisma-manager-core log <job>
       maprisma-manager-core version
       maprisma-manager-core self-update-done <job> [--failed <why>]   (the self-update helper)''';

/// `maprisma-manager-core <command>`: a human table by default, JSON with --json.
Future<int> runCli(List<String> args, {CoreService? service, IOSink? out}) async {
  final sink = out ?? stdout;
  var json = false, force = false, yes = false, deleteSettings = false, reset = false;
  String? desktop, panel, source, search, failed;
  int? index;
  final rest = <String>[];
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (a == '--json') {
      json = true;
    } else if (a == '--force') {
      force = true;
    } else if (a == '--yes' || a == '-y') {
      yes = true;
    } else if (a == '--delete-settings') {
      deleteSettings = true;
    } else if (a == '--reset') {
      reset = true;
    } else if (a == '--source' && i + 1 < args.length) {
      source = args[++i];
    } else if (a == '--failed' && i + 1 < args.length) {
      failed = args[++i];
    } else if (a == '--search' && i + 1 < args.length) {
      search = args[++i];
    } else if (a == '--desktop' && i + 1 < args.length) {
      desktop = args[++i];
    } else if (a == '--panel' && i + 1 < args.length) {
      panel = args[++i];
    } else if (a == '--index' && i + 1 < args.length && int.tryParse(args[i + 1]) != null) {
      index = int.parse(args[++i]);
    } else if (a.startsWith('--desktop=')) {
      desktop = a.substring('--desktop='.length);
    } else if (a.startsWith('-')) {
      stderr.writeln(usage);
      return 2;
    } else {
      rest.add(a);
    }
  }
  if (rest case ['version']) {
    sink.writeln('maprisma-manager-core $coreVersion');
    return 0;
  }
  final CoreService core;
  try {
    core = service ?? CoreService(environment: Platform.environment);
  } on StateError catch (e) {
    stderr.writeln(e.message);
    return 1;
  }
  try {
    switch (rest) {
      case ['self-update-done', final job]:
        final r = finishSelfUpdate(core.ctx.paths, job, failed: failed);
        sink.writeln(json ? jsonEncode(r) : 'job $job: ${r['state']} (${r['selfUpdate']})');
      case ['status']:
        final r = await core.call('apps.list', {'desktop': ?desktop});
        sink.writeln(json ? const JsonEncoder.withIndent('  ').convert(r) : statusTable(r));
      case ['status', final id]:
        final r = await core.call('apps.get', {'id': id, 'desktop': ?desktop});
        sink.writeln(json
            ? const JsonEncoder.withIndent('  ').convert(r)
            : '${statusTable({...r, 'apps': [r['app']]})}\n${sourcesDetail(r['app'] as Map<String, dynamic>)}');
      case ['sources']:
        final r = await core.call('apps.list');
        sink.writeln(json ? const JsonEncoder.withIndent('  ').convert(r) : sourcesTable(r));
      case ['new']:
        final r = await core.call('discovered.list');
        if (json) {
          sink.writeln(const JsonEncoder.withIndent('  ').convert(r));
        } else {
          final apps = (r['apps'] as List).cast<Map<String, dynamic>>();
          final org = r['org'] as Map<String, dynamic>;
          if (apps.isEmpty) sink.writeln('No new Maprisma apps.');
          for (final a in apps) {
            final gh = a['github'] as Map<String, dynamic>?;
            final where = [
              if (a['folder'] != null) a['folder'],
              if (gh != null) '${gh['url']}${gh['public'] == false ? ' (private)' : ''}',
              if (a['folder'] == null) a['cloneTo'] != null ? 'clone-new ${gh!['repo']} → ${a['cloneTo']}' : 'not cloneable: ${a['cloneBlocked']}',
            ].join('  ');
            sink.writeln('${'${a['name']}'.padRight(28)} $where');
          }
          sink.writeln(org['known'] == true
              ? 'GitHub org ${org['org']}: ${_age(org['age'])}${org['error'] != null ? ' (last try failed: ${org['error']})' : ''}; refresh: github --force'
              : 'GitHub org ${org['org']} not listed yet: github --force');
        }
      case ['ai-helpers']:
        final r = await core.call('ai.helpers');
        if (json) {
          sink.writeln(const JsonEncoder.withIndent('  ').convert(r));
        } else {
          sink.writeln('AI updates: ${r['enabled'] == true ? 'on' : 'off'}   chosen: ${r['chosen'] ?? 'none ready'}');
          for (final h in (r['helpers'] as List).cast<Map<String, dynamic>>()) {
            final state = h['signed_in'] == true ? 'ready' : h['installed'] == true ? 'not signed in (${h['login']})' : 'not installed';
            sink.writeln('${'${h['id']}'.padRight(24)} ${'${h['name']}'.padRight(28)} $state');
          }
        }
      case ['ai-update']:
      case ['ai-update', _]:
        return await _runAi(core, sink, rest.length == 2 ? rest[1] : null, json);
      case ['clone-new', final repo]:
        final r = await core.call('discovered.clone', {'repo': repo});
        sink.writeln(json ? const JsonEncoder.withIndent('  ').convert(r) : 'Cloned ${r['repo']} into ${r['folder']}');
      case ['github']:
      case ['github', _]:
        final r = await core.call('github.refresh', {'force': force, if (rest.length == 2) 'id': rest[1]});
        if (json) {
          sink.writeln(const JsonEncoder.withIndent('  ').convert(r));
        } else {
          if (r['note'] != null) sink.writeln(r['note']);
          for (final repo in (r['repos'] as List).cast<Map<String, dynamic>>()) {
            final what = repo['checked'] == true
                ? 'checked via ${repo['via']}${repo['release'] == null ? ', no release' : ', latest release ${repo['release']}'}'
                : repo['error'] != null
                ? 'failed: ${repo['error']} (last known facts kept)'
                : 'skipped: ${repo['skipped']}';
            sink.writeln('${(repo['repo'] as String).padRight(28)} $what');
          }
        }
      case ['release', final id]:
        return await _runJob(core, sink, {'app': id, 'kind': 'release'});
      case ['release', final id, final tag]:
        return await _runJob(core, sink, {'app': id, 'kind': 'release', 'options': {'tag': tag}});
      case ['fetch']:
      case ['fetch', _]:
        final r = await core.call('git.fetch', {'force': force, if (rest.length == 2) 'id': rest[1]});
        if (json) {
          sink.writeln(const JsonEncoder.withIndent('  ').convert(r));
        } else {
          for (final repo in (r['repos'] as List).cast<Map<String, dynamic>>()) {
            final what = repo['fetched'] == true
                ? 'fetched (${repo['relation']}${(repo['behind'] ?? 0) > 0 ? ', ${repo['behind']} new' : ''})'
                : repo['error'] != null
                ? 'failed: ${repo['error']}'
                : 'skipped: ${repo['skipped']}';
            sink.writeln('${(repo['repo'] as String).padRight(28)} $what');
          }
        }
      case ['bar']:
        final r = await core.call('bar.get', {'panel': ?panel});
        sink.writeln(json ? const JsonEncoder.withIndent('  ').convert(r) : barText(r));
      case ['bar', 'apply']:
        final r = await core.call('bar.apply');
        sink.writeln(json ? const JsonEncoder.withIndent('  ').convert(r) : 'changed: ${(r['changed'] as List).isEmpty ? 'nothing' : (r['changed'] as List).join(', ')}');
      case ['bar', final id, final where]:
        final Map<String, dynamic> r;
        if (where == 'out') {
          r = await core.call('bar.remove', {'app': id, 'panel': ?panel});
        } else if (['left', 'center', 'centre', 'right'].contains(where)) {
          r = await core.call('bar.place', {'app': id, 'area': where, 'index': ?index, 'panel': ?panel});
        } else {
          stderr.writeln(usage);
          return 2;
        }
        if (json) {
          sink.writeln(const JsonEncoder.withIndent('  ').convert(r));
        } else {
          final after = await core.call('bar.get', {'panel': ?panel});
          sink.writeln(barText(after));
          final reload = r['reload'] as Map<String, dynamic>?;
          if (reload != null) {
            sink.writeln(reload['reacted'] == true
                ? 'The panel took the change.'
                : reload['restarted'] == true
                ? 'The panel was restarted${reload['back'] == true ? ' and is back' : ', but did not come back'}.'
                : '${reload['note'] ?? reload['error'] ?? ''}');
          }
        }
      case [final kind, final id] when ['install', 'update', 'reinstall'].contains(kind):
        return await _runJob(core, sink, {'app': id, 'kind': kind, 'options': {if (force) 'force': true, 'source': ?source}});
      case ['icon', final id]:
        final r = reset ? await core.call('icons.reset', {'app': id}) : await core.call('icons.get', {'app': id, 'query': search ?? '', 'limit': 40});
        sink.writeln(json ? const JsonEncoder.withIndent('  ').convert(r) : (reset ? iconChangeText(r) : iconText(r)));
      case ['icon', final id, final icon]:
        final r = await core.call('icons.set', {'app': id, 'icon': icon});
        sink.writeln(json ? const JsonEncoder.withIndent('  ').convert(r) : iconChangeText(r));
      case ['remove', final id]:
        final plan = await core.call('apps.remove_plan', {'id': id, 'delete_settings': deleteSettings});
        sink.writeln(planText(plan));
        if (plan['blocked'] != null) {
          stderr.writeln('error: ${plan['blocked']}');
          return 1;
        }
        if ((plan['goes'] as List).isEmpty && (plan['data'] as List).every((d) => d['goes'] != true)) {
          sink.writeln('Nothing of ${plan['name']} to remove.');
        }
        final dependents = plan['dependents'] as List;
        if (!yes) {
          if (!stdin.hasTerminal) {
            stderr.writeln('error: confirm with --yes (no terminal to ask)');
            return 2;
          }
          stdout.write('Remove ${plan['name']}? [y/N] ');
          final answer = stdin.readLineSync()?.trim().toLowerCase();
          if (answer != 'y' && answer != 'yes') {
            sink.writeln('Nothing removed.');
            return 1;
          }
        }
        return await _runJob(core, sink, {
          'app': id,
          'kind': 'remove',
          'options': {'delete_settings': deleteSettings, 'revision': plan['revision'], if (dependents.isNotEmpty) 'dependents_ok': true},
        });
      case ['jobs']:
      case ['jobs', _]:
        final r = await core.call('jobs.list', {if (rest.length == 2) 'app': rest[1]});
        if (json) {
          sink.writeln(const JsonEncoder.withIndent('  ').convert(r));
        } else {
          final jobs = (r['jobs'] as List).cast<Map<String, dynamic>>();
          if (jobs.isEmpty) sink.writeln('no jobs yet');
          for (final j in jobs) {
            final result = j['result'] as Map<String, dynamic>?;
            final why = result == null || result['ok'] == true ? '' : '  ${result['code']}: ${result['message'] ?? ''}${result['repair'] == true ? ' (repair: reinstall)' : ''}';
            sink.writeln('${j['id']}  ${(j['state'] as String).padRight(11)} ${(j['phase'] as String).padRight(7)}$why');
          }
        }
      case ['log', final id]:
        var from = 0;
        while (true) {
          final r = await core.call('jobs.log', {'id': id, 'from': from});
          sink.write(r['text']);
          from = r['next'] as int;
          if (r['finished'] == true) break;
          final job = await core.call('jobs.get', {'id': id});
          if (job['finished'] == true && from >= (r['size'] as int)) {
            final last = await core.call('jobs.log', {'id': id, 'from': from});
            sink.write(last['text']);
            break;
          }
          if ((r['text'] as String).isEmpty) await Future<void>.delayed(const Duration(milliseconds: 300));
        }
      default:
        stderr.writeln(usage);
        return 2;
    }
    return 0;
  } on RouteError catch (e) {
    stderr.writeln('error: ${e.code}${e.message == null ? '' : ' (${e.message})'}');
    return 1;
  }
}

/// Starts a job, prints its output as it comes, Ctrl-C cancels (refused in the commit phase).
/// Exit code: 0 done, 1 failed, 130 cancelled.
Future<int> _runJob(CoreService core, IOSink sink, Map<String, dynamic> params) async {
  final started = await core.call('jobs.start', params);
  final id = started['id'] as String;
  final lines = core.jobs.lines(id)!.listen(sink.writeln);
  StreamSubscription<ProcessSignal>? sigint;
  try {
    sigint = ProcessSignal.sigint.watch().listen((_) async {
      try {
        await core.call('jobs.cancel', {'id': id});
        stderr.writeln('cancelling …');
      } on RouteError catch (e) {
        stderr.writeln('not cancelled: ${e.message ?? e.code}');
      }
    });
  } on Object {
    sigint = null; // no signal watching here (tests)
  }
  final job = await core.jobs.done(id)!;
  await sigint?.cancel();
  await lines.cancel();
  final result = job['result'] as Map<String, dynamic>;
  if (result['ok'] == true) {
    sink.writeln('${job['kind']} ${job['app']}: done${result['partial'] != null ? ' (partly: no ${(result['partial'] as List).join(', ')})' : ''}');
    if (result['restart'] == true) {
      final su = result['selfUpdate'] as Map? ?? const {};
      sink.writeln('The new build is staged and checked: close Maprisma Manager (pid ${(su['waitFor'] as List?)?.join(', ')}) to finish; '
          'the helper swaps it in and starts it again (log: ${su['log']})');
    }
    return 0;
  }
  sink.writeln('${job['kind']} ${job['app']}: ${job['state']} (${result['code']}${result['message'] == null ? '' : ': ${result['message']}'})'
      '${result['repair'] == true ? '. Repair: maprisma-manager-core reinstall ${job['app']}' : ''}');
  sink.writeln('log: ${job['log']}');
  return job['state'] == 'cancelled' ? 130 : 1;
}

/// The human view of icons.get.
String iconText(Map<String, dynamic> r) {
  final lines = <String>['${r['name']}: bar icon ${r['iconName'] ?? '-'}'];
  if (r['changeable'] != true) {
    lines.add('  not changeable: ${r['why']}');
    return lines.join('\n');
  }
  lines.add('  file: ${r['file']}${r['exists'] == true ? '' : ' (missing)'}');
  final choice = r['choice'] as Map<String, dynamic>?;
  lines.add('  now: ${r['current']}${choice == null ? '' : ' (${choice['name'] ?? choice['from']})'}');
  final orig = r['original'] as Map<String, dynamic>;
  if (orig['kept'] == true) lines.add('  original kept: ${orig['file']}');
  if (r['note'] != null) lines.add('  note: ${r['note']}');
  final theme = r['theme'] as Map<String, dynamic>;
  lines.add('Symbolic icons in ${(theme['chain'] as List).join(' → ')}${(r['query'] as String).isEmpty ? '' : ' matching "${r['query']}"'}: ${r['total']}${r['truncated'] == true ? ' (first ${(r['choices'] as List).length})' : ''}');
  for (final c in (r['choices'] as List).cast<Map<String, dynamic>>()) {
    lines.add('  ${c['name']}  (${c['theme']})');
  }
  return lines.join('\n');
}

/// The human view of icons.set / icons.reset.
String iconChangeText(Map<String, dynamic> r) {
  final lines = <String>[];
  if (r['reset'] == false) return '${r['app']}: ${r['note']}';
  final choice = r['choice'] as Map<String, dynamic>?;
  lines.add(r['reset'] == true
      ? '${r['app']}: the original icon is back in ${r['file']}'
      : '${r['app']}: ${r['file']} is now ${choice?['name'] ?? choice?['from']}');
  if (r['iconCache'] != null) lines.add('  icon cache: ${r['iconCache']}');
  final bar = r['bar'] as Map<String, dynamic>?;
  if (bar != null) {
    final panel = bar['panel'] as Map<String, dynamic>?;
    lines.add('  bar: ${panel != null ? (panel['error'] != null ? 'not refreshed (${panel['error']})' : 'the panel rebuilt (${panel['panel']})') : bar['trayRestarted'] != null ? 'tray restarted: ${bar['trayRestarted']}' : bar['error'] ?? bar['note'] ?? ''}');
    if (panel != null && bar['note'] != null) lines.add('  note: ${bar['note']}');
  }
  return lines.join('\n');
}

/// The human view of apps.remove_plan.
String planText(Map<String, dynamic> plan) {
  final lines = <String>['Remove ${plan['name']}:'];
  if (plan['verified'] != true) {
    lines.add('  (no ${plan['receipt'] == 'broken' ? 'valid ' : ''}receipt: the catalog\'s files are removed, unverified)');
  }
  final goes = (plan['goes'] as List).cast<Map<String, dynamic>>();
  lines.add('Goes:${goes.isEmpty ? ' nothing' : ''}');
  for (final g in goes) {
    final tree = g['kind'] == 'tree'
        ? '/  (${g['files']} files${g['links'] == 0 ? '' : ', ${g['links']} links'}${g['derived'] == null ? '' : ', ${g['derived']} byte-code caches'}${g['leftover'] == true ? '; left by an interrupted install' : ''})'
        : '';
    lines.add('  ${g['path']}${g['kind'] == 'dir' ? '/ (if empty)' : ''}$tree${g['unverified'] == true ? '  [unverified]' : ''}');
  }
  for (final g in (plan['generated'] as List? ?? const []).cast<Map<String, dynamic>>()) {
    lines.add('  ${g['path']}  (${g['why']})');
  }
  for (final d in (plan['data'] as List).cast<Map<String, dynamic>>().where((d) => d['goes'] == true)) {
    lines.add('  ${d['path']}  [settings]');
  }
  final stays = [
    ...(plan['stays'] as List).cast<Map<String, dynamic>>(),
    ...(plan['data'] as List).cast<Map<String, dynamic>>().where((d) => d['goes'] != true),
    ...(plan['runtime'] as List).cast<Map<String, dynamic>>().where((r) => !(plan['stays'] as List).any((s) => s['path'] == r['path'])),
  ];
  lines.add('Stays:${stays.isEmpty ? ' nothing' : ''}');
  for (final s in stays) {
    lines.add('  ${s['path']}  (${s['why']})');
  }
  for (final r in (plan['restores'] as List).cast<Map<String, dynamic>>()) {
    lines.add('Restored: ${r['path']} (${r['reason']})');
  }
  for (final b in (plan['backupsKept'] as List).cast<Map<String, dynamic>>()) {
    lines.add('Backup kept, not restored: ${b['path']} (${b['reason']}) in ${b['backup']}');
  }
  final steps = (plan['steps'] as List? ?? const []).cast<Map<String, dynamic>>();
  if (steps.isNotEmpty) lines.add('Steps:');
  for (final s in steps) {
    lines.add('  ${s['when'] == 'after' ? 'after the files: ' : ''}${s['title']}');
    for (final c in (s['commands'] as List? ?? const [])) {
      lines.add('    \$ $c');
    }
  }
  for (final n in (plan['notes'] as List? ?? const [])) {
    lines.add('Note: $n');
  }
  if (plan['blocked'] != null) lines.add('Not possible now: ${plan['blocked']}');
  final dependents = plan['dependents'] as List;
  if (dependents.isNotEmpty) lines.add('Warning: needed by ${dependents.map((d) => d['name']).join(', ')}');
  final bar = plan['bar'] as Map<String, dynamic>;
  if (bar['takenOut'] == true) lines.add('Its bar icon is taken out first.');
  if ((plan['running'] as int) > 0) lines.add('${plan['running']} running process(es) are stopped.');
  return lines.join('\n');
}

/// The human view of bar.get: one line per area, ours marked with their app id.
String barText(Map<String, dynamic> r) {
  final lines = <String>[];
  final where = switch (r['kind']) {
    'cosmicPanel' => 'COSMIC panel "${r['panel']}"',
    'maprismaIcons' => 'Maprisma Icons (widget ${r['widget']})',
    'systemTray' => 'KDE system tray',
    _ => 'no bar',
  };
  lines.add(where);
  if (r['error'] != null) lines.add('error: ${r['error']}');
  if (r['note'] != null) lines.add('${r['note']}');
  final areas = r['areas'] as Map<String, dynamic>?;
  if (areas != null) {
    for (final a in ['left', 'center', 'right']) {
      final entries = (areas[a] as List).cast<Map<String, dynamic>>();
      final names = [for (final e in entries) e['ours'] == true ? '[${e['app']}]' : _short(e['id'] as String)];
      lines.add('${a.padRight(7)} ${names.isEmpty ? '-' : names.join('  ')}');
    }
    final out = (r['out'] as List? ?? const []).cast<Map<String, dynamic>>();
    lines.add('out     ${out.isEmpty ? '-' : out.map((e) => e['app']).join('  ')}');
  }
  final trays = r['trays'] as List?;
  if (r['kind'] == 'systemTray' && trays != null) {
    for (final t in trays.cast<Map<String, dynamic>>()) {
      lines.add('${(t['app'] as String).padRight(10)} ${t['startsAtLogin'] == true ? 'starts at login' : 'hidden'}${t['running'] == true ? ', running' : ''}');
    }
  }
  return lines.join('\n');
}

/// `com.system76.CosmicAppletTime` → `Time`; other ids as they are.
String _short(String id) {
  const prefixes = ['com.system76.CosmicApplet', 'com.system76.CosmicPanel', 'com.system76.Cosmic'];
  for (final pre in prefixes) {
    if (id.startsWith(pre) && id.length > pre.length) return id.substring(pre.length);
  }
  return id;
}

/// The human view of apps.list.
String statusTable(Map<String, dynamic> r) {
  final rows = <List<String>>[
    ['ID', 'STATE', 'VERSION', 'SOURCE', 'BUILD', 'FOLDER', 'UPSTREAM', 'BAR', 'RUN', 'NOTES'],
  ];
  for (final a in (r['apps'] as List).cast<Map<String, dynamic>>()) {
    final comps = (a['components'] as List).cast<Map<String, dynamic>>();
    final updates = a['updates'] as Map<String, dynamic>;
    final repos = (a['repos'] as List).cast<Map<String, dynamic>>();
    final bar = a['bar'] as Map<String, dynamic>;
    final notes = <String>[];
    if (a['supportedHere'] != true) notes.add('not for this desktop');
    for (final c in comps) {
      if (c['applies'] != true) continue;
      final parts = (c['missingParts'] as List).where((p) => p != 'main');
      if (c['state'] == 'partial') {
        final failing = (c['failing'] as List).length;
        notes.add('${c['id']}: $failing path(s) failing${parts.isEmpty ? '' : ', missing ${parts.join(', ')}'}');
      }
      final missing = c['prerequisitesMissing'] as List;
      if (missing.isNotEmpty) notes.add('${c['id']} needs ${missing.join(', ')}');
      if (c['note'] != null) notes.add('${c['note']}');
    }
    for (final g in repos) {
      if (g['present'] != true) {
        notes.add('${g['repo']} ${g['available']}');
      } else if (g['dirty'] == true) {
        notes.add('${g['repo']} dirty');
      }
      if (g['detached'] == true) notes.add('${g['repo']} detached');
    }
    final build = a['build'] as Map<String, dynamic>;
    if (build['error'] != null) notes.add('${build['error']}');
    final releaseNew = updates['releaseNew'] as Map<String, dynamic>?;
    if (releaseNew != null) notes.add('release ${releaseNew['tag']} is newer');
    final githubNew = updates['githubNew'] as int?;
    final upstreamIsGitHub = ((a['sources'] as Map?)?['inputs'] as List? ?? const [])
        .every((s) => (s as Map)['remote'] == null || (s['remote'] as Map)['isUpstream'] == true);
    final githubDiverged = (updates['githubNotes'] as List? ?? const []).any((n) => '$n'.contains('diverged'));
    if (githubDiverged && !upstreamIsGitHub) {
      notes.add('diverged from GitHub');
    } else if (githubNew != null && githubNew > 0 && !upstreamIsGitHub) {
      notes.add('GitHub +$githubNew');
    }
    final job = a['job'] as Map<String, dynamic>?;
    if (job != null && a['repair'] == true) notes.add('${job['kind']} ${job['state']} in ${job['phase']}: repair (reinstall)');
    final versions = a['versions'] as Map<String, dynamic>;
    final version = [
      versions['installed'] ?? '-',
      if (versions['folder'] != null && versions['folder'] != versions['installed']) '(folder ${versions['folder']})',
    ].join(' ');
    final upstream = updates['upstreamNew'] == null
        ? 'none'
        : updates['upstreamNotes'] != null && (updates['upstreamNotes'] as List).any((n) => '$n'.contains('diverged'))
        ? 'diverged'
        : updates['upstreamNew'] == 0
        ? 'up to date'
        : '+${updates['upstreamNew']}';
    rows.add([
      a['id'],
      switch (a['state']) {
        'installed' => 'installed',
        'partial' => 'partly',
        _ => 'not installed',
      },
      version,
      switch ((a['sources'] as Map?)?['where']) {
        'both' => 'both',
        'folder' => 'folder',
        'GitHub' => 'GitHub',
        _ => '-',
      },
      build['known'] == true ? 'receipt' : (a['state'] == 'absent' ? '-' : 'unknown'),
      switch (updates['sourceDiffers']) {
        true => 'differs',
        false => 'same',
        _ => '-',
      },
      upstream,
      switch (bar['state']) {
        'in' => bar['zone'] ?? 'in',
        'out' => 'out',
        'unknown' => '?',
        _ => '-',
      },
      '${a['running']}',
      notes.join('; '),
    ]);
  }
  final widths = [for (var i = 0; i < rows.first.length - 1; i++) rows.map((r) => r[i].length).reduce((a, b) => a > b ? a : b)];
  final lines = [
    'Desktop: ${r['desktop']}   Projects: ${r['projectsDir']} (${r['projectsSource']})   Flutter: ${r['flutter'] ?? 'not found'}',
    for (final row in rows) [for (var i = 0; i < row.length; i++) i < widths.length ? row[i].padRight(widths[i]) : row[i]].join('  ').trimRight(),
  ];
  return lines.join('\n');
}

String _age(Object? seconds) {
  if (seconds is! int) return 'never checked';
  if (seconds < 90) return 'checked just now';
  if (seconds < 5400) return 'checked ${(seconds / 60).round()} min ago';
  if (seconds < 2 * 86400) return 'checked ${(seconds / 3600).round()} h ago';
  return 'checked ${(seconds / 86400).round()} days ago';
}

String _release(Map<String, dynamic>? rel) {
  if (rel == null) return 'none';
  final date = rel['published'] is String ? (rel['published'] as String).split('T').first : '?';
  return '${rel['tag']} ($date)';
}

/// The folder and GitHub lines of one app (`status <id>`).
String sourcesDetail(Map<String, dynamic> app) {
  final lines = <String>[];
  final src = app['sources'] as Map<String, dynamic>;
  for (final s in (src['inputs'] as List).cast<Map<String, dynamic>>()) {
    final folder = s['folder'] as Map<String, dynamic>;
    final gh = s['github'] as Map<String, dynamic>?;
    lines.add('${s['repo']}:');
    if (folder['present'] == true) {
      final head = folder['head'] is String ? (folder['head'] as String).substring(0, 7) : '-';
      final state = folder['dirty'] == true ? 'uncommitted changes' : (folder['dirty'] == false ? 'clean' : 'state unknown');
      lines.add('  Folder:  ${folder['path']} (${folder['branch'] ?? 'detached'} @ $head, $state)');
    } else {
      lines.add('  Folder:  ${folder['path']} (missing${gh != null ? ': can be cloned from GitHub' : ''})');
    }
    if (gh == null) {
      lines.add('  GitHub:  - (local only)');
      continue;
    }
    final vis = gh['public'] == true ? 'public' : (gh['public'] == false ? 'private' : 'visibility unknown');
    final remote = s['remote'] as Map<String, dynamic>?;
    lines.add('  GitHub:  ${gh['url']} ($vis; ${remote == null ? 'no remote of the folder' : 'remote ${remote['name']}${remote['isUpstream'] == true ? ', the upstream' : ''}'}; ${_age(gh['age'])})');
    final rel = gh['release'] as Map<String, dynamic>?;
    lines.add('  Release: ${gh['known'] == true ? _release(rel) : 'unknown (run: github)'}${rel?['url'] != null ? '  ${rel!['url']}' : ''}');
    final cmp = s['compare'] as Map<String, dynamic>?;
    if (cmp != null) {
      lines.add('  Against: ${cmp['ref']}: ${cmp['fetched'] == true ? '${cmp['relation']} (${cmp['ahead']} ahead, ${cmp['behind']} behind)' : 'not fetched yet'}');
    }
    if (gh['error'] != null) lines.add('  Last check failed: ${gh['error']}');
  }
  final updates = app['updates'] as Map<String, dynamic>;
  final rn = updates['releaseNew'] as Map<String, dynamic>?;
  if (rn != null) {
    lines.add('Newer release: ${rn['tag']} (installed ${rn['installed']})${rn['installable'] == true ? '; install with: release ${app['id']}' : ''}');
  }
  for (final n in (updates['githubNotes'] as List? ?? const [])) {
    lines.add('Note: $n');
  }
  return lines.join('\n');
}

/// Every app with its folder and GitHub URL per input (`sources`).
String sourcesTable(Map<String, dynamic> r) {
  final rows = <List<String>>[
    ['APP', 'REPO', 'FOLDER', 'GITHUB', 'RELEASE'],
  ];
  for (final a in (r['apps'] as List).cast<Map<String, dynamic>>()) {
    for (final s in ((a['sources'] as Map)['inputs'] as List).cast<Map<String, dynamic>>()) {
      final folder = s['folder'] as Map<String, dynamic>;
      final gh = s['github'] as Map<String, dynamic>?;
      rows.add([
        a['id'] as String,
        s['repo'] as String,
        folder['present'] == true ? folder['path'] as String : 'missing',
        gh == null ? 'local only' : '${gh['url']}${gh['public'] == false ? ' (private)' : ''}',
        gh == null ? '-' : (gh['known'] == true ? _release(gh['release'] as Map<String, dynamic>?) : 'unknown'),
      ]);
    }
  }
  final widths = [for (var i = 0; i < rows.first.length - 1; i++) rows.map((r) => r[i].length).reduce((a, b) => a > b ? a : b)];
  final facts = [
    for (final a in (r['apps'] as List).cast<Map<String, dynamic>>())
      for (final s in ((a['sources'] as Map)['inputs'] as List).cast<Map<String, dynamic>>())
        if (s['github'] is Map && (s['github'] as Map)['age'] is int) (s['github'] as Map)['age'] as int,
  ];
  return [
    for (final row in rows) [for (var i = 0; i < row.length; i++) i < widths.length ? row[i].padRight(widths[i]) : row[i]].join('  ').trimRight(),
    if (facts.isNotEmpty) 'GitHub facts ${_age(facts.reduce((a, b) => a > b ? a : b))} (oldest); refresh: github [--force]'
    else 'GitHub facts: never checked; refresh: github',
  ].join('\n');
}

/// `ai-update`: starts the AI's run and prints what it says and does until it ends.
Future<int> _runAi(CoreService core, IOSink sink, String? helper, bool json) async {
  var run = (await core.call('ai.start', {'helper': ?helper}))['run'] as Map<String, dynamic>;
  if (!json) sink.writeln('AI update with ${run['helperName']}');
  var shown = 0;
  String? phase;
  while (true) {
    final steps = (run['steps'] as List).cast<Map<String, dynamic>>();
    if (!json) {
      if (run['state'] == 'running' && run['phase'] != phase && steps.length == shown) {
        phase = run['phase'] as String?;
        sink.writeln('  … $phase${run['round'] == null ? '' : ' (round ${run['round']})'}');
      }
      for (; shown < steps.length; shown++) {
        final s = steps[shown];
        if (s['state'] == 'running' && run['state'] == 'running') break; // printed when it ends
        sink.writeln(aiStepLine(s));
      }
    }
    if (run['state'] != 'running') break;
    await Future<void>.delayed(const Duration(milliseconds: 400));
    run = (await core.call('ai.get'))['run'] as Map<String, dynamic>;
  }
  if (json) {
    sink.writeln(const JsonEncoder.withIndent('  ').convert(run));
  } else {
    sink.writeln('AI update: ${run['state']}${run['message'] == null ? '' : ' (${run['message']})'}');
  }
  return run['state'] == 'succeeded' ? 0 : 1;
}

String aiStepLine(Map<String, dynamic> s) => switch (s['kind']) {
  'say' => '  AI: ${s['text']}',
  'note' => '  ${s['text']}',
  _ => s['ok'] == false
      ? '  refused ${s['do']} ${s['app']}: ${s['message']}'
      : '  ${s['do']} ${s['app']}: ${s['state']}${s['up_to_date'] == true ? ' (up to date)' : ''}'
          '${s['state'] != 'succeeded' && s['message'] != null ? ' — ${s['message']}' : s['do'] == 'pub_get' && s['message'] != null ? '\n    ${'${s['message']}'.replaceAll('\n', '\n    ')}' : ''}',
};
