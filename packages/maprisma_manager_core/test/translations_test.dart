import 'dart:convert';
import 'dart:io';

import 'package:maprisma_manager_core/maprisma_manager_core.dart';
import 'package:maprisma_manager_core/src/translations_generated.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  final root = Directory.current.path.endsWith('maprisma_manager_core')
      ? Directory('../..').absolute : Directory.current;
  tearDown(() => configureLanguage('en'));

  test('system language uses first nonempty locale and supported base code', () {
    expect(systemLanguage({}), 'en');
    expect(systemLanguage({'LC_ALL': '', 'LC_MESSAGES': 'de_DE.UTF-8', 'LANG': 'fr_FR'}), 'de');
    expect(systemLanguage({'LC_ALL': 'pl_PL.UTF-8', 'LC_MESSAGES': 'de_DE'}), 'pl');
    expect(systemLanguage({'LC_ALL': 'xx_YY.UTF-8', 'LANG': 'de_DE'}), 'en');
    for (final code in languageNames.keys) {
      expect(systemLanguage({'LANG': '${code}_XX.UTF-8'}), code);
    }
    expect(systemLanguage({'LC_ALL': 'C.UTF-8'}), 'en');
    expect(systemLanguage({'LC_ALL': 'POSIX'}), 'en');
    configureLanguage('fr', {'LC_ALL': 'de_DE'});
    expect(currentLanguage, 'fr');
    configureLanguage('auto', {'LC_ALL': 'de_DE'});
    expect(currentLanguage, 'de');
    configureLanguage('invalid', {'LANG': 'nl_NL'});
    expect(currentLanguage, 'nl');
    expect(tr('A missing translation'), 'A missing translation');
    expect(trf('Value {0}; value {1}', ['{1}', 'two']), 'Value {1}; value two');
  });

  test('every literal translation key exists in every bundled catalog', () {
    // Literal keys may use either quote style; Dart escapes are decoded, including apostrophes.
    final calls = RegExp(r'''\btrf?\(\s*('(?:\\.|[^'\\])*'|"(?:\\.|[^"\\])*")''');
    final keys = <String>{};
    for (final dir in ['flutter_app/lib', 'packages/maprisma_manager_core/lib']) {
      for (final file in Directory('${root.path}/$dir').listSync(recursive: true).whereType<File>()) {
        if (!file.path.endsWith('.dart') || file.path.endsWith('translations_generated.dart')) continue;
        final source = file.readAsStringSync();
        for (final match in calls.allMatches(source)) {
          final literal = match[1]!;
          final key = literal.substring(1, literal.length - 1).replaceAllMapped(
            RegExp(r'\\(.)'), (m) => switch (m[1]) {
              'n' => '\n', 'r' => '\r', 't' => '\t', _ => m[1]!,
            },
          );
          keys.add(key);
        }
      }
    }
    expect(keys.length, greaterThan(600));
    Set<String> placeholders(String value) => RegExp(r'\{\d+\}').allMatches(value).map((m) => m[0]!).toSet();
    for (final code in languageNames.keys) {
      final base = jsonDecode(File('${root.path}/translations/$code.json').readAsStringSync()) as Map;
      final extra = jsonDecode(File('${root.path}/translations/extra/$code.json').readAsStringSync()) as Map;
      final merged = {...base, ...extra};
      expect(merged.keys.toSet().containsAll(keys), isTrue,
          reason: '$code missing: ${keys.difference(merged.keys.toSet())}');
      expect(catalogs[code], merged, reason: 'Run tools/gen-translations');
      for (final key in keys) {
        final value = merged[key];
        expect(value, isA<String>(), reason: '$code: $key');
        expect((value as String).isNotEmpty, isTrue, reason: '$code: $key');
        expect(placeholders(value), placeholders(key), reason: '$code: $key');
      }
    }
  });

  test('language persists, preserves other settings, and changes core errors immediately', () async {
    final world = World.create();
    addTearDown(world.dispose);
    final file = File(world.paths.settingsFile)..createSync(recursive: true);
    file.writeAsStringSync(jsonEncode({'other': 42}));
    final core = world.core(extra: {'LANG': 'de_DE.UTF-8'});
    expect((await core.call('settings.get'))['language'], 'auto');
    expect(currentLanguage, 'de');
    await core.call('settings.language', {'language': 'fr'});
    expect(currentLanguage, 'fr');
    expect(jsonDecode(file.readAsStringSync()), {'other': 42, 'language': 'fr'});
    expect(() => core.call('apps.open', {'id': 'not-an-app'}),
        throwsA(isA<RouteError>().having((e) => e.message, 'localized reason', trf('no app {0}', ['not-an-app']))));
    world.core(extra: {'LANG': 'pl_PL.UTF-8'});
    expect(currentLanguage, 'fr');
    await core.call('settings.language', {'language': 'auto'});
    expect(currentLanguage, 'de');
    await expectLater(core.call('settings.language', {'language': 'xx'}), throwsA(isA<RouteError>()));
    expect(jsonDecode(file.readAsStringSync())['language'], 'auto');
  });
}
