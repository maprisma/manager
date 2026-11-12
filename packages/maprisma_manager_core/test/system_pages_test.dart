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
    fakeSystem(w);
  });
  tearDown(() => w.dispose());

  List<String> log(String n) {
    final f = File(p.join(w.home, n));
    return f.existsSync() ? f.readAsLinesSync() : const [];
  }

  CoreService core() => w.core(desktop: 'Hyprland', extra: {'XDG_DATA_DIRS': '/usr/share'});

  test('defaults: the able apps per role (hidden ones left out); set writes all the role\'s types', () async {
    final r = await core().call('apps_default.get');
    final browser = (r['roles'] as List).first as Map;
    expect(browser['current'], 'firefox.desktop');
    expect([for (final a in browser['apps'] as List) a['name']], ['Chrome', 'Firefox']);
    await core().call('apps_default.set', {'role': 'browser', 'app': 'chrome.desktop'});
    expect(log('xdg.log').last, 'default chrome.desktop x-scheme-handler/http x-scheme-handler/https text/html');
    await expectLater(core().call('apps_default.set', {'role': 'browser', 'app': 'editor.desktop'}), throwsA(isA<RouteError>()));
    await expectLater(core().call('apps_default.set', {'role': 'browser', 'app': 'helper.desktop'}), throwsA(isA<RouteError>()));
  });

  test('autostart: add, switch off with Hidden=true, back on, remove; Maprisma trays are the Bar page\'s', () async {
    w.writeFile(p.join(w.home, '.config/autostart/com.maprisma.Theme.Daemon.desktop'), '[Desktop Entry]\nName=Theme\n');
    final c = core();
    await c.call('autostart.add', {'app': 'editor.desktop'});
    var r = await c.call('autostart.list');
    expect(r['entries'], [{'file': 'editor.desktop', 'name': 'Editor', 'on': true, 'here': true}]);
    expect(r['maprismaTrays'], 1);
    expect([for (final a in r['addable'] as List) a['id']], isNot(contains('editor.desktop')));
    await c.call('autostart.set', {'file': 'editor.desktop', 'on': false});
    final file = File(p.join(w.home, '.config/autostart/editor.desktop'));
    expect(file.readAsStringSync(), contains('Hidden=true'));
    await c.call('autostart.set', {'file': 'editor.desktop', 'on': true});
    expect(RegExp('Hidden=').allMatches(file.readAsStringSync()).length, 1);
    expect(file.readAsStringSync(), contains('Hidden=false'));
    for (final bad in [{'file': '../x.desktop', 'on': true}, {'file': 'com.maprisma.Theme.Daemon.desktop', 'on': false}, {'file': 'nope.desktop', 'on': true}]) {
      await expectLater(c.call('autostart.set', bad), throwsA(isA<RouteError>()), reason: '$bad');
    }
    await c.call('autostart.remove', {'file': 'editor.desktop'});
    expect(file.existsSync(), isFalse);
  });

  test('time and language: read, set through the tools, only listed values', () async {
    final c = core();
    final t = await c.call('time.get');
    expect(t, allOf(containsPair('ntp', true), containsPair('timezone', 'Europe/Berlin')));
    await c.call('time.set_timezone', {'zone': 'UTC'});
    await c.call('time.set_ntp', {'on': false});
    expect(log('tdc.log').where((l) => l.startsWith('set')), ['set-timezone UTC', 'set-ntp false']);
    await expectLater(c.call('time.set_timezone', {'zone': 'Mars/Base'}), throwsA(isA<RouteError>()));
    final l = await c.call('locale.get');
    expect(l, allOf(containsPair('lang', 'en_US.UTF-8'), containsPair('formats', 'de_DE.UTF-8')));
    await c.call('locale.set', {'formats': 'en_US.UTF-8'});
    expect(log('lc.log').last, 'set-locale LANG=en_US.UTF-8 LC_TIME=en_US.UTF-8 LC_NUMERIC=en_US.UTF-8 LC_MONETARY=en_US.UTF-8 LC_MEASUREMENT=en_US.UTF-8 LC_PAPER=en_US.UTF-8');
    await expectLater(c.call('locale.set', {'lang': 'xx_XX.UTF-8'}), throwsA(isA<RouteError>()));
  });

  test('about: from /etc, /sys, /proc and the tools', () async {
    w.writeFile(p.join(w.root, 'etc/os-release'), 'NAME="CachyOS"\nPRETTY_NAME="CachyOS Linux"\n');
    w.writeFile(p.join(w.root, 'etc/hostname'), 'box\n');
    w.writeFile(p.join(w.root, 'sys/class/dmi/id/sys_vendor'), 'Framework\n');
    w.writeFile(p.join(w.root, 'sys/class/dmi/id/product_name'), 'Laptop 13\n');
    w.writeFile(p.join(w.proc, 'meminfo'), 'MemTotal:       16384000 kB\n');
    w.writeFile(p.join(w.proc, 'cpuinfo'), 'processor\t: 0\nmodel name\t: Ryzen 7\n\nprocessor\t: 1\nmodel name\t: Ryzen 7\n');
    w.writeFile(p.join(w.proc, 'sys/kernel/osrelease'), '7.4.0\n');
    w.fake('lspci', 'echo "03:00.0 VGA compatible controller: Advanced Micro Devices, Inc. [AMD/ATI] Navi 31 [Radeon RX 7900 XT] (rev c8)"');
    w.fake('lsblk', r'''echo '{"blockdevices":[{"name":"nvme0n1","size":1000000000000,"type":"disk"},{"name":"zram0","size":8000000000,"type":"disk"}]}' ''');
    w.fake('uname', 'echo x86_64');
    final r = await core().call('about.get');
    expect(r, allOf([
      containsPair('hostname', 'box'),
      containsPair('model', 'Framework Laptop 13'),
      containsPair('memory', '15.6 GiB'),
      containsPair('processor', 'Ryzen 7 × 2'),
      containsPair('graphics', ['AMD Radeon RX 7900 XT']),
      containsPair('disk', '1 TB'),
      containsPair('os', 'CachyOS Linux'),
      containsPair('kernel', '7.4.0'),
      containsPair('arch', 'x86_64'),
      containsPair('desktop', 'Hyprland'),
    ]));
  });
}
