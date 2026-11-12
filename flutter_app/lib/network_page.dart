import 'package:flutter/material.dart';
import 'package:maprisma_manager_core/maprisma_manager_core.dart' show tr, trf;

import 'backend.dart' show ServiceError;
import 'core_call.dart';
import 'desktop_page.dart';
import 'settings_widgets.dart';

/// Network & Wireless, as COSMIC Settings' Wi-Fi, Wired and VPN pages: the Wi-Fi switch, known
/// networks (connect, disconnect, forget), visible networks (connect, with a password when
/// needed), wired and VPN connections. Hyprland: `network.*` (nmcli). Maprisma WLAN Monitor
/// opens for the details.
class NetworkPage extends StatelessWidget {
  const NetworkPage({super.key, required this.core});
  final CoreCall core;
  @override
  Widget build(BuildContext context) => DesktopSettingsPage(
    core: core,
    page: 'network',
    title: tr('Network & Wireless'),
    what: tr('the network'),
    own: (_) => _Network(core: core),
  );
}

class _Network extends StatefulWidget {
  const _Network({required this.core});
  final CoreCall core;
  @override
  State<_Network> createState() => _NetworkState();
}

class _NetworkState extends State<_Network> with RoutePage {
  @override
  CoreCall get core => widget.core;
  @override
  String get getRoute => 'network.get';

  bool scanning = false;

  Future<void> rescan() async {
    if (scanning) return;
    setState(() => scanning = true);
    try {
      final r = await core('network.get', {'rescan': true});
      if (mounted) setState(() => data = r);
    } on ServiceError catch (e) {
      tellOn(this, failure(e));
    } finally {
      if (mounted) setState(() => scanning = false);
    }
  }

  static IconData signal(int s) => s >= 70 ? Icons.network_wifi : s >= 45 ? Icons.network_wifi_3_bar : s >= 25 ? Icons.network_wifi_2_bar : Icons.network_wifi_1_bar;

  Future<void> join(Map v) async {
    final open = '${v['security']}'.trim().isEmpty;
    String? password;
    if (!open) {
      password = await showDialog<String>(context: context, builder: (_) => _PasswordDialog(ssid: '${v['ssid']}'));
      if (password == null) return;
    }
    if (await act('network.connect', {'ssid': v['ssid'], 'password': ?password}) && mounted) tellOn(this, trf('Connected to {0}', [v['ssid']]));
  }

