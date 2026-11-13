import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:maprisma_manager_core/maprisma_manager_core.dart' show tr, trf;

import 'backend.dart' show ServiceError;
import 'core_call.dart';
import 'desktop_page.dart';
import 'settings_widgets.dart';
import 'theme.dart';

/// The Theme page: Maprisma Theme's themes in small (`theme.list`, through Theme's core), the
/// one in use marked, a click applies one (`theme.apply`, as the Theme app does); Dark/Light
/// narrows the grid. Everything else (editor, wallpapers, import) stays in Maprisma Theme
/// ("More in Maprisma Theme…").
class ThemePage extends StatefulWidget {
  const ThemePage({super.key, required this.core, this.onShowApps});
  final CoreCall core;

  /// "Install it on the Apps page".
  final VoidCallback? onShowApps;
  @override
  State<ThemePage> createState() => _ThemePageState();
}

class _ThemePageState extends State<ThemePage> {
  Map<String, dynamic>? data;
  ServiceError? problem;

  /// The theme being applied (its tile shows the progress; the others wait).
  String? applying;

  /// '' (all), 'dark' or 'light'.
  String mode = '';

  /// The palette the page was last built with: when it changes (a theme applied here or
  /// elsewhere, as Maprisma Theme or its applet), the list is read again for the new mark.
  ColorScheme? _scheme;

  @override
  void initState() {
    super.initState();
    unawaited(load());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scheme = Theme.of(context).colorScheme;
    final before = _scheme;
    _scheme = scheme;
    if (before != null && before != scheme && applying == null) unawaited(load());
  }

  Future<void> load() async {
    try {
      final r = await widget.core('theme.list');
      if (mounted) {
        setState(() {
          data = r;
          problem = null;
        });
      }
    } on ServiceError catch (e) {
      if (!mounted) return;
      if (data != null) {
        tellOn(this, failure(e));
      } else {
        setState(() => problem = e);
      }
    }
  }

  Future<void> apply(Map t) async {
    if (applying != null || t['current'] == true) return;
    setState(() => applying = t['slug'] as String);
    try {
      await widget.core('theme.apply', {'slug': t['slug']});
      tellOn(this, trf('{0} is the theme now', [t['name']]));
    } on ServiceError catch (e) {
      tellOn(this, failure(e));
    } finally {
      if (mounted) setState(() => applying = null);
    }
    await load();
  }

  Future<void> openTheme() async {
    try {
      await widget.core('apps.open', {'id': 'theme'});
    } on ServiceError catch (e) {
      tellOn(this, failure(e));
    }
  }

  List<Widget> _actions() => [
    if (applying != null) const Padding(padding: EdgeInsets.only(right: 8), child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))),
    IconButton(tooltip: tr('Reload'), onPressed: applying == null ? load : null, icon: const Icon(Icons.refresh)),
    TextButton(key: const ValueKey('theme-more'), onPressed: openTheme, child: Text(tr('More in Maprisma Theme…'))),
  ];

  Widget _problem(ServiceError e) {
    final missing = e.code == 'not_installed';
    return SettingsSection(
      children: [
        SettingsItem(
          leading: const Icon(Icons.palette_outlined),
          title: missing ? tr('Maprisma Theme is not installed') : e.code == 'too_old' ? tr('Update Maprisma Theme to pick its themes here') : failure(e),
          description: missing ? tr('Its themes are shown and applied here once it is installed.') : null,
          trailing: missing
              ? OutlinedButton(key: const ValueKey('theme-install'), onPressed: widget.onShowApps, child: Text(tr('Install it on the Apps page')))
              : OutlinedButton(key: const ValueKey('theme-retry'), onPressed: load, child: Text(tr('Try again'))),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = data;
    final e = problem;
    if (d == null) {
      return SettingsPage(
        title: tr('Theme'),
        actions: e == null || e.code == 'not_installed' ? const [] : _actions(),
        children: [e != null ? _problem(e) : const Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator()))],
      );
    }
    final all = (d['themes'] as List).cast<Map>();
    final modes = {for (final t in all) t['mode']};
    final shown = [for (final t in all) if (mode.isEmpty || t['mode'] == mode) t];
    final current = all.where((t) => t['current'] == true).firstOrNull;
    return SettingsPage(
      title: tr('Theme'),
      actions: _actions(),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                applying != null
                    ? trf('Applying {0}…', [all.where((t) => t['slug'] == applying).firstOrNull?['name'] ?? applying])
                    : current == null
                    ? tr('Click a theme to use it.')
                    : trf('In use: {0}. Click another theme to use it.', [current['name']]),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ),
            if (modes.length > 1)
              SegmentedButton<String>(
                key: const ValueKey('theme-mode'),
                showSelectedIcon: false,
                segments: [
                  ButtonSegment(value: '', label: Text(tr('All'))),
                  ButtonSegment(value: 'dark', label: Text(tr('Dark'))),
                  ButtonSegment(value: 'light', label: Text(tr('Light'))),
                ],
                selected: {mode},
                onSelectionChanged: (s) => setState(() => mode = s.first),
              ),
          ],
        ),
        if (shown.isEmpty)
          Padding(padding: const EdgeInsets.all(24), child: Center(child: Text(tr('No themes.'))))
        else
          LayoutBuilder(
            builder: (context, box) {
              const gap = 12.0;
              final columns = ((box.maxWidth + gap) / (200 + gap)).floor().clamp(1, 6);
              final width = (box.maxWidth - gap * (columns - 1)) / columns;
              return Wrap(
                spacing: gap,
                runSpacing: gap,
                children: [
                  for (final t in shown)
                    SizedBox(
                      width: width,
                      child: ThemeTile(
                        key: ValueKey('theme-${t['slug']}'),
                        theme: t,
                        busy: applying == t['slug'],
                        onTap: applying == null && t['current'] != true ? () => apply(t) : null,
                      ),
                    ),
                ],
              );
            },
          ),
      ],
    );
  }
}

