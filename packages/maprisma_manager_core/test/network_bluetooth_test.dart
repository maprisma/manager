import 'dart:io';

import 'package:maprisma_manager_core/maprisma_manager_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

const uuidHome = '11111111-2222-3333-4444-555555555555';
const uuidWired = '66666666-7777-8888-9999-000000000000';
const uuidVpn = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';
const uuidNew = '12345678-1234-1234-1234-123456789abc';

/// A fake nmcli: terse answers from the arguments, every call (and an editor's stdin) logged
/// to $HOME/nmcli.log; `connection up` fails for the uuid in $HOME/fail-up.
void fakeNmcli(World w) {
  w.fake('nmcli', '''
echo "\$*" >> "\$HOME/nmcli.log"
case "\$*" in
  "-t radio wifi") echo enabled ;;
  "-t -f DEVICE,TYPE,STATE,CONNECTION device status") printf 'wlan0:wifi:connected:Home\\\\:Net\\nenp16s0:ethernet:unavailable:\\n' ;;
  "-t -f NAME,UUID,TYPE,ACTIVE,DEVICE connection show") printf 'Home\\\\:Net:$uuidHome:802-11-wireless:yes:wlan0\\nWired connection 1:$uuidWired:802-3-ethernet:no:\\nWork:$uuidVpn:wireguard:no:\\nlo:x:loopback:yes:lo\\n' ;;
  "-t -f IN-USE,SSID,SECURITY,SIGNAL device wifi list --rescan auto"|"-t -f IN-USE,SSID,SECURITY,SIGNAL device wifi list --rescan yes")
    printf '*:Home\\\\:Net:WPA2:70\\n :Home\\\\:Net:WPA3:40\\n :Cafe::55\\n ::WPA2:30\\n :Neighbour:WPA2:80\\n' ;;
  "-t -f connection.uuid connection add"*) echo "connection.uuid:$uuidNew" ;;
  "connection edit uuid "*) while IFS= read -r l; do echo "stdin: \$l" >> "\$HOME/nmcli.log"; done ;;
  "connection up uuid "*) if [ -f "\$HOME/fail-up" ]; then echo "Error: Secrets were required, but not provided." >&2; exit 4; fi ;;
esac
exit 0''');
}

void fakeBluetoothctl(World w) {
  w.fake('bluetoothctl', r'''
echo "$*" >> "$HOME/bt.log"
case "$*" in
  show) printf 'Controller 60:E9:AA:5D:C2:BC (public)\n\tName: pc\n\tPowered: yes\n' ;;
  "devices Paired") echo "Device AA:BB:CC:DD:EE:01 Headphones" ;;
  devices) printf 'Device AA:BB:CC:DD:EE:01 Headphones\nDevice AA:BB:CC:DD:EE:02 Keyboard K3\nDevice AA:BB:CC:DD:EE:03 AA-BB-CC-DD-EE-03\n' ;;
  "info AA:BB:CC:DD:EE:01") printf 'Device AA:BB:CC:DD:EE:01 (public)\n\tAlias: My Headphones\n\tIcon: audio-headset\n\tConnected: yes\n\tBattery Percentage: 0x50 (80)\n' ;;
esac
exit 0''');
}

