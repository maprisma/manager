import 'package:flutter/material.dart';
import 'package:maprisma_manager_core/maprisma_manager_core.dart' show tr;

import 'core_call.dart';
import 'desktop_page.dart';
import 'settings_widgets.dart';

/// Displays (COSMIC Settings' page; stub until its Hyprland part is written).
class DisplaysPage extends StatelessWidget {
  const DisplaysPage({super.key, required this.core});
  final CoreCall core;
  @override
  Widget build(BuildContext context) => DesktopSettingsPage(
    core: core,
    page: 'displays',
    title: tr('Displays'),
    what: tr('the displays'),
    own: (_) => SettingsPage(title: tr('Displays'), children: const []),
  );
}
