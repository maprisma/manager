// The Manager's pages against the real core in a temp HOME (the core's test World: a fake
// projects folder, fake /proc, fake tools, COSMIC panel files, no network) plus a fake app whose
// installer can be held, for the log sheet. With MAPRISMA_SHOTS=<folder> it saves PNGs of the
// list, the bar editor, the icon picker and the log sheet at 900 and 460 px.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma_manager/app.dart';
import 'package:maprisma_manager/app_facts.dart';
import 'package:maprisma_manager/core_call.dart';
import 'package:maprisma_manager/jobs_model.dart';
import 'package:maprisma_manager_core/maprisma_manager_core.dart';
import 'package:path/path.dart' as p;

import '../../packages/maprisma_manager_core/test/support.dart';
import 'page_shots.dart';

const _fakeApplet = 'io.test.CosmicFake';

const fakeApp = AppEntry(
  id: 'fake',
  name: 'Maprisma Fake',
  kind: 'test',
  inputs: [Input('fake-app')],
  components: [
    Component(
      id: 'main',
      name: 'Maprisma Fake',
      repo: 'fake-app',
      install: ['./install.sh'],
      paths: [
        InstalledPath('{bin}/mm-fake', PathKind.executable, key: true),
        InstalledPath('{apps}/io.test.Fake.desktop', PathKind.file),
      ],
    ),
  ],
  data: [DataPath('{config}/mm-fake'), DataPath('{config}/mm-fake-shared', sharedWithOmarchy: true)],
  bar: BarIcon(cosmicApplet: _fakeApplet, cosmicAppletExe: '{bin}/mm-fake'),
);

const _installScript = r'''#!/bin/sh
set -eu
ctl="$HOME/.mm-test"
echo "building the fake app"
for i in 1 2 3 4 5 6; do echo "compiling part $i of 6"; done
while [ -e "$ctl/hold-build" ]; do sleep 0.05; done
mkdir -p "$HOME/.local/bin" "${XDG_DATA_HOME:-$HOME/.local/share}/applications"
printf '#!/bin/sh\nexit 0\n' > "$HOME/.local/bin/mm-fake"
chmod 755 "$HOME/.local/bin/mm-fake"
printf '[Desktop Entry]\nName=Fake\n' > "${XDG_DATA_HOME:-$HOME/.local/share}/applications/io.test.Fake.desktop"
echo "installed"
''';

const _tools = [
  'sh', 'bash', 'cp', 'mv', 'rm', 'mkdir', 'chmod', 'ln', 'cat', 'sleep', 'setsid', 'head', 'grep', 'mktemp',
  'readlink', 'ls', 'touch', 'env', 'dirname', 'basename', 'true', 'false', 'printf', 'rmdir', 'echo',
];

String _svg(String shape) => '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16">$shape</svg>';

