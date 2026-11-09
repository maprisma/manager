/// The remove plan (`apps.remove_plan`): what goes, what stays and why, before anything is
/// deleted. The remove job re-plans and deletes exactly what the plan says goes.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'catalog.dart';
import 'context.dart';
import 'kde_remove.dart';
import 'ownership.dart';
import 'procs.dart';
import 'receipts.dart';
import 'status.dart';
import 'trees.dart';

/// Why something stays (shown as such in the plan).
const whyChanged = 'changed since the Manager installed it';
const whyForeign = 'not what the Manager installed';
const whyNotInReceipt = 'not in the receipt';

final class RemovePlan {
  RemovePlan(this.app, this.json, this.goes, this.settingsGo, this.restores, {this.trees = const [], this.recipe, this.blocked});
  final AppEntry app;
  final Map<String, dynamic> json;

  /// The owned folders as checked now (their files go one by one, each checked again).
  final List<TreeCheck> trees;

  /// The app's own steps (KDE apps).
  final RecipePlan? recipe;

  /// Why the remove can't run (e.g. no receipt for an app with bundles); null = it can.
  final String? blocked;

  /// `{path, kind: file|link|dir, sha256?/link?, normalized?, unverified?}`
  final List<Map<String, dynamic>> goes;

  /// User data folders that go with `delete_settings`.
  final List<String> settingsGo;
  final List<Map<String, dynamic>> restores;

  String get revision => json['revision'] as String;
}

/// Refuses an app whose remove needs a step of its own that isn't there yet.
void checkRemovable(AppEntry app, [DesktopId? desktop]) {
  if (app.removal == Support.unsupportedYet) {
    throw RouteError('unsupported_yet', 'removing ${app.name} is not supported yet${app.supportNote == null ? '' : ': ${app.supportNote}'}');
  }
  // Apps of one desktop (Tiling, Icons: KDE) are removed only there (their steps need it).
  if (desktop != null && !app.desktops.contains(desktop)) {
    throw RouteError('unavailable', '${app.name} is removed only on ${app.desktops.map((d) => d.name).join('/')} (this is ${desktop.name})');
  }
}

