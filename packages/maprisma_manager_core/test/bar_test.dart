import 'dart:convert';
import 'dart:io';

import 'package:maprisma_manager_core/maprisma_manager_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

const _c = 'io.github.ubruckhaus.CosmicMaprisma';

/// The real files' format on this machine (2026-11-09): 4-space indent, trailing commas, no
/// newline at the end.
const realWings = 'Some(([\n'
    '    "com.system76.CosmicAppletWorkspaces",\n'
    '    "${_c}Launcher",\n'
    '    "$_c",\n'
    '    "${_c}Theme",\n'
    '], [\n'
    '    "${_c}Home",\n'
    '    "${_c}VideoTranslator",\n'
    '    "${_c}Narrator",\n'
    '    "${_c}BluetoothMonitor",\n'
    '    "com.system76.CosmicAppletStatusArea",\n'
    '    "com.system76.CosmicAppletTiling",\n'
    '    "com.system76.CosmicAppletAudio",\n'
    '    "com.system76.CosmicAppletBluetooth",\n'
    '    "com.system76.CosmicAppletNetwork",\n'
    '    "com.system76.CosmicAppletPower",\n'
    ']))';
const realCenter = 'Some([\n'
    '    "com.system76.CosmicAppletNotifications",\n'
    '    "${_c}HueLights",\n'
    '    "com.system76.CosmicAppletTime",\n'
    '    "${_c}LlmMonitor",\n'
    '    "${_c}WlanMonitor",\n'
    '])';

