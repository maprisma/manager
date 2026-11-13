import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma_manager/app.dart';
import 'package:maprisma_manager_core/maprisma_manager_core.dart';

void main() {
  tearDown(() => configureLanguage('en'));

  testWidgets('all interface languages render with matching Material localization', (tester) async {
    var setting = 'en';
    Future<Map<String, dynamic>> core(String method, [Map<String, dynamic> params = const {}]) async => switch (method) {
      'settings.get' => {'language': setting},
      'apps.list' => {'apps': <Map<String, dynamic>>[], 'desktop': 'other'},
      _ => {},
    };
    for (final code in languageNames.keys) {
      setting = code;
      await tester.pumpWidget(ManagerApp(key: ValueKey(code), core: core, checkOnStart: false));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('apps-title')), findsOneWidget);
      expect(find.text(tr('Maprisma Apps')), findsWidgets);
      final context = tester.element(find.byType(Scaffold).first);
      expect(Localizations.localeOf(context).languageCode, code);
      expect(MaterialLocalizations.of(context).cancelButtonLabel, isNotEmpty);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('Language menu switches immediately and saves the selected code', (tester) async {
    var setting = 'en';
    Future<Map<String, dynamic>> core(String method, [Map<String, dynamic> params = const {}]) async {
      if (method == 'settings.get') return {'language': setting};
      if (method == 'settings.language') {
        setting = params['language'] as String;
        return {'language': setting};
      }
      return method == 'apps.list' ? {'apps': <Map<String, dynamic>>[], 'desktop': 'other'} : {};
    }
    await tester.pumpWidget(ManagerApp(core: core, checkOnStart: false));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('nav-settings')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-language')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Deutsch').last);
    await tester.pumpAndSettle();
    expect(setting, 'de');
    expect(find.text('Sprache'), findsOneWidget);
    expect(find.text('Einstellungen'), findsWidgets);
    expect(currentLanguage, 'de');
    expect(tester.takeException(), isNull);
  });

  // Last: it loads real fonts for the rest of this file.
  testWidgets('"Maprisma Apps" fits the sidebar in every language: the narrowest full window and the condensed list', (tester) async {
    var setting = 'en';
    Future<Map<String, dynamic>> core(String method, [Map<String, dynamic> params = const {}]) async => switch (method) {
      'settings.get' => {'language': setting},
      'apps.list' => {'apps': <Map<String, dynamic>>[], 'desktop': 'other'},
      _ => {},
    };
    // real letters (Roboto, Flutter's own copy) instead of the test font's boxes, so widths are real
    final roboto = File('${Platform.environment['FLUTTER_ROOT'] ?? '/mnt/Data/flutter'}/bin/cache/artifacts/material_fonts/Roboto-Regular.ttf');
    if (!roboto.existsSync()) {
      markTestSkipped('no Roboto in the Flutter cache');
      return;
    }
    for (final family in ['Roboto', 'FlutterTest']) {
      await tester.runAsync(() => (FontLoader(family)..addFont(Future.value(ByteData.sublistView(roboto.readAsBytesSync())))).load());
    }
    addTearDown(tester.view.reset);
    tester.view.devicePixelRatio = 1;
    for (final width in [648.0, 420.0]) {
      tester.view.physicalSize = Size(width, 720);
      for (final code in languageNames.keys) {
        setting = code;
        await tester.pumpWidget(ManagerApp(key: ValueKey('$code-$width'), core: core, checkOnStart: false));
        await tester.pumpAndSettle();
        // condensed: the page list behind the toggle
        if (width < 648) {
          await tester.tap(find.byKey(const ValueKey('nav-toggle')));
          await tester.pumpAndSettle();
        }
        final label = find.descendant(of: find.byKey(const ValueKey('nav-apps')), matching: find.text(tr('Maprisma Apps')));
        expect(label, findsOneWidget, reason: '$code at $width');
        final para = tester.renderObject<RenderParagraph>(label);
        expect(para.didExceedMaxLines, isFalse, reason: '$code at $width: cut off');
        expect(tester.takeException(), isNull);
      }
    }
  });
}
