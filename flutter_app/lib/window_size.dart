import 'dart:async';
import 'dart:io';
import 'dart:math';

/// Rule 5a: a main window opens at the size the user last gave it. The runner reports the
/// window's size ("geometry": width, height, free = shown and neither maximized, fullscreen nor
/// tiled) and takes a saved one ("size", clamped to the screen there); this side parses, clamps
/// to a sane minimum and saves half a second after the last resize.
const minWindowWidth = 420, minWindowHeight = 320;

/// A saved size ([width, height]), at least the minimum; null when missing or broken.
(int, int)? parseWindowSize(Object? value) {
  if (value is! List || value.length != 2) return null;
  final w = value[0], h = value[1];
  if (w is! num || h is! num || !w.isFinite || !h.isFinite) return null;
  if (w <= 0 || h <= 0 || w > 20000 || h > 20000) return null;
  return (max(w.round(), minWindowWidth), max(h.round(), minWindowHeight));
}

/// The size to save from the runner's "geometry" answer, or null: not shown, maximized,
/// fullscreen or tiled, broken, or the same as [saved].
(int, int)? sizeToSave(Object? geometry, (int, int)? saved) {
  if (geometry is! Map || geometry['free'] != true) return null;
  final size = parseWindowSize([geometry['width'], geometry['height']]);
  if (size == null || size == saved) return null;
  return size;
}

/// Maprisma Tiling (the KWin script) sizes the windows it tiles itself, and no tiled state reaches
/// GTK (it only moves the frame), so the runner's "free" can't see it: on Plasma with the script
/// on, only an app it always floats (its `floatingClasses`, by default the Launcher) keeps a size.
/// [environment] and [systemData] are for tests.
bool tiledByMaprismaTiling(String appId, {Map<String, String>? environment, String systemData = '/usr/share'}) {
  final env = environment ?? Platform.environment;
  final names = (env['XDG_CURRENT_DESKTOP'] ?? '').toUpperCase().split(':');
  if (!names.contains('KDE')) return false;
  final home = env['HOME'] ?? '/';
  String xdg(String key, String fallback) {
    final v = env[key] ?? '';
    return v.startsWith('/') ? v : '$home/$fallback';
  }

  String text;
  try {
    final file = File('${xdg('XDG_CONFIG_HOME', '.config')}/kwinrc');
    text = file.lengthSync() > 1024 * 1024 ? '' : file.readAsStringSync();
  } on Object {
    text = '';
  }
  String? value(String group, String key) {
    String? current, found;
    for (final raw in text.split('\n')) {
      final line = raw.trim();
      if (line.startsWith('[') && line.endsWith(']')) {
        current = line.substring(1, line.length - 1);
      } else if (current == group) {
        final eq = line.indexOf('=');
        if (eq > 0 && line.substring(0, eq).trim() == key) found = line.substring(eq + 1).trim();
      }
    }
    return found;
  }

  final enabled = value('Plugins', 'maprisma-tilingEnabled');
  if (enabled == 'false') return false;
  // Not switched either way: on by default once installed.
  if (enabled != 'true' &&
      !Directory('${xdg('XDG_DATA_HOME', '.local/share')}/kwin/scripts/maprisma-tiling').existsSync() &&
      !Directory('$systemData/kwin/scripts/maprisma-tiling').existsSync()) {
    return false;
  }
  final floating = (value('Script-maprisma-tiling', 'floatingClasses') ?? 'com.maprisma.Launcher')
      .split(',')
      .map((c) => c.trim().toLowerCase());
  return !floating.contains(appId.toLowerCase());
}

/// Saves the window's size [delay] after the last resize ([resized], from didChangeMetrics).
/// Each resize also notes the size right away while the window is still shown, so a window
/// closed or hidden within [delay] keeps the size it had ([flush] on closing saves it at once).
final class WindowSizeKeeper {
  WindowSizeKeeper({required this.geometry, required this.save, this.saved, this.delay = const Duration(milliseconds: 500), this.tiled});

  /// The runner's "geometry" answer.
  final Future<Object?> Function() geometry;
  final Future<void> Function(int width, int height) save;
  final Duration delay;

  /// Whether the compositor sizes the window itself where the runner can't tell (e.g.
  /// `() => tiledByMaprismaTiling(appId)`): then nothing is saved.
  final bool Function()? tiled;

  /// The size last saved (or restored).
  (int, int)? saved;
  Timer? _timer;

  /// The last free size seen since the last resize (null: none, or maximized, fullscreen, tiled).
  (int, int)? _latest;
  Future<void> _sampling = Future.value();

  void resized() {
    _timer?.cancel();
    _sampling = _sample();
    _timer = Timer(delay, () => unawaited(_check()));
  }

  Future<void> _sample() async {
    try {
      _latest = _free(await geometry());
    } on Object {
      // the next resize asks again
    }
  }

  static (int, int)? _free(Object? geo) => geo is Map && geo['free'] == true ? parseWindowSize([geo['width'], geo['height']]) : null;

  Future<void> _check() async {
    await _sampling;
    Object? geo;
    try {
      geo = await geometry();
    } on Object {
      geo = null;
    }
    // shown and free now: that size; hidden meanwhile (closed, Esc, the bar): the last one seen
    // (maximized, fullscreen or tiled meanwhile: that resize noted no free size either)
    await _save(_free(geo) ?? _latest);
  }

  /// A resize not saved yet is saved now (the window is closing; it may be hidden already).
  Future<void> flush() async {
    if (_timer?.isActive != true) return;
    _timer!.cancel();
    await _sampling;
    await _save(_latest);
  }

  Future<void> _save((int, int)? size) async {
    if (size == null || size == saved) return;
    try {
      if (tiled?.call() ?? false) return;
    } on Object {
      // can't tell: save
    }
    saved = size;
    try {
      await save(size.$1, size.$2);
    } on Object {
      saved = null; // the next resize tries again
    }
  }

  void dispose() => _timer?.cancel();
}
