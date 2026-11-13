import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:maprisma_manager_core/maprisma_manager_core.dart' show tr, trf;

import 'backend.dart' show ServiceError;
import 'core_call.dart';
import 'desktop_page.dart';
import 'flip_picture.dart';
import 'settings_widgets.dart';
import 'theme.dart';

/// The Theme page: Maprisma Theme's themes in small (`theme.list`, through Theme's core) under a
/// big preview of the selected one (pointer, click or arrow keys; else the one in use) with its
/// name, mode, colours and Apply (`theme.apply`, as the Theme app does). As in Maprisma Theme a
/// card turns in 3D to its wallpapers under the pointer ("3D flip to wallpaper on hover") and the
/// big preview turns by itself after the delay ("Auto-rotate big preview"); both settings are
/// Theme's, shown here read only. Double-click or Enter applies; Dark/Light narrows the grid.
/// Everything else (editor, wallpapers, import) stays in Maprisma Theme ("More in Maprisma Theme…").
class ThemePage extends StatefulWidget {
  const ThemePage({super.key, required this.core, this.onShowApps});
  final CoreCall core;

  /// "Install it on the Apps page".
  final VoidCallback? onShowApps;
  @override
  State<ThemePage> createState() => _ThemePageState();
}

/// A pointer resting this long on a card selects it (passing over cards on the way to the big
/// preview doesn't).
const hoverSelectDelay = Duration(milliseconds: 220);

/// Two clicks on the same card within this apply it.
const doubleClickTime = Duration(milliseconds: 400);

class _ThemePageState extends State<ThemePage> {
  Map<String, dynamic>? data;
  ServiceError? problem;

  /// The theme being applied (its tile shows the progress; the others wait).
  String? applying;

  /// '' (all), 'dark' or 'light'.
  String mode = '';

  /// The theme the big preview shows (null: the one in use).
  String? selected;

  /// The palette the page was last built with: when it changes (a theme applied here or
  /// elsewhere, as Maprisma Theme or its applet), the list is read again for the new mark.
  ColorScheme? _scheme;

  final gridFocus = FocusNode(debugLabel: 'theme grid');
  final scroll = ScrollController();
  final bigFlip = GlobalKey<FlipPictureState>();
  final _tileKeys = <String, GlobalKey>{};
  int columns = 1;
  Timer? _hoverTimer;
  (String, DateTime)? _lastTap;

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

