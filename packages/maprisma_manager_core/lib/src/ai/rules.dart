/// Ask AI rules, shared by every Maprisma app (docs/ask-ai-rules.md): the `ask_ai` key of
/// `maprisma-ai/settings.json` (level, actions, sources, folders) and the log of what Ask AI
/// changed, `$XDG_STATE_HOME/maprisma-ai/actions.jsonl`. Only Settings writes `ask_ai`; every app
/// reads it and enforces it in its own core.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../paths.dart';
import 'posix.dart';
import 'shared_helper.dart';

/// Overall level: actions allowed by the switches (each with its review), or answers only.
const askAiLevels = ['review', 'answers'];

/// One switchable thing on the AI page.
typedef AskAiItem = ({String id, String app, String label});

/// Every action Ask AI can run (docs/ask-ai-rules.md); the page lists them in this order.
const List<AskAiItem> askAiActions = [
  (id: 'launcher.install', app: 'launcher', label: 'Install apps'),
  (id: 'launcher.remove', app: 'launcher', label: 'Uninstall apps'),
  (id: 'launcher.update', app: 'launcher', label: 'Update apps'),
  (id: 'launcher.update_system', app: 'launcher', label: 'Update the system'),
  (id: 'launcher.hide', app: 'launcher', label: 'Hide and unhide apps'),
  (id: 'launcher.shortcuts', app: 'launcher', label: 'Change keyboard shortcuts'),
  (id: 'theme.apply', app: 'theme', label: 'Apply a theme or wallpaper'),
  (id: 'theme.install', app: 'theme', label: 'Install themes from the catalog'),
  (id: 'theme.edit', app: 'theme', label: 'Create and save custom themes'),
  (id: 'theme.generate', app: 'theme', label: 'Generate pictures'),
  (id: 'theme.wallpapers', app: 'theme', label: 'Add wallpapers'),
  (id: 'settings.updates', app: 'settings', label: 'Update Maprisma apps'),
];

/// Install sources of the Launcher's Ask AI.
const List<AskAiItem> askAiSources = [
  (id: 'pacman', app: 'launcher', label: 'Official repositories (pacman)'),
  (id: 'aur', app: 'launcher', label: 'AUR'),
  (id: 'flatpak', app: 'launcher', label: 'Flatpak'),
  (id: 'apt', app: 'launcher', label: 'apt'),
  (id: 'dnf', app: 'launcher', label: 'dnf'),
  (id: 'zypper', app: 'launcher', label: 'zypper'),
  (id: 'snap', app: 'launcher', label: 'Snap'),
  (id: 'github', app: 'launcher', label: 'GitHub releases'),
  (id: 'local', app: 'launcher', label: 'AppImages in Downloads'),
];

/// Folders Ask AI may look into.
const List<AskAiItem> askAiFolders = [
  (id: 'downloads', app: 'launcher', label: 'Downloads (AppImages to install)'),
];

/// Steps that only answer (no switch; listed so the page shows the whole picture).
const List<AskAiItem> askAiAnswers = [
  (id: 'launcher.answers', app: 'launcher', label: 'Suggest and explain apps'),
  (id: 'theme.answers', app: 'theme', label: 'Suggest themes and wallpapers'),
  (id: 'notifier.check', app: 'notifier', label: 'Check a crash notification'),
  (id: 'playground.chat', app: 'playground', label: 'Chat'),
];

final _id = RegExp(r'^[a-z][a-z0-9_.]{0,63}$');

