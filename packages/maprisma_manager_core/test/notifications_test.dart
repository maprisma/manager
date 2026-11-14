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

  String settingsFile() => p.join(w.home, '.config/maprisma-notifier/settings.json');
  String historyFile() => p.join(w.home, '.local/state/maprisma-notifier/history.jsonl');
  String shellFile() => p.join(w.home, '.config/maprisma-shell/shell.json');
  String cosmicFile() => p.join(w.home, '.config/cosmic/com.system76.CosmicNotifications/v1/do_not_disturb');
  Map<String, dynamic> stored(String f) => jsonDecode(File(f).readAsStringSync()) as Map<String, dynamic>;
  Matcher refused(String code) => throwsA(isA<RouteError>().having((e) => e.code, 'code', code));
  // 12:00 local: outside the default 22:00–07:00 window
  DateTime noon() => DateTime(2026, 11, 13, 12);

  String entry(String app, {bool read = false}) =>
      jsonEncode({'id': 'x', 'time': '2026-11-13T08:12:03Z', 'app': app, 'icon': '', 'summary': 's', 'body': 'b', 'urgency': 1, 'server_id': 1, 'read': read, 'closed': false});

  test('the catalog entry: Maprisma Notifier as the plan has it', () {
    final a = findApp('notifier')!;
    expect(a.name, 'Maprisma Notifier');
    expect(a.kind, 'rust');
    expect(a.desktops, {DesktopId.cosmic, DesktopId.kde, DesktopId.hyprland});
    expect(a.inputs.single.repo, 'maprisma-notifier');
    expect(a.inputs.single.github, 'maprisma/notifier');
    expect(a.open, ['{bin}/maprisma-notifier', '--window']);
    expect(a.components.single.install, ['./install.sh']);
    expect(a.bar.cosmicApplet, 'io.github.ubruckhaus.CosmicMaprismaNotifier');
    expect(a.bar.kdeId, 'maprisma-notifier');
    expect(a.bar.kdeKind, KdeBarKind.tray);
    expect(a.bar.kdeTrayExe, '{bin}/maprisma-notifier-tray');
    expect(a.bar.kdeAutostart, '{autostart}/io.github.ubruckhaus.CosmicMaprismaNotifier.Tray.desktop');
    expect(hyprBarId(a), 'tray:maprisma-notifier');
    expect(a.data.map((d) => d.path), ['{config}/maprisma-notifier', '{state}/maprisma-notifier']);
    expect(a.processes.map((m) => m.path), containsAll(['{bin}/maprisma-notifier', '{bin}/maprisma-notifier-tray', '{bin}/maprisma-notifier-recorder']));
  });

  test('defaults without any file; not installed, not running', () async {
    final r = await w.core(desktop: 'Hyprland', clock: noon).call('notifications.get');
    expect(r['installed'], isFalse);
    expect(r['running'], isFalse);
    expect(r['settings'], {
      'file': settingsFile(),
      'exists': false,
      'dnd': false,
      'dnd_schedule': {'on': false, 'from': '22:00', 'to': '07:00'},
      'dnd_now': false,
      'history_max': 500,
      'history_days': 7,
      'show_count': true,
      'notify_crashes': true,
      'muted_apps': <String>[],
      'hidden_apps': <String>[],
    });
    expect(r.containsKey('ai_helpers'), isFalse);
    expect(r['history'], {'file': historyFile(), 'exists': false, 'count': 0, 'apps': <String>[]});
    expect(r['shell'], {'file': shellFile(), 'exists': false, 'dnd': false, 'position': 'top-right', 'timeout': 5, 'max': 5});
    expect(r['desktop_dnd'], {'where': 'shell', 'on': false});
    expect(r['native'], isNull);
  });

  test('installed and running: the key binary and a tray process', () async {
    w.install('notifier');
    final tray = p.join(w.home, '.local/bin/maprisma-notifier-tray');
    w.process(40, exe: tray, argv: [tray]);
    final r = await w.core(desktop: 'KDE').call('notifications.get');
    expect(r['installed'], isTrue);
    expect(r['running'], isTrue);
    expect(r['desktop_dnd'], {'where': 'recorder'});
    expect(r['shell'], isNull);
  });

  test('invalid values read as the defaults, whole numbers out of range as the nearest end', () async {
    w.writeFile(settingsFile(), jsonEncode({
      'dnd': 'yes',
      'dnd_schedule': {'on': true, 'from': '25:00', 'to': '06:30'},
      'history_max': 99999,
      'history_days': 0,
      'show_count': 1,
      'muted_apps': ['Firefox', 3, ''],
      'hidden_apps': 'x',
      'notify_crashes': 'no',
    }));
    final s = (await w.core(clock: noon).call('notifications.get'))['settings'] as Map;
    expect(s['dnd'], isFalse);
    expect(s['dnd_schedule'], {'on': true, 'from': '22:00', 'to': '06:30'});
    expect(s['history_max'], 5000);
    expect(s['history_days'], 1);
    expect(s['show_count'], isTrue);
    expect(s['muted_apps'], ['Firefox']);
    expect(s['hidden_apps'], isEmpty);
    expect(s['notify_crashes'], isTrue);
    expect(s.containsKey('ai_helper'), isFalse);
  });

  test('crash reports: set, read back; the AI helper is set on the AI page now', () async {
    final core = w.core();
    final r = await core.call('notifications.set', {'notify_crashes': false});
    expect(stored(settingsFile()), {'notify_crashes': false});
    expect((r['settings'] as Map)['notify_crashes'], isFalse);
    for (final bad in [
      {'notify_crashes': 1},
      {'ai_helper': 'codex'},
    ]) {
      await expectLater(core.call('notifications.set', bad), refused('bad_params'), reason: '$bad');
    }
  });

  test('the schedule: a window crossing midnight, a window within the day, from == to', () {
    bool at(int h, int m, String from, String to) => NotificationsService.scheduleActive({'on': true, 'from': from, 'to': to}, DateTime(2026, 1, 1, h, m));
    expect(at(23, 0, '22:00', '07:00'), isTrue);
    expect(at(6, 59, '22:00', '07:00'), isTrue);
    expect(at(7, 0, '22:00', '07:00'), isFalse);
    expect(at(12, 0, '22:00', '07:00'), isFalse);
    expect(at(13, 0, '12:30', '14:00'), isTrue);
    expect(at(14, 0, '12:30', '14:00'), isFalse);
    expect(at(10, 0, '10:00', '10:00'), isFalse);
    expect(NotificationsService.scheduleActive({'on': false, 'from': '00:00', 'to': '23:59'}, DateTime(2026, 1, 1, 12)), isFalse);
  });

  test('set writes only the given keys and keeps unknown ones; nothing changed, nothing written', () async {
    w.writeFile(settingsFile(), jsonEncode({'language': 'de', 'window_size': {'width': 500, 'height': 700}, 'dnd_schedule': {'from': '21:00', 'future': 1}, 'later': true}));
    final core = w.core(desktop: 'Hyprland', clock: noon);
    final r = await core.call('notifications.set', {'history_max': 10, 'history_days': 30, 'muted_apps': [' Firefox ', 'Firefox', 'Slack'], 'dnd_schedule': {'on': true}});
    expect(r['written'], isTrue);
    expect(stored(settingsFile()), {
      'language': 'de',
      'window_size': {'width': 500, 'height': 700},
      'dnd_schedule': {'from': '21:00', 'future': 1, 'on': true},
      'later': true,
      'history_max': 50,
      'history_days': 30,
      'muted_apps': ['Firefox', 'Slack'],
    });
    expect((r['settings'] as Map)['dnd_schedule'], {'on': true, 'from': '21:00', 'to': '07:00'});
    // at noon the schedule's window is not now: Maprisma Shell's do not disturb is written off
    expect(r['applied'], {'where': 'shell', 'on': false});
    expect(stored(shellFile()), {'notifications': {'dnd': false}});
    final before = File(settingsFile()).statSync().modified;
    final again = await core.call('notifications.set', {'history_days': 30});
    expect(again['written'], isFalse);
    expect(again.containsKey('applied'), isFalse);
    expect(File(settingsFile()).statSync().modified, before);
  });

  test('set refuses bad values, unknown keys and a broken file (left as it is)', () async {
    final core = w.core();
    for (final bad in [
      <String, dynamic>{},
      {'dnd': 1},
      {'history_max': 1.5},
      {'history_days': '7'},
      {'muted_apps': 'Firefox'},
      {'hidden_apps': [1]},
      {'hidden_apps': ['x' * 201]},
      {'hidden_apps': [for (var i = 0; i < 501; i++) 'a$i']},
      {'dnd_schedule': {'from': '7:00'}},
      {'dnd_schedule': {'on': 'yes'}},
      {'dnd_schedule': {'start': '07:00'}},
      {'language': 'de'},
    ]) {
      await expectLater(core.call('notifications.set', bad), refused('bad_params'), reason: '$bad');
    }
    expect(File(settingsFile()).existsSync(), isFalse);
    w.writeFile(settingsFile(), '{broken');
    await expectLater(core.call('notifications.set', {'dnd': true}), refused('unreadable'));
    expect(File(settingsFile()).readAsStringSync(), '{broken');
    expect((await core.call('notifications.get'))['settings'], contains('error'));
  });

  test('Hyprland: do not disturb goes to settings.json and shell.json, the rest of shell.json stays', () async {
    w.writeFile(shellFile(), jsonEncode({'wallpaper': '/w.jpg', 'idle': {'lock': 60}, 'notifications': {'position': 'top', 'future': 2}}));
    final core = w.core(desktop: 'Hyprland', clock: noon);
    final r = await core.call('notifications.set', {'dnd': true});
    expect(r['applied'], {'where': 'shell', 'on': true});
    expect(stored(settingsFile()), {'dnd': true});
    expect(stored(shellFile()), {'wallpaper': '/w.jpg', 'idle': {'lock': 60}, 'notifications': {'position': 'top', 'future': 2, 'dnd': true}});
    final g = await core.call('notifications.get');
    expect((g['settings'] as Map)['dnd_now'], isTrue);
    expect(g['desktop_dnd'], {'where': 'shell', 'on': true});
  });

  test('Hyprland: a broken shell.json keeps the settings write and says why', () async {
    w.writeFile(shellFile(), '{nope');
    final r = await w.core(desktop: 'Hyprland', clock: noon).call('notifications.set', {'dnd': true});
    expect(stored(settingsFile()), {'dnd': true});
    expect(r['applied'], containsPair('error', isNotEmpty));
    expect(File(shellFile()).readAsStringSync(), '{nope');
  });

  test('COSMIC: do not disturb goes to cosmic-config, with the schedule\'s window', () async {
    final night = w.core(desktop: 'COSMIC', clock: () => DateTime(2026, 11, 13, 23, 30));
    var r = await night.call('notifications.set', {'dnd_schedule': {'on': true}});
    expect(r['applied'], {'where': 'cosmic', 'on': true});
    expect(File(cosmicFile()).readAsStringSync(), 'true');
    r = await w.core(desktop: 'COSMIC', clock: noon).call('notifications.set', {'dnd': false});
    expect(File(cosmicFile()).readAsStringSync(), 'false');
    final g = await w.core(desktop: 'COSMIC', clock: noon).call('notifications.get');
    expect(g['desktop_dnd'], {'where': 'cosmic', 'on': false});
    expect(File(shellFile()).existsSync(), isFalse);
  });

  test('KDE: do not disturb only in settings.json (the recorder inhibits)', () async {
    final r = await w.core(desktop: 'KDE', clock: noon).call('notifications.set', {'dnd': true});
    expect(r['applied'], {'where': 'recorder', 'on': true});
    expect(stored(settingsFile()), {'dnd': true});
    expect(File(shellFile()).existsSync(), isFalse);
    expect(File(cosmicFile()).existsSync(), isFalse);
  });

  test('COSMIC and KDE: their own notification settings', () async {
    w.fake('cosmic-settings', r'echo "$*" >> "$HOME/cosmic.log"');
    w.fake('setsid', r'exec "$@"');
    final cosmic = w.core(desktop: 'COSMIC');
    // cosmic-settings 1.11 has no notifications page: no link (the section is left out)
    expect((await cosmic.call('notifications.get'))['native'], isNull);
    expect((await w.core(desktop: 'KDE').call('notifications.get'))['native'], {'name': 'System Settings', 'available': false});
    expect(await cosmic.call('native.get', {'page': 'notifications'}), containsPair('links', isEmpty));
    expect(cosmic.native.links('notifications'), isEmpty);
    // every COSMIC link is a page cosmic-settings 1.11 knows (`cosmic-settings --help`)
    const known = {
      'accessibility', 'accessibility-magnifier', 'accessibility-osk', 'about', 'appearance', 'applications', 'bluetooth', 'date-time',
      'default-apps', 'desktop', 'displays', 'dock', 'dock-applet', 'input', 'keyboard', 'legacy-applications', 'mouse', 'network', 'panel',
      'panel-applet', 'power', 'region-language', 'sound', 'startup-apps', 'system', 'time', 'touchpad', 'users', 'vpn', 'wallpaper',
      'window-management', 'wired', 'wireless', 'workspaces',
    };
    for (final page in NativeSettings.pages) {
      for (final l in cosmic.native.links(page)) {
        expect(l.argv.first, 'cosmic-settings');
        expect(known, contains(l.argv[1]), reason: page);
      }
    }
    expect(w.core(desktop: 'KDE').native.links('notifications').single.argv, ['systemsettings', 'kcm_notifications']);
    expect(w.core(desktop: 'Hyprland').native.links('notifications'), isEmpty);
  });

  test('set_shell: position, timeout, max (clamped), changed keys only, Hyprland only', () async {
    w.writeFile(shellFile(), jsonEncode({'wallpaper': '/w.jpg', 'notifications': {'dnd': true, 'max': 3}}));
    final core = w.core(desktop: 'Hyprland');
    final r = await core.call('notifications.set_shell', {'position': 'bottom-left', 'timeout': 99});
    expect(r['shell'], allOf(containsPair('position', 'bottom-left'), containsPair('timeout', 60), containsPair('max', 3), containsPair('dnd', true)));
    expect(stored(shellFile()), {'wallpaper': '/w.jpg', 'notifications': {'dnd': true, 'max': 3, 'position': 'bottom-left', 'timeout': 60}});
    await core.call('notifications.set_shell', {'max': 0});
    expect((stored(shellFile())['notifications'] as Map)['max'], 1);
    await core.call('notifications.set_shell', {'max': 2.6});
    expect((stored(shellFile())['notifications'] as Map)['max'], 3);
    for (final bad in [<String, dynamic>{}, {'position': 'middle'}, {'timeout': '5'}, {'max': double.nan}, {'dnd': 'on'}, {'other': 1}]) {
      await expectLater(core.call('notifications.set_shell', bad), refused('bad_params'), reason: '$bad');
    }
    await expectLater(w.core(desktop: 'COSMIC').call('notifications.set_shell', {'max': 2}), refused('unavailable'));
    expect(File(settingsFile()).existsSync(), isFalse);
  });

  test('shell.json read as Maprisma Shell reads it: numbers rounded and clamped, the rest per key', () async {
    w.writeFile(shellFile(), jsonEncode({'notifications': {'dnd': 'true', 'position': 'centre', 'timeout': 7.6, 'max': 40}}));
    var s = (await w.core(desktop: 'Hyprland').call('notifications.get'))['shell'] as Map;
    expect(s, allOf(containsPair('dnd', false), containsPair('position', 'top-right'), containsPair('timeout', 8), containsPair('max', 10)));
    w.writeFile(shellFile(), jsonEncode({'notifications': {'dnd': true, 'timeout': '9', 'max': -3}}));
    s = (await w.core(desktop: 'Hyprland').call('notifications.get'))['shell'] as Map;
    expect(s, allOf(containsPair('dnd', true), containsPair('timeout', 5), containsPair('max', 1)));
  });

  test('the history\'s app names: distinct, sorted, broken lines skipped', () async {
    w.writeFile(historyFile(), [entry('Slack'), entry('firefox'), '{broken', entry('Slack'), jsonEncode({'app': 5}), entry('Discord'), ''].join('\n'));
    final h = (await w.core().call('notifications.get'))['history'] as Map;
    expect(h['apps'], ['Discord', 'firefox', 'Slack']);
    expect(h['count'], 5);
  });

  test('a big history is read from its last 4 MB only', () async {
    final filler = '${entry('Old')}\n';
    final buf = StringBuffer();
    while (buf.length < NotificationsService.historyReadMax + 1024) {
      buf.write(filler);
    }
    // the newest entries
    buf.write('${entry('New')}\n');
    w.writeFile(historyFile(), buf.toString());
    final h = (await w.core().call('notifications.get'))['history'] as Map;
    expect(h['partial'], isTrue);
    expect(h['apps'], ['New', 'Old']);
    expect(h['count'], lessThan(buf.length ~/ filler.length));
  });

  test('clear_history empties the file in place (its mode stays); a link is refused', () async {
    w.writeFile(historyFile(), '${entry('Slack')}\n', mode: '600');
    final core = w.core();
    final r = await core.call('notifications.clear_history');
    expect(r['cleared'], isTrue);
    expect(File(historyFile()).lengthSync(), 0);
    expect(File(historyFile()).statSync().mode & 0x1ff, 0x180);
    expect((r['history'] as Map)['apps'], isEmpty);
    File(historyFile()).deleteSync();
    expect((await core.call('notifications.clear_history'))['cleared'], isFalse);
    final other = p.join(w.home, 'other.jsonl');
    w.writeFile(other, 'keep');
    Link(historyFile()).createSync(other);
    await expectLater(core.call('notifications.clear_history'), refused('unavailable'));
    expect(File(other).readAsStringSync(), 'keep');
  });

  test('clear_history waits for the Notifier\'s history.lock (it never lands inside a change)', () async {
    w.writeFile(historyFile(), '${entry('Slack')}\n', mode: '600');
    final dir = p.dirname(historyFile());
    final ready = p.join(w.home, 'holder.ready');
    // As history.rs `modify` does it: flock(LOCK_EX) on history.lock, read, write back atomically.
    final holder = await Process.start('/usr/bin/python3', ['-I', '-c', r"""
import fcntl, os, sys, time
d, ready = sys.argv[1], sys.argv[2]
lock = open(os.path.join(d, 'history.lock'), 'w')
fcntl.flock(lock, fcntl.LOCK_EX)
entries = open(os.path.join(d, 'history.jsonl')).read()
open(ready, 'w').close()
time.sleep(0.4)
tmp = os.path.join(d, 'history.jsonl.tmp')
open(tmp, 'w').write(entries)
os.rename(tmp, os.path.join(d, 'history.jsonl'))
fcntl.flock(lock, fcntl.LOCK_UN)
""", dir, ready], includeParentEnvironment: false, environment: {'PATH': '/usr/bin:/bin'});
    for (var i = 0; i < 200 && !File(ready).existsSync(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(File(ready).existsSync(), isTrue);
    final watch = Stopwatch()..start();
    final r = await w.core().call('notifications.clear_history');
    expect(watch.elapsedMilliseconds, greaterThan(200));
    expect(await holder.exitCode, 0);
    // cleared after the Notifier's write, not before it (which would bring the entries back)
    expect(r['cleared'], isTrue);
    expect(File(historyFile()).lengthSync(), 0);
  });
}
