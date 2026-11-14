import 'package:flutter/material.dart';
import 'package:maprisma_manager_core/maprisma_manager_core.dart' show tr, trf;

import 'core_call.dart';
import 'settings_widgets.dart';

/// What every app's Ask AI may do (docs/ask-ai-rules.md): the overall level, a switch per action,
/// install sources and folders (`ai.rules`, `ai.set_rule`, `ai.reset_rules`), the answers that are
/// always on, and the log of what Ask AI changed (`ai.log`, `ai.clear_log`). The apps enforce it.
class AskAiRules extends StatefulWidget {
  const AskAiRules({super.key, required this.core});
  final CoreCall core;
  @override
  State<AskAiRules> createState() => AskAiRulesState();
}

class AskAiRulesState extends State<AskAiRules> {
  Map<String, dynamic>? rules;
  List<Map<String, dynamic>> log = const [];
  String? error;
  bool working = false;

  static const apps = {
    'launcher': 'Maprisma Launcher',
    'theme': 'Maprisma Theme',
    'settings': 'Maprisma Settings',
    'notifier': 'Maprisma Notifier',
    'playground': 'Maprisma Playground',
  };

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final r = await widget.core('ai.rules');
      final l = await widget.core('ai.log', {'limit': 50});
      if (!mounted) return;
      setState(() {
        rules = r;
        log = [
          for (final e in (l['entries'] as List?) ?? const [])
            Map<String, dynamic>.from(e as Map),
        ];
        error = null;
      });
    } on Object catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  Future<void> _call(
    String route, [
    Map<String, dynamic> params = const {},
  ]) async {
    setState(() => working = true);
    try {
      final r = await widget.core(route, params);
      if (!mounted) return;
      if (route == 'ai.clear_log') {
        setState(() => log = const []);
      } else {
        setState(() => rules = r);
      }
    } on Object catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(trf('That did not work ({0})', ['$e']))),
        );
      }
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  List<Map> _items(String kind) => [
    for (final i in (rules?[kind] as List?) ?? const []) i as Map,
  ];

  Widget _toggle(String kind, Map item, {required bool answersOnly}) =>
      SettingsToggle(
        key: ValueKey('ask-ai-$kind-${item['id']}'),
        title: tr(item['label'] as String),
        description: answersOnly && item['on'] == true
            ? tr('Off while Ask AI only answers')
            : null,
        value: item['on'] == true,
        onChanged: working
            ? null
            : (v) => _call('ai.set_rule', {
                'kind': kind,
                'id': item['id'],
                'on': v,
              }),
      );

  static String _when(String iso) {
    final t = DateTime.tryParse(iso)?.toLocal();
    if (t == null) return iso;
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  }

  static String _result(Object? r) => switch (r) {
    'done' => tr('done'),
    'started' => tr('started'),
    'failed' => tr('failed'),
    'blocked' => tr('blocked'),
    'cancelled' => tr('cancelled'),
    _ => '$r',
  };

  @override
  Widget build(BuildContext context) {
    final r = rules;
    if (r == null) {
      return SettingsSection(
        title: tr('What Ask AI may do'),
        note: error,
        children: [
          if (error == null)
            const Padding(
              padding: EdgeInsets.all(16),
              child: LinearProgressIndicator(),
            ),
        ],
      );
    }
    final answersOnly = r['level'] == 'answers';
    final actions = _items('actions');
    return Column(
      key: const ValueKey('ask-ai-rules'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (r['broken'] == true)
          SettingsSection(
            title: tr('The rules can\'t be read'),
            note: tr('Until they are reset, Ask AI in every app only answers.'),
            children: [
              SettingsItem(
                leading: Icon(
                  Icons.warning_amber,
                  color: Theme.of(context).colorScheme.error,
                ),
                title: tr('Reset the rules'),
                description: tr(
                  'Keeps a copy of the unreadable file next to it and starts again with everything allowed.',
                ),
                trailing: FilledButton.tonal(
                  key: const ValueKey('ask-ai-reset'),
                  onPressed: working ? null : () => _call('ai.reset_rules'),
                  child: Text(tr('Reset')),
                ),
              ),
            ],
          ),
        SettingsSection(
          title: tr('What Ask AI may do'),
          note: tr(
            'The apps check these themselves, every time; the AI can\'t change them. A switched-off step is still suggested, but its button is disabled. Most changes also show you a review first.',
          ),
          children: [
            SettingsChoice<String>(
              key: const ValueKey('ask-ai-level'),
              title: tr('Ask AI in all apps'),
              description: tr(
                'Answers only: Ask AI explains and suggests, but changes nothing.',
              ),
              value: answersOnly ? 'answers' : 'review',
              choices: [
                ('review', tr('May act')),
                ('answers', tr('Answers only')),
              ],
              onChanged: working
                  ? null
                  : (v) => _call('ai.set_rule', {'level': v}),
            ),
          ],
        ),
        for (final app in ['launcher', 'theme', 'settings'])
          if (actions.any((a) => a['app'] == app))
            SettingsSection(
              title: apps[app]!,
              children: [
                for (final a in actions.where((a) => a['app'] == app))
                  _toggle('actions', a, answersOnly: answersOnly),
              ],
            ),
        SettingsSection(
          title: tr('Install sources'),
          note: tr(
            'Where Ask AI in Maprisma Launcher may install apps from. The AUR and GitHub are not checked by your distribution.',
          ),
          children: [
            for (final s in _items('sources'))
              _toggle('sources', s, answersOnly: answersOnly),
          ],
        ),
        SettingsSection(
          title: tr('Folders'),
          note: tr('Which of your folders Ask AI may look into.'),
          children: [
            for (final f in _items('folders'))
              _toggle('folders', f, answersOnly: answersOnly),
          ],
        ),
        SettingsSection(
          title: tr('Always on: answers only'),
          children: [
            for (final a in (r['answers'] as List?) ?? const [])
              SettingsItem(
                leading: const Icon(Icons.chat_bubble_outline),
                title: tr((a as Map)['label'] as String),
                description: apps['${a['app']}'],
              ),
          ],
        ),
        SettingsSection(
          title: tr('What Ask AI changed'),
          note: log.isEmpty ? tr('Nothing yet.') : null,
          children: [
            for (final e in log.take(50))
              SettingsItem(
                key: ValueKey('ask-ai-log-${e['op']}-${e['result']}'),
                leading: Icon(switch (e['result']) {
                  'done' => Icons.check_circle_outline,
                  'blocked' => Icons.block,
                  'failed' => Icons.error_outline,
                  _ => Icons.play_circle_outline,
                }),
                title: '${e['target'] ?? ''}',
                description:
                    '${_when('${e['time']}')} · ${apps['${e['app']}'] ?? e['app']} · ${_result(e['result'])}',
              ),
            if (log.isNotEmpty)
              Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: TextButton(
                    key: const ValueKey('ask-ai-clear-log'),
                    onPressed: working ? null : () => _call('ai.clear_log'),
                    child: Text(tr('Clear the log')),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}
