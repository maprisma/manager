import 'translations.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'context.dart';
import 'hypr_config.dart';

/// One animation leaf's curve, speed and style as Hyprland has it (after its parents).
typedef AnimLeaf = ({String bezier, double speed, String style, bool enabled});

/// Hyprland's animations on the Appearance page: all on/off (`animations.enabled`), windows
/// (on/off, style, speed), workspaces (on/off, style, speed) and layers (popups, launchers,
/// the bar's panels: on/off). Read live with `hyprctl animations -j`; written into the
/// Manager's hypr-manager.lua (HyprConfig, loaded last), so only what was changed here
/// overrides the user's config. A leaf needs its curve when it is written, so the curves,
/// speeds and styles the config had before the first change are kept (`base`) and every
/// later change starts from them; a reset takes all of it out again.
final class AnimationsService {
  AnimationsService(this.ctx) : hypr = HyprConfig(ctx);
  final Ctx ctx;
  final HyprConfig hypr;

  /// Hyprland's leaf tree, as far as the groups below need it (child → parent).
  static const parents = <String, String>{
    'windows': 'global',
    'windowsIn': 'windows',
    'windowsOut': 'windows',
    'windowsMove': 'windows',
    'layers': 'global',
    'layersIn': 'layers',
    'layersOut': 'layers',
    'fade': 'global',
    'fadeLayers': 'fade',
    'fadeLayersIn': 'fadeLayers',
    'fadeLayersOut': 'fadeLayers',
    'workspaces': 'global',
    'workspacesIn': 'workspaces',
    'workspacesOut': 'workspaces',
  };

  /// The leaves each group writes (every one, so a child the config set itself follows too),
  /// and those of them that take the style.
  static const groups = <String, List<String>>{
    'windows': ['windows', 'windowsIn', 'windowsOut', 'windowsMove'],
    'workspaces': ['workspaces', 'workspacesIn', 'workspacesOut'],
    'layers': ['layers', 'layersIn', 'layersOut', 'fadeLayers', 'fadeLayersIn', 'fadeLayersOut'],
  };
  static const styled = {'windows', 'windowsIn', 'windowsOut', 'workspaces', 'workspacesIn', 'workspacesOut'};

  /// The leaf whose state the page shows for a group.
  static const shown = {'windows': 'windowsIn', 'workspaces': 'workspaces', 'layers': 'layersIn'};

  /// Speed factors (2 = twice as fast, the durations halved).
  static const speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

  /// The styles offered ('' is Hyprland's default); popin and slidefade take a percentage.
  static const windowStyles = ['', 'slide', 'popin', 'gnomed'];
  static const workspaceStyles = ['', 'slide', 'slidevert', 'fade', 'slidefade', 'slidefadevert'];
  static final _windowStyle = RegExp(r'^(|slide|gnomed|popin( (\d{1,3})%)?)$');
  static final _workspaceStyle = RegExp(r'^(|slide|slidevert|fade|(slidefade|slidefadevert)( (\d{1,3})%)?)$');

  static bool validStyle(String group, String style) {
    final m = (group == 'windows' ? _windowStyle : _workspaceStyle).firstMatch(style);
    if (m == null) return false;
    final pct = m.group(m.groupCount);
    return pct == null || int.parse(pct) <= 100;
  }

  /// The keys `animations.set` takes, with their type.
  static const keys = {
    'enabled': 'bool',
    'windows.enabled': 'bool',
    'windows.style': 'style',
    'windows.speed': 'speed',
    'workspaces.enabled': 'bool',
    'workspaces.style': 'style',
    'workspaces.speed': 'speed',
    'layers.enabled': 'bool',
  };

  Future<void> _queue = Future.value();

  /// One change at a time (each reads, writes and reloads).
  Future<T> _serial<T>(Future<T> Function() f) {
    final run = _queue.then((_) => f());
    _queue = run.then((_) {}, onError: (_) {});
    return run;
  }

