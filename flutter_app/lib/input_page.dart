import 'package:flutter/material.dart';
import 'package:maprisma_manager_core/maprisma_manager_core.dart' show tr;

import 'backend.dart' show ServiceError;
import 'core_call.dart';
import 'desktop_page.dart';
import 'settings_widgets.dart';

/// Input devices, as COSMIC Settings' Keyboard, Mouse and Touchpad pages: keyboard layouts,
/// special keys, typing repeat, num lock and the shortcuts (Maprisma Launcher); mouse speed,
/// acceleration, scrolling and the primary button; the touchpad's taps and scrolling (only with
/// a touchpad). Hyprland: `input.*` (hypr-manager.lua).
class InputPage extends StatelessWidget {
  const InputPage({super.key, required this.core});
  final CoreCall core;
  @override
  Widget build(BuildContext context) => DesktopSettingsPage(
    core: core,
    page: 'input',
    title: tr('Input devices'),
    what: tr('the keyboard, mouse and touchpad'),
    own: (_) => _Input(core: core),
    // COSMIC/KDE: their settings app has the devices, the app shortcuts stay in Maprisma Launcher
    alsoNative: (_) => [ShortcutsSection(core: core)],
  );
}

/// "Keyboard shortcuts": the app shortcuts are set in Maprisma Launcher (every desktop).
class ShortcutsSection extends StatelessWidget {
  const ShortcutsSection({super.key, required this.core, this.open});
  final CoreCall core;

  /// How the button opens the Launcher (the own page: its act with the busy state).
  final VoidCallback? open;

  @override
  Widget build(BuildContext context) => SettingsSection(
    title: tr('Keyboard shortcuts'),
    children: [
      SettingsItem(
        title: tr('View and customize shortcuts'),
        description: tr('App shortcuts are set in Maprisma Launcher.'),
        trailing: FilledButton.tonal(
          key: const ValueKey('input-shortcuts'),
          onPressed: open ??
              () async {
                try {
                  await core('apps.open', {'id': 'launcher'});
                } on ServiceError catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context)
                      ..hideCurrentSnackBar()
                      ..showSnackBar(SnackBar(content: Text(failure(e))));
                  }
                }
              },
          child: Text(tr('Open Maprisma Launcher')),
        ),
      ),
    ],
  );
}

class _Input extends StatefulWidget {
  const _Input({required this.core});
  final CoreCall core;
  @override
  State<_Input> createState() => _InputState();
}

class _InputState extends State<_Input> with RoutePage {
  @override
  CoreCall get core => widget.core;
  @override
  String get getRoute => 'input.get';

  Map get values => data!['values'] as Map;

  Future<void> set(String key, Object? value) => act('input.set', {'key': key, 'value': value});

  bool flag(String key) => values[key] == true;
  double number(String key, double fallback) => values[key] is num ? (values[key] as num).toDouble() : fallback;

  /// kb_options with one group (caps:, compose:) set to [choice] and the other options kept.
  String get kbOptions => values['kb_options'] is String ? values['kb_options'] as String : '';

  String withOption(String group, String choice) {
    final now = kbOptions.split(',').where((x) => x.isNotEmpty && !x.startsWith('$group:')).toList();
    if (choice.isNotEmpty) now.add(choice);
    return now.join(',');
  }

  String option(String group) => kbOptions.split(',').firstWhere((x) => x.startsWith('$group:'), orElse: () => '');

  static String capsName(String c) => switch (c) {
    'caps:escape' => tr('Escape'),
    'caps:ctrl_modifier' => tr('Ctrl'),
    'caps:none' => tr('Off'),
    'caps:backspace' => tr('Backspace'),
    _ => tr('Caps Lock'),
  };

  static String composeName(String c) => switch (c) {
    'compose:ralt' => tr('Right Alt'),
    'compose:menu' => tr('Menu'),
    'compose:rctrl' => tr('Right Ctrl'),
    'compose:caps' => tr('Caps Lock'),
    _ => tr('None'),
  };

