import 'package:flutter/material.dart';
import 'package:maprisma_manager_core/maprisma_manager_core.dart' show tr, trf;

import 'ai_dialog.dart';
import 'core_call.dart';
import 'desktop_page.dart';
import 'settings_widgets.dart';

/// AI: the helper every Maprisma app uses (Launcher, Theme, Playground, Notifier's Check with AI
/// and the Manager's AI updates), saved in `~/.config/maprisma-ai/settings.json` (`ai.helpers`,
/// `ai.set_helper`), and Let AI do the updates (`settings.set ai_updates`).
class AiPage extends StatefulWidget {
  const AiPage({super.key, required this.core, this.onAiChanged});
  final CoreCall core;

  /// The Apps page's AI button follows Let AI do the updates.
  final VoidCallback? onAiChanged;
  @override
  State<AiPage> createState() => AiPageState();
}

class AiPageState extends State<AiPage> with RoutePage {
  @override
  CoreCall get core => widget.core;
  @override
  String get getRoute => 'ai.helpers';

  /// The helpers that can answer here (installed and signed in), in the catalog's order.
  static List<Map> ready(Map d) => [for (final h in (d['helpers'] as List?) ?? const []) if ((h as Map)['signed_in'] == true) h];

  /// The choices: Automatic (naming the one it picks), then every ready helper.
  static List<(String, String)> choices(Map d) {
    final list = ready(d);
    return [
      ('auto', list.isEmpty ? tr('Automatic') : trf('Automatic ({0})', [AiDialogState.helperName(list.first)])),
      for (final h in list) ('${h['id']}', AiDialogState.helperName(h)),
    ];
  }

  /// The shared choice when it is listed, else Automatic (a chosen helper that isn't ready).
  static String shown(Map d) {
    final helper = d['helper'];
    return ready(d).any((h) => h['id'] == helper) ? helper as String : 'auto';
  }

  Future<void> _set(String key, Object value) async {
    final ok = await act(key == 'helper' ? 'ai.set_helper' : 'settings.set', key == 'helper' ? {'helper': value} : {'key': key, 'value': value});
    if (ok && key == 'ai_updates') widget.onAiChanged?.call();
  }

  static String _short(String path) {
    final home = RegExp(r'^/home/[^/]+').firstMatch(path)?.group(0);
    return home == null ? path : '~${path.substring(home.length)}';
  }

  @override
  Widget build(BuildContext context) {
    final d = data;
    if (d == null) return SettingsPage(title: tr('AI'), actions: reloadActions(), children: loadingOrError(context));
    final list = ready(d);
    final helper = d['helper'];
    final String? note;
    if (list.isEmpty) {
      note = tr('No AI helper is installed and signed in');
    } else if (d['fallback'] == true) {
      note = trf('{0} is not installed or not ready here, so Automatic is used.', [helper]);
    } else {
      note = d['file'] is String ? trf('Saved in {0}', [_short(d['file'] as String)]) : null;
    }
    return SettingsPage(
      title: tr('AI'),
      actions: reloadActions(),
      children: [
        SettingsSection(
          title: tr('Helper'),
          note: note,
          children: [
            SettingsChoice<String>(
              key: const ValueKey('ai-page-helper'),
              title: tr('AI helper for all Maprisma apps'),
              description: tr('Launcher, Theme, Playground, Notifier (Check with AI) and the Manager\'s AI updates use it. Automatic picks the first installed helper that can do the job.'),
              value: shown(d),
              choices: choices(d),
              onChanged: working || list.isEmpty ? null : (v) => _set('helper', v),
            ),
          ],
        ),
        SettingsSection(
          title: tr('AI updates'),
          children: [
            SettingsToggle(
              key: const ValueKey('ai-updates'),
              title: tr('Let AI do the updates'),
              description: tr('An installed, signed-in AI helper (Claude Code, Codex, pi, Hermes or a local model) decides what to update; the Manager checks each step and does it. Off until you turn it on; it runs only when you click the AI button.'),
              value: d['enabled'] == true,
              onChanged: working || (list.isEmpty && d['enabled'] != true) ? null : (v) => _set('ai_updates', v),
            ),
          ],
        ),
      ],
    );
  }
}
