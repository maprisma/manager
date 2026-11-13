import 'dart:convert';
import 'dart:io';

import 'package:maprisma_manager_core/maprisma_manager_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'fakes.dart';
import 'support.dart';

void main() {
  late World w;
  setUp(() {
    w = World.create();
    fakeHypr(w);
  });
  tearDown(() => w.dispose());

  String lua() => File(p.join(w.home, '.config/hypr/hypr-manager.lua')).readAsStringSync();
  String user() => File(p.join(w.home, '.config/hypr/hypr-user.lua')).readAsStringSync();
  Map state() => jsonDecode(File(p.join(w.home, '.config/maprisma-manager/hyprland.json')).readAsStringSync()) as Map;
  int reloads() {
    final f = File(p.join(w.home, 'hyprctl.log'));
    return f.existsSync() ? f.readAsLinesSync().length : 0;
  }

  test('parse and resolve: a leaf the config left alone follows its nearest set parent', () {
    final set = AnimationsService.parseAnimations(animationsFixture);
    expect(set.keys, isNot(contains('windows')), reason: 'not overridden');
    expect(AnimationsService.resolve(set, 'windowsIn'), (bezier: 'emphasizedDecel', speed: 5.0, style: '', enabled: true));
    expect(AnimationsService.resolve(set, 'windows'), (bezier: 'default', speed: 8.0, style: '', enabled: true), reason: 'global');
    expect(AnimationsService.resolve(set, 'workspacesOut').bezier, 'standard');
    expect(AnimationsService.resolve(set, 'fadeLayersIn').speed, 5.0);
    expect(AnimationsService.parseAnimations('nonsense'), isEmpty);
    expect(AnimationsService.parseAnimations([]), isEmpty);
  });

  test('the Lua (golden): master switch, every leaf of a group with the kept curves, speeds divided, styles where they apply', () {
    final base = AnimationsService.baseFrom(AnimationsService.parseAnimations(animationsFixture));
    final text = AnimationsService.lua({
      'enabled': false,
      'windows': {'style': 'popin 80%', 'speed': 2.0},
      'workspaces': {'enabled': true, 'style': 'slidefade 20%'},
      'layers': {'enabled': false},
      'base': base,
      'baseEnabled': true,
    });
    expect(text, '''
hl.config({
    animations = {
        enabled = false,
    },
})
hl.animation({ leaf = "windows", enabled = true, speed = 4, bezier = "default", style = "popin 80%" })
hl.animation({ leaf = "windowsIn", enabled = true, speed = 2.5, bezier = "emphasizedDecel", style = "popin 80%" })
hl.animation({ leaf = "windowsOut", enabled = true, speed = 1.5, bezier = "emphasizedAccel", style = "popin 80%" })
hl.animation({ leaf = "windowsMove", enabled = true, speed = 3, bezier = "standard" })
hl.animation({ leaf = "workspaces", enabled = true, speed = 5, bezier = "standard", style = "slidefade 20%" })
hl.animation({ leaf = "workspacesIn", enabled = true, speed = 5, bezier = "standard", style = "slidefade 20%" })
hl.animation({ leaf = "workspacesOut", enabled = true, speed = 5, bezier = "standard", style = "slidefade 20%" })
hl.animation({ leaf = "layers", enabled = false, speed = 8, bezier = "default" })
hl.animation({ leaf = "layersIn", enabled = false, speed = 5, bezier = "emphasizedDecel", style = "slide" })
hl.animation({ leaf = "layersOut", enabled = false, speed = 4, bezier = "emphasizedAccel", style = "slide" })
hl.animation({ leaf = "fadeLayers", enabled = false, speed = 5, bezier = "standard" })
hl.animation({ leaf = "fadeLayersIn", enabled = false, speed = 5, bezier = "standard" })
hl.animation({ leaf = "fadeLayersOut", enabled = false, speed = 5, bezier = "standard" })
''');
    expect(AnimationsService.lua({}), '');
    expect(HyprConfig.lua({'monitors': {}, 'input': {}, 'animations': {}}), isNot(contains('hl.animation')));
  });

  test('animations.get: live values, the config\'s as defaults, nothing stored; only on Hyprland', () async {
    final r = await w.core(desktop: 'Hyprland').call('animations.get');
    expect(r['enabled'], isTrue);
    expect(r['windows'], {'enabled': true, 'style': '', 'speed': 1.0});
    expect(r['workspaces'], {'enabled': true, 'style': '', 'speed': 1.0});
    expect(r['layers'], {'enabled': true});
    expect(r['defaults'], {'enabled': true, 'windows': {'enabled': true, 'style': '', 'speed': 1.0}, 'workspaces': {'enabled': true, 'style': '', 'speed': 1.0}, 'layers': {'enabled': true}});
    expect(r['stored'], isEmpty);
    expect(r['writable'], isTrue);
    expect(r['windowStyles'], contains('popin'));
    expect(r['workspaceStyles'], contains('slidefade'));
    await expectLater(w.core(desktop: 'COSMIC').call('animations.get'), throwsA(isA<RouteError>().having((e) => e.code, 'code', 'unavailable')));
    await expectLater(w.core(desktop: 'KDE').call('animations.set', {'key': 'enabled', 'value': false}), throwsA(isA<RouteError>().having((e) => e.code, 'code', 'unavailable')));
  });

  test('animations.set writes the group into hypr-manager.lua, hooks it once, reloads; the first curves are kept; reset takes it all out', () async {
    w.writeFile(p.join(w.home, '.config/hypr/hypr-user.lua'), '-- mine\n');
    final core = w.core(desktop: 'Hyprland');
    await core.call('animations.set', {'key': 'workspaces.style', 'value': 'fade'});
    expect(lua(), contains('hl.animation({ leaf = "workspaces", enabled = true, speed = 5, bezier = "standard", style = "fade" })\n'));
    expect(lua(), isNot(contains('windowsIn')), reason: 'only the changed group');
    expect(user(), '-- mine\n\n${HyprConfig.requireLine}\n');
    expect(reloads(), 1);
    // Hyprland now has the Manager's values; the base stays the config's own.
    final live = jsonDecode(jsonEncode(animationsFixture)) as List;
    for (final a in (live.first as List).cast<Map>()) {
      if (a['name'] == 'windowsIn') a['bezier'] = 'linear';
    }
    w.writeFile(p.join(w.home, 'hypr', 'animations.json'), jsonEncode(live));
    await core.call('animations.set', {'key': 'windows.speed', 'value': 2});
    expect(lua(), contains('hl.animation({ leaf = "windowsIn", enabled = true, speed = 2.5, bezier = "emphasizedDecel" })'));
    await core.call('animations.set', {'key': 'enabled', 'value': false});
    expect(lua(), contains('    animations = {\n        enabled = false,\n    },'));
    expect(RegExp('hypr-manager').allMatches(user()).length, 1);
    expect((state()['animations'] as Map)['stored'], isNull);
    final r = await core.call('animations.get');
    expect(r['stored'], {'workspaces': {'style': 'fade'}, 'windows': {'speed': 2.0}, 'enabled': false});
    expect(r['windows']['speed'], 2.0);
    expect(r['defaults']['enabled'], isTrue, reason: 'what the config had');
    // one value out again
    await core.call('animations.set', {'key': 'enabled', 'value': null});
    expect(lua(), isNot(contains('enabled = false')));
    await core.call('animations.reset');
    expect(lua(), isNot(contains('hl.animation')));
    expect(state()['animations'], isEmpty);
    expect(reloads(), 5);
    // nothing stored: a reset changes nothing
    expect((await core.call('animations.reset'))['written'], isFalse);
    expect(reloads(), 5);
  });

  test('taking the last value out drops the kept curves too; Input and Displays keep the animations', () async {
    final core = w.core(desktop: 'Hyprland');
    await core.call('animations.set', {'key': 'layers.enabled', 'value': false});
    expect((state()['animations'] as Map).keys, containsAll(['layers', 'base', 'baseEnabled']));
    await core.call('input.set', {'key': 'repeat_rate', 'value': 40});
    expect(lua(), contains('repeat_rate = 40'));
    expect(lua(), contains('leaf = "layersIn", enabled = false'));
    await core.call('animations.set', {'key': 'layers.enabled', 'value': null});
    expect(state()['animations'], isEmpty);
    expect(lua(), contains('repeat_rate = 40'));
    expect(lua(), isNot(contains('hl.animation')));
  });

  test('animations.set refuses unknown keys, styles Hyprland does not have, odd speeds and a config it cannot write', () async {
    final core = w.core(desktop: 'Hyprland');
    for (final bad in [
      {'key': 'global.enabled', 'value': false},
      {'key': 'enabled', 'value': 'no'},
      {'key': 'windows.style', 'value': 'fade'},
      {'key': 'windows.style', 'value': 'popin 120%'},
      {'key': 'windows.style', 'value': 'slide"; os.execute("x'},
      {'key': 'workspaces.style', 'value': 'gnomed'},
      {'key': 'workspaces.style', 'value': 'bogus'},
      {'key': 'workspaces.speed', 'value': 3},
      {'key': 'windows.speed', 'value': '2'},
      {'key': 7, 'value': true},
    ]) {
      await expectLater(core.call('animations.set', bad), throwsA(isA<RouteError>().having((e) => e.code, 'code', 'bad_params')), reason: '$bad');
    }
    for (final (g, s) in [('windows', 'popin 80%'), ('windows', 'gnomed'), ('windows', ''), ('workspaces', 'slidefadevert 15%'), ('workspaces', 'slidevert')]) {
      expect(AnimationsService.validStyle(g, s), isTrue, reason: s);
    }
    expect(reloads(), 0);
    w.writeFile(p.join(w.home, '.config/hypr/hypr-user.lua'), '-- mine\n');
    Process.runSync('chmod', ['444', p.join(w.home, '.config/hypr/hypr-user.lua')]);
    expect((await core.call('animations.get'))['writable'], isFalse);
    await expectLater(core.call('animations.set', {'key': 'enabled', 'value': false}), throwsA(isA<RouteError>().having((e) => e.code, 'code', 'refused')));
    expect(user(), '-- mine\n');
  });

  test('two changes sent together both land', () async {
    final core = w.core(desktop: 'Hyprland');
    await Future.wait([
      core.call('animations.set', {'key': 'windows.style', 'value': 'gnomed'}),
      core.call('animations.set', {'key': 'workspaces.enabled', 'value': false}),
    ]);
    expect(lua(), contains('style = "gnomed"'));
    expect(lua(), contains('leaf = "workspaces", enabled = false'));
  });
}