  /// A second layout also gets a key to switch (Alt+Shift) unless a grp: option is set already.
  Future<void> _second(String first, String l) async {
    if (!await act('input.set', {'key': 'kb_layout', 'value': [first, if (l.isNotEmpty && l != first) l].join(',')})) return;
    if (l.isNotEmpty && option('grp').isEmpty) await set('kb_options', withOption('grp', 'grp:alt_shift_toggle'));
  }

  List<Widget> _keyboard(Map d) {
    final layouts = (d['layouts'] as List).cast<String>();
    final now = (values['kb_layout'] is String ? values['kb_layout'] as String : '').split(',').where((l) => l.isNotEmpty).toList();
    final first = now.isEmpty ? '' : now.first;
    final second = now.length > 1 ? now[1] : '';
    List<(String, String)> choices(String current, {bool none = false}) => [
      if (none) ('', tr('None')),
      if (current.isNotEmpty && !layouts.contains(current)) (current, current),
      for (final l in layouts) (l, l),
    ];
    final caps = option('caps'), compose = option('compose');
    return [
      SettingsSection(
        title: tr('Input sources'),
        note: second.isEmpty ? null : tr('Alt+Shift switches between the two layouts.'),
        children: [
          SettingsChoice<String>(
            key: const ValueKey('input-layout-1'),
            title: tr('Keyboard layout'),
            value: first,
            choices: choices(first),
            onChanged: working ? null : (l) => set('kb_layout', [l, if (second.isNotEmpty && second != l) second].join(',')),
          ),
          SettingsChoice<String>(
            key: const ValueKey('input-layout-2'),
            title: tr('Second layout'),
            value: second,
            choices: choices(second, none: true),
            onChanged: working || first.isEmpty ? null : (l) => _second(first, l),
          ),
        ],
      ),
      SettingsSection(
        title: tr('Special character entry'),
        children: [
          SettingsChoice<String>(
            key: const ValueKey('input-caps'),
            title: tr('Caps Lock key'),
            value: caps,
            choices: [for (final c in (d['capsChoices'] as List).cast<String>()) (c, capsName(c))],
            onChanged: working ? null : (c) => set('kb_options', withOption('caps', c)),
          ),
          SettingsChoice<String>(
            key: const ValueKey('input-compose'),
            title: tr('Compose key'),
            value: compose,
            choices: [for (final c in (d['composeChoices'] as List).cast<String>()) (c, composeName(c))],
            onChanged: working ? null : (c) => set('kb_options', withOption('compose', c)),
          ),
        ],
      ),
      SettingsSection(
        title: tr('Typing'),
        children: [
          SettingsSlider(
            key: const ValueKey('input-repeat-delay'),
            title: tr('Repeat delay'),
            value: number('repeat_delay', 600),
            min: 100,
            max: 1000,
            divisions: 18,
            label: (v) => '${v.round()} ms',
            onChangeEnd: working ? null : (v) => set('repeat_delay', v.round()),
          ),
          SettingsSlider(
            key: const ValueKey('input-repeat-rate'),
            title: tr('Repeat rate'),
            value: number('repeat_rate', 25),
            min: 5,
            max: 60,
            divisions: 11,
            label: (v) => '${v.round()}/s',
            onChangeEnd: working ? null : (v) => set('repeat_rate', v.round()),
          ),
          SettingsToggle(
            key: const ValueKey('input-numlock'),
            title: tr('Num Lock on at login'),
            value: flag('numlock_by_default'),
            onChanged: working ? null : (v) => set('numlock_by_default', v),
          ),
        ],
      ),
      ShortcutsSection(core: core, open: () => act('apps.open', {'id': 'launcher'}, reload: false)),
    ];
  }

