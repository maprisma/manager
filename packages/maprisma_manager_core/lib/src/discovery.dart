/// New Maprisma apps the catalog doesn't know (plan: "New apps"): `maprisma*` git folders in the
/// projects folder and repos of the GitHub org [githubOrg] (as last listed). They are only shown,
/// with their folder and GitHub page, and a GitHub-only one can be cloned into the projects
/// folder; installing needs a catalog entry (what it installs, so it can be removed again).
library;

import 'translations.dart';


import 'dart:io';

import 'package:path/path.dart' as p;

import 'catalog.dart';
import 'context.dart';
import 'github.dart';
import 'jobs.dart' show cloneInGroup;

/// Org repos and folders that are no apps of their own (or whose name can't be a folder name:
/// the org's list comes from GitHub, and the name becomes a folder under the projects folder).
bool notAnApp(String name) {
  final n = name.toLowerCase();
  if (!RegExp(r'^[a-z0-9][a-z0-9._-]*$').hasMatch(n) || n.contains('..')) return true;
  return n.startsWith('omarchy-') || n.startsWith('aur-') || n == githubOrg;
}

/// The folder a GitHub-only repo is cloned into: `<projects>/maprisma-<name>` (or its own name
/// when that starts with maprisma).
String cloneFolderFor(Ctx ctx, String name) =>
    p.join(ctx.projectsDir, name.toLowerCase().startsWith('maprisma') ? name : 'maprisma-$name');

/// `{org: orgFacts, projectsDir, apps: [{name, folder: path|null, github: {repo, url, public,
/// description, linkedBy: remote|name|org}|null, cloneTo?: path|null, cloneBlocked?: why}]}`, by name. [GitHub.resolveLinks] first.
Future<Map<String, dynamic>> discover(Ctx ctx) async {
  final gh = ctx.github;
  final knownRepos = {
    for (final a in catalog)
      for (final i in a.inputs) ...[i.repo.toLowerCase(), for (final alias in repoFolderAliases[i.repo] ?? const <String>[]) alias.toLowerCase()],
  };
  final knownSlugs = {for (final a in catalog) for (final i in a.inputs) ?gh.slugOf(i)?.toLowerCase()};
  final found = <String, Map<String, dynamic>>{};

  // Folders: maprisma* git repos that are no catalog input (nor a copy of one).
  final dir = Directory(ctx.projectsDir);
  final entries = dir.existsSync() ? (dir.listSync(followLinks: false).whereType<Directory>().toList()..sort((a, b) => a.path.compareTo(b.path))) : <Directory>[];
  for (final d in entries) {
    final name = p.basename(d.path);
    final lower = name.toLowerCase();
    if (!lower.startsWith('maprisma') || knownRepos.contains(lower) || notAnApp(name)) continue;
    if (FileSystemEntity.typeSync(p.join(d.path, '.git')) == FileSystemEntityType.notFound) continue;
    final slug = githubSlugOfRemotes(await ctx.git.remotes(d.path));
    if (slug != null && knownSlugs.contains(slug)) continue;
    found[lower] = {
      'name': name,
      'folder': d.path,
      'github': slug == null ? null : {'repo': slug, 'url': githubWebUrl(slug), 'linkedBy': 'remote'},
    };
  }

  // The org's repos that no catalog input is (nor a folder above already has as its remote).
  for (final r in gh.orgRepos()) {
    final name = '${r['name']}';
    final slug = '$githubOrg/$name'.toLowerCase();
    if (r['archived'] == true || notAnApp(name) || knownSlugs.contains(slug)) continue;
    final facts = {'repo': slug, 'url': r['url'] ?? githubWebUrl(slug), 'public': r['public'], 'description': r['description']};
    final byRemote = found.values.where((f) => (f['github'] as Map?)?['repo'] == slug).firstOrNull;
    if (byRemote != null) {
      byRemote['github'] = {...facts, 'linkedBy': 'remote'};
      continue;
    }
    // a folder of its name without a GitHub remote
    final lower = name.toLowerCase();
    final byName = [found[lower], found['maprisma-$lower']].nonNulls.where((f) => f['github'] == null).firstOrNull;
    if (byName != null) {
      byName['github'] = {...facts, 'linkedBy': 'name'};
      continue;
    }
    // Its clone folder must not be a catalog app's (an org repo `maprisma-launcher` beside the
    // catalog's `launcher` would land in the Launcher's folder) nor another new app's.
    final to = cloneFolderFor(ctx, name);
    final toName = p.basename(to).toLowerCase();
    final taken = knownRepos.contains(toName) || found.containsKey(toName) || found.values.any((f) => f['cloneTo'] == to);
    found[slug] = {
      'name': name,
      'folder': null,
      'github': {...facts, 'linkedBy': 'org'},
      'cloneTo': taken ? null : to,
      if (taken) 'cloneBlocked': trf('{0} is the folder of {1}', [p.basename(to), knownRepos.contains(toName) ? tr('a catalog app') : tr('another app')]),
    };
  }

  final apps = found.values.toList()..sort((a, b) => '${a['name']}'.toLowerCase().compareTo('${b['name']}'.toLowerCase()));
  return {'org': gh.orgFacts(), 'projectsDir': ctx.projectsDir, 'apps': apps};
}

