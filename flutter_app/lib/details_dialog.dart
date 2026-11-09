import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_facts.dart';
import 'app_icon.dart';
import 'backend.dart' show ServiceError;
import 'core_call.dart';

/// Where an app exists (its folder, GitHub with a link, the latest release), the installed build,
/// what it installs, its bar icon and the prerequisites it misses (`apps.get`).
class DetailsDialog extends StatefulWidget {
  const DetailsDialog({super.key, required this.core, required this.app, this.desktop = 'cosmic'});
  final CoreCall core;
  final App app;
  final String desktop;
  @override
  State<DetailsDialog> createState() => _DetailsDialogState();
}

class _DetailsDialogState extends State<DetailsDialog> {
  App? detail;
  String? error;

  @override
  void initState() {
    super.initState();
    widget.core('apps.get', {'id': widget.app['id']}).then((r) {
      if (mounted) setState(() => detail = Map<String, dynamic>.from(r['app'] as Map));
    }, onError: (Object e) {
      if (mounted) setState(() => error = e is ServiceError ? '${e.code}: ${e.reason ?? ''}' : '$e');
    });
  }

  Widget _heading(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(0, 14, 0, 4),
    child: Text(text, style: const TextStyle(fontWeight: FontWeight.w700)),
  );

  Widget _line(String label, Widget value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 120, child: Text(label, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant))),
        Expanded(child: value),
      ],
    ),
  );

  Widget _text(String t) => SelectableText(t);

  Widget _link(String url) {
    final scheme = Theme.of(context).colorScheme;
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        InkWell(
          onTap: () async {
            try {
              await widget.core('links.open', {'url': url});
            } on ServiceError catch (e) {
              if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Not opened: ${e.reason ?? e.code}')));
            }
          },
          child: Text(url, style: TextStyle(color: scheme.primary, decoration: TextDecoration.underline, decorationColor: scheme.primary)),
        ),
        IconButton(
          tooltip: 'Copy',
          visualDensity: VisualDensity.compact,
          iconSize: 16,
          onPressed: () => Clipboard.setData(ClipboardData(text: url)),
          icon: const Icon(Icons.copy),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final a = detail ?? widget.app;
    final scheme = Theme.of(context).colorScheme;
    final icon = a['icon'] as Map? ?? const {};
    final build = a['build'] as Map? ?? const {};
    final receipt = build['receipt'] as Map?;
    final sources = a['sources'] as Map? ?? const {};
    final rel = sources['release'] as Map?;
    final inputs = (sources['inputs'] as List?) ?? const [];
    final comps = (a['components'] as List?) ?? const [];
    final checks = [for (final c in comps) if ((c as Map)['applies'] != false) ...((c['checks'] as List?) ?? const [])];
    final prereqs = [
      for (final c in comps)
        if ((c as Map)['applies'] != false)
          for (final p in (c['prerequisites'] as List?) ?? const [])
            if ((p as Map)['found'] != true) p,
    ];
    final versions = a['versions'] as Map? ?? const {};
    final bar = a['bar'] as Map? ?? const {};
    final reasons = updateReasons(a);
    return AlertDialog(
      title: Row(
        children: [
          AppIcon(icon['file'] as String?, symbolic: icon['symbolic'] == true, size: 36),
          const SizedBox(width: 12),
          Expanded(child: Text('${a['name']}')),
        ],
      ),
      content: SizedBox(
        width: 560,
        child: error != null
            ? Text(error!, style: TextStyle(color: scheme.error))
            : detail == null
            ? const SizedBox(height: 120, child: Center(child: CircularProgressIndicator()))
            : SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(subtitle(a, widget.desktop),
                        style: TextStyle(color: scheme.onSurfaceVariant)),
                    if (a['note'] != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text('${a['note']}')),
                    _heading('Where it exists'),
                    for (final i in inputs) ...[
                      if (inputs.length > 1) Text('${(i as Map)['repo']}', style: const TextStyle(fontWeight: FontWeight.w600)),
                      _line(
                        'Folder',
                        _text((i as Map)['folder']?['present'] == true
                            ? '${i['folder']['path']}  (${i['folder']['branch'] ?? 'detached'} at ${shortCommit(i['folder']['head'])}${i['folder']['dirty'] == true ? ', uncommitted changes' : ''})'
                            : '${i['folder']?['path'] ?? '?'}: missing'),
                      ),
                      _line('GitHub', i['github'] == null ? _text('local only (not on GitHub)') : _link('${i['github']['url']}')),
                    ],
                    _line(
                      'Latest release',
                      rel == null
                          ? _text(sources['url'] == null ? '–' : 'none')
                          : Wrap(children: [
                              _text('${rel['tag']}${rel['published'] == null ? '' : ', ${'${rel['published']}'.split('T').first}'}  '),
                              if (rel['url'] is String && '${rel['url']}'.startsWith('https://github.com/')) _link('${rel['url']}'),
                            ]),
                    ),
                    _heading('Installed build'),
                    if (!installed(a))
                      _text('Not installed')
                    else ...[
                      _line('State', _text('${a['state']}${missingParts(a).isEmpty ? '' : ' (no ${missingParts(a).join(', ')})'}')),
                      _line('Version', _text('${versions['installed'] ?? 'unknown'}${versions['folder'] != null ? '  (folder: ${versions['folder']})' : ''}')),
                      if (receipt == null)
                        _line('Build', _text(build['error'] != null ? 'receipt not readable: ${build['error']}' : 'unknown: installed before the Manager'))
                      else ...[
                        _line('Installed', _text('${'${receipt['at']}'.replaceFirst('T', ' ').split('.').first} UTC')),
                        for (final i in (receipt['inputs'] as List?) ?? const [])
                          _line('Commit', _text('${(i as Map)['repo']} ${shortCommit(i['commit'])}${i['dirty'] == true ? ' (with uncommitted changes)' : ''}')),
                      ],
                      if (reasons.isNotEmpty) _line('Updates', _text(reasons.join('\n'))),
                    ],
                    _heading('What it installs'),
                    _text('${checks.length} files and links${checks.where((c) => (c as Map)['ok'] != true).isEmpty || !installed(a) ? '' : ', ${checks.where((c) => (c as Map)['ok'] != true).length} not as installed'}'
                        '${comps.length > 1 ? ' in ${comps.length} parts' : ''}'),
                    if (bar['has'] == true)
                      _line('Bar icon', _text('${bar['iconName'] ?? bar['id']}${installed(a) ? ' · ${bar['state'] == 'in' ? 'in the bar (${zoneName(bar['zone'])})' : bar['state']}' : ''}')),
                    if (((a['dependsOn'] as List?) ?? const []).isNotEmpty) _line('Needs', _text((a['dependsOn'] as List).join(', '))),
                    if (((a['neededBy'] as List?) ?? const []).isNotEmpty) _line('Needed by', _text((a['neededBy'] as List).join(', '))),
                    _heading('Prerequisites'),
                    if (prereqs.isEmpty)
                      _text('All found')
                    else
                      for (final p in prereqs)
                        _line(
                          'Missing',
                          Text('${p['command']}${p['part'] != null ? ' (for the ${p['part']})' : ''}${p['optional'] == true ? ', optional' : ''}${p['note'] != null ? ': ${p['note']}' : ''}',
                              style: TextStyle(color: p['optional'] == true || p['part'] != null ? null : scheme.error)),
                        ),
                    if ((a['support'] as Map?)?['note'] != null) ...[
                      _heading('Notes'),
                      _text('${a['support']['note']}'),
                    ],
                  ],
                ),
              ),
      ),
      actions: [TextButton(autofocus: true, onPressed: () => Navigator.pop(context), child: const Text('Close'))],
    );
  }
}
