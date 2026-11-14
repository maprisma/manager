import 'dart:convert';
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
  WindowSizeKeeper({
    required this.geometry,
    required this.save,
    this.saved,
    this.delay = const Duration(milliseconds: 500),
    this.tiled,
    this.notUsers = hyprlandSizeNotUsers,
  });

  /// The runner's "geometry" answer.
  final Future<Object?> Function() geometry;
  final Future<void> Function(int width, int height) save;
  final Duration delay;

  /// Whether the compositor sizes the window itself where the runner can't tell (e.g.
  /// `() => tiledByMaprismaTiling(appId)`): then nothing is saved.
  final bool Function()? tiled;

  /// Whether the present size is the compositor's (Hyprland: tiled or fullscreen), asked just
  /// before saving.
  final Future<bool> Function() notUsers;

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
    if (await notUsers()) return;
    saved = size;
    try {
      await save(size.$1, size.$2);
    } on Object {
      saved = null; // the next resize tries again
    }
  }

  void dispose() => _timer?.cancel();
}

/// A saved place ([x, y], Hyprland's layout pixels); null when missing or broken.
(int, int)? parseWindowPosition(Object? value) {
  if (value is! List || value.length != 2) return null;
  final x = value[0], y = value[1];
  if (x is! int || y is! int || x.abs() > 100000 || y.abs() > 100000) return null;
  return (x, y);
}

/// From `hyprctl -j clients`: where [processId]'s window is, when it floats and isn't fullscreen
/// (a tiled or fullscreen place is not the user's); null otherwise.
(int, int)? hyprPosition(String clientsJson, int processId) {
  if (hyprNotUsers(clientsJson, processId) != false) return null;
  for (final client in jsonDecode(clientsJson) as List) {
    if (client is Map && client['pid'] == processId) {
      final at = client['at'];
      if (at is List && at.length == 2 && at[0] is int && at[1] is int) return (at[0] as int, at[1] as int);
    }
  }
  return null;
}

/// From `hyprctl -j monitors`: whether a window at [position] (its top left) with [size] keeps
/// at least 48 px on a screen, so a place on a screen that is gone isn't used.
bool onAMonitor(String monitorsJson, (int, int) position, (int, int) size) {
  Object? list;
  try {
    list = jsonDecode(monitorsJson);
  } on FormatException {
    return false;
  }
  if (list is! List) return false;
  final (x, y) = position;
  for (final m in list) {
    if (m is! Map) continue;
    final scale = (m['scale'] is num && (m['scale'] as num) > 0) ? (m['scale'] as num).toDouble() : 1.0;
    final mx = m['x'], my = m['y'], mw = m['width'], mh = m['height'];
    if (mx is! num || my is! num || mw is! num || mh is! num) continue;
    final w = mw / scale, h = mh / scale;
    if (x + size.$1 - 48 >= mx && x + 48 <= mx + w && y >= my && y + 48 <= my + h) return true;
  }
  return false;
}

/// Hyprland: the window opens where the user left it (Uwe, 2026-11-14, every Maprisma window).
/// A Wayland window can't place itself or hear that it was moved, and the runner hides it before
/// Dart could ask, so while it is shown [every] few seconds hyprctl says where it is (saved when
/// that changed), and each time it is shown again it is moved back there. Elsewhere it does
/// nothing. [run] and [environment] are for tests.
final class WindowPlaceKeeper {
  WindowPlaceKeeper({
    required (int, int)? saved,
    required this.save,
    this.every = const Duration(seconds: 2),
    Map<String, String>? environment,
    Future<ProcessResult> Function(List<String> args)? run,
    int? processId,
  }) : _saved = saved, // ignore: prefer_initializing_formals
       _env = environment ?? Platform.environment,
       _run = run ?? ((args) => Process.run('hyprctl', args)),
       _pid = processId ?? pid;

  final Future<void> Function(int x, int y) save;
  final Duration every;
  final Map<String, String> _env;
  final Future<ProcessResult> Function(List<String> args) _run;
  final int _pid;
  (int, int)? _saved;
  Timer? _timer;
  bool _shown = true;

  /// Hyprland only, and never in widget tests (they must not ask or move the real windows).
  bool get active => _env['FLUTTER_TEST'] != 'true' && _hyprlandDesktop(_env);

  Future<String?> _ask(List<String> args) async {
    try {
      final r = await _run(args).timeout(const Duration(seconds: 2));
      return r.exitCode == 0 ? r.stdout.toString() : null;
    } on Object {
      return null;
    }
  }

  /// At start: back to the saved place, then sampling while shown.
  void start() {
    if (!active) return;
    unawaited(restore());
    _timer = Timer.periodic(every, (_) {
      if (_shown) unawaited(sample());
    });
  }

