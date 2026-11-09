import 'dart:convert';
import 'dart:io';

import 'context.dart';
import 'core.dart';

const usage = '''usage: maprisma-manager-core status [--json] [--desktop cosmic|kde|other] [<id>]
       maprisma-manager-core fetch [--force] [<id>]
       maprisma-manager-core bar [--json] [--panel <name>]
       maprisma-manager-core bar <id> left|center|right|out [--index <n>] [--panel <name>]
       maprisma-manager-core bar apply''';

/// `maprisma-manager-core <command>`: a human table by default, JSON with --json.
Future<int> runCli(List<String> args, {CoreService? service, IOSink? out}) async {
  final sink = out ?? stdout;
  var json = false, force = false;
  String? desktop, panel;
  int? index;
  final rest = <String>[];
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (a == '--json') {
      json = true;
    } else if (a == '--force') {
      force = true;
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
  final CoreService core;
  try {
    core = service ?? CoreService(environment: Platform.environment);
  } on StateError catch (e) {
    stderr.writeln(e.message);
    return 1;
  }
  try {
    switch (rest) {
      case ['status']:
        final r = await core.call('apps.list', {'desktop': ?desktop});
        sink.writeln(json ? const JsonEncoder.withIndent('  ').convert(r) : statusTable(r));
      case ['status', final id]:
        final r = await core.call('apps.get', {'id': id, 'desktop': ?desktop});
        sink.writeln(json ? const JsonEncoder.withIndent('  ').convert(r) : statusTable({...r, 'apps': [r['app']]}));
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
    ['ID', 'STATE', 'VERSION', 'BUILD', 'FOLDER', 'UPSTREAM', 'BAR', 'RUN', 'NOTES'],
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
