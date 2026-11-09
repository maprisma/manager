/// Whole-tree ownership (step 5a; Codex step-3 finding #13): a folder an installer fills as a
/// whole (a Flutter bundle, a backend, a KWin script package) is recorded in the receipt as a
/// manifest of every entry below it (`{p, sha256, mode}` / `{p, link}` / `{p, dir}`), bounded in
/// size. A remove deletes only entries that are still what the manifest says, plus Python's
/// byte-code caches (`__pycache__/*.pyc`, made from the tree's own files), then the folders left
/// empty; everything else stays and is listed. Leftovers of atomic-swap installers
/// (`<root>.new.XXXXXX`, `<root>.old.XXXXXX`) go only when they hold nothing but the manifest's
/// files.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'ownership.dart';

/// At most this many entries per tree; a bigger one is recorded as `overflow` and never removed.
const maxTreeEntries = 20000;

/// At most this many "stays" entries per tree in a plan (the rest is counted).
const maxTreeStays = 100;

/// A relative entry path as a manifest holds it: normalized, no `..`, not absolute.
bool validRel(Object? v) =>
    v is String && v.isNotEmpty && !p.isAbsolute(v) && p.normalize(v) == v && !p.split(v).contains('..') && v != '.';

/// A derived byte-code cache Python writes next to the tree's own modules.
bool isPyCache(String rel) {
  final parts = p.split(rel);
  return parts.length >= 2 && parts[parts.length - 2] == '__pycache__' && (rel.endsWith('.pyc') || rel.endsWith('.pyo'));
}

/// The digest of a manifest's entries (stored with it; a receipt whose digest differs is broken).
String manifestDigest(List<Map<String, dynamic>> entries) => sha256Text(jsonEncode(entries));

/// The manifest of [root] as it is now: `{root, files, links, dirs, bytes, entries, digest}` or
/// `{root, overflow: true, files}` past [maxTreeEntries]; null when [root] isn't a real folder.
Map<String, dynamic>? treeManifest(String root, {int max = maxTreeEntries}) {
  if (FileSystemEntity.typeSync(root, followLinks: false) != FileSystemEntityType.directory) return null;
  final entries = <Map<String, dynamic>>[];
  var files = 0, links = 0, dirs = 0, bytes = 0, count = 0;
  final all = Directory(root).listSync(recursive: true, followLinks: false)..sort((a, b) => a.path.compareTo(b.path));
  for (final e in all) {
    count++;
    if (count > max) return {'root': root, 'overflow': true, 'files': all.length};
    final rel = p.relative(e.path, from: root);
    if (isPyCache(rel)) continue; // derived, made at runtime
    final st = pathState(e.path);
    switch (st['type']) {
      case 'file':
        files++;
        bytes += File(e.path).lengthSync();
        entries.add({'p': rel, 'sha256': st['sha256'], 'mode': st['mode']});
      case 'link':
        links++;
        entries.add({'p': rel, 'link': st['link']});
      case 'dir':
        if (p.basename(rel) == '__pycache__') continue;
        dirs++;
        entries.add({'p': rel, 'dir': true});
      default:
        break; // sockets, fifos: not an installer's
    }
  }
  return {'root': root, 'files': files, 'links': links, 'dirs': dirs, 'bytes': bytes, 'entries': entries, 'digest': manifestDigest(entries)};
}

/// Checks a receipt's tree record; throws [FormatException] when it isn't well-formed.
void validateTree(Map e) {
  final root = e['root'];
  if (root is! String || !p.isAbsolute(root) || p.normalize(root) != root) throw const FormatException('trees.root');
  if (e['overflow'] == true) return;
  final entries = e['entries'];
  if (entries is! List || entries.length > maxTreeEntries) throw const FormatException('trees.entries');
  for (final x in entries) {
    if (x is! Map || !validRel(x['p'])) throw const FormatException('trees entry');
    final kinds = [
      if (x.containsKey('sha256')) x['sha256'] is String && RegExp(r'^[0-9a-f]{64}$').hasMatch(x['sha256']),
      if (x.containsKey('link')) x['link'] is String && (x['link'] as String).isNotEmpty,
      if (x.containsKey('dir')) x['dir'] == true,
    ];
    if (kinds.length != 1 || !kinds.single) throw const FormatException('trees entry kind');
  }
  final list = [for (final x in entries) Map<String, dynamic>.from(x as Map)];
  if (e['digest'] != manifestDigest(list)) throw const FormatException('trees.digest');
  if (e['preexisting'] != null && e['preexisting'] is! bool) throw const FormatException('trees.preexisting');
}

