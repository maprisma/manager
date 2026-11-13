import 'dart:io';

import 'package:maprisma_manager_core/maprisma_manager_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'fakes.dart';
import 'support.dart';

void main() {
  late World w;
  setUp(() => w = World.create());
  tearDown(() => w.dispose());

  List<String> log() {
    final f = File(p.join(w.home, 'theme.log'));
    return f.existsSync() ? f.readAsLinesSync() : const [];
  }

  test('theme.list: Theme core\'s list without hidden themes; previews only when there; colours checked', () async {
    fakeThemeCore(w);
    final r = await w.core().call('theme.list');
    expect(r['current'], 'nord');
    final themes = (r['themes'] as List).cast<Map>();
    expect(themes.map((t) => t['slug']), ['nord', 'latte', 'autumn']);
    expect(themes[0], {
      'slug': 'nord',
      'name': 'Nord',
      'current': true,
      'favorite': true,
      'preview': p.join(w.home, 'themes/nord/preview.png'),
      'wallpapers': [p.join(w.home, 'themes/nord/backgrounds/b.png'), p.join(w.home, 'themes/nord/backgrounds/a.png')],
      'mode': 'dark',
      'colors': {'background': '#2e3440', 'foreground': '#d8dee9', 'accent': '#88c0d0'},
    });
    expect(themes[1]['mode'], 'light');
    expect(themes[1]['wallpapers'], isEmpty, reason: 'no preview to flip from');
    expect(themes[2]['preview'], isNull, reason: 'the file is not there');
    expect((themes[2]['colors'] as Map).containsKey('green'), isFalse, reason: 'not a colour');
  });

  test('theme.apply runs Theme core\'s apply; its refusals and bad slugs come back as errors', () async {
    fakeThemeCore(w);
    final core = w.core();
    final r = await core.call('theme.apply', {'slug': 'latte'});
    expect(r['applied'], 'latte');
    expect(log(), ['apply latte']);
    expect(((await core.call('theme.list'))['current']), 'latte');
    await expectLater(core.call('theme.apply', {'slug': 'broken'}), throwsA(isA<RouteError>().having((e) => e.code, 'code', 'not_found')));
    for (final bad in ['-x', '../etc', '', 'a b']) {
      await expectLater(core.call('theme.apply', {'slug': bad}), throwsA(isA<RouteError>().having((e) => e.code, 'code', 'bad_params')), reason: bad);
    }
    await expectLater(core.call('theme.apply', {'slug': 3}), throwsA(isA<RouteError>()));
    expect(log(), ['apply latte', 'apply broken']);
  });

  test('without Theme: not_installed; an older Theme core without list: too_old', () async {
    await expectLater(w.core().call('theme.list'), throwsA(isA<RouteError>().having((e) => e.code, 'code', 'not_installed')));
    fakeThemeCore(w, old: true);
    await expectLater(w.core().call('theme.list'), throwsA(isA<RouteError>().having((e) => e.code, 'code', 'too_old')));
  });

  test('MAPRISMA_THEME_CORE names another Theme core build', () async {
    fakeThemeCore(w);
    final other = p.join(w.dir, 'other-core');
    w.writeFile(other, '#!/bin/sh\necho \'{"current":"x","themes":[]}\'\n', mode: '755');
    final r = await w.core(extra: {'MAPRISMA_THEME_CORE': other}).call('theme.list');
    expect(r['current'], 'x');
    expect(r['themes'], isEmpty);
    // not absolute: ignored
    expect((await w.core(extra: {'MAPRISMA_THEME_CORE': 'other-core'}).call('theme.list'))['current'], 'nord');
  });

  test('theme.list: the preview settings from Theme core, else read from Theme\'s settings.json, else defaults', () async {
    fakeThemeCore(w);
    const defaults = {'preview_flip_3d': true, 'preview_flip_delay': 2.0, 'preview_big_auto_rotate': true};
    expect((await w.core().call('theme.list'))['settings'], defaults);
    final file = p.join(w.home, '.config/maprisma-theme/settings.json');
    w.writeFile(file, '{"preview_flip_3d":false,"preview_flip_delay":1.5,"preview_big_auto_rotate":false,"language":"de"}');
    expect((await w.core().call('theme.list'))['settings'], {'preview_flip_3d': false, 'preview_flip_delay': 1.5, 'preview_big_auto_rotate': false});
    w.writeFile(file, '{"preview_flip_3d":"no","preview_flip_delay":7}');
    expect((await w.core().call('theme.list'))['settings'], defaults, reason: 'values Theme would refuse');
    w.writeFile(file, 'not json');
    expect((await w.core().call('theme.list'))['settings'], defaults);
    // a newer Theme core says them itself; the file is not asked then
    final other = p.join(w.dir, 'other-core');
    w.writeFile(other, '#!/bin/sh\necho \'{"current":"x","themes":[],"settings":{"preview_flip_3d":true,"preview_flip_delay":0,"preview_big_auto_rotate":false}}\'\n', mode: '755');
    expect((await w.core(extra: {'MAPRISMA_THEME_CORE': other}).call('theme.list'))['settings'],
        {'preview_flip_3d': true, 'preview_flip_delay': 0.0, 'preview_big_auto_rotate': false});
    expect(File(file).readAsStringSync(), 'not json', reason: 'never written');
  });
}