  /// `hyprctl animations -j`: {leaf: (bezier, speed, style, enabled)} of the overridden
  /// leaves (the others follow their parent).
  static Map<String, AnimLeaf> parseAnimations(Object? json) {
    final out = <String, AnimLeaf>{};
    if (json is! List || json.isEmpty || json.first is! List) return out;
    for (final a in json.first as List) {
      if (a is! Map || a['name'] is! String || a['overridden'] != true) continue;
      out[a['name'] as String] = (
        bezier: a['bezier'] is String ? a['bezier'] as String : '',
        speed: a['speed'] is num ? (a['speed'] as num).toDouble() : 1.0,
        style: a['style'] is String ? a['style'] as String : '',
        enabled: a['enabled'] != false,
      );
    }
    return out;
  }

  /// What [leaf] has: its own values when set, else its nearest set parent's.
  static AnimLeaf resolve(Map<String, AnimLeaf> set, String leaf) {
    for (String? l = leaf; l != null; l = parents[l]) {
      final v = set[l];
      if (v != null) return v;
    }
    return (bezier: 'default', speed: 8.0, style: '', enabled: true);
  }

  /// The base of every leaf the groups write, from Hyprland's answer.
  static Map<String, dynamic> baseFrom(Map<String, AnimLeaf> set) => {
    for (final leaf in groups.values.expand((l) => l))
      leaf: () {
        final r = resolve(set, leaf);
        return {'bezier': r.bezier.isEmpty ? 'default' : r.bezier, 'speed': r.speed, 'style': r.style, 'enabled': r.enabled};
      }(),
  };