Future<RemovePlan> removePlan(Ctx ctx, AppEntry app, {bool deleteSettings = false}) async {
  checkRemovable(app, ctx.desktop);
  if (app.components.any((c) => c.kind == InstallKind.pacman)) return _pacmanPlan(ctx, app, deleteSettings: deleteSettings);
  final paths = ctx.paths;
  final roots = sharedRoots(paths);
  // Folders owned as a whole: their paths are handled by the tree's manifest only.
  final treeRoots = [for (final c in app.components) for (final t in c.trees) (t, paths.expand(t.path))];
  bool inTree(String path) => treeRoots.any((t) => t.$2 == path || p.isWithin(t.$2, path));
  final rec = readReceipt(paths, app.id);
  final receipt = rec.receipt;
  final norm = normalizedPaths(paths, app);
  final known = {for (final (ip, path) in catalogPaths(paths, app.components)) path: ip};
  final goes = <Map<String, dynamic>>[], stays = <Map<String, dynamic>>[];

  if (receipt != null) {
    final inReceipt = <String>{};
    for (final e in receipt.paths) {
      final path = e['path'] as String;
      inReceipt.add(path);
      if (inTree(path)) continue;
      final now = pathState(path, normalized: e['normalized'] as String?);
      if (now['exists'] != true) continue; // already gone
      if (!known.containsKey(path)) {
        stays.add({'path': path, 'why': 'in the receipt, but no longer in the catalog'});
      } else if (e.containsKey('sha256')) {
        if (now['type'] == 'file' && now['sha256'] == e['sha256']) {
          goes.add({'path': path, 'kind': 'file', 'sha256': e['sha256'], 'normalized': ?e['normalized']});
        } else {
          stays.add({'path': path, 'why': now['type'] == 'file' ? whyChanged : whyForeign});
        }
      } else if (e.containsKey('link')) {
        if (now['type'] == 'link' && now['link'] == e['link']) {
          goes.add({'path': path, 'kind': 'link', 'link': e['link']});
        } else {
          stays.add({'path': path, 'why': now['type'] == 'link' ? 'the link points elsewhere now' : whyForeign});
        }
      } else if (e['dir'] == true) {
        if (now['type'] == 'dir') {
          goes.add({'path': path, 'kind': 'dir', 'onlyIfEmpty': true});
        } else {
          stays.add({'path': path, 'why': whyForeign});
        }
      }
    }
    for (final path in known.keys) {
      if (inReceipt.contains(path) || inTree(path)) continue;
      if (pathState(path, hash: false)['exists'] == true) stays.add({'path': path, 'why': whyNotInReceipt});
    }
  } else {
    // No receipt (installed before the Manager, or a broken one): the catalog's paths, marked
    // unverified; a link goes only when it points where the installer points it.
    for (final MapEntry(key: path, value: ip) in known.entries) {
      if (inTree(path)) continue;
      final now = pathState(path, normalized: norm.contains(path) ? normalizedHidden : null);
      if (now['exists'] != true) continue;
      switch (ip.kind) {
        case PathKind.file:
        case PathKind.executable:
          if (now['type'] == 'file') {
            goes.add({'path': path, 'kind': 'file', 'sha256': now['sha256'], 'normalized': ?now['normalized'], 'unverified': true});
          } else {
            stays.add({'path': path, 'why': 'not a file'});
          }
        case PathKind.link:
          final want = ip.target == null ? null : p.normalize(paths.expand(ip.target!));
          final raw = now['link'] as String?;
          final target = raw == null ? null : p.normalize(p.isAbsolute(raw) ? raw : p.join(p.dirname(path), raw));
          if (now['type'] == 'link' && want != null && target == want) {
            goes.add({'path': path, 'kind': 'link', 'link': raw, 'unverified': true});
          } else {
            stays.add({'path': path, 'why': now['type'] == 'link' ? 'the link points elsewhere' : 'not a link'});
          }
        case PathKind.dir:
          if (now['type'] == 'dir') {
            goes.add({'path': path, 'kind': 'dir', 'onlyIfEmpty': true, 'unverified': true});
          } else {
            stays.add({'path': path, 'why': 'not a folder'});
          }
      }
    }
  }

  // The owned folders: what is still as installed goes, file by file; the rest stays.
  final treeChecks = <TreeCheck>[];
  final keptTrees = <String>{};
  String? blocked;
  for (final (t, root) in treeRoots) {
    final exists = FileSystemEntity.typeSync(root, followLinks: false) != FileSystemEntityType.notFound;
    final leftovers = swapLeftovers(root, swap: t.swap, staged: t.staged);
    if (!exists && leftovers.isEmpty) continue;
    final rec = receipt?.tree(root);
    String? why;
    if (receipt == null) {
      why = 'no receipt: the files of this folder are unknown (reinstall through the Manager, then remove)';
      blocked ??= 'Reinstall ${app.name} through the Manager first: without a receipt the files of $root are unknown';
    } else if (rec == null) {
      why = 'its files are not in the receipt (reinstall through the Manager, then remove)';
    } else if (rec['overflow'] == true) {
      why = 'too many files to own (${rec['files']})';
    } else if (rec['preexisting'] == true) {
      why = 'it was there before the Manager installed ${app.name} (it may not be only ${app.name}\'s)';
    } else if (FileSystemEntity.typeSync(root, followLinks: false) == FileSystemEntityType.link) {
      why = 'a link, not the folder the installer made';
    } else {
      why = unsafeReach(root, roots);
    }
    if (why != null) {
      if (exists) stays.add({'path': root, 'why': why});
      for (final l in leftovers) {
        stays.add({'path': l, 'why': 'left by an interrupted install (not checked: $why)'});
      }
      keptTrees.add(root);
      continue;
    }
    final entries = (rec!['entries'] as List).cast<Map<String, dynamic>>();
    if (exists) {
      final c = checkTree(root, entries, foreignWhy: (_) => 'not installed by the Manager (added later)');
      if (t.wholeOnly && !c.whole) {
        stays.add({'path': root, 'why': 'changed since the Manager installed it: the package stays as a whole'});
        stays.addAll(c.stays);
        keptTrees.add(root);
      } else {
        goes.add(c.goesJson());
        stays.addAll(c.stays);
        treeChecks.add(c);
      }
    }
    for (final l in leftovers) {
      final c = checkTree(l, entries, foreignWhy: (_) => 'not in the installed build');
      if (c.whole && unsafeReach(l, roots) == null) {
        goes.add(c.goesJson(leftover: true));
        treeChecks.add(c);
      } else {
        stays.add({'path': l, 'why': 'left by an interrupted install; it isn\'t the installed build'});
      }
    }
  }

  // Nothing reached through a linked folder or outside the install folders; without a receipt,
  // nothing an earlier remove kept (changed or foreign then, and not the Manager's since).
  final kept = receipt == null ? loadKept(paths, app.id) : const <String, Map<String, dynamic>>{};
  for (final g in [...goes]) {
    if (g['kind'] == 'tree') continue; // checked above
    final path = g['path'] as String;
    final unsafe = unsafeReach(path, roots);
    final k = kept[path];
    final wasKept = k != null && ((k['sha256'] != null && k['sha256'] == g['sha256']) || (k['link'] != null && k['link'] == g['link']));
    if (unsafe != null || wasKept) {
      goes.remove(g);
      stays.add({'path': path, 'why': unsafe ?? 'kept by an earlier remove (not the Manager\'s)'});
    }
  }

  // User data: kept unless asked; data shared with Omarchy never goes.
  final settingsGo = <String>[];
  final data = <Map<String, dynamic>>[];
  for (final d in app.data) {
    final path = paths.expand(d.path);
    final exists = FileSystemEntity.typeSync(path, followLinks: false) != FileSystemEntityType.notFound;
    if (!exists) continue;
    if (d.neverDelete) {
      data.add({'path': path, 'goes': false, 'why': d.sharedWithOmarchy ? 'shared with Omarchy (never deleted)' : 'never deleted${d.note == null ? '' : ' (${d.note})'}'});
    } else if (deleteSettings && unsafeReach(path, roots) != null) {
      data.add({'path': path, 'goes': false, 'why': unsafeReach(path, roots)});
    } else if (deleteSettings) {
      data.add({'path': path, 'goes': true});
      settingsGo.add(path);
    } else {
      data.add({'path': path, 'goes': false, 'why': 'user data (kept; "delete settings" removes it)'});
    }
  }
  final runtime = <Map<String, dynamic>>[];
  for (final r in app.runtime) {
    final info = StatusReader(ctx).pathInfo(r.path, glob: r.glob, marker: r.marker);
    if (info['exists'] != true) continue;
    runtime.add({'path': info['path'], if (r.glob) 'matches': info['matches'], 'markedOurs': ?info['markedOurs'], 'why': 'made at runtime (${r.note}); not removed by this step'});
    // Runtime things that outlive the app are told under "stays" with the reason.
    if (r.stays != null) {
      for (final path in r.glob ? (info['matches'] as List).cast<String>() : [info['path'] as String]) {
        stays.add({'path': path, 'why': r.stays, 'runtime': true, if (info['markedOurs'] == true) 'marked': true});
      }
    }
  }

  // The app's own steps (KDE): shown before they run.
  final recipe = app.removeRecipe == RemoveRecipe.none
      ? null
      : await recipePlan(ctx, app, receipt, keptTrees: keptTrees, checks: {for (final c in treeChecks) c.root: c});
  if (recipe != null) {
    stays.addAll(recipe.stays);
    blocked ??= recipe.blocked;
  }

  final displaced = Displaced.load(paths, app.id);
  // Put back only at the app's own catalog paths, never through a linked folder.
  final restores = [
    for (final e in displaced.entries)
      if (e['restore'] == true && known.containsKey(e['path']) && unsafeReach(e['path'] as String, roots) == null) e,
  ];
  final backups = [for (final e in displaced.entries) if (!restores.contains(e)) e];

  final status = StatusReader(ctx);
  final dependents = <Map<String, dynamic>>[];
  for (final other in catalog) {
    if (!other.dependsOn.contains(app.id)) continue;
    final states = [for (final c in other.components) (await status.component(other, c)).state];
    if (states.any((s) => s != InstallState.absent)) dependents.add({'id': other.id, 'name': other.name});
  }
  final barId = switch (ctx.desktop) {
    DesktopId.cosmic => app.bar.cosmicApplet,
    DesktopId.kde => app.bar.kdeId,
    DesktopId.other => null,
  };
  final procs = ctx.processes();
  final running = runningFor(app, paths, procs).length;

  final revision = sha256Text(jsonEncode([
    goes,
    settingsGo,
    restores.map((e) => e['path']).toList(),
    [for (final c in treeChecks) c.digest],
    [for (final s in recipe?.steps ?? const <RecipeStep>[]) s.toJson()],
    recipe?.goes ?? const [],
  ])).substring(0, 16);
  return RemovePlan(app, {
    'app': app.id,
    'name': app.name,
    'receipt': receipt != null ? 'valid' : (rec.error != null ? 'broken' : 'none'),
    if (rec.error != null) 'receiptError': rec.error,
    'verified': receipt != null,
    'goes': goes,
    'stays': stays,
    'data': data,
    'deleteSettings': deleteSettings,
    'runtime': runtime,
    'restores': [for (final e in restores) {'path': e['path'], 'backup': e['backup'], 'reason': e['reason']}],
    'backupsKept': [for (final e in backups) {'path': e['path'], 'backup': e['backup'], 'reason': e['reason']}],
    'dependents': dependents,
    'units': [for (final u in app.units) u.name],
    'running': running,
    'bar': {'has': barId != null, 'id': ?barId, if (barId != null) 'takenOut': true},
    'postSteps': ['gtk-update-icon-cache', 'update-desktop-database'],
    if (recipe != null) ...{
      'steps': [for (final s in recipe.steps) s.toJson()],
      'generated': recipe.goes,
      if (recipe.notes.isNotEmpty) 'notes': recipe.notes,
    },
    'blocked': ?blocked,
    'revision': revision,
  }, goes, settingsGo, restores, trees: treeChecks, recipe: recipe, blocked: blocked);
}

