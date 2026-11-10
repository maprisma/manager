// F12 (a private picture of the window and an optional note) and Settings › Corners, on a fake
// core that keeps its settings in a map (as Maprisma Playground's shell_test.dart).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma_manager/app.dart';
import 'package:maprisma_manager/theme.dart';
import 'package:maprisma_manager_core/maprisma_manager_core.dart';

void main() {
  late Directory home;
  late Map<String, dynamic> settings;
  setUp(() {
    configureLanguage('en');
    home = Directory.systemTemp.createTempSync('manager-shots-');
    settings = {'language': 'en', 'corners': 'windows', 'screenshot_key': true};
  });
  tearDown(() => home.deleteSync(recursive: true));

  Future<Map<String, dynamic>> core(String method, [Map<String, dynamic> params = const {}]) async {
    switch (method) {
      case 'settings.get':
        return {...settings};
      case 'settings.set':
        settings[params['key'] as String] = params['value'];
        return {...params};
      case 'apps.list':
        return {'apps': <Map<String, dynamic>>[], 'desktop': 'other'};
    }
    return {};
  }

  String shots() => '${home.path}/Pictures/Maprisma Manager';
  List<String> files() => Directory(shots()).existsSync()
      ? (Directory(shots()).listSync().map((f) => f.uri.pathSegments.last).toList()..sort())
      : <String>[];

  Future<void> pump(WidgetTester tester, {Map<String, dynamic> look = const {}}) async {
    await tester.pumpWidget(ManagerApp(core: core, look: look, checkOnStart: false, screenshots: shots()));
    await tester.pumpAndSettle();
  }

  Future<void> press(WidgetTester tester, {bool ctrl = false}) async {
    await tester.runAsync(() async {
      if (ctrl) await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.f12);
      if (ctrl) await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      // The picture is drawn and encoded off the test's fake clock.
      for (var i = 0; i < 50 && files().isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
  }

  group('F12', () {
    testWidgets('saves a private PNG, asks for a note and writes it beside the picture', (tester) async {
      await pump(tester);
      await press(tester);
      final saved = files();
      expect(saved, hasLength(1));
      expect(saved.single, matches(RegExp(r'^maprisma-manager-\d{8}-\d{6}\.png$')));
      final png = File('${shots()}/${saved.single}');
      expect(png.readAsBytesSync().take(4), [0x89, 0x50, 0x4e, 0x47]);
      expect(FileStat.statSync(png.path).mode & 0x1ff, 0x180);
      expect(FileStat.statSync(shots()).mode & 0x1ff, 0x1c0);
      expect(find.text('Screenshot saved'), findsOneWidget);
      expect(find.textContaining('Saved as '), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('screenshot-note')), 'The gear is cut off');
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
      expect(files(), [saved.single, saved.single.replaceFirst('.png', '.txt')]);
      expect(File('${shots()}/${saved.single.replaceFirst('.png', '.txt')}').readAsStringSync(), 'The gear is cut off\n');
    });

    testWidgets('F12 while the note is asked for opens no second dialog; Esc keeps the note', (tester) async {
      await pump(tester);
      await press(tester);
      await tester.enterText(find.byKey(const ValueKey('screenshot-note')), 'Twice?');
      await tester.runAsync(() async {
        await tester.sendKeyEvent(LogicalKeyboardKey.f12);
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pumpAndSettle();
      expect(find.text('Screenshot saved'), findsOneWidget);
      expect(files(), hasLength(1));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
      expect(find.text('Screenshot saved'), findsNothing);
      expect(files(), hasLength(2));
      expect(File('${shots()}/${files().last}').readAsStringSync(), 'Twice?\n');
    });

    testWidgets('no note, no .txt; Ctrl+F12 and a switched-off key save nothing', (tester) async {
      await pump(tester);
      await press(tester);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(files(), hasLength(1));
      await press(tester, ctrl: true);
      expect(find.text('Screenshot saved'), findsNothing);
      expect(files(), hasLength(1));
      // Switched off through the settings menu.
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(CheckedPopupMenuItem<String>).last);
      await tester.pumpAndSettle();
      expect(settings['screenshot_key'], isFalse);
      await press(tester);
      expect(files(), hasLength(1));
      expect(find.text('Screenshot saved'), findsNothing);
    });

    testWidgets('a folder that is not yours to write: a message, no dialog', (tester) async {
      Directory(shots()).createSync(recursive: true);
      Process.runSync('/bin/chmod', ['777', shots()]);
      await pump(tester);
      await press(tester);
      expect(find.text('Screenshot saved'), findsNothing);
      expect(find.textContaining('The screenshot could not be saved'), findsOneWidget);
      expect(files(), isEmpty);
    });
  });

  group('corners in three sizes', () {
    test('slight is 6; the sizes follow the radius; Square squares all', () {
      expect(cornerRadius('slight', 20), 6);
      expect(cornerRadius('rounded', null), 12);
      expect(cornerRadius('square', 10), 0);
      expect(cornerRadius('windows', 10), 10);
      expect(cornerRadius('nonsense', null), 12);
      const big = Corners(14), square = Corners(0), slight = Corners(6);
      expect([big.radius, big.control, big.small, big.board], [14, 8, 4, 12]);
      expect([slight.control, slight.small], [6, 4]);
      expect([square.radius, square.control, square.small, square.board], [0, 0, 0, 0]);
    });

    test('the theme gives every control its size', () {
      double r(ShapeBorder? shape) => ((shape! as RoundedRectangleBorder).borderRadius as BorderRadius).topLeft.x;
      final theme = appTheme(Brightness.dark, const {}, 12);
      expect(r(theme.checkboxTheme.shape), 4);
      expect(theme.progressIndicatorTheme.borderRadius, BorderRadius.circular(4));
      expect((theme.tooltipTheme.decoration! as BoxDecoration).borderRadius, BorderRadius.circular(8));
      expect(r(theme.dialogTheme.shape), 12);
      expect(r(theme.popupMenuTheme.shape), 12);
      expect(r(theme.cardTheme.shape), 12);
      expect(r(theme.snackBarTheme.shape), 12);
      expect(r(theme.menuTheme.style!.shape!.resolve({})), 12);
      expect(r(theme.dropdownMenuTheme.menuStyle!.shape!.resolve({})), 12);
      for (final style in [
        theme.filledButtonTheme.style,
        theme.outlinedButtonTheme.style,
        theme.textButtonTheme.style,
        theme.elevatedButtonTheme.style,
        theme.iconButtonTheme.style,
      ]) {
        expect(r(style!.shape!.resolve({})), 8);
      }
      expect((theme.inputDecorationTheme.border! as OutlineInputBorder).borderRadius, BorderRadius.circular(8));
      expect((theme.inputDecorationTheme.errorBorder! as OutlineInputBorder).borderRadius, BorderRadius.circular(8));
      final square = appTheme(Brightness.dark, const {}, 0);
      expect((square.sliderTheme.thumbShape! as KnobShape).square, isTrue);
      expect(square.sliderTheme.thumbShape!.getPreferredSize(true, false), const Size.square(14));
      expect((theme.sliderTheme.thumbShape! as KnobShape).square, isFalse);
      expect(r(square.textButtonTheme.style!.shape!.resolve({})), 0);
    });

    testWidgets('the settings menu: four choices; Slightly rounded makes the window 6 px', (tester) async {
      await pump(tester, look: {'rounding': 10});
      Corners sizes() => Theme.of(tester.element(find.byType(Scaffold))).extension<Corners>()!;
      expect(sizes().radius, 10); // like windows
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      for (final label in ['Like windows', 'Slightly rounded (6 px)', 'Rounded (12 px)', 'Square']) {
        expect(find.text(label), findsOneWidget);
      }
      await tester.tap(find.ancestor(of: find.text('Slightly rounded (6 px)'), matching: find.byType(CheckedPopupMenuItem<String>)));
      await tester.pumpAndSettle();
      expect(settings['corners'], 'slight');
      expect(sizes().radius, 6);
      expect(sizes().control, 6);
      expect(sizes().small, 4);
    });

    testWidgets('an unknown stored value counts as like windows', (tester) async {
      settings['corners'] = 'odd';
      await pump(tester, look: {'rounding': 9});
      expect(Theme.of(tester.element(find.byType(Scaffold))).extension<Corners>()!.radius, 9);
    });
  });
}
