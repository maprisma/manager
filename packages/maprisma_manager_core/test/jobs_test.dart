// The job engine against a fake app: a fake repo whose install.sh writes into the temp HOME, a
// real long-running process of the app to stop (its exe is under the temp HOME), a fake
// systemctl in PATH. The real /proc is read (only processes under the temp HOME match), the
// COSMIC panel files are temp ones and the panel follow-up is replaced. No network.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:maprisma_manager_core/maprisma_manager_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

const _applet = 'io.test.FakeApplet';

const fakeApp = AppEntry(
  id: 'fake',
  name: 'Fake App',
  kind: 'test',
  inputs: [Input('fake-app')],
  components: [
    Component(
      id: 'main',
      name: 'Fake App',
      repo: 'fake-app',
      install: ['./install.sh'],
      flutter: FlutterEnv.executable,
      env: {'MM_FAKE': '{config}/mm-fake-env'},
      optionalParts: {'icon'},
      prerequisites: [Prerequisite('sh'), Prerequisite('cmake-not-here', part: 'icon')],
      paths: [
        InstalledPath('{bin}/mm-fake-daemon', PathKind.executable, key: true),
        InstalledPath('{data}/mm-fake/scripts/helper.sh', PathKind.executable),
        InstalledPath('{apps}/io.test.Fake.desktop', PathKind.file),
        InstalledPath('{autostart}/io.test.Fake.Tray.desktop', PathKind.file),
        InstalledPath('{icons}/io.test.Fake-symbolic.svg', PathKind.file, part: 'icon'),
      ],
    ),
  ],
  data: [DataPath('{config}/mm-fake'), DataPath('{config}/mm-fake-shared', sharedWithOmarchy: true)],
  units: [UnitRef('mm-fake.service', runtime: true)],
  processes: [
    ProcessMatch(MatchKind.exe, '{bin}/mm-fake-daemon'),
    ProcessMatch(MatchKind.script, '{data}/mm-fake/scripts/helper.sh'),
  ],
  bar: BarIcon(
    cosmicApplet: _applet,
    cosmicAppletExe: '{bin}/mm-fake-daemon',
    kdeId: 'mm-fake',
    kdeAutostart: '{autostart}/io.test.Fake.Tray.desktop',
    kdeTrayExe: '{bin}/mm-fake-daemon',
  ),
  postSteps: ['gtk-update-icon-cache'],
);

/// Writes the catalog paths (not the icon); control files in $HOME/.mm-test hold or fail it.
const installScript = r'''#!/bin/sh
set -eu
ctl="$HOME/.mm-test"
echo "building"
echo "PATH=$PATH"
echo "FLUTTER=${FLUTTER:-}"
echo "MM_FAKE=${MM_FAKE:-}"
echo "JOB=${MAPRISMA_MANAGER_JOB:-}"
if [ -e "$ctl/fail-build" ]; then echo "build failed" >&2; exit 3; fi
if [ -e "$ctl/stubborn" ]; then ( trap '' TERM; while :; do sleep 0.05; done ) & fi
if [ -e "$ctl/long-line" ]; then head -c 300000 /dev/zero | tr '\0' 'x'; echo; fi
while [ -e "$ctl/hold-build" ]; do sleep 0.05; done
bin="$HOME/.local/bin"
data="${XDG_DATA_HOME:-$HOME/.local/share}"
auto="${XDG_CONFIG_HOME:-$HOME/.config}/autostart"
mkdir -p "$bin" "$data/mm-fake/scripts" "$data/applications" "$auto"
cp /usr/bin/sleep "$bin/.mm-fake-daemon.tmp"
mv -f "$bin/.mm-fake-daemon.tmp" "$bin/mm-fake-daemon"
echo "copied the daemon"
while [ -e "$ctl/hold-commit" ]; do sleep 0.05; done
printf '#!/bin/sh\nwhile :; do sleep 1; done\n' > "$data/mm-fake/scripts/helper.sh"
chmod 755 "$data/mm-fake/scripts/helper.sh"
printf '[Desktop Entry]\nName=Fake\nExec=x\n' > "$data/applications/io.test.Fake.desktop"
if [ -e "$ctl/fail-commit" ]; then echo "copy failed" >&2; exit 4; fi
printf '[Desktop Entry]\nName=Fake tray\nExec=%s\nOnlyShowIn=KDE;\n' "$bin/mm-fake-daemon" > "$auto/io.test.Fake.Tray.desktop"
echo "installed"
''';

