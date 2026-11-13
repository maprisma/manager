import 'translations.dart';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'bar_cosmic.dart';
import 'bar_hypr.dart';
import 'bar_kde.dart';
import 'catalog.dart';
import 'context.dart';
import 'paths.dart';
import 'procs.dart';

/// The fixed entries of Maprisma Icons that aren't tray icons.
const kdeClock = 'clock';

// --- the wanted bar state (bar.json) -----------------------------------------------------------

/// What the user chose through the Manager, per desktop and app:
/// `{"cosmic": {"wlan": {"placed": true, "area": "center", "index": 4}}, "kde": {…}}`.
/// Kept so an install (which rewrites autostart files, restarts trays) can put it back.
final class WantedBar {
  WantedBar(this.data);

  static String file(Paths paths) => p.join(paths.managerState, 'bar.json');

  factory WantedBar.load(Paths paths) {
    try {
      final v = jsonDecode(File(file(paths)).readAsStringSync());
      if (v is Map<String, dynamic>) {
        return WantedBar({
          for (final d in v.entries)
            if (d.value is Map)
              d.key: {
                for (final a in (d.value as Map).entries)
                  if (a.value is Map && (a.value as Map)['placed'] is bool) '${a.key}': (a.value as Map).cast<String, dynamic>(),
              },
        });
      }
    } on FileSystemException {
      // none yet
    } on FormatException {
      // a broken file counts as none
    }
    return WantedBar({});
  }

  final Map<String, Map<String, Map<String, dynamic>>> data;

  Map<String, dynamic>? of(DesktopId d, String app) => data[d.name]?[app];

  void set(DesktopId d, String app, {required bool placed, Area? area, int? index, Map<String, Object>? target}) {
    (data[d.name] ??= {})[app] = {'placed': placed, if (area != null) 'area': area.name, 'index': ?index, ...?target};
  }

  void save(Paths paths) => atomicWrite(file(paths), const JsonEncoder.withIndent('  ').convert(data));
}

// --- the bar ---------------------------------------------------------------------------------

/// The bar of the current desktop: read, change, put the wanted state back.
final class Bar {
  Bar(this.ctx);
  final Ctx ctx;
  Paths get paths => ctx.paths;

  /// Waits for cosmic-panel after a write (tests replace it).
  Future<Map<String, dynamic>> Function(List<ProcInfo> before)? follow;

  /// Starts / stops a KDE tray right after it was put in / taken out (the core sets the job
  /// engine's; null: only the autostart file changes, as before).
  Future<bool> Function(String exe, List<String> args)? startTray;
  Future<void> Function(List<ProcInfo> trays)? stopTrays;

  AppEntry? appByBarId(String id) {
    for (final a in catalog) {
      if (a.bar.cosmicApplet == id || a.bar.kdeId == id || hyprBarId(a) == id) return a;
    }
    return null;
  }

  String? barId(AppEntry a) => switch (ctx.desktop) {
    DesktopId.cosmic => a.bar.cosmicApplet,
    DesktopId.kde => a.bar.kdeId,
    DesktopId.hyprland => a.desktops.contains(DesktopId.hyprland) ? hyprBarId(a) : null,
    DesktopId.other => null,
  };

  AppEntry app(Object? id) {
    if (id is! String || id.isEmpty) throw RouteError('bad_params', 'app');
    final a = findApp(id);
    if (a == null) throw RouteError('not_found', trf('no app {0}', [id]));
    if (barId(a) == null) throw RouteError('no_bar_icon', trf('{0} has no bar icon on {1}', [a.name, ctx.desktop.name]));
    return a;
  }

  // ---------- COSMIC ----------

  String cosmicInstance(Object? param) {
    final instances = cosmicInstances(paths);
    if (param == null) return instances.contains('Panel') ? 'Panel' : instances.first;
    if (param is! String || !instances.contains(param)) throw RouteError('bad_params', trf('panel (one of {0})', [instances.join(', ')]));
    return param;
  }

