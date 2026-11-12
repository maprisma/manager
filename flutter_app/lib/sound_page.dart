import 'package:flutter/material.dart';
import 'package:maprisma_manager_core/maprisma_manager_core.dart' show tr;

import 'core_call.dart';
import 'desktop_page.dart';
import 'settings_widgets.dart';

/// Sound (COSMIC Settings' page; stub until its Hyprland part is written).
class SoundPage extends StatelessWidget {
  const SoundPage({super.key, required this.core});
  final CoreCall core;
  @override
  Widget build(BuildContext context) => DesktopSettingsPage(
    core: core,
    page: 'sound',
    title: tr('Sound'),
    what: tr('the sound'),
    own: (_) => SettingsPage(title: tr('Sound'), children: const []),
  );
}
