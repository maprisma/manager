// Fake system tools for the settings pages' tests (core and Flutter): pactl, hyprctl,
// localectl, nmcli, bluetoothctl, xdg-mime, timedatectl and .desktop files. No package:test
// here, so the Flutter tests can use them too.
import 'dart:convert';

import 'package:path/path.dart' as p;

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

/// A fake pactl: `-f json list <what>` / `-f json info` from `$HOME/pactl/<what>.json`, every
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

final monitorsFixture = [
  {
    'name': 'HDMI-A-1', 'description': 'LG TV', 'width': 3840, 'height': 2160, 'refreshRate': 120.0, 'x': 0, 'y': 0, 'scale': 2, 'transform': 0,
    'vrr': false, 'disabled': false, 'mirrorOf': 'none', 'availableModes': ['3840x2160@120.00Hz', '3840x2160@60.00Hz', '1920x1080@60.00Hz'],
  },
  {
    'name': 'DP-1', 'description': 'Dell', 'width': 2560, 'height': 1440, 'refreshRate': 59.95, 'x': 1920, 'y': 0, 'scale': 1, 'transform': 0,
    'vrr': false, 'disabled': false, 'mirrorOf': 'none', 'availableModes': ['2560x1440@59.95Hz'],
  },
];

/// A fake hyprctl (monitors, devices, getoption from $HOME/`opt/<key>`, reload logged) and
/// localectl (two layouts).
/// `hyprctl animations -j` of this PC's config (Maprisma Shell's animations.lua), shortened.
final animationsFixture = [
  [
    {'name': 'global', 'overridden': true, 'bezier': 'default', 'enabled': true, 'speed': 8.0, 'style': ''},
    {'name': 'windows', 'overridden': false, 'bezier': '', 'enabled': true, 'speed': 0.0, 'style': ''},
    {'name': 'windowsIn', 'overridden': true, 'bezier': 'emphasizedDecel', 'enabled': true, 'speed': 5.0, 'style': ''},
    {'name': 'windowsOut', 'overridden': true, 'bezier': 'emphasizedAccel', 'enabled': true, 'speed': 3.0, 'style': ''},
    {'name': 'windowsMove', 'overridden': true, 'bezier': 'standard', 'enabled': true, 'speed': 6.0, 'style': ''},
    {'name': 'layersIn', 'overridden': true, 'bezier': 'emphasizedDecel', 'enabled': true, 'speed': 5.0, 'style': 'slide'},
    {'name': 'layersOut', 'overridden': true, 'bezier': 'emphasizedAccel', 'enabled': true, 'speed': 4.0, 'style': 'slide'},
    {'name': 'fade', 'overridden': true, 'bezier': 'standard', 'enabled': true, 'speed': 6.0, 'style': ''},
    {'name': 'fadeLayers', 'overridden': true, 'bezier': 'standard', 'enabled': true, 'speed': 5.0, 'style': ''},
    {'name': 'workspaces', 'overridden': true, 'bezier': 'standard', 'enabled': true, 'speed': 5.0, 'style': ''},
    {'name': 'workspacesIn', 'overridden': false, 'bezier': '', 'enabled': true, 'speed': 0.0, 'style': ''},
    {'name': 'specialWorkspace', 'overridden': true, 'bezier': 'specialWorkSwitch', 'enabled': true, 'speed': 4.0, 'style': 'slidefadevert 15%'},
  ],
  [
    {'name': 'standard', 'X0': 0.2, 'Y0': 0.0, 'X1': 0.0, 'Y1': 1.0},
  ],
];