  CosmicPanelConfig readCosmic(String instance) {
    final c = CosmicPanelConfig.read(paths, instance);
    if (c.error != null) throw RouteError('unreadable', c.error);
    return c;
  }

  // ---------- KDE ----------

  /// The Maprisma Icons instance to use: [param] (its widget id) or the first one; null without one.
  Future<({KdeWidget? widget, List<KdeWidget> all})> kdeWidget(Object? param) async {
    final all = await readKdeWidgets(ctx.runner);
    if (param != null) {
      final w = all.where((w) => w.widget == param).firstOrNull;
      if (w == null) throw RouteError('bad_params', trf('widget (one of {0})', [all.map((w) => w.widget).join(', ')]));
      return (widget: w, all: all);
    }
    return (widget: all.firstOrNull, all: all);
  }

  /// What the widget shows: its saved zones, plus what it adds by itself (the Launcher and running
  /// Maprisma trays at the end of the left zone, the clock in the centre), hidden ids left out.
  Layout kdeShown(KdeWidget w, List<ProcInfo> procs) {
    final l = w.savedLayout;
    for (final h in w.hidden) {
      l.remove(h);
    }
    // The widget puts entries in no zone after the placed ones, sorted by their title.
    final extra = <(String, String)>[];
    void implicit(String id, String title) {
      if (l.find(id) == null && !w.hidden.contains(id)) extra.add((id, title));
    }

    implicit('maprisma-launcher', 'Maprisma Launcher');
    for (final a in catalog) {
      final id = a.bar.kdeId;
      if (id == null || a.bar.kdeTrayExe == null) continue;
      if (trayRunning(a, procs)) implicit(id, a.name);
    }
    extra.sort((x, y) => x.$2.toLowerCase().compareTo(y.$2.toLowerCase())); // ~ localeCompare
    l.areas[Area.left]!.addAll([for (final e in extra) e.$1]);
    if (l.find(kdeClock) == null && !w.hidden.contains(kdeClock)) l.areas[Area.center]!.add(kdeClock);
    return l;
  }

  bool trayRunning(AppEntry a, List<ProcInfo> procs) {
    final exe = a.bar.kdeTrayExe == null ? null : paths.expand(a.bar.kdeTrayExe!);
    if (exe == null) return false;
    final targets = {exe, ?_resolved(exe)};
    return procs.any((pr) => pr.exe != null && targets.any((t) => p.equals(pr.exe!, t)));
  }

  // ---------- Hyprland (Maprisma Bar) ----------

  /// What Maprisma Bar shows: its saved zones, plus what it adds by itself (a missing widget in
  /// its default zone, `tray` at the start of the right one; running Maprisma trays without a
  /// place of their own where `tray` is), hidden entries left out.
  /// [group] false: without the running trays that sit in the `tray` group (the layout as it is
  /// stored, in the coordinates bar.json keeps; what is written back).
  Layout hyprShown(MaprismaBarFile f, List<ProcInfo> procs, {bool group = true}) {
    final l = f.layout.copy();
    final defaults = MaprismaBarFile.defaults;
    for (final area in Area.values) {
      for (final w in (defaults[area.name] as List).cast<String>()) {
        if (l.find(w) != null || f.hidden.contains(w)) continue;
        if (w == 'tray') {
          l.areas[Area.right]!.insert(0, w);
        } else {
          l.areas[area]!.add(w);
        }
      }
    }
    final tray = l.find('tray');
    if (tray != null && group) {
      final implicit = [
        for (final a in catalog)
          if (hyprBarId(a) case final id? when id.startsWith('tray:') && a.desktops.contains(DesktopId.hyprland) && l.find(id) == null && !f.hidden.contains(id) && trayRunning(a, procs)) id,
      ];
      l.areas[tray.area]!.insertAll(tray.index + 1, implicit);
    }
    return l;
  }

