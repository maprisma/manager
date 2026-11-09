import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'bar_read.dart';
import 'catalog.dart';
import 'context.dart';
import 'git.dart';
import 'github.dart';
import 'jobs.dart';
import 'paths.dart';
import 'procs.dart';
import 'receipts.dart';
import 'run.dart';
import 'sources.dart';

enum InstallState { installed, partial, absent }

/// One postcondition: the path as the installer leaves it.
Map<String, dynamic> checkPath(Paths paths, InstalledPath ip) {
  final path = paths.expand(ip.path);
  String? problem;
  switch (ip.kind) {
    case PathKind.link:
      final link = Link(path);
      if (!FileSystemEntity.isLinkSync(path)) {
        problem = FileSystemEntity.typeSync(path, followLinks: false) == FileSystemEntityType.notFound ? 'missing' : 'not a link';
      } else {
        final raw = link.targetSync();
        final target = p.normalize(p.isAbsolute(raw) ? raw : p.join(p.dirname(path), raw));
        final want = ip.target == null ? null : p.normalize(paths.expand(ip.target!));
        if (want != null && !p.equals(target, want)) {
          problem = 'points to $target';
        } else if (FileSystemEntity.typeSync(path) == FileSystemEntityType.notFound) {
          problem = 'dangling';
        }
      }
    case PathKind.dir:
      final t = FileSystemEntity.typeSync(path);
      if (t == FileSystemEntityType.notFound) {
        problem = 'missing';
      } else if (t != FileSystemEntityType.directory) {
        problem = 'not a folder';
      }
    case PathKind.file:
    case PathKind.executable:
      final t = FileSystemEntity.typeSync(path);
      if (t == FileSystemEntityType.notFound) {
        problem = 'missing';
      } else if (t != FileSystemEntityType.file) {
        problem = 'not a file';
      } else if (ip.kind == PathKind.executable && !isExecutableFile(path)) {
        problem = 'not executable';
      }
  }
  return {'path': path, 'kind': ip.kind.name, 'part': ip.part, if (ip.key) 'key': true, 'ok': problem == null, 'problem': ?problem};
}

final class ComponentStatus {
  ComponentStatus(this.component, this.state, this.checks, this.prerequisites, this.applies, {this.packageVersion, this.note});
  final Component component;
  final InstallState state;
  final List<Map<String, dynamic>> checks;
  final List<Map<String, dynamic>> prerequisites;
  final bool applies;
  final String? packageVersion;
  final String? note;

  List<Map<String, dynamic>> get failing => [for (final c in checks) if (c['ok'] != true) c];
  Set<String> get missingParts => {
    for (final part in {for (final c in checks) c['part'] as String})
      if (checks.where((c) => c['part'] == part).every((c) => c['ok'] != true)) part,
  };

  Map<String, dynamic> toJson({bool detail = false}) => {
    'id': component.id,
    'name': component.name,
    'repo': component.repo,
    'applies': applies,
    'state': state.name,
    if (packageVersion != null) 'packageVersion': packageVersion,
    if (note != null) 'note': note,
    'failing': [for (final f in failing) {'path': f['path'], 'part': f['part'], 'problem': f['problem']}],
    'missingParts': missingParts.toList(),
    'prerequisitesMissing': [for (final pr in prerequisites) if (pr['found'] != true && pr['optional'] != true) pr['command']],
    if (detail) ...{
      'install': component.install,
      'kind': component.kind.name,
      'desktops': [for (final d in component.desktops) d.name],
      'checks': checks,
      'prerequisites': prerequisites,
      'dependsOn': component.dependsOn,
      'optionalParts': component.optionalParts.toList(),
      if (component.note != null) 'catalogNote': component.note,
    },
  };
}

InstallState _stateOf(List<Map<String, dynamic>> checks) {
  if (checks.every((c) => c['ok'] == true)) return InstallState.installed;
  if (checks.every((c) => c['problem'] == 'missing')) return InstallState.absent;
  return InstallState.partial;
}

/// Reads everything about the apps (no writes, no network).
final class StatusReader {
  StatusReader(this.ctx);
  final Ctx ctx;

  Paths get paths => ctx.paths;

  Future<String?> pacmanVersion(String pkg) async {
    if (ctx.runner.which('pacman') == null) return null;
    final r = await ctx.runner.run(['pacman', '-Q', pkg], extraEnv: const {'LC_ALL': 'C'});
    if (!r.ok) return '';
    final parts = r.stdout.trim().split(RegExp(r'\s+'));
    return parts.length == 2 && parts[0] == pkg ? parts[1] : '';
  }