/// The `ask_ai` object as stored (unknown ids kept); defaults when missing or invalid.
({String level, Map<String, bool> actions, Map<String, bool> sources, Map<String, bool> folders, bool broken})
    readAskAiRules(Paths paths) {
  // An existing file that can't be read, or an ask_ai that isn't an object: restrictive.
  if (sharedFileBroken(paths)) return (level: 'answers', actions: {}, sources: {}, folders: {}, broken: true);
  final whole = readSharedObject(paths);
  // Missing = defaults; present but not an object (null too) = restrictive (contract).
  if (whole == null || !whole.containsKey('ask_ai')) {
    return (level: 'review', actions: {}, sources: {}, folders: {}, broken: false);
  }
  final raw = whole['ask_ai'];
  if (raw is! Map) return (level: 'answers', actions: {}, sources: {}, folders: {}, broken: true);
  var broken = false;
  // Malformed values are restrictive (docs/ask-ai-rules.md): a map that isn't an object switches
  // all of its kind off, a known id with a non-boolean value is off.
  Map<String, bool> map(String key, List<AskAiItem> known) {
    if (!raw.containsKey(key)) return {};
    final v = raw[key];
    if (v is! Map) {
      broken = true;
      return {for (final i in known) i.id: false};
    }
    final out = <String, bool>{};
    for (final e in v.entries) {
      if (e.key is! String || !_id.hasMatch(e.key as String)) continue;
      if (e.value is bool) {
        out[e.key as String] = e.value as bool;
      } else if (known.any((i) => i.id == e.key)) {
        broken = true;
        out[e.key as String] = false;
      }
    }
    return out;
  }

  final level = raw['level'];
  final actions = map('actions', askAiActions), sources = map('sources', askAiSources), folders = map('folders', askAiFolders);
  final hasLevel = raw.containsKey('level');
  if (hasLevel && !askAiLevels.contains(level)) broken = true;
  return (
    level: !hasLevel ? 'review' : (askAiLevels.contains(level) ? level as String : 'answers'),
    actions: actions,
    sources: sources,
    folders: folders,
    broken: broken,
  );
}

/// The decision every app makes (here for Settings' own AI updates and the page's summary).
bool askAiAllowed(Paths paths, String action, {String? source}) {
  final r = readAskAiRules(paths);
  return r.level != 'answers' &&
      r.actions[action] != false &&
      (source == null || r.sources[source] != false) &&
      (source != 'local' || r.folders['downloads'] != false);
}

/// Changes one switch (`kind` actions/sources/folders) or the level, keeping every other key.
void writeAskAiRule(Paths paths, {String? level, String? kind, String? id, bool? on}) {
  final r = readAskAiRules(paths);
  final next = {
    'level': r.level,
    'actions': {...r.actions},
    'sources': {...r.sources},
    'folders': {...r.folders},
  };
  if (level != null) {
    if (!askAiLevels.contains(level)) throw ArgumentError.value(level, 'level');
    next['level'] = level;
  }
  if (kind != null) {
    final known = switch (kind) {
      'actions' => askAiActions,
      'sources' => askAiSources,
      'folders' => askAiFolders,
      _ => throw ArgumentError.value(kind, 'kind'),
    };
    if (id == null || !known.any((i) => i.id == id) || on == null) throw ArgumentError.value(id, 'id');
    (next[kind] as Map<String, bool>)[id] = on;
  }
  writeSharedKey(paths, 'ask_ai', next);
}

/// Resets the rules to the defaults (the page's answer to a broken file): writes a fresh file that
/// keeps nothing of the unreadable one except what can't be lost (helper → auto).
void resetAskAiRules(Paths paths) {
  final path = sharedAiFile(paths);
  Posix.instance.withFlock(sharedAiLock(paths), () {
    if (sharedFileBroken(paths)) File(path).renameSync('$path.broken-${DateTime.now().millisecondsSinceEpoch}');
  });
  writeSharedKey(paths, 'ask_ai', {'level': 'review', 'actions': {}, 'sources': {}, 'folders': {}});
}

// ---------------------------------------------------------------- the log

const askAiLogMax = 1000, askAiLogKeep = 500, askAiLogBytes = 1 << 20;

String askAiLogFile(Paths paths) => p.join(paths.state, sharedAiDir, 'actions.jsonl');

String askAiLogLock(Paths paths) => p.join(paths.state, sharedAiDir, 'actions.lock');

