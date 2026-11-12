import 'dart:async';

import 'package:flutter/material.dart';
import 'package:maprisma_manager_core/maprisma_manager_core.dart' show tr, trf;

import 'backend.dart' show ServiceError;
import 'core_call.dart';
import 'settings_widgets.dart';

/// Power, as COSMIC Settings' Power & Battery page: the power mode and the idle times
/// (lock, screens off, suspend). COSMIC and KDE have their own settings app for it, so there
/// the page only opens theirs; on Hyprland it sets Maprisma Shell's idle times (`power.*`).
class PowerPage extends StatefulWidget {
  const PowerPage({super.key, required this.core});
  final CoreCall core;
  @override
  State<PowerPage> createState() => PowerPageState();
}

/// The idle choices in seconds (0: never, listed last), COSMIC Settings' lists where it has one:
/// "Turn off the screen after" and "Automatic suspend" (with 5 and 10 minutes, Maprisma Shell's
/// default being 10); the lock gets short times.
const idleChoices = {
  'lock': [60, 120, 180, 300, 600, 900, 1800, 0],
  'screenOff': [120, 300, 600, 900, 1800, 0],
  'suspend': [300, 600, 900, 1200, 1500, 1800, 2700, 3600, 4800, 5400, 6000, 7200, 0],
};

/// 0 → Never, 300 → 5 minutes, 3600 → 1 hour, 5400 → 1 hour 30 minutes, 45 → 45 seconds.
String idleLabel(int seconds) {
  if (seconds <= 0) return tr('Never');
  if (seconds % 60 != 0) return seconds == 1 ? tr('1 second') : trf('{0} seconds', [seconds]);
  final minutes = seconds ~/ 60, h = minutes ~/ 60, m = minutes % 60;
  String mins(int n) => n == 1 ? tr('1 minute') : trf('{0} minutes', [n]);
  String hours(int n) => n == 1 ? tr('1 hour') : trf('{0} hours', [n]);
  if (h == 0) return mins(m);
  return m == 0 ? hours(h) : '${hours(h)} ${mins(m)}';
}

class PowerPageState extends State<PowerPage> {
  Map<String, dynamic>? power;
  String? error;
  bool working = false;

  @override
  void initState() {
    super.initState();
    unawaited(load());
  }

  Future<void> load() async {
    try {
      final r = await widget.core('power.get');
      if (mounted) {
        setState(() {
          power = r;
          error = null;
        });
      }
    } on ServiceError catch (e) {
      if (mounted) setState(() => error = '${e.code}${e.reason == null ? '' : ': ${e.reason}'}');
    }
  }

