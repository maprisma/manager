import 'translations.dart';
import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'context.dart';
import 'paths.dart';
import 'procs.dart';
import 'ron.dart';

/// The three areas of a bar, left to right.
enum Area { left, center, right }

Area? parseArea(Object? v) => switch (v) {
  'left' => Area.left,
  'center' || 'centre' => Area.center,
  'right' => Area.right,
  _ => null,
};

/// The bar's areas: ordered entry ids.
final class Layout {
  Layout(List<String> left, List<String> center, List<String> right)
    : areas = {Area.left: [...left], Area.center: [...center], Area.right: [...right]};

  final Map<Area, List<String>> areas;

  Layout copy() => Layout(areas[Area.left]!, areas[Area.center]!, areas[Area.right]!);

  ({Area area, int index})? find(String id) {
    for (final a in Area.values) {
      final i = areas[a]!.indexOf(id);
      if (i >= 0) return (area: a, index: i);
    }
    return null;
  }

  /// Takes [id] out of every area; true when it was in one.
  bool remove(String id) {
    var any = false;
    for (final l in areas.values) {
      while (l.remove(id)) {
        any = true;
      }
    }
    return any;
  }

  /// Puts [id] into [area] at [index] (clamped; the index counts without [id] itself).
  void put(String id, Area area, int index) {
    remove(id);
    final l = areas[area]!;
    l.insert(index.clamp(0, l.length), id);
  }

  bool sameAs(Layout o) => Area.values.every((a) => _eq(areas[a]!, o.areas[a]!));

  Map<String, List<String>> toJson() => {for (final a in Area.values) a.name: areas[a]!};
}

bool _eq(List<String> a, List<String> b) => a.length == b.length && [for (var i = 0; i < a.length; i++) a[i] == b[i]].every((x) => x);

/// COSMIC's default place in an area: the end of the left wing and of the centre, the start of
/// the right wing's COSMIC applets (after the other icons there).
int cosmicDefaultIndex(Layout l, Area area, String id) {
  final list = [...l.areas[area]!]..remove(id);
  if (area != Area.right) return list.length;
  final firstCosmic = list.indexWhere((e) => e.startsWith('com.system76.'));
  return firstCosmic < 0 ? list.length : firstCosmic;
}

/// One of the panel's two files: the user's (when it exists), else the system default.
final class PanelFile {
  PanelFile(this.name, this.userPath, this.userText, this.source, this.doc, this.error, [this.effectiveText]);

  /// The text in effect: the user file's, else the system default's.
  final String? effectiveText;
  final String name;
  final String userPath;

  /// The user file's text; null when it is missing.
  final String? userText;

  /// `user`, `system` (the default from /usr/share/cosmic) or `none`.
  final String source;
  final RonListDoc? doc;
  final String? error;

  List<List<String>> get lists => doc?.values ?? const [];
}

/// A COSMIC panel instance (Panel, Dock …) as its files say.
final class CosmicPanelConfig {
  CosmicPanelConfig(this.instance, this.wings, this.center);
  final String instance;
  final PanelFile wings;
  final PanelFile center;

  String? get error => wings.error ?? center.error;

  Layout get layout {
    final w = wings.lists, c = center.lists;
    return Layout(w.isNotEmpty ? w[0] : const [], c.isNotEmpty ? c[0] : const [], w.length > 1 ? w[1] : const []);
  }

  /// What the user saw: both files in effect, with where they came from (a missing user file
  /// counts as such, and a changed system default changes it too).
  String get revision => fnv64([
    for (final f in [wings, center]) '${f.name}:${f.source}:${f.userText == null ? 'missing' : 'present'}:${f.effectiveText ?? ''}',
  ].join('\u0001'));

  static String dir(Paths paths, String instance) => p.join(paths.config, 'cosmic/com.system76.CosmicPanel.$instance/v1');
  static String systemDir(Paths paths, String instance) => paths.sys('/usr/share/cosmic/com.system76.CosmicPanel.$instance/v1');

  static CosmicPanelConfig read(Paths paths, String instance) {
    PanelFile file(String name, int count) {
      final user = p.join(dir(paths, instance), name);
      String? userText;
      try {
        userText = File(user).readAsStringSync();
      } on PathNotFoundException {
        userText = null;
      } on FileSystemException catch (e) {
        return PanelFile(name, user, null, 'user', null, '$name: ${e.message}');
      }
      var source = 'user';
      var text = userText;
      if (text == null) {
        try {
          text = File(p.join(systemDir(paths, instance), name)).readAsStringSync();
          source = 'system';
        } on FileSystemException {
          text = '';
          source = 'none';
        }
      }
      try {
        return PanelFile(name, user, userText, source, RonListDoc.parse(text, count: count), null, text);
      } on FormatException catch (e) {
        return PanelFile(name, user, userText, source, null, '$name: ${e.message}', text);
      }
    }

    return CosmicPanelConfig(instance, file('plugins_wings', 2), file('plugins_center', 1));
  }

