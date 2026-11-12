import 'translations.dart';
import 'dart:async';

import 'context.dart';
import 'hypr_config.dart';

/// The Displays page on Hyprland (COSMIC Settings' Displays without the arrangement canvas and
/// Night Light): per monitor on/off, resolution with refresh rate, scale, orientation, variable
/// refresh rate, position and mirroring. Read with `hyprctl monitors all`, written to
/// hypr-manager.lua (HyprConfig). Every change goes back by itself after [keepFor] unless it is
/// kept (`displays.keep`, COSMIC's "Keep changes?"): here in the core, so a closed or slow page
/// can't leave a mode the screen can't show. Further changes before that go back to the values
/// before the first one.
final class DisplaysService {
  DisplaysService(this.ctx) : hypr = HyprConfig(ctx);
  final Ctx ctx;
  final HyprConfig hypr;

  /// The monitors' stored values before the changes not kept yet (null: nothing to undo).
  Map<String, dynamic>? _undo;

  /// How long a change waits to be kept.
  Duration keepFor = const Duration(seconds: 15);
  Timer? _revert;

  /// A change was made and is neither kept nor undone yet.
  bool _unkept = false;

  /// Changes, keeps, undos and the timer's undo run one after the other (a write awaits
  /// `hyprctl reload`, and the window may send the next request meanwhile).
  Future<void> _queue = Future<void>.value();
  Future<T> _serial<T>(Future<T> Function() f) {
    final run = _queue.then((_) => f());
    _queue = run.then((_) {}, onError: (_) {});
    return run;
  }

  static const scales = [1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0];
  static const positions = ['auto', 'auto-right', 'auto-left', 'auto-up', 'auto-down', 'auto-center-right', 'auto-center-left'];

  /// "3840x2160@120.00Hz" → "3840x2160@120.00".
  static String modeOf(String m) => m.endsWith('Hz') ? m.substring(0, m.length - 2) : m;

  Future<Map<String, dynamic>> get() async {
    hypr.need();
    final list = (await hypr.json(['monitors', 'all']) as List).cast<Map>();
    final stored = (hypr.read()['monitors'] as Map);
    return {
      'monitors': [
        for (final m in list)
          {
            'name': m['name'],
            'description': m['description'],
            'enabled': m['disabled'] != true,
            'mode': '${m['width']}x${m['height']}@${(m['refreshRate'] as num).toStringAsFixed(2)}',
            'modes': [for (final x in (m['availableModes'] as List? ?? const [])) modeOf('$x')],
            'scale': (m['scale'] as num).toDouble(),
            'transform': m['transform'] ?? 0,
            'vrr': m['vrr'] == true,
            'position': '${m['x']}x${m['y']}',
            'mirror': m['mirrorOf'] == null || m['mirrorOf'] == 'none' ? null : m['mirrorOf'],
            'stored': stored[m['name']] ?? const {},
          },
      ],
      'scales': scales,
      'positions': positions,
      'canUndo': _undo != null,
      'pending': _unkept,
    };
  }

  /// `displays.set` {output, and any of: disabled, mode, scale, transform, vrr, position, mirror}.
  Future<Map<String, dynamic>> set(Map<String, dynamic> params) => _serial(() => _set(params));

  Future<Map<String, dynamic>> _set(Map<String, dynamic> params) async {
    hypr.need();
    final output = params['output'];
    final now = (await get())['monitors'] as List;
    final mon = now.cast<Map>().where((m) => m['name'] == output).firstOrNull;
    if (mon == null) throw RouteError('bad_params', 'output');
    final change = <String, Object?>{};
    for (final MapEntry(:key, :value) in params.entries) {
      switch (key) {
        case 'output':
          continue;
        case 'disabled':
          if (value is! bool) throw RouteError('bad_params', 'disabled');
          if (value && now.cast<Map>().where((m) => m['enabled'] == true && m['name'] != output).isEmpty) {
            throw RouteError('refused', tr('This is the only display that is on'));
          }
          change[key] = value;
        case 'mode':
          if (value is! String || !(mon['modes'] as List).contains(value)) throw RouteError('bad_params', 'mode');
          change[key] = value;
        case 'scale':
          if (value is! num || !scales.contains(value.toDouble())) throw RouteError('bad_params', 'scale');
          change[key] = value.toDouble();
        case 'transform':
          if (value is! int || value < 0 || value > 3) throw RouteError('bad_params', 'transform (0–3)');
          change[key] = value;
        case 'vrr':
          if (value is! int || value < 0 || value > 2) throw RouteError('bad_params', 'vrr (0–2)');
          change[key] = value;
        case 'position':
          if (value is! String || !(positions.contains(value) || RegExp(r'^-?\d{1,5}x-?\d{1,5}$').hasMatch(value))) throw RouteError('bad_params', 'position');
          change[key] = value;
        case 'mirror':
          if (value != null && (value is! String || value == output || !now.cast<Map>().any((m) => m['name'] == value))) throw RouteError('bad_params', 'mirror');
          change[key] = value;
        default:
          throw RouteError('bad_params', key);
      }
    }
    if (change.isEmpty) throw RouteError('bad_params', tr('nothing to change'));
    final state = hypr.read();
    // A change on top of one not kept yet goes back to where the first one started.
    if (!_unkept || _undo == null) {
      _undo = {for (final e in (state['monitors'] as Map).entries) e.key as String: Map<String, dynamic>.from(e.value as Map)};
    }
    _unkept = true;
    _revert?.cancel();
    _revert = null;
    final monitors = state['monitors'] as Map<String, dynamic>;
    // A monitor's line always carries its mode and position: Hyprland needs both.
    final entry = Map<String, dynamic>.from((monitors[output] as Map?) ?? {'mode': mon['mode'], 'position': mon['position'], 'scale': mon['scale']});
    for (final MapEntry(:key, :value) in change.entries) {
      if (value == null) {
        entry.remove(key);
      } else {
        entry[key] = value;
      }
    }
    monitors[output as String] = entry;
    // The countdown starts when the change is on screen (after the reload).
    final written = await hypr.write(state);
    _revert = Timer(keepFor, () => unawaited(_serial(_goBack)));
    return {...written, 'canUndo': true, 'revertIn': keepFor.inSeconds};
  }

  /// The change was not kept in time (in the queue: never in the middle of another change).
  Future<void> _goBack() async {
    _revert = null;
    if (!_unkept || _undo == null) return;
    try {
      await _undoNow();
    } on Object {
      // nothing more to do here: the page shows the state as it is
    }
  }

  /// `displays.keep`: the changes stay (and can't be undone any more); `kept: false` when they
  /// had gone back already.
  Future<Map<String, dynamic>> keep() => _serial(() async {
    final had = _unkept;
    _revert?.cancel();
    _revert = null;
    _unkept = false;
    _undo = null;
    return {'kept': had};
  });

  /// `displays.undo`: the monitors as before the changes not kept yet.
  Future<Map<String, dynamic>> undo() => _serial(() {
    hypr.need();
    return _undoNow();
  });

  Future<Map<String, dynamic>> _undoNow() async {
    _revert?.cancel();
    _revert = null;
    final before = _undo;
    if (before == null) throw RouteError('unavailable', tr('Nothing to undo'));
    final state = hypr.read();
    state['monitors'] = before;
    _undo = null;
    _unkept = false;
    return await hypr.write(state);
  }
}
