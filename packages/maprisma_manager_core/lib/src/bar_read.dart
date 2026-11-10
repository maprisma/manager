import 'translations.dart';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'bar.dart';
import 'bar_cosmic.dart';
import 'bar_kde.dart';
import 'catalog_model.dart';
import 'context.dart';
import 'procs.dart';

export 'ron.dart' show ronStringLists;

/// What the status needs of the bar, read once per apps.list.
final class BarSnapshot {
  BarSnapshot._(this.ctx, this.bar, this.procs, this.panels, this.widget, this.widgetError, this.wanted);

  static Future<BarSnapshot> read(Ctx ctx, List<ProcInfo> procs) async {
    final bar = Bar(ctx);
    final panels = <String, CosmicPanelConfig>{};
    KdeWidget? widget;
    String? widgetError;
    switch (ctx.desktop) {
      case DesktopId.cosmic:
        for (final i in cosmicInstances(ctx.paths)) {
          panels[i] = CosmicPanelConfig.read(ctx.paths, i);
        }
      case DesktopId.kde:
        try {
          widget = (await bar.kdeWidget(null)).widget;
          if (widget == null) widgetError = tr('Maprisma Icons is not in a panel');
        } on RouteError catch (e) {
          widgetError = e.message ?? e.code;
        }
      case DesktopId.other:
        break;
    }
    return BarSnapshot._(ctx, bar, procs, panels, widget, widgetError, WantedBar.load(ctx.paths));
  }

  final Ctx ctx;
  final Bar bar;
  final List<ProcInfo> procs;
  final Map<String, CosmicPanelConfig> panels;
  final KdeWidget? widget;
  final String? widgetError;
  final WantedBar wanted;

  /// The bar state of one app: in/out/unknown, where, and separately whether it starts at login,
  /// runs and is visible (null where that can't be told).
  Map<String, dynamic> stateOf(AppEntry app) {
    final b = app.bar;
    final paths = ctx.paths;
    final wanted = this.wanted.of(ctx.desktop, app.id);
    if (b.none) return {'has': false, 'state': 'none'};
    switch (ctx.desktop) {
      case DesktopId.cosmic:
        final id = b.cosmicApplet;
        if (id == null) return {'has': false, 'state': 'none'};
        final broken = panels.values.where((c) => c.error != null).firstOrNull;
        if (panels.isEmpty || broken != null) {
          // An unreadable panel config is not "out of the bar".
          return {'has': true, 'id': id, 'state': 'unknown', 'error': broken?.error ?? tr('no panel'), 'iconName': b.iconName, 'wanted': ?wanted};
        }
        String? panel, zone;
        for (final e in panels.entries) {
          final at = e.value.layout.find(id);
          if (at != null) {
            panel = e.key;
            zone = at.area.name;
            break;
          }
        }
        final running = _appletRunning(app);
        return {
          'has': true,
          'id': id,
          'state': zone == null ? 'out' : 'in',
          'zone': zone,
          'panel': ?panel,
          // cosmic-panel starts its applets: in the panel = starts at login.
          'startsAtLogin': zone != null,
          'running': running,
          'visible': zone != null && running,
          'iconName': b.iconName,
          'wanted': ?wanted,
        };
      case DesktopId.kde:
        final id = b.kdeId;
        if (id == null) return {'has': false, 'state': 'none'};
        final w = widget;
        final shown = w == null ? null : bar.kdeShown(w, procs);
        final zone = shown?.find(id)?.area.name;
        final hiddenInWidget = w != null && w.hidden.contains(id);
        if (b.kdeKind == KdeBarKind.widgetEntry) {
          return {
            'has': true,
            'id': id,
            'kind': 'widgetEntry',
            'state': w == null ? 'unknown' : (zone == null ? 'out' : 'in'),
            'zone': ?zone,
            'visible': w == null ? null : zone != null,
            if (w == null) 'error': widgetError,
            'iconName': b.kdeIconName ?? b.iconName,
            'wanted': ?wanted,
          };
        }
        final autostart = b.kdeAutostart == null ? null : paths.expand(b.kdeAutostart!);
        final atLogin = autostart != null && File(autostart).existsSync() && !desktopHidden(autostart);
        final running = bar.trayRunning(app, procs);
        return {
          'has': true,
          'id': id,
          'kind': 'tray',
          'state': (atLogin || running) && !hiddenInWidget ? 'in' : 'out',
          'zone': ?zone,
          'startsAtLogin': atLogin,
          'running': running,
          // In Maprisma Icons: shown when running and not hidden. In the system tray it may sit in
          // the overflow: unknown.
          'visible': w == null ? (running ? null : false) : running && zone != null,
          if (w == null) 'where': 'systemTray',
          'iconName': b.kdeIconName ?? b.iconName,
          'wanted': ?wanted,
        };
      case DesktopId.other:
        return {'has': false, 'state': 'none', 'reason': tr('no bar icons on this desktop')};
    }
  }

  /// The applet runs as a child of a cosmic-panel.
  bool _appletRunning(AppEntry app) {
    final t = app.bar.cosmicAppletExe;
    if (t == null) return false;
    final exe = ctx.paths.expand(t);
    String? resolved;
    try {
      resolved = File(exe).resolveSymbolicLinksSync();
    } on FileSystemException {
      resolved = null;
    }
    final panels = {for (final pr in cosmicPanels(procs)) pr.pid};
    return procs.any((pr) => panels.contains(pr.ppid) && pr.exe != null && (p.equals(pr.exe!, exe) || (resolved != null && p.equals(pr.exe!, resolved))));
  }
}
