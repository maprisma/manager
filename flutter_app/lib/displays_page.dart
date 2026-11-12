import 'dart:async';

import 'package:flutter/material.dart';
import 'package:maprisma_manager_core/maprisma_manager_core.dart' show tr, trf;

import 'backend.dart' show ServiceError;
import 'core_call.dart';
import 'desktop_page.dart';
import 'settings_widgets.dart';

/// Displays, as COSMIC Settings' page without the arrangement canvas: per display on/off,
/// resolution, refresh rate, scale, orientation, variable refresh rate, position and
/// mirroring. Hyprland: `displays.*`; every change asks "Keep these display settings?" and goes
/// back by itself after [keepSeconds] (a mode the screen can't show leaves it black).
class DisplaysPage extends StatelessWidget {
  const DisplaysPage({super.key, required this.core, this.keepSeconds = 15});
  final CoreCall core;
  final int keepSeconds;
  @override
  Widget build(BuildContext context) => DesktopSettingsPage(
    core: core,
    page: 'displays',
    title: tr('Displays'),
    what: tr('the displays'),
    own: (_) => _Displays(core: core, keepSeconds: keepSeconds),
  );
}

class _Displays extends StatefulWidget {
  const _Displays({required this.core, required this.keepSeconds});
  final CoreCall core;
  final int keepSeconds;
  @override
  State<_Displays> createState() => _DisplaysState();
}

class _DisplaysState extends State<_Displays> with RoutePage {
  @override
  CoreCall get core => widget.core;
  @override
  String get getRoute => 'displays.get';

  static String orientation(int t) => switch (t) {
    1 => tr('Rotate 90°'),
    2 => tr('Rotate 180°'),
    3 => tr('Rotate 270°'),
    _ => tr('Standard'),
  };

  static String position(String p) => switch (p) {
    'auto' => tr('Automatic'),
    'auto-right' => tr('Right of the others'),
    'auto-left' => tr('Left of the others'),
    'auto-up' => tr('Above the others'),
    'auto-down' => tr('Below the others'),
    'auto-center-right' => tr('Right, centred'),
    'auto-center-left' => tr('Left, centred'),
    _ => p,
  };

  static String scale(num s) => '${(s * 100).round()} %';

  /// Changes [output] and asks at once whether to keep it. The core goes back by itself when it
  /// isn't kept in time, also when this page is gone meanwhile; Revert goes back now.
  Future<void> change(String output, Map<String, dynamic> values) async {
    final ok = await act('displays.set', {'output': output, ...values}, reload: false);
    if (!ok || !mounted) return;
    // The dialog ends a second before the core goes back, so a Keep in time is never too late.
    final keep = await showDialog<bool>(context: context, barrierDismissible: false, builder: (_) => _KeepDialog(seconds: widget.keepSeconds - 1));
    if (!mounted) return; // the core goes back by itself
    if (keep == true) {
      try {
        final r = await core('displays.keep');
        if (r['kept'] != true) tellOn(this, tr('Too late: the previous display settings are back'));
      } on ServiceError catch (e) {
        tellOn(this, failure(e));
      }
      if (mounted) await load();
    } else if (keep == false) {
      await act('displays.undo', const {});
    } else {
      // the time ran out: the core is going back by itself
      await Future<void>.delayed(const Duration(milliseconds: 800));
      if (mounted) await load();
    }
  }