  List<Map<String, dynamic>> prerequisites(Component c) => [
    for (final pr in c.prerequisites)
      () {
        final found = ctx.tool(pr.command);
        return {
          'command': pr.command,
          'found': found != null,
          'path': found,
          if (pr.part != null) 'part': pr.part,
          if (pr.optional) 'optional': true,
          if (pr.note != null) 'note': pr.note,
        };
      }(),
  ];

  Future<ComponentStatus> component(AppEntry app, Component c) async {
    final checks = [for (final ip in c.paths) checkPath(paths, ip)];
    final applies = c.desktops.contains(ctx.desktop);
    final pre = prerequisites(c);
    var state = _stateOf(checks);
    if (c.kind == InstallKind.pacman && app.version.pacman != null) {
      final v = await pacmanVersion(app.version.pacman!);
      if (v == null) {
        return ComponentStatus(c, state, checks, pre, applies, note: 'pacman not found: state from the files only');
      }
      if (v.isEmpty) {
        // not a registered package: files left behind are partial, nothing is absent
        return ComponentStatus(c, state == InstallState.absent ? InstallState.absent : InstallState.partial, checks, pre, applies,
            note: state == InstallState.absent ? null : 'files present, but pacman has no ${app.version.pacman}');
      }
      if (state == InstallState.absent) state = InstallState.partial;
      return ComponentStatus(c, state, checks, pre, applies, packageVersion: v);
    }
    return ComponentStatus(c, state, checks, pre, applies);
  }

  String? folderVersion(AppEntry app) {
    final v = app.version;
    if (v.folderFile == null || v.folderPattern == null) return null;
    try {
      final text = File(p.join(ctx.repoFolder(app.mainInput.repo), v.folderFile!)).readAsStringSync();
      return RegExp(v.folderPattern!, multiLine: true).firstMatch(text)?.group(1);
    } on FileSystemException {
      return null;
    }
  }

  String? bundleVersion(AppEntry app) {
    final f = app.version.installedJson;
    if (f == null) return null;
    try {
      final data = jsonDecode(File(paths.expand(f)).readAsStringSync());
      return data is Map && data['version'] is String ? data['version'] : null;
    } on Object {
      return null;
    }
  }

  Map<String, dynamic> pathInfo(String template, {bool glob = false, String? marker}) {
    final path = paths.expand(template);
    if (glob) {
      final dir = Directory(p.dirname(path));
      final re = RegExp('^${RegExp.escape(p.basename(path)).replaceAll(r'\*', '.*')}\$');
      final found = dir.existsSync()
          ? [for (final e in dir.listSync(followLinks: false)) if (re.hasMatch(p.basename(e.path))) e.path]
          : <String>[];
      found.sort();
      return {'path': path, 'glob': true, 'exists': found.isNotEmpty, 'matches': found};
    }
    final exists = FileSystemEntity.typeSync(path, followLinks: false) != FileSystemEntityType.notFound;
    bool? ours;
    if (marker != null && exists) {
      try {
        ours = File(path).readAsLinesSync().any((l) => l.trim().startsWith(marker));
      } on Object {
        ours = false;
      }
    }
    return {'path': path, 'exists': exists, 'markedOurs': ?ours};
  }

  /// The full status of every app (or of [only]).
  Future<List<Map<String, dynamic>>> apps({String? only, bool detail = false}) async {
    final apps = only == null ? catalog : [findApp(only)!];
    final repos = {for (final a in apps) for (final i in a.inputs) i.repo};
    final gitInfos = Map.fromEntries(
      await Future.wait([for (final r in repos) ctx.git.inspect(r, ctx.repoFolder(r)).then((g) => MapEntry(r, g))]),
    );
    final procs = ctx.processes();
    final bar = await BarSnapshot.read(ctx, procs);
    final jobs = latestJobs(paths);
    final facts = ctx.github.allFacts();
    final out = <Map<String, dynamic>>[];
    for (final app in apps) {
      out.add({...await _app(app, gitInfos, procs, bar, detail, facts), 'job': jobs[app.id], 'repair': repairOffered(jobs[app.id])});
    }
    return out;
  }