  /// Back to what bar.json keeps, as Maprisma Bar's own collapse: the group's trays right after
  /// `tray` stay in the group (taken out, the bar adds them again); ones split off from it by
  /// another entry keep a place of their own. [moved] (just placed) always keeps its place;
  /// when it is `tray` itself, the whole group goes with it.
  void _collapseGroup(Layout l, List<String> grouped, {required String moved}) {
    for (final area in Area.values) {
      var inRun = false;
      for (final e in [...l.areas[area]!]) {
        if (e == 'tray') {
          inRun = true;
        } else if (grouped.contains(e) && e != moved) {
          if (inRun || moved == 'tray') l.remove(e);
        } else {
          inRun = false;
        }
      }
    }
  }

  MaprismaBarFile readHypr() {
    final f = MaprismaBarFile.read(paths);
    if (f.error != null) throw RouteError('unreadable', f.error);
    return f;
  }

  /// Whether Maprisma Bar draws an entry now: its widgets always, a tray icon while it runs.
  bool _hyprShownNow(String id, List<ProcInfo> procs) {
    if (!id.startsWith('tray:')) return true;
    final a = appByBarId(id);
    return a == null || trayRunning(a, procs);
  }

  // ---------- routes ----------

  Future<Map<String, dynamic>> get(Map<String, dynamic> params) async {
    final procs = ctx.processes();
    switch (ctx.desktop) {
      case DesktopId.cosmic:
        final instance = cosmicInstance(params['panel']);
        final c = CosmicPanelConfig.read(paths, instance);
        final base = {
          'desktop': 'cosmic',
          'kind': 'cosmicPanel',
          'panel': instance,
          'panels': cosmicInstances(paths),
          'files': {'plugins_wings': c.wings.source, 'plugins_center': c.center.source},
        };
        if (c.error != null) return {...base, 'error': c.error};
        final l = c.layout;
        return {...base, 'revision': c.revision, 'areas': _areas(l, procs), 'out': _out(l)};
      case DesktopId.kde:
        final ({KdeWidget? widget, List<KdeWidget> all}) found;
        try {
          found = await kdeWidget(params['widget']);
        } on RouteError catch (e) {
          if (e.code != 'unavailable') rethrow;
          return {'desktop': 'kde', 'kind': 'systemTray', 'error': e.message, 'trays': _trays(procs)};
        }
        final w = found.widget;
        if (w == null) {
          return {'desktop': 'kde', 'kind': 'systemTray', 'note': tr('Maprisma Icons is not in a panel: icons go to the system tray'), 'trays': _trays(procs)};
        }
        final l = kdeShown(w, procs);
        return {
          'desktop': 'kde',
          'kind': 'maprismaIcons',
          'widget': w.widget,
          'widgets': [for (final x in found.all) x.toJson()],
          'revision': w.revision,
          'hidden': w.hidden,
          'areas': _areas(l, procs),
          'out': _out(l),
          'trays': _trays(procs),
        };
      case DesktopId.hyprland:
        final f = MaprismaBarFile.read(paths);
        final base = {'desktop': 'hyprland', 'kind': 'maprismaBar', 'files': {'bar': f.path}};
        if (f.error != null) return {...base, 'error': f.error};
        final l = hyprShown(f, procs);
        return {...base, 'revision': f.revision, 'hidden': f.hidden, 'areas': _areas(l, procs), 'out': _out(l)};
      case DesktopId.other:
        return {'desktop': 'other', 'kind': 'none', 'note': tr('no bar icons on this desktop')};
    }
  }

  /// Puts an app's icon into [area] (at [index], else the area's default place).
  Future<Map<String, dynamic>> place(Map<String, dynamic> params) async {
    final a = app(params['app']);
    final area = parseArea(params['area']);
    if (area == null) throw RouteError('bad_params', 'area (left, center, right)');
    final index = _index(params['index'], optional: true);
    return _change(params, a, area: area, index: index, placed: true);
  }

