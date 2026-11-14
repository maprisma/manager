/// What the list shows about an app, read from its `apps.list` entry (docs/protocol.md "App").
library;

import 'package:maprisma_manager_core/maprisma_manager_core.dart' show canonicalAppId, selfApp, tr, trf, uiLabel;


typedef App = Map<String, dynamic>;

int _n(Object? v) => v is int ? v : 0;

bool installed(App a) => a['state'] == 'installed' || a['state'] == 'partial';
bool hasBar(App a) => (a['bar'] as Map?)?['has'] == true;
bool inBar(App a) => (a['bar'] as Map?)?['state'] == 'in';
bool supportedHere(App a) => a['supportedHere'] != false;
String? githubUrl(App a) => (a['sources'] as Map?)?['url'] as String?;

/// The main input's folder (present or not).
Map? mainFolder(App a) {
  final inputs = (a['sources'] as Map?)?['inputs'] as List?;
  return inputs == null || inputs.isEmpty ? null : (inputs.first as Map)['folder'] as Map?;
}

/// The latest release (as last checked), or null.
Map? latestRelease(App a) => (a['sources'] as Map?)?['release'] as Map?;

/// A release the Manager can install (Launcher, Maprisma).
bool releaseInstallable(App a) => ((a['sources'] as Map?)?['releaseInstall'] as Map?)?['supported'] == true && latestRelease(a) != null;

/// Which sources it has: `Folder`, `GitHub`.
List<String> sourceChips(App a) {
  final inputs = ((a['sources'] as Map?)?['inputs'] as List?) ?? const [];
  final folder = inputs.isNotEmpty && ((inputs.first as Map)['folder'] as Map?)?['present'] == true;
  return [if (folder) tr('Folder'), if (githubUrl(a) != null) tr('GitHub')];
}

/// New commits since the installed build, per where they are (for the update mark's tooltip).
({int folder, int upstream, int github}) newCommits(App a) {
  final u = a['updates'] as Map? ?? const {};
  var folder = 0;
  for (final i in ((a['sources'] as Map?)?['inputs'] as List?) ?? []) {
    folder += _n((i as Map)['newSinceBuild']);
  }
  return (folder: folder, upstream: _n(u['upstreamNew']), github: _n(u['githubNew']));
}

/// The update mark's lines, empty = no mark. Only for an installed app.
List<String> updateReasons(App a) {
  if (!installed(a)) return const [];
  final u = a['updates'] as Map? ?? {};
  final n = newCommits(a);
  String commits(int k) => k == 1 ? tr('1 new commit') : trf('{0} new commits', [k]);
  final out = <String>[];
  if (n.github > 0) out.add(trf('{0} on GitHub', [commits(n.github)]));
  if (n.upstream > 0 && n.upstream != n.github) out.add(trf('{0} upstream', [commits(n.upstream)]));
  if (n.folder > 0) {
    out.add(trf('{0} in the folder', [commits(n.folder)]));
  } else if (u['sourceDiffers'] == true) {
    final reasons = (u['sourceReasons'] as List?)?.cast<Object>().map((e) => '$e').where((e) => !e.startsWith(trf('installed from release {0}', ['']))).toList() ?? [];
    if (reasons.isNotEmpty) out.add(trf('The folder differs from the installed build ({0})', [reasons.join(', ')]));
  }
  final rel = u['releaseNew'] as Map?;
  if (rel != null) out.add(trf('Release {0} is newer (installed {1})', [rel['tag'], rel['installed'] ?? tr('unknown')]));
  return out;
}

/// Whether "Update" (pull and build) makes sense: new commits somewhere, or the folder differs.
bool canUpdate(App a) {
  if (!installed(a)) return false;
  final u = a['updates'] as Map? ?? {};
  final n = newCommits(a);
  return n.github > 0 || n.upstream > 0 || n.folder > 0 || u['sourceDiffers'] == true;
}

/// The newer release to install (`{tag, version, installed, installable}`), or null.
Map? newerRelease(App a) {
  final rel = (a['updates'] as Map?)?['releaseNew'] as Map?;
  return rel != null && rel['installable'] == true ? rel : null;
}

bool buildUnknown(App a) => (a['updates'] as Map?)?['buildUnknown'] == true;

/// Parts that weren't installed (`partial`): "settings window" …
List<String> missingParts(App a) => [
  for (final c in (a['components'] as List?) ?? const [])
    if ((c as Map)['applies'] != false)
      for (final m in (c['missingParts'] as List?) ?? const []) uiLabel(m),
];

List<String> prerequisitesMissing(App a) => {
  for (final c in (a['components'] as List?) ?? [])
    if ((c as Map)['applies'] != false)
      for (final m in (c['prerequisitesMissing'] as List?) ?? []) '$m',
}.toList();

/// A job that was interrupted or failed after it had started writing: Repair.
bool needsRepair(App a) => a['repair'] == true;

/// Which desktops it runs on, when not this one: "KDE only".
String? otherDesktopNote(App a) {
  if (supportedHere(a)) return null;
  final d = (a['desktops'] as List?)?.cast<Object>() ?? const [];
  return d.length == 1 ? trf('{0} only', [d.single == 'kde' ? 'KDE' : d.single == 'cosmic' ? 'COSMIC' : d.single == 'hyprland' ? 'Hyprland' : d.single]) : tr('not for this desktop');
}

/// "left", "centre", "right" for a zone.
String zoneName(Object? z) => switch (z) {
  'left' => tr('left'),
  'center' => tr('centre'),
  'right' => tr('right'),
  _ => '$z',
};