  @override
  void dispose() {
    _hoverTimer?.cancel();
    gridFocus.dispose();
    scroll.dispose();
    super.dispose();
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

  List<Map> get _all => data == null ? const [] : (data!['themes'] as List).cast<Map>();
  List<Map> get shown => [for (final t in _all) if (mode.isEmpty || t['mode'] == mode) t];
  Map<String, dynamic> get settings => (data?['settings'] as Map?)?.cast<String, dynamic>() ?? const {};

  /// The theme in the big preview: the selected one, else the one in use, else the first.
  Map? previewed(List<Map> list) =>
      list.where((t) => t['slug'] == selected).firstOrNull ?? list.where((t) => t['current'] == true).firstOrNull ?? list.firstOrNull;

  void select(String slug, {bool reveal = false}) {
    if (selected != slug) setState(() => selected = slug);
    if (!reveal) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final c = _tileKeys[slug]?.currentContext;
      if (c != null && c.mounted) Scrollable.ensureVisible(c, duration: const Duration(milliseconds: 100), alignment: .5);
    });
  }

  void _tap(Map t) {
    final slug = t['slug'] as String;
    gridFocus.requestFocus();
    _hoverTimer?.cancel();
    final now = DateTime.now();
    final last = _lastTap;
    _lastTap = (slug, now);
    select(slug);
    if (last != null && last.$1 == slug && now.difference(last.$2) <= doubleClickTime) {
      _lastTap = null;
      unawaited(apply(t));
    }
  }

  void _hover(String slug, bool inside) {
    _hoverTimer?.cancel();
    if (inside) _hoverTimer = Timer(hoverSelectDelay, () => mounted ? select(slug) : null);
  }

  KeyEventResult onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    // Only while the grid itself has the keyboard (a focused button keeps its own keys).
    if (!gridFocus.hasPrimaryFocus) return KeyEventResult.ignored;
    final list = shown;
    if (list.isEmpty) return KeyEventResult.ignored;
    final cur = previewed(list);
    final i = cur == null ? 0 : list.indexOf(cur);
    int to;
    switch (e.logicalKey) {
      case LogicalKeyboardKey.arrowLeft:
        to = i - 1;
      case LogicalKeyboardKey.arrowRight:
        to = i + 1;
      case LogicalKeyboardKey.arrowUp:
        to = i - columns;
      case LogicalKeyboardKey.arrowDown:
        to = i + columns;
      case LogicalKeyboardKey.home:
        to = 0;
      case LogicalKeyboardKey.end:
        to = list.length - 1;
      case LogicalKeyboardKey.enter || LogicalKeyboardKey.numpadEnter:
        if (cur != null && e is KeyDownEvent) unawaited(apply(cur));
        return KeyEventResult.handled;
      default:
        return KeyEventResult.ignored;
    }
    if (to >= 0 && to < list.length) select(list[to]['slug'] as String, reveal: true);
    return KeyEventResult.handled;
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

  /// Theme's two preview settings, read only here (Theme core has no way to set them from
  /// outside): the switches show what Maprisma Theme does, the note says where they are set.
  Widget _settings(bool reduced) {
    final s = settings;
    return SettingsSection(
      key: const ValueKey('theme-preview-settings'),
      title: tr('Preview'),
      note: reduced
          ? tr('Reduced motion is on: the previews turn only with the arrows. Set in Maprisma Theme › Settings.')
          : tr('Set in Maprisma Theme › Settings.'),
      children: [
        SettingsToggle(
          key: const ValueKey('theme-flip-3d'),
          title: tr('3D flip to wallpaper on hover'),
          description: tr("Hovering a theme card flips its preview in 3D to show the theme's wallpaper."),
          value: s['preview_flip_3d'] != false,
          onChanged: null,
        ),
        SettingsToggle(
          key: const ValueKey('theme-auto-rotate'),
          title: tr('Auto-rotate big preview'),
          description: tr('Automatically flips the big preview to its first wallpaper after the 3D rotation delay. Off keeps the theme preview until you use the arrows.'),
          value: s['preview_big_auto_rotate'] != false,
          onChanged: null,
        ),
      ],
    );
  }

  Widget _status(List<Map> all, Map? current) {
    final modes = {for (final t in all) t['mode']};
    return Row(
      children: [
        Expanded(
          child: Text(
            applying != null
                ? trf('Applying {0}…', [all.where((t) => t['slug'] == applying).firstOrNull?['name'] ?? applying])
                : current == null
                ? tr('Click a theme to preview it; double-click or Enter uses it.')
                : trf('In use: {0}. Click a theme to preview it; double-click or Enter uses it.', [current['name']]),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        ),
        if (modes.length > 1) ...[
          const SizedBox(width: 8),
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
      ],
    );
  }

  Widget _grid(List<Map> list, Map? big, bool flip, double delay, bool reduced) {
    if (list.isEmpty) return Padding(padding: const EdgeInsets.all(24), child: Center(child: Text(tr('No themes.'))));
    return LayoutBuilder(
      builder: (context, box) {
        const gap = 12.0;
        columns = ((box.maxWidth + gap) / (200 + gap)).floor().clamp(1, 6);
        final width = (box.maxWidth - gap * (columns - 1)) / columns;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final t in list)
              SizedBox(
                key: _tileKeys.putIfAbsent(t['slug'] as String, GlobalKey.new),
                width: width,
                child: ThemeTile(
                  key: ValueKey('theme-${t['slug']}'),
                  theme: t,
                  busy: applying == t['slug'],
                  selected: identical(t, big),
                  flip: flip && !reduced,
                  flipDelay: delay,
                  onTap: applying == null ? () => _tap(t) : null,
                  onHover: (inside) => _hover(t['slug'] as String, inside),
                ),
              ),
          ],
        );
      },
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
    final all = _all;
    final list = shown;
    final current = all.where((t) => t['current'] == true).firstOrNull;
    final big = previewed(list);
    final reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final s = settings;
    final delay = (s['preview_flip_delay'] as num?)?.toDouble() ?? 2.0;
    final flip = s['preview_flip_3d'] != false;
    final autoRotate = s['preview_big_auto_rotate'] != false && !reduced;
    final side = SettingsMetrics.sidePadding(context);
    return LayoutBuilder(
      builder: (context, outer) {
        final bounded = outer.maxHeight.isFinite;
        final previewHeight = bounded ? (outer.maxHeight * .4).clamp(130.0, 340.0) : 300.0;
        final header = <Widget>[
          SettingsTitle(tr('Theme'), trailing: _actions()),
          _status(all, current),
          const SizedBox(height: 12),
          if (big != null) ...[
            BigThemePreview(
              key: const ValueKey('theme-big'),
              theme: big,
              flipKey: bigFlip,
              maxPictureHeight: previewHeight,
              delaySeconds: autoRotate ? delay : 0,
              instant: reduced,
              busy: applying == big['slug'],
              onApply: applying == null && big['current'] != true ? () => apply(big) : null,
            ),
            const SizedBox(height: 16),
          ],
        ];
        final body = <Widget>[
          _grid(list, big, flip, delay, reduced),
          const SizedBox(height: SettingsMetrics.sectionGap),
          _settings(reduced),
        ];
        Widget column(List<Widget> children) => Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: SettingsMetrics.maxWidth),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: children),
          ),
        );
        final keys = Focus(focusNode: gridFocus, autofocus: true, onKeyEvent: onKey, child: column(body));
        if (!bounded) {
          return Padding(padding: EdgeInsets.fromLTRB(side, 16, side, 24), child: Column(children: [column(header), keys]));
        }
        // The big preview stays in view; only the cards scroll under it.
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(padding: EdgeInsets.fromLTRB(side, 16, side, 0), child: column(header)),
            Expanded(
              child: ListView(
                controller: scroll,
                padding: EdgeInsets.fromLTRB(side, 0, side, 24),
                children: [keys],
              ),
            ),
          ],
        );
      },
    );
  }
}

