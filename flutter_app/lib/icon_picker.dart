import 'package:maprisma_manager_core/maprisma_manager_core.dart' show tr, trf, uiLabel;
import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'app_facts.dart';
import 'backend.dart' show ServiceError;
import 'core_call.dart';
import 'theme.dart';

/// Picks another bar icon for an app (`icons.get`, `icons.set`, `icons.reset`): the icon theme's
/// symbolic icons to search, a preview, an SVG file of your own, and Reset. Pops true when it
/// changed something.
class IconPicker extends StatefulWidget {
  const IconPicker({super.key, required this.core, required this.app, this.pickFile});
  final CoreCall core;
  final App app;

  /// Tests replace the file chooser.
  final Future<String?> Function()? pickFile;
  @override
  State<IconPicker> createState() => _IconPickerState();
}

class _IconPickerState extends State<IconPicker> {
  Map<String, dynamic>? info;
  List<Map> choices = [];
  String query = '';
  String? selected, selectedFile, error;
  bool working = false, changed = false;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _search();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _search() async {
    try {
      final r = await widget.core('icons.get', {'app': widget.app['id'], 'query': query, 'limit': 240});
      if (!mounted) return;
      setState(() {
        info = r;
        choices = ((r['choices'] as List?) ?? const []).cast<Map>();
        error = null;
      });
    } on ServiceError catch (e) {
      if (mounted) setState(() => error = e.reason ?? e.code);
    }
  }

