import 'dart:async';

import 'package:flutter/material.dart';
import 'package:maprisma_manager_core/maprisma_manager_core.dart' show tr;

import 'backend.dart' show ServiceError;
import 'core_call.dart';
import 'desktop_page.dart';
import 'settings_widgets.dart';

/// Hyprland's animations on the Appearance page (`animations.*`, written to hypr-manager.lua):
/// all on/off; windows and workspaces on/off, style and speed; popups and launchers (layers)
/// on/off; back to the config's own. Not shown where `animations.get` is unavailable (other
/// desktops, no hyprctl).
class AnimationsCard extends StatefulWidget {
  const AnimationsCard({super.key, required this.core});
  final CoreCall core;
  @override
  State<AnimationsCard> createState() => _AnimationsCardState();
}

class _AnimationsCardState extends State<AnimationsCard> with RoutePage {
  @override
  CoreCall get core => widget.core;
  @override
  String get getRoute => 'animations.get';

  /// `animations.get` said this desktop has none (not Hyprland): the card is not there.
  bool unavailable = false;

  @override
  Future<void> load() async {
    try {
      final r = await core(getRoute);
      if (mounted) {
        setState(() {
          data = r;
          error = null;
        });
      }
    } on ServiceError catch (e) {
      if (!mounted) return;
      if (e.code == 'unavailable') {
        setState(() => unavailable = true);
      } else if (data != null) {
        tellOn(this, failure(e));
      } else {
        setState(() => error = failure(e));
      }
    }
  }

  /// The percentage the style takes, when one does (and its default).
  static const percent = {'popin': 80, 'slidefade': 20, 'slidefadevert': 20};

  static String styleName(String s) => switch (s) {
    'slide' => tr('Slide'),
    'popin' => tr('Pop in'),
    'gnomed' => tr('GNOME-like'),
    'slidevert' => tr('Slide vertically'),
    'fade' => tr('Fade'),
    'slidefade' => tr('Slide and fade'),
    'slidefadevert' => tr('Slide and fade vertically'),
    '' => tr('Default'),
    _ => s,
  };

  static String speedName(double f) => '${f == f.roundToDouble() ? f.toStringAsFixed(0) : '$f'}×';

  Future<void> set(String key, Object? value) => act('animations.set', {'key': key, 'value': value});

  List<Widget> _group(Map d, String group, {required bool on, required String title, required String what}) {
    final g = d[group] as Map;
    final enabled = g['enabled'] == true;
    final style = '${g['style'] ?? ''}';
    final name = style.split(' ').first;
    final pct = int.tryParse(RegExp(r'(\d+)%').firstMatch(style)?.group(1) ?? '');
    final styles = ((group == 'windows' ? d['windowStyles'] : d['workspaceStyles']) as List).cast<String>();
    final speeds = [for (final s in d['speeds'] as List) (s as num).toDouble()];
    final factor = (g['speed'] as num?)?.toDouble() ?? 1.0;
    final index = speeds.contains(factor) ? speeds.indexOf(factor) : speeds.indexOf(1.0);
    final live = on && enabled && !working && d['writable'] == true;
    return [
      SettingsToggle(
        key: ValueKey('anim-$group'),
        title: title,
        description: what,
        value: enabled,
        onChanged: on && !working && d['writable'] == true ? (v) => set('$group.enabled', v) : null,
      ),
      SettingsChoice<String>(
        key: ValueKey('anim-$group-style'),
        title: group == 'windows' ? tr('Window style') : tr('Workspace style'),
        value: name,
        choices: [
          for (final s in styles) (s, styleName(s)),
          if (!styles.contains(name)) (name, styleName(name)),
        ],
        onChanged: live ? (s) => set('$group.style', percent.containsKey(s) ? '$s ${pct ?? percent[s]}%' : s) : null,
      ),
      if (percent.containsKey(name))
        SettingsSlider(
          key: ValueKey('anim-$group-percent'),
          title: name == 'popin' ? tr('Pop-in size') : tr('Fade distance'),
          value: (pct ?? percent[name]!).toDouble(),
          min: 10,
          max: 100,
          divisions: 18,
          label: (v) => '${v.round()} %',
          onChangeEnd: live ? (v) => set('$group.style', '$name ${v.round()}%') : null,
        ),
      SettingsSlider(
        key: ValueKey('anim-$group-speed'),
        title: group == 'windows' ? tr('Window speed') : tr('Workspace speed'),
        description: tr('Faster to the right'),
        value: index.toDouble(),
        min: 0,
        max: (speeds.length - 1).toDouble(),
        divisions: speeds.length - 1,
        label: (v) => speedName(speeds[v.round()]),
        onChangeEnd: live ? (v) => set('$group.speed', speeds[v.round()]) : null,
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    if (unavailable) return const SizedBox.shrink();
    final d = data;
    if (d == null) {
      return SettingsSection(title: tr('Animations (Hyprland)'), children: [Padding(padding: const EdgeInsets.all(12), child: Column(children: loadingOrError(context)))]);
    }
    final writable = d['writable'] == true;
    final on = d['enabled'] == true;
    final stored = (d['stored'] as Map?) ?? const {};
    return SettingsSection(
      key: const ValueKey('anim-card'),
      title: tr('Animations (Hyprland)'),
      note: writable ? tr('Saved in ~/.config/hypr/hypr-manager.lua; Hyprland reloads its config.') : tr('The Hyprland config cannot be written'),
      children: [
        SettingsToggle(
          key: const ValueKey('anim-enabled'),
          title: tr('Animations'),
          description: tr('All of Hyprland\'s animations'),
          value: on,
          onChanged: writable && !working ? (v) => set('enabled', v) : null,
        ),
        ..._group(d, 'windows', on: on, title: tr('Windows'), what: tr('Opening, closing and moving windows')),
        ..._group(d, 'workspaces', on: on, title: tr('Workspaces'), what: tr('Switching workspaces')),
        SettingsToggle(
          key: const ValueKey('anim-layers'),
          title: tr('Popups and launchers'),
          description: tr('Menus, launchers, notifications and the bar\'s panels'),
          value: (d['layers'] as Map)['enabled'] == true,
          onChanged: on && writable && !working ? (v) => set('layers.enabled', v) : null,
        ),
        SettingsItem(
          title: tr('Reset to the defaults'),
          description: tr('Takes these settings out again; the Hyprland config\'s own animations apply.'),
          trailing: OutlinedButton(
            key: const ValueKey('anim-reset'),
            onPressed: stored.isEmpty || working || !writable ? null : () => unawaited(act('animations.reset', const {})),
            child: Text(tr('Reset')),
          ),
        ),
      ],
    );
  }
}
