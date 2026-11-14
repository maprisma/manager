// Step 6: Maprisma Settings (formerly Maprisma Manager) updates itself (jobs_self.dart, tools/self-update, tools/install-local
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
  printf '#!/bin/sh\nexit 0\n' > "$stage/bundle/maprisma-settings"
else
  printf '#!/bin/sh\n[ -n "${MAPRISMA_MANAGER_READY:-}" ] && echo $$ > "$MAPRISMA_MANAGER_READY"\necho "started build %s" >> "$HOME/.mm-test/started"\nls -l /proc/$$/fd > "$HOME/.mm-test/gui-fds"\n' "$build" > "$stage/bundle/maprisma-settings"
fi
chmod 755 "$stage/bundle/maprisma-settings"
echo "lib $build" > "$stage/bundle/lib/libapp.so"
echo flutter > "$stage/bundle/lib/libflutter_linux_gtk.so"
echo icu > "$stage/bundle/data/icudtl.dat"
echo "{\"version\":\"0.1.$build\"}" > "$stage/bundle/data/flutter_assets/version.json"
cat > "$stage/bundle/bin/maprisma-settings-core" <<'CORE'
#!/bin/sh
# answers with the name it was started by, as the real core does (cli.dart cliName)
if [ "$1" = version ]; then echo "$(basename "$0") 0.1.0"; exit 0; fi
echo "$*" >> "$HOME/.mm-test/core-calls"
CORE
chmod 755 "$stage/bundle/bin/maprisma-settings-core"
[[ -e $ctl/no-core ]] && rm "$stage/bundle/bin/maprisma-settings-core"
# the bar icon (bar/, Rust): a COSMIC applet that ends at once and a tray that notes its open
# files (a lock it holds would block every later install); none without cargo (no-bar)
printf '#!/bin/sh\nexit 0\n' > "$stage/bundle/bin/maprisma-settings-applet"
printf '#!/bin/sh\nls -l /proc/$$/fd > "$HOME/.mm-test/tray-fds"\n' > "$stage/bundle/bin/maprisma-settings-tray"
chmod 755 "$stage/bundle/bin/maprisma-settings-applet" "$stage/bundle/bin/maprisma-settings-tray"
[[ -e $ctl/no-bar ]] && rm "$stage/bundle/bin/maprisma-settings-applet" "$stage/bundle/bin/maprisma-settings-tray"
# the old names, as the real install-local's compat_links makes them
ln -s maprisma-settings "$stage/bundle/maprisma-manager"
for f in core applet tray; do
  [[ -e $stage/bundle/bin/maprisma-settings-$f ]] && ln -s "maprisma-settings-$f" "$stage/bundle/bin/maprisma-manager-$f"
