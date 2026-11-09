import 'dart:convert';
import 'dart:io';

import 'context.dart';
import 'core.dart';

const usage = '''usage: maprisma-manager-core status [--json] [--desktop cosmic|kde|other] [<id>]
       maprisma-manager-core fetch [--force] [<id>]''';

/// `maprisma-manager-core <command>`: a human table by default, JSON with --json.
Future<int> runCli(List<String> args, {CoreService? service, IOSink? out}) async {
  final sink = out ?? stdout;
  var json = false, force = false;
  String? desktop;
  final rest = <String>[];
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (a == '--json') {
      json = true;
    } else if (a == '--force') {
      force = true;
    } else if (a == '--desktop' && i + 1 < args.length) {
      desktop = args[++i];
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
