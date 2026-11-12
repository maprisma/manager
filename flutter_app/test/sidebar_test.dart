// The sidebar (COSMIC Settings' layout): Apps, Bar, Power, Settings; the Power page on Hyprland
// (Maprisma Shell's idle times, the power profile) and on COSMIC (only a link to COSMIC
// Settings). With MAPRISMA_SHOTS=<folder> it saves PNGs of the pages.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma_manager/app.dart';
import 'package:maprisma_manager/core_call.dart';
import 'package:maprisma_manager/jobs_model.dart';
import 'package:maprisma_manager_core/maprisma_manager_core.dart';
import 'package:path/path.dart' as p;

import '../../packages/maprisma_manager_core/test/support.dart';
import 'page_shots.dart';

const _dark = {'background': '#1a2234', 'foreground': '#cdd6ee', 'accent': '#4dd6c8', 'muted': '#a0a9c0'};

void main() {
  late World w;
  setUpAll(loadShotFonts);
  setUp(() {
    configureLanguage('en');
    w = World.create();
    w.writeFile(p.join(w.home, 'profile'), 'balanced');
    w.writeFile(p.join(w.fakeBin, 'powerprofilesctl'), r'''#!/bin/sh
read cur < "$HOME/profile"
case "$1" in
  list) for x in performance balanced power-saver; do if [ "$x" = "$cur" ]; then echo "* $x:"; else echo "  $x:"; fi; echo; done ;;
  set) echo "$2" > "$HOME/profile" ;;
esac
''', mode: '755');
    w.writeFile(p.join(w.fakeBin, 'cosmic-settings'), '#!/bin/sh\n', mode: '755');
  });
  tearDown(() => w.dispose());

  String shellFile() => p.join(w.home, '.config/maprisma-shell/shell.json');

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

  Future<void> open(WidgetTester tester, String desktop, double width) async {
    tester.view.physicalSize = Size(width, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final core = w.core(desktop: desktop);
    final jobs = JobsModel(call(core), every: const Duration(milliseconds: 200));
    addTearDown(jobs.dispose);
    await tester.pumpWidget(ManagerApp(core: call(core), look: const {'colors': _dark}, checkOnStart: false, jobs: jobs, screenshots: p.join(w.dir, 'shots')));
    await settle(tester);
  }

  /// A page from the sidebar (in a condensed window through the toggle first).
  Future<void> nav(WidgetTester tester, String page) async {
    if (find.byKey(const ValueKey('nav-toggle')).evaluate().isNotEmpty) {
      await tester.tap(find.byKey(const ValueKey('nav-toggle')));
      await settle(tester, 2);
    }
    await tester.tap(find.byKey(ValueKey('nav-$page')));
    await settle(tester);
  }

  for (final width in [900.0, 600.0]) {
    testWidgets('Hyprland at ${width.round()} px: the sidebar, the Power page writes shell.json and sets the profile', (tester) async {
      w.writeFile(shellFile(), jsonEncode({'wallpaper': '/w.jpg', 'idle': {'lock': 180, 'screenOff': 300, 'suspend': 600, 'whilePlaying': false}}));
      await open(tester, 'Hyprland', width);
      final condensed = width < 648;
      // condensed: the sidebar hides behind the toggle and covers the window when shown
      expect(find.byKey(const ValueKey('sidebar')), condensed ? findsNothing : findsOneWidget);
      if (shotsDir != null) await saveShot(tester, 'sidebar-apps-${width.round()}');
      if (condensed) {
        await tester.tap(find.byKey(const ValueKey('nav-toggle')));
        await settle(tester, 2);
        if (shotsDir != null) await saveShot(tester, 'sidebar-open-${width.round()}');
        await tester.tap(find.byKey(const ValueKey('nav-toggle')));
        await settle(tester, 2);
      }
      await nav(tester, 'power');
      expect(find.byKey(const ValueKey('sidebar')), condensed ? findsNothing : findsOneWidget);
      for (final s in ['Power mode', 'Power saving options', 'Extended battery life', 'High performance']) {
        expect(find.text(s), findsOneWidget, reason: s);
      }
      expect(find.text('10 minutes'), findsOneWidget);
      if (shotsDir != null) await saveShot(tester, 'power-hyprland-${width.round()}');

      await tester.tap(find.byKey(const ValueKey('profile-power-saver')));
      await settle(tester);
      expect(File(p.join(w.home, 'profile')).readAsStringSync().trim(), 'power-saver');

      await tester.tap(find.text('10 minutes'));
      await settle(tester, 2);
      await tester.tap(find.text('Never').last);
      await settle(tester);
      final stored = jsonDecode(File(shellFile()).readAsStringSync()) as Map;
      expect(stored['wallpaper'], '/w.jpg');
      expect((stored['idle'] as Map)['suspend'], 0);

      await tester.ensureVisible(find.byKey(const ValueKey('idle-whilePlaying')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('idle-whilePlaying')));
      await settle(tester);
      expect(((jsonDecode(File(shellFile()).readAsStringSync()) as Map)['idle'] as Map)['whilePlaying'], isTrue);

      // Ctrl+, the settings; Ctrl+1 back to the list
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.comma);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await settle(tester);
      expect(find.byKey(const ValueKey('settings-page')), findsOneWidget);
      if (shotsDir != null) await saveShot(tester, 'settings-${width.round()}');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await settle(tester);
      expect(find.byKey(const ValueKey('settings-page')), findsNothing);
      expect(find.byKey(const ValueKey('apps-title')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('COSMIC: the Power page only opens COSMIC Settings; Settings: F12 and Corners are saved', (tester) async {
    await open(tester, 'COSMIC', 900);
    await nav(tester, 'power');
    expect(find.text('Power is set in COSMIC Settings'), findsOneWidget);
    expect(find.text('Power mode'), findsNothing);
    expect(find.text('Power saving options'), findsNothing);
    if (shotsDir != null) await saveShot(tester, 'power-cosmic-900');

    await nav(tester, 'settings');
    await tester.tap(find.byKey(const ValueKey('settings-screenshot-key')));
    await settle(tester);
    expect(Settings.load(w.paths).screenshotKey, isFalse);
    await tester.tap(find.text('Like windows'));
    await settle(tester, 2);
    await tester.tap(find.text('Square').last);
    await settle(tester);
    expect(Settings.load(w.paths).corners, 'square');
    expect(tester.takeException(), isNull);
  });
}

final class _Failed {
  _Failed(this.error);
  final Object error;
}
