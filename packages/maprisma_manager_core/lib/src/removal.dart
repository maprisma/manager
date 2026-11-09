/// The remove plan (`apps.remove_plan`): what goes, what stays and why, before anything is
/// deleted. The remove job re-plans and deletes exactly what the plan says goes.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'catalog.dart';
import 'context.dart';
import 'ownership.dart';
import 'procs.dart';
import 'receipts.dart';
import 'status.dart';

/// Why something stays (shown as such in the plan).
const whyChanged = 'changed since the Manager installed it';
const whyForeign = 'not what the Manager installed';
const whyNotInReceipt = 'not in the receipt';

final class RemovePlan {
  RemovePlan(this.app, this.json, this.goes, this.settingsGo, this.restores);
  final AppEntry app;
  final Map<String, dynamic> json;

  /// `{path, kind: file|link|dir, sha256?/link?, normalized?, unverified?}`
  final List<Map<String, dynamic>> goes;

  /// User data folders that go with `delete_settings`.
  final List<String> settingsGo;
  final List<Map<String, dynamic>> restores;

  String get revision => json['revision'] as String;
}

/// Refuses an app whose remove needs a step of its own that isn't there yet.
void checkRemovable(AppEntry app) {
  if (app.removal == Support.unsupportedYet) {
    throw RouteError('unsupported_yet', 'removing ${app.name} is not supported yet${app.supportNote == null ? '' : ': ${app.supportNote}'}');
  }
}

Future<RemovePlan> removePlan(Ctx ctx, AppEntry app, {bool deleteSettings = false}) async {
  checkRemovable(app);
  final paths = ctx.paths;
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
      if (inReceipt.contains(path)) continue;
      if (pathState(path, hash: false)['exists'] == true) stays.add({'path': path, 'why': whyNotInReceipt});
    }
  } else {
    // No receipt (installed before the Manager, or a broken one): the catalog's paths, marked
    // unverified; a link goes only when it points where the installer points it.
    for (final MapEntry(key: path, value: ip) in known.entries) {
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

  // User data: kept unless asked; data shared with Omarchy never goes.
  final settingsGo = <String>[];
  final data = <Map<String, dynamic>>[];
  for (final d in app.data) {
    final path = paths.expand(d.path);
    final exists = FileSystemEntity.typeSync(path, followLinks: false) != FileSystemEntityType.notFound;
    if (!exists) continue;
    if (d.neverDelete) {
      data.add({'path': path, 'goes': false, 'why': 'shared with Omarchy (never deleted)'});
    } else if (deleteSettings) {
      data.add({'path': path, 'goes': true});
      settingsGo.add(path);
    } else {
      data.add({'path': path, 'goes': false, 'why': 'user data (kept; "delete settings" removes it)'});
    }
  }
  final runtime = [
    for (final r in app.runtime)
      if (StatusReader(ctx).pathInfo(r.path, glob: r.glob, marker: r.marker) case final info when info['exists'] == true)
        {'path': info['path'], if (r.glob) 'matches': info['matches'], 'why': 'made at runtime (${r.note}); not removed by this step'},
  ];

  final displaced = Displaced.load(paths, app.id);
  final restores = [for (final e in displaced.entries) if (e['restore'] == true) e];
  final kept = [for (final e in displaced.entries) if (e['restore'] != true) e];

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

  final revision = sha256Text(jsonEncode([goes, settingsGo, restores.map((e) => e['path']).toList()])).substring(0, 16);
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
    'backupsKept': [for (final e in kept) {'path': e['path'], 'backup': e['backup'], 'reason': e['reason']}],
    'dependents': dependents,
    'units': [for (final u in app.units) u.name],
    'running': running,
    'bar': {'has': barId != null, 'id': ?barId, if (barId != null) 'takenOut': true},
    'postSteps': ['gtk-update-icon-cache', 'update-desktop-database'],
    'revision': revision,
  }, goes, settingsGo, restores);
}
