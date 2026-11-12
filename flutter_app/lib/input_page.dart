import 'package:flutter/material.dart';
import 'package:maprisma_manager_core/maprisma_manager_core.dart' show tr;

import 'core_call.dart';
import 'desktop_page.dart';
import 'settings_widgets.dart';

/// Input devices (COSMIC Settings' page; stub until its Hyprland part is written).
class InputPage extends StatelessWidget {
  const InputPage({super.key, required this.core});
  final CoreCall core;
  @override
  Widget build(BuildContext context) => DesktopSettingsPage(
    core: core,
    page: 'input',
    title: tr('Input devices'),
    what: tr('the keyboard, mouse and touchpad'),
    own: (_) => SettingsPage(title: tr('Input devices'), children: const []),
  );
}