done
cp "$here/tools/real-install-local" "$stage/tools/install-local"
[[ -e $ctl/bad-integrate ]] && printf '#!/bin/sh\n[ "$1" = --integrate ] && exit 1\nexit 0\n' > "$stage/tools/install-local"
cp "$here/tools/self-update" "$stage/tools/self-update"
cp "$here/tools/procs.sh" "$stage/tools/procs.sh"
chmod 755 "$stage/tools/install-local" "$stage/tools/self-update"
cp "$here/packaging/"* "$stage/packaging/"
echo "staged build $build"
''';

const _tools = [
  'sh', 'bash', 'cp', 'mv', 'rm', 'mkdir', 'chmod', 'ln', 'cat', 'sleep', 'setsid', 'head', 'grep', 'mktemp',
  'readlink', 'ls', 'touch', 'env', 'dirname', 'basename', 'true', 'false', 'printf', 'rmdir', 'echo', 'date',
  'seq', 'install', 'kill', 'flock', 'sed', 'cut', 'stat',
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
    File(p.join(_repoRoot, 'tools/procs.sh')).copySync(p.join(repo, 'tools/procs.sh'));
    for (final f in Directory(p.join(_repoRoot, 'packaging')).listSync().map((e) => p.basename(e.path))) {
      w.writeFile(p.join(repo, 'packaging', f), File(p.join(_repoRoot, 'packaging', f)).readAsStringSync());
    }
  });

  tearDown(() => w.dispose());

  CoreService core({String desktop = 'COSMIC'}) {
    final c = CoreService(
      environment: w.env(desktop: desktop, extra: {'PATH': '${w.fakeBin}:$sysbin', 'MAPRISMA_FLUTTER': p.join(w.fakeBin, 'flutter')}),
      uid: 1000,
    )..followPanel = (_) async => {'panel': null, 'note': 'test'};
    c.jobs
      ..pollEvery = const Duration(milliseconds: 30)
      ..selfReadyTimeout = const Duration(seconds: 3);
    return c;
  }

  Future<Map<String, dynamic>> run(CoreService c, String kind) async {
    final j = await c.call('jobs.start', {'app': 'settings', 'kind': kind});
    return c.jobs.done(j['id'] as String)!;
  }

  String lib() => p.join(w.home, '.local/lib/maprisma-settings');
  String selfDir() => p.join(w.paths.managerState, 'self-update');
  Map<String, dynamic> receipt() => jsonDecode(File(p.join(w.paths.receipts, 'settings.json')).readAsStringSync()) as Map<String, dynamic>;

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
    expect(Link(p.join(w.home, '.local/bin/maprisma-settings')).targetSync(), p.join(lib(), 'maprisma-settings'));
    expect(Link(p.join(w.home, '.local/bin/maprisma-settings-core')).targetSync(), p.join(lib(), 'bin/maprisma-settings-core'));
    // the old names: links to the bundle's links of the old name, which point to the new programs
    expect(Link(p.join(w.home, '.local/bin/maprisma-manager')).targetSync(), p.join(lib(), 'maprisma-manager'));
    expect(Link(p.join(w.home, '.local/bin/maprisma-manager-core')).targetSync(), p.join(lib(), 'bin/maprisma-manager-core'));
    expect(File(p.join(w.home, '.local/bin/maprisma-manager')).resolveSymbolicLinksSync(), p.join(lib(), 'maprisma-settings'));
    final entry = File(p.join(w.paths.apps, 'com.maprisma.Settings.desktop')).readAsStringSync();
    expect(entry, contains('Exec="${p.join(w.home, '.local/bin/maprisma-settings')}"'));
    expect(entry, contains('Name=Maprisma Settings'));
    expect(entry, isNot(contains('NoDisplay')));
    final compat = File(p.join(w.paths.apps, 'com.maprisma.Manager.desktop')).readAsStringSync();
    expect(compat, contains('NoDisplay=true'));
    expect(compat, contains('Exec="${p.join(w.home, '.local/bin/maprisma-settings')}"'));
    expect(File(p.join(w.paths.icons, 'com.maprisma.Settings.svg')).existsSync(), isTrue);
    expect(File(p.join(w.paths.icons, 'com.maprisma.Manager.svg')).existsSync(), isTrue);
    final r = receipt();
    expect(r['version'], '0.1.1');
    expect((r['trees'] as List).single['root'], lib());
    expect(r['inputs'].single['repo'], 'maprisma-manager');
    // the stage is gone, no window was started
    expect(Directory(p.join(selfDir(), job['id'] as String)).existsSync(), isFalse);
    expect(File(p.join(ctl, 'started')).existsSync(), isFalse);
    final list = await c.call('apps.list');
    final m = appOf(list, 'settings');
    expect(m['state'], 'installed');
    expect(m['build']['known'], isTrue);
    expect(m['support']['install'], isTrue);
    expect(m['support']['remove'], isFalse);
    expect(m['icon']['file'], p.join(w.paths.icons, 'com.maprisma.Settings.svg'));
  });

  test('without cargo (no bar binaries): the self-update succeeds, the Manager is partly installed (no bar icon)', () async {
    File(p.join(ctl, 'no-bar')).createSync();
    final c = core();
    final job = await run(c, 'install');
    expect(job['state'], 'succeeded', reason: File(job['log'] as String).readAsStringSync());
    expect(File(job['log'] as String).readAsStringSync(), contains('partly installed: no bar icon'));
    final m = appOf(await c.call('apps.list'), 'settings');
    expect(m['state'], 'partial');
    // the bar icon's picture is there anyway (the main part)
    expect(File(p.join(w.paths.icons, 'io.github.ubruckhaus.CosmicMaprismaManager-symbolic.svg')).existsSync(), isTrue);
  });

  test('on Hyprland the new tray is started without the self-update lock open', () async {
    final c = core(desktop: 'Hyprland');
    final job = await run(c, 'install');
    expect(job['state'], 'succeeded', reason: File(job['log'] as String).readAsStringSync());
    final fds = File(p.join(ctl, 'tray-fds'));
    for (var i = 0; i < 40 && !fds.existsSync(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(fds.existsSync(), isTrue, reason: 'the tray was not started');
    expect(fds.readAsStringSync(), isNot(contains('self-update/lock')));
  });

  test('with a Manager window: the job ends, the helper waits for it to quit, swaps, starts the new one, which is ready', () async {
    final c = core();
    expect((await run(c, 'install'))['state'], 'succeeded');
    File(p.join(ctl, 'build')).writeAsStringSync('2');
    // a Manager window of the installed build
    w.process(424242, exe: p.join(lib(), 'maprisma-settings'), start: 777);
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
    // (by its old id too)
    await expectLater(c.call('jobs.start', {'app': 'manager', 'kind': 'reinstall'}), throwsA(isA<RouteError>().having((e) => e.code, 'code', 'busy')));
    // nothing else starts either while the window has to quit for it
    await expectLater(c.call('jobs.start', {'app': 'wlan', 'kind': 'install'}), throwsA(isA<RouteError>().having((e) => e.code, 'code', 'busy')));
    // the window quits
    Directory(p.join(w.proc, '424242')).deleteSync(recursive: true);
    final s = await waitStatus(id, (s) => s == 'done' || s.startsWith('rolled') || s.startsWith('failed'));
    expect(s, 'done', reason: File(p.join(selfDir(), '$id.log')).readAsStringSync());
    expect(File(p.join(lib(), 'lib/libapp.so')).readAsStringSync(), 'lib 2\n');
    expect(File(p.join(ctl, 'started')).readAsStringSync(), contains('started build 2'));
    // without the helper's lock: everything its jobs start would inherit it (a restarted shell …)
    expect(File(p.join(ctl, 'gui-fds')).readAsStringSync(), isNot(contains('self-update/lock')));
    // the new core was asked to record it (the fake core only notes the call): do what it does
    // then the bar icon of the new build (also after the first install, which records nothing)
    expect(File(p.join(ctl, 'core-calls')).readAsStringSync().trim().split('\n'), ['self-update-bar', 'self-update-done $id', 'self-update-bar']);
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
    expect(Directory(p.dirname(lib())).listSync().map((e) => p.basename(e.path)), ['maprisma-settings']);
  });

  test('a new Manager that is not ready in time: rolled back to the old bundle, the old one started, the job failed', () async {
    final c = core();
    expect((await run(c, 'install'))['state'], 'succeeded');
    final oldEntry = File(p.join(w.paths.apps, 'com.maprisma.Settings.desktop')).readAsStringSync();
    File(p.join(ctl, 'build')).writeAsStringSync('3');
    File(p.join(ctl, 'never-ready')).writeAsStringSync('');
    w.process(424243, exe: p.join(lib(), 'maprisma-settings'), start: 778);
    final job = await run(c, 'reinstall');
    final id = job['id'] as String;
    expect(job['result']['restart'], isTrue);
    Directory(p.join(w.proc, '424243')).deleteSync(recursive: true);
    final s = await waitStatus(id, (s) => s == 'done' || s.startsWith('rolled') || s.startsWith('failed'));
    expect(s, startsWith('rolled back: the new Maprisma Settings wasn\'t ready within 3 s'));
    expect(File(p.join(lib(), 'lib/libapp.so')).readAsStringSync(), 'lib 1\n');
    expect(File(p.join(w.paths.apps, 'com.maprisma.Settings.desktop')).readAsStringSync(), oldEntry);
    // the old build was started again (it writes "started build 1")
    expect(File(p.join(ctl, 'started')).readAsStringSync(), contains('started build 1'));
    // a rollback leaves the bar icon alone (the old build is the one in place)
    final calls = File(p.join(ctl, 'core-calls')).readAsStringSync().trim().split('\n');
    expect(calls.last, startsWith('self-update-done $id --failed'));
    expect(calls.where((c) => c == 'self-update-bar'), hasLength(1)); // only the first install's
    finishSelfUpdate(w.paths, id, failed: 'the new Maprisma Settings wasn\'t ready within 3 s; the old build is back');
    final j = await c.call('jobs.get', {'id': id});
    expect(j['state'], 'failed');
    expect(j['result']['code'], 'self_update_failed');
    expect(receipt()['version'], '0.1.1');
    expect(Directory(p.dirname(lib())).listSync().map((e) => p.basename(e.path)), ['maprisma-settings']);
  });

  test('linking the new build fails: rolled back before the new one starts, the old bundle back', () async {
    final c = core();
    expect((await run(c, 'install'))['state'], 'succeeded');
    File(p.join(ctl, 'build')).writeAsStringSync('4');
    File(p.join(ctl, 'bad-integrate')).writeAsStringSync('');
    final job = await run(c, 'reinstall');
    expect(job['state'], 'failed');
    expect(job['result']['code'], 'self_update_failed');
    expect(job['result']['message'], contains('linking the new build failed'));
    expect(File(p.join(lib(), 'lib/libapp.so')).readAsStringSync(), 'lib 1\n');
    expect(Directory(p.dirname(lib())).listSync().map((e) => p.basename(e.path)), ['maprisma-settings']);
  });

  test('another install holds the lock: the helper changes nothing', () async {
    final c = core();
    expect((await run(c, 'install'))['state'], 'succeeded');
    Directory(selfDir()).createSync(recursive: true);
    final holder = await Process.start('/usr/bin/flock', [p.join(selfDir(), 'lock'), '/usr/bin/sleep', '20']);
    addTearDown(holder.kill);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    File(p.join(ctl, 'build')).writeAsStringSync('5');
    final job = await run(c, 'reinstall');
    expect(job['state'], 'failed');
    expect(job['result']['message'], contains('aborted'));
    expect(File(p.join(lib(), 'lib/libapp.so')).readAsStringSync(), 'lib 1\n');
  });

  test('self-update-done also finishes a job whose window closed before it wrote its result (a job of the old id)', () async {
    final c = core();
    expect((await run(c, 'install'))['state'], 'succeeded');
    final id = '20261109T120000Z-manager-update';
    w.writeFile(p.join(w.paths.managerState, 'jobs', '$id.json'), jsonEncode({
      'id': id, 'app': 'manager', 'kind': 'update', 'state': 'running', 'phase': 'commit', 'committed': true,
      'owner': {'pid': 999999, 'start': 1}, 'log': p.join(w.paths.managerState, 'logs', '$id.log'),
      'selfUpdate': {'state': 'waiting', 'inputs': receipt()['inputs']},
    }));
    final r = finishSelfUpdate(w.paths, id);
    expect(r['state'], 'succeeded');
    expect(r['selfUpdate'], 'done');
    expect(receipt()['job'], id);
  });

  test('across the rename: a Manager from before it updates into this build; the old folders become links', () async {
    // an install of before the rename, by hand: bundle, links, settings, state, entries
    final oldLib = p.join(w.home, '.local/lib/maprisma-manager');
    w.writeFile(p.join(oldLib, 'maprisma-manager'), '#!/bin/sh\nexit 0\n', mode: '755');
    w.writeFile(p.join(oldLib, 'lib/libapp.so'), 'lib old\n');
    w.writeFile(p.join(oldLib, 'bin/maprisma-manager-core'), '#!/bin/sh\necho "maprisma-manager-core 0.3.1"\n', mode: '755');
    Directory(p.join(w.home, '.local/bin')).createSync(recursive: true);
    Link(p.join(w.home, '.local/bin/maprisma-manager')).createSync(p.join(oldLib, 'maprisma-manager'));
    final oldConfig = p.join(w.home, '.config/maprisma-manager');
    w.writeFile(p.join(oldConfig, 'settings.json'), '{"language":"de","window_size":[900,700]}');
    final oldState = p.join(w.home, '.local/state/maprisma-manager');
    w.writeFile(p.join(oldState, 'installed/manager.json'), jsonEncode({'schema': 1, 'id': 'manager', 'at': '2026-11-13T00:00:00Z', 'inputs': []}));
    w.writeFile(p.join(oldState, 'bar.json'), jsonEncode({'hyprland': {'manager': {'placed': true, 'area': 'right'}, 'wlan': {'placed': false}}}));
    w.writeFile(p.join(w.paths.apps, 'com.maprisma.Manager.desktop'), '[Desktop Entry]\nName=Maprisma Manager\nExec=maprisma-manager\n');
    w.writeFile(p.join(w.home, '.config/autostart/com.maprisma.Manager.Tray.desktop'), '[Desktop Entry]\nExec=maprisma-manager-tray\nHidden=true\n');

    // the new build, staged as the old Manager stages it (the repo's install-local --stage)
    File(p.join(ctl, 'build')).writeAsStringSync('7');
    final env = {'HOME': w.home, 'PATH': sysbin, 'XDG_CURRENT_DESKTOP': 'COSMIC'};
    final stage = p.join(oldState, 'self-update', 'stage-7');
    final staged = await Process.run('bash', [p.join(repo, 'tools/install-local'), '--stage', stage], environment: env, includeParentEnvironment: false);
    expect(staged.exitCode, 0, reason: '${staged.stdout}${staged.stderr}');
    // what the old Manager's checks look for (its _stageFiles and `version` answer)
    for (final f in ['bundle/maprisma-manager', 'bundle/bin/maprisma-manager-core', 'packaging/com.maprisma.Manager.desktop', 'packaging/com.maprisma.Manager.svg']) {
      expect(FileSystemEntity.typeSync(p.join(stage, f)), FileSystemEntityType.file, reason: f);
    }
    final v = await Process.run(p.join(stage, 'bundle/bin/maprisma-manager-core'), ['version'], environment: env, includeParentEnvironment: false);
    expect('${v.stdout}', startsWith('maprisma-manager-core '));

    // the old Manager starts the stage's helper with the folders of the old name
    final helper = p.join(oldState, 'self-update', 'helper');
    File(p.join(repo, 'tools/self-update')).copySync(helper);
    const id = '20261113T120000Z-manager-update';
    final run = await Process.run('bash', [
      helper, '--job', id, '--stage', stage, '--lib', oldLib, '--state', p.join(oldState, 'self-update'),
      '--proc', w.proc, '--restart', '0', '--ready-timeout', '3', '--wait-timeout', '5',
    ], environment: env, includeParentEnvironment: false);
    final status = File(p.join(oldState, 'self-update', '$id.status'));
    expect(status.readAsStringSync().trim(), 'done', reason: '${run.stderr}${File(p.join(oldState, 'self-update', '$id.log')).readAsStringSync()}');

    // the folders: renamed (not copied), links of the old name left
    for (final (old, renamed) in [(oldLib, lib()), (oldConfig, p.join(w.home, '.config/maprisma-settings')), (oldState, p.join(w.home, '.local/state/maprisma-settings'))]) {
      expect(FileSystemEntity.isLinkSync(old), isTrue, reason: old);
      expect(Link(old).targetSync(), p.basename(renamed));
      expect(FileSystemEntity.isDirectorySync(renamed), isTrue);
    }
    expect(File(p.join(lib(), 'lib/libapp.so')).readAsStringSync(), 'lib 7\n');
    expect(File(p.join(w.home, '.config/maprisma-settings/settings.json')).readAsStringSync(), contains('"language":"de"'));
    // the old paths still lead to the same files (older tools, the old Manager's job reading the status)
    expect(File(p.join(oldConfig, 'settings.json')).readAsStringSync(), contains('"language":"de"'));
    expect(File(p.join(w.home, '.local/bin/maprisma-manager')).resolveSymbolicLinksSync(), p.join(lib(), 'maprisma-settings'));
    expect(File(p.join(w.home, '.local/bin/maprisma-settings')).resolveSymbolicLinksSync(), p.join(lib(), 'maprisma-settings'));
    // the entries: the new one, the old id hidden; the tray's Hidden=true carried over
    expect(File(p.join(w.paths.apps, 'com.maprisma.Settings.desktop')).readAsStringSync(), contains('Name=Maprisma Settings'));
    expect(File(p.join(w.paths.apps, 'com.maprisma.Manager.desktop')).readAsStringSync(), contains('NoDisplay=true'));
    final autostart = p.join(w.home, '.config/autostart');
    expect(File(p.join(autostart, 'com.maprisma.Manager.Tray.desktop')).existsSync(), isFalse);
    expect(File(p.join(autostart, 'com.maprisma.Settings.Tray.desktop')).readAsLinesSync(), contains('Hidden=true'));

    // the first start of the new core: the state of the old id gets the new one
    final c = core();
    final hello = await c.call('core.hello');
    expect(hello['migrated'], containsAll(['receipt manager -> settings', 'bar.json manager -> settings']));
    expect(File(p.join(w.paths.receipts, 'manager.json')).existsSync(), isFalse);
    expect(jsonDecode(File(p.join(w.paths.receipts, 'settings.json')).readAsStringSync())['id'], 'settings');
    expect((jsonDecode(File(p.join(w.paths.managerState, 'bar.json')).readAsStringSync()) as Map)['hyprland'].keys, ['wlan', 'settings']);
    // the old id still names the app
    expect((await c.call('apps.get', {'id': 'manager'}))['app']['id'], 'settings');
    // a second start has nothing to do
    expect((await core().call('core.hello'))['migrated'], isNull);
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
    await expectLater(c.call('jobs.start', {'app': 'settings', 'kind': 'remove'}),
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
    expect(look['fonts'], isEmpty); // no CosmicTk fonts in this world
    final tk = p.join(w.paths.config, 'cosmic/com.system76.CosmicTk/v1');
    w.writeFile(p.join(tk, 'interface_font'), '(\n    family: "Open Sans",\n    weight: Normal,\n)');
    w.writeFile(p.join(tk, 'monospace_font'), '(\n    family: "Hack",\n    weight: Normal,\n)');
    expect((await core().call('desktop.look'))['fonts'], {'ui': 'Open Sans', 'mono': 'Hack'});
    w.writeFile(p.join(w.paths.config, 'kdeglobals'), '[General]\nfixed=Hack,10,-1,5,400,0,0,0,0,0\nfont=Noto Sans,10,-1,5,400,0,0,0,0,0\n');
    final kde = await w.core(desktop: 'KDE').call('desktop.look');
    expect(kde['colors']['accent'], '#3daee9');
    expect(kde['fonts'], {'ui': 'Noto Sans', 'mono': 'Hack'});
    expect((await w.core(desktop: 'X').call('desktop.look'))['colors'], isEmpty);
  });

  test('desktop.look on COSMIC 1.x: the theme in v2 (v1 empty), the user\'s before the system\'s', () async {
    final cosmic = p.join(w.paths.config, 'cosmic');
    Directory(p.join(cosmic, 'com.system76.CosmicTheme.Dark/v1')).createSync(recursive: true); // empty, as COSMIC 1.0 leaves it
    w.writeFile(p.join(cosmic, 'com.system76.CosmicTheme.Mode/v1/is_dark'), 'true');
    final v2 = p.join(cosmic, 'com.system76.CosmicTheme.Dark/v2');
    w.writeFile(p.join(v2, 'accent'), '(\n    base: "#FF0000FF",\n    on: "#000000FF",\n)'); // v2: hex strings
    w.writeFile(p.join(v2, 'corner_radii'), '(\n    radius_s: (4.0, 4.0, 4.0, 4.0),\n)');
    // the system's defaults (both versions) only where the user has nothing
    final system = p.join(w.root, 'usr/share/cosmic/com.system76.CosmicTheme.Dark');
    w.writeFile(p.join(system, 'v1/accent'), '(\n    base: (red: 0.0, green: 1.0, blue: 0.0, alpha: 1.0),\n)');
    w.writeFile(p.join(system, 'v2/background'), '(\n    base: "#333333FF",\n    component: (\n        base: "#2D3649FF",\n        on: "#000000FF",\n    ),\n    on: "#FFFFFFFF",\n)');
    final look = await core().call('desktop.look');
    expect(look['colors']['accent'], '#ff0000');
    expect(look['colors']['background'], '#333333');
    expect(look['colors']['foreground'], '#ffffff', reason: 'the top level on, not the component\'s');
    expect(look['rounding'], 4);
  });

  test('desktop.look on Hyprland follows Caelestia\'s scheme, else no colours', () async {
    expect((await w.core(desktop: 'Hyprland').call('desktop.look'))['colors'], isEmpty);
    w.writeFile(p.join(w.paths.home, '.local/state/maprisma-shell/scheme.json'),
        '{"colours": {"primary": "89B4FA", "surface": "1e1e2e", "onSurface": "cdd6f4", "green": "bad"}}');
    final look = await w.core(desktop: 'Hyprland').call('desktop.look');
    expect(look['desktop'], 'hyprland');
    expect(look['colors'], {'accent': '#89b4fa', 'background': '#1e1e2e', 'foreground': '#cdd6f4'});
    expect(look['is_dark'], isTrue);
    expect((await w.core(desktop: 'X').call('desktop.look'))['colors'], isEmpty);
  });

  test('desktop.look on Hyprland takes the windows\' rounding from hyprctl, asked at most every 30 s', () async {
    // No hyprctl in the fake PATH: the rounding is unknown (the window falls back to 12).
    expect((await w.core(desktop: 'Hyprland').call('desktop.look'))['rounding'], isNull);
    final calls = p.join(w.dir, 'hyprctl-calls');
    w.fake('hyprctl', 'echo "\$@" >> $calls\n/usr/bin/cat ${p.join(w.dir, 'rounding.json')}');
    w.writeFile(p.join(w.dir, 'rounding.json'), '{"option": "decoration:rounding", "int": 15, "set": true }');
    var now = DateTime(2026, 11, 12, 10);
    final c = w.core(desktop: 'Hyprland', clock: () => now);
    expect((await c.call('desktop.look'))['rounding'], 15);
    expect(File(calls).readAsStringSync().trim(), '-j getoption decoration:rounding');
    // Within 30 s the answer is reused; after it Hyprland is asked again.
    w.writeFile(p.join(w.dir, 'rounding.json'), '{"option": "decoration:rounding", "int": 0, "set": true }');
    now = now.add(const Duration(seconds: 10));
    expect((await c.call('desktop.look'))['rounding'], 15);
    now = now.add(const Duration(seconds: 31));
    expect((await c.call('desktop.look'))['rounding'], 0);
    expect(File(calls).readAsLinesSync(), hasLength(2));
    // Out of range is clamped; no number or a failing hyprctl give null.
    w.writeFile(p.join(w.dir, 'rounding.json'), '{"int": 200}');
    expect((await w.core(desktop: 'Hyprland').call('desktop.look'))['rounding'], 64);
    w.writeFile(p.join(w.dir, 'rounding.json'), '{"str": "x"}');
    expect((await w.core(desktop: 'Hyprland').call('desktop.look'))['rounding'], isNull);
    w.writeFile(p.join(w.dir, 'rounding.json'), 'not json');
    expect((await w.core(desktop: 'Hyprland').call('desktop.look'))['rounding'], isNull);
    w.fake('hyprctl', 'exit 1');
    expect((await w.core(desktop: 'Hyprland').call('desktop.look'))['rounding'], isNull);
  });
}
