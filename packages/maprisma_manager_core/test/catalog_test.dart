import 'package:maprisma_manager_core/maprisma_manager_core.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  test('16 apps with unique ids, a key path per component, known dependencies', () {
    expect(catalog, hasLength(16));
    final ids = {for (final a in catalog) a.id};
    expect(ids, hasLength(16));
    expect(ids, containsAll(['maprisma', 'control', 'launcher', 'theme', 'playground', 'bluetooth', 'home', 'hue', 'llm', 'wlan', 'narrator', 'video', 'tiling', 'icons', 'shell', 'manager']));
    for (final a in catalog) {
      for (final c in a.components) {
        expect(c.paths.where((p) => p.key), hasLength(1), reason: '${a.id}/${c.id}');
        for (final dep in c.dependsOn) {
          expect(findApp(dep.split('/').first), isNotNull, reason: dep);
        }
      }
      for (final dep in a.dependsOn) {
        expect(ids, contains(dep));
      }
    }
  });

  test('every template expands under a temp HOME; nothing points into the real home', () {
    final w = World.create();
    addTearDown(w.dispose);
    final paths = w.paths;
    for (final a in catalog) {
      final all = [
        for (final c in a.components) ...[for (final ip in c.paths) ip.path, for (final ip in c.paths) ?ip.target],
        for (final d in a.data) d.path,
        for (final r in a.runtime) r.path,
        for (final m in a.processes) m.path,
        ?a.bar.kdeAutostart,
        ?a.bar.kdeTrayExe,
      ];
      for (final t in all) {
        final e = paths.expand(t);
        expect(e.startsWith(w.dir), isTrue, reason: '${a.id}: $t -> $e');
      }
    }
  });

  test('Omarchy-shared data is marked never-delete', () {
    final shared = {
      for (final a in catalog)
        for (final d in a.data)
          if (d.sharedWithOmarchy) d.path,
    };
    expect(shared, {
      '{config}/hue-lights',
      '{config}/bluetooth-monitor',
      '{config}/ubruckhaus-wlan-monitor',
      '{config}/video-trans',
      '{data}/video-trans',
      '{homeShare}/kindle-reader',
      '{home}/.config/kindle-reader',
    });
    for (final a in catalog) {
      for (final d in a.data) {
        expect(d.neverDelete, d.sharedWithOmarchy || d.keep);
      }
    }
  });

  test('bar icons: COSMIC applet ids and KDE ids as the sources have them', () {
    expect(findApp('wlan')!.bar.cosmicApplet, 'io.github.ubruckhaus.CosmicMaprismaWlanMonitor');
    expect(findApp('wlan')!.bar.kdeId, 'maprisma-wlan-monitor');
    expect(findApp('control')!.bar.kdeId, 'maprisma-control');
    expect(findApp('narrator')!.bar.kdeId, 'com.maprisma.Narrator.Tray');
    expect(findApp('theme')!.bar.kdeId, 'maprisma-theme');
    expect(findApp('launcher')!.bar.kdeKind, KdeBarKind.widgetEntry);
    expect(findApp('manager')!.bar.kdeId, 'maprisma-manager');
    expect(findApp('manager')!.bar.cosmicApplet, 'io.github.ubruckhaus.CosmicMaprismaManager');
    for (final id in ['maprisma', 'tiling', 'icons', 'shell']) {
      expect(findApp(id)!.bar.none, isTrue, reason: id);
    }
  });

  test('Flutter environment per app: Theme a folder, Narrator/Video the executable', () {
    expect(findApp('theme')!.components.single.flutter, FlutterEnv.dir);
    expect(findApp('narrator')!.components.single.flutter, FlutterEnv.executable);
    expect(findApp('video')!.components.single.flutter, FlutterEnv.executable);
  });

  test('interpreted helpers are matched by script path, not by interpreter', () {
    final wlan = findApp('wlan')!;
    expect(wlan.processes.where((m) => m.kind == MatchKind.script).map((m) => m.path), ['{data}/maprisma-wlan-monitor/scripts/wlan-monitor.py']);
    for (final a in catalog) {
      for (final m in a.processes) {
        expect(m.path, isNot(contains('python')), reason: a.id);
      }
    }
  });

  test('Maprisma Shell: Hyprland only; its qs instance is matched by config, not every Quickshell', () {
    final bar = findApp('shell')!;
    expect(bar.desktops, {DesktopId.hyprland});
    expect(bar.inputs.single.github, 'maprisma/shell');
    final m = bar.processes.single;
    const dir = '/h/.config/quickshell/maprisma-shell';
    ProcInfo proc(String exe, List<String> argv) => ProcInfo(1, 1000, exe, argv, 1);
    quickshellConfigRoot = '/h/.config/quickshell';
    addTearDown(() => quickshellConfigRoot = null);
    expect(processMatches(m, dir, proc('/usr/bin/quickshell', ['qs', '-c', 'maprisma-shell', '-n', '-d'])), isTrue);
    expect(processMatches(m, dir, proc('/usr/bin/quickshell', ['quickshell', '--config=maprisma-shell'])), isTrue);
    expect(processMatches(m, dir, proc('/usr/bin/quickshell', ['qs', '-p', '$dir/shell.qml'])), isTrue);
    expect(processMatches(m, dir, proc('/usr/bin/quickshell', ['qs', '-c', 'caelestia', '-n', '-d'])), isFalse);
    expect(processMatches(m, dir, proc('/usr/bin/nvim', ['nvim', '-c', 'maprisma-shell'])), isFalse);
    expect(processMatches(m, dir, proc('/usr/bin/quickshell', ['qs', '-p', '/elsewhere/maprisma-shell/shell.qml'])), isFalse);
    // a temp HOME's bar folder never claims the user's running `qs -c maprisma-shell`
    expect(processMatches(m, '/tmp/x/.config/quickshell/maprisma-shell', proc('/usr/bin/quickshell', ['qs', '-c', 'maprisma-shell'])), isFalse);
  });
}
