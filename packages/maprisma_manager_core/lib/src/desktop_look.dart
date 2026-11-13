import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'catalog_model.dart' show DesktopId;
import 'context.dart';

/// `desktop.look`: the desktop's palette and window corners, as Maprisma Launcher reads them
/// (maprisma_launcher_core desktops.dart), so the Manager looks like the Launcher's pages.
/// `{desktop, colors: {accent, background, foreground, muted, selection, red, yellow, orange, green}, rounding, is_dark}`.
Future<Map<String, dynamic>> desktopLook(Ctx ctx) async {
  final colors = switch (ctx.desktop) {
    DesktopId.cosmic => _cosmicColors(ctx),
    DesktopId.kde => _kdeColors(ctx),
    DesktopId.hyprland => _shellColors(ctx),
    DesktopId.other => <String, String>{},
  };
  final bg = colors['background'];
  return {
    'desktop': ctx.desktop.name,
    'colors': colors,
    'rounding': switch (ctx.desktop) {
      DesktopId.cosmic => _cosmicRounding(ctx),
      DesktopId.kde => 8,
      DesktopId.hyprland => await hyprRounding(ctx),
      DesktopId.other => null,
    },
    'is_dark': bg == null ? null : _dark(bg),
  };
}

/// The last answer of `hyprctl` per core, so the look's re-reads (every few seconds while the
/// window is open) ask Hyprland at most every 30 s.
final _roundingCache = Expando<({DateTime at, int? value})>('hyprRounding');

/// Hyprland's window rounding (`hyprctl -j getoption decoration:rounding` → `.int`, 0–64), null
/// when hyprctl is missing, fails or gives no number. Asked at most every 30 s per core.
Future<int?> hyprRounding(Ctx ctx) async {
  final now = ctx.clock();
  final cached = _roundingCache[ctx];
  if (cached != null && now.difference(cached.at).abs() < const Duration(seconds: 30)) return cached.value;
  int? value;
  final r = await ctx.runner.run(['hyprctl', '-j', 'getoption', 'decoration:rounding'], timeout: const Duration(seconds: 3));
  if (r.ok) {
    try {
      final data = jsonDecode(r.stdout);
      final v = data is Map ? data['int'] : null;
      if (v is int) value = v.clamp(0, 64);
    } on FormatException {
      value = null;
    }
  }
  _roundingCache[ctx] = (at: now, value: value);
  return value;
}

/// Maprisma Shell's colour scheme (XDG_STATE_HOME/maprisma-shell/scheme.json, written by
/// Maprisma Theme; Material names, hex without '#'), as Maprisma Playground reads it; empty
/// without it.
Map<String, String> _shellColors(Ctx ctx) {
  final stateHome = ctx.environment['XDG_STATE_HOME'];
  final state = stateHome != null && p.isAbsolute(stateHome) ? stateHome : p.join(ctx.paths.home, '.local', 'state');
  final text = _read(p.join(state, 'maprisma-shell', 'scheme.json'), 256 * 1024);
  if (text == null) return {};
  Object? data;
  try {
    data = jsonDecode(text);
  } on FormatException {
    return {};
  }
  final colours = data is Map ? data['colours'] : null;
  if (colours is! Map) return {};
  String? c(String key) {
    final v = colours[key];
    return v is String && RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(v) ? '#${v.toLowerCase()}' : null;
  }

  final out = {
    'accent': c('primary'),
    'background': c('surface') ?? c('background'),
    'foreground': c('onSurface'),
    'muted': c('outline'),
    'selection': c('surfaceContainerHighest'),
    'red': c('error') ?? c('red'),
    'yellow': c('yellow'),
    'orange': c('peach'),
    'green': c('green'),
  };
  return {for (final e in out.entries) if (e.value != null) e.key: e.value!};
}

const _light = {
  'background': '#fafafb', 'foreground': '#323233', 'muted': '#77767b',
  'selection': '#dedddf', 'red': '#e01b24', 'yellow': '#c88800',
  'orange': '#e66100', 'green': '#26a269',
};
const _darkColors = {
  'background': '#222226', 'foreground': '#ffffff', 'muted': '#9a9996',
  'selection': '#3a3a3e', 'red': '#ff7b63', 'yellow': '#f8e45c',
  'orange': '#ffa348', 'green': '#8ff0a4',
};