  Widget _monitor(Map m, List<Map> all, Map d) {
    final name = '${m['name']}';
    final modes = (m['modes'] as List).cast<String>();
    final res = '${m['mode']}'.split('@').first;
    final resolutions = <String>{for (final x in modes) x.split('@').first}.toList();
    if (!resolutions.contains(res)) resolutions.insert(0, res);
    final rates = [for (final x in modes) if (x.startsWith('$res@')) x];
    if (!rates.contains(m['mode'])) rates.insert(0, '${m['mode']}');
    final vrr = (m['stored'] as Map)['vrr'] as int? ?? (m['vrr'] == true ? 1 : 0);
    final others = [for (final o in all) if (o['name'] != name) '${o['name']}'];
    final scales = [for (final s in (d['scales'] as List)) (s as num).toDouble()];
    final s = (m['scale'] as num).toDouble();
    if (!scales.contains(s)) scales.insert(0, s);
    final positions = (d['positions'] as List).cast<String>();
    final storedPos = (m['stored'] as Map)['position'] as String?;
    final pos = storedPos ?? '${m['position']}';
    return SettingsSection(
      key: ValueKey('display-$name'),
      title: '${m['description'] ?? name} ($name)',
      children: [
        if (all.length > 1)
          SettingsToggle(
            key: ValueKey('display-on-$name'),
            title: tr('Enable display'),
            value: m['enabled'] == true,
            onChanged: working ? null : (v) => change(name, {'disabled': !v}),
          ),
        if (m['enabled'] == true) ...[
          SettingsChoice<String>(
            key: ValueKey('display-resolution-$name'),
            title: tr('Resolution'),
            value: res,
            choices: [for (final r in resolutions) (r, r.replaceAll('x', ' × '))],
            onChanged: working ? null : (r) {
              // the highest refresh rate of that resolution
              final best = ([for (final x in modes) if (x.startsWith('$r@')) x]..sort((a, b) => double.parse(b.split('@')[1]).compareTo(double.parse(a.split('@')[1])))).firstOrNull;
              if (best != null) change(name, {'mode': best});
            },
          ),
          SettingsChoice<String>(
            key: ValueKey('display-rate-$name'),
            title: tr('Refresh rate'),
            value: '${m['mode']}',
            choices: [for (final x in rates) (x, '${double.parse(x.split('@')[1]).toStringAsFixed(2)} Hz')],
            onChanged: working ? null : (x) => change(name, {'mode': x}),
          ),
          SettingsChoice<int>(
            key: ValueKey('display-vrr-$name'),
            title: tr('Variable refresh rate'),
            value: vrr,
            choices: [(0, tr('Disabled')), (1, tr('Always')), (2, tr('Automatic'))],
            onChanged: working ? null : (v) => change(name, {'vrr': v}),
          ),
          SettingsChoice<double>(
            key: ValueKey('display-scale-$name'),
            title: tr('Scale'),
            value: s,
            choices: [for (final x in scales) (x, scale(x))],
            onChanged: working ? null : (x) => change(name, {'scale': x}),
          ),
          SettingsChoice<int>(
            key: ValueKey('display-orientation-$name'),
            title: tr('Orientation'),
            value: m['transform'] as int? ?? 0,
            choices: [for (final t in [0, 1, 2, 3]) (t, orientation(t))],
            onChanged: working ? null : (t) => change(name, {'transform': t}),
          ),
          if (all.length > 1) ...[
            SettingsChoice<String>(
              key: ValueKey('display-position-$name'),
              title: tr('Position'),
              value: positions.contains(pos) ? pos : '${m['position']}',
              choices: [
                if (!positions.contains(pos)) ('${m['position']}', trf('At {0}', ['${m['position']}'.replaceAll('x', ', ')])),
                for (final p in positions) (p, position(p)),
              ],
              onChanged: working ? null : (p) => change(name, {'position': p}),
            ),
            SettingsChoice<String>(
              key: ValueKey('display-mirror-$name'),
              title: tr('Mirroring'),
              value: m['mirror'] as String? ?? '',
              choices: [('', tr('Don\'t mirror')), for (final o in others) (o, trf('Mirror {0}', [o]))],
              onChanged: working ? null : (o) => change(name, {'mirror': o.isEmpty ? null : o}),
            ),
          ],
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = data;
    if (d == null) return SettingsPage(title: tr('Displays'), actions: reloadActions(), children: loadingOrError(context));
    final all = (d['monitors'] as List).cast<Map>();
    return SettingsPage(
      title: tr('Displays'),
      actions: reloadActions(),
      children: [
        for (final m in all) _monitor(m, all, d),
        Text(tr('Saved in ~/.config/hypr/hypr-manager.lua, which Hyprland loads after your own config.'), style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
      ],
    );
  }
}

/// "Keep these display settings?" with a countdown; true keeps them.
class _KeepDialog extends StatefulWidget {
  const _KeepDialog({required this.seconds});
  final int seconds;
  @override
  State<_KeepDialog> createState() => _KeepDialogState();
}

class _KeepDialogState extends State<_KeepDialog> {
  late int left = widget.seconds;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return;
      if (--left <= 0) {
        t.cancel();
        Navigator.pop(context);
      } else {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(tr('Keep these display settings?')),
    content: Text(trf('Going back to the previous settings in {0} s.', [left])),
    actions: [
      TextButton(key: const ValueKey('display-revert'), onPressed: () => Navigator.pop(context, false), child: Text(tr('Revert'))),
      FilledButton(key: const ValueKey('display-keep'), onPressed: () => Navigator.pop(context, true), child: Text(tr('Keep changes'))),
    ],
  );
}