Color? _hex(Object? v) {
  if (v is! String || v.length != 7 || !v.startsWith('#')) return null;
  final n = int.tryParse(v.substring(1), radix: 16);
  return n == null ? null : Color(0xff000000 | n);
}

/// One theme: its preview picture (else its colours), its name; the one in use framed in the
/// accent with a check; a star for Theme's favorites.
class ThemeTile extends StatefulWidget {
  const ThemeTile({super.key, required this.theme, required this.busy, required this.onTap});
  final Map theme;
  final bool busy;
  final VoidCallback? onTap;
  @override
  State<ThemeTile> createState() => _ThemeTileState();
}

class _ThemeTileState extends State<ThemeTile> {
  bool hover = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final c = cornerSizes(context);
    final t = widget.theme;
    final colors = (t['colors'] as Map?) ?? const {};
    final current = t['current'] == true;
    final preview = t['preview'] as String?;
    final swatch = _Swatches(colors: colors);
    final inner = c.radius == 0 ? 0.0 : (c.radius - 4).clamp(2.0, 12.0);
    return Tooltip(
      message: current ? tr('In use') : trf('Use {0}', [t['name']]),
      waitDuration: const Duration(milliseconds: 600),
      child: MouseRegion(
        cursor: widget.onTap == null ? SystemMouseCursors.basic : SystemMouseCursors.click,
        onEnter: (_) => setState(() => hover = true),
        onExit: (_) => setState(() => hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: Container(
            padding: EdgeInsets.all(current ? 3 : 4),
            decoration: BoxDecoration(
              color: hover && widget.onTap != null ? scheme.surfaceContainerHighest : scheme.surfaceContainerLow,
              border: current ? Border.all(color: scheme.primary, width: 2) : Border.all(color: hover && widget.onTap != null ? scheme.primary : scheme.outlineVariant),
              borderRadius: BorderRadius.circular(c.radius),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                AspectRatio(
                  aspectRatio: 16 / 9,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(inner),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (preview != null) Image.file(File(preview), fit: BoxFit.cover, cacheWidth: 480, errorBuilder: (_, _, _) => swatch) else swatch,
                        if (current)
                          Positioned(
                            left: 6,
                            bottom: 6,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(color: scheme.primary, borderRadius: BorderRadius.circular(c.small)),
                              child: Row(mainAxisSize: MainAxisSize.min, children: [
                                Icon(Icons.check, size: 14, color: scheme.onPrimary),
                                const SizedBox(width: 4),
                                Text(tr('In use'), style: Theme.of(context).textTheme.labelSmall?.copyWith(color: scheme.onPrimary)),
                              ]),
                            ),
                          ),
                        if (widget.busy) ColoredBox(color: Colors.black38, child: Center(child: SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 3, color: scheme.primary)))),
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 8, 4, 4),
                  child: Row(
                    children: [
                      if (t['favorite'] == true) ...[Icon(Icons.star, size: 15, color: scheme.primary), const SizedBox(width: 4)],
                      Expanded(
                        child: Text(
                          '${t['name']}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: current ? FontWeight.w600 : null),
                        ),
                      ),
                      Icon(t['mode'] == 'light' ? Icons.light_mode_outlined : Icons.dark_mode_outlined, size: 14, color: scheme.onSurfaceVariant),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A theme without a picture: its background with its accent and colours as bars.
class _Swatches extends StatelessWidget {
  const _Swatches({required this.colors});
  final Map colors;
  @override
  Widget build(BuildContext context) {
    final bars = [for (final k in ['accent', 'red', 'green', 'yellow', 'blue', 'magenta', 'cyan']) ?_hex(colors[k])];
    return ColoredBox(
      color: _hex(colors['background']) ?? Theme.of(context).colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Aa', style: TextStyle(color: _hex(colors['foreground']) ?? Theme.of(context).colorScheme.onSurface, fontWeight: FontWeight.w600)),
            const Spacer(),
            Row(children: [for (final b in bars) Expanded(child: Container(height: 10, margin: const EdgeInsets.only(right: 3), color: b))]),
          ],
        ),
      ),
    );
  }
}
