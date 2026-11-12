import 'package:flutter/material.dart';
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
      expect(find.text(tr('Apps')), findsWidgets);
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
}
