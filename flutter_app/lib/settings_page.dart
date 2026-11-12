import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:maprisma_manager_core/maprisma_manager_core.dart' show tr, trf, languageNames, systemLanguage;

import 'ai_dialog.dart';
import 'backend.dart' show ServiceError;
import 'core_call.dart';
import 'settings_widgets.dart';
import 'theme.dart';

/// The Manager's own settings (they were the toolbar's Language and Settings menus): language,
/// corners, F12 and Let AI do the updates.
class ManagerSettingsPage extends StatefulWidget {
  const ManagerSettingsPage({
    super.key,
    required this.core,
    required this.languageSetting,
    required this.cornersSetting,
    required this.screenshotKey,
    this.onLanguageChanged,
    this.onSettingsChanged,
    this.onAiChanged,
  });
  final CoreCall core;
  final String languageSetting, cornersSetting;
  final bool screenshotKey;
  final Future<void> Function()? onLanguageChanged, onSettingsChanged;

  /// The Apps page's AI button follows Let AI do the updates.
  final VoidCallback? onAiChanged;
  @override
  State<ManagerSettingsPage> createState() => ManagerSettingsPageState();
}

class ManagerSettingsPageState extends State<ManagerSettingsPage> {
  Map<String, dynamic> ai = const {};
  List<Map> get aiReady => [for (final h in (ai['helpers'] as List?) ?? const []) if ((h as Map)['signed_in'] == true) h];

  @override
  void initState() {
    super.initState();
    unawaited(_loadAi());
  }

  Future<void> _loadAi() async {
    try {
      final r = await widget.core('ai.helpers');
      if (mounted) setState(() => ai = r);
    } on ServiceError {
      if (mounted) setState(() => ai = const {});
    }
  }

  void _tell(String text) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));

  Future<void> _set(String key, Object? value) async {
    try {
      await widget.core('settings.set', {'key': key, 'value': value});
      if (key.startsWith('ai_')) {
        await _loadAi();
        widget.onAiChanged?.call();
      }
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
    final chosen = ai['chosen'] as String?;
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
              description: tr('A picture of this window goes to ~/Pictures/Maprisma Manager; then you can add a note about what is wrong, saved next to it.'),
              value: widget.screenshotKey,
              onChanged: (v) => _set('screenshot_key', v),
            ),
          ],
        ),
        SettingsSection(
          title: tr('AI'),
          note: aiReady.isEmpty ? tr('No AI helper is installed and signed in') : null,
          children: [
            SettingsToggle(
              key: const ValueKey('ai-updates'),
              title: tr('Let AI do the updates'),
              description: tr('An installed, signed-in AI helper (Claude Code, Codex, pi, Hermes or a local model) decides what to update; the Manager checks each step and does it. Off until you turn it on; it runs only when you click the AI button.'),
              value: ai['enabled'] == true,
              onChanged: aiReady.isNotEmpty || ai['enabled'] == true ? (v) => _set('ai_updates', v) : null,
            ),
            if (aiReady.isNotEmpty)
              SettingsChoice<String>(
                key: const ValueKey('settings-ai-helper'),
                title: tr('Helper'),
                value: chosen ?? '${aiReady.first['id']}',
                choices: [for (final h in aiReady) ('${h['id']}', AiDialogState.helperName(h))],
                onChanged: (v) => _set('ai_helper', v),
              ),
          ],
        ),
      ],
    );
  }
}