void main() {
  late World w;
  late String ctl;
  final started = <Process>[];

  setUp(() {
    w = World.create();
    catalogOverride = [...builtinCatalog, fakeApp];
    ctl = p.join(w.home, '.mm-test');
    Directory(ctl).createSync(recursive: true);
    w.fake('pacman', 'exit 1');
    w.fake('flutter', 'exit 0');
    // systemd: `is-active` says active while $HOME/.mm-test/unit-active exists; calls are logged.
    w.fake('systemctl', r'''echo "$*" >> "$HOME/.mm-test/systemctl.log"
case "$*" in *is-active*) [ -e "$HOME/.mm-test/unit-active" ] && exit 0; exit 3;; esac
exit 0''');
    final repo = w.repo('fake-app');
    w.writeFile(p.join(repo, 'install.sh'), installScript, mode: '755');
    w.git(repo, ['add', '.']);
    w.git(repo, ['commit', '-q', '-m', 'installer']);
    // COSMIC panel files without the fake applet; bar.json wants it in the centre.
    final panel = p.join(w.paths.config, 'cosmic/com.system76.CosmicPanel.Panel/v1');
    w.writeFile(p.join(panel, 'plugins_wings'), 'Some(([\n    "com.system76.CosmicAppletWorkspaces",\n], [\n    "com.system76.CosmicAppletPower",\n]))');
    w.writeFile(p.join(panel, 'plugins_center'), 'Some([\n    "com.system76.CosmicAppletTime",\n])');
  });

  tearDown(() async {
    for (final pr in started) {
      pr.kill(ProcessSignal.sigkill);
    }
    started.clear();
    catalogOverride = null;
    w.dispose();
  });

  Map<String, String> env() => w.env(extra: {
    'PATH': '${w.fakeBin}:/usr/bin:/bin',
    'MAPRISMA_MANAGER_PROC': '/proc',
    'MAPRISMA_FLUTTER': p.join(w.fakeBin, 'flutter'),
  });

  CoreService core() {
    final c = CoreService(environment: env(), uid: currentUid())..followPanel = (_) async => {'panel': null, 'note': 'test'};
    c.jobs
      ..pollEvery = const Duration(milliseconds: 30)
      ..stopGrace = const Duration(seconds: 2)
      ..killAfter = const Duration(seconds: 2);
    return c;
  }

  String bin(String n) => p.join(w.paths.bin, n);
  String daemon() => bin('mm-fake-daemon');
  String desktop() => p.join(w.paths.apps, 'io.test.Fake.desktop');
  String helper() => p.join(w.paths.data, 'mm-fake/scripts/helper.sh');
  String receiptFile() => p.join(w.paths.receipts, 'fake.json');

  Future<Map<String, dynamic>> run(CoreService c, String kind, [Map<String, dynamic> options = const {}]) async {
    final j = await c.call('jobs.start', {'app': 'fake', 'kind': kind, 'options': options});
    return c.jobs.done(j['id'] as String)!;
  }

  Future<void> until(bool Function() cond, {Duration timeout = const Duration(seconds: 10)}) async {
    final end = DateTime.now().add(timeout);
    while (!cond()) {
      if (DateTime.now().isAfter(end)) throw TimeoutException('condition not met');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  String log(Map<String, dynamic> job) => File(job['log'] as String).readAsStringSync();

  test('install: phases, explicit environment, processes and unit stopped, verify, receipt, bar state applied', () async {
    // The app runs already: its daemon (exe under ~/.local/bin) and its helper script.
    Directory(w.paths.bin).createSync(recursive: true);
    File('/usr/bin/sleep').copySync(daemon());
    chmod(daemon(), '755');
    w.writeFile(helper(), '#!/bin/sh\n# an older one\nwhile :; do sleep 1; done\n', mode: '755');
    final d = await Process.start(daemon(), ['1000']);
    final h = await Process.start('/bin/sh', [helper()]);
    started.addAll([d, h]);
    File(p.join(ctl, 'unit-active')).createSync();
    w.writeFile(WantedBar.file(w.paths), jsonEncode({'cosmic': {'fake': {'placed': true, 'area': 'center', 'index': 0}}}));

    final c = core();
    final lines = <String>[];
    final j = await c.call('jobs.start', {'app': 'fake', 'kind': 'install'});
    c.jobs.lines(j['id'] as String)!.listen(lines.add);
    final job = await c.jobs.done(j['id'] as String)!;

    expect(job['state'], 'succeeded', reason: log(job));
    expect(job['phase'], 'finish');
    expect(job['committed'], isTrue);
    expect((job['result'] as Map)['partial'], ['icon']);
    final text = log(job);
    for (final phase in ['prepare', 'build', 'commit', 'verify', 'finish']) {
      expect(text, contains('phase: $phase'));
    }
    // explicit environment: flutter's folder and ~/.cargo/bin first, FLUTTER the executable, catalog env
    expect(text, contains('PATH=${w.fakeBin}:${p.join(w.home, '.cargo/bin')}:'));
    expect(text, contains('FLUTTER=${p.join(w.fakeBin, 'flutter')}'));
    expect(text, contains('MM_FAKE=${p.join(w.paths.config, 'mm-fake-env')}'));
    expect(text, contains('JOB=${job['id']}'));
    expect(lines, contains('installed'));
    // the unit first, then both processes (identity checked), all gone now
    expect(File(p.join(ctl, 'systemctl.log')).readAsStringSync(), contains('--user stop mm-fake.service'));
    await d.exitCode.timeout(const Duration(seconds: 5));
    await h.exitCode.timeout(const Duration(seconds: 5));
    final stopped = (job['stopped'] as List).map((s) => s['pid']).toSet();
    expect(stopped, containsAll([d.pid, h.pid]));
    // receipt: hashes, modes, inputs, displaced (the old files had no receipt: kept, not restored)
    final rec = jsonDecode(File(receiptFile()).readAsStringSync()) as Map<String, dynamic>;
    expect(readReceipt(w.paths, 'fake').receipt, isNotNull);
    final paths = {for (final e in rec['paths'] as List) e['path']: e};
    expect(paths[daemon()]['sha256'], sha256File(daemon()));
    expect(paths[daemon()]['mode'], '755');
    expect(paths[p.join(w.paths.autostart, 'io.test.Fake.Tray.desktop')]['normalized'], 'hidden');
    expect(paths.containsKey(p.join(w.paths.icons, 'io.test.Fake-symbolic.svg')), isFalse);
    expect(rec['inputs'][0]['commit'], w.head('fake-app'));
    expect(rec['inputs'][0]['dirty'], isFalse);
    expect(rec['inputs'][0]['fingerprint'], startsWith('tree:'));
    expect(rec['manager'], coreVersion);
    // the old helper differed (kept, not restored: no receipt then); the daemon was the same file
    expect([for (final e in rec['displaced'] as List) e['path']], [helper()]);
    expect((rec['displaced'] as List).every((e) => e['restore'] == false), isTrue);
    // bar.json re-applied: the applet is in the centre again
    final center = File(p.join(w.paths.config, 'cosmic/com.system76.CosmicPanel.Panel/v1/plugins_center')).readAsStringSync();
    expect(center, contains(_applet));
    // status shows the receipt and the job
    final st = appOf(await c.call('apps.list'), 'fake');
    expect(st['build']['known'], isTrue);
    expect(st['job']['state'], 'succeeded');
    expect(st['repair'], isFalse);
    // the log route, in pieces
    final first = await c.call('jobs.log', {'id': job['id'], 'from': 0});
    expect(first['finished'], isTrue);
    expect(first['text'], text);
    final rest = await c.call('jobs.log', {'id': job['id'], 'from': 10});
    expect(rest['text'], utf8.decode(utf8.encode(text).sublist(10)));
  });

  test('a failing script: state failed, no receipt, nothing deleted; repair only once it had written', () async {
    final c = core();
    File(p.join(ctl, 'fail-build')).createSync();
    var job = await run(c, 'install');
    expect(job['state'], 'failed');
    expect(job['result']['code'], 'script_failed');
    expect(job['result']['repair'], isFalse);
    expect(job['committed'], isFalse);
    expect(File(receiptFile()).existsSync(), isFalse);

    File(p.join(ctl, 'fail-build')).deleteSync();
    File(p.join(ctl, 'fail-commit')).createSync();
    job = await run(c, 'install');
    expect(job['state'], 'failed', reason: log(job));
    expect(job['result']['repair'], isTrue);
    expect(job['committed'], isTrue);
    expect(File(receiptFile()).existsSync(), isFalse);
    expect(File(daemon()).existsSync(), isTrue); // what it wrote stays
    expect(File(desktop()).existsSync(), isTrue);
    final st = appOf(await c.call('apps.list'), 'fake');
    expect(st['repair'], isTrue);
    expect(statusTable(await c.call('apps.list')), contains('repair (reinstall)'));
  });

  test('cancel during the build ends the process group; nothing changed, no receipt', () async {
    final c = core();
    File(p.join(ctl, 'hold-build')).createSync();
    final j = await c.call('jobs.start', {'app': 'fake', 'kind': 'install'});
    final id = j['id'] as String;
    await until(() => File(p.join(w.paths.managerState, 'logs/$id.log')).readAsStringSync().contains('building'));
    expect((await c.call('jobs.get', {'id': id}))['cancellable'], isTrue);
    final r = await c.call('jobs.cancel', {'id': id});
    expect(r['cancelling'], isTrue);
    final job = await c.jobs.done(id)!;
    expect(job['state'], 'cancelled');
    expect(job['committed'], isFalse);
    expect(File(daemon()).existsSync(), isFalse);
    expect(File(receiptFile()).existsSync(), isFalse);
    // the script's group (its sleep too) is gone
    final pg = (job['script'] as Map)['pgid'] as int;
    expect(sameProcess(pg, null), isFalse);
  });

  test('cancel: a child that ignores TERM is killed; the job ends only when the group is gone', () async {
    final c = core();
    File(p.join(ctl, 'hold-build')).createSync();
    File(p.join(ctl, 'stubborn')).createSync();
    final j = await c.call('jobs.start', {'app': 'fake', 'kind': 'install'});
    final id = j['id'] as String;
    await until(() => File(p.join(w.paths.managerState, 'logs/$id.log')).readAsStringSync().contains('building'));
    await c.call('jobs.cancel', {'id': id});
    final job = await c.jobs.done(id)!;
    expect(job['state'], 'cancelled', reason: log(job));
    expect(log(job), contains('KILL'));
    expect(groupMembers((job['script'] as Map)['pgid'] as int), isEmpty);
  });

  test('an orphaned script of an interrupted job keeps every other job out', () async {
    final orphan = await Process.start('setsid', ['sleep', '30']);
    started.add(orphan);
    await until(() => procStat(orphan.pid)?.session == orphan.pid);
    const id = '20261109T100000Z-fake-install';
    w.writeFile(p.join(w.paths.managerState, 'jobs/$id.json'), jsonEncode({
      'id': id, 'app': 'fake', 'kind': 'install', 'state': 'running', 'phase': 'commit', 'committed': true,
      'created': '2026-11-09T10:00:00Z', 'owner': {'pid': 999999999, 'start': 1}, 'log': p.join(w.paths.managerState, 'logs/$id.log'),
      'script': {'pid': orphan.pid, 'pgid': orphan.pid, 'start': procStat(orphan.pid)!.start},
    }));
    final c = core();
    expect((await c.call('jobs.get', {'id': id}))['result']['orphan'], isTrue);
    await expectLater(c.call('jobs.start', {'app': 'fake', 'kind': 'reinstall'}), throwsA(isA<RouteError>().having((e) => e.code, 'code', 'busy')));
    orphan.kill(ProcessSignal.sigkill);
    await orphan.exitCode;
    expect((await run(c, 'reinstall'))['state'], 'succeeded');
  });

  test('jobs.log hands out a line longer than one read in pieces', () async {
    File(p.join(ctl, 'long-line')).createSync();
    final c = core();
    final job = await run(c, 'install');
    var from = 0, rounds = 0, text = StringBuffer();
    while (true) {
      final r = await c.call('jobs.log', {'id': job['id'], 'from': from});
      text.write(r['text']);
      if (r['finished'] == true) break;
      expect(r['next'], greaterThan(from));
      from = r['next'] as int;
      expect(++rounds, lessThan(10));
    }
    expect(text.toString(), File(job['log'] as String).readAsStringSync());
  });

  test('cancel once the script has written: refused (not_cancellable), even before the poll saw it', () async {
    final c = core();
    c.jobs.pollEvery = const Duration(hours: 1); // only the cancel's own check can see the change
    File(p.join(ctl, 'hold-commit')).createSync();
    final j = await c.call('jobs.start', {'app': 'fake', 'kind': 'install'});
    final id = j['id'] as String;
    await until(() => File(p.join(w.paths.managerState, 'logs/$id.log')).readAsStringSync().contains('copied the daemon'));
    expect((await c.call('jobs.get', {'id': id}))['phase'], 'build');
    await expectLater(c.call('jobs.cancel', {'id': id}), throwsA(isA<RouteError>().having((e) => e.code, 'code', 'not_cancellable')));
    expect((await c.call('jobs.get', {'id': id}))['phase'], 'commit');
    await expectLater(c.call('jobs.cancel', {'id': id}), throwsA(isA<RouteError>().having((e) => e.code, 'code', 'not_cancellable')));
    File(p.join(ctl, 'hold-commit')).deleteSync();
    final job = await c.jobs.done(id)!;
    expect(job['state'], 'succeeded', reason: log(job));
    expect(File(receiptFile()).existsSync(), isTrue);
  });

  test('an interrupted job (its Manager gone) is reported with repair', () async {
    final dead = await Process.start('/bin/true', []);
    await dead.exitCode;
    const id = '20261109T100000Z-fake-install';
    w.writeFile(p.join(w.paths.managerState, 'jobs/$id.json'), jsonEncode({
      'id': id, 'app': 'fake', 'kind': 'install', 'state': 'running', 'phase': 'commit', 'committed': true,
      'created': '2026-11-09T10:00:00Z', 'owner': {'pid': dead.pid, 'start': 1}, 'log': p.join(w.paths.managerState, 'logs/$id.log'),
    }));
    final c = core();
    final st = appOf(await c.call('apps.list'), 'fake');
    expect(st['job']['state'], 'interrupted');
    expect(st['repair'], isTrue);
    final job = await c.call('jobs.get', {'id': id});
    expect(job['result']['code'], 'interrupted');
    expect(jsonDecode(File(p.join(w.paths.managerState, 'jobs/$id.json')).readAsStringSync())['state'], 'interrupted');
    expect((await c.call('jobs.list'))['jobs'], hasLength(1));
  });

  test('one job at a time: a second Manager (another process, or another core here) is refused', () async {
    final lock = p.join(w.paths.managerState, 'jobs/lock');
    Directory(p.dirname(lock)).createSync(recursive: true);
    final holder = await Process.start('python3', ['-c', 'import fcntl,sys,time\nf=open(sys.argv[1],"a")\nfcntl.lockf(f, fcntl.LOCK_EX)\nprint("locked", flush=True)\ntime.sleep(30)', lock]);
    started.add(holder);
    await holder.stdout.transform(utf8.decoder).firstWhere((l) => l.contains('locked'));
    final c = core();
    await expectLater(c.call('jobs.start', {'app': 'fake', 'kind': 'install'}), throwsA(isA<RouteError>().having((e) => e.code, 'code', 'busy')));
    holder.kill(ProcessSignal.sigkill);
    await holder.exitCode;

    File(p.join(ctl, 'hold-build')).createSync();
    final j = await c.call('jobs.start', {'app': 'fake', 'kind': 'install'});
    await expectLater(core().call('jobs.start', {'app': 'fake', 'kind': 'install'}), throwsA(isA<RouteError>().having((e) => e.code, 'code', 'busy')));
    await expectLater(c.call('jobs.start', {'app': 'fake', 'kind': 'reinstall'}), throwsA(isA<RouteError>().having((e) => e.code, 'code', 'busy')));
    File(p.join(ctl, 'hold-build')).deleteSync();
    expect((await c.jobs.done(j['id'] as String)!)['state'], 'succeeded');
    // the lock is free again
    expect((await run(core(), 'reinstall'))['state'], 'succeeded');
  });

  test('update pulls (fast-forward) when clean and behind; the receipt has the new commit', () async {
    final c = core();
    expect((await run(c, 'install'))['state'], 'succeeded');
    final repo = p.join(w.projects, 'fake-app');
    final bare = p.join(w.dir, 'remotes', 'fake-app.git');
    Directory(p.dirname(bare)).createSync(recursive: true);
    w.git(w.dir, ['init', '-q', '--bare', bare]);
    w.git(repo, ['remote', 'add', 'origin', bare]);
    w.git(repo, ['push', '-q', '-u', 'origin', 'main']);
    w.pushUpstreamCommit('fake-app');
    await c.call('git.fetch', {'id': 'fake', 'force': true});
    final job = await run(c, 'update');
    expect(job['state'], 'succeeded', reason: log(job));
    expect(log(job), contains('git pull --ff-only'));
    final rec = jsonDecode(File(receiptFile()).readAsStringSync());
    expect(rec['inputs'][0]['commit'], w.head('fake-app'));
    expect(File(p.join(repo, 'NEW')).existsSync(), isTrue);
  });

  test('remove: plan first; a changed and a foreign file stay, settings only when asked, shared never', () async {
    final c = core();
    expect((await run(c, 'install'))['state'], 'succeeded');
    final icon = p.join(w.paths.icons, 'io.test.Fake-symbolic.svg');
    w.writeFile(desktop(), '[Desktop Entry]\nName=Edited by the user\n'); // changed
    w.writeFile(icon, '<svg/>'); // foreign: the installer never wrote it
    w.writeFile(p.join(w.paths.config, 'mm-fake/settings.json'), '{}');
    w.writeFile(p.join(w.paths.config, 'mm-fake-shared/x.json'), '{}');
    // hiding the tray doesn't make its autostart file "changed"
    setDesktopHidden(w.paths, p.join(w.paths.autostart, 'io.test.Fake.Tray.desktop'), true);

    final plan = await c.call('apps.remove_plan', {'id': 'fake', 'delete_settings': true});
    expect(plan['verified'], isTrue);
    final goes = [for (final g in plan['goes'] as List) g['path']];
    expect(goes, containsAll([daemon(), helper(), p.join(w.paths.autostart, 'io.test.Fake.Tray.desktop')]));
    final stays = {for (final s in plan['stays'] as List) s['path']: s['why']};
    expect(stays[desktop()], whyChanged);
    expect(stays[icon], whyNotInReceipt);
    final data = {for (final d in plan['data'] as List) d['path']: d['goes']};
    expect(data[p.join(w.paths.config, 'mm-fake')], isTrue);
    expect(data[p.join(w.paths.config, 'mm-fake-shared')], isFalse);
    expect(planText(plan), contains('Stays:'));

    final j = await c.call('jobs.start', {'app': 'fake', 'kind': 'remove', 'options': {'delete_settings': true, 'revision': plan['revision']}});
    final job = await c.jobs.done(j['id'] as String)!;
    expect(job['state'], 'succeeded', reason: log(job));
    expect(File(daemon()).existsSync(), isFalse);
    expect(File(helper()).existsSync(), isFalse);
    expect(Directory(p.join(w.paths.data, 'mm-fake')).existsSync(), isFalse); // emptied folders pruned
    expect(Directory(w.paths.bin).existsSync(), isTrue); // shared roots stay
    expect(File(desktop()).readAsStringSync(), contains('Edited by the user'));
    expect(File(icon).existsSync(), isTrue);
    expect(Directory(p.join(w.paths.config, 'mm-fake')).existsSync(), isFalse);
    expect(File(p.join(w.paths.config, 'mm-fake-shared/x.json')).existsSync(), isTrue);
    expect(File(receiptFile()).existsSync(), isFalse);
    // the bar icon was taken out; bar.json keeps the user's choice for a reinstall
    final center = File(p.join(w.paths.config, 'cosmic/com.system76.CosmicPanel.Panel/v1/plugins_center')).readAsStringSync();
    expect(center, isNot(contains(_applet)));
  });

  test('a stale plan is refused; unsupported removes are refused with their own code', () async {
    final c = core();
    expect((await run(c, 'install'))['state'], 'succeeded');
    final job = await run(c, 'remove', {'revision': 'not-the-plan'});
    expect(job['state'], 'failed');
    expect(job['result']['code'], 'changed');
    expect(File(daemon()).existsSync(), isTrue);
    await expectLater(c.call('apps.remove_plan', {'id': 'narrator'}), throwsA(isA<RouteError>().having((e) => e.code, 'code', 'unsupported_yet')));
    await expectLater(c.call('jobs.start', {'app': 'tiling', 'kind': 'remove'}), throwsA(isA<RouteError>().having((e) => e.code, 'code', 'unsupported_yet')));
    await expectLater(c.call('jobs.start', {'app': 'maprisma', 'kind': 'install'}), throwsA(isA<RouteError>().having((e) => e.code, 'code', 'unsupported_yet')));
  });

  test('a second remove never takes what the first one kept; nothing through a linked folder', () async {
    final c = core();
    expect((await run(c, 'install'))['state'], 'succeeded');
    w.writeFile(desktop(), '[Desktop Entry]\nName=Edited\n');
    expect((await run(c, 'remove'))['state'], 'succeeded');
    expect(File(desktop()).existsSync(), isTrue);
    expect(File(keptFile(w.paths, 'fake')).existsSync(), isTrue);
    final plan = await c.call('apps.remove_plan', {'id': 'fake'});
    expect(plan['verified'], isFalse);
    expect([for (final g in plan['goes'] as List) g['path']], isNot(contains(desktop())));
    expect({for (final s in plan['stays'] as List) s['path']: s['why']}[desktop()], contains('kept by an earlier remove'));

    // the app's scripts folder is a link to somewhere else: the file there is not touched
    final elsewhere = p.join(w.dir, 'elsewhere');
    w.writeFile(p.join(elsewhere, 'helper.sh'), 'mine', mode: '755');
    Directory(p.join(w.paths.data, 'mm-fake')).createSync(recursive: true);
    Link(p.join(w.paths.data, 'mm-fake/scripts')).createSync(elsewhere);
    final plan2 = await c.call('apps.remove_plan', {'id': 'fake'});
    expect([for (final g in plan2['goes'] as List) g['path']], isNot(contains(helper())));
    expect({for (final s in plan2['stays'] as List) s['path']: s['why']}[helper()], contains('linked folder'));
  });

  test('install records the bar state of an app never placed through the Manager', () async {
    final c = core();
    expect((await run(c, 'install'))['state'], 'succeeded');
    expect(File(WantedBar.file(w.paths)).existsSync(), isFalse); // not installed before: nothing to record
    final center = p.join(w.paths.config, 'cosmic/com.system76.CosmicPanel.Panel/v1/plugins_center');
    w.writeFile(center, 'Some([\n    "com.system76.CosmicAppletTime",\n    "$_applet",\n])');
    final job = await run(c, 'reinstall');
    expect(job['state'], 'succeeded', reason: log(job));
    expect(WantedBar.load(w.paths).of(DesktopId.cosmic, 'fake'), {'placed': true, 'area': 'center'});
  });

  test('without a receipt, remove takes the catalog paths, marked unverified', () async {
    w.writeFile(daemon(), 'x', mode: '755');
    w.writeFile(desktop(), 'x');
    final plan = await core().call('apps.remove_plan', {'id': 'fake'});
    expect(plan['verified'], isFalse);
    expect([for (final g in plan['goes'] as List) if (g['unverified'] == true) g['path']], unorderedEquals([daemon(), desktop()]));
  });

  test('a displaced file is backed up before the run and restored by remove', () async {
    final c = core();
    expect((await run(c, 'install'))['state'], 'succeeded');
    // something else writes the desktop file; a reinstall displaces it
    w.writeFile(desktop(), '[Desktop Entry]\nName=Someone else\n');
    final re = await run(c, 'reinstall');
    expect(re['state'], 'succeeded', reason: log(re));
    expect(File(desktop()).readAsStringSync(), contains('Name=Fake'));
    final d = Displaced.load(w.paths, 'fake');
    final e = d.of(desktop())!;
    expect(e['restore'], isTrue);
    expect(File(e['backup'] as String).readAsStringSync(), contains('Someone else'));
    final rec = jsonDecode(File(receiptFile()).readAsStringSync());
    expect([for (final x in rec['displaced'] as List) x['path']], contains(desktop()));

    final plan = await c.call('apps.remove_plan', {'id': 'fake'});
    expect([for (final r in plan['restores'] as List) r['path']], [desktop()]);
    final rm = await run(c, 'remove');
    expect(rm['state'], 'succeeded', reason: log(rm));
    expect(File(desktop()).readAsStringSync(), contains('Someone else'));
    expect(Displaced.load(w.paths, 'fake').of(desktop()), isNull);
  });

  test('the log is bounded: its end is kept', () {
    final dir = Directory.systemTemp.createTempSync('mm-log-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final l = JobLog(p.join(dir.path, 'x.log'), max: 1000, tailMax: 100);
    for (var i = 0; i < 200; i++) {
      l.add(utf8.encode('line $i\n'));
    }
    l.close();
    final text = File(p.join(dir.path, 'x.log')).readAsStringSync();
    expect(text, startsWith('line 0\n'));
    expect(text, contains('bytes of output left out'));
    expect(text.trimRight(), endsWith('line 199'));
    expect(text.length, lessThan(1300));
  });

  test('CLI: jobs and log', () async {
    final c = core();
    final job = await run(c, 'install');
    final out = _Capture();
    expect(await runCli(['jobs'], service: c, out: out), 0);
    expect(out.text, contains(job['id']));
    final out2 = _Capture();
    expect(await runCli(['log', job['id'] as String], service: c, out: out2), 0);
    expect(out2.text, contains('installed'));
  });
}

final class _Capture implements IOSink {
  final _b = StringBuffer();
  String get text => _b.toString();
  @override
  void writeln([Object? object = '']) => _b.writeln(object);
  @override
  void write(Object? object) => _b.write(object);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