  Future<Map<String, dynamic>> _app(
    AppEntry app,
    Map<String, GitInfo> gitInfos,
    List<ProcInfo> procs,
    BarSnapshot bar,
    bool detail,
    Map<String, Map<String, dynamic>> facts,
  ) async {
    final components = [for (final c in app.components) await component(app, c)];
    final counted = components.where((c) => c.applies).toList();
    final basis = counted.isEmpty ? components : counted;
    final InstallState state;
    if (basis.every((c) => c.state == InstallState.installed)) {
      state = InstallState.installed;
    } else if (basis.every((c) => c.state == InstallState.absent)) {
      state = InstallState.absent;
    } else {
      state = InstallState.partial;
    }

    final rec = readReceipt(paths, app.id);
    final receipt = rec.receipt;
    final installedAtAll = state != InstallState.absent;

    // The three update facts (plan: "Update status").
    bool? sourceDiffers;
    final differReasons = <String>[];
    if (receipt != null && receipt.fromRelease) {
      // A release isn't built from the folder: the folder is only its installer.
      differReasons.add('installed from release ${receipt.source!['tag']}');
    } else if (receipt != null) {
      var differs = false, unknown = false;
      for (final input in app.inputs) {
        final g = gitInfos[input.repo]!;
        final r = receipt.input(input.repo);
        if (r == null) {
          differs = true;
          differReasons.add('${input.repo}: not in the receipt');
        } else if (!g.isRepo || g.head == null) {
          unknown = true;
          differReasons.add('${input.repo}: no repo to compare');
        } else if (r.commit != g.head) {
          differs = true;
          differReasons.add('${input.repo}: built ${_short(r.commit)}, folder at ${_short(g.head)}');
        } else if (g.dirty == true || r.dirty) {
          // Same commit, but uncommitted changes on either side: not provably the same build.
          differs = true;
          differReasons.add('${input.repo}: ${g.dirty == true ? 'uncommitted changes in the folder' : 'built from uncommitted changes'}');
        } else if (g.dirty == null) {
          unknown = true;
          differReasons.add('${input.repo}: its state is unknown (${g.error})');
        }
      }
      // Unknown when nothing differs provably but something could not be compared.
      sourceDiffers = differs ? true : (unknown ? null : false);
    }
    int? upstreamNew;
    final upstreamNotes = <String>[];
    for (final input in app.inputs) {
      final g = gitInfos[input.repo]!;
      if (g.upstream == null) continue;
      final n = g.newUpstreamCommits;
      if (n == null) {
        upstreamNotes.add('${input.repo}: could not compare with ${g.upstream}');
        continue;
      }
      upstreamNew = (upstreamNew ?? 0) + n;
      if (g.relation == Relation.diverged) upstreamNotes.add('${input.repo}: diverged from ${g.upstream}');
      if (n > 0 && g.dirty != false) upstreamNotes.add('${input.repo}: uncommitted changes, no pull');
    }

    // Where it exists, and what GitHub has (as of the last fetch / github.refresh).
    final sources = [for (final input in app.inputs) await inputSource(ctx, input, gitInfos[input.repo]!, facts, receipt)];
    int? githubNew;
    final githubNotes = <String>[];
    for (final src in sources) {
      final cmp = src['compare'] as Map<String, dynamic>?;
      if (src['github'] == null) continue;
      final folder = src['folder'] as Map;
      if (folder['present'] != true) {
        githubNotes.add('${src['repo']}: no folder; it can be cloned from GitHub');
        continue;
      }
      if (src['remote'] == null) {
        githubNotes.add('${src['repo']}: no remote of the folder is ${(src['github'] as Map)['url']}');
        continue;
      }
      if (cmp == null) continue;
      if (cmp['fetched'] != true) {
        githubNotes.add('${src['repo']}: ${cmp['ref']} not fetched yet');
        continue;
      }
      final n = switch (cmp['relation']) {
        'behind' || 'diverged' => cmp['behind'] as int?,
        'upToDate' || 'ahead' => 0,
        _ => null,
      };
      if (n == null) continue;
      githubNew = (githubNew ?? 0) + n;
      if (cmp['relation'] == 'diverged') githubNotes.add('${src['repo']}: diverged from ${cmp['ref']}: no fast-forward');
      if (n > 0 && folder['dirty'] != false) githubNotes.add('${src['repo']}: uncommitted changes: no fast-forward');
    }
    final pkgVersion = components.map((c) => c.packageVersion).whereType<String>().firstOrNull;
    final installedVersion = pkgVersion ?? bundleVersion(app);
    final mainFacts = sources.first['github'] as Map<String, dynamic>?;
    final latest = mainFacts?['release'] as Map<String, dynamic>?;
    Map<String, dynamic>? releaseNew;
    if (latest != null && latest['tag'] is String && installedAtAll) {
      final cmp = compareVersions(latest['tag'] as String, installedVersion);
      if (cmp != null && cmp > 0) {
        releaseNew = {
          'tag': latest['tag'],
          'version': tagVersion(latest['tag'] as String),
          'installed': installedVersion,
          'installable': app.release?.supported == true,
        };
      }
    }

    final env = <String, String?>{};
    for (final c in app.components) {
      final f = ctx.flutter().exe;
      switch (c.flutter) {
        case FlutterEnv.dir:
          env['FLUTTER'] = f == null ? null : p.dirname(f);
        case FlutterEnv.executable:
          env['FLUTTER'] = f;
        case FlutterEnv.path:
          env['PATH+'] = f == null ? null : p.dirname(f);
        case FlutterEnv.none:
          break;
      }
    }

    final running = runningFor(app, paths, procs);
    final neededBy = [for (final a in catalog) if (a.dependsOn.contains(app.id)) a.id];

    return {
      'id': app.id,
      'name': app.name,
      'kind': app.kind,
      'desktops': [for (final d in app.desktops) d.name],
      'supportedHere': app.desktops.contains(ctx.desktop),
      'state': state.name,
      'components': [for (final c in components) c.toJson(detail: detail)],
      'build': {
        'known': receipt != null,
        if (receipt != null) 'receipt': receipt.toJson(),
        if (rec.error != null) 'error': rec.error,
      },
      'updates': {
        'buildUnknown': installedAtAll && receipt == null,
        'sourceDiffers': sourceDiffers,
        if (differReasons.isNotEmpty) 'sourceReasons': differReasons,
        'upstreamNew': upstreamNew,
        if (upstreamNotes.isNotEmpty) 'upstreamNotes': upstreamNotes,
        'githubNew': githubNew,
        if (githubNotes.isNotEmpty) 'githubNotes': githubNotes,
        'releaseNew': releaseNew,
      },
      'versions': {
        'installed': installedVersion,
        'folder': folderVersion(app),
        'release': latest?['tag'] is String ? tagVersion(latest!['tag'] as String) : null,
      },
      'sources': {
        'where': whereOf(sources.first),
        'url': mainFacts?['url'],
        'release': latest,
        'releaseInstall': app.release == null ? null : {'supported': app.release!.supported, 'note': ?app.release!.note},
        'inputs': sources,
      },
      'repos': [
        for (final input in app.inputs)
          {
            ...gitInfos[input.repo]!.toJson(),
            'cloneUrl': input.remote,
            'available': gitInfos[input.repo]!.present ? 'here' : (input.remote != null ? 'cloneable' : 'not available here'),
          },
      ],
      'bar': bar.stateOf(app),
      'running': running.length,
      'dependsOn': app.dependsOn,
      'neededBy': neededBy,
      'support': {
        'install': app.installation == Support.supported,
        'remove': app.removal == Support.supported,
        'note': ?app.supportNote,
      },
      'env': env,
      if (detail) ...{
        'processes': running,
        'processMatches': [for (final m in app.processes) {...m.toJson(), 'path': paths.expand(m.path)}],
        'units': [
          for (final u in app.units)
            {
              ...u.toJson(),
              'file': pathInfo(u.fileTemplate)['exists'],
              'enabledBy': _wantedBy(p.dirname(paths.expand(u.fileTemplate)), u.name),
            },
        ],
        'data': [for (final d in app.data) {...d.toJson(), ...pathInfo(d.path)}],
        'runtime': [for (final r in app.runtime) {...r.toJson(), ...pathInfo(r.path, glob: r.glob, marker: r.marker)}],
        'postSteps': app.postSteps,
        'barIcon': app.bar.toJson(),
        if (app.note != null) 'note': app.note,
      },
    };
  }
}

String _short(String? commit) => commit == null ? '(none)' : (commit.length > 8 ? commit.substring(0, 8) : commit);

/// The targets whose `.wants` folder links the unit (enabled).
List<String> _wantedBy(String unitsDir, String unit) {
  final dir = Directory(unitsDir);
  if (!dir.existsSync()) return const [];
  return [
    for (final e in dir.listSync(followLinks: false))
      if (e is Directory && e.path.endsWith('.wants') &&
          FileSystemEntity.typeSync(p.join(e.path, unit), followLinks: false) != FileSystemEntityType.notFound)
        p.basename(e.path).replaceAll(RegExp(r'\.wants$'), ''),
  ]..sort();
}
