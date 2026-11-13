import 'package:maprisma_manager_core/maprisma_manager_core.dart' show tr, trf, uiLabel;
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
    padding: const EdgeInsets.fromLTRB(0, 16, 0, 4),
    child: Text(text, style: TextStyle(fontWeight: FontWeight.w700)),
  );

  Widget _line(String label, Widget value) => Padding(
    padding: EdgeInsets.symmetric(vertical: 4),
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
              if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(trf('Not opened: {0}', [e.reason ?? e.code]))));
            }
          },
          child: Text(url, style: TextStyle(color: scheme.primary, decoration: TextDecoration.underline, decorationColor: scheme.primary)),
        ),
        IconButton(
          tooltip: tr('Copy'),
          visualDensity: VisualDensity.compact,
          iconSize: 16,
          onPressed: () => Clipboard.setData(ClipboardData(text: url)),
          icon: Icon(Icons.copy),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final a = detail ?? widget.app;
    final scheme = Theme.of(context).colorScheme;
    final icon = a['icon'] as Map? ?? const {};
    final build = a['build'] as Map? ?? {};
    final receipt = build['receipt'] as Map?;
    final sources = a['sources'] as Map? ?? {};
    final rel = sources['release'] as Map?;
    final inputs = (sources['inputs'] as List?) ?? const [];
    final comps = (a['components'] as List?) ?? [];
    final checks = [for (final c in comps) if ((c as Map)['applies'] != false) ...((c['checks'] as List?) ?? [])];
    final prereqs = [
      for (final c in comps)
        if ((c as Map)['applies'] != false)
          for (final p in (c['prerequisites'] as List?) ?? const [])
            if ((p as Map)['found'] != true) p,
    ];
    final versions = a['versions'] as Map? ?? const {};
    final bar = a['bar'] as Map? ?? {};
    final reasons = updateReasons(a);
    return AlertDialog(
      title: Row(
        children: [
          AppIcon(icon['file'] as String?, symbolic: icon['symbolic'] == true, size: 36),
          SizedBox(width: 12),
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
                    if (a['note'] != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text(uiLabel(a['note']))),
                    _heading(tr('Where it exists')),
                    for (final i in inputs) ...[
                      if (inputs.length > 1) Text('${(i as Map)['repo']}', style: const TextStyle(fontWeight: FontWeight.w600)),
                      _line(
                        tr('Folder'),
                        _text((i as Map)['folder']?['present'] == true
                            ? trf('{0}  ({1} at {2}{3})', [i['folder']['path'], i['folder']['branch'] ?? tr('detached'), shortCommit(i['folder']['head']), i['folder']['dirty'] == true ? tr(', uncommitted changes') : ''])
                            : trf('{0}: missing', [i['folder']?['path'] ?? '?'])),
                      ),
                      _line(tr('GitHub'), i['github'] == null ? _text(tr('local only (not on GitHub)')) : _link('${i['github']['url']}')),
                    ],
                    _line(
                      tr('Latest release'),
                      rel == null
                          ? _text(sources['url'] == null ? '–' : tr('none'))
                          : Wrap(children: [
                              _text('${rel['tag']}${rel['published'] == null ? '' : ', ${'${rel['published']}'.split('T').first}'}  '),
                              if (rel['url'] is String && '${rel['url']}'.startsWith('https://github.com/')) _link('${rel['url']}'),
                            ]),
                    ),
                    _heading(tr('Installed build')),
                    if (!installed(a))
                      _text(tr('Not installed'))
                    else ...[
                      _line(tr('State'), _text(trf('{0}{1}', [uiLabel(a['state']), missingParts(a).isEmpty ? '' : trf(' (no {0})', [missingParts(a).join(', ')])]))),
                      _line(tr('Version'), _text(trf('{0}{1}', [versions['installed'] ?? tr('unknown'), versions['folder'] != null ? trf('  (folder: {0})', [versions['folder']]) : '']))),
                      if (receipt == null)
                        _line(tr('Build'), _text(build['error'] != null ? trf('receipt not readable: {0}', [build['error']]) : tr('unknown: installed before Maprisma Settings')))
                      else ...[
                        _line(tr('Installed'), _text(trf('{0} UTC', ['${receipt['at']}'.replaceFirst('T', ' ').split('.').first]))),
                        for (final i in (receipt['inputs'] as List?) ?? const [])
                          _line(tr('Commit'), _text('${(i as Map)['repo']} ${shortCommit(i['commit'])}${i['dirty'] == true ? tr(' (with uncommitted changes)') : ''}')),
                      ],
                      if (reasons.isNotEmpty) _line(tr('Updates'), _text(reasons.join('\n'))),
                    ],
                    _heading(tr('What it installs')),
                    _text(trf('{0} files and links{1}', [checks.length, checks.where((c) => (c as Map)['ok'] != true).isEmpty || !installed(a) ? '' : trf(', {0} not as installed', [checks.where((c) => (c as Map)['ok'] != true).length])]) +
                        (comps.length > 1 ? trf(' in {0} parts', [comps.length]) : '')),
                    if (bar['has'] == true)
                      _line(tr('Bar icon'), _text('${bar['iconName'] ?? bar['id']}${installed(a) ? ' · ${bar['state'] == 'in' ? trf('in the bar ({0})', [zoneName(bar['zone'])]) : uiLabel(bar['state'])}' : ''}')),
                    if (((a['dependsOn'] as List?) ?? const []).isNotEmpty) _line(tr('Needs'), _text((a['dependsOn'] as List).join(', '))),
                    if (((a['neededBy'] as List?) ?? const []).isNotEmpty) _line(tr('Needed by'), _text((a['neededBy'] as List).join(', '))),
                    _heading(tr('Prerequisites')),
                    if (prereqs.isEmpty)
                      _text(tr('All found'))
                    else
                      for (final p in prereqs)
                        _line(
                          tr('Missing'),
                          Text('${p['command']}${p['part'] != null ? trf(' (for the {0})', [uiLabel(p['part'])]) : ''}${p['optional'] == true ? tr(', optional') : ''}${p['note'] != null ? ': ${uiLabel(p['note'])}' : ''}',
                              style: TextStyle(color: p['optional'] == true || p['part'] != null ? null : scheme.error)),
                        ),
                    if ((a['support'] as Map?)?['note'] != null) ...[
                      _heading(tr('Notes')),
                      _text(uiLabel(a['support']['note'])),
                    ],
                  ],
                ),
              ),
      ),
      actions: [TextButton(autofocus: true, onPressed: () => Navigator.pop(context), child: Text(tr('Close')))],
    );
  }
}