  static String _num(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : '${double.parse(v.toStringAsFixed(2))}';

  /// The Lua for the stored animation settings (empty when nothing is set).
  static String lua(Map<String, dynamic> anim) {
    final b = StringBuffer();
    if (anim['enabled'] is bool) {
      b.writeln('hl.config({');
      b.writeln('    animations = {');
      b.writeln('        enabled = ${anim['enabled']},');
      b.writeln('    },');
      b.writeln('})');
    }
    final base = anim['base'] is Map ? anim['base'] as Map : const {};
    for (final MapEntry(key: group, value: leaves) in groups.entries) {
      final g = anim[group];
      if (g is! Map || g.isEmpty) continue;
      for (final leaf in leaves) {
        final bl = base[leaf] is Map ? base[leaf] as Map : const {};
        final bezier = bl['bezier'] is String && (bl['bezier'] as String).isNotEmpty ? bl['bezier'] as String : 'default';
        final factor = g['speed'] is num ? (g['speed'] as num).toDouble() : 1.0;
        final baseSpeed = bl['speed'] is num ? (bl['speed'] as num).toDouble() : 8.0;
        final speed = (baseSpeed / factor).clamp(0.1, 100.0);
        final enabled = g['enabled'] is bool ? g['enabled'] as bool : bl['enabled'] != false;
        final style = styled.contains(leaf) ? (g['style'] is String ? g['style'] as String : (bl['style'] is String ? bl['style'] as String : '')) : (bl['style'] is String ? bl['style'] as String : '');
        b.write('hl.animation({ leaf = ${jsonEncode(leaf)}, enabled = $enabled, speed = ${_num(speed)}, bezier = ${jsonEncode(bezier)}');
        if (style.isNotEmpty) b.write(', style = ${jsonEncode(style)}');
        b.writeln(' })');
      }
    }
    return b.toString();
  }

  Future<Map<String, AnimLeaf>> _live() async => parseAnimations(await hypr.json(['animations']));

  /// Whether the Manager can write its file and hook it in (both there or creatable).
  bool get writable {
    bool fileOk(String path) {
      final f = File(path);
      if (!f.existsSync()) return true;
      try {
        f.openSync(mode: FileMode.append).closeSync();
        return true;
      } on FileSystemException {
        return false;
      }
    }

    final dir = Directory(hypr.hyprDir);
    if (dir.existsSync() && dir.statSync().mode & 128 == 0) return false;
    return fileOk(hypr.luaFile) && fileOk(hypr.userFile);
  }

  /// The Manager's own values (without the config's kept ones).
  static Map<String, dynamic> _stored(Map<String, dynamic> anim) => {for (final e in anim.entries) if (e.key != 'base' && e.key != 'baseEnabled') e.key: e.value};

  Future<Map<String, dynamic>> get() async {
    hypr.need();
    final live = await _live();
    final enabled = await hypr.option('animations.enabled');
    final anim = hypr.read()['animations'] as Map<String, dynamic>;
    final base = anim['base'] is Map ? Map<String, dynamic>.from(anim['base'] as Map) : baseFrom(live);
    Map<String, dynamic> group(String g, {required bool fromBase}) {
      final leaf = shown[g]!;
      final r = fromBase ? base[leaf] as Map : () {
        final v = resolve(live, leaf);
        return {'enabled': v.enabled, 'style': v.style};
      }();
      final stored = anim[g] is Map ? anim[g] as Map : const {};
      return {
        'enabled': r['enabled'] != false,
        if (g != 'layers') 'style': '${r['style'] ?? ''}',
        if (g != 'layers') 'speed': fromBase ? 1.0 : (stored['speed'] is num ? (stored['speed'] as num).toDouble() : 1.0),
      };
    }

    return {
      'enabled': enabled is bool ? enabled : true,
      for (final g in groups.keys) g: group(g, fromBase: false),
      'defaults': {
        'enabled': anim['baseEnabled'] is bool ? anim['baseEnabled'] as bool : (enabled is bool ? enabled : true),
        for (final g in groups.keys) g: group(g, fromBase: true),
      },
      'stored': _stored(anim),
      'writable': writable,
      'windowStyles': windowStyles,
      'workspaceStyles': workspaceStyles,
      'speeds': speeds,
    };
  }

  /// `animations.set` {key, value}; `value: null` takes the Manager's value out.
  Future<Map<String, dynamic>> set(Map<String, dynamic> params) async {
    hypr.need();
    final key = params['key'];
    final type = keys[key];
    if (key is! String || type == null) throw RouteError('bad_params', 'key');
    final value = params['value'];
    if (value != null) {
      final ok = switch (type) {
        'bool' => value is bool,
        'speed' => value is num && speeds.contains(value.toDouble()),
        'style' => value is String && validStyle(key.split('.').first, value),
        _ => false,
      };
      if (!ok) throw RouteError('bad_params', 'value');
    }
    if (!writable) throw RouteError('refused', tr('The Hyprland config cannot be written'));
    return _serial(() async {
      final state = hypr.read();
      final anim = state['animations'] as Map<String, dynamic>;
      // The config's own curves, from before Maprisma Settings's first change.
      if (anim['base'] is! Map) {
        anim['base'] = baseFrom(await _live());
        final on = await hypr.option('animations.enabled');
        anim['baseEnabled'] = on is bool ? on : true;
      }
      if (key == 'enabled') {
        value == null ? anim.remove('enabled') : anim['enabled'] = value;
      } else {
        final [group, field] = key.split('.');
        final g = anim[group] is Map ? Map<String, dynamic>.from(anim[group] as Map) : <String, dynamic>{};
        value == null ? g.remove(field) : g[field] = type == 'speed' ? (value as num).toDouble() : value;
        g.isEmpty ? anim.remove(group) : anim[group] = g;
      }
      if (_stored(anim).isEmpty) {
        anim
          ..remove('base')
          ..remove('baseEnabled');
      }
      return await hypr.write(state);
    });
  }

  /// `animations.reset`: all of the Manager's animation settings out (the config's own again).
  Future<Map<String, dynamic>> reset() async {
    hypr.need();
    return _serial(() async {
      final state = hypr.read();
      if ((state['animations'] as Map).isEmpty) return {'written': false, 'hooked': false, 'reloaded': false};
      state['animations'] = <String, dynamic>{};
      return await hypr.write(state);
    });
  }
}
