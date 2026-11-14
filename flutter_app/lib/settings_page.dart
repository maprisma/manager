import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:maprisma_manager_core/maprisma_manager_core.dart' show tr, trf, languageNames, systemLanguage;

import 'core_call.dart';
import 'settings_widgets.dart';
import 'theme.dart';
import 'window_style.dart';

/// The Manager's own settings (they were the toolbar's Language and Settings menus): language,
/// corners and F12 (Let AI do the updates and the helper are on the AI page).
class ManagerSettingsPage extends StatefulWidget {
  const ManagerSettingsPage({
    super.key,
    required this.core,
    required this.languageSetting,
    required this.cornersSetting,
    required this.screenshotKey,
    this.onLanguageChanged,
    this.onSettingsChanged,
  });
  final CoreCall core;
  final String languageSetting, cornersSetting;
  final bool screenshotKey;
  final Future<void> Function()? onLanguageChanged, onSettingsChanged;
  @override
  State<ManagerSettingsPage> createState() => ManagerSettingsPageState();
}

class ManagerSettingsPageState extends State<ManagerSettingsPage> {
  String windowStyle = chosenWindowStyle();

  /// Settings › App windows: written to the file all Maprisma apps read.
  Future<void> _windowStyle(String value) async {
    try {
      await writeWindowsSetting('style', value);
      WindowStyleWatcher.refreshAll();
      if (mounted) setState(() => windowStyle = value);
    } on Object {
      if (mounted) _tell(tr('Could not save the setting.'));
    }
  }

  void _tell(String text) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));

  Future<void> _set(String key, Object? value) async {
    try {
      await widget.core('settings.set', {'key': key, 'value': value});
      await widget.onSettingsChanged?.call();
    } on Object {
      if (mounted) _tell(tr('Could not save the setting.'));
    }
  }

  Future<void> _language(String value) async {
    try {
      await widget.core('settings.language', {'language': value});
      await widget.onLanguageChanged?.call();
    } on Object {
      if (mounted) _tell(tr('Could not save the language setting.'));
    }
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPage(
      title: tr('Settings'),
      children: [
        SettingsSection(
          title: tr('Window'),
          children: [
            SettingsChoice<String>(
              key: const ValueKey('settings-language'),
              title: tr('Language'),
              value: widget.languageSetting,
              choices: [
                ('auto', trf('System ({0})', [languageNames[systemLanguage(Platform.environment)]])),
                for (final e in languageNames.entries) (e.key, e.value),
              ],
              onChanged: _language,
            ),
            SettingsChoice<String>(
              key: const ValueKey('settings-corners'),
              title: tr('Corners'),
              value: widget.cornersSetting,
              choices: [
                ('windows', tr('Like windows')),
                ('slight', trf('Slightly rounded ({0} px)', [slightRadius])),
                ('rounded', trf('Rounded ({0} px)', [roundedRadius])),
                ('square', tr('Square')),
              ],
              onChanged: (v) => _set('corners', v),
            ),
            SettingsToggle(
              key: const ValueKey('settings-screenshot-key'),
              title: tr('F12 saves a screenshot'),
              description: tr('A picture of this window goes to ~/Pictures/Maprisma Settings; then you can add a note about what is wrong, saved next to it.'),
              value: widget.screenshotKey,
              onChanged: (v) => _set('screenshot_key', v),
            ),
            SettingsChoice<String>(
              key: const ValueKey('settings-window-style'),
              title: tr('App windows'),
              description: tr('For all Maprisma apps: see-through windows, blurred behind where the desktop blurs (Glassy). Follow the desktop uses Omarchy\'s window style, elsewhere Glassy while Maprisma Theme has blur on.'),
              value: windowStyle,
              choices: windowStyleChoices(tr),
              onChanged: _windowStyle,
            ),
          ],
        ),
      ],
    );
  }
}
