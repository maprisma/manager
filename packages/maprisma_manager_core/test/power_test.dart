import 'dart:convert';
import 'dart:io';

import 'package:maprisma_manager_core/maprisma_manager_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late World w;
  setUp(() => w = World.create());
  tearDown(() => w.dispose());

  String shellFile() => p.join(w.home, '.config/maprisma-shell/shell.json');
  Map<String, dynamic> stored() => jsonDecode(File(shellFile()).readAsStringSync()) as Map<String, dynamic>;

  /// A fake powerprofilesctl: `list` with the profile in $HOME/profile starred, `set` writes it.
  void profiles({String current = 'balanced'}) {
    w.writeFile(p.join(w.home, 'profile'), current);
    w.writeFile(p.join(w.fakeBin, 'powerprofilesctl'), r'''#!/bin/sh
read cur < "$HOME/profile"
case "$1" in
  list)
    for x in performance balanced power-saver; do
      if [ "$x" = "$cur" ]; then echo "* $x:"; else echo "  $x:"; fi
      echo "    CpuDriver:	amd_pstate"
      echo
    done ;;
  set)
    case "$2" in performance|balanced|power-saver) echo "$2" > "$HOME/profile" ;; *) echo "bad" >&2; exit 1 ;; esac ;;
esac
''', mode: '755');
  }

  test('Hyprland: the idle times (defaults without a file) and the profiles', () async {
    profiles(current: 'performance');
    final r = await w.core(desktop: 'Hyprland').call('power.get');
    expect(r['desktop'], 'hyprland');
    expect(r['native'], isNull);
    expect(r['idle'], allOf(containsPair('lock', 180), containsPair('screenOff', 300), containsPair('suspend', 600), containsPair('whilePlaying', false), containsPair('exists', false)));
    expect(r['profiles'], {'available': true, 'list': ['performance', 'balanced', 'power-saver'], 'current': 'performance'});
  });

  test('set_idle keeps the wallpaper and unknown keys, and bad values count as the shell reads them', () async {
    w.writeFile(shellFile(), jsonEncode({'wallpaper': '/w.jpg', 'idle': {'lock': -1, 'screenOff': 120, 'future': 1}, 'other': true}));
    final core = w.core(desktop: 'Hyprland');
    expect((await core.call('power.get'))['idle'], containsPair('lock', 180));
    final r = await core.call('power.set_idle', {'suspend': 0, 'whilePlaying': true});
    expect(r['idle'], allOf(containsPair('suspend', 0), containsPair('screenOff', 120), containsPair('whilePlaying', true)));
    expect(stored(), {
      'wallpaper': '/w.jpg',
      'idle': {'lock': 180, 'screenOff': 120, 'future': 1, 'suspend': 0, 'whilePlaying': true},
      'other': true,
    });
  });

  test('set_idle refuses bad values, a broken file and other desktops', () async {
    final core = w.core(desktop: 'Hyprland');
    for (final bad in [{'lock': -5}, {'lock': 1.5}, {'suspend': PowerService.idleMax + 1}, {'whilePlaying': 'yes'}, <String, dynamic>{}]) {
      await expectLater(core.call('power.set_idle', bad), throwsA(isA<RouteError>().having((e) => e.code, 'code', 'bad_params')));
    }
    w.writeFile(shellFile(), '{not json');
    await expectLater(core.call('power.set_idle', {'lock': 60}), throwsA(isA<RouteError>().having((e) => e.code, 'code', 'unreadable')));
    expect(File(shellFile()).readAsStringSync(), '{not json');
    expect((await core.call('power.get'))['idle'], contains('error'));
    await expectLater(w.core(desktop: 'COSMIC').call('power.set_idle', {'lock': 60}), throwsA(isA<RouteError>().having((e) => e.code, 'code', 'unavailable')));
  });

  test('set_profile: only a listed profile, through powerprofilesctl', () async {
    profiles();
    final core = w.core(desktop: 'Hyprland');
    final r = await core.call('power.set_profile', {'profile': 'power-saver'});
    expect((r['profiles'] as Map)['current'], 'power-saver');
    await expectLater(core.call('power.set_profile', {'profile': 'turbo'}), throwsA(isA<RouteError>().having((e) => e.code, 'code', 'bad_params')));
  });

  test('COSMIC and KDE: their own settings app, no idle times or profiles here', () async {
    profiles();
    w.writeFile(p.join(w.fakeBin, 'cosmic-settings'), '#!/bin/sh\n', mode: '755');
    final cosmic = await w.core(desktop: 'COSMIC').call('power.get');
    expect(cosmic['native'], {'name': 'COSMIC Settings', 'available': true});
    expect(cosmic['idle'], isNull);
    expect(cosmic['profiles'], isNull);
    final kde = await w.core(desktop: 'KDE').call('power.get');
    expect(kde['native'], {'name': 'System Settings', 'available': false});
    await expectLater(w.core(desktop: 'KDE').call('power.open_native'), throwsA(isA<RouteError>().having((e) => e.code, 'code', 'unavailable')));
    await expectLater(w.core(desktop: 'COSMIC').call('power.set_profile', {'profile': 'balanced'}), throwsA(isA<RouteError>()));
  });

  test('another desktop: profiles only; no powerprofilesctl: none', () async {
    final r = await w.core(desktop: 'sway').call('power.get');
    expect(r['desktop'], 'other');
    expect(r['idle'], isNull);
    expect(r['profiles'], isNull);
  });
}