  /// Moves an app's icon or any entry (a foreign one too) to [area] at [index].
  Future<Map<String, dynamic>> move(Map<String, dynamic> params) async {
    final area = parseArea(params['area']);
    if (area == null) throw RouteError('bad_params', 'area (left, center, right)');
    final index = _index(params['index'], optional: false);
    if (params['app'] != null) return _change(params, app(params['app']), area: area, index: index, placed: true);
    final entry = params['entry'];
    if (entry is! String || entry.isEmpty) throw RouteError('bad_params', tr('app or entry'));
    final ours = appByBarId(entry);
    if (ours != null) return _change(params, ours, area: area, index: index, placed: true);
    return _change(params, null, entry: entry, area: area, index: index, placed: true);
  }

  /// [remember] false: bar.json keeps the user's choice (a remove job takes the icon out, the
  /// choice comes back with a reinstall); [autostart] false: the tray's autostart file is left
  /// alone (the remove job deletes it).
  Future<Map<String, dynamic>> remove(Map<String, dynamic> params, {bool remember = true, bool autostart = true}) async {
    final a = app(params['app']);
    return _change(params, a, placed: false, remember: remember, touchAutostart: autostart);
  }

  int? _index(Object? v, {required bool optional}) {
    if (v == null && optional) return null;
    if (v is! int || v < 0) throw RouteError('bad_params', 'index');
    return v;
  }

  /// One change, start to end (read, write, bar.json) under the state lock.
  Future<Map<String, dynamic>> _change(Map<String, dynamic> params, AppEntry? a,
          {String? entry, Area? area, int? index, required bool placed, bool remember = true, bool touchAutostart = true}) =>
      withStateLock(paths, () => _changeLocked(params, a,
          entry: entry, area: area, index: index, placed: placed, remember: remember, touchAutostart: touchAutostart));

