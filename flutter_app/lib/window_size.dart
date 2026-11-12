import 'dart:async';
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

/// Saves the window's size [delay] after the last resize ([resized], from didChangeMetrics).
final class WindowSizeKeeper {
  WindowSizeKeeper({required this.geometry, required this.save, this.saved, this.delay = const Duration(milliseconds: 500)});

  /// The runner's "geometry" answer.
  final Future<Object?> Function() geometry;
  final Future<void> Function(int width, int height) save;
  final Duration delay;

  /// The size last saved (or restored).
  (int, int)? saved;
  Timer? _timer;

  void resized() {
    _timer?.cancel();
    _timer = Timer(delay, _check);
  }

  Future<void> _check() async {
    final Object? geo;
    try {
      geo = await geometry();
    } on Object {
      return;
    }
    final size = sizeToSave(geo, saved);
    if (size == null) return;
    saved = size;
    try {
      await save(size.$1, size.$2);
    } on Object {
      saved = null; // the next resize tries again
    }
  }

  void dispose() => _timer?.cancel();
}
