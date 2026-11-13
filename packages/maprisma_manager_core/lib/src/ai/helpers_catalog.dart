/// The AI helpers catalog shared with Maprisma: its `data/helpers.json`, made from its agent
/// adapters (Maprisma's docs/adapter-format.md, "The helpers export"). Ask AI offers every
/// entry with an `ask` (one prompt, one answer on stdout, no tools or read-only) whose program
/// is installed, in the catalog's order (its order of preference).
///
/// The catalog: Maprisma's installed `/usr/lib/maprisma/data/helpers.json` when it parses and is
/// at least as new (`version`) as the copy shipped here (`data/helpers.json`, built in by
/// tools/gen-helpers). The same rules as maprisma-notifier's helpers.rs.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'bounded.dart';
import 'helpers_shipped.g.dart';
import 'posix.dart';

const helperPrompt = '{prompt}';
const systemHelpersPath = '/usr/lib/maprisma/data/helpers.json';
const helpersCatalogMax = 1024 * 1024;

/// The longest prompt one argv element takes (Linux's MAX_ARG_STRLEN, 32 pages, with its NUL).
const argvPromptMax = 128 * 1024 - 1;

/// Where Maprisma's catalog is read from; tests point it elsewhere.
var systemHelpersCatalog = systemHelpersPath;

/// One catalog entry with an `ask`: [argv] starts with [command] and has a `{prompt}` element
/// (unless [stdin]: then the prompt goes on stdin).
typedef CatalogHelper = ({String id, String name, String command, List<String> argv, bool stdin, bool verified});
typedef HelpersCatalog = ({int version, List<CatalogHelper> helpers});

final _plain = RegExp(r'^[A-Za-z0-9_+][A-Za-z0-9._+-]{0,63}$');

/// An id or a command: a plain name (no path, no spaces, not an option).
bool plainHelperName(String text) => _plain.hasMatch(text);

CatalogHelper? _entry(Object? h) {
  if (h is! Map) return null;
  final id = h['id'], command = h['command'], ask = h['ask'];
  if (id is! String || !plainHelperName(id) || command is! String || !plainHelperName(command)) return null;
  if (ask is! Map || ask['argv'] is! List) return null;
  final raw = ask['argv'] as List;
  if (raw.isEmpty || raw.length > 64 || raw.any((a) => a is! String || a.contains('\x00'))) return null;
  final argv = [for (final a in raw) a as String];
  final stdin = ask['stdin'] == true;
  if (argv.first != command) return null;
  if (!stdin && !argv.skip(1).any((a) => a.contains(helperPrompt))) return null;
  final rawName = h['name'];
  var name = rawName is String ? rawName.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '').trim() : '';
  if (name.isEmpty) name = id;
  if (name.length > 64) name = name.substring(0, 64);
  return (id: id, name: name, command: command, argv: List.unmodifiable(argv), stdin: stdin, verified: h['verified'] == true);
}

/// A catalog; null when it isn't one. Entries without an `ask`, or with broken fields, are left
/// out; a repeated id counts once (the first).
HelpersCatalog? parseHelpersCatalog(String text) {
  Object? v;
  try {
    v = jsonDecode(text);
  } on FormatException {
    return null;
  }
  if (v is! Map || v['version'] is! int || v['helpers'] is! List) return null;
  final out = <CatalogHelper>[];
  for (final h in v['helpers'] as List) {
    final e = _entry(h);
    if (e != null && !out.any((o) => o.id == e.id)) out.add(e);
  }
  return (version: v['version'] as int, helpers: List.unmodifiable(out));
}

/// Maprisma's catalog when it is at least as new as the shipped one.
HelpersCatalog pickHelpersCatalog(HelpersCatalog? system, HelpersCatalog shipped) =>
    system != null && system.version >= shipped.version ? system : shipped;

HelpersCatalog get shippedHelpersCatalog => parseHelpersCatalog(shippedHelpersJson)!;

(String, DateTime, int, HelpersCatalog?)? _cached;

/// The catalog in use (Maprisma's file read again only when it changed).
HelpersCatalog helpersCatalog() {
  final path = systemHelpersCatalog;
  HelpersCatalog? system;
  try {
    final stat = File(path).statSync();
    final c = _cached;
    if (stat.type != FileSystemEntityType.file) {
      system = null;
    } else if (c != null && c.$1 == path && c.$2 == stat.modified && c.$3 == stat.size) {
      system = c.$4;
    } else {
      final bytes = Posix.instance.readRegular(path, helpersCatalogMax);
      system = bytes == null ? null : parseHelpersCatalog(utf8.decode(bytes, allowMalformed: true));
      _cached = (path, stat.modified, stat.size, system);
    }
  } on FileSystemException {
    system = null;
  }
  return pickHelpersCatalog(system, shippedHelpersCatalog);
}

bool _isProgram(String path) =>
    FileSystemEntity.isFileSync(path) && Posix.instance.executable(path);

/// mise's shims folder (`$MISE_DATA_DIR/shims`, by default `~/.local/share/mise/shims`).
String miseShims(String home, Map<String, String> environment) {
  final data = environment['MISE_DATA_DIR'] ?? '';
  if (data.startsWith('/')) return p.join(data, 'shims');
  final xdg = environment['XDG_DATA_HOME'] ?? '';
  return p.join(xdg.startsWith('/') ? xdg : p.join(home, '.local/share'), 'mise', 'shims');
}

/// A program: on PATH, in `~/.local/bin` or `~/.npm-global/bin`, else where mise has it
/// (`mise which`, asked only for a command mise has a shim for). Nothing that would install it
/// is ever run.
Future<String?> findHelperCommand(String command, String home, Map<String, String> environment) async {
  if (!plainHelperName(command)) return null;
  final onPath = which(command, environment);
  if (onPath != null) return onPath;
  for (final dir in const ['.local/bin', '.npm-global/bin']) {
    final candidate = p.join(home, dir, command);
    if (_isProgram(candidate)) return candidate;
  }
  if (command == 'mise') return null;
  final shim = p.join(miseShims(home, environment), command);
  if (FileSystemEntity.typeSync(shim, followLinks: false) == FileSystemEntityType.notFound) return null;
  final mise = await findHelperCommand('mise', home, environment);
  if (mise == null) return null;
  final out = (await readBoundedText(
    [mise, 'which', command],
    maxBytes: 4096,
    timeout: const Duration(seconds: 5),
    environment: environment,
  ))?.split('\n').first.trim();
  return out != null && out.isNotEmpty && p.isAbsolute(out) && _isProgram(out) ? out : null;
}

/// The argv of a catalog helper's Ask: [program] for its command, `{prompt}` replaced inside
/// single elements (never through a shell; NULs dropped). A prompt alone in an element never
/// starts with `-`, so it can't be read as an option. With `stdin` the `{prompt}` elements go
/// (the prompt is written to stdin).
List<String> catalogAskArgv(CatalogHelper h, String program, String prompt) {
  final clean = prompt.replaceAll('\x00', '');
  final lone = clean.startsWith('-') ? ' $clean' : clean;
  return [
    program,
    for (final a in h.argv.skip(1))
      if (!(h.stdin && a.contains(helperPrompt))) a == helperPrompt ? lone : a.replaceAll(helperPrompt, clean),
  ];
}