/// Maprisma (pacman): the package goes as a whole (`pkexec /usr/bin/pacman -R`), after its
/// provider service is stopped and disabled; its user data only with `delete_settings`.
Future<RemovePlan> _pacmanPlan(Ctx ctx, AppEntry app, {required bool deleteSettings}) async {
  final paths = ctx.paths;
  final roots = sharedRoots(paths);
  final pkg = app.version.pacman!;
  final status = StatusReader(ctx);
  final installed = await status.pacmanVersion(pkg);
  String? blocked;
  if (installed == null) {
    blocked = 'pacman not found';
  } else if (installed.isEmpty) {
    blocked = '$pkg is not installed (pacman -Q $pkg)';
  } else if (ctx.runner.which('pkexec') == null) {
    blocked = 'pkexec not found: it asks for the password pacman needs';
  }
  final goes = <Map<String, dynamic>>[
    if (installed != null && installed.isNotEmpty) {'path': pkg, 'kind': 'package', 'version': installed, 'note': 'pacman removes every file of the package'},
  ];
  final settingsGo = <String>[];
  final data = <Map<String, dynamic>>[];
  for (final d in app.data) {
    final path = paths.expand(d.path);
    if (FileSystemEntity.typeSync(path, followLinks: false) == FileSystemEntityType.notFound) continue;
    final unsafe = unsafeReach(path, roots);
    if (d.neverDelete) {
      data.add({'path': path, 'goes': false, 'why': d.sharedWithOmarchy ? 'shared with Omarchy (never deleted)' : 'never deleted'});
    } else if (deleteSettings && unsafe != null) {
      data.add({'path': path, 'goes': false, 'why': unsafe});
    } else if (deleteSettings) {
      data.add({'path': path, 'goes': true});
      settingsGo.add(path);
    } else {
      data.add({'path': path, 'goes': false, 'why': 'user data (kept; "delete settings" removes it)'});
    }
  }
  final stays = <Map<String, dynamic>>[
    for (final u in app.units)
      if (File(paths.expand(u.fileTemplate)).existsSync())
        {'path': paths.expand(u.fileTemplate), 'why': 'written by Maprisma itself: disabled, not deleted', 'runtime': true},
  ];
  final dependents = <Map<String, dynamic>>[];
  for (final other in catalog) {
    if (!other.dependsOn.contains(app.id)) continue;
    final states = [for (final c in other.components) (await status.component(other, c)).state];
    if (states.any((s) => s != InstallState.absent)) dependents.add({'id': other.id, 'name': other.name});
  }
  final steps = [
    for (final u in app.units)
      {'id': 'unit', 'title': 'Stop and disable ${u.name}', 'commands': ['systemctl --user stop ${u.name}', 'systemctl --user disable ${u.name}'], 'when': 'before'},
    {'id': 'package', 'title': 'Remove the package (a password dialog asks)', 'commands': ['pkexec /usr/bin/pacman -R --noconfirm $pkg'], 'when': 'before', 'required': true},
  ];
  final rec = readReceipt(paths, app.id);
  final revision = sha256Text(jsonEncode([goes, settingsGo, steps])).substring(0, 16);
  return RemovePlan(app, {
    'app': app.id,
    'name': app.name,
    'receipt': rec.receipt != null ? 'valid' : (rec.error != null ? 'broken' : 'none'),
    if (rec.error != null) 'receiptError': rec.error,
    'verified': installed != null && installed.isNotEmpty,
    'goes': goes,
    'stays': stays,
    'data': data,
    'deleteSettings': deleteSettings,
    'runtime': const [],
    'restores': const [],
    'backupsKept': const [],
    'dependents': dependents,
    'units': [for (final u in app.units) u.name],
    'running': runningFor(app, paths, ctx.processes()).length,
    'bar': {'has': false},
    'postSteps': const [],
    'steps': steps,
    'blocked': ?blocked,
    'revision': revision,
  }, goes, settingsGo, const [], blocked: blocked);
}
