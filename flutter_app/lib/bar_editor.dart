import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_facts.dart';
import 'app_icon.dart';
import 'backend.dart' show ServiceError;
import 'core_call.dart';
import 'theme.dart';

const _areas = ['left', 'center', 'right'];

/// The bar's three areas (left / centre / right) as rows of chips in their real order, the
/// desktop's own entries greyed but movable (`bar.get`). Drag a chip within an area or into
/// another, or into "Not in the bar"; with a chip focused: Left/Right move it, Up/Down to the area
/// above or below, Delete takes one of ours out. Writes with `bar.move` / `bar.place` / `bar.remove`, each
/// with the revision it was read at: a concurrent edit (`changed`) is shown with Reload.
class BarEditorPage extends StatefulWidget {
  const BarEditorPage({super.key, required this.core, required this.apps});
  final CoreCall core;
  final List<App> apps;
  @override
  State<BarEditorPage> createState() => BarEditorPageState();
}

class BarEditorPageState extends State<BarEditorPage> {
  Map<String, dynamic>? bar;
  String? error;
  bool stale = false, working = false;
  String? selected;
  final _keys = <String, GlobalKey>{};
  final _focus = <String, FocusNode>{};
  ({String area, int slot})? _dropAt;

  @override
  void initState() {
    super.initState();
    unawaited(load());
  }

  @override
  void dispose() {
    for (final f in _focus.values) {
      f.dispose();
    }
    super.dispose();
  }

  Future<void> load() async {
    try {
      final r = await widget.core('bar.get');
      if (!mounted) return;
      setState(() {
        bar = r;
        error = r['error'] as String?;
        stale = false;
      });
      final s = selected;
      if (s != null) WidgetsBinding.instance.addPostFrameCallback((_) => _focus[s]?.requestFocus());
    } on ServiceError catch (e) {
      if (mounted) setState(() => error = '${e.code}: ${e.reason ?? ''}');
    }
  }

  App? _app(Object? id) => widget.apps.where((a) => a['id'] == id).firstOrNull;

  List<Map> entries(String area) => (((bar?['areas'] as Map?)?[area] as List?) ?? const []).cast<Map>();
  /// Our icons that are out of the bar, of installed apps only.
  List<Map> get out => [
    for (final o in ((bar?['out'] as List?) ?? const []).cast<Map>())
      if (_app(o['app']) case final a? when installed(a)) o,
  ];

