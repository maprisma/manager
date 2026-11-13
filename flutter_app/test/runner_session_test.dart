// The runner's Hyprland check (linux/runner/desktop_session.h, shared by the Maprisma Flutter
// runners): compiled with the system's C compiler and glib and run with fake environments.
// Skipped where no compiler or glib is installed.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final header = File('linux/runner/desktop_session.h').absolute.path;
  late Directory dir;
  String? exe;

  setUpAll(() async {
    dir = Directory.systemTemp.createTempSync('runner-session');
    final flags = await Process.run('pkg-config', ['--cflags', '--libs', 'glib-2.0']);
    if (flags.exitCode != 0) return;
    File('${dir.path}/main.c').writeAsStringSync('#include "$header"\nint main(void) { return maprisma_on_hyprland() ? 0 : 1; }\n');
    final cc = await Process.run('cc', ['-o', '${dir.path}/check', '${dir.path}/main.c', ...'${flags.stdout}'.trim().split(RegExp(r'\s+'))]);
    if (cc.exitCode == 0) exe = '${dir.path}/check';
  });
  tearDownAll(() => dir.deleteSync(recursive: true));

  Future<bool> onHyprland(Map<String, String> env) async =>
      (await Process.run(exe!, const [], environment: env, includeParentEnvironment: false)).exitCode == 0;

  test('XDG_CURRENT_DESKTOP decides; a signature only counts without it and with its socket', () async {
    if (exe == null) {
      markTestSkipped('no C compiler or glib');
      return;
    }
    final runtime = '${dir.path}/run';
    final live = {'HYPRLAND_INSTANCE_SIGNATURE': 'abc', 'XDG_RUNTIME_DIR': runtime};
    expect(await onHyprland({'XDG_CURRENT_DESKTOP': 'Hyprland'}), isTrue);
    expect(await onHyprland({'XDG_CURRENT_DESKTOP': 'foo:hyprland'}), isTrue);
    expect(await onHyprland({}), isFalse);
    expect(await onHyprland(live), isFalse, reason: 'a stale signature: no socket');
    File('$runtime/hypr/abc/.socket.sock').createSync(recursive: true);
    expect(await onHyprland(live), isTrue);
    expect(await onHyprland({...live, 'XDG_CURRENT_DESKTOP': 'KDE'}), isFalse, reason: 'KDE named: the signature does not count');
    expect(await onHyprland({...live, 'XDG_CURRENT_DESKTOP': 'COSMIC'}), isFalse);
    expect(await onHyprland({...live, 'HYPRLAND_INSTANCE_SIGNATURE': '../hypr/abc'}), isFalse);
  });
}
