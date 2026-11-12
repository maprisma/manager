import 'package:flutter/material.dart';
import 'package:maprisma_manager_core/maprisma_manager_core.dart' show tr;

import 'core_call.dart';
import 'desktop_page.dart';
import 'settings_widgets.dart';

/// About (COSMIC Settings' page; stub until its Hyprland part is written).
class AboutPage extends StatelessWidget {
  const AboutPage({super.key, required this.core});
  final CoreCall core;
  @override
  Widget build(BuildContext context) => DesktopSettingsPage(
    core: core,
    page: 'about',
    title: tr('About'),
    what: tr('the system information'),
    own: (_) => SettingsPage(title: tr('About'), children: const []),
  );
}
