import 'translations.dart';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'bar_cosmic.dart';
import 'catalog_model.dart';
import 'paths.dart';

/// Maprisma Shell's bar (Hyprland, Quickshell; its README "## bar.json"):
/// `~/.config/maprisma-shell/bar.json` =
/// `{version: 1, background, left: [...], center: [...], right: [...], hidden: [...]}`.
/// An entry is a widget id (`launcher`, `workspaces`, `clock`, …), `tray` (every tray icon
/// without a place of its own) or `tray:<StatusNotifierItem id>`. The bar watches the file;
/// a write is atomic (a half-written file would be ignored by the bar).
final class MaprismaBarFile {
  MaprismaBarFile._(this.path, this.raw, this.layout, this.hidden, this.error);

  static String file(Paths paths) => p.join(paths.config, 'maprisma-shell', 'bar.json');

  /// The bar's defaults (README), used when there is no file yet.
  static Map<String, dynamic> get defaults => {
    'version': 1,
    'background': 'opaque',
    'left': ['launcher', 'workspaces'],
    'center': ['clock'],
    'right': ['tray', 'bluetooth', 'network', 'audio', 'power'],
  };

  factory MaprismaBarFile.read(Paths paths) {
    final path = file(paths);
    Map<String, dynamic> raw;
    String? error;
    try {
      final f = File(path);
      if (!f.existsSync()) {
        raw = defaults;
      } else if (f.lengthSync() > 256 * 1024) {
        return MaprismaBarFile._(path, const {}, Layout(const [], const [], const []), const [], tr('bar.json is too big'));
      } else {
        final v = jsonDecode(f.readAsStringSync());
        if (v is! Map<String, dynamic>) throw const FormatException('not an object');
        raw = v;
      }
    } on FormatException catch (e) {
      error = trf('bar.json is not readable: {0}', [e.message]);
      raw = const {};
    } on FileSystemException catch (e) {
      error = trf('bar.json is not readable: {0}', [e.message]);
      raw = const {};
    }
    List<String> list(String key) {
      final v = raw[key];
      final out = <String>[];
      if (v is List) {
        for (final e in v) {
          if (e is String && validBarEntry(e) && !out.contains(e)) out.add(e);
        }
      }
      return out;
    }

    // As the bar's BarModel.js normalize(): hidden wins over a zone ("tray" itself can't be
    // hidden), an entry counts once (its first place), a file without any valid zone entry
    // has the default zones.
    final hidden = [for (final h in list('hidden')) if (h != 'tray') h];
    var zones = [list('left'), list('center'), list('right')];
    if (zones.every((z) => z.isEmpty)) {
      final d = defaults;
      zones = [for (final a in Area.values) (d[a.name] as List).cast<String>()];
    }
    final seen = <String>{};
    final kept = [
      for (final z in zones) [for (final e in z) if (!hidden.contains(e) && seen.add(e)) e],
    ];
    final layout = Layout(kept[0], kept[1], kept[2]);
    return MaprismaBarFile._(path, raw, layout, hidden, error);
  }

  final String path;
  final Map<String, dynamic> raw;
  final Layout layout;
  final List<String> hidden;

  /// Set when the file exists but can't be read: nothing is written then.
  final String? error;

  String get revision => fnv64(jsonEncode({...layout.toJson(), 'hidden': hidden}));

  /// Writes [l] and [hidden] atomically, keeping every other key (background, version, …).
  /// False when nothing changed.
  bool write(Layout l, List<String> hidden) {
    if (error != null) throw StateError(error!);
    final h = [for (final x in hidden) if (l.find(x) == null && x.isNotEmpty && x != 'tray') x];
    if (File(path).existsSync() && l.sameAs(layout) && _same(h, this.hidden)) return false;
    final out = <String, dynamic>{...raw, 'version': raw['version'] ?? 1, ...l.toJson()};
    if (h.isEmpty) {
      out.remove('hidden');
    } else {
      out['hidden'] = h;
    }
    Directory(p.dirname(path)).createSync(recursive: true);
    atomicWrite(path, const JsonEncoder.withIndent('  ').convert(out));
    return true;
  }
}

bool _same(List<String> a, List<String> b) => a.length == b.length && [for (var i = 0; i < a.length; i++) a[i] == b[i]].every((x) => x);

/// An app's entry in Maprisma Bar: the Launcher is the bar's own `launcher` widget, a tray app
/// is `tray:<its StatusNotifierItem id>` (the catalog's kdeId: the same trays run on KDE and
/// Hyprland). Null: no icon in Maprisma Bar.
String? hyprBarId(AppEntry a) {
  final b = a.bar;
  if (b.kdeKind == KdeBarKind.widgetEntry && b.kdeId == 'maprisma-launcher') return 'launcher';
  if (b.kdeId != null && b.kdeTrayExe != null) return 'tray:${b.kdeId}';
  return null;
}

/// An entry Maprisma Bar accepts (BarModel.js validEntry).
bool validBarEntry(String e) =>
    hyprBarWidgets.contains(e) || RegExp(r'^tray:[^\x00-\x1f]{1,200}$').hasMatch(e);

/// The bar's own widgets (not ours; movable, never taken out by the Manager).
const hyprBarWidgets = {'launcher', 'workspaces', 'clock', 'bluetooth', 'network', 'audio', 'power', 'tray'};