void main() {
  late World w;
  late CoreService core;
  late String ctl;

  setUpAll(loadShotFonts);

  setUp(() {
    catalogOverride = [...builtinCatalog, fakeApp];
    w = World.create();
    ctl = p.join(w.home, '.mm-test');
    Directory(ctl).createSync(recursive: true);
    final sysbin = p.join(w.dir, 'sysbin');
    Directory(sysbin).createSync();
    for (final t in _tools) {
      for (final d in ['/usr/bin', '/bin']) {
        if (File(p.join(d, t)).existsSync()) {
          Link(p.join(sysbin, t)).createSync(p.join(d, t));
          break;
        }
      }
    }
    for (final f in ['cargo', 'flutter', 'dart', 'gtk-update-icon-cache', 'update-desktop-database']) {
      w.fake(f, 'exit 0');
    }
    // Maprisma's package (no bar icon of its own)
    w.fake('pacman', 'case "\$*" in "-Q maprisma-bin") echo "maprisma-bin 0.14.2-1";; *) exit 1;; esac');
    // the COSMIC panel: COSMIC's own applets and four of ours
    final panel = p.join(w.paths.config, 'cosmic/com.system76.CosmicPanel.Panel/v1');
    w.writeFile(p.join(panel, 'plugins_wings'),
        'Some(([\n    "com.system76.CosmicAppletWorkspaces",\n    "io.github.ubruckhaus.CosmicMaprismaLauncher",\n], [\n    "io.github.ubruckhaus.CosmicMaprismaHueLights",\n    "com.system76.CosmicAppletNetwork",\n    "com.system76.CosmicAppletPower",\n]))');
    w.writeFile(p.join(panel, 'plugins_center'),
        'Some([\n    "com.system76.CosmicAppletTime",\n    "io.github.ubruckhaus.CosmicMaprismaWlanMonitor",\n])');
    for (final (id, name) in [
      ('com.system76.CosmicAppletWorkspaces', 'Workspaces'),
      ('com.system76.CosmicAppletTime', 'Date, Time & Calendar'),
      ('com.system76.CosmicAppletNetwork', 'Network'),
      ('com.system76.CosmicAppletPower', 'Power'),
    ]) {
      w.writeFile(p.join(w.root, 'usr/share/applications/$id.desktop'), '[Desktop Entry]\nName=$name\nType=Application\n');
    }
    // installed: WLAN, Hue, LLM, Home, the Launcher (both parts); Theme partly
    for (final a in ['wlan', 'hue', 'llm', 'home', 'launcher', 'maprisma']) {
      w.install(a);
    }
    w.install('theme', skipParts: {'main'});
    w.writeFile(p.join(w.home, '.local/lib/maprisma-launcher/data/flutter_assets/version.json'), '{"version":"0.1.4"}');
    // readable icons for the rows
    final shapes = [
      '<circle cx="8" cy="8" r="6" fill="#444"/>',
      '<rect x="2" y="2" width="12" height="12" rx="3" fill="#444"/>',
      '<path d="M8 1 L15 15 L1 15 Z" fill="#444"/>',
      '<path d="M2 12 A6 6 0 0 1 14 12 Z" fill="#444"/>',
    ];
    var n = 0;
    for (final a in catalog) {
      if (!['wlan', 'hue', 'llm', 'home', 'launcher', 'maprisma', 'theme'].contains(a.id)) continue;
      final name = a.appIcon ?? a.bar.iconName;
      if (name == null) continue;
      final real = File(p.join(Platform.environment['HOME'] ?? '/', '.local/share/icons/hicolor/scalable/apps/$name.svg'));
      final repoIcon = File('/mnt/Data/Projects/maprisma-manager/packaging/$name.svg');
      w.writeFile(p.join(w.paths.icons, '$name.svg'),
          real.existsSync() ? real.readAsStringSync() : repoIcon.existsSync() ? repoIcon.readAsStringSync() : _svg(shapes[n++ % shapes.length]));
    }
    // an icon theme to pick from (COSMIC's default name)
    final theme = p.join(w.root, 'usr/share/icons/Cosmic');
    w.writeFile(p.join(theme, 'index.theme'), '[Icon Theme]\nName=Cosmic\n');
    final realTheme = Directory('/usr/share/icons/Cosmic/scalable/status');
    final picked = realTheme.existsSync()
        ? (realTheme.listSync().whereType<File>().where((f) => f.path.endsWith('-symbolic.svg')).toList()..sort((a, b) => a.path.compareTo(b.path))).take(60).toList()
        : <File>[];
    if (picked.isEmpty) {
      for (var i = 0; i < 24; i++) {
        w.writeFile(p.join(theme, 'scalable/status/test-$i-symbolic.svg'), _svg(shapes[i % shapes.length]));
      }
    }
    for (final f in picked) {
      w.writeFile(p.join(theme, 'scalable/status', p.basename(f.path)), f.readAsStringSync());
    }
    // repos: WLAN behind its upstream by one commit, the Launcher's folder, the fake app
    final wlan = w.repo('maprisma-wlan-monitor', upstream: true);
    w.pushUpstreamCommit('maprisma-wlan-monitor');
    w.git(wlan, ['fetch', '-q']);
    w.repo('maprisma-launcher');
    final fake = w.repo('fake-app');
    w.writeFile(p.join(fake, 'install.sh'), _installScript, mode: '755');
    // GitHub as last checked: the WLAN Monitor's page and a newer Launcher release
    final now = DateTime.now().toUtc().toIso8601String();
    w.writeFile(p.join(w.paths.managerState, 'github.json'), jsonEncode({
      'schema': 1,
      'repos': {
        'maprisma/wlan-monitor': {'checked': now, 'via': 'gh', 'facts': {'url': 'https://github.com/maprisma/wlan-monitor', 'public': true, 'defaultBranch': 'main', 'release': null}},
        'maprisma/launcher': {
          'checked': now,
          'via': 'gh',
          'facts': {
            'url': 'https://github.com/maprisma/launcher',
            'public': true,
            'defaultBranch': 'main',
            'release': {'tag': 'v0.1.5', 'name': 'v0.1.5', 'published': '2026-11-08T10:00:00Z', 'url': 'https://github.com/maprisma/launcher/releases/tag/v0.1.5', 'prerelease': false, 'assets': []},
          },
        },
      },
    }));
    core = CoreService(environment: w.env(extra: {'PATH': '${w.fakeBin}:$sysbin', 'MAPRISMA_FLUTTER': p.join(w.fakeBin, 'flutter')}), uid: 1000)
      ..followPanel = (_) async => {'panel': null, 'note': 'test'};
    core.jobs.pollEvery = const Duration(milliseconds: 30);
  });

  tearDown(() {
    catalogOverride = null;
    w.dispose();
  });

  /// Every core call in real time (the core starts processes and polls with timers). An error
  /// can't cross from the root zone into the test's error zone: it comes over as a value.
  CoreCall call() {
    final inner = inProcess(core);
    return (m, [params = const {}]) async {
      final r = await Zone.root.run(() => inner(m, params).then<Object>((v) => v, onError: (Object e) => _Failed(e)));
      if (r is _Failed) throw r.error;
      return r as Map<String, dynamic>;
    };
  }

  Future<void> settle(WidgetTester tester, [int rounds = 8]) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

  Future<JobsModel> open(WidgetTester tester, double width, {double height = 720}) async {
    tester.view.physicalSize = Size(width, height);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final jobs = JobsModel(call(), every: const Duration(milliseconds: 200));
    addTearDown(jobs.dispose);
    final look = await tester.runAsync(() => call()('desktop.look'));
    await tester.pumpWidget(ManagerApp(core: call(), look: {...?look, 'colors': _dark}, checkOnStart: false, relook: null, jobs: jobs));
    await settle(tester);
    return jobs;
  }

  Finder rowAction(String id) => find.descendant(of: find.byKey(ValueKey('app-$id')), matching: find.byTooltip('App actions'));

  /// Opens the ⋮ menu of an app's row (scrolled into view first: the list builds lazily).
  Future<void> tapAction(WidgetTester tester, String id) async {
    if (find.byKey(ValueKey('app-$id')).evaluate().isEmpty) {
      await tester.scrollUntilVisible(find.byKey(ValueKey('app-$id')), 120,
          scrollable: find.descendant(of: find.byKey(const ValueKey('app-list')), matching: find.byType(Scrollable)).first);
    }
    await tester.ensureVisible(find.byKey(ValueKey('app-$id')));
    await tester.pump();
    await tester.tap(rowAction(id));
    await settle(tester, 3);
  }

  Future<void> shot(WidgetTester tester, String name) async {
    if (shotsDir == null) return;
    await settle(tester, 4);
    await saveShot(tester, name);
  }

  for (final width in [900.0, 460.0]) {
    testWidgets('the list at ${width.round()} px: sections, marks, source chips, the ⋮ menu, the filter and Esc', (tester) async {
      await open(tester, width, height: width > 600 ? 1250 : 1500);
      expect(find.byKey(const ValueKey('apps-title')), findsOneWidget);
      for (final s in ['In the bar', 'Not in the bar', 'No bar icon', 'Not installed']) {
        expect(find.text(s), findsOneWidget, reason: s);
      }
      expect(find.text('Maprisma WLAN Monitor'), findsOneWidget);
      expect(find.byTooltip('1 new commit upstream'), findsOneWidget);
      expect(find.text('0.1.4'), findsOneWidget);
      expect(find.byTooltip('Release v0.1.5 is newer (installed 0.1.4)'), findsOneWidget);
      expect(find.textContaining('Partly installed'), findsNothing); // a tooltip, not text
      expect(find.byIcon(Icons.incomplete_circle), findsOneWidget); // Theme: partly installed
      expect(find.byIcon(Icons.help_outline), findsWidgets); // build unknown
      expect(find.descendant(of: find.byKey(const ValueKey('app-wlan')), matching: find.text('GitHub')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const ValueKey('app-wlan')), matching: find.text('Folder')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await shot(tester, 'list-${width.round()}');

      // the ⋮ menu of an app in the bar
      await tapAction(tester, 'wlan');
      for (final t in ['Open', 'Details…', 'Update', 'Reinstall', 'Take out of the bar', 'Move left', 'Move right', 'Change icon…', 'Reset icon', 'Open on GitHub', 'Copy GitHub URL', 'Copy folder path', 'Uninstall…']) {
        expect(find.text(t), findsOneWidget, reason: t);
      }
      await shot(tester, 'menu-${width.round()}');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester, 4);
      expect(find.text('Take out of the bar'), findsNothing);

      // an app that is not installed, local only: GitHub entries disabled
      await tapAction(tester, 'fake');
      expect(find.text('Install'), findsOneWidget);
      final gh = tester.widget<PopupMenuItem<String>>(find.ancestor(of: find.text('Open on GitHub'), matching: find.byType(PopupMenuItem<String>)));
      expect(gh.enabled, isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester, 4);

      // the filter, and Esc clears it
      await tester.enterText(find.byKey(const ValueKey('filter')), 'wlan');
      await settle(tester, 2);
      expect(find.text('Maprisma WLAN Monitor'), findsOneWidget);
      expect(find.text('Maprisma Hue Lights'), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester, 4);
      expect(find.text('Maprisma Hue Lights'), findsOneWidget);
    });
  }

  for (final width in [900.0, 460.0]) {
    testWidgets('the legend at ${width.round()} px: every mark explained, a click filters, again or Esc: all', (tester) async {
      await open(tester, width, height: width > 600 ? 1250 : 1500);
      await tester.tap(find.byKey(const ValueKey('legend')));
      await settle(tester, 3);
      expect(find.text('What the marks mean'), findsOneWidget);
      for (final id in ['update', 'partial', 'unknown', 'repair', 'job']) {
        expect(find.byKey(ValueKey('legend-$id')), findsOneWidget, reason: id);
      }
      expect(tester.takeException(), isNull);
      await shot(tester, 'legend-${width.round()}');

      // Partly installed: only Theme is left, the button shows the filter
      await tester.tap(find.byKey(const ValueKey('legend-partial')));
      await settle(tester, 4);
      expect(find.text('Maprisma Theme'), findsOneWidget);
      expect(find.text('Maprisma WLAN Monitor'), findsNothing);
      expect(find.byIcon(Icons.filter_alt), findsOneWidget);

      // the same mark again: all
      await tester.tap(find.byKey(const ValueKey('legend')));
      await settle(tester, 3);
      await tester.tap(find.byKey(const ValueKey('legend-partial')));
      await settle(tester, 4);
      expect(find.text('Maprisma WLAN Monitor'), findsOneWidget);

      // Update available, then Esc: all
      await tester.tap(find.byKey(const ValueKey('legend')));
      await settle(tester, 3);
      await tester.tap(find.byKey(const ValueKey('legend-update')));
      await settle(tester, 4);
      expect(find.text('Maprisma WLAN Monitor'), findsOneWidget);
      expect(find.text('Maprisma Hue Lights'), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester, 4);
      expect(find.text('Maprisma Hue Lights'), findsOneWidget);
      expect(find.byIcon(Icons.filter_alt), findsNothing);
    });
  }

  testWidgets('new apps: a section with the folder-only and the GitHub-only one; Clone puts it into the projects folder', (tester) async {
    // a local app the catalog doesn't know, and a repo of the org (as last listed)
    final sky = w.repo('maprisma-sky');
    w.git(sky, ['remote', 'add', 'origin', 'https://github.com/maprisma/sky.git']);
    final src = p.join(w.dir, 'src-clock');
    Directory(src).createSync(recursive: true);
    w.git(src, ['init', '-q', '-b', 'main']);
    File(p.join(src, 'README.md')).writeAsStringSync('clock\n');
    w.git(src, ['add', '.']);
    w.git(src, ['commit', '-q', '-m', 'one']);
    final bare = p.join(w.dir, 'github', 'clock.git');
    w.git(w.dir, ['clone', '-q', '--bare', src, bare]);
    core.ctx.cloneUrlFor = (slug) => slug == 'maprisma/clock' ? bare : '/nowhere/$slug.git';
    final cache = p.join(w.paths.managerState, 'github.json');
    final data = jsonDecode(File(cache).readAsStringSync()) as Map<String, dynamic>;
    data['org'] = {
      'checked': DateTime.now().toUtc().toIso8601String(),
      'via': 'gh',
      'repos': [
        {'name': 'clock', 'url': 'https://github.com/maprisma/clock', 'public': false, 'description': 'A clock', 'archived': false, 'fork': false},
        {'name': 'sky', 'url': 'https://github.com/maprisma/sky', 'public': true, 'description': 'Sky', 'archived': false, 'fork': false},
      ],
    };
    w.writeFile(cache, jsonEncode(data));

    await open(tester, 900, height: 1600);
    expect(find.text('New, not in the catalog'), findsOneWidget);
    expect(find.byKey(const ValueKey('new-maprisma-sky')), findsOneWidget);
    expect(find.byKey(const ValueKey('new-clock')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('new-clock')), matching: find.text('private')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('new-maprisma-sky')), matching: find.text('Clone')), findsNothing);
    expect(tester.takeException(), isNull);
    await shot(tester, 'new-apps');

    await tester.ensureVisible(find.byKey(const ValueKey('new-clock')));
    await tester.tap(find.descendant(of: find.byKey(const ValueKey('new-clock')), matching: find.text('Clone')));
    await settle(tester, 12);
    expect(File(p.join(w.projects, 'maprisma-clock', 'README.md')).existsSync(), isTrue);
    // now it is a folder: listed with it, no Clone any more
    expect(find.byKey(const ValueKey('new-maprisma-clock')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('new-maprisma-clock')), matching: find.text('Clone')), findsNothing);

    // the filter covers them too
    await tester.enterText(find.byKey(const ValueKey('filter')), 'sky');
    await settle(tester, 2);
    expect(find.byKey(const ValueKey('new-maprisma-sky')), findsOneWidget);
    expect(find.byKey(const ValueKey('new-maprisma-clock')), findsNothing);
  });

  testWidgets('Take out of the bar and put back through the menu writes the panel files', (tester) async {
    await open(tester, 900);
    final center = File(p.join(w.paths.config, 'cosmic/com.system76.CosmicPanel.Panel/v1/plugins_center'));
    await tapAction(tester, 'wlan');
    await tester.tap(find.text('Take out of the bar'));
    await settle(tester);
    expect(center.readAsStringSync(), isNot(contains('WlanMonitor')));
    expect(find.descendant(of: find.byKey(const ValueKey('app-wlan')), matching: find.textContaining('bar:')), findsNothing);
    await tapAction(tester, 'wlan');
    await tester.tap(find.text('Put into the bar: centre'));
    await settle(tester);
    expect(center.readAsStringSync(), contains('WlanMonitor'));
  });

  for (final width in [900.0, 460.0]) {
    testWidgets('the bar editor at ${width.round()} px: real order, keyboard moves, a concurrent edit with Reload', (tester) async {
      await open(tester, width);
      await tester.tap(find.byKey(ValueKey(width < 648 ? 'nav-toggle' : 'nav-bar')));
      if (width < 648) {
        await settle(tester, 2);
        await tester.tap(find.byKey(const ValueKey('nav-bar')));
      }
      await settle(tester);
      expect(find.byKey(const ValueKey('bar-page')), findsOneWidget);
      final left = find.byKey(const ValueKey('area-left'));
      expect(find.descendant(of: left, matching: find.text('Workspaces')), findsOneWidget);
      expect(find.descendant(of: left, matching: find.text('Launcher')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const ValueKey('area-center')), matching: find.text('WLAN Monitor')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const ValueKey('area-out')), matching: find.text('LLM Monitor')), findsOneWidget);
      // only installed apps are offered
      expect(find.descendant(of: find.byKey(const ValueKey('area-out')), matching: find.text('Narrator')), findsNothing);
      expect(tester.takeException(), isNull);
      await shot(tester, 'bar-${width.round()}');

      // WLAN one to the left (before the clock), by keyboard
      final center = File(p.join(w.paths.config, 'cosmic/com.system76.CosmicPanel.Panel/v1/plugins_center'));
      final chip = find.descendant(of: find.byKey(const ValueKey('area-center')), matching: find.text('WLAN Monitor'));
      await tester.ensureVisible(chip);
      await tester.pump();
      await tester.tap(chip);
      await settle(tester, 2);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await settle(tester);
      final text = center.readAsStringSync();
      expect(text.indexOf('WlanMonitor'), lessThan(text.indexOf('CosmicAppletTime')));

      // LLM Monitor dragged from "Not in the bar" into the left area
      final llm = find.descendant(of: find.byKey(const ValueKey('area-out')), matching: find.text('LLM Monitor'));
      await tester.ensureVisible(llm);
      await tester.pump();
      final g = await tester.startGesture(tester.getCenter(llm));
      await tester.pump();
      await g.moveBy(const Offset(0, -8));
      await tester.pump();
      final leftArea = find.byKey(const ValueKey('area-left'));
      await g.moveTo(tester.getBottomRight(leftArea) - const Offset(30, 20));
      await tester.pump();
      expect(tester.takeException(), isNull); // no duplicate keys while dragging
      await g.up();
      await settle(tester);
      final wings = File(p.join(w.paths.config, 'cosmic/com.system76.CosmicPanel.Panel/v1/plugins_wings')).readAsStringSync();
      expect(wings.indexOf('LlmMonitor'), lessThan(wings.indexOf('], [')));

      // someone else edits the panel meanwhile: the next move is refused, Reload shows it
      await tester.ensureVisible(chip);
      await tester.pump();
      await tester.tap(chip);
      await settle(tester, 2);
      center.writeAsStringSync('Some([\n    "com.system76.CosmicAppletTime",\n])');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await settle(tester);
      expect(find.byKey(const ValueKey('bar-changed')), findsOneWidget);
      await shot(tester, 'bar-changed-${width.round()}');
      await tester.tap(find.text('Reload'));
      await settle(tester);
      expect(find.byKey(const ValueKey('bar-changed')), findsNothing);
      expect(find.descendant(of: find.byKey(const ValueKey('area-out')), matching: find.text('WLAN Monitor')), findsOneWidget);

      // Esc goes back to the list
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester, 3);
      expect(find.byKey(const ValueKey('apps-title')), findsOneWidget);
    });

    testWidgets('the icon picker at ${width.round()} px: the note, search, preview, apply, reset', (tester) async {
      await open(tester, width);
      final file = File(p.join(w.paths.icons, 'io.github.ubruckhaus.CosmicMaprismaWlanMonitor-symbolic.svg'));
      final before = file.readAsStringSync();
      await tapAction(tester, 'wlan');
      await tester.tap(find.text('Change icon…'));
      await settle(tester);
      expect(find.text('Bar icon of Maprisma WLAN Monitor'), findsOneWidget);
      expect(find.textContaining('Note: the COSMIC applet draws a built-in copy'), findsOneWidget);
      final first = find.descendant(of: find.byType(GridView), matching: find.byType(InkWell)).first;
      await tester.ensureVisible(first);
      await tester.pump();
      await tester.tap(first);
      await tester.pump(const Duration(milliseconds: 400)); // past the double-tap wait (cells also take a double click)
      // the grid keeps room on a narrow window too (a long note once squeezed it to 15 px)
      expect(tester.getRect(find.byType(GridView)).height, greaterThan(80));
      await settle(tester, 3);
      expect(tester.takeException(), isNull);
      await shot(tester, 'icons-${width.round()}');
      await tester.tap(find.text('Use this icon'));
      await settle(tester, 12);
      expect(file.readAsStringSync(), isNot(before));
      // Reset from the menu brings the original back
      await tapAction(tester, 'wlan');
      await tester.tap(find.text('Reset icon'));
      await settle(tester, 12);
      expect(file.readAsStringSync(), before);
    });

    testWidgets('the log sheet at ${width.round()} px: a job runs, its phase and log, Cancel, the result', (tester) async {
      final jobs = await open(tester, width);
      File(p.join(ctl, 'hold-build')).writeAsStringSync('');
      await tapAction(tester, 'fake');
      await tester.tap(find.text('Install'));
      await settle(tester, 10);
      expect(find.byKey(const ValueKey('job-sheet')), findsOneWidget);
      expect(find.text('Installing Maprisma Fake'), findsOneWidget);
      expect(find.text('Building'), findsOneWidget);
      expect(find.textContaining('compiling part 6 of 6'), findsOneWidget);
      final cancel = tester.widget<TextButton>(find.widgetWithText(TextButton, 'Cancel'));
      expect(cancel.onPressed, isNotNull); // nothing changed yet: cancellable
      await shot(tester, 'log-${width.round()}');
      File(p.join(ctl, 'hold-build')).deleteSync();
      for (var i = 0; i < 40 && jobs.busy; i++) {
        await settle(tester, 1);
      }
      await settle(tester, 6);
      expect(jobs.jobs.single.state, 'succeeded');
      expect(find.text('Done.'), findsOneWidget);
      expect(find.textContaining('installed'), findsWidgets);
      await shot(tester, 'log-done-${width.round()}');
      // Esc hides the sheet
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester, 4);
      expect(find.byKey(const ValueKey('job-sheet')), findsNothing);
      // now installed: in "Not in the bar"
      expect(installed(appOf(await tester.runAsync(() => call()('apps.list')) as Map<String, dynamic>, 'fake')), isTrue);
    });
  }

  testWidgets('Update all: per category line with its count, only its apps to confirm, Cancel, Ctrl+U: all, one job per app in order', (tester) async {
    final jobs = await open(tester, 900, height: 1250);
    final list = [for (final x in (await tester.runAsync(() => call()('apps.list')))!['apps'] as List) Map<String, dynamic>.from(x as Map)];
    final plan = updateAllPlan(list);
    expect(plan.steps, isNotEmpty);
    expect(find.byKey(const ValueKey('update-all')), findsNothing); // not in the header any more
    final secs = sections(list, '${(await tester.runAsync(() => call()('apps.list')))!['desktop']}');
    final withUpdates = [for (final (t, items) in secs) if (updateAllPlan(items).steps.isNotEmpty) (t, updateAllPlan(items))];
    expect(withUpdates, isNotEmpty);
    expect(withUpdates.fold<int>(0, (n, x) => n + x.$2.steps.length), plan.steps.length);
    for (final (t, p) in withUpdates) {
      expect(find.descendant(of: find.byKey(ValueKey('update-all-$t')), matching: find.text('Update all (${p.steps.length})')), findsOneWidget, reason: t);
    }
    final (title, part) = withUpdates.first;
    await tester.tap(find.byKey(ValueKey('update-all-$title')));
    await settle(tester, 3);
    expect(find.text(part.steps.length == 1 ? 'Update 1 app?' : 'Update ${part.steps.length} apps?'), findsOneWidget);
    for (final st in part.steps) {
      expect(find.textContaining('• ${st.app['name']}'), findsOneWidget);
    }
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await settle(tester, 3);
    expect(jobs.jobs, isEmpty);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyU);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await settle(tester, 3);
    await tester.tap(find.byKey(const ValueKey('update-all-go')));
    await settle(tester, 6);
    expect([for (final j in jobs.jobs) '${j.app}:${j.kind}'], [for (final st in plan.steps) '${st.app['id']}:${st.kind}']);
    for (var i = 0; i < 60 && jobs.busy; i++) {
      await settle(tester, 1);
    }
  });

  testWidgets('Let AI do the updates: off without a helper; on, the AI button, the helper row and its steps', (tester) async {
    await open(tester, 900);
    await tester.tap(find.byKey(const ValueKey('nav-ai')));
    await settle(tester, 2);
    expect(find.text('No AI helper is installed and signed in'), findsOneWidget);
    expect(tester.widget<Switch>(find.descendant(of: find.byKey(const ValueKey('ai-updates')), matching: find.byType(Switch))).onChanged, isNull);
    await tester.tap(find.byKey(const ValueKey('nav-apps')));
    await settle(tester, 2);
    expect(find.byKey(const ValueKey('ai-button')), findsNothing);

    // a signed-in Claude Code; the helper answers from the test
    w.fake('claude', 'exit 0');
    w.writeFile(p.join(w.home, '.claude/.credentials.json'), '{}');
    w.writeFile(p.join(w.projects, 'maprisma-wlan-monitor/flutter_app/pubspec.yaml'), 'name: x\n');
    var round = 0;
    core.ai.ask = (helper, prompt) async => ++round == 1
        ? jsonEncode({'say': 'The WLAN Monitor needs its packages.', 'actions': [{'do': 'pub_get', 'app': 'wlan'}, {'do': 'update', 'app': 'manager'}], 'done': false})
        : jsonEncode({'say': 'All done.', 'actions': [], 'done': true});
    await tester.tap(find.byKey(const ValueKey('nav-ai')));
    await settle(tester, 4);
    expect(find.text('Automatic (Claude Code)'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('ai-updates'))); // under Web search
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ai-updates')));
    await settle(tester, 3);
    expect(Settings.load(w.paths).values['ai_updates'], isTrue);
    await tester.tap(find.byKey(const ValueKey('nav-apps')));
    await settle(tester, 3);
    expect(find.byKey(const ValueKey('ai-button')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('ai-button')));
    await settle(tester, 3);
    expect(find.text('Helper:'), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('ai-helper')), matching: find.text('Claude Code')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('ai-start')));
    await settle(tester, 30);
    expect(find.text('The WLAN Monitor needs its packages.'), findsOneWidget);
    expect(find.textContaining('Fetch Flutter packages · Maprisma WLAN Monitor — done'), findsOneWidget);
    expect(find.textContaining('Update · Maprisma Settings — not done'), findsOneWidget);
    expect(find.text('All done.'), findsOneWidget);
    expect(find.text('Finished'), findsOneWidget);
    await shot(tester, 'ai-900');
    await tester.tap(find.text('Close'));
    await settle(tester, 2);
    expect(find.text('Helper:'), findsNothing);
  });

  testWidgets('the details dialog: where it exists, the GitHub link, the installed build, prerequisites', (tester) async {
    await open(tester, 900);
    await tapAction(tester, 'wlan');
    await tester.tap(find.text('Details…'));
    await settle(tester);
    expect(find.text('Where it exists'), findsOneWidget);
    expect(find.text('https://github.com/maprisma/wlan-monitor'), findsOneWidget);
    expect(find.text('Installed build'), findsOneWidget);
    expect(find.textContaining('unknown: installed before Maprisma Settings'), findsOneWidget);
    expect(find.text('What it installs'), findsOneWidget);
    expect(find.text('Prerequisites'), findsOneWidget);
    await shot(tester, 'details-900');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester, 2);
    expect(find.text('Where it exists'), findsNothing);
  });

  testWidgets('the uninstall dialog: goes / stays, shared data never offered, the settings checkbox', (tester) async {
    final jobs = await open(tester, 900, height: 1250);
    await tapAction(tester, 'fake');
    await tester.tap(find.text('Install'));
    for (var i = 0; i < 40 && (jobs.jobs.isEmpty || jobs.busy); i++) {
      await settle(tester, 1);
    }
    await settle(tester, 4);
    w.writeFile(p.join(w.paths.config, 'mm-fake/settings.json'), '{}');
    w.writeFile(p.join(w.paths.config, 'mm-fake-shared/x.json'), '{}');
    await tapAction(tester, 'fake');
    await tester.tap(find.text('Uninstall…'));
    await settle(tester);
    expect(find.text('Do you want to uninstall Maprisma Fake?'), findsOneWidget);
    expect(find.textContaining('Goes ('), findsOneWidget);
    expect(find.textContaining('shared with Omarchy'), findsWidgets);
    expect(find.text('Also delete its settings'), findsOneWidget);
    await shot(tester, 'remove-900');
    await tester.tap(find.text('Also delete its settings'));
    await settle(tester, 2);
    expect(find.textContaining('Settings that go'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Uninstall'));
    for (var i = 0; i < 40 && jobs.busy; i++) {
      await settle(tester, 1);
    }
    await settle(tester, 4);
    expect(jobs.jobs.last.state, 'succeeded');
    expect(File(p.join(w.home, '.local/bin/mm-fake')).existsSync(), isFalse);
    expect(Directory(p.join(w.paths.config, 'mm-fake')).existsSync(), isFalse);
    expect(Directory(p.join(w.paths.config, 'mm-fake-shared')).existsSync(), isTrue);
  });

  testWidgets('the Manager\'s own update: the job says restart, the page quits for the helper', (tester) async {
    // what the page does with the result (the helper itself is tested in the core)
    var restarted = false;
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final jobs = JobsModel(call(), every: const Duration(milliseconds: 200));
    addTearDown(jobs.dispose);
    await tester.pumpWidget(ManagerApp(core: call(), checkOnStart: false, jobs: jobs, onRestart: () => restarted = true));
    await settle(tester);
    final j = JobView(id: 'x', app: 'settings', name: 'Maprisma Settings', kind: 'update')
      ..data = {'state': 'succeeded', 'result': {'ok': true, 'restart': true}};
    jobs.onFinished!(j);
    await tester.pump(const Duration(milliseconds: 1600));
    expect(restarted, isTrue);
    await settle(tester, 2);
  });
}

final class _Failed {
  _Failed(this.error);
  final Object error;
}

/// A COSMIC dark palette (as desktop.look reads one), so the pictures look like the real window.
const _dark = {
  'background': '#1b1b1b',
  'foreground': '#e4e4e4',
  'muted': '#9a9996',
  'selection': '#3a3a3e',
  'accent': '#63d0df',
  'red': '#ff7b63',
  'yellow': '#f8e45c',
  'orange': '#ffa348',
  'green': '#8ff0a4',
};