  Future<Map<String, dynamic>> _changeLocked(
    Map<String, dynamic> params,
    AppEntry? a, {
    String? entry,
    Area? area,
    int? index,
    required bool placed,
    bool remember = true,
    bool touchAutostart = true,
  }) async {
    final id = entry ?? barId(a!)!;
    final revision = params['revision'];
    if (revision != null && revision is! String) throw RouteError('bad_params', 'revision');
    switch (ctx.desktop) {
      case DesktopId.cosmic:
        final shown = cosmicInstance(params['panel']); // the one bar.get showed (its revision)
        final instances = params['panel'] == null && !placed ? cosmicInstances(paths) : [shown];
        final results = <Map<String, dynamic>>[];
        final before = ctx.processes();
        var wroteAny = false;
        for (final instance in instances) {
          final c = readCosmic(instance);
          if (revision != null && instance == shown && c.revision != revision) {
            throw RouteError('changed', tr('the panel config changed since it was read'));
          }
          final l = c.layout;
          if (placed) {
            final at = l.find(id);
            if (!(at != null && at.area == area && index == null)) {
              l.put(id, area!, index ?? cosmicDefaultIndex(l, area, id));
            }
          } else {
            l.remove(id);
          }
          final w = await writeCosmic(paths, c, l);
          wroteAny |= w.written.isNotEmpty;
          final at = l.find(id);
          results.add({'panel': instance, 'written': w.written, 'backup': ?w.backup, 'area': ?at?.area.name, 'index': ?at?.index});
        }
        if (a != null && remember) {
          _remember(a,
              placed: placed,
              at: placed ? (area: Area.values.byName(results.first['area'] as String), index: results.first['index'] as int) : null,
              target: params['panel'] == null ? null : {'panel': shown});
        }
        final follow = wroteAny ? await (this.follow ?? (b) => followPanel(ctx.processes, b, kill: paths.proc == '/proc' ? null : (_) => false))(before) : null;
        return {'id': id, 'app': ?a?.id, 'placed': placed, 'panels': results, 'reload': ?follow};
      case DesktopId.kde:
        final procs = ctx.processes();
        ({KdeWidget? widget, List<KdeWidget> all}) found;
        String? noScripting;
        try {
          found = await kdeWidget(params['widget']);
        } on RouteError catch (e) {
          // Without qdbus6 Plasma can't be scripted (bar.get shows the system tray then): an
          // app's own tray can still be put in or out; zone orders stay refused.
          if (e.code != 'unavailable' || a == null || ctx.runner.which('qdbus6') != null) rethrow;
          found = (widget: null, all: const []);
          noScripting = e.message;
        }
        final w = found.widget;
        final result = <String, dynamic>{'id': id, 'app': ?a?.id, 'placed': placed};
        final autostart = a?.bar.kdeAutostart == null || !touchAutostart ? null : paths.expand(a!.bar.kdeAutostart!);
        // A broken autostart file stops the change before anything is written.
        if (autostart != null && File(autostart).existsSync()) checkDesktopFile(autostart);
        if (w != null) {
          if (revision != null && w.revision != revision) throw RouteError('changed', tr('Maprisma Icons\' zones changed since they were read'));
          final l = kdeShown(w, procs);
          final hidden = [...w.hidden];
          if (placed) {
            hidden.remove(id);
            final at = l.find(id);
            if (!(at != null && at.area == area && index == null)) {
              final list = [...l.areas[area!]!]..remove(id);
              l.put(id, area, index ?? (area == Area.right ? 0 : list.length));
            }
          } else {
            l.remove(id);
            if (!hidden.contains(id)) hidden.add(id);
          }
          final back = await writeKdeWidget(ctx.runner, w, l, hidden);
          final at = back.savedLayout.find(id);
          result.addAll({'widget': back.widget, 'area': ?at?.area.name, 'index': ?at?.index, 'hidden': back.hidden});
        } else if (a == null) {
          throw RouteError('unavailable', tr('without Maprisma Icons only Maprisma icons can be put in or out (the system tray orders itself)'));
        } else {
          result['note'] = noScripting ?? tr('Maprisma Icons is not in a panel: the icon goes to the system tray');
        }
        if (autostart != null) {
          result['autostart'] = File(autostart).existsSync() ? (setDesktopHidden(paths, autostart, !placed) ? 'changed' : 'unchanged') : 'missing';
          // The change shows now, not only after the next login: a tray put in starts; one taken
          // out of the system tray stops (Maprisma Icons hides it by itself, it keeps running).
          if (a != null && a.bar.kdeTrayExe != null) {
            final exe = paths.expand(a.bar.kdeTrayExe!);
            final targets = {exe, ?_resolved(exe)};
            final trays = [for (final pr in procs) if (pr.exe != null && targets.any((t) => p.equals(pr.exe!, t))) pr];
            if (placed && trays.isEmpty && startTray != null) {
              result['trayStarted'] = await startTray!(exe, a.bar.kdeTrayArgs);
            } else if (!placed && w == null && trays.isNotEmpty && stopTrays != null) {
              await stopTrays!(trays);
              result['trayStopped'] = trays.length;
            }
          }
        }
        if (a != null && remember) {
          final idx = result['index'];
          _remember(a,
              placed: placed,
              at: placed && result['area'] != null ? (area: Area.values.byName(result['area'] as String), index: idx as int) : null,
              target: params['widget'] == null || w == null ? null : {'widget': w.widget});
        }
        return result;
      case DesktopId.hyprland:
        final f = readHypr();
        if (revision != null && f.revision != revision) throw RouteError('changed', tr('Maprisma Bar\'s layout changed since it was read'));
        final autostart = a?.bar.kdeAutostart == null || !touchAutostart ? null : paths.expand(a!.bar.kdeAutostart!);
        if (autostart != null && File(autostart).existsSync()) checkDesktopFile(autostart);
        if (!placed && hyprBarWidgets.contains(id) && a == null) {
          throw RouteError('unavailable', tr('the bar\'s own entries can be moved, not taken out'));
        }
        final procs = ctx.processes();
        // indices come from bar.get (the shown layout, the group's trays included); what is
        // written keeps the group's trays in the group, except the one placed now
        final l = hyprShown(f, procs);
        final stored = hyprShown(f, procs, group: false);
        final grouped = [for (final a in Area.values) ...l.areas[a]!.where((e) => stored.find(e) == null)];
        final hidden = [...f.hidden];
        if (placed) {
          hidden.remove(id);
          final at = l.find(id);
          if (!(at != null && at.area == area && index == null)) {
            final list = [...l.areas[area!]!]..remove(id);
            var i = index ?? (area == Area.right ? 0 : list.length);
            // as Maprisma Bar: before the group's first icon means before the group itself
            if (i > 0 && i < list.length && grouped.contains(list[i]) && list[i - 1] == 'tray') i -= 1;
            l.put(id, area, i);
          }
        } else {
          l.remove(id);
          if (!hidden.contains(id)) hidden.add(id);
        }
        _collapseGroup(l, grouped, moved: id);
        final written = f.write(l, hidden);
        final at = l.find(id);
        final result = <String, dynamic>{'id': id, 'app': ?a?.id, 'placed': placed, 'written': written, 'area': ?at?.area.name, 'index': ?at?.index, 'hidden': hidden};
        if (autostart != null) {
          result['autostart'] = File(autostart).existsSync() ? (setDesktopHidden(paths, autostart, !placed) ? 'changed' : 'unchanged') : 'missing';
        }
        if (a != null && remember) {
          _remember(a, placed: placed, at: placed && at != null ? (area: at.area, index: at.index) : null);
        }
        return result;
      case DesktopId.other:
        throw RouteError('unavailable', tr('no bar icons on this desktop'));
    }
  }

