import 'package:flutter/material.dart';
import 'package:maprisma_manager_core/maprisma_manager_core.dart' show tr;

import 'core_call.dart';
import 'desktop_page.dart';
import 'settings_widgets.dart';

/// Time & Language (COSMIC Settings' page; stub until its Hyprland part is written).
class TimePage extends StatelessWidget {
  const TimePage({super.key, required this.core});
  final CoreCall core;
  @override
  Widget build(BuildContext context) => DesktopSettingsPage(
    core: core,
    page: 'time',
    title: tr('Time & Language'),
    what: tr('the date, time and language'),
    own: (_) => SettingsPage(title: tr('Time & Language'), children: const []),
  );
}