  void _tell(String text) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));

  Future<void> _call(String route, Map<String, dynamic> params) async {
    if (working) return;
    setState(() => working = true);
    try {
      await widget.core(route, params);
    } on ServiceError catch (e) {
      _tell(trf('That did not work ({0}){1}', [e.code, e.reason == null || e.reason!.isEmpty ? '' : ': ${e.reason}']));
    } finally {
      if (mounted) setState(() => working = false);
    }
    await load();
  }

  static String profileName(String id) => switch (id) {
    'performance' => tr('High performance'),
    'balanced' => tr('Balanced'),
    'power-saver' => tr('Extended battery life'),
    _ => id,
  };

  static String profileAbout(String id) => switch (id) {
    'performance' => tr('Peak performance and power usage'),
    'balanced' => tr('Quiet performance and moderate power usage'),
    'power-saver' => tr('Reduced power usage and silent performance'),
    _ => '',
  };

  Widget _profiles(Map p) {
    // COSMIC's order: battery life, balanced, performance; others after them.
    const order = ['power-saver', 'balanced', 'performance'];
    final list = (p['list'] as List).cast<String>().toList()
      ..sort((a, b) => (order.contains(a) ? order.indexOf(a) : 9).compareTo(order.contains(b) ? order.indexOf(b) : 9));
    final current = p['current'] as String?;
    return RadioGroup<String>(
      groupValue: current,
      onChanged: (v) => working || v == null || v == current ? null : _call('power.set_profile', {'profile': v}),
      child: SettingsSection(
      title: tr('Power mode'),
      note: tr('Set with powerprofilesctl (power-profiles-daemon).'),
      children: [
        for (final id in list)
          SettingsItem(
            key: ValueKey('profile-$id'),
            title: profileName(id),
            description: profileAbout(id),
            onTap: working || id == current ? null : () => _call('power.set_profile', {'profile': id}),
            leading: Radio<String>(value: id, enabled: !working),
          ),
      ],
      ),
    );
  }

  Widget _idleChoice(String key, String title, String description, Map idle) {
    final value = idle[key] as int;
    final base = idleChoices[key]!;
    // A value of the file that isn't in the list is shown too (in its place by length).
    final choices = base.contains(value) ? base : [...([...base.where((c) => c > 0), value]..sort()), 0];
    return SettingsChoice<int>(
      key: ValueKey('idle-$key'),
      title: title,
      description: description,
      value: value,
      choices: [for (final c in choices) (c, idleLabel(c))],
      onChanged: working || idle['error'] != null ? null : (v) => _call('power.set_idle', {key: v}),
    );
  }

  Widget _idle(Map idle) => SettingsSection(
    title: tr('Power saving options'),
    note: idle['error'] != null ? '${idle['error']}' : trf('Maprisma Shell, saved in {0}', [_short('${idle['file']}')]),
    children: [
      _idleChoice('lock', tr('Lock the screen after'), tr('Idle time before Maprisma Shell locks the screen.'), idle),
      _idleChoice('screenOff', tr('Turn off the screen after'), tr('Idle time before the screens turn off.'), idle),
      _idleChoice('suspend', tr('Automatic suspend'), tr('Idle time before the computer suspends; it locks first.'), idle),
      SettingsToggle(
        key: const ValueKey('idle-whilePlaying'),
        title: tr('Also while media plays'),
        description: tr('Off: nothing locks, turns off or suspends while music or a video plays.'),
        value: idle['whilePlaying'] == true,
        onChanged: working || idle['error'] != null ? null : (v) => _call('power.set_idle', {'whilePlaying': v}),
      ),
    ],
  );

  static String _short(String path) {
    final home = RegExp(r'^/home/[^/]+').firstMatch(path)?.group(0);
    return home == null ? path : '~${path.substring(home.length)}';
  }

  Widget _native(Map n) => SettingsSection(
    title: tr('Power'),
    note: n['available'] == true ? null : trf('{0} was not found.', [n['name']]),
    children: [
      SettingsItem(
        title: trf('Power is set in {0}', [n['name']]),
        description: tr('This desktop has its own settings app for the power mode, screen blanking and suspend; the Manager leaves them to it.'),
        trailing: FilledButton.tonal(
          key: const ValueKey('power-open-native'),
          onPressed: n['available'] == true ? () => _call('power.open_native', const {}) : null,
          child: Text(trf('Open {0}', [n['name']])),
        ),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final p = power;
    final List<Widget> sections;
    if (p == null) {
      sections = [
        if (error != null)
          Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error))
        else
          const Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator())),
      ];
    } else {
      final profiles = p['profiles'] as Map?;
      sections = [
        if (p['native'] is Map) _native(p['native'] as Map),
        if (profiles?['available'] == true) _profiles(profiles!),
        if (p['idle'] is Map) _idle(p['idle'] as Map),
        if (p['native'] == null && profiles?['available'] != true && p['idle'] == null)
          SettingsSection(children: [SettingsItem(title: tr('Nothing to set here on this desktop'), description: tr('No power-profiles-daemon and no Maprisma Shell.'))]),
      ];
    }
    return SettingsPage(
      title: tr('Power'),
      actions: [
        if (working) const Padding(padding: EdgeInsets.only(right: 8), child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))),
        IconButton(tooltip: tr('Reload'), onPressed: load, icon: const Icon(Icons.refresh)),
      ],
      children: sections,
    );
  }
}
