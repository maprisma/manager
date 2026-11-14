/// The AI helper every Maprisma app uses (Launcher, Theme, Playground, Notifier and the Manager's
/// AI updates): `$XDG_CONFIG_HOME/maprisma-ai/settings.json`, a JSON object whose `helper` is
/// `"auto"` or a helper id (a catalog id like `claude`, or a local model like
/// `pi:<provider>/<model>`). A missing or broken file or value means "auto": the first installed
/// helper in the catalog's order that can do what the app needs. A chosen helper that isn't
/// installed (or can't do it) falls back to auto.
///
/// Writes keep every other key, go through a temporary file in the same folder and a rename;
/// the folder is 0700, the file 0600. When the file doesn't exist yet, the Manager seeds it once
/// from its old `ai_helper` setting ([seedSharedHelper]).
///
/// `web_search` (a boolean, missing or invalid = false): when an app can't find something (e.g.
/// an app to install), the helper may search the web and read pages — nothing else. Only helpers
/// with a web-only mode can do it ([webSearchHelpers]); the app checks every result itself.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../paths.dart';
import 'ask_ai.dart';
import 'posix.dart';

const sharedAiDir = 'maprisma-ai';
const sharedAuto = 'auto';
const sharedAiFileMax = 64 * 1024;

final _helperId = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:/@+-]{0,160}$');

/// `"auto"` or a helper id.
bool validSharedHelper(Object? value) => value is String && (value == sharedAuto || _helperId.hasMatch(value));

String sharedAiFile(Paths paths) => p.join(paths.config, sharedAiDir, 'settings.json');

/// The file's object; null when it is missing, too big or not a JSON object.
Map<String, dynamic>? _readObject(String path) {
  try {
    final f = File(path);
    if (FileSystemEntity.typeSync(path) != FileSystemEntityType.file || f.lengthSync() > sharedAiFileMax) return null;
    final v = jsonDecode(f.readAsStringSync());
    return v is Map<String, dynamic> ? v : null;
  } on FileSystemException {
    return null;
  } on FormatException {
    return null;
  }
}

/// The shared choice: "auto" or a helper id (missing or invalid → "auto").
String readSharedHelper(Paths paths) {
  final v = _readObject(sharedAiFile(paths))?['helper'];
  return validSharedHelper(v) ? v as String : sharedAuto;
}

/// Whether the shared file is there (any content).
bool sharedHelperExists(Paths paths) =>
    FileSystemEntity.typeSync(sharedAiFile(paths), followLinks: false) != FileSystemEntityType.notFound;

/// Saves [helper] ("auto" or an id) and keeps every other key of the file.
void writeSharedHelper(Paths paths, String helper) {
  if (!validSharedHelper(helper)) throw ArgumentError.value(helper, 'helper', '"auto" or a helper id');
  _writeKey(paths, 'helper', helper);
}

/// Whether the helper may search the web (missing or not a boolean → false).
bool readSharedWebSearch(Paths paths) => _readObject(sharedAiFile(paths))?['web_search'] == true;

/// Saves `web_search` and keeps every other key of the file.
void writeSharedWebSearch(Paths paths, bool on) => _writeKey(paths, 'web_search', on);

/// Whether [helper] (a resolved helper id, or null when none is ready) can search the web: it has
/// a web-only mode (only the tools that search the web and read pages, ask_ai.dart's
/// `Helper.web`). Only Claude Code for now (`--tools WebSearch,WebFetch`, nothing else).
bool helperCanSearchWeb(String? helper) => helper != null && canSearchWeb(helper);

/// The shared file's object (null when missing or invalid), for the other shared keys (rules.dart).
Map<String, dynamic>? readSharedObject(Paths paths) => _readObject(sharedAiFile(paths));

/// Whether the shared file exists but can't be read as a JSON object (docs/ask-ai-rules.md: the
/// rules are then restrictive, and nothing rewrites the file).
bool sharedFileBroken(Paths paths) {
  final path = sharedAiFile(paths);
  return FileSystemEntity.typeSync(path, followLinks: false) != FileSystemEntityType.notFound && _readObject(path) == null;
}

/// The shared file's lock (docs/ask-ai-rules.md), never renamed.
String sharedAiLock(Paths paths) => p.join(paths.config, sharedAiDir, 'settings.lock');

/// Saves one key of the shared file, keeping every other key.
void writeSharedKey(Paths paths, String key, Object value) => _writeKey(paths, key, value);

void _writeKey(Paths paths, String key, Object value) {
  final path = sharedAiFile(paths);
  final dir = Directory(p.dirname(path));
  dir.createSync(recursive: true);
  chmodPath(dir.path, 0x1c0); // 0700
  // Under the shared lock every app takes; an existing file that can't be read is never rebuilt
  // from one key (that would drop the user's rules).
  Posix.instance.withFlock(sharedAiLock(paths), () => _writeKeyLocked(path, dir, key, value));
}

void _writeKeyLocked(String path, Directory dir, String key, Object value) {
  if (FileSystemEntity.typeSync(path, followLinks: false) != FileSystemEntityType.notFound && _readObject(path) == null) {
    throw FileSystemException('the shared AI settings can\'t be read: not changed', path);
  }
  final values = {...?_readObject(path), key: value};
  final tmp = File(p.join(dir.path, '.settings.json.$pid.${DateTime.now().microsecondsSinceEpoch}.tmp'));
  try {
    final raf = tmp.openSync(mode: FileMode.writeOnly);
    try {
      if (!chmodPath(tmp.path, 0x180)) throw FileSystemException('chmod 0600 failed', tmp.path); // 0600
      raf.writeStringSync('${const JsonEncoder.withIndent('  ').convert(values)}\n');
      raf.flushSync();
    } finally {
      raf.closeSync();
    }
    tmp.renameSync(path);
  } on Object {
    if (tmp.existsSync()) tmp.deleteSync();
    rethrow;
  }
}

/// Migration: when the shared file doesn't exist yet, the Manager's old `ai_helper` setting (if
/// it is set and valid) becomes the shared choice. Returns whether it wrote the file.
bool seedSharedHelper(Paths paths, Settings settings) {
  if (sharedHelperExists(paths)) return false;
  final old = settings.str('ai_helper');
  if (old == null || !validSharedHelper(old)) return false;
  try {
    writeSharedHelper(paths, old);
    return true;
  } on FileSystemException {
    return false;
  }
}

/// The shared choice after the one-time seed.
String sharedHelper(Paths paths) {
  seedSharedHelper(paths, Settings.load(paths));
  return readSharedHelper(paths);
}

/// The helper to use from [ready] ids (in the catalog's order): the [choice] when it is ready,
/// else the first ready one; null when none is.
String? resolveHelper(String choice, List<String> ready) => ready.contains(choice) ? choice : ready.firstOrNull;