  Widget _knownRow(Map k) {
    final on = k['active'] == true;
    return SettingsItem(
      key: ValueKey('known-${k['uuid']}'),
      leading: Icon(on ? Icons.wifi : Icons.wifi_outlined, size: 20),
      title: '${k['name']}',
      description: on ? tr('Connected') : null,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextButton(
            onPressed: working ? null : () => act(on ? 'network.down' : 'network.up', {'uuid': k['uuid']}),
            child: Text(on ? tr('Disconnect') : tr('Connect')),
          ),
          PopupMenuButton<String>(
            key: ValueKey('known-menu-${k['uuid']}'),
            tooltip: tr('More'),
            enabled: !working,
            itemBuilder: (_) => [PopupMenuItem(value: 'forget', child: Text(tr('Forget')))],
            onSelected: (_) => act('network.forget', {'uuid': k['uuid']}),
          ),
        ],
      ),
    );
  }

  Widget _toggleRow(Map c, {String? device}) => SettingsToggle(
    key: ValueKey('conn-${c['uuid']}'),
    title: '${c['name']}',
    description: c['active'] == true ? tr('Connected') : device,
    value: c['active'] == true,
    onChanged: working ? null : (v) => act(v ? 'network.up' : 'network.down', {'uuid': c['uuid']}),
  );

  @override
  Widget build(BuildContext context) {
    final d = data;
    final actions = [
      if (d?['monitor'] == true)
        TextButton.icon(
          key: const ValueKey('network-monitor'),
          onPressed: () => act('apps.open', {'id': 'wlan'}, reload: false),
          icon: const Icon(Icons.open_in_new, size: 16),
          label: Text(tr('WLAN Monitor')),
        ),
      ...reloadActions(),
    ];
    if (d == null) return SettingsPage(title: tr('Network & Wireless'), actions: actions, children: loadingOrError(context));
    final known = (d['known'] as List).cast<Map>();
    final visible = [for (final v in (d['visible'] as List).cast<Map>()) if (v['known'] != true) v];
    final wired = (d['wired'] as List).cast<Map>();
    final wiredDevices = (d['wiredDevices'] as List).cast<Map>();
    final vpn = (d['vpn'] as List).cast<Map>();
    return SettingsPage(
      title: tr('Network & Wireless'),
      actions: actions,
      children: [
        if (d['wifiDevice'] == true) ...[
          SettingsSection(
            title: tr('Wi-Fi'),
            children: [
              SettingsToggle(key: const ValueKey('wifi-on'), title: tr('Wi-Fi'), value: d['wifiOn'] == true, onChanged: working ? null : (v) => act('network.wifi', {'on': v})),
              for (final k in known) _knownRow(k),
            ],
          ),
          if (d['wifiOn'] == true)
            SettingsSection(
              title: tr('Visible networks'),
              note: visible.isEmpty ? tr('No other networks found.') : null,
              children: [
                SettingsItem(
                  title: tr('Search again'),
                  trailing: scanning
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : IconButton(key: const ValueKey('wifi-rescan'), tooltip: tr('Search again'), onPressed: rescan, icon: const Icon(Icons.wifi_find, size: 20)),
                ),
                for (final v in visible)
                  SettingsItem(
                    key: ValueKey('visible-${v['ssid']}'),
                    leading: Icon(signal(v['signal'] as int), size: 20),
                    title: '${v['ssid']}',
                    description: '${v['security']}'.trim().isEmpty ? tr('Open network') : '${v['security']}',
                    onTap: working ? null : () => join(v),
                    trailing: Icon('${v['security']}'.trim().isEmpty ? Icons.lock_open : Icons.lock_outline, size: 16),
                  ),
              ],
            ),
        ],
        if (wired.isNotEmpty || wiredDevices.isNotEmpty)
          SettingsSection(
            title: tr('Wired'),
            note: wiredDevices.isNotEmpty && wiredDevices.every((w) => w['state'] == 'unavailable') ? tr('No cable is plugged in.') : null,
            children: [for (final c in wired) _toggleRow(c)],
          ),
        if (vpn.isNotEmpty)
          SettingsSection(
            title: tr('VPN'),
            children: [for (final c in vpn) _toggleRow(c)],
          ),
      ],
    );
  }
}

/// The network's password (shown on request).
class _PasswordDialog extends StatefulWidget {
  const _PasswordDialog({required this.ssid});
  final String ssid;
  @override
  State<_PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<_PasswordDialog> {
  final _field = TextEditingController();
  bool _show = false;

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  bool get _ok => _field.text.length >= 8 && _field.text.length <= 63;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(trf('Connect to {0}', [widget.ssid])),
    content: SizedBox(
      width: 380,
      child: TextField(
        key: const ValueKey('wifi-password'),
        controller: _field,
        autofocus: true,
        obscureText: !_show,
        onChanged: (_) => setState(() {}),
        onSubmitted: (_) => _ok ? Navigator.pop(context, _field.text) : null,
        decoration: InputDecoration(
          hintText: tr('Password'),
          suffixIcon: IconButton(
            tooltip: _show ? tr('Hide password') : tr('Show password'),
            onPressed: () => setState(() => _show = !_show),
            icon: Icon(_show ? Icons.visibility_off : Icons.visibility, size: 18),
          ),
        ),
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Cancel'))),
      FilledButton(key: const ValueKey('wifi-connect'), onPressed: _ok ? () => Navigator.pop(context, _field.text) : null, child: Text(tr('Connect'))),
    ],
  );
}