  List<Widget> _mouse() => [
    SettingsSection(
      title: tr('Mouse'),
      children: [
        SettingsChoice<bool>(
          key: const ValueKey('input-primary'),
          title: tr('Primary button'),
          value: flag('left_handed'),
          choices: [(false, tr('Left')), (true, tr('Right'))],
          onChanged: working ? null : (v) => set('left_handed', v),
        ),
        SettingsSlider(
          key: const ValueKey('input-speed'),
          title: tr('Mouse speed'),
          value: number('sensitivity', 0),
          min: -1,
          max: 1,
          divisions: 20,
          label: (v) => v.toStringAsFixed(1),
          onChangeEnd: working ? null : (v) => set('sensitivity', double.parse(v.toStringAsFixed(2))),
        ),
        SettingsToggle(
          key: const ValueKey('input-accel'),
          title: tr('Mouse acceleration'),
          value: values['accel_profile'] != 'flat',
          onChanged: working ? null : (v) => set('accel_profile', v ? 'adaptive' : 'flat'),
        ),
        SettingsSlider(
          key: const ValueKey('input-scroll-speed'),
          title: tr('Scrolling speed'),
          value: number('scroll_factor', 1),
          min: 0.2,
          max: 3,
          divisions: 14,
          label: (v) => '${v.toStringAsFixed(1)}×',
          onChangeEnd: working ? null : (v) => set('scroll_factor', double.parse(v.toStringAsFixed(2))),
        ),
        SettingsToggle(
          key: const ValueKey('input-natural'),
          title: tr('Natural scrolling'),
          description: tr('Scrolling moves the content, not the view.'),
          value: flag('natural_scroll'),
          onChanged: working ? null : (v) => set('natural_scroll', v),
        ),
      ],
    ),
  ];

  List<Widget> _touchpad() => [
    SettingsSection(
      title: tr('Touchpad'),
      children: [
        SettingsToggle(key: const ValueKey('pad-typing'), title: tr('Disable while typing'), value: flag('touchpad.disable_while_typing'), onChanged: working ? null : (v) => set('touchpad.disable_while_typing', v)),
        SettingsToggle(key: const ValueKey('pad-tap'), title: tr('Tap to click'), value: flag('touchpad.tap_to_click'), onChanged: working ? null : (v) => set('touchpad.tap_to_click', v)),
        SettingsToggle(key: const ValueKey('pad-drag'), title: tr('Tap and drag'), value: flag('touchpad.tap_and_drag'), onChanged: working ? null : (v) => set('touchpad.tap_and_drag', v)),
        SettingsToggle(key: const ValueKey('pad-lock'), title: tr('Drag lock'), value: flag('touchpad.drag_lock'), onChanged: working ? null : (v) => set('touchpad.drag_lock', v)),
        SettingsChoice<bool>(
          key: const ValueKey('pad-click'),
          title: tr('Secondary click'),
          value: flag('touchpad.clickfinger_behavior'),
          choices: [(true, tr('Two fingers')), (false, tr('Bottom right corner'))],
          onChanged: working ? null : (v) => set('touchpad.clickfinger_behavior', v),
        ),
        SettingsSlider(
          key: const ValueKey('pad-scroll-speed'),
          title: tr('Scrolling speed'),
          value: number('touchpad.scroll_factor', 1),
          min: 0.2,
          max: 3,
          divisions: 14,
          label: (v) => '${v.toStringAsFixed(1)}×',
          onChangeEnd: working ? null : (v) => set('touchpad.scroll_factor', double.parse(v.toStringAsFixed(2))),
        ),
        SettingsToggle(key: const ValueKey('pad-natural'), title: tr('Natural scrolling'), value: flag('touchpad.natural_scroll'), onChanged: working ? null : (v) => set('touchpad.natural_scroll', v)),
      ],
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final d = data;
    if (d == null) return SettingsPage(title: tr('Input devices'), actions: reloadActions(), children: loadingOrError(context));
    return SettingsPage(
      title: tr('Input devices'),
      actions: reloadActions(),
      children: [
        ..._keyboard(d),
        ..._mouse(),
        if (d['touchpad'] == true) ..._touchpad(),
        Text(tr('Saved in ~/.config/hypr/hypr-manager.lua, which Hyprland loads after your own config.'), style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
      ],
    );
  }
}