  /// [target]: the panel/widget the user picked (none: the default one; for a removal: all).
  void _remember(AppEntry a, {required bool placed, ({Area area, int index})? at, Map<String, Object>? target}) {
    final wanted = WantedBar.load(paths);
    wanted.set(ctx.desktop, a.id, placed: placed, area: at?.area, index: at?.index, target: target);
    wanted.save(paths);
  }

  /// Puts every app's icon where bar.json wants it on this desktop (after an install), in one write
  /// per panel and one panel follow-up. Apps whose icon is already in the wanted area stay.
  Future<Map<String, dynamic>> applyWanted() => withStateLock(paths, _applyLocked);

  Future<Map<String, dynamic>> _applyLocked() async {
    final wanted = WantedBar.load(paths).data[ctx.desktop.name] ?? const {};
    final apps = [
      for (final e in wanted.entries)
        if (findApp(e.key) case final a? when barId(a) != null) (a, e.value),
    ];
    if (apps.isEmpty) return {'changed': <String>[]};
    final changed = <String>[];
    switch (ctx.desktop) {
      case DesktopId.cosmic:
        final before = ctx.processes();
        var wroteAny = false;
        final instances = cosmicInstances(paths);
        final main = cosmicInstance(null);
        for (final instance in instances) {
          final c = readCosmic(instance);
          final l = c.layout;
          for (final (a, want) in apps) {
            final id = barId(a)!;
            final at = l.find(id);
            // The panel the user picked (gone: the main one); a removal without one: every panel.
            final target = instances.contains(want['panel']) ? want['panel'] as String : null;
            if (want['placed'] == true) {
              if (instance != (target ?? main)) continue;
              final area = parseArea(want['area']) ?? Area.right;
              if (at != null && at.area == area) continue;
              final i = want['index'];
              l.put(id, area, i is int ? i : cosmicDefaultIndex(l, area, id));
              changed.add(a.id);
            } else if (at != null && (target == null || target == instance)) {
              l.remove(id);
              changed.add(a.id);
            }
          }
          final w = await writeCosmic(paths, c, l);
          wroteAny |= w.written.isNotEmpty;
        }
        final follow = wroteAny ? await (this.follow ?? (b) => followPanel(ctx.processes, b, kill: paths.proc == '/proc' ? null : (_) => false))(before) : null;
        return {'changed': changed, 'reload': ?follow};
      case DesktopId.kde:
        final procs = ctx.processes();
        List<KdeWidget> all = const [];
        try {
          all = await readKdeWidgets(ctx.runner);
        } on RouteError catch (e) {
          if (e.code != 'unavailable') rethrow;
        }
        // Per widget the apps the user put there (no or a gone widget: the first one).
        for (final w in all) {
          final mine = [
            for (final (a, want) in apps)
              if ((all.any((x) => x.widget == want['widget']) ? want['widget'] : all.first.widget) == w.widget) (a, want),
          ];
          if (mine.isEmpty) continue;
          final before = changed.length;
          final l = kdeShown(w, procs);
          final hidden = [...w.hidden];
          for (final (a, want) in mine) {
            final id = barId(a)!;
            final at = l.find(id);
            if (want['placed'] == true) {
              final area = parseArea(want['area']) ?? Area.left;
              final wasHidden = hidden.remove(id);
              if (at != null && at.area == area && !wasHidden) continue;
              final i = want['index'];
              l.put(id, area, i is int ? i : l.areas[area]!.length);
              changed.add(a.id);
            } else if (at != null || !hidden.contains(id)) {
              l.remove(id);
              if (!hidden.contains(id)) hidden.add(id);
              changed.add(a.id);
            }
          }
          if (changed.length > before) await writeKdeWidget(ctx.runner, w, l, hidden);
        }
        for (final (a, want) in apps) {
          final f = a.bar.kdeAutostart;
          if (f == null || !File(paths.expand(f)).existsSync()) continue;
          if (setDesktopHidden(paths, paths.expand(f), want['placed'] != true) && !changed.contains(a.id)) changed.add(a.id);
        }
        return {'changed': changed};
      case DesktopId.hyprland:
        final f = readHypr();
        final l = hyprShown(f, ctx.processes(), group: false);
        final hidden = [...f.hidden];
        for (final (a, want) in apps) {
          final id = barId(a)!;
          final at = l.find(id);
          if (want['placed'] == true && want['group'] == true) {
            // in the bar's tray group: shown again where the group is, no place of its own
            final wasHidden = hidden.remove(id);
            if (l.remove(id) || wasHidden) changed.add(a.id);
            continue;
          }
          if (want['placed'] == true) {
            final area = parseArea(want['area']) ?? Area.right;
            final wasHidden = hidden.remove(id);
            if (at != null && at.area == area && !wasHidden) continue;
            final i = want['index'];
            l.put(id, area, i is int ? i : (area == Area.right ? 0 : l.areas[area]!.length));
            changed.add(a.id);
          } else if (at != null || !hidden.contains(id)) {
            l.remove(id);
            if (!hidden.contains(id)) hidden.add(id);
            changed.add(a.id);
          }
        }
        if (changed.isNotEmpty) f.write(l, hidden);
        for (final (a, want) in apps) {
          final file = a.bar.kdeAutostart;
          if (file == null || !File(paths.expand(file)).existsSync()) continue;
          if (setDesktopHidden(paths, paths.expand(file), want['placed'] != true) && !changed.contains(a.id)) changed.add(a.id);
        }
        return {'changed': changed};
      case DesktopId.other:
        return {'changed': changed};
    }
  }

