import 'translations.dart';

import 'context.dart';
import 'hypr_config.dart';

/// One Hyprland input option the page offers: its type and range.
typedef InputOption = ({String type, num? min, num? max, List<String>? choices});

/// The Input devices page on Hyprland (COSMIC Settings' Keyboard, Mouse and Touchpad): layouts,
/// special keys, typing repeat, num lock; mouse speed, acceleration, scrolling, primary button;
/// the touchpad's tap, drag and scrolling. Read live with `hyprctl getoption`, written to
/// hypr-manager.lua (HyprConfig); a reset takes the Manager's value out again.
final class InputService {
  InputService(this.ctx) : hypr = HyprConfig(ctx);
  final Ctx ctx;
  final HyprConfig hypr;

  static const options = <String, InputOption>{
    'kb_layout': (type: 'layouts', min: null, max: null, choices: null),
    'kb_options': (type: 'kbOptions', min: null, max: null, choices: null),
    'repeat_delay': (type: 'int', min: 100, max: 2000, choices: null),
    'repeat_rate': (type: 'int', min: 1, max: 100, choices: null),
    'numlock_by_default': (type: 'bool', min: null, max: null, choices: null),
    'sensitivity': (type: 'float', min: -1, max: 1, choices: null),
    'accel_profile': (type: 'choice', min: null, max: null, choices: ['', 'adaptive', 'flat']),
    'natural_scroll': (type: 'bool', min: null, max: null, choices: null),
    'left_handed': (type: 'bool', min: null, max: null, choices: null),
    'scroll_factor': (type: 'float', min: 0.1, max: 5, choices: null),
    'touchpad.disable_while_typing': (type: 'bool', min: null, max: null, choices: null),
    'touchpad.clickfinger_behavior': (type: 'bool', min: null, max: null, choices: null),
    'touchpad.tap_to_click': (type: 'bool', min: null, max: null, choices: null),
    'touchpad.tap_and_drag': (type: 'bool', min: null, max: null, choices: null),
    'touchpad.drag_lock': (type: 'bool', min: null, max: null, choices: null),
    'touchpad.natural_scroll': (type: 'bool', min: null, max: null, choices: null),
    'touchpad.scroll_factor': (type: 'float', min: 0.1, max: 5, choices: null),
  };

  /// kb_options groups the page sets (one choice each); other options are kept.
  static const capsChoices = ['', 'caps:escape', 'caps:ctrl_modifier', 'caps:none', 'caps:backspace'];
  static const composeChoices = ['', 'compose:ralt', 'compose:menu', 'compose:rctrl', 'compose:caps'];

  List<String>? _layouts;

  /// The keyboard layouts (`localectl list-x11-keymap-layouts`).
  Future<List<String>> layouts() async {
    if (_layouts != null) return _layouts!;
    final r = await ctx.runner.run(['localectl', 'list-x11-keymap-layouts'], timeout: const Duration(seconds: 10));
    return _layouts = r.ok ? [for (final l in r.stdout.split('\n')) if (RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(l.trim())) l.trim()] : const [];
  }

  Future<Map<String, dynamic>> get() async {
    hypr.need();
    final keys = options.keys.toList();
    final read = await Future.wait([for (final k in keys) hypr.option('input.$k')]);
    final values = <String, Object?>{for (var i = 0; i < keys.length; i++) keys[i]: read[i]};
    final devices = await hypr.json(['devices']) as Map;
    final mice = [for (final m in (devices['mice'] as List? ?? const [])) '${(m as Map)['name']}'];
    return {
      'values': values,
      'stored': hypr.read()['input'],
      'touchpad': mice.any((n) => RegExp(r'touchpad|trackpad|synaptics|elan|alps', caseSensitive: false).hasMatch(n)),
      'layouts': await layouts(),
      'capsChoices': capsChoices,
      'composeChoices': composeChoices,
    };
  }

  /// `input.set` {key, value}; `value: null` takes the Manager's value out (back to the config's).
  Future<Map<String, dynamic>> set(Map<String, dynamic> params) async {
    hypr.need();
    final key = params['key'];
    final o = options[key];
    if (key is! String || o == null) throw RouteError('bad_params', 'key');
    final value = params['value'];
    if (value != null) {
      final ok = switch (o.type) {
        'bool' => value is bool,
        'int' => value is int && value >= o.min! && value <= o.max!,
        'float' => value is num && value >= o.min! && value <= o.max!,
        'choice' => value is String && o.choices!.contains(value),
        'layouts' => value is String && value.isNotEmpty && value.split(',').length <= 4 && value.split(',').every((l) => RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(l)),
        'kbOptions' => value is String && value.length <= 200 && (value.isEmpty || value.split(',').every((x) => RegExp(r'^[a-z0-9_]+:[a-z0-9_]+$').hasMatch(x))),
        _ => false,
      };
      if (!ok) throw RouteError('bad_params', 'value');
      if (o.type == 'layouts') {
        final known = await layouts();
        if (known.isNotEmpty && !value.split(',').every(known.contains)) throw RouteError('bad_params', tr('unknown keyboard layout'));
      }
    }
    final state = hypr.read();
    final input = state['input'] as Map<String, dynamic>;
    if (value == null) {
      input.remove(key);
    } else {
      input[key] = o.type == 'float' ? (value as num).toDouble() : value;
    }
    return await hypr.write(state);
  }
}
