import 'dart:convert';
import 'dart:io';

import 'package:maprisma_manager_core/maprisma_manager_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late World w;
  setUp(() {
    w = World.create();
    w.fake('pacman', 'exit 1');
  });
  tearDown(() => w.dispose());

  Future<Map<String, dynamic>> list([String desktop = 'COSMIC']) => w.core(desktop: desktop).call('apps.list');

  test('an empty HOME: nothing installed, no build facts', () async {
    final r = await list();
    expect(r['desktop'], 'cosmic');
    expect(r['projectsDir'], w.projects);
    for (final a in (r['apps'] as List).cast<Map<String, dynamic>>()) {
      expect(a['state'], 'absent', reason: a['id']);
      expect(a['updates']['buildUnknown'], isFalse);
    }
    expect(appOf(r, 'wlan')['repos'][0]['available'], 'cloneable');
    expect(appOf(r, 'home')['repos'][0]['available'], 'not available here');
  });

  test('installed, then partly installed when a file is missing', () async {
    w.install('wlan');
    var a = appOf(await list(), 'wlan');
    expect(a['state'], 'installed');
    expect(a['updates']['buildUnknown'], isTrue);
    expect(a['build']['known'], isFalse);

    File(p.join(w.paths.data, 'maprisma-wlan-monitor/scripts/wlan-monitor.py')).deleteSync();
    a = appOf(await list(), 'wlan');
    expect(a['state'], 'partial');
    final failing = a['components'][0]['failing'] as List;
    expect(failing.single['path'], endsWith('scripts/wlan-monitor.py'));
    expect(failing.single['problem'], 'missing');
  });

  test('a non-executable binary and a link to the wrong place fail', () async {
    w.install('theme');
    chmod(p.join(w.paths.lib, 'maprisma-theme/bin/maprisma-theme-core'), '644');
    final link = Link(p.join(w.paths.bin, 'maprisma-theme-helper'));
    link.deleteSync();
    link.createSync('/nowhere/helper');
    final a = appOf(await list(), 'theme');
    expect(a['state'], 'partial');
    final problems = {for (final f in a['components'][0]['failing'] as List) p.basename(f['path']): f['problem']};
    expect(problems['maprisma-theme-core'], 'not executable');
    expect(problems['maprisma-theme-helper'], 'points to /nowhere/helper');
  });

  test('Narrator without its settings window (no cmake) is partly installed', () async {
    w.install('narrator', skipParts: {'settings window'});
    final a = appOf(await list(), 'narrator');
    expect(a['state'], 'partial');
    expect(a['components'][0]['missingParts'], ['settings window']);
    expect(a['components'][0]['prerequisitesMissing'], containsAll(['cargo', 'python3', 'flutter', 'cmake', 'ninja']));
  });

  test('Launcher: the COSMIC applet counts on COSMIC only', () async {
    w.install('launcher', skipComponents: {'applet'});
    expect(appOf(await list('COSMIC'), 'launcher')['state'], 'partial');
    expect(appOf(await list('KDE'), 'launcher')['state'], 'installed');
  });

  test('KDE-only apps report their files on COSMIC too, marked as not for this desktop', () async {
    w.install('tiling');
    final a = appOf(await list(), 'tiling');
    expect(a['state'], 'installed');
    expect(a['supportedHere'], isFalse);
  });

  group('maprisma via pacman', () {
    test('installed: pacman -Q and the files', () async {
      w.fake('pacman', r'[ "$1 $2" = "-Q maprisma-bin" ] && echo "maprisma-bin 0.13.1-9" && exit 0; exit 1');
      w.install('maprisma');
      w.repo('maprisma');
      File(p.join(w.projects, 'maprisma/addons.py')).writeAsStringSync('MAPRISMA_VERSION = "0.14.2"  # x\n');
      final a = appOf(await list(), 'maprisma');
      expect(a['state'], 'installed');
      expect(a['versions'], {'installed': '0.13.1-9', 'folder': '0.14.2', 'release': null});
      expect(a['components'][0]['packageVersion'], '0.13.1-9');
      // system files are under the test root
      expect(File(p.join(w.root, 'usr/lib/maprisma/maprisma')).existsSync(), isTrue);
    });

    test('not a package: absent; files without the package: partial', () async {
      expect(appOf(await list(), 'maprisma')['state'], 'absent');
      w.install('maprisma');
      final a = appOf(await list(), 'maprisma');
      expect(a['state'], 'partial');
      expect(a['components'][0]['note'], contains('pacman has no maprisma-bin'));
    });

    test('no pacman at all: said so, state from the files', () async {
      File(p.join(w.fakeBin, 'pacman')).deleteSync();
      w.install('maprisma');
      final a = appOf(await list(), 'maprisma');
      expect(a['state'], 'installed');
      expect(a['components'][0]['note'], contains('pacman not found'));
      expect(a['components'][0]['prerequisitesMissing'], contains('pacman'));
    });
  });

  group('receipts and the three update facts', () {
    void receipt(Map<String, dynamic> data) => w.writeFile(p.join(w.paths.receipts, 'wlan.json'), jsonEncode(data));

    test('a part for another desktop: its folder is not compared (the Launcher\'s COSMIC applet on KDE)', () async {
      final core = w.core(desktop: 'KDE');
      w.install('launcher');
      w.repo('maprisma-launcher');
      w.repo('maprisma-launcher-applet');
      w.writeFile(p.join(w.paths.receipts, 'launcher.json'), jsonEncode({
        'id': 'launcher',
        'at': '2026-11-11T06:53:17Z',
        'inputs': [{'repo': 'maprisma-launcher', 'commit': w.head('maprisma-launcher'), 'dirty': false}],
        'paths': [{'path': '/d', 'dir': true}],
      }));
      var a = appOf(await core.call('apps.list'), 'launcher');
      expect(a['updates'], containsPair('sourceDiffers', false));
      // on COSMIC the applet is built too: not in the receipt, so the folder differs
      a = appOf(await w.core(desktop: 'COSMIC').call('apps.list'), 'launcher');
      expect(a['updates'], containsPair('sourceDiffers', true));
      expect(a['updates']['sourceReasons'], contains('maprisma-launcher-applet: not in the receipt'));
    });

    test('a matching receipt: build known, folder same', () async {
      w.install('wlan');
      w.repo('maprisma-wlan-monitor');
      receipt({
        'id': 'wlan',
        'at': '2026-11-09T10:00:00Z',
        'inputs': [{'repo': 'maprisma-wlan-monitor', 'commit': w.head('maprisma-wlan-monitor'), 'dirty': false}],
        'paths': [
          {'path': '/x', 'sha256': 'abababababababababababababababababababababababababababababababab'},
          {'path': '/l', 'link': '/t'},
          {'path': '/d', 'dir': true},
        ],
      });
      final a = appOf(await list(), 'wlan');
      expect(a['build']['known'], isTrue);
      expect(a['updates'], containsPair('sourceDiffers', false));
      expect(a['updates'], containsPair('buildUnknown', false));
      expect(a['updates'], containsPair('upstreamNew', null));
    });

    test('another commit or uncommitted changes: the folder differs', () async {
      w.install('wlan');
      final dir = w.repo('maprisma-wlan-monitor');
      receipt({
        'id': 'wlan',
        'at': '2026-11-09T10:00:00Z',
        'inputs': [{'repo': 'maprisma-wlan-monitor', 'commit': 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef', 'dirty': false}],
      });
      var a = appOf(await list(), 'wlan');
      expect(a['updates']['sourceDiffers'], isTrue);
      expect(a['updates']['sourceReasons'].single, contains('built deadbeef'));

      receipt({
        'id': 'wlan',
        'at': '2026-11-09T10:00:00Z',
        'inputs': [{'repo': 'maprisma-wlan-monitor', 'commit': w.head('maprisma-wlan-monitor'), 'dirty': false}],
      });
      File(p.join(dir, 'README')).writeAsStringSync('changed\n');
      a = appOf(await list(), 'wlan');
      expect(a['updates']['sourceDiffers'], isTrue);
      expect(a['updates']['sourceReasons'].single, contains('uncommitted'));
    });

    test('a broken receipt is reported, not trusted', () async {
      w.install('wlan');
      final good = {'repo': 'maprisma-wlan-monitor', 'commit': 'a' * 40, 'dirty': false};
      for (final (bad, why) in [
        ({'id': 'other', 'at': '2026-11-09T10:00:00Z', 'inputs': [good]}, 'id does not match the file'),
        ({'id': 'wlan', 'at': 'x', 'inputs': [good]}, 'at'),
        ({'id': 'wlan', 'at': '2026-11-09T10:00:00Z', 'inputs': [{...good, 'commit': null}]}, 'inputs entry'),
        ({'id': 'wlan', 'at': '2026-11-09T10:00:00Z', 'inputs': [good, good]}, 'duplicate input'),
        ({'id': 'wlan', 'at': '2026-11-09T10:00:00Z', 'inputs': [good], 'paths': [{'path': '/x'}]}, 'paths'),
        ({'id': 'wlan', 'at': '2026-11-09T10:00:00Z', 'inputs': [good], 'paths': [{'path': '/x', 'sha256': 'ab', 'dir': true}]}, 'paths'),
        ({'id': 'wlan', 'at': '2026-11-09T10:00:00Z', 'inputs': [good], 'displaced': [{'path': '/x'}]}, 'displaced'),
      ]) {
        receipt(bad);
        final a = appOf(await list(), 'wlan');
        expect(a['build']['known'], isFalse, reason: why);
        expect(a['build']['error'], 'invalid receipt: $why');
        expect(a['updates']['buildUnknown'], isTrue);
      }
    });

    test('a receipt but no repo to compare: unknown, not "same"', () async {
      w.install('wlan');
      receipt({
        'id': 'wlan',
        'at': '2026-11-09T10:00:00Z',
        'inputs': [{'repo': 'maprisma-wlan-monitor', 'commit': 'a' * 40, 'dirty': false}],
      });
      final a = appOf(await list(), 'wlan');
      expect(a['build']['known'], isTrue);
      expect(a['updates']['sourceDiffers'], isNull);
      expect(a['updates']['sourceReasons'].single, contains('no repo to compare'));
    });
  });

  test('prerequisites are looked up in PATH (and flutter from MAPRISMA_FLUTTER)', () async {
    w.fake('cargo', 'exit 0');
    w.writeFile(p.join(w.dir, 'flutter/bin/flutter'), '#!/bin/sh\n', mode: '755');
    w.writeFile(p.join(w.dir, 'flutter/bin/dart'), '#!/bin/sh\n', mode: '755');
    final core = w.core(extra: {'MAPRISMA_FLUTTER': p.join(w.dir, 'flutter/bin')});
    final r = await core.call('apps.get', {'id': 'theme'});
    final pre = {for (final x in r['app']['components'][0]['prerequisites'] as List) x['command']: x['path']};
    expect(pre['cargo'], p.join(w.fakeBin, 'cargo'));
    expect(pre['flutter'], p.join(w.dir, 'flutter/bin/flutter'));
    expect(pre['dart'], p.join(w.dir, 'flutter/bin/dart'));
    expect(r['app']['env'], {'FLUTTER': p.join(w.dir, 'flutter/bin')});
    final n = await core.call('apps.get', {'id': 'narrator'});
    expect(n['app']['env'], {'FLUTTER': p.join(w.dir, 'flutter/bin/flutter')});
  });

  group('bar state', () {
    test('COSMIC: the zone from plugins_wings / plugins_center', () async {
      final dir = p.join(w.paths.config, 'cosmic/com.system76.CosmicPanel.Panel/v1');
      w.writeFile(p.join(dir, 'plugins_wings'), 'Some(([\n    "com.system76.CosmicAppletWorkspaces",\n    "io.github.ubruckhaus.CosmicMaprismaLauncher",\n], [\n    "io.github.ubruckhaus.CosmicMaprismaHome",\n]))');
      w.writeFile(p.join(dir, 'plugins_center'), 'Some([\n    "io.github.ubruckhaus.CosmicMaprismaWlanMonitor",\n])');
      final r = await list();
      expect(appOf(r, 'launcher')['bar']['zone'], 'left');
      expect(appOf(r, 'home')['bar']['zone'], 'right');
      expect(appOf(r, 'wlan')['bar']['zone'], 'center');
      expect(appOf(r, 'hue')['bar']['state'], 'out');
      expect(appOf(r, 'maprisma')['bar']['state'], 'none');
    });

    test('RON lists: None, empty, comments', () {
      expect(ronStringLists('None'), isEmpty);
      expect(ronStringLists('Some(([], []))'), [<String>[], <String>[]]);
      expect(ronStringLists('// ["x"]\nSome([ /* "y" /* ] */ */ "a", // "b"\n "c"])'), [['a', 'c']]);
      expect(() => ronStringLists('Some(["a"'), throwsFormatException);
    });

    test('an unreadable panel config is "unknown", not "out"', () async {
      final dir = p.join(w.paths.config, 'cosmic/com.system76.CosmicPanel.Panel/v1');
      w.writeFile(p.join(dir, 'plugins_wings'), 'Some(([ "io.github.ubruckhaus.CosmicMaprismaHome"');
      final bar = appOf(await list(), 'home')['bar'];
      expect(bar['state'], 'unknown');
      expect(bar['error'], contains('plugins_wings'));
    });

    test('KDE: a tray starts at login unless its autostart file is Hidden', () async {
      w.install('wlan');
      expect(appOf(await list('KDE'), 'wlan')['bar'], containsPair('state', 'in'));
      final f = File(p.join(w.paths.autostart, 'io.github.ubruckhaus.CosmicMaprismaWlanMonitor.Tray.desktop'));
      f.writeAsStringSync('[Desktop Entry]\nHidden=true\n');
      expect(appOf(await list('KDE'), 'wlan')['bar'], containsPair('state', 'out'));
      expect(appOf(await list('KDE'), 'launcher')['bar']['kind'], 'widgetEntry');
      expect(appOf(await list('KDE'), 'theme')['bar']['iconName'], 'com.maprisma.Theme');
      expect(appOf(await list('COSMIC'), 'theme')['bar']['iconName'], 'io.github.ubruckhaus.CosmicMaprismaTheme-symbolic');
    });

    test('other desktops have no bar icons', () async {
      expect(appOf(await list('GNOME'), 'wlan')['bar']['state'], 'none');
    });
  });

  test('runtime files: marked ours by their marker line', () async {
    w.writeFile(p.join(w.paths.bin, 'video-trans'), '#!/usr/bin/env bash\n# Managed by ubruckhaus.video-trans\n');
    final units = p.join(w.home, '.config/systemd/user'); // Narrator's setup hardcodes ~/.config
    w.writeFile(p.join(units, 'ocrvox.service'), '# Managed by ubruckhaus.simple-reader (Screen Narrator)\n');
    Directory(p.join(units, 'graphical-session.target.wants')).createSync(recursive: true);
    Link(p.join(units, 'graphical-session.target.wants/ocrvox.service')).createSync('../ocrvox.service');
    final v = (await w.core().call('apps.get', {'id': 'video'}))['app'];
    expect((v['runtime'] as List).firstWhere((r) => r['path'].endsWith('/video-trans'))['markedOurs'], isTrue);
    final n = (await w.core().call('apps.get', {'id': 'narrator'}))['app'];
    expect((n['runtime'] as List).first['markedOurs'], isTrue);
    expect((n['units'] as List).single['enabledBy'], ['graphical-session.target']);
  });
}

