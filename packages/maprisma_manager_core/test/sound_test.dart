import 'dart:convert';
import 'dart:io';

import 'package:maprisma_manager_core/maprisma_manager_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

/// pactl's JSON as PipeWire's pulse server gives it (shortened from a real machine).
final soundFixtures = {
  'info': {'default_sink_name': 'hdmi', 'default_source_name': 'mic'},
  'sinks': [
    {'index': 72, 'name': 'hdmi', 'description': 'HDMI (LG TV)', 'mute': false, 'volume': {'front-left': {'value_percent': '80%'}, 'front-right': {'value_percent': '60%'}}},
    {'index': 74, 'name': 'speakers', 'description': 'USB Audio Speakers', 'mute': true, 'volume': {'front-left': {'value_percent': '100%'}}},
  ],
  'sources': [
    {'index': 72, 'name': 'hdmi.monitor', 'description': 'Monitor of HDMI', 'monitor_source': 'hdmi', 'mute': false, 'volume': {}},
    {'index': 78, 'name': 'mic', 'description': 'Razer Kiyo', 'monitor_source': '', 'mute': false, 'volume': {'mono': {'value_percent': '45%'}}},
  ],
  'sink-inputs': [
    {'index': 4374, 'mute': false, 'properties': {'application.name': 'Google Chrome', 'media.name': 'Playback'}, 'volume': {'front-left': {'value_percent': '100%'}}},
  ],
  'cards': [
    {
      'name': 'alsa_card.usb',
      'properties': {'device.description': 'USB Audio'},
      'active_profile': 'HiFi',
      'profiles': {'off': {'description': 'Off', 'available': true}, 'HiFi': {'description': 'HiFi', 'available': true}},
    },
  ],
};

/// A fake pactl: `-f json list <what>` / `-f json info` from $HOME/pactl/<what>.json, every
/// other call appended to $HOME/pactl.log.
void fakePactl(World w) {
  for (final MapEntry(:key, :value) in soundFixtures.entries) {
    w.writeFile(p.join(w.home, 'pactl', '$key.json'), jsonEncode(value));
  }
  w.fake('pactl', r'''
if [ "$1" = "-f" ]; then
  if [ "$3" = "info" ]; then f="$HOME/pactl/info.json"; else f="$HOME/pactl/$4.json"; fi
  while IFS= read -r l || [ -n "$l" ]; do echo "$l"; done < "$f"
  exit 0
fi
echo "$*" >> "$HOME/pactl.log"''');
}

void main() {
  late World w;
  setUp(() {
    w = World.create();
    fakePactl(w);
  });
  tearDown(() => w.dispose());

  List<String> calls() {
    final f = File(p.join(w.home, 'pactl.log'));
    return f.existsSync() ? f.readAsLinesSync() : const [];
  }

  test('sound.get: devices with their average volume, no monitors as inputs, streams, profiles', () async {
    final r = await w.core(desktop: 'Hyprland').call('sound.get');
    expect(r['default_sink'], 'hdmi');
    expect(r['sinks'], [
      {'name': 'hdmi', 'description': 'HDMI (LG TV)', 'volume': 70, 'mute': false},
      {'name': 'speakers', 'description': 'USB Audio Speakers', 'volume': 100, 'mute': true},
    ]);
    expect([for (final s in r['sources'] as List) s['name']], ['mic']);
    expect((r['streams'] as List).single, allOf(containsPair('app', 'Google Chrome'), containsPair('index', 4374)));
    expect(((r['cards'] as List).single as Map)['profiles'], hasLength(2));
    expect(r['amplify'], isFalse);
  });

  test('volume, mute, default device, stream and profile go to pactl; wrong values are refused', () async {
    final core = w.core(desktop: 'Hyprland');
    await core.call('sound.volume', {'target': 'sink', 'percent': 55});
    await core.call('sound.mute', {'target': 'source', 'mute': true});
    await core.call('sound.default', {'target': 'sink', 'name': 'speakers'});
    await core.call('sound.stream', {'index': 4374, 'percent': 30, 'mute': false});
    await core.call('sound.profile', {'card': 'alsa_card.usb', 'profile': 'off'});
    expect(calls(), [
      'set-sink-volume @DEFAULT_SINK@ 55%',
      'set-source-mute @DEFAULT_SOURCE@ 1',
      'set-default-sink speakers',
      'set-sink-input-volume 4374 30%',
      'set-sink-input-mute 4374 0',
      'set-card-profile alsa_card.usb off',
    ]);
    for (final (route, params) in [
      ('sound.volume', {'target': 'sink', 'percent': 120}),
      ('sound.volume', {'target': 'speaker', 'percent': 10}),
      ('sound.default', {'target': 'sink', 'name': 'hdmi.monitor'}),
      ('sound.default', {'target': 'source', 'name': 'hdmi.monitor'}),
      ('sound.profile', {'card': 'alsa_card.usb', 'profile': 'turbo'}),
      ('sound.stream', {'index': 1}),
    ]) {
      await expectLater(core.call(route, params), throwsA(isA<RouteError>().having((e) => e.code, 'code', 'bad_params')), reason: '$route $params');
    }
  });

  test('Amplification allows up to 150 %', () async {
    final core = w.core(desktop: 'Hyprland');
    await core.call('settings.set', {'key': 'sound_amplify', 'value': true});
    await core.call('sound.volume', {'target': 'sink', 'percent': 150});
    expect(calls().last, 'set-sink-volume @DEFAULT_SINK@ 150%');
    expect((await core.call('sound.get'))['amplify'], isTrue);
  });
}
