import 'dart:convert';
import 'dart:io';

import 'package:maprisma_manager_core/maprisma_manager_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late World w;
  setUp(() => w = World.create());
  tearDown(() => w.dispose());

  CoreService hypr() => w.core(desktop: 'Hyprland');
  String barFile() => p.join(w.home, '.config/maprisma-shell/bar.json');
  Map<String, dynamic> stored() => jsonDecode(File(barFile()).readAsStringSync()) as Map<String, dynamic>;
  void bar(Map<String, dynamic> v) => w.writeFile(barFile(), jsonEncode(v));
  String autostart(String app) => w.paths.expand(findApp(app)!.bar.kdeAutostart!);
  List<String> ids(Map<String, dynamic> b, String area) => [for (final e in (b['areas'][area] as List)) e['id'] as String];

  test('Hyprland is its own desktop; bar ids: the Launcher is the bar widget, trays are tray:<SNI id>', () {
    expect(detectDesktop({'XDG_CURRENT_DESKTOP': 'Hyprland'}), DesktopId.hyprland);
    expect(hyprBarId(findApp('launcher')!), 'launcher');
    expect(hyprBarId(findApp('llm')!), 'tray:maprisma-llm-monitor');
    expect(hyprBarId(findApp('narrator')!), 'tray:com.maprisma.Narrator.Tray');
    expect(hyprBarId(findApp('maprisma')!), isNull);
  });

  test('bar.get: the zones as the bar shows them (missing widgets back, running trays at "tray", hidden left out)', () async {
    bar({'version': 1, 'background': 'glassy', 'left': ['workspaces'], 'center': ['clock', 'tray:maprisma-wlan-monitor'], 'right': ['tray', 'power'], 'hidden': ['tray:maprisma-hue-lights']});
    w.install('llm');
    w.install('hue');
    w.process(600, exe: p.join(w.paths.bin, 'maprisma-llm-monitor-tray'));
    w.process(601, exe: p.join(w.paths.bin, 'maprisma-hue-lights-tray'));
    final r = await hypr().call('bar.get');
    expect(r['kind'], 'maprismaBar');
    expect(ids(r, 'left'), ['workspaces', 'launcher']);
    expect(ids(r, 'center'), ['clock', 'tray:maprisma-wlan-monitor']);
    expect(ids(r, 'right'), ['tray', 'tray:maprisma-llm-monitor', 'power', 'bluetooth', 'network', 'audio']);
    expect(r['hidden'], ['tray:maprisma-hue-lights']);
    expect((r['out'] as List).map((e) => e['app']), contains('hue'));
    final wlan = (r['areas']['center'] as List)[1] as Map;
    expect(wlan, allOf(containsPair('ours', true), containsPair('app', 'wlan'), containsPair('shown', false)));
  });

  test('place / move / take out: zones and hidden in bar.json, other keys kept, autostart flag', () async {
    bar({'version': 1, 'background': 'glassy', 'left': ['launcher', 'workspaces'], 'center': ['clock'], 'right': ['tray', 'power']});
    w.install('wlan');
    w.writeFile(autostart('wlan'), '[Desktop Entry]\nExec=x\n');
    final core = hypr();
    var r = await core.call('bar.place', {'app': 'wlan', 'area': 'center'});
    expect(r['written'], isTrue);
    expect(stored()['center'], ['clock', 'tray:maprisma-wlan-monitor']);
    expect(stored()['background'], 'glassy');
    r = await core.call('bar.move', {'app': 'wlan', 'area': 'right', 'index': 0});
    expect(stored()['right'].first, 'tray:maprisma-wlan-monitor');
    // taken out: hidden, no zone, Hidden=true in its autostart file
    r = await core.call('bar.remove', {'app': 'wlan'});
    expect(r['autostart'], 'changed');
    expect(stored()['hidden'], ['tray:maprisma-wlan-monitor']);
    expect([...stored()['left'], ...stored()['center'], ...stored()['right']], isNot(contains('tray:maprisma-wlan-monitor')));
    expect(File(autostart('wlan')).readAsStringSync(), contains('Hidden=true'));
    expect(appOf(await core.call('apps.list'), 'wlan')['bar']['state'], 'out');
    // the Launcher (the bar's widget) can be taken out and put back
    await core.call('bar.remove', {'app': 'launcher'});
    expect(stored()['hidden'], ['tray:maprisma-wlan-monitor', 'launcher']);
    await core.call('bar.place', {'app': 'launcher', 'area': 'left'});
    expect(stored()['hidden'], ['tray:maprisma-wlan-monitor']);
    // back in: out of hidden, autostart shown again
    await core.call('bar.place', {'app': 'wlan', 'area': 'left'});
    expect(stored().containsKey('hidden'), isFalse);
    expect(File(autostart('wlan')).readAsStringSync(), isNot(contains('Hidden')));
    // the bar's own entries move but can't be taken out
    await core.call('bar.move', {'entry': 'clock', 'area': 'right', 'index': 0});
    expect(stored()['right'].first, 'clock');
    await expectLater(core.call('bar.remove', {'entry': 'clock'}), throwsA(isA<RouteError>()));
  });

  test('trays in the bar\'s tray group stay in the group when something else moves', () async {
    bar({'version': 1, 'left': ['launcher'], 'center': ['clock'], 'right': ['tray', 'power']});
    w.install('llm');
    w.install('wlan');
    for (final a in ['llm', 'wlan']) {
      w.writeFile(autostart(a), '[Desktop Entry]\nExec=x\n');
    }
    w.process(600, exe: p.join(w.paths.bin, 'maprisma-llm-monitor-tray'));
    w.process(601, exe: p.join(w.paths.bin, 'maprisma-wlan-monitor-tray'));
    final core = hypr();
    expect(ids(await core.call('bar.get'), 'right'), ['tray', 'tray:maprisma-llm-monitor', 'tray:maprisma-wlan-monitor', 'power', 'bluetooth', 'network', 'audio']);
    await core.call('bar.move', {'entry': 'clock', 'area': 'left', 'index': 0});
    expect(stored()['right'], ['tray', 'power', 'bluetooth', 'network', 'audio']);
    // placing one of them gives only that one a place of its own (shown index 2 = after llm)
    await core.call('bar.move', {'app': 'wlan', 'area': 'right', 'index': 2});
    expect(stored()['right'], ['tray', 'tray:maprisma-wlan-monitor', 'power', 'bluetooth', 'network', 'audio']);
    final st = appOf(await core.call('apps.list'), 'llm')['bar'];
    expect(st, allOf(containsPair('state', 'in'), containsPair('group', true), containsPair('zone', 'right')));
  });

  test('a drop inside the tray group splits off only the trays after it, as the bar does', () async {
    bar({'version': 1, 'left': ['launcher'], 'center': ['clock'], 'right': ['tray', 'power']});
    w.install('llm');
    w.install('wlan');
    for (final a in ['llm', 'wlan']) {
      w.writeFile(autostart(a), '[Desktop Entry]\nExec=x\n');
    }
    w.process(600, exe: p.join(w.paths.bin, 'maprisma-llm-monitor-tray'));
    w.process(601, exe: p.join(w.paths.bin, 'maprisma-wlan-monitor-tray'));
    final core = hypr();
    // shown: tray, llm, wlan, power, ...: the clock between llm and wlan
    await core.call('bar.move', {'entry': 'clock', 'area': 'right', 'index': 2});
    expect(stored()['right'], ['tray', 'clock', 'tray:maprisma-wlan-monitor', 'power', 'bluetooth', 'network', 'audio']);
    expect(ids(await core.call('bar.get'), 'right').take(4), ['tray', 'tray:maprisma-llm-monitor', 'clock', 'tray:maprisma-wlan-monitor']);
    // before the group's first icon means before the group itself
    await core.call('bar.move', {'entry': 'power', 'area': 'right', 'index': 1});
    expect(stored()['right'].take(2), ['power', 'tray']);
  });

  test('restoring a grouped tray takes away a place it was given meanwhile', () async {
    bar({'version': 1, 'left': ['launcher'], 'center': ['tray', 'clock'], 'right': ['tray:maprisma-llm-monitor', 'power']});
    final env = w.env(desktop: 'Hyprland');
    final b = Bar(Ctx(paths: Paths.fromEnvironment(env), environment: env));
    WantedBar({})
      ..set(DesktopId.hyprland, 'llm', placed: true, area: Area.center, target: {'group': true})
      ..save(w.paths);
    w.install('llm');
    w.writeFile(autostart('llm'), '[Desktop Entry]\nExec=x\n');
    final r = await b.applyWanted();
    expect(r['changed'], contains('llm'));
    expect(stored()['right'], isNot(contains('tray:maprisma-llm-monitor')));
  });

  test('a reinstall puts a grouped tray back into the group, a placed one at its stored place', () async {
    bar({'version': 1, 'left': ['launcher'], 'center': ['tray', 'clock'], 'right': ['power']});
    final env = w.env(desktop: 'Hyprland');
    final b = Bar(Ctx(paths: Paths.fromEnvironment(env), environment: env));
    final wanted = WantedBar({})
      ..set(DesktopId.hyprland, 'llm', placed: true, area: Area.center, target: {'group': true})
      ..set(DesktopId.hyprland, 'wlan', placed: true, area: Area.right, index: 0);
    w.install('llm');
    w.install('wlan');
    for (final a in ['llm', 'wlan']) {
      w.writeFile(autostart(a), '[Desktop Entry]\nExec=x\n');
    }
    wanted.save(w.paths);
    // llm was hidden meanwhile: the group shows it again; wlan gets its own place
    final f = MaprismaBarFile.read(w.paths);
    f.write(f.layout, ['tray:maprisma-llm-monitor']);
    final r = await b.applyWanted();
    expect(r['changed'], containsAll(['llm', 'wlan']));
    expect(stored().containsKey('hidden'), isFalse);
    expect(stored()['center'], ['tray', 'clock']);
    expect(stored()['right'].first, 'tray:maprisma-wlan-monitor');
  });

  test('a stale revision or an unreadable bar.json writes nothing', () async {
    bar({'version': 1, 'left': [], 'center': ['clock'], 'right': []});
    w.install('wlan');
    final core = hypr();
    await expectLater(core.call('bar.place', {'app': 'wlan', 'area': 'left', 'revision': 'old'}),
        throwsA(isA<RouteError>().having((e) => e.code, 'code', 'changed')));
    w.writeFile(barFile(), '{half');
    await expectLater(core.call('bar.place', {'app': 'wlan', 'area': 'left'}), throwsA(isA<RouteError>().having((e) => e.code, 'code', 'unreadable')));
    expect(File(barFile()).readAsStringSync(), '{half');
    expect((await core.call('bar.get'))['error'], isNotNull);
  });

  test('hidden wins over a zone, "tray" itself is never hidden; no file: the bar\'s defaults', () {
    expect(MaprismaBarFile.read(w.paths).layout.toJson(), {'left': ['launcher', 'workspaces'], 'center': ['clock'], 'right': ['tray', 'bluetooth', 'network', 'audio', 'power']});
    bar({'left': ['launcher', 'tray:x'], 'center': [], 'right': ['tray'], 'hidden': ['tray:x', 'tray']});
    final f = MaprismaBarFile.read(w.paths);
    expect(f.layout.toJson()['left'], ['launcher']);
    expect(f.hidden, ['tray:x']);
    // invalid entries dropped, an entry counts once (its first place), no valid zone entry: defaults
    bar({'left': ['bogus', 'clock', 5], 'center': ['clock', 'tray:'], 'right': ['tray']});
    expect(MaprismaBarFile.read(w.paths).layout.toJson(), {'left': ['clock'], 'center': [], 'right': ['tray']});
    bar({'left': ['bogus'], 'center': [], 'right': [], 'hidden': ['clock']});
    expect(MaprismaBarFile.read(w.paths).layout.toJson(), {'left': ['launcher', 'workspaces'], 'center': [], 'right': ['tray', 'bluetooth', 'network', 'audio', 'power']});
  });

  test('desktop.look follows Caelestia\'s scheme', () async {
    w.writeFile(p.join(w.home, '.local/state/maprisma-shell/scheme.json'), '{"colours": {"primary": "89B4FA", "surface": "1e1e2e", "onSurface": "cdd6f4"}}');
    final look = await hypr().call('desktop.look');
    expect(look['desktop'], 'hyprland');
    expect(look['colors'], {'accent': '#89b4fa', 'background': '#1e1e2e', 'foreground': '#cdd6f4'});
  });
}