  /// The texts for [l]: null for a file that doesn't change.
  ({String? wings, String? center}) render(Layout l) {
    String? one(PanelFile f, List<List<String>> values) {
      if (f.error != null) throw StateError(f.error!);
      final old = f.lists;
      final same = old.length == values.length && [for (var i = 0; i < old.length; i++) _eq(old[i], values[i])].every((x) => x);
      // A None/missing file whose lists stay empty stays as it is.
      if (same || (old.isEmpty && values.every((v) => v.isEmpty))) return null;
      // From the system default or None: written as COSMIC writes user files.
      final doc = f.source == 'user' && !f.doc!.isNone ? f.doc! : RonListDoc.parse('', count: values.length);
      return doc.render(values);
    }

    return (
      wings: one(wings, [l.areas[Area.left]!, l.areas[Area.right]!]),
      center: one(center, [l.areas[Area.center]!]),
    );
  }
}

/// The panel instances COSMIC runs (`com.system76.CosmicPanel/v1/entries`, else its default).
List<String> cosmicInstances(Paths paths) {
  for (final f in [
    p.join(paths.config, 'cosmic/com.system76.CosmicPanel/v1/entries'),
    paths.sys('/usr/share/cosmic/com.system76.CosmicPanel/v1/entries'),
  ]) {
    try {
      final text = File(f).readAsStringSync();
      final doc = RonListDoc.parse('Some($text)', count: 1);
      return doc.values.single;
    } on FileSystemException {
      continue;
    } on FormatException {
      continue;
    }
  }
  return const ['Panel'];
}

/// 64-bit FNV-1a, hex: a revision token, not a security hash.
String fnv64(String s) {
  var h = 0xcbf29ce484222325;
  for (final c in s.codeUnits) {
    h ^= c;
    h = (h * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
  }
  return h.toUnsigned(64).toRadixString(16).padLeft(16, '0');
}

/// Writes [l] to [instance]'s files when they still are what [seen] read (else `changed`):
/// both files backed up first, each written atomically, the one that loses entries first.
/// Returns the files written and the backup folder. The caller holds [withStateLock].
Future<({List<String> written, String? backup})> writeCosmic(Paths paths, CosmicPanelConfig seen, Layout l) async {
  final texts = seen.render(l);
  if (texts.wings == null && texts.center == null) return (written: const <String>[], backup: null);
  return () async {
    final now = CosmicPanelConfig.read(paths, seen.instance);
    if (now.revision != seen.revision) throw RouteError('changed', tr('the panel config changed since it was read'));
    final backup = backupFiles(paths, 'cosmic-${seen.instance}', [seen.wings.userPath, seen.center.userPath]);
    final order = <(PanelFile, String)>[
      if (texts.wings != null) (seen.wings, texts.wings!),
      if (texts.center != null) (seen.center, texts.center!),
    ];
    // The file that loses an entry first: no moment with an applet twice in the panel.
    final before = seen.layout;
    bool loses(PanelFile f) {
      final areas = f == seen.wings ? [Area.left, Area.right] : [Area.center];
      final had = {for (final a in areas) ...before.areas[a]!};
      final has = {for (final a in areas) ...l.areas[a]!};
      return had.difference(has).isNotEmpty;
    }

    order.sort((a, b) => (loses(b.$1) ? 1 : 0) - (loses(a.$1) ? 1 : 0));
    final written = <String>[];
    for (final (f, text) in order) {
      // Checked again right before each file: a concurrent edit is never overwritten.
      final current = _readOrNull(f.userPath);
      if (current != f.userText) {
        throw RouteError('changed', trf('{0} changed while writing{1}', [f.name, written.isEmpty ? '' : trf(' ({0} already written; backup in {1})', [written.join(', '), backup])]));
      }
      atomicWrite(f.userPath, text);
      written.add(f.name);
    }
    return (written: written, backup: backup);
  }();
}

String? _readOrNull(String path) {
  try {
    return File(path).readAsStringSync();
  } on PathNotFoundException {
    return null;
  }
}

/// Writes [text] to a temporary file next to [path] and renames it over [path].
void atomicWrite(String path, String text) {
  Directory(p.dirname(path)).createSync(recursive: true);
  final tmp = File(p.join(p.dirname(path), '.${p.basename(path)}.maprisma-manager.$pid.tmp'));
  final raf = tmp.openSync(mode: FileMode.writeOnly);
  try {
    raf.writeStringSync(text);
    raf.flushSync();
  } finally {
    raf.closeSync();
  }
  try {
    tmp.renameSync(path);
  } on FileSystemException {
    if (tmp.existsSync()) tmp.deleteSync();
    rethrow;
  }
}

/// How many backups of each kind are kept.
const keepBackups = 20;

/// Copies [files] (a missing one is noted as such) to `<state>/maprisma-manager/backups/<time>-<kind>/`.
String backupFiles(Paths paths, String kind, List<String> files) {
  final root = p.join(paths.managerState, 'backups');
  final stamp = DateTime.now().toUtc().toIso8601String().replaceAll(':', '').replaceAll('-', '').replaceAll('.', '');
  var dir = p.join(root, '$stamp-$kind');
  for (var n = 2; Directory(dir).existsSync(); n++) {
    dir = p.join(root, '$stamp-$kind-$n');
  }
  Directory(dir).createSync(recursive: true);
  final listing = StringBuffer();
  for (final f in files) {
    final src = File(f);
    if (src.existsSync()) {
      src.copySync(p.join(dir, p.basename(f)));
      listing.writeln('$f\t${p.basename(f)}');
    } else {
      listing.writeln('$f\tmissing');
    }
  }
  File(p.join(dir, 'files')).writeAsStringSync(listing.toString());
  // Keep the newest ones of this kind.
  final mine = Directory(root).listSync().whereType<Directory>().where((d) => RegExp('^[0-9TZ]+-${RegExp.escape(kind)}(-[0-9]+)?\$').hasMatch(p.basename(d.path))).toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final d in mine.take(mine.length > keepBackups ? mine.length - keepBackups : 0)) {
    d.deleteSync(recursive: true);
  }
  return dir;
}

