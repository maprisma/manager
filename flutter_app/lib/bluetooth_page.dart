import 'package:flutter/material.dart';
import 'package:maprisma_manager_core/maprisma_manager_core.dart' show tr, trf;

import 'core_call.dart';
import 'desktop_page.dart';
import 'settings_widgets.dart';

/// Bluetooth, as COSMIC Settings' page: the switch, paired devices (connect, disconnect,
/// forget, battery) and nearby devices (a scan, then pair and connect). Hyprland:
/// `bluetooth.*` (bluetoothctl). Maprisma Bluetooth Monitor opens for the details.
class BluetoothPage extends StatelessWidget {
  const BluetoothPage({super.key, required this.core});
  final CoreCall core;
  @override
  Widget build(BuildContext context) => DesktopSettingsPage(
    core: core,
    page: 'bluetooth',
    title: tr('Bluetooth'),
    what: tr('Bluetooth'),
    own: (_) => _Bluetooth(core: core),
  );
}

class _Bluetooth extends StatefulWidget {
  const _Bluetooth({required this.core});
  final CoreCall core;
  @override
  State<_Bluetooth> createState() => _BluetoothState();
}

class _BluetoothState extends State<_Bluetooth> with RoutePage {
  @override
  CoreCall get core => widget.core;
  @override
  String get getRoute => 'bluetooth.get';

  bool scanning = false;

  Future<void> scan() async {
    if (scanning) return;
    setState(() => scanning = true);
    try {
      await loadFrom('bluetooth.scan', {'seconds': 8});
    } finally {
      if (mounted) setState(() => scanning = false);
    }
  }

  static IconData icon(String? kind) => switch (kind) {
    'audio-headset' || 'audio-headphones' => Icons.headphones,
    'audio-card' => Icons.speaker,
    'input-keyboard' => Icons.keyboard,
    'input-mouse' => Icons.mouse,
    'input-gaming' => Icons.sports_esports,
    'phone' => Icons.smartphone,
    _ => Icons.bluetooth,
  };

  Widget _paired(Map d) {
    final on = d['connected'] == true;
    final battery = d['battery'] as int?;
    return SettingsItem(
      key: ValueKey('bt-${d['mac']}'),
      leading: Icon(icon(d['icon'] as String?), size: 20),
      title: '${d['name']}',
      description: [if (on) tr('Connected'), if (battery != null) trf('Battery {0} %', [battery])].join(' · '),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextButton(
            onPressed: working ? null : () => act(on ? 'bluetooth.disconnect' : 'bluetooth.connect', {'mac': d['mac']}),
            child: Text(on ? tr('Disconnect') : tr('Connect')),
          ),
          PopupMenuButton<String>(
            key: ValueKey('bt-menu-${d['mac']}'),
            tooltip: tr('More'),
            enabled: !working,
            itemBuilder: (_) => [PopupMenuItem(value: 'forget', child: Text(tr('Forget')))],
            onSelected: (_) => act('bluetooth.forget', {'mac': d['mac']}),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = data;
    final actions = [
      if (d?['monitor'] == true)
        TextButton.icon(
          key: const ValueKey('bluetooth-monitor'),
          onPressed: () => act('apps.open', {'id': 'bluetooth'}, reload: false),
          icon: const Icon(Icons.open_in_new, size: 16),
          label: Text(tr('Bluetooth Monitor')),
        ),
      ...reloadActions(),
    ];
    if (d == null) return SettingsPage(title: tr('Bluetooth'), actions: actions, children: loadingOrError(context));
    if (d['controller'] != true) {
      return SettingsPage(title: tr('Bluetooth'), actions: actions, children: [
        SettingsSection(children: [SettingsItem(title: tr('No Bluetooth adapter found'))]),
      ]);
    }
    final paired = (d['paired'] as List).cast<Map>();
    final nearby = (d['nearby'] as List).cast<Map>();
    final on = d['powered'] == true;
    return SettingsPage(
      title: tr('Bluetooth'),
      actions: actions,
      children: [
        SettingsSection(
          children: [
            SettingsToggle(key: const ValueKey('bt-power'), title: tr('Bluetooth'), value: on, onChanged: working ? null : (v) => act('bluetooth.power', {'on': v})),
          ],
        ),
        if (on) ...[
          if (paired.isNotEmpty) SettingsSection(title: tr('Previously connected devices'), children: [for (final p in paired) _paired(p)]),
          SettingsSection(
            title: tr('Nearby devices'),
            note: nearby.isEmpty && !scanning ? tr('Put the device into pairing mode, then search.') : null,
            children: [
              SettingsItem(
                title: scanning ? tr('Searching…') : tr('Search for devices'),
                trailing: scanning
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : IconButton(key: const ValueKey('bt-scan'), tooltip: tr('Search for devices'), onPressed: working ? null : scan, icon: const Icon(Icons.bluetooth_searching, size: 20)),
              ),
              for (final n in nearby)
                SettingsItem(
                  key: ValueKey('bt-near-${n['mac']}'),
                  leading: const Icon(Icons.bluetooth, size: 20),
                  title: '${n['name']}',
                  trailing: TextButton(
                    onPressed: working ? null : () async {
                      if (await act('bluetooth.pair', {'mac': n['mac']})) tellOn(this, trf('{0} is paired', [n['name']]));
                    },
                    child: Text(tr('Pair')),
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }
}