  Future<void> _apply(String icon) async {
    setState(() => working = true);
    try {
      await widget.core('icons.set', {'app': widget.app['id'], 'icon': icon});
      changed = true;
      if (mounted) Navigator.pop(context, true);
    } on ServiceError catch (e) {
      if (mounted) setState(() => error = '${e.code == 'bad_icon' ? tr('Not an icon the Manager writes') : e.code}: ${e.reason ?? ''}');
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  Future<void> _reset() async {
    setState(() => working = true);
    try {
      await widget.core('icons.reset', {'app': widget.app['id']});
      changed = true;
      if (mounted) Navigator.pop(context, true);
    } on ServiceError catch (e) {
      if (mounted) setState(() => error = e.reason ?? e.code);
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  Future<void> _pickFile() async {
    final String? path;
    if (widget.pickFile != null) {
      path = await widget.pickFile!();
    } else {
      final f = await openFile(acceptedTypeGroups: [XTypeGroup(label: tr('SVG icons'), extensions: ['svg'], mimeTypes: ['image/svg+xml'])]);
      path = f?.path;
    }
    if (path == null || !mounted) return;
    setState(() {
      selected = null;
      selectedFile = path;
    });
  }

  Widget _svg(String? file, double size) {
    final scheme = Theme.of(context).colorScheme;
    if (file == null || !File(file).existsSync()) return Icon(Icons.image_not_supported_outlined, size: size, color: scheme.onSurfaceVariant);
    return SvgPicture.file(
      File(file),
      width: size,
      height: size,
      colorFilter: file.endsWith('-symbolic.svg') ? ColorFilter.mode(scheme.onSurface, BlendMode.srcIn) : null,
      placeholderBuilder: (_) => SizedBox(width: size, height: size),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final i = info;
    final changeable = i?['changeable'] == true;
    final pickedFile = selectedFile ??
        (selected == null ? null : choices.where((c) => c['name'] == selected).firstOrNull?['file'] as String?);
    final width = MediaQuery.sizeOf(context).width;
    return AlertDialog(
      title: Text(trf('Bar icon of {0}', [widget.app['name']])),
      content: SizedBox(
        width: width < 640 ? width - 80 : 560,
        // the grid keeps room on small windows too
        height: (MediaQuery.sizeOf(context).height - 220).clamp(340.0, 560.0),
        child: i == null
            ? (error != null ? Text(error!, style: TextStyle(color: scheme.error)) : const Center(child: CircularProgressIndicator()))
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Column(children: [
                        _svg(i['file'] as String?, 40),
                        const SizedBox(height: 4),
                        Text(i['current'] == 'original' ? tr('now (original)') : tr('now (changed)'), style: Theme.of(context).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant)),
                      ]),
                      SizedBox(width: 12),
                      Icon(Icons.arrow_forward, color: scheme.onSurfaceVariant),
                      SizedBox(width: 12),
                      Column(children: [
                        pickedFile == null ? SizedBox(width: 40, height: 40, child: Icon(Icons.help_outline, color: scheme.outlineVariant)) : _svg(pickedFile, 40),
                        const SizedBox(height: 4),
                        Text(tr('new'), style: Theme.of(context).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant)),
                      ]),
                      SizedBox(width: 16),
                      Expanded(
                        child: Text(
                          selectedFile != null ? selectedFile! : (selected ?? tr('Pick an icon below, or a file')),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: scheme.onSurfaceVariant),
                        ),
                      ),
                    ],
                  ),
                  if (!changeable)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(trf('It can\'t be changed: {0}', [i['why'] ?? tr('no icon of its own')]), style: TextStyle(color: scheme.error)),
                    ),
                  if (i['note'] != null)
                    Padding(
                      padding: EdgeInsets.only(top: 12),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.info_outline, size: 16, color: scheme.onSurfaceVariant),
                          const SizedBox(width: 8),
                          // a long note stays short on narrow windows; the whole text in its tooltip
                          Expanded(
                            child: Tooltip(
                              message: uiLabel(i['note']),
                              child: Text(trf('Note: {0}', [uiLabel(i['note'])]),
                                  maxLines: width < 640 ? 3 : 5,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(error!, style: TextStyle(color: scheme.error))),
                  const SizedBox(height: 12),
                  TextField(
                    key: ValueKey('icon-search'),
                    autofocus: true,
                    enabled: changeable,
                    decoration: InputDecoration(
                      hintText: trf('Search {0}\'s icons', [(i['theme'] as Map?)?['name'] ?? tr('the icon theme')]),
                      prefixIcon: Icon(Icons.search, size: 20),
                    ),
                    onChanged: (v) {
                      query = v;
                      _debounce?.cancel();
                      _debounce = Timer(const Duration(milliseconds: 250), _search);
                    },
                  ),
                  const SizedBox(height: 8),
                  Text(
                    trf('{0} icons{1}', [i['total'], i['truncated'] == true ? trf(', the first {0} shown', [choices.length]) : '']),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                  SizedBox(height: 4),
                  Expanded(
                    child: GridView.builder(
                      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 52, mainAxisSpacing: 4, crossAxisSpacing: 4),
                      itemCount: changeable ? choices.length : 0,
                      itemBuilder: (context, n) {
                        final c = choices[n];
                        final on = c['name'] == selected;
                        return Tooltip(
                          message: '${c['name']} (${c['theme']})',
                          waitDuration: Duration(milliseconds: 400),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(cornerSizes(context).control),
                            onTap: () => setState(() {
                              selected = '${c['name']}';
                              selectedFile = null;
                            }),
                            onDoubleTap: () => _apply('${c['name']}'),
                            child: Container(
                              decoration: BoxDecoration(
                                color: on ? scheme.primary.withValues(alpha: .18) : null,
                                borderRadius: BorderRadius.circular(cornerSizes(context).control),
                                border: Border.all(color: on ? scheme.primary : Colors.transparent),
                              ),
                              child: Center(child: _svg(c['file'] as String?, 24)),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
      ),
      actions: [
        TextButton(onPressed: !changeable || working ? null : _pickFile, child: Text(tr('Choose an SVG file…'))),
        TextButton(onPressed: i?['current'] == 'original' || i?['current'] == null || working ? null : _reset, child: Text(tr('Reset'))),
        TextButton(onPressed: () => Navigator.pop(context, changed), child: Text(tr('Cancel'))),
        FilledButton(
          onPressed: !changeable || working || (selected == null && selectedFile == null) ? null : () => _apply(selectedFile ?? selected!),
          child: working ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : Text(tr('Use this icon')),
        ),
      ],
    );
  }
}
