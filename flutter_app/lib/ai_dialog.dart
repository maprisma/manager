import 'dart:async';

import 'package:flutter/material.dart';
import 'package:maprisma_manager_core/maprisma_manager_core.dart' show tr, trf, uiLabel;

import 'backend.dart' show ServiceError;
import 'core_call.dart';
import 'theme.dart';

/// "Let AI do the updates": Helper: [name ▾] as on Maprisma Theme's Ask AI page, Start, and what
/// the AI said and the Manager did (`ai.*`, polled while it runs).
class AiDialog extends StatefulWidget {
  const AiDialog({super.key, required this.core, this.poll = const Duration(milliseconds: 400)});
  final CoreCall core;
  final Duration poll;
  @override
  State<AiDialog> createState() => AiDialogState();
}

class AiDialogState extends State<AiDialog> {
  List<Map<String, dynamic>> helpers = [];
  String? helper;
  Map<String, dynamic>? run;
  String? error;
  bool loading = true;
  Timer? _timer;
  final _scroll = ScrollController();

  /// The helper's id (`pi:<provider>/<model>` too) as Ask AI shows it.
  static String helperName(Map h) => '${h['name']}${h['local'] == true ? tr(' · on this PC') : ''}';

  List<Map<String, dynamic>> get ready => [for (final h in helpers) if (h['signed_in'] == true) h];
  bool get running => run?['state'] == 'running';

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final h = await widget.core('ai.helpers');
      final r = await widget.core('ai.get');
      if (!mounted) return;
      setState(() {
        helpers = [for (final x in h['helpers'] as List) Map<String, dynamic>.from(x as Map)];
        helper = h['chosen'] as String?;
        run = r['run'] == null ? null : Map<String, dynamic>.from(r['run'] as Map);
        loading = false;
      });
      if (running) _follow();
    } on ServiceError catch (e) {
      if (mounted) {
        setState(() {
          loading = false;
          error = e.reason ?? e.code;
        });
      }
    }
  }

  void _follow() {
    _timer?.cancel();
    _timer = Timer.periodic(widget.poll, (_) async {
      try {
        final r = await widget.core('ai.get');
        if (!mounted) return;
        final next = r['run'] == null ? null : Map<String, dynamic>.from(r['run'] as Map);
        final grew = ((next?['steps'] as List?)?.length ?? 0) != ((run?['steps'] as List?)?.length ?? 0);
        setState(() => run = next);
        if (grew) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (_scroll.hasClients) _scroll.animateTo(_scroll.position.maxScrollExtent, duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
          });
        }
        if (!running) _timer?.cancel();
      } on ServiceError {
        // the next poll tries again
      }
    });
  }

  Future<void> _choose(String id) async {
    if (id == helper) return;
    setState(() => helper = id);
    try {
      await widget.core('settings.set', {'key': 'ai_helper', 'value': id});
    } on ServiceError {
      // used for this run anyway; the choice is just not remembered
    }
  }

  Future<void> start() async {
    setState(() => error = null);
    try {
      final r = await widget.core('ai.start', {'helper': ?helper});
      if (!mounted) return;
      setState(() => run = Map<String, dynamic>.from(r['run'] as Map));
      _follow();
    } on ServiceError catch (e) {
      if (mounted) setState(() => error = e.reason ?? e.code);
    }
  }

  Future<void> cancel() async {
    try {
      await widget.core('ai.cancel');
    } on ServiceError {
      // it ended meanwhile
    }
  }

  String _phase(Map r) => switch (r['phase']) {
    'checking' => tr('Checking the apps…'),
    'asking' => trf('Waiting for {0}…', [r['helperName']]),
    'working' => tr('Working…'),
    _ => '',
  };

  Widget _helperRow(ColorScheme scheme) {
    final current = ready.where((h) => h['id'] == helper).firstOrNull;
    final radius = BorderRadius.circular(cornerSizes(context).control);
    return Row(
      children: [
        Text(tr('Helper:')),
        const SizedBox(width: 8),
        Flexible(
          child: PopupMenuButton<String>(
            key: const ValueKey('ai-helper'),
            tooltip: current == null ? tr('No helper ready') : helperName(current),
            enabled: ready.isNotEmpty && !running,
            onSelected: _choose,
            position: PopupMenuPosition.under,
            itemBuilder: (_) => [
              for (final h in ready) CheckedPopupMenuItem(value: h['id'] as String, checked: h['id'] == helper, child: Text(helperName(h))),
            ],
            child: Container(
              padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
              decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: radius),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(child: Text(current == null ? '—' : helperName(current), maxLines: 1, overflow: TextOverflow.ellipsis)),
                  const SizedBox(width: 4),
                  Icon(Icons.expand_more, size: 18, color: scheme.onSurfaceVariant),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _step(Map s, ColorScheme scheme) {
    final marks = markColors(context);
    if (s['kind'] == 'say') {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.auto_awesome, size: 16, color: scheme.primary),
            const SizedBox(width: 8),
            Expanded(child: SelectableText('${s['text']}', style: TextStyle(fontStyle: s['unreadable'] == true ? FontStyle.italic : null))),
          ],
        ),
      );
    }
    if (s['kind'] == 'note') {
      return Padding(padding: const EdgeInsets.symmetric(vertical: 2), child: Text('${s['text']}', style: TextStyle(color: scheme.onSurfaceVariant)));
    }
    final what = switch (s['do']) {
      'update' => tr('Update'),
      'reinstall' => tr('Reinstall'),
      'pub_get' => tr('Fetch Flutter packages'),
      _ => '${s['do']}',
    };
    final name = s['name'] ?? s['app'];
    final (IconData icon, Color color, String state) = s['ok'] == false
        ? (Icons.block, scheme.onSurfaceVariant, trf('not done: {0}', [s['message']]))
        : switch (s['state']) {
            'running' => (Icons.hourglass_top, marks.update, tr('running…')),
            'succeeded' => (Icons.check_circle_outline, marks.running, s['up_to_date'] == true ? tr('already up to date') : tr('done')),
            'cancelled' => (Icons.cancel_outlined, scheme.onSurfaceVariant, uiLabel('cancelled')),
            _ => (Icons.error_outline, scheme.error, uiLabel(s['state'] ?? 'failed')),
          };
    final detail = s['ok'] != false && s['state'] != 'running' && (s['state'] != 'succeeded' || s['do'] == 'pub_get')
        ? [s['message'], s['log']].whereType<String>().join('\n\n')
        : '';
    final line = Row(
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 8),
        Expanded(child: Text('$what · $name — $state', maxLines: 2, overflow: TextOverflow.ellipsis)),
      ],
    );
    if (detail.isEmpty) return Padding(padding: const EdgeInsets.symmetric(vertical: 2), child: line);
    return ExpansionTile(
      dense: true,
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.fromLTRB(24, 0, 0, 8),
      title: line,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: SelectableText(detail, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final r = run;
    final steps = (r?['steps'] as List?) ?? const [];
    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.auto_awesome, color: scheme.primary),
          const SizedBox(width: 10),
          Expanded(child: Text(tr('Let AI do the updates'))),
        ],
      ),
      content: SizedBox(
        width: 600,
        child: loading
            ? const SizedBox(height: 120, child: Center(child: CircularProgressIndicator()))
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _helperRow(scheme),
                  const SizedBox(height: 8),
                  Text(
                    tr('The helper sees the apps\' status and the results, and tells the Manager what to do. The Manager only updates or reinstalls apps and fetches Flutter packages: no code changes, no push, no password. Maprisma and the Manager itself keep their own Update buttons.'),
                    style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                  ),
                  if (ready.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(tr('No helper ready: install Claude Code, Codex, pi or Hermes and sign in, or connect pi or Hermes to a local model.'), style: TextStyle(color: scheme.error)),
                    ),
                  if (error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(error!, style: TextStyle(color: scheme.error))),
                  if (r != null) ...[
                    const Divider(height: 20),
                    Flexible(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 360),
                        child: ListView(
                          key: const ValueKey('ai-steps'),
                          controller: _scroll,
                          shrinkWrap: true,
                          children: [for (final s in steps) _step(s as Map, scheme)],
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    if (running)
                      Row(
                        children: [
                          const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                          const SizedBox(width: 8),
                          Text(_phase(r), style: TextStyle(color: scheme.onSurfaceVariant)),
                        ],
                      )
                    else
                      Text(
                        switch (r['state']) {
                          'succeeded' => tr('Finished'),
                          'cancelled' => tr('Stopped'),
                          _ => trf('Did not finish: {0}', [r['message'] ?? uiLabel(r['state'])]),
                        },
                        style: TextStyle(fontWeight: FontWeight.w600, color: r['state'] == 'failed' ? scheme.error : null),
                      ),
                  ],
                ],
              ),
      ),
      actions: [
        if (running)
          TextButton(onPressed: cancel, child: Text(tr('Stop')))
        else
          FilledButton.icon(
            key: const ValueKey('ai-start'),
            onPressed: loading || ready.isEmpty ? null : start,
            icon: const Icon(Icons.auto_awesome, size: 18),
            label: Text(r == null ? tr('Start') : tr('Start again')),
          ),
        TextButton(autofocus: true, onPressed: () => Navigator.pop(context), child: Text(tr('Close'))),
      ],
    );
  }
}