  // ---------- describing entries ----------

  /// Whether Maprisma Icons shows a saved entry now: the clock and the Launcher always, a tray
  /// while it runs (a stopped tray keeps its place in the zone but isn't drawn).
  bool _kdeShownNow(String id, List<ProcInfo> procs) {
    if (id == kdeClock || id == 'maprisma-launcher') return true;
    final a = appByBarId(id);
    return a != null && trayRunning(a, procs);
  }

  Map<String, List<Map<String, dynamic>>> _areas(Layout l, List<ProcInfo> procs) => {
    for (final a in Area.values)
      a.name: [
        for (final id in l.areas[a]!)
          {
            ...describeEntry(id, procs),
            if (ctx.desktop == DesktopId.kde) 'shown': _kdeShownNow(id, procs),
            if (ctx.desktop == DesktopId.hyprland) 'shown': _hyprShownNow(id, procs),
          },
      ],
  };

  /// Our apps with a bar icon here that are not in the bar.
  List<Map<String, dynamic>> _out(Layout l) => [
    for (final a in catalog)
      if (barId(a) case final id? when l.find(id) == null && a.desktops.contains(ctx.desktop))
        {'id': id, 'app': a.id, 'name': a.name, 'iconName': _iconName(a)},
  ];

  List<Map<String, dynamic>> _trays(List<ProcInfo> procs) => [
    for (final a in catalog)
      if (a.bar.kdeAutostart != null)
        {
          'app': a.id,
          'id': a.bar.kdeId,
          'startsAtLogin': File(paths.expand(a.bar.kdeAutostart!)).existsSync() && !desktopHidden(paths.expand(a.bar.kdeAutostart!)),
          'running': trayRunning(a, procs),
        },
  ];