/// What a remove of one tree would do now.
final class TreeCheck {
  TreeCheck(this.root);
  final String root;

  /// Files and links that go (absolute), with what they must still be right before the delete.
  final goes = <({String path, String? sha256, String? link})>[];

  /// Folders below the root, deepest first (removed only when empty), then the root.
  final dirs = <String>[];
  final stays = <Map<String, dynamic>>[];
  int derived = 0, bytes = 0;

  bool get whole => stays.isEmpty;

  /// A stable summary for the plan's revision.
  String get digest => sha256Text(jsonEncode([
    for (final g in goes) [g.path, g.sha256, g.link],
    for (final s in stays) [s['path'], s['why']],
  ]));

  Map<String, dynamic> goesJson({bool leftover = false}) => {
    'path': root,
    'kind': 'tree',
    'files': goes.where((g) => g.sha256 != null).length,
    'links': goes.where((g) => g.link != null).length,
    'bytes': bytes,
    if (derived > 0) 'derived': derived,
    if (leftover) 'leftover': true,
    'whole': whole,
  };
}

/// Compares [root] with a manifest's [entries]: an entry goes only while it is what the manifest
/// says (files by sha256, links by target, never followed); `__pycache__/*.pyc` go as derived;
/// anything else stays with the reason.
TreeCheck checkTree(String root, List<Map<String, dynamic>> entries, {required String Function(String rel) foreignWhy}) {
  final c = TreeCheck(root);
  if (FileSystemEntity.typeSync(root, followLinks: false) != FileSystemEntityType.directory) return c;
  final want = {for (final e in entries) e['p'] as String: e};
  final all = Directory(root).listSync(recursive: true, followLinks: false)..sort((a, b) => a.path.compareTo(b.path));
  final dirs = <String>[];
  var extra = 0;
  void stay(String path, String why) {
    if (c.stays.length < maxTreeStays) {
      c.stays.add({'path': path, 'why': why});
    } else {
      extra++;
    }
  }

  for (final e in all) {
    final rel = p.relative(e.path, from: root);
    final w = want[rel];
    final type = FileSystemEntity.typeSync(e.path, followLinks: false);
    if (type == FileSystemEntityType.directory) {
      dirs.add(e.path);
      continue;
    }
    if (type == FileSystemEntityType.file) {
      final h = sha256File(e.path);
      if (w != null && w['sha256'] == h) {
        c.goes.add((path: e.path, sha256: h, link: null));
        c.bytes += File(e.path).lengthSync();
      } else if (w == null && isPyCache(rel)) {
        c.goes.add((path: e.path, sha256: h, link: null));
        c.derived++;
      } else {
        stay(e.path, w == null ? foreignWhy(rel) : (w['sha256'] != null ? 'changed since the Manager installed it' : 'not what the Manager installed'));
      }
    } else if (type == FileSystemEntityType.link) {
      final t = Link(e.path).targetSync();
      if (w != null && w['link'] == t) {
        c.goes.add((path: e.path, sha256: null, link: t));
      } else {
        stay(e.path, w == null ? foreignWhy(rel) : 'the link points elsewhere now');
      }
    } else {
      stay(e.path, 'not a file the Manager installed');
    }
  }
  if (extra > 0) c.stays.add({'path': root, 'why': '$extra more path(s) in it stay (changed or not the Manager\'s)'});
  dirs.sort((a, b) => p.split(b).length.compareTo(p.split(a).length));
  c.dirs
    ..addAll(dirs)
    ..add(root);
  return c;
}

/// The leftovers of an interrupted installer next to [root]: an atomic swap's
/// `<name>.new.XXXXXX` / `<name>.old.XXXXXX` ([swap]), a staging copy `<name>.new` ([staged]).
List<String> swapLeftovers(String root, {bool swap = true, bool staged = false}) {
  final parent = Directory(p.dirname(root));
  if (!parent.existsSync() || (!swap && !staged)) return const [];
  final name = RegExp.escape(p.basename(root));
  final alts = [if (swap) r'\.(new|old)\.[A-Za-z0-9]{6}', if (staged) r'\.new'];
  final re = RegExp('^$name(${alts.join('|')})\$');
  return [
    for (final e in parent.listSync(followLinks: false))
      if (re.hasMatch(p.basename(e.path)) && FileSystemEntity.typeSync(e.path, followLinks: false) == FileSystemEntityType.directory) e.path,
  ]..sort();
}
