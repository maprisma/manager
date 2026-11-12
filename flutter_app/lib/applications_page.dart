import 'package:flutter/material.dart';
import 'package:maprisma_manager_core/maprisma_manager_core.dart' show tr;

import 'core_call.dart';
import 'desktop_page.dart';
import 'settings_widgets.dart';

/// Applications (COSMIC Settings' page; stub until its Hyprland part is written).
class ApplicationsPage extends StatelessWidget {
  const ApplicationsPage({super.key, required this.core});
  final CoreCall core;
  @override
  Widget build(BuildContext context) => DesktopSettingsPage(
    core: core,
    page: 'applications',
    title: tr('Applications'),
    what: tr('the default and startup applications'),
    own: (_) => SettingsPage(title: tr('Applications'), children: const []),
  );
}