  String? _iconName(AppEntry a) => traysDesktop(ctx.desktop) ? (a.bar.kdeIconName ?? a.bar.iconName) : a.bar.iconName;

  /// An entry for the editor: ours with app id/name/icon, a foreign one with what its desktop
  /// file says (COSMIC applets) or nothing.
  Map<String, dynamic> describeEntry(String id, List<ProcInfo> procs) {
    final a = appByBarId(id);
    if (a != null) return {'id': id, 'ours': true, 'app': a.id, 'name': a.name, 'iconName': _iconName(a)};
    if (ctx.desktop == DesktopId.kde && id == kdeClock) return {'id': id, 'ours': false, 'name': 'Clock'};
    if (ctx.desktop == DesktopId.hyprland) {
      final name = switch (id) {
        'workspaces' => 'Workspaces',
        'clock' => 'Clock',
        'bluetooth' => 'Bluetooth',
        'network' => 'Network',
        'audio' => 'Audio',
        'power' => 'Power',
        'tray' => tr('Other tray icons'),
        'launcher' => 'Launcher',
        _ => id.startsWith('tray:') ? id.substring(5) : id,
      };
      return {'id': id, 'ours': false, 'name': name};
    }
    final d = _desktopFile(id);
    return {'id': id, 'ours': false, 'name': ?d?.name, 'iconName': ?d?.icon};
  }

  final Map<String, ({String? name, String? icon})?> _desktopCache = {};

  ({String? name, String? icon})? _desktopFile(String id) => _desktopCache.putIfAbsent(id, () {
    for (final dir in [paths.apps, paths.sys('/usr/share/applications')]) {
      try {
        String? name, icon;
        var inEntry = false;
        for (final line in File(p.join(dir, '$id.desktop')).readAsLinesSync()) {
          final t = line.trim();
          if (t.startsWith('[')) inEntry = t == '[Desktop Entry]';
          if (!inEntry) continue;
          if (t.startsWith('Name=')) name ??= t.substring(5);
          if (t.startsWith('Icon=')) icon ??= t.substring(5);
        }
        return (name: name, icon: icon);
      } on FileSystemException {
        continue;
      }
    }
    return null;
  });
}

String? _resolved(String path) {
  try {
    final r = File(path).resolveSymbolicLinksSync();
    return r == path ? null : r;
  } on FileSystemException {
    return null;
  }
}
