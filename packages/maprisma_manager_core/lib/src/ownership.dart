/// What a job owns on disk: snapshots of the catalog's paths (hash, link target, mode,
/// existence), the cheap stat signature that tells when an install script starts writing, and
/// the displaced files' backups (plan: "Ownership").
library;

import 'translations.dart';


import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'bar_cosmic.dart' show atomicWrite;
import 'catalog.dart';
import 'paths.dart';

/// The `Hidden=` line of an autostart file is the bar state, not the install: it is left out
/// of that file's hash, so hiding the icon doesn't make the file "changed".
const normalizedHidden = 'hidden';

String sha256File(String path, {String? normalized}) {
  final bytes = File(path).readAsBytesSync();
  if (normalized == normalizedHidden) {
    final text = utf8.decode(bytes, allowMalformed: true);
    final kept = text.split('\n').where((l) => !RegExp(r'^\s*Hidden\s*=').hasMatch(l)).join('\n');
    return sha256.convert(utf8.encode(kept)).toString();
  }
  return sha256.convert(bytes).toString();
}

String sha256Text(String text) => sha256.convert(utf8.encode(text)).toString();
String sha256Bytes(List<int> bytes) => sha256.convert(bytes).toString();

/// One path as it is now: `{path, exists, type: file|link|dir|other, sha256?, link?, mode?}`.
Map<String, dynamic> pathState(String path, {bool hash = true, String? normalized}) {
  final type = FileSystemEntity.typeSync(path, followLinks: false);
  switch (type) {
    case FileSystemEntityType.notFound:
      return {'path': path, 'exists': false};
    case FileSystemEntityType.link:
      String? target;
      try {
        target = Link(path).targetSync();
      } on FileSystemException {
        target = null;
      }
      return {'path': path, 'exists': true, 'type': 'link', 'link': target};
    case FileSystemEntityType.directory:
      return {'path': path, 'exists': true, 'type': 'dir', 'mode': _mode(path)};
    case FileSystemEntityType.file:
      String? h;
      if (hash) {
        try {
          h = sha256File(path, normalized: normalized);
        } on FileSystemException {
          h = null;
        }
      }
      return {'path': path, 'exists': true, 'type': 'file', 'sha256': ?h, 'mode': _mode(path), 'normalized': ?normalized};
    default:
      return {'path': path, 'exists': true, 'type': 'other'};
  }
}

String? _mode(String path) {
  try {
    return (File(path).statSync().mode & 0xfff).toRadixString(8);
  } on FileSystemException {
    return null;
  }
}

/// A cheap signature of a path (type, size, mode, mtime, ctime, link target): it changes when a
/// script replaces, rewrites, chmods or deletes it. Used to find the start of the commit.
String statSignature(String path) {
  final type = FileSystemEntity.typeSync(path, followLinks: false);
  if (type == FileSystemEntityType.notFound) return '-';
  if (type == FileSystemEntityType.link) {
    try {
      return 'l:${Link(path).targetSync()}';
    } on FileSystemException {
      return 'l:?';
    }
  }
  try {
    final st = File(path).statSync();
    return '${type.toString()}:${st.size}:${st.mode}:${st.modified.microsecondsSinceEpoch}:${st.changed.microsecondsSinceEpoch}';
  } on FileSystemException {
    return '?';
  }
}

/// Every catalog path of [components], expanded (in catalog order, no duplicates).
List<(InstalledPath, String)> catalogPaths(Paths paths, Iterable<Component> components) {
  final seen = <String>{};
  return [
    for (final c in components)
      for (final ip in c.paths)
        if (seen.add(paths.expand(ip.path))) (ip, paths.expand(ip.path)),
  ];
}

/// The paths whose hash leaves out `Hidden=` (the app's KDE tray autostart file).
Set<String> normalizedPaths(Paths paths, AppEntry app) => {if (app.bar.kdeAutostart != null) paths.expand(app.bar.kdeAutostart!)};

Map<String, String> signatures(Iterable<String> paths) => {for (final path in paths) path: statSignature(path)};

/// The first path whose signature differs from [before], or null.
String? firstChanged(Map<String, String> before) {
  for (final e in before.entries) {
    if (statSignature(e.key) != e.value) return e.key;
  }
  return null;
}

// --- where removing may reach ---------------------------------------------------------------

/// The shared folders apps install into (never removed themselves).
Set<String> sharedRoots(Paths paths) => {
  for (final r in [
    paths.bin, paths.lib, paths.data, paths.homeShare, paths.apps, paths.icons, paths.autostart, paths.config,
    paths.state, paths.cache, paths.units, p.join(paths.homeShare, 'applications'),
    p.join(paths.homeShare, 'icons/hicolor/scalable/apps'), p.join(paths.data, 'kwin/scripts'),
    p.join(paths.data, 'plasma/plasmoids'), p.join(paths.data, 'dbus-1/services'), p.join(paths.home, '.config'),
  ])
    p.normalize(r),
};

/// Why [path] must not be touched by a remove, or null: it must lie below one of the shared roots
/// and no folder between that root and it may be a symlink (a linked folder would take the delete
/// somewhere else).
String? unsafeReach(String path, Set<String> roots) {
  final n = p.normalize(path);
  String? root;
  for (final r in roots) {
    if (p.isWithin(r, n) && (root == null || r.length > root.length)) root = r;
  }
  if (root == null) return tr('outside the folders apps install into');
  var d = p.dirname(n);
  while (d != root && p.isWithin(root, d)) {
    if (FileSystemEntity.isLinkSync(d)) return trf('reached through the linked folder {0}', [d]);
    d = p.dirname(d);
  }
  return null;
}