void main() {
  late World w;
  setUp(() {
    w = World.create();
    fakeNmcli(w);
    fakeBluetoothctl(w);
  });
  tearDown(() => w.dispose());

  List<String> log(String name) {
    final f = File(p.join(w.home, name));
    return f.existsSync() ? f.readAsLinesSync() : const [];
  }

  test('terse lines: escaped colons stay in the field', () {
    expect(NetworkService.terse(r'Home\:Net:WPA2:70'), ['Home:Net', 'WPA2', '70']);
    expect(NetworkService.terse(r'a\\b::c'), [r'a\b', '', 'c']);
  });

  test('network.get: known, visible (one per name, strongest, hidden ones left out), wired, VPN', () async {
    final r = await w.core(desktop: 'Hyprland').call('network.get');
    expect(r['wifiOn'], isTrue);
    expect(r['known'], [{'name': 'Home:Net', 'uuid': uuidHome, 'type': '802-11-wireless', 'active': true, 'device': 'wlan0'}]);
    expect([for (final v in r['visible'] as List) v['ssid']], ['Neighbour', 'Home:Net', 'Cafe']);
    final home = (r['visible'] as List).firstWhere((v) => v['ssid'] == 'Home:Net') as Map;
    expect(home, allOf(containsPair('inUse', true), containsPair('known', true), containsPair('signal', 70)));
    expect([for (final c in r['wired'] as List) c['uuid']], [uuidWired]);
    expect([for (final c in r['vpn'] as List) c['name']], ['Work']);
  });

  test('connect with a password: the key only on stdin, never in an argument', () async {
    final core = w.core(desktop: 'Hyprland');
    final r = await core.call('network.connect', {'ssid': 'Neighbour', 'password': 'secret-pass-123'});
    expect(r['uuid'], uuidNew);
    final calls = log('nmcli.log');
    expect(calls.where((l) => !l.startsWith('stdin:')).any((l) => l.contains('secret-pass-123')), isFalse);
    expect(calls, contains('stdin: set 802-11-wireless-security.psk secret-pass-123'));
    expect(calls, contains('connection up uuid $uuidNew'));
  });

  test('a refused password removes the new connection again', () async {
    w.writeFile(p.join(w.home, 'fail-up'), '');
    final core = w.core(desktop: 'Hyprland');
    await expectLater(core.call('network.connect', {'ssid': 'Neighbour', 'password': 'wrong-pass-1'}), throwsA(isA<RouteError>().having((e) => e.message, 'message', contains('Secrets were required'))));
    expect(log('nmcli.log'), contains('connection delete uuid $uuidNew'));
  });

  test('up/down/forget only for known connections of the right kind; bad input refused', () async {
    final core = w.core(desktop: 'Hyprland');
    await core.call('network.down', {'uuid': uuidHome});
    await core.call('network.up', {'uuid': uuidVpn});
    await core.call('network.forget', {'uuid': uuidHome});
    await core.call('network.wifi', {'on': false});
    expect(log('nmcli.log').where((l) => !l.startsWith('-t')), ['connection down uuid $uuidHome', 'connection up uuid $uuidVpn', 'connection delete uuid $uuidHome', 'radio wifi off']);
    for (final (route, params) in [
      ('network.forget', {'uuid': uuidWired}),
      ('network.up', {'uuid': '99999999-0000-0000-0000-000000000000'}),
      ('network.up', {'uuid': '--help'}),
      ('network.connect', {'ssid': 'x', 'password': 'short'}),
      ('network.connect', {'ssid': ''}),
    ]) {
      await expectLater(core.call(route, params), throwsA(isA<RouteError>()), reason: '$route $params');
    }
  });

  test('bluetooth.get: paired with battery, nearby without the paired and the unnamed', () async {
    final r = await w.core(desktop: 'Hyprland').call('bluetooth.get');
    expect(r['powered'], isTrue);
    expect(r['paired'], [{'mac': 'AA:BB:CC:DD:EE:01', 'name': 'My Headphones', 'connected': true, 'icon': 'audio-headset', 'battery': 80}]);
    expect(r['nearby'], [{'mac': 'AA:BB:CC:DD:EE:02', 'name': 'Keyboard K3'}]);
  });

  test('bluetooth actions go to bluetoothctl; a bad address is refused', () async {
    final core = w.core(desktop: 'Hyprland');
    await core.call('bluetooth.pair', {'mac': 'AA:BB:CC:DD:EE:02'});
    await core.call('bluetooth.forget', {'mac': 'AA:BB:CC:DD:EE:01'});
    await core.call('bluetooth.power', {'on': false});
    expect(log('bt.log'), ['pair AA:BB:CC:DD:EE:02', 'trust AA:BB:CC:DD:EE:02', 'connect AA:BB:CC:DD:EE:02', 'remove AA:BB:CC:DD:EE:01', 'power off']);
    await expectLater(core.call('bluetooth.connect', {'mac': 'aa:bb'}), throwsA(isA<RouteError>().having((e) => e.code, 'code', 'bad_params')));
  });
}