Color? _hex(Object? v) {
  if (v is! String || v.length != 7 || !v.startsWith('#')) return null;
  final n = int.tryParse(v.substring(1), radix: 16);
  return n == null ? null : Color(0xff000000 | n);
}

List<String> _wallpapers(Map t) => [for (final w in (t['wallpapers'] as List?) ?? const []) if (w is String) w];

/// The "In use" mark over a card's picture.
class _InUse extends StatelessWidget {
  const _InUse();
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(color: scheme.primary, borderRadius: BorderRadius.circular(cornerSizes(context).small)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.check, size: 14, color: scheme.onPrimary),
        const SizedBox(width: 4),
        Text(tr('In use'), style: Theme.of(context).textTheme.labelSmall?.copyWith(color: scheme.onPrimary)),
      ]),
    );
  }
}

/// A theme's picture: its preview turning in 3D to its wallpapers ([FlipPicture]) when it has
/// both and [flip] is on, else the preview, else its colours.
Widget themePicture({
  required Map theme,
  required double radius,
  required bool flip,
  required bool active,
  required double delaySeconds,
  required bool instant,
  required int cacheWidth,
  Key? flipKey,
  Widget? badges,
}) {
  final colors = (theme['colors'] as Map?) ?? const {};
  final preview = theme['preview'] as String?;
  final walls = _wallpapers(theme);
  final swatch = _Swatches(colors: colors);
  if (flip && preview != null && walls.isNotEmpty) {
    return FlipPicture(
      key: flipKey ?? ValueKey('flip-${theme['slug']}'),
      slug: theme['slug'] as String,
      preview: preview,
      wallpapers: walls,
      borderRadius: radius,
      active: active,
      delaySeconds: delaySeconds,
      instant: instant,
      fallback: swatch,
      badges: badges,
    );
  }
  return ClipRRect(
    borderRadius: BorderRadius.circular(radius),
    child: Stack(fit: StackFit.expand, children: [
      if (preview != null) Image.file(File(preview), fit: BoxFit.cover, cacheWidth: cacheWidth, errorBuilder: (_, _, _) => swatch) else swatch,
      if (badges != null) Positioned(left: 6, bottom: 6, child: badges),
    ]),
  );
}

/// The big preview of the selected theme: its picture turning to its wallpapers (‹ › step
/// through them; it turns by itself after Theme's delay when "Auto-rotate big preview" is on),
/// beside its name, mode, colours and Apply (under each other in a narrow window).
class BigThemePreview extends StatelessWidget {
  const BigThemePreview({
    super.key,
    required this.theme,
    required this.flipKey,
    required this.maxPictureHeight,
    required this.delaySeconds,
    required this.instant,
    required this.busy,
    required this.onApply,
  });
  final Map theme;
  final GlobalKey<FlipPictureState> flipKey;
  final double maxPictureHeight;
  final double delaySeconds;
  final bool instant, busy;
  final VoidCallback? onApply;