// --- files a remove kept ------------------------------------------------------------------

/// What a remove left in place (changed or foreign files): `kept/<app>.json`. Without a receipt
/// a later remove would take them as the catalog's; these are never taken.
String keptFile(Paths paths, String app) => p.join(paths.managerState, 'kept', '$app.json');

Map<String, Map<String, dynamic>> loadKept(Paths paths, String app) {
  try {
    final data = jsonDecode(File(keptFile(paths, app)).readAsStringSync());
    if (data is Map && data['paths'] is List) {
      return {for (final e in data['paths'] as List) if (e is Map && e['path'] is String) e['path'] as String: Map<String, dynamic>.from(e)};
    }
  } on FileSystemException {
    // none
  } on FormatException {
    // broken: none
  }
  return {};
}

// --- displaced files -------------------------------------------------------------------------

/// The displaced files of one app: `<state>/maprisma-settings/displaced/<app>/index.json`
/// `{"entries": [{path, backup?, link?, sha256?, mode?, restore, reason, at, job}]}`.
/// A file that existed at a catalog path and wasn't the Manager's (per the receipt) is copied here
/// before an install script runs; remove puts back those marked `restore`.
final class Displaced {
  Displaced(this.dir, this.entries);

  static String dirOf(Paths paths, String app) => p.join(paths.managerState, 'displaced', app);

  factory Displaced.load(Paths paths, String app) {
    final dir = dirOf(paths, app);
    try {
      final data = jsonDecode(File(p.join(dir, 'index.json')).readAsStringSync());
      if (data is Map && data['entries'] is List) {
        // Only well-formed entries: an absolute path, and a backup inside this folder (or a link).
        bool valid(Map e) {
          final path = e['path'], backup = e['backup'];
          if (path is! String || !p.isAbsolute(path) || p.normalize(path) != path) return false;
          if (backup == '(link)') return e['link'] is String;
          return backup is String && p.isWithin(dir, backup) && p.normalize(backup) == backup;
        }

        return Displaced(dir, [for (final e in data['entries'] as List) if (e is Map && valid(e)) Map<String, dynamic>.from(e)]);
      }
    } on FileSystemException {
      // none
    } on FormatException {
      // broken: start again (the backups stay on disk)
    }
    return Displaced(dir, []);
  }

  final String dir;
  final List<Map<String, dynamic>> entries;

  Map<String, dynamic>? of(String path) => entries.where((e) => e['path'] == path).firstOrNull;

  /// Backs up what is at [path] now ([state] from [pathState]). An earlier backup of the same
  /// path is kept (it is the older original). Returns the new entry, null when there was one.
  Map<String, dynamic>? add(String path, Map<String, dynamic> state, {required bool restore, required String reason, required String job, required DateTime at}) {
    if (of(path) != null) return null;
    final entry = <String, dynamic>{'path': path, 'restore': restore, 'reason': reason, 'at': at.toUtc().toIso8601String(), 'job': job};
    if (state['type'] == 'link') {
      entry['link'] = state['link'];
      entry['backup'] = '(link)';
    } else if (state['type'] == 'file') {
      Directory(dir).createSync(recursive: true);
      final name = '${sha256Text(path).substring(0, 16)}-${p.basename(path)}';
      final backup = p.join(dir, name);
      File(path).copySync(backup);
      entry['backup'] = backup;
      entry['sha256'] = state['sha256'];
      entry['mode'] = state['mode'];
    } else {
      return null; // folders and others are not backed up
    }
    entries.add(entry);
    return entry;
  }

  void drop(Map<String, dynamic> entry) {
    entries.remove(entry);
    final b = entry['backup'];
    if (b is String && b != '(link)' && p.isWithin(dir, b)) {
      try {
        File(b).deleteSync();
      } on FileSystemException {
        // already gone
      }
    }
  }

  void save() {
    if (entries.isEmpty) {
      try {
        File(p.join(dir, 'index.json')).deleteSync();
        if (Directory(dir).listSync().isEmpty) Directory(dir).deleteSync();
      } on FileSystemException {
        // nothing there
      }
      return;
    }
    atomicWrite(p.join(dir, 'index.json'), const JsonEncoder.withIndent('  ').convert({'entries': entries}));
  }

  /// Puts a backup back at its path (only when the path is free now). Returns whether it did.
  bool restoreEntry(Map<String, dynamic> e) {
    final path = e['path'] as String;
    if (FileSystemEntity.typeSync(path, followLinks: false) != FileSystemEntityType.notFound) return false;
    Directory(p.dirname(path)).createSync(recursive: true);
    if (e['link'] is String) {
      Link(path).createSync(e['link'] as String);
      return true;
    }
    final b = e['backup'];
    if (b is! String || !p.isWithin(dir, b) || FileSystemEntity.typeSync(b, followLinks: false) != FileSystemEntityType.file) return false;
    if (e['sha256'] is String && sha256File(b) != e['sha256']) return false; // not the file that was backed up
    File(b).copySync(path);
    final mode = e['mode'];
    if (mode is String) Process.runSync('chmod', [mode, path]);
    return true;
  }
}