void fakeHypr(World w, {bool touchpad = false}) {
  w.writeFile(p.join(w.home, 'hypr', 'monitors.json'), jsonEncode(monitorsFixture));
  w.writeFile(p.join(w.home, 'hypr', 'devices.json'), jsonEncode({'mice': [{'name': touchpad ? 'elan-touchpad' : 'logitech-mouse'}], 'keyboards': []}));
  w.writeFile(p.join(w.home, 'opt', 'input.kb_layout'), '{"option": "input:kb_layout", "str": "de", "set": true}');
  w.writeFile(p.join(w.home, 'opt', 'input.repeat_rate'), '{"option": "input:repeat_rate", "int": 35, "set": true}');
  w.writeFile(p.join(w.home, 'opt', 'animations.enabled'), '{"option": "animations:enabled", "bool": true, "set": true}');
  w.writeFile(p.join(w.home, 'hypr', 'animations.json'), jsonEncode(animationsFixture));
  w.fake('hyprctl', r'''
show() { while IFS= read -r l || [ -n "$l" ]; do echo "$l"; done < "$1"; }
case "$1" in
  monitors) show "$HOME/hypr/monitors.json" ;;
  devices) show "$HOME/hypr/devices.json" ;;
  animations) show "$HOME/hypr/animations.json" ;;
  getoption) if [ -f "$HOME/opt/$2" ]; then show "$HOME/opt/$2"; else echo '{"option": "x", "bool": false, "set": false}'; fi ;;
  reload) echo reload >> "$HOME/hyprctl.log"; echo ok ;;
  *) exit 1 ;;
esac''');
  w.fake('localectl', 'echo de; echo us; echo fr');
}

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
  "-t -f IN-USE,SSID,SECURITY,SIGNAL device wifi list --rescan no"|"-t -f IN-USE,SSID,SECURITY,SIGNAL device wifi list --rescan yes")
    printf '*:Home\\\\:Net:WPA2:70\\n :Home\\\\:Net:WPA3:40\\n :Cafe::55\\n ::WPA2:30\\n :Neighbour:WPA2:80\\n' ;;
  "-t -f connection.uuid connection add"*) echo "connection.uuid:$uuidNew" ;;
  "connection up uuid "*)
    case "\$5" in passwd-file)
      while IFS= read -r l; do echo "passwd-file: \$l" >> "\$HOME/nmcli.log"; done < "\$6"
      echo "passwd-dir-mode: \$(/usr/bin/stat -c %a "\$(/usr/bin/dirname "\$6")")" >> "\$HOME/nmcli.log" ;;
    esac
    if [ -f "\$HOME/fail-up" ]; then echo "Error: Secrets were required, but not provided." >&2; exit 4; fi ;;
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

/// Applications, Time & Language and About against fakes: .desktop files under the fake root
/// and HOME, xdg-mime/timedatectl/localectl logging their calls, /proc and /sys files.
void fakeSystem(World w) {
  String app(String name, String mime, {bool hidden = false}) => '[Desktop Entry]\nType=Application\nName=$name\nName[de]=X\nExec=x\nMimeType=$mime\n${hidden ? 'NoDisplay=true\n' : ''}';
  w.writeFile(p.join(w.root, 'usr/share/applications/firefox.desktop'), app('Firefox', 'text/html;x-scheme-handler/http;x-scheme-handler/https;'));
  w.writeFile(p.join(w.root, 'usr/share/applications/chrome.desktop'), app('Chrome', 'text/html;x-scheme-handler/http;'));
  w.writeFile(p.join(w.root, 'usr/share/applications/helper.desktop'), app('Helper', 'text/html;', hidden: true));
  w.writeFile(p.join(w.root, 'usr/share/applications/editor.desktop'), app('Editor', 'text/plain;'));
  w.fake('xdg-mime', r'echo "$*" >> "$HOME/xdg.log"; if [ "$1" = query ]; then case "$3" in x-scheme-handler/http) echo firefox.desktop;; esac; fi');
  w.fake('timedatectl', r'''echo "$*" >> "$HOME/tdc.log"
case "$1" in
  show) printf 'NTP=yes\nTimezone=Europe/Berlin\nCanNTP=yes\n' ;;
  list-timezones) printf 'Europe/Berlin\nEurope/Paris\nUTC\n' ;;
esac''');
  w.fake('localectl', r'''echo "$*" >> "$HOME/lc.log"
case "$1" in
  status) printf '   System Locale: LANG=en_US.UTF-8\n                  LC_TIME=de_DE.UTF-8\n       VC Keymap: de\n      X11 Layout: de\n' ;;
  list-locales) printf 'C.UTF-8\nde_DE.UTF-8\nen_US.UTF-8\n' ;;
esac''');
}
