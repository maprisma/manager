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
  int reloads() {
    final f = File(p.join(w.home, 'hyprctl.log'));
    return f.existsSync() ? f.readAsLinesSync().length : 0;
  }

  test('displays.get: modes without Hz, scale, position, nothing stored yet', () async {
    final r = await w.core(desktop: 'Hyprland').call('displays.get');
    final m = (r['monitors'] as List).first as Map;
    expect(m, allOf(containsPair('mode', '3840x2160@120.00'), containsPair('scale', 2.0), containsPair('position', '0x0'), containsPair('enabled', true)));
    expect(m['modes'], ['3840x2160@120.00', '3840x2160@60.00', '1920x1080@60.00']);
  });

  test('displays.set writes hl.monitor into hypr-manager.lua, hooks it once into hypr-user.lua, reloads, and undoes', () async {
    w.writeFile(p.join(w.home, '.config/hypr/hypr-user.lua'), '-- mine\nhl.config({ input = { kb_layout = "de" } })\n');
    final core = w.core(desktop: 'Hyprland');
    await core.call('displays.set', {'output': 'HDMI-A-1', 'mode': '3840x2160@60.00', 'vrr': 2});
    expect(lua(), contains('hl.monitor({\n    output = "HDMI-A-1",\n    mode = "3840x2160@60.00",\n    position = "0x0",\n    scale = 2.0,\n    vrr = 2,\n})'));
    expect(user(), startsWith('-- mine\nhl.config({ input = { kb_layout = "de" } })\n'));
    expect(user(), endsWith('${HyprConfig.requireLine}\n'));
    await core.call('displays.set', {'output': 'HDMI-A-1', 'scale': 1.5});
    expect(RegExp('hypr-manager').allMatches(user()).length, 1);
    expect(reloads(), 2);
    expect((await core.call('displays.get'))['canUndo'], isTrue);
    await core.call('displays.undo');
    expect(lua(), contains('scale = 2.0'));
    expect(lua(), contains('mode = "3840x2160@60.00"'));
  });

  test('displays.set refuses unknown modes, scales, outputs and switching off the last display', () async {
    final core = w.core(desktop: 'Hyprland');
    for (final bad in [
      {'output': 'HDMI-A-1', 'mode': '800x600@60.00'},
      {'output': 'HDMI-A-1', 'scale': 1.33},
      {'output': 'HDMI-A-9', 'scale': 1.0},
      {'output': 'HDMI-A-1', 'position': 'left; rm -rf'},
      {'output': 'HDMI-A-1', 'mirror': 'HDMI-A-1'},
      {'output': 'HDMI-A-1'},
    ]) {
      await expectLater(core.call('displays.set', bad), throwsA(isA<RouteError>()), reason: '$bad');
    }
    await core.call('displays.set', {'output': 'DP-1', 'disabled': true});
    monitorsFixture[1]['disabled'] = true;
    fakeHypr(w);
    try {
      await expectLater(core.call('displays.set', {'output': 'HDMI-A-1', 'disabled': true}), throwsA(isA<RouteError>().having((e) => e.code, 'code', 'refused')));
    } finally {
      monitorsFixture[1]['disabled'] = false;
    }
    await expectLater(w.core(desktop: 'COSMIC').call('displays.get'), throwsA(isA<RouteError>().having((e) => e.code, 'code', 'unavailable')));
  });

  test('input.get reads live values; input.set writes the input block (touchpad nested) and null takes a value out', () async {
    final core = w.core(desktop: 'Hyprland');
    final r = await core.call('input.get');
    expect((r['values'] as Map)['kb_layout'], 'de');
    expect((r['values'] as Map)['repeat_rate'], 35);
    expect(r['layouts'], ['de', 'us', 'fr']);
    expect(r['touchpad'], isFalse);
    await core.call('input.set', {'key': 'kb_layout', 'value': 'de,us'});
    await core.call('input.set', {'key': 'sensitivity', 'value': -0.5});
    await core.call('input.set', {'key': 'touchpad.tap_to_click', 'value': true});
    await core.call('input.set', {'key': 'kb_options', 'value': 'caps:escape,compose:ralt'});
    expect(lua(), contains('hl.config({\n    input = {\n        kb_layout = "de,us",\n        sensitivity = -0.5,\n        kb_options = "caps:escape,compose:ralt",\n        touchpad = {\n            tap_to_click = true,\n        },\n    },\n})'));
    await core.call('input.set', {'key': 'sensitivity', 'value': null});
    expect(lua(), isNot(contains('sensitivity')));
    for (final bad in [
      {'key': 'kb_layout', 'value': 'xx'},
      {'key': 'kb_layout', 'value': 'de"; os.execute("x'},
      {'key': 'repeat_rate', 'value': 500},
      {'key': 'sensitivity', 'value': 3},
      {'key': 'accel_profile', 'value': 'turbo'},
      {'key': 'kb_options', 'value': 'caps escape'},
      {'key': 'gestures', 'value': true},
    ]) {
      await expectLater(core.call('input.set', bad), throwsA(isA<RouteError>().having((e) => e.code, 'code', 'bad_params')), reason: '$bad');
    }
  });

  test('a touchpad is found by its name', () async {
    fakeHypr(w, touchpad: true);
    expect((await w.core(desktop: 'Hyprland').call('input.get'))['touchpad'], isTrue);
  });
}
