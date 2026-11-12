import 'package:flutter/material.dart';
import 'package:maprisma_manager_core/maprisma_manager_core.dart' show tr;

import 'core_call.dart';
import 'desktop_page.dart';
import 'settings_widgets.dart';

/// Bluetooth (COSMIC Settings' page; stub until its Hyprland part is written).
class BluetoothPage extends StatelessWidget {
  const BluetoothPage({super.key, required this.core});
  final CoreCall core;
  @override
  Widget build(BuildContext context) => DesktopSettingsPage(
    core: core,
    page: 'bluetooth',
    title: tr('Bluetooth'),
    what: tr('Bluetooth'),
    own: (_) => SettingsPage(title: tr('Bluetooth'), children: const []),
  );
}