/// The in-process queue in front of the file lock: fcntl locks don't exclude the same process,
/// and closing any descriptor of the lock file would drop it.
Future<void> _queue = Future.value();

/// Runs [body] holding the Manager's state lock (one change at a time, in this process and
/// across processes). Not re-entrant: callers take it once around a whole change.
Future<T> withStateLock<T>(Paths paths, Future<T> Function() body) {
  final previous = _queue;
  final done = Completer<void>();
  _queue = done.future;
  return previous.then((_) => _locked(paths, body)).whenComplete(done.complete);
}

Future<T> _locked<T>(Paths paths, Future<T> Function() body) async {
  final f = File(p.join(paths.managerState, 'lock'));
  f.createSync(recursive: true);
  final raf = f.openSync(mode: FileMode.append);
  try {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (true) {
      try {
        raf.lockSync(FileLock.exclusive);
        break;
      } on FileSystemException {
        if (DateTime.now().isAfter(deadline)) throw RouteError('busy', tr('another Maprisma Manager is changing things'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    return await body();
  } finally {
    raf.closeSync();
  }
}

// --- does the panel follow? ----------------------------------------------------------------

/// The user's cosmic-panel processes.
List<ProcInfo> cosmicPanels(List<ProcInfo> procs) =>
    [for (final pr in procs) if (pr.exe != null && p.basename(pr.exe!) == 'cosmic-panel') pr];

/// After a write: cosmic-panel 1.11 rebuilds its applets when plugins_wings/plugins_center change
/// (checked live 2026-11-09, docs/plan.md). The panel reacted when a child process of it started
/// after the write. If it didn't within [wait], the panel is restarted once (TERM by PID; COSMIC's
/// session starts it again) and checked to come back.
Future<Map<String, dynamic>> followPanel(
  List<ProcInfo> Function() procs,
  List<ProcInfo> before, {
  Duration wait = const Duration(seconds: 5),
  Duration back = const Duration(seconds: 10),
  bool Function(int pid)? kill,
  Duration step = const Duration(milliseconds: 250),
}) async {
  final panels = cosmicPanels(before);
  if (panels.isEmpty) return {'panel': null, 'note': tr('cosmic-panel is not running')};
  // One cosmic-panel runs all panel instances; with more than one, which one serves the changed
  // instance can't be told: none is restarted then.
  if (panels.length > 1) kill = (_) => false;
  final panel = panels.first;
  final ids = {for (final pr in panels) pr.pid};
  final oldPanels = {for (final pr in panels) '${pr.pid}:${pr.startTicks}'};
  final known = {for (final pr in before) if (ids.contains(pr.ppid)) '${pr.pid}:${pr.startTicks}'};
  final until = DateTime.now().add(wait);
  var killed = false;
  while (true) {
    final now = procs();
    final stillThere = now.any((pr) => pr.pid == panel.pid && pr.startTicks == panel.startTicks);
    if (!stillThere) break; // the panel restarted by itself (or crashed): check that one comes back
    final fresh = now.where((pr) => ids.contains(pr.ppid) && !known.contains('${pr.pid}:${pr.startTicks}'));
    if (fresh.isNotEmpty) return {'panel': panel.pid, 'reacted': true, 'restarted': false};
    if (DateTime.now().isAfter(until)) {
      final ok = (kill ?? (pid) => Process.killPid(pid, ProcessSignal.sigterm))(panel.pid);
      if (!ok) {
        return {'panel': panel.pid, 'reacted': false, 'restarted': false, 'error': panels.length > 1 ? tr('no reaction; several cosmic-panel processes, none restarted') : tr('could not signal the panel')};
      }
      killed = true;
      break;
    }
    await Future<void>.delayed(step);
  }
  final backUntil = DateTime.now().add(back);
  while (DateTime.now().isBefore(backUntil)) {
    // A new panel process, not one that ran before.
    final again = cosmicPanels(procs()).where((pr) => !oldPanels.contains('${pr.pid}:${pr.startTicks}'));
    if (again.isNotEmpty) return {'panel': again.first.pid, 'reacted': !killed, 'restarted': killed, 'back': true};
    await Future<void>.delayed(step);
  }
  return {'panel': null, 'reacted': false, 'restarted': killed, 'back': false, 'error': tr('cosmic-panel did not come back')};
}