/// Clones the new GitHub-only app [slug] (one of [discover]'s, without a folder) into its
/// [cloneFolderFor]: into a temporary folder first, renamed when complete.
Future<Map<String, dynamic>> cloneDiscovered(Ctx ctx, String slug) async {
  final d = await discover(ctx);
  final app = (d['apps'] as List).cast<Map<String, dynamic>>().where((a) => (a['github'] as Map?)?['repo'] == slug.toLowerCase()).firstOrNull;
  if (app == null) throw RouteError('not_found', trf('{0} is no new app of {1}', [slug, githubOrg]));
  if (app['folder'] != null) throw RouteError('exists', trf('{0} is at {1}', [slug, app['folder']]));
  final to = app['cloneTo'] as String?;
  if (to == null) throw RouteError('exists', '${app['cloneBlocked']}');
  if (FileSystemEntity.typeSync(to, followLinks: false) != FileSystemEntityType.notFound) throw RouteError('exists', trf('{0} is there already', [to]));
  final git = ctx.runner.which('git');
  if (git == null) throw RouteError('unavailable', tr('git is missing'));
  final url = ctx.cloneUrlFor(slug.toLowerCase());
  final tmp = p.join(p.dirname(to), '.${p.basename(to)}.clone-${ctx.clock().microsecondsSinceEpoch}');
  void drop() {
    if (FileSystemEntity.typeSync(tmp, followLinks: false) == FileSystemEntityType.directory) Directory(tmp).deleteSync(recursive: true);
  }

  Directory(p.dirname(to)).createSync(recursive: true);
  try {
    // git and its helpers in their own process group: a hung clone ends completely
    final out = <int>[];
    final r = await cloneInGroup(ctx, git, url, tmp,
        killAfter: const Duration(seconds: 5), deadlineAfter: const Duration(minutes: 10), onOutput: (b) => out.length < 65536 ? out.addAll(b) : null);
    if (r.startFailed != null) throw RouteError('clone_failed', trf('git clone could not start: {0}', [r.startFailed]));
    if (r.code != 0 || r.stopped) {
      final text = String.fromCharCodes(out).trim();
      final line = text.split('\n').lastWhere((l) => l.trim().isNotEmpty, orElse: () => '');
      throw RouteError('clone_failed', r.stopped ? tr('git clone took too long') : (line.isEmpty ? trf('git clone failed (exit code {0})', [r.code]) : line));
    }
    if (FileSystemEntity.typeSync(to, followLinks: false) != FileSystemEntityType.notFound) throw RouteError('exists', trf('{0} is there already', [to]));
    Directory(tmp).renameSync(to);
  } finally {
    drop();
  }
  return {'repo': slug.toLowerCase(), 'folder': to, 'cloned': url};
}