  static const _swatchKeys = ['background', 'foreground', 'accent', 'red', 'green', 'yellow', 'blue', 'magenta', 'cyan'];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final c = cornerSizes(context);
    final t = theme;
    final current = t['current'] == true;
    final colors = (t['colors'] as Map?) ?? const {};
    final light = t['mode'] == 'light';
    final inner = c.radius == 0 ? 0.0 : (c.radius - 4).clamp(2.0, 12.0);
    final picture = Stack(fit: StackFit.expand, children: [
      // Another theme: FlipPicture starts again from its preview (it resets on a new slug).
      themePicture(theme: t, radius: inner, flip: true, active: true, delaySeconds: delaySeconds, instant: instant, cacheWidth: 1280, flipKey: flipKey),
      if (busy)
        ClipRRect(
          borderRadius: BorderRadius.circular(inner),
          child: ColoredBox(color: Colors.black38, child: Center(child: SizedBox(width: 32, height: 32, child: CircularProgressIndicator(strokeWidth: 3, color: scheme.primary)))),
        ),
    ]);
    final info = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(children: [
          if (t['favorite'] == true) ...[Icon(Icons.star, size: 18, color: scheme.primary), const SizedBox(width: 4)],
          Expanded(child: Text('${t['name']}', key: const ValueKey('theme-big-name'), maxLines: 2, overflow: TextOverflow.ellipsis, style: text.titleMedium?.copyWith(fontWeight: FontWeight.w600))),
        ]),
        const SizedBox(height: 4),
        Row(children: [
          Icon(light ? Icons.light_mode_outlined : Icons.dark_mode_outlined, size: 16, color: scheme.onSurfaceVariant),
          const SizedBox(width: 4),
          Text(light ? tr('Light') : tr('Dark'), style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
        ]),
        const SizedBox(height: 12),
        Wrap(
          key: const ValueKey('theme-big-swatches'),
          spacing: 4,
          runSpacing: 4,
          children: [
            for (final k in _swatchKeys)
              if (_hex(colors[k]) case final color?)
                Tooltip(
                  message: '$k ${colors[k]}',
                  child: Container(
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(color: color, border: Border.all(color: scheme.outlineVariant), borderRadius: BorderRadius.circular(c.small)),
                  ),
                ),
          ],
        ),
        if (_wallpapers(t).isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(trf('Wallpapers: {0} (‹ › on the picture)', [_wallpapers(t).length]), style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
        ],
        const SizedBox(height: 16),
        FilledButton.icon(
          key: const ValueKey('theme-apply'),
          onPressed: onApply,
          icon: Icon(current ? Icons.check : Icons.play_arrow, size: 18),
          label: Text(current ? tr('In use') : tr('Apply theme')),
        ),
      ],
    );
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: current ? Border.all(color: scheme.primary, width: 2) : Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(c.radius),
      ),
      child: LayoutBuilder(
        builder: (context, box) {
          if (box.maxWidth < 560) {
            final w = math.min(box.maxWidth, maxPictureHeight * 16 / 9);
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
              Center(child: SizedBox(width: w, height: w * 9 / 16, child: picture)),
              const SizedBox(height: 12),
              info,
            ]);
          }
          final w = math.min(box.maxWidth * .62, maxPictureHeight * 16 / 9);
          return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: w, height: w * 9 / 16, child: picture),
            const SizedBox(width: 16),
            Expanded(child: info),
          ]);
        },
      ),
    );
  }
}

/// One theme: its preview picture (else its colours) turning to its wallpapers under the
/// pointer, its name; the one in use framed in the accent with a check; the selected one (in the
/// big preview) on the selection colour; a star for Theme's favorites.
class ThemeTile extends StatefulWidget {
  const ThemeTile({
    super.key,
    required this.theme,
    required this.busy,
    required this.onTap,
    this.selected = false,
    this.flip = false,
    this.flipDelay = 2,
    this.onHover,
  });
  final Map theme;
  final bool busy;
  final VoidCallback? onTap;
  final bool selected;
  final bool flip;
  final double flipDelay;
  final ValueChanged<bool>? onHover;
  @override
  State<ThemeTile> createState() => _ThemeTileState();
}

class _ThemeTileState extends State<ThemeTile> {
  bool hover = false;

  void _setHover(bool on) {
    setState(() => hover = on);
    widget.onHover?.call(on);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final c = cornerSizes(context);
    final t = widget.theme;
    final current = t['current'] == true;
    final inner = c.radius == 0 ? 0.0 : (c.radius - 4).clamp(2.0, 12.0);
    final lit = widget.selected || (hover && widget.onTap != null);
    return MouseRegion(
      cursor: widget.onTap == null ? SystemMouseCursors.basic : SystemMouseCursors.click,
      onEnter: (_) => _setHover(true),
      onExit: (_) => _setHover(false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          padding: EdgeInsets.all(current ? 3 : 4),
          decoration: BoxDecoration(
            color: lit ? scheme.surfaceContainerHighest : scheme.surfaceContainerLow,
            border: current ? Border.all(color: scheme.primary, width: 2) : Border.all(color: lit ? scheme.primary : scheme.outlineVariant),
            borderRadius: BorderRadius.circular(c.radius),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              AspectRatio(
                aspectRatio: 16 / 9,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    themePicture(
                      theme: t,
                      radius: inner,
                      flip: widget.flip,
                      active: hover,
                      delaySeconds: widget.flipDelay,
                      instant: false,
                      cacheWidth: 480,
                      badges: current ? const Wrap(children: [_InUse()]) : null,
                    ),
                    if (widget.busy)
                      ClipRRect(
                        borderRadius: BorderRadius.circular(inner),
                        child: ColoredBox(color: Colors.black38, child: Center(child: SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 3, color: scheme.primary)))),
                      ),
                  ],
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
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: current || widget.selected ? FontWeight.w600 : null),
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
