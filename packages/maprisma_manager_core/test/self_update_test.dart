// Step 6: the Manager updates itself (jobs_self.dart, tools/self-update, tools/install-local
// --integrate) in a temp HOME. The repo's install-local is a fake for --stage (a tiny bundle of
// shell scripts) and the real one for --integrate; the helper is the real tools/self-update. The
// running Manager window is a fake /proc entry (the helper is pointed at the same fake /proc), so
// nothing real is waited for or ended; the "new Manager" the helper starts is a shell script that
// writes its ready file (or doesn't).
import 'dart:convert';
import 'dart:io';

import 'package:maprisma_manager_core/maprisma_manager_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

final _repoRoot = p.normalize(p.join(Directory.current.path, '../..'));

const _fakeInstall = r'''#!/bin/bash
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
[[ ${1:-} == --stage ]] || { echo "fake install-local: only --stage" >&2; exit 2; }
stage=$2
ctl="$HOME/.mm-test"
mkdir -p "$stage/bundle/lib" "$stage/bundle/bin" "$stage/bundle/data/flutter_assets" "$stage/tools" "$stage/packaging"
build=$(cat "$ctl/build" 2>/dev/null || echo 1)
if [[ -e $ctl/never-ready ]]; then
  printf '#!/bin/sh\nexit 0\n' > "$stage/bundle/maprisma-manager"
else
  printf '#!/bin/sh\n[ -n "${MAPRISMA_MANAGER_READY:-}" ] && echo $$ > "$MAPRISMA_MANAGER_READY"\necho "started build %s" >> "$HOME/.mm-test/started"\n' "$build" > "$stage/bundle/maprisma-manager"
fi
chmod 755 "$stage/bundle/maprisma-manager"
echo "lib $build" > "$stage/bundle/lib/libapp.so"
echo flutter > "$stage/bundle/lib/libflutter_linux_gtk.so"
echo icu > "$stage/bundle/data/icudtl.dat"
echo "{\"version\":\"0.1.$build\"}" > "$stage/bundle/data/flutter_assets/version.json"
cat > "$stage/bundle/bin/maprisma-manager-core" <<'CORE'
#!/bin/sh
if [ "$1" = version ]; then echo "maprisma-manager-core 0.1.0"; exit 0; fi
echo "$*" >> "$HOME/.mm-test/core-calls"
CORE
chmod 755 "$stage/bundle/bin/maprisma-manager-core"
[[ -e $ctl/no-core ]] && rm "$stage/bundle/bin/maprisma-manager-core"
cp "$here/tools/real-install-local" "$stage/tools/install-local"
cp "$here/tools/self-update" "$stage/tools/self-update"
chmod 755 "$stage/tools/install-local" "$stage/tools/self-update"
cp "$here/packaging/"* "$stage/packaging/"
echo "staged build $build"
''';

const _tools = [
  'sh', 'bash', 'cp', 'mv', 'rm', 'mkdir', 'chmod', 'ln', 'cat', 'sleep', 'setsid', 'head', 'grep', 'mktemp',
  'readlink', 'ls', 'touch', 'env', 'dirname', 'basename', 'true', 'false', 'printf', 'rmdir', 'echo', 'date',
  'seq', 'install', 'kill',
];

