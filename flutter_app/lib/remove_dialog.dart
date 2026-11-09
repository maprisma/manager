import 'package:flutter/material.dart';

import 'app_facts.dart';
import 'backend.dart' show ServiceError;
import 'core_call.dart';

/// "Uninstall …?": what goes and what stays with the reasons (`apps.remove_plan`), the apps that
/// need it, and "Also delete its settings" when it has settings of its own (data shared with
/// Omarchy is never offered). Pops the job's options, or null.
class RemoveDialog extends StatefulWidget {
  const RemoveDialog({super.key, required this.core, required this.app});
  final CoreCall core;
  final App app;
  @override
  State<RemoveDialog> createState() => _RemoveDialogState();
}

class _RemoveDialogState extends State<RemoveDialog> {
  Map<String, dynamic>? plan, withSettings;
  bool deleteSettings = false;
  String? error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final a = await widget.core('apps.remove_plan', {'id': widget.app['id']});
      final b = await widget.core('apps.remove_plan', {'id': widget.app['id'], 'delete_settings': true});
      if (mounted) {
        setState(() {
          plan = a;
          withSettings = b;
        });
      }
    } on ServiceError catch (e) {
      if (mounted) setState(() => error = e.reason ?? e.code);
    }
  }

  /// The plan for the checkbox as it is now.
  Map<String, dynamic>? get current => deleteSettings ? withSettings : plan;

  bool get settingsOffered => ((withSettings?['data'] as List?) ?? const []).any((d) => (d as Map)['goes'] == true);

  Widget _paths(String title, List items, {required bool goes}) {
    final scheme = Theme.of(context).colorScheme;
    if (items.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 12, bottom: 4),
          child: Text('$title (${items.length})', style: const TextStyle(fontWeight: FontWeight.w700)),
        ),
        for (final e in items.take(60))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 1),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(goes ? Icons.remove_circle_outline : Icons.shield_outlined, size: 14, color: goes ? scheme.error : scheme.onSurfaceVariant),
                const SizedBox(width: 6),
                Expanded(
                  child: Text.rich(
                    TextSpan(children: [
                      TextSpan(text: _short('${(e as Map)['path']}')),
                      if (e['kind'] == 'tree') TextSpan(text: '  (folder, ${e['files']} files)', style: TextStyle(color: scheme.onSurfaceVariant)),
                      if (e['kind'] == 'package') TextSpan(text: '  (pacman package ${e['version'] ?? ''})', style: TextStyle(color: scheme.onSurfaceVariant)),
                      if (e['why'] != null) TextSpan(text: ': ${e['why']}', style: TextStyle(color: scheme.onSurfaceVariant)),
                    ]),
                    style: const TextStyle(fontSize: 12.5),
                  ),
                ),
              ],
            ),
          ),
        if (items.length > 60) Text('… and ${items.length - 60} more', style: TextStyle(color: scheme.onSurfaceVariant)),
      ],
    );
  }

  String _short(String path) {
    final home = RegExp(r'^/home/[^/]+/').firstMatch(path);
    return home == null ? path : '~/${path.substring(home.end)}';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final p = current;
    final dependents = ((p?['dependents'] as List?) ?? const []).cast<Map>();
    final blocked = p?['blocked'];
    final data = ((p?['data'] as List?) ?? const []).cast<Map>();
    final steps = ((p?['steps'] as List?) ?? const []).cast<Map>();
    return AlertDialog(
      title: Text('Do you want to uninstall ${widget.app['name']}?'),
      content: SizedBox(
        width: 560,
        child: error != null
            ? Text(error!, style: TextStyle(color: scheme.error))
            : p == null
            ? const SizedBox(height: 100, child: Center(child: CircularProgressIndicator()))
            : SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (blocked != null)
                      Text('It can\'t be removed now: $blocked', style: TextStyle(color: scheme.error, fontWeight: FontWeight.w600)),
                    if (dependents.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Text(
                          '${dependents.map((d) => d['name']).join(', ')} ${dependents.length == 1 ? 'needs' : 'need'} it: ${dependents.length == 1 ? 'it stops working' : 'they stop working'} without it.',
                          style: TextStyle(color: scheme.error),
                        ),
                      ),
                    if (p['receipt'] != 'valid')
                      Text(
                        'Installed before the Manager (no record of its files): only the files its installer writes go.',
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                    if (steps.isNotEmpty) ...[
                      const Padding(padding: EdgeInsets.only(top: 12, bottom: 4), child: Text('Steps first', style: TextStyle(fontWeight: FontWeight.w700))),
                      for (final s in steps) Text('• ${s['title']}', style: const TextStyle(fontSize: 12.5)),
                    ],
                    _paths('Goes', (p['goes'] as List?) ?? const [], goes: true),
                    _paths('Stays', [
                      ...((p['stays'] as List?) ?? const []),
                      ...((p['runtime'] as List?) ?? const []),
                      for (final d in data)
                        if (d['goes'] != true) d,
                    ], goes: false),
                    _paths('Settings that go', [for (final d in data) if (d['goes'] == true) d], goes: true),
                    if (settingsOffered)
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        value: deleteSettings,
                        onChanged: (v) => setState(() => deleteSettings = v ?? false),
                        title: const Text('Also delete its settings'),
                        subtitle: const Text('Data shared with Omarchy\'s apps is never deleted'),
                      ),
                  ],
                ),
              ),
      ),
      actions: [
        // Removing: Enter must not do it by accident.
        TextButton(autofocus: true, onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: scheme.error),
          onPressed: p == null || blocked != null
              ? null
              : () => Navigator.pop(context, {
                  'delete_settings': deleteSettings,
                  if (dependents.isNotEmpty) 'dependents_ok': true,
                  'revision': ?p['revision'],
                }),
          child: const Text('Uninstall'),
        ),
      ],
    );
  }
}