  Future<void> _write(String route, Map<String, dynamic> params) async {
    if (working) return;
    setState(() => working = true);
    try {
      await widget.core(route, {...params, 'revision': ?bar?['revision']});
    } on ServiceError catch (e) {
      if (!mounted) return;
      if (e.code == 'changed') {
        setState(() => stale = true);
        return;
      }
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('That did not work (${e.code})${e.reason == null ? '' : ': ${e.reason}'}')));
    } finally {
      if (mounted) setState(() => working = false);
    }
    if (!stale) await load();
  }

  /// [entry] to [area] before the chip at [slot] (counted with the entry itself where it is).
  Future<void> moveTo(Map entry, String area, int slot) async {
    final from = entries(area).indexWhere((e) => e['id'] == entry['id']);
    final index = from >= 0 && slot > from ? slot - 1 : slot;
    if (from >= 0 && index == from) return;
    selected = '${entry['id']}';
    await _write('bar.move', {
      if (entry['ours'] == true && entry['app'] != null) 'app': entry['app'] else 'entry': entry['id'],
      'area': area,
      'index': index,
    });
  }

  Future<void> place(Map item, String area, int slot) async {
    selected = '${item['id']}';
    await _write('bar.place', {'app': item['app'], 'area': area, 'index': slot});
  }

  Future<void> takeOut(Map entry) async {
    if (entry['ours'] != true || entry['app'] == null) return;
    selected = '${entry['id']}';
    await _write('bar.remove', {'app': entry['app']});
  }

  String _label(Map e) {
    final app = _app(e['app']);
    return app == null ? '${e['name'] ?? e['id']}' : '${app['name']}'.replaceFirst('Maprisma ', '');
  }

  Widget _chip(Map e, {required String? area}) {
    final scheme = Theme.of(context).colorScheme;
    final id = '${e['id']}';
    final ours = e['ours'] == true || area == null;
    final app = _app(e['app']);
    final icon = app?['icon'] as Map?;
    final focus = _focus.putIfAbsent(id, () => FocusNode(debugLabel: id));
    final on = selected == id;
    final hidden = e['shown'] == false;
    // The measuring key only on the chip in the bar: the drag's feedback and placeholder are copies.
    Widget box({Key? key}) => Container(
      key: key,
      margin: const EdgeInsets.symmetric(horizontal: 3, vertical: 4),
      padding: const EdgeInsets.fromLTRB(6, 4, 10, 4),
      decoration: BoxDecoration(
        color: ours ? scheme.secondaryContainer.withValues(alpha: .7) : scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(corners(context).clamp(4, 12)),
        border: Border.all(color: on ? scheme.primary : (ours ? scheme.outlineVariant : scheme.outlineVariant.withValues(alpha: .5)), width: on ? 2 : 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (app != null)
            AppIcon(icon?['file'] as String?, symbolic: icon?['symbolic'] == true, size: 20)
          else
            Icon(Icons.widgets_outlined, size: 18, color: scheme.onSurfaceVariant.withValues(alpha: .6)),
          const SizedBox(width: 6),
          Text(
            _label(e),
            style: TextStyle(fontSize: 13, color: ours ? scheme.onSurface : scheme.onSurfaceVariant.withValues(alpha: .75)),
          ),
          if (hidden) ...[
            const SizedBox(width: 4),
            Tooltip(message: 'Not running: it keeps its place but isn\'t drawn', child: Icon(Icons.visibility_off, size: 14, color: scheme.onSurfaceVariant)),
          ],
        ],
      ),
    );
    final body = box(key: _keys.putIfAbsent(id, GlobalKey.new));
    final chip = Focus(
      focusNode: focus,
      onFocusChange: (f) {
        if (f) setState(() => selected = id);
      },
      onKeyEvent: (_, event) => _chipKey(e, area, event),
      child: GestureDetector(
        onTap: () {
          setState(() => selected = id);
          focus.requestFocus();
        },
        child: Tooltip(
          message: area == null
              ? '${_label(e)}: drag it into an area (Enter: the end of the centre)'
              : ours
              ? '${_label(e)}: drag it, or use the arrow keys (Delete takes it out)'
              : '${_label(e)} (the desktop\'s own): it can be moved, not taken out',
          waitDuration: const Duration(milliseconds: 700),
          child: body,
        ),
      ),
    );
    return Draggable<Map>(
      data: {...e, 'fromArea': area},
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: Material(color: Colors.transparent, child: Opacity(opacity: .85, child: box())),
      childWhenDragging: Opacity(opacity: .3, child: box()),
      onDragEnd: (_) => setState(() => _dropAt = null),
      child: chip,
    );
  }

  KeyEventResult _chipKey(Map e, String? area, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final k = event.logicalKey;
    if (area == null) {
      if (k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.space) {
        unawaited(place(e, 'center', entries('center').length));
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    final list = entries(area);
    final i = list.indexWhere((x) => x['id'] == e['id']);
    if (k == LogicalKeyboardKey.arrowLeft && i > 0) {
      unawaited(moveTo(e, area, i - 1));
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowRight && i >= 0 && i < list.length - 1) {
      unawaited(moveTo(e, area, i + 2));
      return KeyEventResult.handled;
    }
    final a = _areas.indexOf(area);
    if (k == LogicalKeyboardKey.arrowUp && a > 0) {
      unawaited(moveTo(e, _areas[a - 1], entries(_areas[a - 1]).length));
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowDown && a < 2) {
      unawaited(moveTo(e, _areas[a + 1], 0));
      return KeyEventResult.handled;
    }
    if ((k == LogicalKeyboardKey.delete || k == LogicalKeyboardKey.backspace) && e['ours'] == true) {
      unawaited(takeOut(e));
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Where a drop at [globalX] lands in [area]: before the first chip whose middle is right of it.
  int _slot(String area, double globalX) {
    final list = entries(area);
    for (var i = 0; i < list.length; i++) {
      final box = _keys['${list[i]['id']}']?.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) continue;
      if (globalX < box.localToGlobal(Offset(box.size.width / 2, 0)).dx) return i;
    }
    return list.length;
  }

  Widget _area(String area) {
    final scheme = Theme.of(context).colorScheme;
    final list = entries(area);
    final title = switch (area) {
      'left' => 'Left',
      'center' => 'Centre',
      _ => 'Right',
    };
    Widget line() => Container(width: 3, height: 30, margin: const EdgeInsets.symmetric(horizontal: 1), color: scheme.primary);
    return DragTarget<Map>(
      onWillAcceptWithDetails: (_) => !working,
      onMove: (d) {
        final s = _slot(area, d.offset.dx);
        if (_dropAt?.area != area || _dropAt?.slot != s) setState(() => _dropAt = (area: area, slot: s));
      },
      onLeave: (_) => setState(() => _dropAt = null),
      onAcceptWithDetails: (d) {
        final s = _slot(area, d.offset.dx);
        setState(() => _dropAt = null);
        final e = d.data;
        if (e['fromArea'] == null) {
          unawaited(place(e, area, s));
        } else {
          unawaited(moveTo(e, area, s));
        }
      },
      builder: (context, candidates, _) => Container(
        key: ValueKey('area-$area'),
        margin: const EdgeInsets.symmetric(vertical: 5),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(corners(context).clamp(4, 14)),
          border: Border.all(color: candidates.isNotEmpty ? scheme.primary : scheme.outlineVariant),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: TextStyle(fontWeight: FontWeight.w700, color: scheme.onSurfaceVariant, fontSize: 12.5)),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 40),
                child: Row(
                  children: [
                    for (var i = 0; i < list.length; i++) ...[
                      if (_dropAt?.area == area && _dropAt?.slot == i) line(),
                      _chip(list[i], area: area),
                    ],
                    if (_dropAt?.area == area && _dropAt?.slot == list.length) line(),
                    if (list.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(8),
                        child: Text('Empty: drop an icon here', style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12.5)),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _outRow() {
    final scheme = Theme.of(context).colorScheme;
    return DragTarget<Map>(
      onWillAcceptWithDetails: (d) => !working && d.data['fromArea'] != null && d.data['ours'] == true,
      onAcceptWithDetails: (d) => unawaited(takeOut(d.data)),
      builder: (context, candidates, _) => Container(
        key: const ValueKey('area-out'),
        margin: const EdgeInsets.symmetric(vertical: 5),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(corners(context).clamp(4, 14)),
          border: Border.all(color: candidates.isNotEmpty ? scheme.primary : scheme.outlineVariant, style: BorderStyle.solid),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Not in the bar', style: TextStyle(fontWeight: FontWeight.w700, color: scheme.onSurfaceVariant, fontSize: 12.5)),
            Wrap(
              children: [
                for (final o in out) _chip(o, area: null),
                if (out.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text('Every installed Maprisma icon is in the bar: drop one here to take it out',
                        style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12.5)),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final b = bar;
    final kind = b?['kind'];
    Widget body;
    if (b == null) {
      body = error != null ? Center(child: Text(error!, style: TextStyle(color: scheme.error))) : const Center(child: CircularProgressIndicator());
    } else if (kind == 'none') {
      body = const Center(child: Text('This desktop has no bar the Manager can edit.'));
    } else if (kind == 'systemTray') {
      final trays = ((b['trays'] as List?) ?? const []).cast<Map>();
      body = ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('${b['note'] ?? b['error'] ?? 'Without Maprisma Icons in the panel the icons sit in the system tray: their order is Plasma\'s.'}'),
          const SizedBox(height: 12),
          for (final t in trays)
            ListTile(
              title: Text(_label({'app': t['app'], 'id': t['id']})),
              subtitle: Text('${t['startsAtLogin'] == true ? 'starts at login' : 'doesn\'t start at login'} · ${t['running'] == true ? 'running' : 'not running'}'),
            ),
        ],
      );
    } else {
      body = ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
        children: [
          if (error != null) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(error!, style: TextStyle(color: scheme.error))),
          Text(
            kind == 'cosmicPanel'
                ? 'COSMIC panel "${b['panel']}": drag the icons where you want them. The greyed ones are COSMIC\'s own.'
                : 'Maprisma Icons in the panel: drag the icons where you want them. The greyed ones are Plasma\'s own.',
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 6),
          for (final a in _areas) _area(a),
          _outRow(),
          const SizedBox(height: 6),
          Text(
            'Keys: Tab to a chip; Left and Right move it, Up and Down to the area above or below, Delete takes it out; Enter puts one from "Not in the bar" into the centre.',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ],
      );
    }
    return Scaffold(
      body: CallbackShortcuts(
        bindings: {const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.maybePop(context)},
        child: Focus(
          autofocus: true,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 10, 16, 4),
                child: Row(
                  children: [
                    TextButton.icon(
                      onPressed: () => Navigator.maybePop(context),
                      icon: const Icon(Icons.arrow_back, size: 18),
                      label: const Text('Back'),
                    ),
                    const Spacer(),
                    if (working) const Padding(padding: EdgeInsets.only(right: 8), child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))),
                    IconButton(tooltip: 'Reload', onPressed: load, icon: const Icon(Icons.refresh)),
                    Text('BAR', style: TextStyle(letterSpacing: 1.2, fontWeight: FontWeight.w700, color: scheme.onSurfaceVariant)),
                  ],
                ),
              ),
              if (stale)
                MaterialBanner(
                  key: const ValueKey('bar-changed'),
                  backgroundColor: scheme.surfaceContainerHigh,
                  leading: Icon(Icons.sync_problem, color: markColors(context).update),
                  content: const Text('The bar was changed meanwhile (by COSMIC\'s settings or another program): nothing was written. Reload to see it as it is now.'),
                  actions: [TextButton(onPressed: load, child: const Text('Reload'))],
                ),
              Expanded(child: body),
            ],
          ),
        ),
      ),
    );
  }
}
