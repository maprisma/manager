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

  group('desktop', () {
    test('from XDG_CURRENT_DESKTOP, overridable', () {
      expect(detectDesktop({'XDG_CURRENT_DESKTOP': 'COSMIC'}), DesktopId.cosmic);
      expect(detectDesktop({'XDG_CURRENT_DESKTOP': 'KDE'}), DesktopId.kde);
      expect(detectDesktop({'XDG_CURRENT_DESKTOP': 'ubuntu:GNOME'}), DesktopId.other);
      expect(detectDesktop({}), DesktopId.other);
      expect(detectDesktop({'XDG_CURRENT_DESKTOP': 'COSMIC', 'MAPRISMA_MANAGER_DESKTOP': 'kde'}), DesktopId.kde);
    });

    test('a desktop param shows the list as that desktop sees it', () async {
      final r = await w.core().call('apps.list', {'desktop': 'kde'});
      expect(r['desktop'], 'kde');
      expect(appOf(r, 'tiling')['supportedHere'], isTrue);
      await expectLater(w.core().call('apps.list', {'desktop': 'mac'}), throwsA(isA<RouteError>()));
    });
  });

  group('paths and settings', () {
    test('XDG variables, relative ones ignored', () {
      final paths = Paths.fromEnvironment({'HOME': '/h', 'XDG_CONFIG_HOME': '/c', 'XDG_DATA_HOME': 'rel'});
      expect(paths.config, '/c');
      expect(paths.data, '/h/.local/share');
      expect(paths.bin, '/h/.local/bin');
      expect(paths.expand('{autostart}/x'), '/c/autostart/x');
      expect(paths.expand('/usr/bin/x'), '/usr/bin/x');
      expect(() => paths.expand('{nope}/x'), throwsArgumentError);
      expect(() => Paths.fromEnvironment({}), throwsStateError);
    });

    test('projects folder: env, then the settings file, then a folder with repos', () {
      final paths = w.paths;
      final a = p.join(w.dir, 'a'), b = p.join(w.dir, 'b');
      Directory(a).createSync();
      Directory(p.join(b, 'maprisma-home')).createSync(recursive: true);
      final none = Settings(const {});
      expect(resolveProjectsDir(paths, {'MAPRISMA_PROJECTS': '/x'}, none, catalogRepos).dir, '/x');
      expect(resolveProjectsDir(paths, {}, Settings({'projectsDir': '~/src'}), catalogRepos), (dir: p.join(w.home, 'src'), source: 'settings'));
      // the first candidate exists but is empty: the one with a repo wins
      expect(resolveProjectsDir(paths, {}, none, catalogRepos, candidates: [a, b]), (dir: b, source: 'found'));
      expect(resolveProjectsDir(paths, {}, none, catalogRepos, candidates: [p.join(w.dir, 'missing'), a]), (dir: a, source: 'default'));
      expect(resolveProjectsDir(paths, {}, none, catalogRepos, candidates: [p.join(w.dir, 'x'), p.join(w.dir, 'y')]),
          (dir: p.join(w.dir, 'x'), source: 'default'));
    });

    test('the settings file is read', () {
      w.writeFile(p.join(w.paths.config, 'maprisma-manager/settings.json'), jsonEncode({'projectsDir': '/somewhere'}));
      final core = CoreService(environment: {...w.env()}..remove('MAPRISMA_PROJECTS'), uid: 1000);
      expect(core.ctx.projectsDir, '/somewhere');
      expect(core.ctx.projectsSource, 'settings');
    });
  });

  group('processes', () {
    test('by exe, by exe folder (swap siblings too), by normalized script path; never by interpreter', () async {
      final paths = w.paths;
      w.process(10, exe: p.join(paths.bin, 'maprisma-wlan-monitor'), argv: [p.join(paths.bin, 'maprisma-wlan-monitor')]);
      w.process(11, exe: '/usr/bin/python3.14', argv: ['python3', '-I', '${paths.bin}/../share/maprisma-wlan-monitor/scripts/wlan-monitor.py']);
      w.process(12, exe: '/usr/bin/python3.14', argv: ['python3', '/elsewhere/wlan-monitor.py']);
      w.process(13, exe: p.join(paths.bin, 'maprisma-wlan-monitor'), uid: 1001); // another user's
      w.process(14, exe: '${paths.lib}/maprisma-theme.old.Ab12/bin/maprisma-theme-core', argv: ['x', 'daemon']);
      w.process(15, exe: '${paths.lib}/maprisma-theme-other/x');
      w.process(16, exe: p.join(paths.bin, 'maprisma-wlan-monitor-tray'));
      final procs = listProcesses(w.proc, uid: 1000);
      expect(procs.map((x) => x.pid), isNot(contains(13)));
      expect(procs.firstWhere((x) => x.pid == 10).startTicks, 4242);
      List<int> pids(String id) => [for (final m in runningFor(findApp(id)!, paths, procs)) m['pid'] as int]..sort();
      expect(pids('wlan'), [10, 11, 16]);
      expect(pids('theme'), [14]);
      final r = await w.core().call('apps.list');
      expect(appOf(r, 'wlan')['running'], 3);
      final kde = await w.core(desktop: 'KDE').call('apps.list');
      expect(appOf(kde, 'wlan')['bar']['running'], isTrue);
    });

    test('a deleted executable still matches', () {
      final paths = w.paths;
      w.process(20, exe: '${paths.lib}/maprisma-launcher/maprisma-launcher (deleted)');
      expect(runningFor(findApp('launcher')!, paths, listProcesses(w.proc, uid: 1000)), hasLength(1));
    });
  });

  group('protocol', () {
    test('frames in and out', () async {
      final core = w.core();
      final hello = jsonDecode(await core.handleAsync(jsonEncode({'id': 1, 'protocol': 1, 'method': 'core.hello'})));
      expect(hello['result']['desktop'], 'cosmic');
      expect(hello['result']['projectsDir'], w.projects);
      final unknown = jsonDecode(await core.handleAsync(jsonEncode({'id': 2, 'protocol': 1, 'method': 'nope'})));
      expect(unknown['error']['code'], 'unknown_route');
      final bad = jsonDecode(await core.handleAsync(jsonEncode({'id': 3, 'protocol': 1, 'method': 'apps.get', 'params': {'id': 'zzz'}})));
      expect(bad['error']['code'], 'not_found');
      final noId = jsonDecode(await core.handleAsync(jsonEncode({'id': 4, 'protocol': 1, 'method': 'apps.get'})));
      expect(noId['error']['code'], 'bad_params');
      final badForce = jsonDecode(await core.handleAsync(jsonEncode({'id': 5, 'protocol': 1, 'method': 'git.fetch', 'params': {'force': 'yes'}})));
      expect(badForce['error']['code'], 'bad_params');
      final broken = jsonDecode(await core.handleAsync('{'));
      expect(broken['error']['code'], 'bad_request');
    });

    test('apps.get has the details, apps.list does not', () async {
      final core = w.core();
      final list = await core.call('apps.list');
      expect(appOf(list, 'wlan').containsKey('data'), isFalse);
      final get = await core.call('apps.get', {'id': 'wlan'});
      expect(get['app']['data'].single['neverDelete'], isTrue);
      expect(get['app']['components'][0]['checks'], isNotEmpty);
    });
  });

  group('CLI', () {
    test('status as a table and as JSON', () async {
      w.install('wlan');
      final out = _Capture();
      expect(await runCli(['status'], service: w.core(), out: out), 0);
      expect(out.text, contains('ID'));
      expect(out.text, matches(RegExp(r'wlan\s+installed')));
      final json = _Capture();
      expect(await runCli(['status', '--json'], service: w.core(), out: json), 0);
      expect(appOf(jsonDecode(json.text), 'wlan')['state'], 'installed');
      final one = _Capture();
      expect(await runCli(['status', 'wlan', '--desktop', 'kde'], service: w.core(), out: one), 0);
      expect(one.text, contains('Desktop: kde'));
      expect(await runCli(['bogus'], service: w.core(), out: _Capture()), 2);
    });

    test('fetch', () async {
      w.repo('maprisma-home');
      final out = _Capture();
      expect(await runCli(['fetch', 'home'], service: w.core(), out: out), 0);
      expect(out.text, contains('skipped: no upstream'));
    });
  });
}

final class _Capture implements IOSink {
  final _b = StringBuffer();
  String get text => _b.toString();
  @override
  void writeln([Object? object = '']) => _b.writeln(object);
  @override
  void write(Object? object) => _b.write(object);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