  /// From didChangeAppLifecycleState: hidden stops the sampling; shown again moves it back.
  void lifecycle(AppLifecycleStateName state) {
    if (!active) return;
    final shown = state != AppLifecycleStateName.hidden && state != AppLifecycleStateName.paused;
    if (shown && !_shown) unawaited(restore());
    _shown = shown;
  }

  /// Saves where the window is now when that changed (floating, not fullscreen).
  Future<void> sample() async {
    final clients = await _ask(['-j', 'clients']);
    if (clients == null) return;
    final at = hyprPosition(clients, _pid);
    if (at == null || at == _saved) return;
    _saved = at;
    await save(at.$1, at.$2);
  }

  /// Once Hyprland lists the window (asked every 50 ms for up to 3 s), it is moved to the saved
  /// place when that is still on a screen.
  Future<void> restore() async {
    final place = _saved;
    if (place == null) return;
    for (var i = 0; i < 60; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final clients = await _ask(['-j', 'clients']);
      if (clients == null) return;
      if (hyprNotUsers(clients, _pid) == null) continue; // not mapped yet
      if (hyprNotUsers(clients, _pid) == true) return; // tiled or fullscreen: Hyprland's place
      final size = _sizeOf(clients);
      if (hyprPosition(clients, _pid) == place || size == null) return;
      final monitors = await _ask(['-j', 'monitors']);
      if (monitors != null && onAMonitor(monitors, place, size)) {
        await _ask(['eval', "hl.dispatch(hl.dsp.window.move({ x = ${place.$1}, y = ${place.$2}, window = 'pid:$_pid' }))"]);
      }
      return;
    }
  }

  (int, int)? _sizeOf(String clientsJson) {
    for (final client in jsonDecode(clientsJson) as List) {
      if (client is Map && client['pid'] == _pid && client['size'] is List) {
        final s = client['size'] as List;
        if (s.length == 2 && s[0] is int && s[1] is int) return (s[0] as int, s[1] as int);
      }
    }
    return null;
  }

  void dispose() => _timer?.cancel();
}

/// The app lifecycle states [WindowPlaceKeeper.lifecycle] needs, by name (this file doesn't
/// import Flutter): `AppLifecycleStateName.values.byName(state.name)`.
enum AppLifecycleStateName { detached, resumed, inactive, hidden, paused }

/// Hyprland marks every window as tiled, floating ones too, so the runner can't tell whether a
/// size is the user's: there `hyprctl -j clients` decides. True when this process's window is
/// tiled or fullscreen (not a size to keep); false on other desktops or when it can't be told.
/// Shared in every Maprisma Flutter app's size code (Uwe, 2026-11-14).
Future<bool> hyprlandSizeNotUsers({
  Map<String, String>? environment,
  int? processId,
  Future<ProcessResult> Function()? clients,
}) async {
  final env = environment ?? Platform.environment;
  if (!_hyprlandDesktop(env)) return false;
  try {
    final result = await (clients ?? () => Process.run('hyprctl', ['-j', 'clients']))()
        .timeout(const Duration(seconds: 2));
    if (result.exitCode != 0) return false;
    return hyprNotUsers(result.stdout.toString(), processId ?? pid) ?? false;
  } on Object {
    return false;
  }
}

/// From `hyprctl -j clients`: whether [processId]'s window is tiled or fullscreen; null when the
/// list has no window of it.
bool? hyprNotUsers(String clientsJson, int processId) {
  Object? list;
  try {
    list = jsonDecode(clientsJson);
  } on FormatException {
    return null;
  }
  if (list is! List) return null;
  for (final client in list) {
    if (client is Map && client['pid'] == processId) {
      final fullscreen = client['fullscreen'];
      return client['floating'] != true || (fullscreen is num && fullscreen != 0) || fullscreen == true;
    }
  }
  return null;
}

/// MAPRISMA_DESKTOP, else XDG_CURRENT_DESKTOP; Hyprland's instance signature only when neither
/// is set (a stale one stays in the systemd user environment after a Hyprland session).
bool _hyprlandDesktop(Map<String, String> env) {
  final forced = (env['MAPRISMA_DESKTOP'] ?? '').trim().toLowerCase();
  if (forced.isNotEmpty) return forced == 'hyprland';
  final names = (env['XDG_CURRENT_DESKTOP'] ?? '')
      .toLowerCase()
      .split(':')
      .map((n) => n.trim())
      .where((n) => n.isNotEmpty)
      .toList();
  if (names.isNotEmpty) return names.contains('hyprland');
  return (env['HYPRLAND_INSTANCE_SIGNATURE'] ?? '').isNotEmpty;
}