void main() {
  late World w;
  setUp(() {
    w = World.create();
    w.fake('pacman', 'exit 1');
  });
  tearDown(() => w.dispose());

  String panelDir([String instance = 'Panel']) => p.join(w.paths.config, 'cosmic/com.system76.CosmicPanel.$instance/v1');
  String wingsFile([String i = 'Panel']) => p.join(panelDir(i), 'plugins_wings');
  String centerFile([String i = 'Panel']) => p.join(panelDir(i), 'plugins_center');
  void realPanel() {
    w.writeFile(wingsFile(), realWings);
    w.writeFile(centerFile(), realCenter);
  }

  CoreService cosmic() => w.core()..followPanel = (_) async => {'panel': null, 'note': 'test'};
  List<String> ids(Map<String, dynamic> bar, String area) => [for (final e in (bar['areas'][area] as List)) e['id'] as String];

  group('RON', () {
    test('the real files read and render back byte for byte', () {
      final wd = RonListDoc.parse(realWings, count: 2), cd = RonListDoc.parse(realCenter, count: 1);
      expect(wd.values[0], hasLength(4));
      expect(wd.values[1].last, 'com.system76.CosmicAppletPower');
      expect(wd.render(wd.values), realWings);
      expect(cd.render(cd.values), realCenter);
    });

    test('a changed list keeps the style: indent, trailing commas, no newline at the end', () {
      final cd = RonListDoc.parse(realCenter, count: 1);
      final v = [...cd.values[0]]..remove('${_c}WlanMonitor');
      v.insert(3, '${_c}WlanMonitor');
      final out = cd.render([v]);
      expect(out, realCenter.replaceAll('    "${_c}LlmMonitor",\n    "${_c}WlanMonitor",\n', '    "${_c}WlanMonitor",\n    "${_c}LlmMonitor",\n'));
      expect(out.endsWith('])'), isTrue);
      // only the changed list is rewritten
      final wd = RonListDoc.parse(realWings, count: 2);
      final right = [...wd.values[1]]..removeAt(0);
      final w2 = wd.render([wd.values[0], right]);
      expect(w2, realWings.replaceFirst('    "${_c}Home",\n', ''));
    });

    test('comments stay: outside the lists, and with the item they were written before', () {
      const text = '// the panel\nSome([\n    /* clock */ "com.system76.CosmicAppletTime",\n    // ours\n    "a",\n    "b",\n    // end\n]) // tail';
      final d = RonListDoc.parse(text, count: 1);
      expect(d.values, [['com.system76.CosmicAppletTime', 'a', 'b']]);
      final out = d.render([['b', 'a', 'com.system76.CosmicAppletTime']]);
      expect(out, '// the panel\nSome([\n    "b",\n    // ours\n    "a",\n    /* clock */\n    "com.system76.CosmicAppletTime",\n    // end\n]) // tail');
      expect(RonListDoc.parse(out, count: 1).values, [['b', 'a', 'com.system76.CosmicAppletTime']]);
    });

    test('None, empty, single-line (the system default) and broken files', () {
      expect(RonListDoc.parse('None', count: 2).isNone, isTrue);
      expect(RonListDoc.parse('', count: 1).isNone, isTrue);
      expect(RonListDoc.parse('None', count: 1).render([['a']]), 'Some([\n    "a",\n])');
      expect(RonListDoc.parse('None', count: 2).render([['a'], []]), 'Some(([\n    "a",\n], []))');
      const single = 'Some(["com.system76.CosmicAppletTime"])';
      expect(RonListDoc.parse(single, count: 1).render([['x', 'com.system76.CosmicAppletTime']]), 'Some(["x", "com.system76.CosmicAppletTime"])');
      expect(RonListDoc.parse('Some([\n])', count: 1).render([['a']]), 'Some([\n    "a",\n])');
      expect(() => RonListDoc.parse('Some(["a"', count: 1), throwsFormatException);
      expect(() => RonListDoc.parse('Some(["a" "b"])', count: 1), throwsFormatException);
      expect(() => RonListDoc.parse('Some(["a"])', count: 2), throwsFormatException);
      expect(() => RonListDoc.parse('Some(([], [], []))', count: 2), throwsFormatException);
      expect(RonListDoc.parse(r'Some(["a\"b"])', count: 1).render([[r'a"b', 'c']]), r'Some(["a\"b", "c"])');
    });
  });

  group('RON after the review', () {
    test('ids are rewritten as they were spelled; escapes decode; unknown escapes are refused', () {
      const text = 'Some([\n    "a\\u{62}",\n    "c",\n])';
      final d = RonListDoc.parse(text, count: 1);
      expect(d.values, [['ab', 'c']]);
      expect(d.render([['c', 'ab']]), 'Some([\n    "c",\n    "a\\u{62}",\n])');
      expect(() => RonListDoc.parse(r'Some(["a\q"])', count: 1), throwsFormatException);
      expect(RonListDoc.parse('None', count: 1).render([['x\ny']]), r'Some([' '\n    "x\\ny",\n])');
    });

    test('a comment moves with its id between the wings', () {
      const text = 'Some(([\n    // mine\n    "a",\n], [\n    "b",\n]))';
      final d = RonListDoc.parse(text, count: 2);
      expect(d.render([[], ['a', 'b']]), 'Some(([], [\n    // mine\n    "a",\n    "b",\n]))');
    });

    test('a commented None keeps its comments', () {
      expect(RonListDoc.parse('// off\nNone // for now', count: 1).render([['a']]), '// off\nSome([\n    "a",\n]) // for now');
    });
  });

  group('layout', () {
    test('default places: left and centre at the end, right before COSMIC\'s applets', () {
      final l = Layout(['a'], ['t'], ['${_c}Home', 'com.system76.CosmicAppletAudio', 'com.system76.CosmicAppletPower']);
      expect(cosmicDefaultIndex(l, Area.left, 'x'), 1);
      expect(cosmicDefaultIndex(l, Area.center, 'x'), 1);
      expect(cosmicDefaultIndex(l, Area.right, 'x'), 1);
      expect(cosmicDefaultIndex(Layout([], [], ['foreign.Applet']), Area.right, 'x'), 1);
      l.put('a', Area.right, 0);
      expect(l.toJson(), {'left': <String>[], 'center': ['t'], 'right': ['a', '${_c}Home', 'com.system76.CosmicAppletAudio', 'com.system76.CosmicAppletPower']});
      l.put('a', Area.center, 99);
      expect(l.areas[Area.center], ['t', 'a']);
      expect(l.remove('a'), isTrue);
      expect(l.remove('a'), isFalse);
    });
  });

  group('COSMIC', () {
    test('bar.get: areas in order, foreign entries kept and named from their desktop file', () async {
      realPanel();
      w.writeFile(w.paths.sys('/usr/share/applications/com.system76.CosmicAppletTime.desktop'), '[Desktop Entry]\nName=Date, Time & Calendar\nIcon=com.system76.CosmicAppletTime\n');
      final r = await cosmic().call('bar.get');
      expect(r['panel'], 'Panel');
      expect(ids(r, 'center'), ['com.system76.CosmicAppletNotifications', '${_c}HueLights', 'com.system76.CosmicAppletTime', '${_c}LlmMonitor', '${_c}WlanMonitor']);
      final time = (r['areas']['center'] as List)[2];
      expect(time, {'id': 'com.system76.CosmicAppletTime', 'ours': false, 'name': 'Date, Time & Calendar', 'iconName': 'com.system76.CosmicAppletTime'});
      final wlan = (r['areas']['center'] as List)[4];
      expect(wlan, containsPair('app', 'wlan'));
      expect(wlan['iconName'], '${_c}WlanMonitor-symbolic');
      expect(r['out'], isEmpty);
      expect(r['revision'], isA<String>());
    });

    test('place, move (within and between files), take out: foreign ids kept, style kept, backups', () async {
      realPanel();
      final core = cosmic();
      // one to the left within the centre
      var r = await core.call('bar.move', {'app': 'wlan', 'area': 'center', 'index': 3});
      expect(r['panels'][0]['written'], ['plugins_center']);
      expect(File(centerFile()).readAsStringSync(), realCenter.replaceAll('    "${_c}LlmMonitor",\n    "${_c}WlanMonitor",\n', '    "${_c}WlanMonitor",\n    "${_c}LlmMonitor",\n'));
      expect(File(wingsFile()).readAsStringSync(), realWings);
      // and back: the exact original
      await core.call('bar.move', {'app': 'wlan', 'area': 'center', 'index': 4});
      expect(File(centerFile()).readAsStringSync(), realCenter);
      // out and in again (default: the end of the centre)
      r = await core.call('bar.remove', {'app': 'wlan'});
      expect(r['placed'], isFalse);
      expect(File(centerFile()).readAsStringSync(), isNot(contains('WlanMonitor')));
      await core.call('bar.place', {'app': 'wlan', 'area': 'center'});
      expect(File(centerFile()).readAsStringSync(), realCenter);
      // to the right wing: before COSMIC's own applets
      r = await core.call('bar.place', {'app': 'wlan', 'area': 'right'});
      expect(r['panels'][0]['written'], ['plugins_center', 'plugins_wings']); // the file that loses it first
      final bar = await core.call('bar.get');
      expect(ids(bar, 'right').sublist(3, 6), ['${_c}BluetoothMonitor', '${_c}WlanMonitor', 'com.system76.CosmicAppletStatusArea']);
      expect(File(wingsFile()).readAsStringSync(), endsWith('    "com.system76.CosmicAppletPower",\n]))'));
      // a foreign entry moves too, by its id
      await core.call('bar.move', {'entry': 'com.system76.CosmicAppletTime', 'area': 'left', 'index': 0});
      expect(ids(await core.call('bar.get'), 'left').first, 'com.system76.CosmicAppletTime');
      // backups: both files as they were before each change
      final backups = Directory(p.join(w.paths.managerState, 'backups')).listSync().whereType<Directory>().toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      expect(backups, hasLength(6));
      expect(File(p.join(backups.first.path, 'plugins_center')).readAsStringSync(), realCenter);
      expect(File(p.join(backups.first.path, 'plugins_wings')).readAsStringSync(), realWings);
      // no temporary files left
      expect(Directory(panelDir()).listSync().map((e) => p.basename(e.path)).toSet(), {'plugins_wings', 'plugins_center'});
      // placing where it already is changes nothing
      final again = await core.call('bar.place', {'app': 'wlan', 'area': 'right'});
      expect(again['panels'][0]['written'], isEmpty);
      expect(again.containsKey('reload'), isFalse);
    });

    test('a change since bar.get is refused with "changed"; nothing is written', () async {
      realPanel();
      final core = cosmic();
      final seen = await core.call('bar.get');
      // someone else (COSMIC Settings) edits the panel
      File(centerFile()).writeAsStringSync(realCenter.replaceAll('    "${_c}HueLights",\n', ''));
      await expectLater(
        core.call('bar.move', {'app': 'wlan', 'area': 'left', 'index': 0, 'revision': seen['revision']}),
        throwsA(isA<RouteError>().having((e) => e.code, 'code', 'changed')),
      );
      expect(File(wingsFile()).readAsStringSync(), realWings);
      // with the new revision it goes through
      final now = await core.call('bar.get');
      await core.call('bar.move', {'app': 'wlan', 'area': 'left', 'index': 0, 'revision': now['revision']});
      expect(ids(await core.call('bar.get'), 'left').first, '${_c}WlanMonitor');
    });

    test('a file that changes between reading and writing is not overwritten', () async {
      realPanel();
      final seen = CosmicPanelConfig.read(w.paths, 'Panel');
      File(wingsFile()).writeAsStringSync('$realWings ');
      final l = seen.layout..put('${_c}WlanMonitor', Area.left, 0);
      await expectLater(writeCosmic(w.paths, seen, l), throwsA(isA<RouteError>().having((e) => e.code, 'code', 'changed')));
      expect(File(wingsFile()).readAsStringSync(), '$realWings ');
      expect(File(centerFile()).readAsStringSync(), realCenter);
    });

    test('the revision follows the system default while there is no user file', () {
      final sys = w.paths.sys('/usr/share/cosmic/com.system76.CosmicPanel.Panel/v1/plugins_center');
      w.writeFile(sys, 'Some(["com.system76.CosmicAppletTime"])');
      final a = CosmicPanelConfig.read(w.paths, 'Panel').revision;
      w.writeFile(sys, 'Some(["com.system76.CosmicAppletTime", "x"])');
      expect(CosmicPanelConfig.read(w.paths, 'Panel').revision, isNot(a));
    });

    test('changes at the same time in one process run one after the other', () async {
      realPanel();
      final core = cosmic();
      await Future.wait([
        core.call('bar.move', {'app': 'wlan', 'area': 'left', 'index': 0}),
        core.call('bar.move', {'app': 'hue', 'area': 'right', 'index': 0}),
        core.call('bar.remove', {'app': 'llm'}),
      ]);
      final bar = await core.call('bar.get');
      expect(ids(bar, 'left').first, '${_c}WlanMonitor');
      expect(ids(bar, 'right').first, '${_c}HueLights');
      expect(ids(bar, 'center'), ['com.system76.CosmicAppletNotifications', 'com.system76.CosmicAppletTime']);
      final wanted = jsonDecode(File(p.join(w.paths.managerState, 'bar.json')).readAsStringSync())['cosmic'] as Map;
      expect(wanted.keys, unorderedEquals(['wlan', 'hue', 'llm']));
    });

    test('bar.apply puts an icon back into the panel it was put into', () async {
      realPanel();
      w.writeFile(p.join(w.paths.config, 'cosmic/com.system76.CosmicPanel/v1/entries'), '["Panel", "Dock"]');
      w.writeFile(centerFile('Dock'), 'Some([\n    "com.system76.CosmicAppList",\n])');
      final core = cosmic();
      await core.call('bar.place', {'app': 'home', 'area': 'center', 'panel': 'Dock'});
      final dock = File(centerFile('Dock')).readAsStringSync();
      w.writeFile(centerFile('Dock'), 'Some([\n    "com.system76.CosmicAppList",\n])');
      expect((await core.call('bar.apply'))['changed'], ['home']);
      expect(File(centerFile('Dock')).readAsStringSync(), dock);
      expect(File(wingsFile()).readAsStringSync(), realWings); // still in the Panel's right wing, untouched
    });

    test('missing user files: the system default is read; the first change writes user files', () async {
      w.writeFile(w.paths.sys('/usr/share/cosmic/com.system76.CosmicPanel.Panel/v1/plugins_wings'), 'Some((["com.system76.CosmicPanelWorkspacesButton"],["com.system76.CosmicAppletPower"]))\n');
      w.writeFile(w.paths.sys('/usr/share/cosmic/com.system76.CosmicPanel.Panel/v1/plugins_center'), 'Some(["com.system76.CosmicAppletTime"])');
      final core = cosmic();
      final r = await core.call('bar.get');
      expect(r['files'], {'plugins_wings': 'system', 'plugins_center': 'system'});
      expect(ids(r, 'right'), ['com.system76.CosmicAppletPower']);
      await core.call('bar.place', {'app': 'hue', 'area': 'center'});
      expect(File(centerFile()).readAsStringSync(), 'Some([\n    "com.system76.CosmicAppletTime",\n    "${_c}HueLights",\n])');
      expect(File(wingsFile()).existsSync(), isFalse); // unchanged: still the default
      final backup = Directory(p.join(w.paths.managerState, 'backups')).listSync().single.path;
      expect(File(p.join(backup, 'files')).readAsStringSync(), contains('\tmissing'));
    });

    test('a None wings file gets wings when an icon goes there', () async {
      w.writeFile(wingsFile(), 'None');
      w.writeFile(centerFile(), realCenter);
      await cosmic().call('bar.place', {'app': 'home', 'area': 'right'});
      expect(File(wingsFile()).readAsStringSync(), 'Some(([], [\n    "${_c}Home",\n]))');
    });

    test('panel instances from the entries file; taking out removes the id from every panel', () async {
      realPanel();
      w.writeFile(p.join(w.paths.config, 'cosmic/com.system76.CosmicPanel/v1/entries'), '[\n    "Panel",\n    "Dock",\n]');
      w.writeFile(centerFile('Dock'), 'Some([\n    "com.system76.CosmicAppList",\n    "${_c}WlanMonitor",\n])');
      final core = cosmic();
      expect(cosmicInstances(w.paths), ['Panel', 'Dock']);
      final dock = await core.call('bar.get', {'panel': 'Dock'});
      expect(ids(dock, 'center'), ['com.system76.CosmicAppList', '${_c}WlanMonitor']);
      await expectLater(core.call('bar.get', {'panel': 'Nope'}), throwsA(isA<RouteError>()));
      await core.call('bar.remove', {'app': 'wlan'});
      expect(File(centerFile('Dock')).readAsStringSync(), 'Some([\n    "com.system76.CosmicAppList",\n])');
      expect(File(centerFile()).readAsStringSync(), isNot(contains('Wlan')));
    });

    test('an unreadable file: bar.get reports it, changes are refused', () async {
      w.writeFile(wingsFile(), 'Some(([ "x"');
      w.writeFile(centerFile(), realCenter);
      final core = cosmic();
      expect((await core.call('bar.get'))['error'], contains('plugins_wings'));
      await expectLater(core.call('bar.place', {'app': 'wlan', 'area': 'left'}), throwsA(isA<RouteError>().having((e) => e.code, 'code', 'unreadable')));
      expect(File(centerFile()).readAsStringSync(), realCenter);
    });

    test('bad params', () async {
      realPanel();
      final core = cosmic();
      Matcher code(String c) => throwsA(isA<RouteError>().having((e) => e.code, 'code', c));
      await expectLater(core.call('bar.place', {'app': 'wlan', 'area': 'top'}), code('bad_params'));
      await expectLater(core.call('bar.place', {'app': 'nope', 'area': 'left'}), code('not_found'));
      await expectLater(core.call('bar.place', {'app': 'maprisma', 'area': 'left'}), code('no_bar_icon'));
      await expectLater(core.call('bar.move', {'app': 'wlan', 'area': 'left'}), code('bad_params'));
      await expectLater(core.call('bar.move', {'app': 'wlan', 'area': 'left', 'index': -1}), code('bad_params'));
    });

    test('the wanted state is kept and put back after an installer changed the panel', () async {
      realPanel();
      final core = cosmic();
      await core.call('bar.move', {'app': 'wlan', 'area': 'left', 'index': 1});
      await core.call('bar.remove', {'app': 'hue'});
      final wanted = jsonDecode(File(p.join(w.paths.managerState, 'bar.json')).readAsStringSync());
      expect(wanted['cosmic'], {
        'wlan': {'placed': true, 'area': 'left', 'index': 1},
        'hue': {'placed': false},
      });
      final mine = File(wingsFile()).readAsStringSync();
      // an "install" puts the panel back to how it was
      realPanel();
      final r = await core.call('bar.apply');
      expect(r['changed'], unorderedEquals(['wlan', 'hue']));
      expect(File(wingsFile()).readAsStringSync(), mine);
      expect(File(centerFile()).readAsStringSync(), isNot(contains('HueLights')));
      expect((await core.call('bar.apply'))['changed'], isEmpty);
    });

    test('status: in the panel = starts at login; running = the applet is a child of cosmic-panel', () async {
      realPanel();
      w.install('wlan');
      w.process(500, exe: '/usr/bin/cosmic-panel');
      w.process(501, exe: p.join(w.paths.bin, 'maprisma-wlan-monitor'), ppid: 500);
      w.process(502, exe: p.join(w.paths.bin, 'maprisma-llm-monitor'), ppid: 1); // a window, not the applet
      final r = await w.core().call('apps.list');
      expect(appOf(r, 'wlan')['bar'], allOf(containsPair('startsAtLogin', true), containsPair('running', true), containsPair('visible', true), containsPair('zone', 'center')));
      expect(appOf(r, 'llm')['bar'], allOf(containsPair('running', false), containsPair('visible', false)));
    });
  });

  group('the panel follows', () {
    ProcInfo pr(int pid, {int? ppid, int start = 1, String exe = '/usr/bin/x'}) => ProcInfo(pid, 1000, exe, const [], start, ppid: ppid);

    test('reacted: a child of cosmic-panel started after the write', () async {
      final before = [pr(10, exe: '/usr/bin/cosmic-panel'), pr(11, ppid: 10)];
      var calls = 0;
      final r = await followPanel(() => ++calls < 3 ? before : [...before, pr(12, ppid: 10, start: 9)], before, step: Duration.zero);
      expect(r, {'panel': 10, 'reacted': true, 'restarted': false});
    });

    test('no reaction: the panel is restarted once by its pid and comes back', () async {
      final before = [pr(10, exe: '/usr/bin/cosmic-panel'), pr(11, ppid: 10)];
      final killed = <int>[];
      final r = await followPanel(
        () => killed.isEmpty ? before : [pr(20, exe: '/usr/bin/cosmic-panel', start: 5)],
        before,
        wait: const Duration(milliseconds: 20),
        step: Duration.zero,
        kill: (pid) {
          killed.add(pid);
          return true;
        },
      );
      expect(killed, [10]);
      expect(r, {'panel': 20, 'reacted': false, 'restarted': true, 'back': true});
    });

    test('a panel process that ran before is no proof of coming back; several panels: none is killed', () async {
      final before = [pr(10, exe: '/usr/bin/cosmic-panel'), pr(30, exe: '/usr/bin/cosmic-panel')];
      final killed = <int>[];
      final r = await followPanel(() => before, before, wait: Duration.zero, back: Duration.zero, step: Duration.zero, kill: (pid) {
        killed.add(pid);
        return true;
      });
      expect(killed, isEmpty);
      expect(r['error'], contains('several'));
    });

    test('a panel that doesn\'t come back is reported; no panel at all is a note', () async {
      final before = [pr(10, exe: '/usr/bin/cosmic-panel')];
      final r = await followPanel(() => before, before, wait: Duration.zero, back: const Duration(milliseconds: 20), step: Duration.zero, kill: (_) => true);
      expect(r['back'], isFalse);
      expect(r['error'], contains('did not come back'));
      expect((await followPanel(() => const [], const []))['panel'], isNull);
    });
  });

  group('KDE', () {
    late String state;
    void plasma(List<Map<String, dynamic>> widgets) {
      state = p.join(w.dir, 'plasma.json');
      File(state).writeAsStringSync(jsonEncode(widgets));
      final fake = p.join(w.fakeBin, 'qdbus6');
      File(p.join(Directory.current.path, 'test/fake_qdbus6.py')).copySync(fake);
      chmod(fake, '755');
    }

    Map<String, dynamic> widget({int id = 7, List<String>? left, List<String>? center, List<String>? right, List<String>? hidden}) => {
      'panel': 1, 'widget': id, 'screen': 0, 'location': 'top',
      'zoneLeft': left, 'zoneCenter': center, 'zoneRight': right, 'hidden': hidden,
    };
    List<Map<String, dynamic>> stored() => (jsonDecode(File(state).readAsStringSync()) as List).cast<Map<String, dynamic>>();
    CoreService kde({Map<String, String> extra = const {}}) => w.core(desktop: 'KDE', extra: {'FAKE_PLASMA': state, ...extra});
    String autostart(String app) => w.paths.expand(findApp(app)!.bar.kdeAutostart!);

    test('the scripts use the General group, StringLists and the widget id', () {
      final read = kdeReadScript();
      expect(read, contains("w.readConfig(key, [])")); // a list default: KConfig decodes a StringList
      expect(read, contains('w.configKeys'));
      expect(read, contains("widgets('com.maprisma.panel')"));
      expect(read, contains("currentConfigGroup = ['General']"));
      final write = kdeWriteScript(7, {'zoneLeft': ['a']}, {'zoneLeft': null});
      expect(write, contains('ws[j].id !== 7'));
      expect(write, contains('writeConfig(key, want[key])'));
      expect(write, contains('var want = {"zoneLeft":["a"]};'));
    });

    test('bar.get: the zones as the widget shows them (fixed entries, running trays, hidden left out)', () async {
      plasma([widget(left: ['maprisma-wlan-monitor'], right: ['maprisma-home'], hidden: ['maprisma-hue-lights'])]);
      w.install('llm');
      w.process(600, exe: p.join(w.paths.bin, 'maprisma-llm-monitor-tray'));
      final r = await kde().call('bar.get');
      expect(r['kind'], 'maprismaIcons');
      expect(ids(r, 'left'), ['maprisma-wlan-monitor', 'maprisma-launcher', 'maprisma-llm-monitor']);
      expect(ids(r, 'center'), ['clock']);
      expect(ids(r, 'right'), ['maprisma-home']);
      expect((r['areas']['center'] as List).single, {'id': 'clock', 'ours': false, 'name': 'Clock', 'shown': true});
      expect((r['out'] as List).map((e) => e['app']), contains('hue'));
      expect(File('$state.log').readAsStringSync(), contains("currentConfigGroup = ['General']"));
    });

    test('place / move / take out write the zones and the hidden list, deduplicated, and the autostart flag', () async {
      plasma([widget(left: ['maprisma-wlan-monitor', 'maprisma-launcher'], center: ['clock', 'maprisma-wlan-monitor'], right: [])]);
      w.install('wlan');
      w.writeFile(autostart('wlan'), '[Desktop Entry]\nExec=x\n');
      final core = kde();
      var r = await core.call('bar.move', {'app': 'wlan', 'area': 'right', 'index': 0});
      expect(r['area'], 'right');
      expect(stored().single, allOf(
        containsPair('zoneLeft', ['maprisma-launcher']),
        containsPair('zoneCenter', ['clock']),
        containsPair('zoneRight', ['maprisma-wlan-monitor']),
        containsPair('hidden', <String>[]),
      ));
      // the Launcher (a fixed entry) can be taken out: hidden, in no zone
      r = await core.call('bar.remove', {'app': 'launcher'});
      expect(stored().single['hidden'], ['maprisma-launcher']);
      expect(stored().single['zoneLeft'], isEmpty);
      // a tray taken out: hidden in the widget and Hidden=true in its autostart file
      r = await core.call('bar.remove', {'app': 'wlan'});
      expect(r['autostart'], 'changed');
      expect(File(autostart('wlan')).readAsStringSync(), startsWith('[Desktop Entry]\nHidden=true\n'));
      expect(stored().single['hidden'], ['maprisma-launcher', 'maprisma-wlan-monitor']);
      // and back in, into the centre after the clock
      r = await core.call('bar.place', {'app': 'wlan', 'area': 'center'});
      expect(stored().single['zoneCenter'], ['clock', 'maprisma-wlan-monitor']);
      expect(stored().single['hidden'], ['maprisma-launcher']);
      expect(File(autostart('wlan')).readAsStringSync(), isNot(contains('Hidden')));
      // the clock moves like any entry
      await core.call('bar.move', {'entry': 'clock', 'area': 'right', 'index': 0});
      expect(stored().single['zoneRight'], ['clock']);
      expect(stored().single['zoneCenter'], ['maprisma-wlan-monitor']);
    });

    test('a concurrent change in Plasma is refused with "changed"', () async {
      plasma([widget(left: ['maprisma-wlan-monitor'])]);
      final core = kde(extra: {'FAKE_PLASMA_RACE': jsonEncode({'zoneLeft': ['maprisma-home']})});
      await expectLater(core.call('bar.place', {'app': 'wlan', 'area': 'right'}), throwsA(isA<RouteError>().having((e) => e.code, 'code', 'changed')));
      expect(stored().single['zoneRight'], isNull);
      // and with a stale revision from bar.get
      plasma([widget(left: ['maprisma-wlan-monitor'])]);
      final seen = await kde().call('bar.get');
      final s = stored()..single['zoneLeft'] = ['maprisma-home'];
      File(state).writeAsStringSync(jsonEncode(s));
      await expectLater(kde().call('bar.place', {'app': 'wlan', 'area': 'right', 'revision': seen['revision']}), throwsA(isA<RouteError>().having((e) => e.code, 'code', 'changed')));
    });

    test('the old single order counts as the left zone, as in main.qml; stopped trays are marked', () async {
      plasma([{...widget(), 'order': ['maprisma-wlan-monitor', 'maprisma-launcher']}]);
      final r = await kde().call('bar.get');
      expect(ids(r, 'left'), ['maprisma-wlan-monitor', 'maprisma-launcher']);
      expect((r['areas']['left'] as List).map((e) => e['shown']), [false, true]);
      expect(ids(r, 'center'), ['clock']);
    });

    test('several Maprisma Icons: the first by default, another by its id', () async {
      plasma([widget(id: 3, left: []), widget(id: 9, left: ['maprisma-home'])]);
      final core = kde();
      expect((await core.call('bar.get'))['widget'], 3);
      expect(ids(await core.call('bar.get', {'widget': 9}), 'left').first, 'maprisma-home');
      await core.call('bar.place', {'app': 'hue', 'area': 'left', 'widget': 9});
      expect(stored()[1]['zoneLeft'], ['maprisma-home', 'maprisma-launcher', 'maprisma-hue-lights']);
      expect(stored()[0]['zoneLeft'], isEmpty);
    });

    test('without the widget: the system tray; only the autostart flag changes', () async {
      plasma([]);
      w.install('wlan');
      w.writeFile(autostart('wlan'), '[Desktop Entry]\nExec=x\n');
      final core = kde();
      final r = await core.call('bar.get');
      expect(r['kind'], 'systemTray');
      expect((r['trays'] as List).firstWhere((t) => t['app'] == 'wlan')['startsAtLogin'], isTrue);
      await core.call('bar.remove', {'app': 'wlan'});
      expect(File(autostart('wlan')).readAsStringSync(), contains('Hidden=true'));
      expect(appOf(await core.call('apps.list'), 'wlan')['bar'], allOf(containsPair('state', 'out'), containsPair('startsAtLogin', false), containsPair('where', 'systemTray')));
      await core.call('bar.place', {'app': 'wlan', 'area': 'left'});
      expect(File(autostart('wlan')).readAsStringSync(), isNot(contains('Hidden')));
      await expectLater(core.call('bar.move', {'entry': 'clock', 'area': 'left', 'index': 0}), throwsA(isA<RouteError>()));
    });

    test('plasmashell not reachable: bar.get says so, changes are refused', () async {
      plasma([widget()]);
      final core = kde(extra: {'FAKE_PLASMA_DOWN': '1'});
      final r = await core.call('bar.get');
      expect(r['kind'], 'systemTray');
      expect(r['error'], contains('plasmashell'));
      await expectLater(core.call('bar.place', {'app': 'wlan', 'area': 'left'}), throwsA(isA<RouteError>().having((e) => e.code, 'code', 'unavailable')));
      expect(appOf(await core.call('apps.list'), 'launcher')['bar']['state'], 'unknown');
    });

    test('the wanted state is put back: zones, hidden, autostart', () async {
      plasma([widget(left: ['maprisma-wlan-monitor'])]);
      w.install('wlan');
      w.writeFile(autostart('wlan'), '[Desktop Entry]\nExec=x\n');
      final core = kde();
      await core.call('bar.move', {'app': 'wlan', 'area': 'right', 'index': 0});
      await core.call('bar.remove', {'app': 'launcher'});
      // an install rewrote the autostart file; Plasma lost the zones
      plasma([widget(left: ['maprisma-wlan-monitor'])]);
      File(autostart('wlan')).writeAsStringSync('[Desktop Entry]\nName=x\n');
      final r = await core.call('bar.apply');
      expect(r['changed'], unorderedEquals(['wlan', 'launcher']));
      expect(stored().single, allOf(containsPair('zoneRight', ['maprisma-wlan-monitor']), containsPair('hidden', ['maprisma-launcher'])));
      expect(File(autostart('wlan')).readAsStringSync(), '[Desktop Entry]\nName=x\n');
      expect((await core.call('bar.apply'))['changed'], isEmpty);
    });

    test('status: the Launcher entry from the widget; a hidden tray is out', () async {
      plasma([widget(hidden: ['maprisma-launcher', 'maprisma-wlan-monitor'])]);
      w.install('wlan');
      final r = await kde().call('apps.list');
      expect(appOf(r, 'launcher')['bar'], allOf(containsPair('state', 'out'), containsPair('visible', false)));
      expect(appOf(r, 'wlan')['bar'], allOf(containsPair('state', 'out'), containsPair('startsAtLogin', true)));
      plasma([widget()]);
      expect(appOf(await kde().call('apps.list'), 'launcher')['bar'], allOf(containsPair('state', 'in'), containsPair('zone', 'left')));
    });
  });

  group('autostart flag', () {
    test('Hidden=true is set in [Desktop Entry] only, and taken out again; the rest stays', () {
      final f = p.join(w.paths.autostart, 'x.desktop');
      const text = '[Desktop Entry]\nType=Application\nExec=x\n\n[Desktop Action a]\nHidden=false\nName=a\n';
      w.writeFile(f, text);
      expect(desktopHidden(f), isFalse);
      expect(setDesktopHidden(w.paths, f, true), isTrue);
      expect(File(f).readAsStringSync(), '[Desktop Entry]\nHidden=true\nType=Application\nExec=x\n\n[Desktop Action a]\nHidden=false\nName=a\n');
      expect(desktopHidden(f), isTrue);
      expect(setDesktopHidden(w.paths, f, true), isFalse);
      expect(setDesktopHidden(w.paths, f, false), isTrue);
      expect(File(f).readAsStringSync(), text);
      w.writeFile(f, '[Desktop Entry]\nHidden = true\nExec=x');
      expect(desktopHidden(f), isTrue);
      setDesktopHidden(w.paths, f, false);
      expect(File(f).readAsStringSync(), '[Desktop Entry]\nExec=x');
      expect(() => setDesktopHidden(w.paths, p.join(w.dir, 'none.desktop'), true), throwsA(isA<RouteError>()));
    });
  });

  test('CLI: bar prints the areas; bar <id> <area> changes them', () async {
    realPanel();
    final out = _Sink();
    expect(await runCli(['bar'], service: cosmic(), out: out), 0);
    expect(out.text, contains('center  Notifications  [hue]  Time  [llm]  [wlan]'));
    final out2 = _Sink();
    expect(await runCli(['bar', 'wlan', 'left'], service: cosmic(), out: out2), 0);
    expect(out2.text, contains('left    Workspaces  [launcher]  [control]  [theme]  [wlan]'));
    expect(await runCli(['bar', 'wlan', 'out'], service: cosmic(), out: _Sink()), 0);
    expect(File(wingsFile()).readAsStringSync(), realWings);
    expect(await runCli(['bar', 'wlan', 'up'], service: cosmic(), out: _Sink()), 2);
  });
}

final class _Sink implements IOSink {
  final _b = StringBuffer();
  String get text => _b.toString();
  @override
  void writeln([Object? o = '']) => _b.writeln(o);
  @override
  void write(Object? o) => _b.write(o);
  @override
  dynamic noSuchMethod(Invocation i) => null;
}
