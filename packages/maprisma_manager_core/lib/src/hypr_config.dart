import 'translations.dart';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'animations.dart' show AnimationsService;
import 'bar_cosmic.dart' show atomicWrite;
import 'catalog_model.dart' show DesktopId;
import 'context.dart';

/// The Hyprland settings the Manager's Displays, Input and Appearance (animations) pages change. They live in a file of
/// the Manager's own, `~/.config/hypr/hypr-manager.lua`, loaded last from hypr-user.lua (a
/// marked line), so it overrides the user's config only where a value was set here. The values
/// are kept as JSON next to it (`maprisma-manager/hyprland.json`) and the Lua is made from them;
/// after a write Hyprland reloads its config.
final class HyprConfig {
  HyprConfig(this.ctx);
  final Ctx ctx;

  String get hyprDir => p.join(ctx.paths.config, 'hypr');
  String get luaFile => p.join(hyprDir, 'hypr-manager.lua');
  String get userFile => p.join(hyprDir, 'hypr-user.lua');
  String get stateFile => p.join(ctx.paths.config, 'maprisma-manager', 'hyprland.json');

  static const requireLine = 'pcall(require, "hypr-manager") -- Maprisma Manager: Displays, Input devices, Animations (keep last)';

  void need() {
    if (ctx.desktop != DesktopId.hyprland) throw RouteError('unavailable', tr('Only on Hyprland; this desktop has its own settings'));
    if (ctx.runner.which('hyprctl') == null) throw RouteError('unavailable', tr('hyprctl is missing'));
  }

  /// The stored values: {monitors: {name: {...}}, input: {key: value}, animations: {...}}.
  Map<String, dynamic> read() {
    Map<String, dynamic> part(Object? v) => v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
    try {
      final v = jsonDecode(File(stateFile).readAsStringSync());
      if (v is Map<String, dynamic>) return {'monitors': part(v['monitors']), 'input': part(v['input']), 'animations': part(v['animations'])};
    } on FileSystemException {
      // none yet
    } on FormatException {
      // a broken file counts as none; the next write replaces it
    }
    return {'monitors': <String, dynamic>{}, 'input': <String, dynamic>{}, 'animations': <String, dynamic>{}};
  }

  /// Saves [state], writes the Lua, makes sure hypr-user.lua loads it, and reloads Hyprland.
  Future<Map<String, dynamic>> write(Map<String, dynamic> state) async {
    Directory(p.dirname(stateFile)).createSync(recursive: true);
    atomicWrite(stateFile, '${const JsonEncoder.withIndent('  ').convert(state)}\n');
    Directory(hyprDir).createSync(recursive: true);
    atomicWrite(luaFile, lua(state));
    final hooked = _hook();
    final r = await ctx.runner.run(['hyprctl', 'reload'], timeout: const Duration(seconds: 10));
    return {'written': true, 'hooked': hooked, 'reloaded': r.ok};
  }

  /// The marked require line at the end of hypr-user.lua (created when missing); false when it
  /// was there already.
  bool _hook() {
    final f = File(userFile);
    final text = f.existsSync() ? f.readAsStringSync() : '-- Personal Hyprland settings, loaded last (from hyprland.lua)\n';
    if (text.contains('require, "hypr-manager")')) return false;
    atomicWrite(userFile, '${text.endsWith('\n') ? text : '$text\n'}\n$requireLine\n');
    return true;
  }

  static String _value(Object? v) => switch (v) {
    String s => jsonEncode(s), // a Lua string with the same escapes
    bool b => '$b',
    num n => '$n',
    _ => 'nil',
  };

  /// The Lua for [state]: one hl.monitor per changed monitor, one hl.config with the input, then
  /// the animations (AnimationsService.lua).
  static String lua(Map<String, dynamic> state) {
    final b = StringBuffer('-- Written by Maprisma Manager (Displays, Input devices, Animations). Changes made here by hand are\n-- replaced on the next change in the Manager; remove a value there instead.\n');
    final monitors = (state['monitors'] as Map?) ?? const {};
    for (final MapEntry(:key, :value) in monitors.entries) {
      final m = value as Map;
      b.writeln('hl.monitor({');
      b.writeln('    output = ${_value(key)},');
      for (final k in ['disabled', 'mode', 'position', 'scale', 'transform', 'vrr', 'mirror']) {
        if (m.containsKey(k)) b.writeln('    $k = ${_value(m[k])},');
      }
      b.writeln('})');
    }
    final input = (state['input'] as Map?) ?? const {};
    if (input.isNotEmpty) {
      final top = {for (final e in input.entries) if (!e.key.startsWith('touchpad.')) e.key: e.value};
      final pad = {for (final e in input.entries) if (e.key.startsWith('touchpad.')) e.key.substring(9): e.value};
      b.writeln('hl.config({');
      b.writeln('    input = {');
      for (final e in top.entries) {
        b.writeln('        ${e.key} = ${_value(e.value)},');
      }
      if (pad.isNotEmpty) {
        b.writeln('        touchpad = {');
        for (final e in pad.entries) {
          b.writeln('            ${e.key} = ${_value(e.value)},');
        }
        b.writeln('        },');
      }
      b.writeln('    },');
      b.writeln('})');
    }
    final animations = state['animations'];
    if (animations is Map<String, dynamic>) b.write(AnimationsService.lua(animations));
    return b.toString();
  }

  /// `hyprctl getoption <key> -j`'s value (int, float, str or bool), null when unknown.
  Future<Object?> option(String key) async {
    final r = await ctx.runner.run(['hyprctl', 'getoption', key, '-j'], timeout: const Duration(seconds: 5));
    if (!r.ok) return null;
    try {
      final v = jsonDecode(r.stdout);
      if (v is! Map) return null;
      for (final k in ['int', 'float', 'bool', 'str']) {
        if (v.containsKey(k)) return v[k] == '[[EMPTY]]' ? '' : v[k];
      }
    } on FormatException {
      return null;
    }
    return null;
  }

  Future<dynamic> json(List<String> args) async {
    final r = await ctx.runner.run(['hyprctl', ...args, '-j'], timeout: const Duration(seconds: 5));
    if (!r.ok) throw RouteError('failed', r.stderr.trim().isEmpty ? trf('exit {0}', [r.code]) : r.stderr.trim().split('\n').first);
    try {
      return jsonDecode(r.stdout);
    } on FormatException {
      throw RouteError('failed', tr('hyprctl gave no readable answer'));
    }
  }
}
