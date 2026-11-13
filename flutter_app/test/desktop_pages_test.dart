// The sidebar's desktop pages on Hyprland against fake tools (the core tests' fakes), and on
// COSMIC and KDE (only the link to their own settings). With MAPRISMA_SHOTS=<folder> it saves a
// PNG of every page.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma_manager/app.dart';
import 'package:maprisma_manager/core_call.dart';
import 'package:maprisma_manager/jobs_model.dart';
import 'package:maprisma_manager_core/maprisma_manager_core.dart';
import 'package:path/path.dart' as p;

import '../../packages/maprisma_manager_core/test/fakes.dart';
import '../../packages/maprisma_manager_core/test/support.dart';
import 'page_shots.dart';

const _dark = {'background': '#1a2234', 'foreground': '#cdd6ee', 'accent': '#4dd6c8', 'muted': '#a0a9c0'};

void main() {
  late World w;
  setUpAll(loadShotFonts);
  setUp(() {
    configureLanguage('en');
    w = World.create();
    fakePactl(w);
    fakeHypr(w);
    fakeNmcli(w);
    fakeBluetoothctl(w);
    fakeSystem(w);
    w.writeFile(p.join(w.root, 'etc/os-release'), 'PRETTY_NAME="CachyOS Linux"\n');
    w.writeFile(p.join(w.proc, 'meminfo'), 'MemTotal:       65536000 kB\n');
    w.fake('cosmic-settings', r'echo "$*" >> "$HOME/cosmic.log"');
    w.fake('systemsettings', r'echo "$*" >> "$HOME/kde.log"');
    w.fake('setsid', r'exec "$@"');
  });
  tearDown(() => w.dispose());

  List<String> log(String n) {
    final f = File(p.join(w.home, n));
    return f.existsSync() ? f.readAsLinesSync() : const [];
  }

  CoreCall call(CoreService core) {
    final inner = inProcess(core);
    return (m, [params = const {}]) async {
      final r = await Zone.root.run(() => inner(m, params).then<Object>((v) => v, onError: (Object e) => _Failed(e)));
      if (r is _Failed) throw r.error;
      return r as Map<String, dynamic>;
    };
  }

  Future<void> settle(WidgetTester tester, [int rounds = 6]) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

  Future<void> open(WidgetTester tester, String desktop) async {
    tester.view.physicalSize = const Size(1000, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final core = w.core(desktop: desktop, extra: {'XDG_DATA_DIRS': '/usr/share', 'XDG_SESSION_TYPE': 'wayland'});
    final jobs = JobsModel(call(core), every: const Duration(milliseconds: 200));
    addTearDown(jobs.dispose);
    await tester.pumpWidget(ManagerApp(core: call(core), look: const {'colors': _dark}, checkOnStart: false, relook: null, jobs: jobs, screenshots: p.join(w.dir, 'shots')));
    await settle(tester);
  }

  Future<void> nav(WidgetTester tester, String page) async {
    await tester.ensureVisible(find.byKey(ValueKey('nav-$page')));
    await tester.pump();
    await tester.tap(find.byKey(ValueKey('nav-$page')));
    await settle(tester, 12);
  }

  Future<void> shot(WidgetTester tester, String name) async {
    if (shotsDir != null) await saveShot(tester, name);
  }

  Future<void> choose(WidgetTester tester, String key, String label) async {
    await tester.ensureVisible(find.byKey(ValueKey(key)));
    await tester.pump();
    await tester.tap(find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(DropdownButton<String>)));
    await settle(tester, 2);
    await tester.tap(find.text(label).last);
    await settle(tester);
  }

  testWidgets('Hyprland: Sound sets the output device and mutes', (tester) async {
    await open(tester, 'Hyprland');
    await nav(tester, 'sound');
    expect(find.text('Output volume'), findsOneWidget);
    expect(find.text('Google Chrome'), findsOneWidget);
    expect(find.text('Device profiles'), findsOneWidget);
    await shot(tester, 'page-sound');
    await choose(tester, 'sink-device', 'USB Audio Speakers');
    await tester.tap(find.byKey(const ValueKey('sink-mute')));
    await settle(tester);
    expect(log('pactl.log'), ['set-default-sink speakers', 'set-sink-mute @DEFAULT_SINK@ 1']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Hyprland: Displays changes the scale, Revert undoes it; Keep keeps it', (tester) async {
    await open(tester, 'Hyprland');
    await nav(tester, 'displays');
    expect(find.text('LG TV (HDMI-A-1)'), findsOneWidget);
    expect(find.text('Dell (DP-1)'), findsOneWidget);
    await shot(tester, 'page-displays');
    await tester.tap(find.descendant(of: find.byKey(const ValueKey('display-scale-HDMI-A-1')), matching: find.byType(DropdownButton<double>)));
    await settle(tester, 2);
    await tester.tap(find.text('150 %').last);
    await settle(tester);
    expect(find.text('Keep these display settings?'), findsOneWidget);
    await shot(tester, 'page-displays-keep');
    final lua = File(p.join(w.home, '.config/hypr/hypr-manager.lua'));
    expect(lua.readAsStringSync(), contains('scale = 1.5'));
    await tester.tap(find.byKey(const ValueKey('display-revert')));
    await settle(tester);
    expect(lua.readAsStringSync(), isNot(contains('HDMI-A-1')));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Hyprland: Input devices writes the layout and the Caps Lock key', (tester) async {
    await open(tester, 'Hyprland');
    await nav(tester, 'input');
    expect(find.text('Input sources'), findsOneWidget);
    expect(find.text('Touchpad'), findsNothing);
    await shot(tester, 'page-input');
    await choose(tester, 'input-caps', 'Escape');
    final lua = File(p.join(w.home, '.config/hypr/hypr-manager.lua')).readAsStringSync();
    expect(lua, contains('kb_options = "caps:escape"'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Hyprland: Network lists known and visible networks; a password connects', (tester) async {
    await open(tester, 'Hyprland');
    await nav(tester, 'network');
    expect(find.text('Home:Net'), findsOneWidget);
    expect(find.text('Neighbour'), findsOneWidget);
    expect(find.text('Wired connection 1'), findsOneWidget);
    expect(find.text('Work'), findsOneWidget);
    await shot(tester, 'page-network');
    await tester.tap(find.byKey(const ValueKey('visible-Neighbour')));
    await settle(tester, 2);
    await tester.enterText(find.byKey(const ValueKey('wifi-password')), 'secret-pass-123');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('wifi-connect')));
    await settle(tester);
    expect(log('nmcli.log'), contains('passwd-file: 802-11-wireless-security.psk:secret-pass-123'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Hyprland: Bluetooth shows the paired device with its battery and disconnects it', (tester) async {
    await open(tester, 'Hyprland');
    await nav(tester, 'bluetooth');
    expect(find.text('My Headphones'), findsOneWidget);
    expect(find.text('Connected · Battery 80 %'), findsOneWidget);
    await shot(tester, 'page-bluetooth');
    await tester.tap(find.text('Disconnect'));
    await settle(tester);
    expect(log('bt.log'), contains('disconnect AA:BB:CC:DD:EE:01'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Hyprland: Applications, Time & Language and About', (tester) async {
    await open(tester, 'Hyprland');
    await nav(tester, 'applications');
    expect(find.text('Web browser'), findsOneWidget);
    await shot(tester, 'page-applications');
    await choose(tester, 'default-browser', 'Chrome');
    expect(log('xdg.log'), contains(startsWith('default chrome.desktop')));
    await tester.tap(find.byKey(const ValueKey('autostart-add')));
    await settle(tester, 2);
    await tester.tap(find.byKey(const ValueKey('pick-editor.desktop')));
    await settle(tester);
    expect(File(p.join(w.home, '.config/autostart/editor.desktop')).existsSync(), isTrue);

    await nav(tester, 'time');
    expect(find.text('Europe/Berlin'), findsOneWidget);
    await shot(tester, 'page-time');
    await tester.tap(find.byKey(const ValueKey('time-zone')));
    await settle(tester, 2);
    await tester.enterText(find.byKey(const ValueKey('pick-filter')), 'utc');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('pick-UTC')));
    await settle(tester);
    expect(log('tdc.log'), contains('set-timezone UTC'));

    await nav(tester, 'about');
    expect(find.text('CachyOS Linux'), findsOneWidget);
    expect(find.text('62.5 GiB'), findsOneWidget);
    await shot(tester, 'page-about');
    expect(tester.takeException(), isNull);
  });

  testWidgets('Appearance opens Maprisma Theme (or points to the Apps page)', (tester) async {
    await open(tester, 'Hyprland');
    await nav(tester, 'appearance');
    expect(find.text('Maprisma Theme'), findsOneWidget);
    expect(find.byKey(const ValueKey('appearance-install-theme')), findsOneWidget);
    await shot(tester, 'page-appearance');
  });

  testWidgets('Hyprland: Appearance sets the animations (workspace style, windows off) and resets them', (tester) async {
    await open(tester, 'Hyprland');
    await nav(tester, 'appearance');
    expect(find.text('Animations (Hyprland)'), findsOneWidget);
    expect(find.byKey(const ValueKey('anim-reset')), findsOneWidget);
    expect(tester.widget<OutlinedButton>(find.byKey(const ValueKey('anim-reset'))).onPressed, isNull, reason: 'nothing set yet');
    await choose(tester, 'anim-workspaces-style', 'Slide and fade');
    final lua = File(p.join(w.home, '.config/hypr/hypr-manager.lua'));
    expect(lua.readAsStringSync(), contains('leaf = "workspaces", enabled = true, speed = 5, bezier = "standard", style = "slidefade 20%"'));
    // the Hyprland fake still answers with the config's values: make it answer with the new style
    final live = jsonDecode(jsonEncode(animationsFixture)) as List;
    for (final a in (live.first as List).cast<Map>()) {
      if (a['name'] == 'workspaces') a['style'] = 'slidefade 20%';
    }
    w.writeFile(p.join(w.home, 'hypr', 'animations.json'), jsonEncode(live));
    await nav(tester, 'apps');
    await nav(tester, 'appearance');
    expect(find.byKey(const ValueKey('anim-workspaces-percent')), findsOneWidget, reason: 'slidefade takes a distance');
    await shot(tester, 'page-appearance-animations');
    await tester.ensureVisible(find.byKey(const ValueKey('anim-windows')));
    await tester.tap(find.descendant(of: find.byKey(const ValueKey('anim-windows')), matching: find.byType(Switch)));
    await settle(tester);
    expect(lua.readAsStringSync(), contains('leaf = "windowsIn", enabled = false'));
    await tester.ensureVisible(find.byKey(const ValueKey('anim-reset')));
    await tester.tap(find.byKey(const ValueKey('anim-reset')));
    await settle(tester);
    expect(lua.readAsStringSync(), isNot(contains('hl.animation')));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Theme: Maprisma Theme\'s themes in small, the one in use marked; Light narrows; a click applies', (tester) async {
    fakeThemeCore(w);
    await open(tester, 'COSMIC');
    await nav(tester, 'theme');
    expect(find.byKey(const ValueKey('theme-page')), findsOneWidget);
    expect(find.text('Nord'), findsOneWidget);
    expect(find.text('Catppuccin Latte'), findsOneWidget);
    expect(find.text('Autumn'), findsOneWidget);
    expect(find.text('Secret'), findsNothing, reason: 'hidden in Maprisma Theme');
    expect(find.descendant(of: find.byKey(const ValueKey('theme-nord')), matching: find.text('In use')), findsOneWidget);
    await shot(tester, 'page-theme');
    await tester.tap(find.text('Light'));
    await settle(tester, 2);
    expect(find.text('Nord'), findsNothing);
    expect(find.text('Catppuccin Latte'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('theme-latte')));
    await settle(tester, 8);
    expect(log('theme.log'), ['apply latte']);
    expect(find.descendant(of: find.byKey(const ValueKey('theme-latte')), matching: find.text('In use')), findsOneWidget);
    // the one in use is not applied again
    await tester.tap(find.byKey(const ValueKey('theme-latte')));
    await settle(tester, 2);
    expect(log('theme.log'), ['apply latte']);
    expect(find.byKey(const ValueKey('theme-more')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Theme without Maprisma Theme points to the Apps page', (tester) async {
    await open(tester, 'Hyprland');
    await nav(tester, 'theme');
    expect(find.text('Maprisma Theme is not installed'), findsOneWidget);
    expect(find.byKey(const ValueKey('theme-install')), findsOneWidget);
    await shot(tester, 'page-theme-missing');
  });

  testWidgets('COSMIC and KDE: no animations card on Appearance', (tester) async {
    for (final desktop in ['COSMIC', 'KDE']) {
      await open(tester, desktop);
      await nav(tester, 'appearance');
      expect(find.text('Maprisma Theme'), findsOneWidget, reason: desktop);
      expect(find.text('Animations (Hyprland)'), findsNothing, reason: desktop);
      expect(find.byKey(const ValueKey('anim-card')), findsNothing, reason: desktop);
    }
  });

  testWidgets('COSMIC: pages only open COSMIC Settings; KDE: one row per module', (tester) async {
    await open(tester, 'COSMIC');
    await nav(tester, 'sound');
    expect(find.text('This is set in COSMIC Settings'), findsOneWidget);
    expect(find.text('Output volume'), findsNothing);
    await shot(tester, 'page-sound-cosmic');
    await tester.tap(find.byKey(const ValueKey('native-open-0')));
    await settle(tester);
    await nav(tester, 'input');
    expect(find.text('Mouse'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('native-open-2')));
    await settle(tester);
    expect(log('cosmic.log'), ['sound', 'touchpad']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('KDE: Input devices lists the three modules', (tester) async {
    await open(tester, 'KDE');
    await nav(tester, 'input');
    expect(find.text('This is set in System Settings'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('native-open-1')));
    await settle(tester);
    expect(log('kde.log'), ['kcm_mouse']);
    await shot(tester, 'page-input-kde');
  });
}

final class _Failed {
  _Failed(this.error);
  final Object error;
}
