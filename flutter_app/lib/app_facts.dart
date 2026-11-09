/// What the list shows about an app, read from its `apps.list` entry (docs/protocol.md "App").
library;

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
  return [if (folder) 'Folder', if (githubUrl(a) != null) 'GitHub'];
}

/// New commits since the installed build, per where they are (for the update mark's tooltip).
({int folder, int upstream, int github}) newCommits(App a) {
  final u = a['updates'] as Map? ?? const {};
  var folder = 0;
  for (final i in ((a['sources'] as Map?)?['inputs'] as List?) ?? const []) {
    folder += _n((i as Map)['newSinceBuild']);
  }
  return (folder: folder, upstream: _n(u['upstreamNew']), github: _n(u['githubNew']));
}

/// The update mark's lines, empty = no mark. Only for an installed app.
List<String> updateReasons(App a) {
  if (!installed(a)) return const [];
  final u = a['updates'] as Map? ?? const {};
  final n = newCommits(a);
  String commits(int k) => k == 1 ? '1 new commit' : '$k new commits';
  final out = <String>[];
  if (n.github > 0) out.add('${commits(n.github)} on GitHub');
  if (n.upstream > 0 && n.upstream != n.github) out.add('${commits(n.upstream)} upstream');
  if (n.folder > 0) {
    out.add('${commits(n.folder)} in the folder');
  } else if (u['sourceDiffers'] == true) {
    final reasons = (u['sourceReasons'] as List?)?.cast<Object>().map((e) => '$e').where((e) => !e.startsWith('installed from release')).toList() ?? const [];
    if (reasons.isNotEmpty) out.add('The folder differs from the installed build (${reasons.join(', ')})');
  }
  final rel = u['releaseNew'] as Map?;
  if (rel != null) out.add('Release ${rel['tag']} is newer (installed ${rel['installed'] ?? 'unknown'})');
  return out;
}

/// Whether "Update" (pull and build) makes sense: new commits somewhere, or the folder differs.
bool canUpdate(App a) {
  if (!installed(a)) return false;
  final u = a['updates'] as Map? ?? const {};
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
      for (final m in (c['missingParts'] as List?) ?? const []) '$m',
];

List<String> prerequisitesMissing(App a) => {
  for (final c in (a['components'] as List?) ?? const [])
    if ((c as Map)['applies'] != false)
      for (final m in (c['prerequisitesMissing'] as List?) ?? const []) '$m',
}.toList();

/// A job that was interrupted or failed after it had started writing: Repair.
bool needsRepair(App a) => a['repair'] == true;

/// Which desktops it runs on, when not this one: "KDE only".
String? otherDesktopNote(App a) {
  if (supportedHere(a)) return null;
  final d = (a['desktops'] as List?)?.cast<Object>() ?? const [];
  return d.length == 1 ? '${d.single == 'kde' ? 'KDE' : d.single == 'cosmic' ? 'COSMIC' : d.single} only' : 'not for this desktop';
}

/// "left", "centre", "right" for a zone.
String zoneName(Object? z) => switch (z) {
  'left' => 'left',
  'center' => 'centre',
  'right' => 'right',
  _ => '$z',
};

/// The row's second line: kind, where its bar icon is, notes.
String subtitle(App a, String desktop) {
  final parts = <String>['${a['kind'] ?? ''}'];
  final bar = a['bar'] as Map? ?? const {};
  if (installed(a) && bar['has'] == true && desktop != 'other') {
    if (bar['state'] == 'in') {
      parts.add(bar['zone'] == null ? 'in the bar' : 'bar: ${zoneName(bar['zone'])}${bar['panel'] != null && bar['panel'] != 'Panel' ? ' (${bar['panel']})' : ''}');
    } else if (bar['state'] == 'unknown') {
      parts.add('bar state unknown');
    }
  }
  if (!installed(a)) {
    final repos = (a['repos'] as List?) ?? const [];
    final avail = repos.isEmpty ? null : (repos.first as Map)['available'];
    if (avail == 'cloneable') parts.add('cloned from GitHub when installed');
    if (avail == 'not available here') parts.add('not available here (no folder, not on GitHub)');
  }
  if (_n(a['running']) > 0 && installed(a)) parts.add('running');
  final other = otherDesktopNote(a);
  if (other != null) parts.add(other);
  return parts.where((p) => p.isNotEmpty).join(' · ');
}

/// The list's sections: by bar state on COSMIC and KDE, Installed / Not installed elsewhere.
List<(String, List<App>)> sections(List<App> apps, String desktop) {
  if (desktop == 'other') {
    return [
      ('Installed', [for (final a in apps) if (installed(a)) a]),
      ('Not installed', [for (final a in apps) if (!installed(a)) a]),
    ];
  }
  return [
    ('In the bar', [for (final a in apps) if (installed(a) && hasBar(a) && inBar(a)) a]),
    ('Not in the bar', [for (final a in apps) if (installed(a) && hasBar(a) && !inBar(a)) a]),
    ('No bar icon', [for (final a in apps) if (installed(a) && !hasBar(a)) a]),
    ('Not installed', [for (final a in apps) if (!installed(a)) a]),
  ];
}

/// The app's name and id match the filter (any case).
bool matches(App a, String query) {
  final q = query.toLowerCase().trim();
  if (q.isEmpty) return true;
  return '${a['name']}'.toLowerCase().contains(q) || '${a['id']}'.toLowerCase().contains(q);
}

String shortCommit(Object? c) => c is String && c.length > 8 ? c.substring(0, 8) : '${c ?? ''}';
