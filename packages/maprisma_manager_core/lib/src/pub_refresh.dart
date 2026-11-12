// Dart/Flutter package folders of an app, and whether their package cache
// (.dart_tool/package_config.json) still fits the Flutter the Manager builds with.
//
// A `pub get` run with another Flutter (another machine sharing the disk, an agent with its
// own SDK) leaves a cache that points there; `flutter build` then can't find the Flutter
// libraries ("'Column' isn't defined") and doesn't fetch again by itself.

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'translations.dart';

const _skip = {'build', 'node_modules', 'target', 'linux', 'windows', 'macos', 'android', 'ios', 'web'};

/// Folders with a pubspec.yaml under [root] (itself and up to 3 levels down), not in build
/// output or hidden folders, sorted.
List<String> dartPackages(String root) {
  final out = <String>[];
  void walk(String dir, int depth) {
    if (FileSystemEntity.typeSync(dir, followLinks: false) != FileSystemEntityType.directory) return;
    if (File(p.join(dir, 'pubspec.yaml')).existsSync()) out.add(dir);
    if (depth >= 3) return;
    List<FileSystemEntity> children;
    try {
      children = Directory(dir).listSync(followLinks: false);
    } on FileSystemException {
      return;
    }
    children.sort((a, b) => a.path.compareTo(b.path));
    for (final c in children) {
      final name = p.basename(c.path);
      if (c is! Directory || name.startsWith('.') || _skip.contains(name)) continue;
      walk(c.path, depth + 1);
    }
  }

  walk(root, 0);
  return out;
}

/// A workspace member resolves in a folder above it: pub there could write outside the app.
bool isWorkspaceMember(String dir) {
  try {
    return RegExp(r'^resolution:\s*workspace', multiLine: true).hasMatch(File(p.join(dir, 'pubspec.yaml')).readAsStringSync());
  } on FileSystemException {
    return false;
  }
}

/// Whether [dir] needs Flutter (`sdk: flutter` in its pubspec) rather than plain Dart.
bool usesFlutter(String dir) {
  try {
    return RegExp(r'sdk:\s*flutter').hasMatch(File(p.join(dir, 'pubspec.yaml')).readAsStringSync());
  } on FileSystemException {
    return false;
  }
}

/// The SDK folder of [flutterExe] (the one with bin/flutter and packages/flutter), or null
/// when it can't be told (a wrapper script elsewhere, for example).
String? flutterRootOf(String? flutterExe) {
  if (flutterExe == null) return null;
  String exe;
  try {
    exe = File(flutterExe).resolveSymbolicLinksSync();
  } on FileSystemException {
    return null;
  }
  final root = p.dirname(p.dirname(exe));
  if (!Directory(p.join(root, 'packages', 'flutter')).existsSync()) return null;
  return _real(root);
}

String _real(String dir) {
  try {
    return Directory(dir).resolveSymbolicLinksSync();
  } on FileSystemException {
    return p.normalize(dir);
  }
}

/// Why [dir]'s package cache has to be fetched again before a build with [flutterRoot]
/// (from [flutterRootOf]), or null when it fits or there is none yet (a build makes it).
String? stalePackageCache(String dir, String? flutterRoot) {
  final f = File(p.join(dir, '.dart_tool', 'package_config.json'));
  if (!f.existsSync()) return null;
  Object? cfg;
  try {
    cfg = jsonDecode(f.readAsStringSync());
  } on Object {
    return tr('the package cache is not readable');
  }
  if (cfg is! Map) return tr('the package cache is not readable');
  String? path(Object? uri) {
    if (uri is! String || !uri.startsWith('file://')) return null;
    try {
      return Uri.parse(uri).toFilePath();
    } on Object {
      return null;
    }
  }

  final root = path(cfg['flutterRoot']);
  if (root != null) {
    if (!Directory(root).existsSync()) return trf('it points at a Flutter that is gone: {0}', [root]);
    if (flutterRoot != null && _real(root) != flutterRoot) return trf('it was made with another Flutter: {0}', [root]);
  }
  final packages = cfg['packages'];
  if (packages is List) {
    for (final pkg in packages) {
      final at = pkg is Map ? path(pkg['rootUri']) : null;
      if (at != null && !Directory(at).existsSync()) return trf('a package folder is gone: {0}', [at]);
    }
  }
  return null;
}