/// Appends one entry under the log's lock (docs/ask-ai-rules.md: lock first, then open the data
/// file; trim to the newest [askAiLogKeep] above [askAiLogMax]). A failure never stops a step.
void appendAskAiLog(Paths paths,
    {required String op, required String app, required String action, required String target, required String result}) {
  final path = askAiLogFile(paths);
  try {
    final dir = Directory(p.dirname(path))..createSync(recursive: true);
    // a real folder of the user (no link), else nothing is logged
    if (FileSystemEntity.typeSync(dir.path, followLinks: false) != FileSystemEntityType.directory ||
        Posix.instance.ownerOf(dir.path, follow: false) != Posix.instance.uid) {
      return;
    }
    chmodPath(dir.path, 0x1c0);
    Posix.instance.withFlock(askAiLogLock(paths), () {
      if (FileSystemEntity.typeSync(path, followLinks: false) == FileSystemEntityType.link) return;
      final entry = {
        'time': DateTime.now().toUtc().toIso8601String().replaceFirst(RegExp(r'\.\d+Z$'), 'Z'),
        'op': op,
        'app': app,
        'action': action,
        'target': target.length > 200 ? target.substring(0, 200) : target,
        'result': result,
      };
      final raf = File(path).openSync(mode: FileMode.append);
      try {
        chmodPath(path, 0x180);
        raf.writeStringSync('${jsonEncode(entry)}\n');
        raf.flushSync();
      } finally {
        raf.closeSync();
      }
      final data = File(path);
      final lines = data.readAsStringSync().split('\n');
      final complete = lines.sublist(0, lines.length - 1); // the part after the last newline is incomplete
      if (complete.length > askAiLogMax || data.lengthSync() > askAiLogBytes) {
        final keep = complete.length > askAiLogKeep ? complete.sublist(complete.length - askAiLogKeep) : complete;
        final tmp = File(p.join(dir.path, '.actions.${DateTime.now().microsecondsSinceEpoch}.tmp'));
        if (tmp.existsSync()) return; // O_EXCL by name: never write into a file that is already there
        final out = tmp.openSync(mode: FileMode.writeOnly);
        try {
          chmodPath(tmp.path, 0x180);
          out.writeStringSync('${keep.join('\n')}\n');
          out.flushSync();
        } finally {
          out.closeSync();
        }
        tmp.renameSync(path);
      }
    });
  } on FileSystemException {
    // a record only
  }
}

/// The newest [limit] entries, newest first (malformed lines skipped).
List<Map<String, dynamic>> readAskAiLog(Paths paths, {int limit = 100}) {
  final path = askAiLogFile(paths);
  if (FileSystemEntity.typeSync(path, followLinks: false) != FileSystemEntityType.file) return [];
  final out = <Map<String, dynamic>>[];
  // at most the last MiB; the first (possibly cut) and an unterminated last line are skipped
  final raf = File(path).openSync();
  String text;
  try {
    final length = raf.lengthSync();
    final start = length > askAiLogBytes ? length - askAiLogBytes : 0;
    raf.setPositionSync(start);
    text = utf8.decode(raf.readSync(length - start), allowMalformed: true);
    if (start > 0) text = text.substring(text.indexOf('\n') + 1);
  } finally {
    raf.closeSync();
  }
  final lines = text.split('\n')..removeLast();
  for (final line in lines.reversed) {
    try {
      final v = jsonDecode(line);
      if (v is Map<String, dynamic> && v['time'] is String && v['app'] is String && v['action'] is String) out.add(v);
    } on FormatException {
      continue;
    }
    if (out.length >= limit) break;
  }
  return out;
}

/// Empties the log (under its lock).
void clearAskAiLog(Paths paths) {
  final path = askAiLogFile(paths);
  if (FileSystemEntity.typeSync(path, followLinks: false) != FileSystemEntityType.file) return;
  Posix.instance.withFlock(askAiLogLock(paths), () => File(path).writeAsStringSync(''));
}

/// `ai.rules`: the stored rules, what each switch means, and the effective state per item.
Map<String, dynamic> askAiRulesView(Paths paths) {
  final r = readAskAiRules(paths);
  List<Map<String, dynamic>> items(List<AskAiItem> list, Map<String, bool> stored, String kind) => [
        for (final i in list)
          {
            'id': i.id,
            'app': i.app,
            'label': i.label,
            'on': stored[i.id] != false,
            'effective': r.level != 'answers' && stored[i.id] != false,
          },
      ];
  return {
    'level': r.level,
    'broken': r.broken,
    'actions': items(askAiActions, r.actions, 'actions'),
    'sources': items(askAiSources, r.sources, 'sources'),
    'folders': items(askAiFolders, r.folders, 'folders'),
    'answers': [for (final i in askAiAnswers) {'id': i.id, 'app': i.app, 'label': i.label}],
  };
}