/// The row's second line: kind, where its bar icon is, notes.
String subtitle(App a, String desktop) {
  final parts = <String>['${a['kind'] ?? ''}'];
  final bar = a['bar'] as Map? ?? const {};
  if (installed(a) && bar['has'] == true && desktop != 'other') {
    if (bar['state'] == 'in') {
      parts.add(bar['zone'] == null ? tr('in the bar') : trf('bar: {0}{1}', [zoneName(bar['zone']), bar['panel'] != null && bar['panel'] != 'Panel' ? ' (${bar['panel']})' : '']));
    } else if (bar['state'] == 'unknown') {
      parts.add(tr('bar state unknown'));
    }
  }
  if (!installed(a)) {
    final repos = (a['repos'] as List?) ?? [];
    final avail = repos.isEmpty ? null : (repos.first as Map)['available'];
    if (avail == 'cloneable') parts.add(tr('cloned from GitHub when installed'));
    if (avail == 'not available here') parts.add(tr('not available here (no folder, not on GitHub)'));
  }
  final via = a['barVia'];
  if (installed(a) && via is Map && desktop != 'other') parts.add(trf('bar icon: {0}', ['${via['name']}']));
  if (_n(a['running']) > 0 && installed(a)) parts.add(tr('running'));
  final other = otherDesktopNote(a);
  if (other != null) parts.add(other);
  return parts.where((p) => p.isNotEmpty).join(' · ');
}

/// The list's sections: by bar state on COSMIC and KDE, Installed / Not installed elsewhere.
List<(String, List<App>)> sections(List<App> apps, String desktop) {
  if (desktop == 'other') {
    return [
      (tr('Installed'), [for (final a in apps) if (installed(a)) a]),
      (tr('Not installed'), [for (final a in apps) if (!installed(a)) a]),
    ];
  }
  // An app whose bar icon is another app's ([barVia]) follows that app, when both are installed.
  final byId = {for (final a in apps) '${a['id']}': a};
  App? hostOf(App a) {
    final via = a['barVia'];
    final h = via is Map ? byId['${via['id']}'] : null;
    return h != null && installed(a) && installed(h) && hasBar(h) ? h : null;
  }
  final guests = <String, List<App>>{};
  for (final a in apps) {
    final h = hostOf(a);
    if (h != null) guests.putIfAbsent('${h['id']}', () => []).add(a);
  }
  List<App> pick(bool Function(App) test) => [
    for (final a in apps)
      if (hostOf(a) == null && test(a)) ...[a, ...?guests['${a['id']}']],
  ];
  return [
    (tr('In the bar'), pick((a) => installed(a) && hasBar(a) && inBar(a))),
    (tr('Not in the bar'), pick((a) => installed(a) && hasBar(a) && !inBar(a))),
    (tr('No bar icon'), pick((a) => installed(a) && !hasBar(a))),
    (tr('Not installed'), pick((a) => !installed(a))),
  ];
}

/// The app's name and id match the filter (any case).
bool matches(App a, String query) {
  final q = query.toLowerCase().trim();
  if (q.isEmpty) return true;
  return '${a['name']}'.toLowerCase().contains(q) || '${a['id']}'.toLowerCase().contains(q);
}

String shortCommit(Object? c) => c is String && c.length > 8 ? c.substring(0, 8) : '${c ?? ''}';

/// One step of "Update all": the job to start for an app.
typedef UpdateStep = ({App app, String kind, Map<String, dynamic> options});

/// Whether the job asks for the password (pkexec): Maprisma's pacman package.
bool needsPassword(App a) => a['id'] == 'maprisma' || '${a['kind']}'.contains('pacman');

/// "Update all": every installed app of this desktop with an update mark (Update) or only a newer
/// release (that release), and the ones left out with why. Uncommitted changes in a folder are
/// never built by it (someone works there), an interrupted job needs Repair first. The password
/// apps come first (the dialog shows while you are still there), Maprisma Settings itself last
/// (its update restarts this window when the others have ended).
({List<UpdateStep> steps, List<(App, String)> skipped}) updateAllPlan(List<App> apps) {
  final steps = <UpdateStep>[];
  final skipped = <(App, String)>[];
  for (final a in apps) {
    final update = canUpdate(a);
    final rel = newerRelease(a);
    if (!installed(a) || (!update && rel == null)) continue;
    if (!supportedHere(a)) continue; // its mark is for another desktop
    if (needsRepair(a)) {
      skipped.add((a, tr('needs Repair first')));
      continue;
    }
    final dirty = [for (final r in (a['repos'] as List?) ?? const []) if ((r as Map)['dirty'] == true) '${r['repo'] ?? r['name'] ?? ''}'];
    if (update && dirty.isNotEmpty) {
      skipped.add((a, trf('uncommitted changes in {0}', [dirty.where((d) => d.isNotEmpty).join(', ')])));
      continue;
    }
    steps.add(update ? (app: a, kind: 'update', options: const {}) : (app: a, kind: 'release', options: {'tag': rel!['tag']}));
  }
  int rank(UpdateStep s) => canonicalAppId('${s.app['id']}') == selfApp ? 2 : (needsPassword(s.app) ? 0 : 1);
  final ordered = [for (final (i, s) in steps.indexed) (i, s)]..sort((x, y) => rank(x.$2) != rank(y.$2) ? rank(x.$2) - rank(y.$2) : x.$1 - y.$1);
  return (steps: [for (final (_, s) in ordered) s], skipped: skipped);
}
