/// What a job owns on disk: snapshots of the catalog's paths (hash, link target, mode,
/// existence), the cheap stat signature that tells when an install script starts writing, and
/// the displaced files' backups (plan: "Ownership").
library;

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

// --- displaced files -------------------------------------------------------------------------

/// The displaced files of one app: `<state>/maprisma-manager/displaced/<app>/index.json`
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
        return Displaced(dir, [for (final e in data['entries'] as List) if (e is Map && e['path'] is String) Map<String, dynamic>.from(e)]);
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
    if (b is String && b != '(link)') {
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
    if (b is! String || !File(b).existsSync()) return false;
    File(b).copySync(path);
    final mode = e['mode'];
    if (mode is String) Process.runSync('chmod', [mode, path]);
    return true;
  }
}