bool _dark(String hex) {
  final v = int.parse(hex.substring(1), radix: 16);
  final r = (v >> 16) & 255, g = (v >> 8) & 255, b = v & 255;
  return (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255 < 0.5;
}

String? _read(String path, int max) {
  try {
    final f = File(path);
    if (FileSystemEntity.typeSync(path) != FileSystemEntityType.file || f.lengthSync() > max) return null;
    return utf8.decode(f.readAsBytesSync(), allowMalformed: true);
  } on FileSystemException {
    return null;
  }
}

// --- COSMIC ----------------------------------------------------------------------------

/// The user's config, else the system's defaults; in each the newest schema first (COSMIC 1.x
/// keeps its themes in `v2` and leaves `v1` empty or stale; the Mode is still `v1`).
String? _cosmicConfig(Ctx ctx, String component, String key) {
  for (final base in [p.join(ctx.paths.config, 'cosmic'), p.join(ctx.paths.root, 'usr/share/cosmic')]) {
    for (final version in const ['v2', 'v1']) {
      final text = _read(p.join(base, component, version, key), 256 * 1024);
      if (text != null) return text;
    }
  }
  return null;
}

bool _cosmicDark(Ctx ctx) => (_cosmicConfig(ctx, 'com.system76.CosmicTheme.Mode', 'is_dark') ?? 'true').trim() != 'false';

/// COSMIC's theme: accent, background (base and on), success/warning/destructive.
Map<String, String> _cosmicColors(Ctx ctx) {
  final dark = _cosmicDark(ctx);
  final theme = dark ? 'com.system76.CosmicTheme.Dark' : 'com.system76.CosmicTheme.Light';
  String? container(String key, String field) {
    final text = _cosmicConfig(ctx, theme, key);
    return text == null ? null : ronColor(ronField(text, field));
  }

  final accent = container('accent', 'base') ?? ronColor(_cosmicConfig(ctx, theme, 'accent'));
  return {
    ...(dark ? _darkColors : _light),
    'accent': accent ?? '#63d0df',
    'background': ?container('background', 'base'),
    'foreground': ?container('background', 'on'),
    'green': ?container('success', 'base'),
    'yellow': ?container('warning', 'base'),
    'red': ?container('destructive', 'base'),
  };
}

int _cosmicRounding(Ctx ctx) {
  final theme = _cosmicDark(ctx) ? 'com.system76.CosmicTheme.Dark' : 'com.system76.CosmicTheme.Light';
  final radii = _cosmicConfig(ctx, theme, 'corner_radii');
  final small = radii == null ? null : ronField(radii, 'radius_s');
  final first = small == null ? null : RegExp(r'([0-9.]+)').firstMatch(small)?[1];
  return first == null ? 8 : double.tryParse(first)?.round() ?? 8;
}

/// The value after `key:` at the first nesting level of a RON struct, or null.
String? ronField(String text, String key) {
  var depth = 0;
  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    if (c == '(' || c == '[') {
      depth++;
    } else if (c == ')' || c == ']') {
      depth--;
    } else if (depth == 1 && text.startsWith(key, i) && (i == 0 || !RegExp(r'[\w]').hasMatch(text[i - 1]))) {
      var j = i + key.length;
      while (j < text.length && text[j] == ' ') {
        j++;
      }
      if (j >= text.length || text[j] != ':') continue;
      j++;
      final start = j;
      var d = 0;
      for (; j < text.length; j++) {
        final cj = text[j];
        if (cj == '(' || cj == '[') d++;
        if (cj == ')' || cj == ']') {
          if (d == 0) break;
          d--;
        }
        if (cj == ',' && d == 0) break;
      }
      return text.substring(start, j).trim();
    }
  }
  return null;
}

/// A RON colour `(red: 0.1, green: …, blue: …)` (schema v1) or `"#RRGGBBAA"` (v2) as #rrggbb, or
/// null.
String? ronColor(String? value) {
  if (value == null) return null;
  // COSMIC 1.x (schema v2) writes colours as "#RRGGBBAA" strings.
  final hexString = RegExp(r'^"?#([0-9a-fA-F]{6})(?:[0-9a-fA-F]{2})?"?$').firstMatch(value.trim());
  if (hexString != null) return '#${hexString[1]!.toLowerCase()}';
  int? part(String name) {
    final m = RegExp('$name:\\s*([0-9.eE+-]+)').firstMatch(value);
    final v = m == null ? null : double.tryParse(m[1]!);
    return v == null ? null : (v.clamp(0, 1) * 255).round();
  }

  final r = part('red'), g = part('green'), b = part('blue');
  if (r == null || g == null || b == null) return null;
  String hex(int v) => v.toRadixString(16).padLeft(2, '0');
  return '#${hex(r)}${hex(g)}${hex(b)}';
}

// --- KDE ---------------------------------------------------------------------------------

String? _kdeIni(String text, String group, String key) {
  String? current, found;
  for (final raw in const LineSplitter().convert(text)) {
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

String? _kdeColor(String? value) {
  if (value == null) return null;
  final parts = value.split(',').map((v) => int.tryParse(v.trim())).toList();
  if ((parts.length != 3 && parts.length != 4) || parts.any((v) => v == null || v < 0 || v > 255)) return null;
  String hex(int v) => v.toRadixString(16).padLeft(2, '0');
  return '#${hex(parts[0]!)}${hex(parts[1]!)}${hex(parts[2]!)}';
}

/// Plasma's colour scheme from kdeglobals (as the Launcher reads it).
Map<String, String> _kdeColors(Ctx ctx) {
  final text = _read(p.join(ctx.paths.config, 'kdeglobals'), 1024 * 1024) ?? '';
  String? c(String group, String key) => _kdeColor(_kdeIni(text, group, key));
  final bg = c('Colors:Window', 'BackgroundNormal');
  return {
    ...(bg == null || _dark(bg) ? _darkColors : _light),
    'accent': c('General', 'AccentColor') ?? c('Colors:View', 'DecorationFocus') ?? c('Colors:Selection', 'BackgroundNormal') ?? '#3daee9',
    'background': ?bg,
    'foreground': ?c('Colors:Window', 'ForegroundNormal'),
    'selection': ?c('Colors:Selection', 'BackgroundNormal'),
    'muted': ?c('Colors:Window', 'ForegroundInactive'),
    'red': ?c('Colors:View', 'ForegroundNegative'),
    'yellow': ?c('Colors:View', 'ForegroundNeutral'),
    'green': ?c('Colors:View', 'ForegroundPositive'),
  };
}
