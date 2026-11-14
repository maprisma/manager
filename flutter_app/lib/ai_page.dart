import 'package:flutter/material.dart';
import 'package:maprisma_manager_core/maprisma_manager_core.dart' show tr, trf;

import 'ai_dialog.dart';
import 'ask_ai_rules.dart';
import 'core_call.dart';
import 'desktop_page.dart';
import 'settings_widgets.dart';

/// AI: the helper every Maprisma app uses (Launcher, Theme, Playground, Notifier's Check with AI
/// and the Manager's AI updates), saved in `~/.config/maprisma-ai/settings.json` (`ai.helpers`,
/// `ai.set_helper`), whether that helper may search the web (`web_search`, `ai.set_web_search`),
/// and Let AI do the updates (`settings.set ai_updates`).
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

  /// Why web search can't be used with the helper in use now; null when it can (or when no
  /// helper is ready: the Helper card says so).
  static String? webSearchNote(Map d) {
    final chosen = d['chosen'];
    if (d['web_search_supported'] == true || chosen == null) return null;
    final h = ((d['helpers'] as List?) ?? const []).cast<Map>().where((h) => h['id'] == chosen).firstOrNull;
    return trf('Works with Claude Code; {0} can\'t search the web here', [h == null ? '$chosen' : '${h['name']}']);
  }

  Future<void> _set(String key, Object value) async {
    final ok = await act(switch (key) {
      'helper' => 'ai.set_helper',
      'web_search' => 'ai.set_web_search',
      _ => 'settings.set',
    }, switch (key) {
      'helper' => {'helper': value},
      'web_search' => {'on': value},
      _ => {'key': key, 'value': value},
    });
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
              description: tr('Launcher, Theme, Playground, Notifier (Check with AI) and the AI updates of Maprisma Settings use it. Automatic picks the first installed helper that can do the job.'),
              value: shown(d),
              choices: choices(d),
              onChanged: working || list.isEmpty ? null : (v) => _set('helper', v),
            ),
          ],
        ),
        SettingsSection(
          title: tr('Web search'),
          note: webSearchNote(d),
          children: [
            SettingsToggle(
              key: const ValueKey('ai-web-search'),
              title: tr('Let the AI helper search the web'),
              description: tr('When an app can\'t find something, for example an app to install, the helper may search the web and read pages, nothing else. The app checks the results before it offers anything. Used by Maprisma Launcher\'s Ask AI; more apps later. Off until you turn it on.'),
              value: d['web_search'] == true,
              // can't be turned on with a helper that can't search the web; can always be turned off
              onChanged: working || (d['web_search_supported'] != true && d['web_search'] != true) ? null : (v) => _set('web_search', v),
            ),
            _InfoNote(
              key: const ValueKey('ai-web-privacy'),
              title: tr('Where the questions go'),
              text: tr('With web search on, the question and the helper\'s searches go to the helper\'s provider, and the pages it reads are fetched from the web. It gets no other tools: no commands, no files.'),
            ),
          ],
        ),
        SettingsSection(
          title: tr('AI updates'),
          children: [
            SettingsToggle(
              key: const ValueKey('ai-updates'),
              title: tr('Let AI do the updates'),
              description: tr('An installed, signed-in AI helper (Claude Code, Codex, pi, Hermes or a local model) decides what to update; Maprisma Settings checks each step and does it. Off until you turn it on; it runs only when you click the AI button.'),
              value: d['enabled'] == true,
              onChanged: working || (list.isEmpty && d['enabled'] != true) ? null : (v) => _set('ai_updates', v),
            ),
          ],
        ),
        AskAiRules(core: core),
      ],
    );
  }
}

/// An info level card (layout rules: info = accent mark before the heading and an accent left
/// edge), here for the privacy note.
class _InfoNote extends StatelessWidget {
  const _InfoNote({super.key, required this.title, required this.text});
  final String title, text;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(border: Border(left: BorderSide(color: scheme.primary, width: 3))),
      child: SettingsItem(
        leading: Icon(Icons.info_outline, color: scheme.primary),
        title: title,
        description: text,
      ),
    );
  }
}