void main() {
  late World w;
  late String ctl;
  late String sysbin;
  late String repo;

  setUp(() {
    w = World.create();
    ctl = p.join(w.home, '.mm-test');
    Directory(ctl).createSync(recursive: true);
    sysbin = p.join(w.dir, 'sysbin');
    Directory(sysbin).createSync();
    for (final t in _tools) {
      for (final d in ['/usr/bin', '/bin']) {
        if (File(p.join(d, t)).existsSync()) {
          Link(p.join(sysbin, t)).createSync(p.join(d, t));
          break;
        }
      }
    }
    for (final f in ['flutter', 'dart']) {
      w.fake(f, 'exit 0');
    }
    repo = w.repo('maprisma-manager');
    w.writeFile(p.join(repo, 'tools/install-local'), _fakeInstall, mode: '755');
    File(p.join(_repoRoot, 'tools/install-local')).copySync(p.join(repo, 'tools/real-install-local'));
    File(p.join(_repoRoot, 'tools/self-update')).copySync(p.join(repo, 'tools/self-update'));
    for (final f in ['com.maprisma.Manager.desktop', 'com.maprisma.Manager.svg']) {
      w.writeFile(p.join(repo, 'packaging', f), File(p.join(_repoRoot, 'packaging', f)).readAsStringSync());
    }
  });

  tearDown(() => w.dispose());

  CoreService core() {
    final c = CoreService(
      environment: w.env(extra: {'PATH': '${w.fakeBin}:$sysbin', 'MAPRISMA_FLUTTER': p.join(w.fakeBin, 'flutter')}),
      uid: 1000,
    )..followPanel = (_) async => {'panel': null, 'note': 'test'};
    c.jobs
      ..pollEvery = const Duration(milliseconds: 30)
      ..selfReadyTimeout = const Duration(seconds: 3);
    return c;
  }

  Future<Map<String, dynamic>> run(CoreService c, String kind) async {
    final j = await c.call('jobs.start', {'app': 'manager', 'kind': kind});
    return c.jobs.done(j['id'] as String)!;
  }

  String lib() => p.join(w.home, '.local/lib/maprisma-manager');
  String selfDir() => p.join(w.paths.managerState, 'self-update');
  Map<String, dynamic> receipt() => jsonDecode(File(p.join(w.paths.receipts, 'manager.json')).readAsStringSync()) as Map<String, dynamic>;

  Future<String> waitStatus(String id, bool Function(String) done) async {
    final f = File(p.join(selfDir(), '$id.status'));
    for (var i = 0; i < 200; i++) {
      final s = f.existsSync() ? f.readAsStringSync().trim() : '';
      if (done(s)) return s;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    fail('the helper did not get there: ${f.existsSync() ? f.readAsStringSync() : 'no status'}\n${File(p.join(selfDir(), '$id.log')).readAsStringSync()}');
  }

  test('without a Manager window: staged, checked, swapped in by the helper, verified, receipt written', () async {
    final c = core();
    final job = await run(c, 'install');
    expect(job['state'], 'succeeded', reason: File(job['log'] as String).readAsStringSync());
    expect(job['result']['selfUpdate']['state'], 'done');
    expect(File(p.join(lib(), 'lib/libapp.so')).readAsStringSync(), 'lib 1\n');
    expect(Link(p.join(w.home, '.local/bin/maprisma-manager')).targetSync(), p.join(lib(), 'maprisma-manager'));
    expect(Link(p.join(w.home, '.local/bin/maprisma-manager-core')).targetSync(), p.join(lib(), 'bin/maprisma-manager-core'));
    final entry = File(p.join(w.paths.apps, 'com.maprisma.Manager.desktop')).readAsStringSync();
    expect(entry, contains('Exec="${p.join(w.home, '.local/bin/maprisma-manager')}"'));
    expect(File(p.join(w.paths.icons, 'com.maprisma.Manager.svg')).existsSync(), isTrue);
    final r = receipt();
    expect(r['version'], '0.1.1');
    expect((r['trees'] as List).single['root'], lib());
    expect(r['inputs'].single['repo'], 'maprisma-manager');
    // the stage is gone, no window was started
    expect(Directory(p.join(selfDir(), job['id'] as String)).existsSync(), isFalse);
    expect(File(p.join(ctl, 'started')).existsSync(), isFalse);
    final list = await c.call('apps.list');
    final m = appOf(list, 'manager');
    expect(m['state'], 'installed');
    expect(m['build']['known'], isTrue);
    expect(m['support']['install'], isTrue);
    expect(m['support']['remove'], isFalse);
    expect(m['icon']['file'], p.join(w.paths.icons, 'com.maprisma.Manager.svg'));
  });

  test('with a Manager window: the job ends, the helper waits for it to quit, swaps, starts the new one, which is ready', () async {
    final c = core();
    expect((await run(c, 'install'))['state'], 'succeeded');
    File(p.join(ctl, 'build')).writeAsStringSync('2');
    // a Manager window of the installed build
    w.process(424242, exe: p.join(lib(), 'maprisma-manager'), start: 777);
    final job = await run(c, 'reinstall');
    final id = job['id'] as String;
    expect(job['state'], 'succeeded', reason: File(job['log'] as String).readAsStringSync());
    expect(job['result']['restart'], isTrue);
    expect(job['result']['selfUpdate']['state'], 'waiting');
    expect(job['result']['selfUpdate']['waitFor'], [424242]);
    await waitStatus(id, (s) => s.startsWith('waiting '));
    // nothing swapped while the window is open; a second Manager job is refused meanwhile
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(File(p.join(lib(), 'lib/libapp.so')).readAsStringSync(), 'lib 1\n');
    await expectLater(c.call('jobs.start', {'app': 'manager', 'kind': 'reinstall'}), throwsA(isA<RouteError>().having((e) => e.code, 'code', 'busy')));
    // the window quits
    Directory(p.join(w.proc, '424242')).deleteSync(recursive: true);
    final s = await waitStatus(id, (s) => s == 'done' || s.startsWith('rolled') || s.startsWith('failed'));
    expect(s, 'done', reason: File(p.join(selfDir(), '$id.log')).readAsStringSync());
    expect(File(p.join(lib(), 'lib/libapp.so')).readAsStringSync(), 'lib 2\n');
    expect(File(p.join(ctl, 'started')).readAsStringSync(), contains('started build 2'));
    // the new core was asked to record it (the fake core only notes the call): do what it does
    expect(File(p.join(ctl, 'core-calls')).readAsStringSync().trim(), 'self-update-done $id');
    final done = finishSelfUpdate(w.paths, id);
    expect(done['selfUpdate'], 'done');
    expect(receipt()['version'], '0.1.2');
    expect(receipt()['job'], id);
    final again = (await c.call('jobs.get', {'id': id}));
    expect(again['state'], 'succeeded');
    expect(again['result']['selfUpdate']['state'], 'done');
    // only once
    expect(() => finishSelfUpdate(w.paths, id), throwsA(isA<RouteError>().having((e) => e.code, 'code', 'finished')));
    // no old bundle left beside it
    expect(Directory(p.dirname(lib())).listSync().map((e) => p.basename(e.path)), ['maprisma-manager']);
  });

  test('a new Manager that is not ready in time: rolled back to the old bundle, the old one started, the job failed', () async {
    final c = core();
    expect((await run(c, 'install'))['state'], 'succeeded');
    final oldEntry = File(p.join(w.paths.apps, 'com.maprisma.Manager.desktop')).readAsStringSync();
    File(p.join(ctl, 'build')).writeAsStringSync('3');
    File(p.join(ctl, 'never-ready')).writeAsStringSync('');
    w.process(424243, exe: p.join(lib(), 'maprisma-manager'), start: 778);
    final job = await run(c, 'reinstall');
    final id = job['id'] as String;
    expect(job['result']['restart'], isTrue);
    Directory(p.join(w.proc, '424243')).deleteSync(recursive: true);
    final s = await waitStatus(id, (s) => s == 'done' || s.startsWith('rolled') || s.startsWith('failed'));
    expect(s, startsWith('rolled back: the new Manager wasn\'t ready within 3 s'));
    expect(File(p.join(lib(), 'lib/libapp.so')).readAsStringSync(), 'lib 1\n');
    expect(File(p.join(w.paths.apps, 'com.maprisma.Manager.desktop')).readAsStringSync(), oldEntry);
    // the old build was started again (it writes "started build 1")
    expect(File(p.join(ctl, 'started')).readAsStringSync(), contains('started build 1'));
    final call = File(p.join(ctl, 'core-calls')).readAsStringSync().trim();
    expect(call, startsWith('self-update-done $id --failed'));
    finishSelfUpdate(w.paths, id, failed: 'the new Manager wasn\'t ready within 3 s; the old build is back');
    final j = await c.call('jobs.get', {'id': id});
    expect(j['state'], 'failed');
    expect(j['result']['code'], 'self_update_failed');
    expect(receipt()['version'], '0.1.1');
    expect(Directory(p.dirname(lib())).listSync().map((e) => p.basename(e.path)), ['maprisma-manager']);
  });

  test('a stage without the core is refused before anything is touched', () async {
    final c = core();
    File(p.join(ctl, 'no-core')).writeAsStringSync('');
    final job = await run(c, 'install');
    expect(job['state'], 'failed');
    expect(job['result']['code'], 'bad_stage');
    expect(job['result']['repair'], isFalse);
    expect(Directory(lib()).existsSync(), isFalse);
    expect(File(p.join(selfDir(), 'helper')).existsSync(), isFalse);
  });

  test('the Manager is not removed by itself: self_remove names the terminal script', () async {
    final c = core();
    await expectLater(c.call('jobs.start', {'app': 'manager', 'kind': 'remove'}),
        throwsA(isA<RouteError>().having((e) => e.code, 'code', 'self_remove').having((e) => e.message, 'message', contains('tools/uninstall-local'))));
    await expectLater(c.call('apps.remove_plan', {'id': 'manager'}), throwsA(isA<RouteError>().having((e) => e.code, 'code', 'self_remove')));
  });

  test('desktop.look reads COSMIC\'s palette and corners', () async {
    final theme = p.join(w.paths.config, 'cosmic/com.system76.CosmicTheme.Dark/v1');
    w.writeFile(p.join(w.paths.config, 'cosmic/com.system76.CosmicTheme.Mode/v1/is_dark'), 'true');
    w.writeFile(p.join(theme, 'accent'), '(\n    base: (red: 0.0, green: 0.5, blue: 1.0, alpha: 1.0),\n)');
    w.writeFile(p.join(theme, 'background'), '(\n    base: (red: 0.1, green: 0.1, blue: 0.1, alpha: 1.0),\n    on: (red: 0.9, green: 0.9, blue: 0.9, alpha: 1.0),\n)');
    w.writeFile(p.join(theme, 'corner_radii'), '(\n    radius_0: (0.0, 0.0, 0.0, 0.0),\n    radius_s: (12.0, 12.0, 12.0, 12.0),\n)');
    final look = await core().call('desktop.look');
    expect(look['desktop'], 'cosmic');
    expect(look['colors']['accent'], '#0080ff');
    expect(look['colors']['background'], '#1a1a1a');
    expect(look['colors']['foreground'], '#e6e6e6');
    expect(look['rounding'], 12);
    expect(look['is_dark'], isTrue);
    final kde = await w.core(desktop: 'KDE').call('desktop.look');
    expect(kde['colors']['accent'], '#3daee9');
    expect((await w.core(desktop: 'X').call('desktop.look'))['colors'], isEmpty);
  });
}
