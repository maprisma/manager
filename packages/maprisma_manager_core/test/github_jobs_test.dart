// Jobs with GitHub sources against local stand-ins: a bare repo is "GitHub" (the URL mapping
// injected), release assets are files copied by an injected download, the REST API is a fixture.
// No network, no real panel (followPanel replaced; the fake app has no bar icon).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:maprisma_manager_core/maprisma_manager_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

const _slug = 'test/mm-gh';

const ghApp = AppEntry(
  id: 'ghfake',
  name: 'GitHub Fake',
  kind: 'test',
  inputs: [Input('mm-gh', github: _slug)],
  components: [
    Component(
      id: 'main',
      name: 'GitHub Fake',
      repo: 'mm-gh',
      install: ['./install.sh'],
      stopsOwnProcesses: true,
      paths: [
        InstalledPath('{bin}/mm-gh-daemon', PathKind.executable, key: true),
        InstalledPath('{data}/mm-gh/version.json', PathKind.file),
      ],
    ),
  ],
  version: VersionSource(installedJson: '{data}/mm-gh/version.json'),
  release: ReleaseSpec(
    tarball: 'mm-gh-{version}-x86_64.tar.gz',
    component: 'main',
    install: ['tools/install-local', '--no-build'],
    prerequisites: [Prerequisite('tar')],
  ),
);

/// Builds from the folder: the daemon and a version.json saying "folder".
const installSh = r'''#!/bin/sh
set -eu
mkdir -p "$HOME/.local/bin" "$HOME/.local/share/mm-gh"
printf '#!/bin/sh\necho folder\n' > "$HOME/.local/bin/mm-gh-daemon"
chmod 755 "$HOME/.local/bin/mm-gh-daemon"
echo '{"version":"0.0.1"}' > "$HOME/.local/share/mm-gh/version.json"
echo "built from the folder"
''';

/// Like the Launcher's: the newest dist/mm-gh-*-x86_64.tar.gz, unpacked and installed.
const installLocal = r'''#!/bin/sh
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
[ "${1:-}" = "--no-build" ] || { echo "usage" >&2; exit 2; }
tarball=$(ls -t "$root"/dist/mm-gh-*-x86_64.tar.gz 2>/dev/null | head -1 || true)
[ -n "$tarball" ] || { echo "no release in dist/" >&2; exit 1; }
echo "picked $(basename "$tarball")"
stage=$(mktemp -d)
tar -xzf "$tarball" -C "$stage"
mkdir -p "$HOME/.local/bin" "$HOME/.local/share/mm-gh"
cp "$stage/mm-gh/mm-gh-daemon" "$HOME/.local/bin/.mm-gh-daemon.new"
mv -f "$HOME/.local/bin/.mm-gh-daemon.new" "$HOME/.local/bin/mm-gh-daemon"
cp "$stage/mm-gh/version.json" "$HOME/.local/share/mm-gh/version.json"
rm -rf "$stage"
echo "installed $(basename "$tarball")"
''';

void main() {
  late World w;
  late String github; // the bare repo standing in for GitHub
  late String assets; // release assets by name
  final calls = <String>[];
  Map<String, dynamic> release = {};

  setUp(() {
    w = World.create();
    catalogOverride = [...builtinCatalog, ghApp];
    w.fake('pacman', 'exit 1');
    // "GitHub": a bare repo with install.sh and tools/install-local
    final seed = w.repo('seed-mm-gh');
    w.writeFile(p.join(seed, 'install.sh'), installSh, mode: '755');
    w.writeFile(p.join(seed, 'tools/install-local'), installLocal, mode: '755');
    w.git(seed, ['add', '.']);
    w.git(seed, ['commit', '-q', '-m', 'installers']);
    github = p.join(w.dir, 'github', 'mm-gh.git');
    Directory(p.dirname(github)).createSync(recursive: true);
    w.git(w.dir, ['clone', '-q', '--bare', seed, github]);
    Directory(seed).deleteSync(recursive: true);
    assets = p.join(w.dir, 'assets');
    Directory(assets).createSync();
    calls.clear();
    release = {};
  });

  tearDown(() {
    catalogOverride = null;
    w.dispose();
  });

  Map<String, String> env() => w.env(extra: {'PATH': '${w.fakeBin}:/usr/bin:/bin', 'MAPRISMA_MANAGER_PROC': '/proc'});

  CoreService core() {
    final c = CoreService(environment: env(), uid: currentUid())..followPanel = (_) async => {'panel': null, 'note': 'test'};
    c.ctx.cloneUrlFor = (slug) => slug == _slug ? github : '/nowhere/$slug.git';
    c.ctx.github.http = (uri) async {
      final path = uri.path.substring(1);
      calls.add(path);
      if (path == 'repos/$_slug') {
        return (status: 200, body: jsonEncode({'html_url': 'https://github.com/$_slug', 'private': false, 'default_branch': 'main'}), headers: const <String, String>{});
      }
      if (path == 'repos/$_slug/releases/latest' || path == 'repos/$_slug/releases/tags/${release['tag_name']}') {
        return (status: 200, body: jsonEncode(release), headers: const <String, String>{});
      }
      return (status: 404, body: '{}', headers: const <String, String>{});
    };
    c.ctx.github.download = (url, dest, {required cancelled}) async {
      final f = File(p.join(assets, p.basename(url.path)));
      if (!f.existsSync()) throw const HttpException('404');
      f.copySync(dest);
    };
    c.jobs
      ..pollEvery = const Duration(milliseconds: 30)
      ..stopGrace = const Duration(seconds: 2)
      ..killAfter = const Duration(seconds: 2);
    return c;
  }

  Future<Map<String, dynamic>> run(CoreService c, String kind, [Map<String, dynamic> options = const {}]) async {
    final j = await c.call('jobs.start', {'app': 'ghfake', 'kind': kind, 'options': options});
    return c.jobs.done(j['id'] as String)!;
  }

  String log(Map<String, dynamic> job) => File(job['log'] as String).readAsStringSync();
  String folder() => p.join(w.projects, 'mm-gh');
  String receiptFile() => p.join(w.paths.receipts, 'ghfake.json');

  /// A release tarball (and, unless [sum] is false, its .sha256; [wrong] makes it lie).
  String makeRelease(String version, {bool sum = true, bool wrong = false}) {
    final stage = Directory(p.join(w.dir, 'stage-$version', 'mm-gh'))..createSync(recursive: true);
    w.writeFile(p.join(stage.path, 'mm-gh-daemon'), '#!/bin/sh\necho release $version\n', mode: '755');
    w.writeFile(p.join(stage.path, 'version.json'), '{"version":"$version"}');
    final name = 'mm-gh-$version-x86_64.tar.gz';
    final r = Process.runSync('/usr/bin/tar', ['-czf', p.join(assets, name), '-C', p.dirname(stage.path), 'mm-gh']);
    if (r.exitCode != 0) throw StateError('tar: ${r.stderr}');
    final hash = sha256File(p.join(assets, name));
    if (sum) File(p.join(assets, '$name.sha256')).writeAsStringSync('${wrong ? 'b' * 64 : hash}  $name\n');
    release = {
      'tag_name': 'v$version',
      'published_at': '2026-11-06T00:00:00Z',
      'html_url': 'https://github.com/$_slug/releases/tag/v$version',
      'assets': [
        {'name': name, 'size': File(p.join(assets, name)).lengthSync(), 'browser_download_url': 'https://github.com/$_slug/releases/download/v$version/$name'},
        if (sum) {'name': '$name.sha256', 'size': 100, 'browser_download_url': 'https://github.com/$_slug/releases/download/v$version/$name.sha256'},
      ],
    };
    return hash;
  }

  test('install with the folder missing: cloned from GitHub (logged), then built; receipt says folder', () async {
    final c = core();
    final job = await run(c, 'install');
    expect(job['state'], 'succeeded', reason: log(job));
    final text = log(job);
    expect(text, contains('the folder is missing: git clone $github ${folder()}'));
    expect(text, contains('cloned into ${folder()}'));
    expect(text, contains('built from the folder'));
    expect(Directory(p.join(folder(), '.git')).existsSync(), isTrue);
    expect(Directory(w.projects).listSync().map((e) => p.basename(e.path)), isNot(contains(startsWith('.mm-gh.clone'))));
    final rec = jsonDecode(File(receiptFile()).readAsStringSync());
    expect(rec['source'], {'kind': 'folder'});
    expect((job['result'] as Map)['sources'], [{'repo': 'mm-gh', 'cloned': github}]);
    final a = appOf(await c.call('apps.list'), 'ghfake');
    expect(a['sources']['where'], 'both');
    expect(a['sources']['inputs'][0]['remote'], {'name': 'origin', 'url': github, 'isUpstream': true});

    // a new commit on GitHub (the upstream here) without a git.fetch before: update fetches itself
    final other = p.join(w.dir, 'other');
    w.git(w.dir, ['clone', '-q', github, other]);
    File(p.join(other, 'NEW')).writeAsStringSync('x');
    w.git(other, ['add', '.']);
    w.git(other, ['commit', '-q', '-m', 'on github']);
    w.git(other, ['push', '-q', 'origin', 'main']);
    final upd = await run(c, 'update');
    expect(upd['state'], 'succeeded', reason: log(upd));
    expect(log(upd), contains('git fetch origin (GitHub, $github)'));
    expect(log(upd), contains('git pull --ff-only (1 new from origin/main)'));
    expect(w.head('mm-gh'), (w.git(other, ['rev-parse', 'HEAD']).stdout as String).trim());
  });

  test('a clone that fails leaves nothing; a cancelled clone leaves nothing', () async {
    var c = core();
    c.ctx.cloneUrlFor = (slug) => p.join(w.dir, 'gone.git');
    var job = await run(c, 'install');
    expect(job['state'], 'failed');
    expect(job['result']['code'], 'clone_failed');
    expect(Directory(w.projects).listSync().where((e) => p.basename(e.path).contains('mm-gh')), isEmpty);

    // a git whose clone hangs: cancelled in prepare
    final realGit = Link(p.join(w.fakeBin, 'git')).targetSync();
    Link(p.join(w.fakeBin, 'git')).deleteSync();
    // its helper (a child that outlives a TERM to git alone) must end with it
    w.fake('git', 'for last; do :; done\nfor a; do [ "\$a" = clone ] && { mkdir -p "\$last"; sleep 30 & echo \$! > "\$HOME/.clone-child"; wait; exit 1; }; done\nexec $realGit "\$@"');
    c = core();
    final j = await c.call('jobs.start', {'app': 'ghfake', 'kind': 'install'});
    final id = j['id'] as String;
    final logFile = File(p.join(w.paths.managerState, 'logs/$id.log'));
    final end = DateTime.now().add(const Duration(seconds: 10));
    while (!logFile.readAsStringSync().contains('git clone')) {
      if (DateTime.now().isAfter(end)) fail('no clone started');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(await c.call('jobs.cancel', {'id': id}), {'id': id, 'cancelling': true});
    job = await c.jobs.done(id)!.timeout(const Duration(seconds: 10));
    expect(job['state'], 'cancelled', reason: log(job));
    expect(log(job), contains('clone cancelled'));
    expect(Directory(w.projects).listSync().where((e) => p.basename(e.path).contains('mm-gh')), isEmpty);
    final child = int.parse(File(p.join(w.home, '.clone-child')).readAsStringSync().trim());
    expect(Directory('/proc/$child').existsSync(), isFalse, reason: 'the clone\'s helper still runs');
  });

  test('update against the GitHub remote when the upstream is another one: fast-forward only when clean and behind', () async {
    final c = core();
    // the folder's upstream is a private stand-in; GitHub is the remote "public"
    w.git(w.projects, ['clone', '-q', github, 'mm-gh']);
    final private = p.join(w.dir, 'private', 'mm-gh.git');
    Directory(p.dirname(private)).createSync(recursive: true);
    w.git(w.dir, ['clone', '-q', '--bare', github, private]);
    w.git(folder(), ['remote', 'rename', 'origin', 'public']);
    w.git(folder(), ['remote', 'add', 'origin', private]);
    w.git(folder(), ['fetch', '-q', 'origin']);
    w.git(folder(), ['branch', '-q', '--set-upstream-to=origin/main']);
    expect((await run(c, 'install'))['state'], 'succeeded');

    // a new commit on GitHub only
    final other = p.join(w.dir, 'other');
    w.git(w.dir, ['clone', '-q', github, other]);
    File(p.join(other, 'NEW')).writeAsStringSync('x');
    w.git(other, ['add', '.']);
    w.git(other, ['commit', '-q', '-m', 'on github']);
    w.git(other, ['push', '-q', 'origin', 'main']);
    final ghHead = (w.git(other, ['rev-parse', 'HEAD']).stdout as String).trim();

    // status after git.fetch: the GitHub remote was fetched explicitly
    await c.call('git.fetch', {'id': 'ghfake', 'force': true});
    var a = appOf(await c.call('apps.list'), 'ghfake');
    expect(a['updates']['upstreamNew'], 0);
    expect(a['updates']['githubNew'], 1);
    expect(a['sources']['inputs'][0]['remote']['name'], 'public');
    expect(a['sources']['inputs'][0]['newSinceBuild'], 1);

    // dirty: no fast-forward, the reason told
    File(p.join(folder(), 'LOCAL')).writeAsStringSync('x');
    var job = await run(c, 'update');
    expect(job['state'], 'succeeded', reason: log(job));
    expect(log(job), contains('no fast-forward to public/main: uncommitted changes'));
    expect((job['result'] as Map)['sources'], [
      {'repo': 'mm-gh', 'remote': 'public', 'ref': 'public/main', 'fastForward': false, 'why': 'uncommitted changes'},
    ]);
    File(p.join(folder(), 'LOCAL')).deleteSync();

    // clean and behind: fetched and fast-forwarded to the exact commit (a local branch named
    // public/main, which a short ref name would resolve to, doesn't interfere), then built
    w.git(folder(), ['branch', 'public/main', 'HEAD']);
    job = await run(c, 'update');
    expect(job['state'], 'succeeded', reason: log(job));
    expect(log(job), contains('git fetch public (GitHub, $github)'));
    expect(log(job), contains('git merge --ff-only public/main (${ghHead.substring(0, 12)}, 1 new from GitHub)'));
    expect(w.head('mm-gh'), ghHead);
    expect(jsonDecode(File(receiptFile()).readAsStringSync())['inputs'][0]['commit'], ghHead);
    a = appOf(await c.call('apps.list'), 'ghfake');
    expect(a['updates']['githubNew'], 0);

    // a local commit and a new one on GitHub: diverged, no fast-forward
    File(p.join(folder(), 'MINE')).writeAsStringSync('x');
    w.git(folder(), ['add', '.']);
    w.git(folder(), ['commit', '-q', '-m', 'mine']);
    File(p.join(other, 'NEW2')).writeAsStringSync('x');
    w.git(other, ['add', '.']);
    w.git(other, ['commit', '-q', '-m', 'again']);
    w.git(other, ['push', '-q', 'origin', 'main']);
    job = await run(c, 'update');
    expect(log(job), contains('no fast-forward to public/main: diverged from public/main (1 local, 1 there)'));
  });

  test('release: downloaded, sha256 checked, placed as the newest in dist/, installed, cleaned up; receipt records it', () async {
    final c = core();
    final hash = makeRelease('0.2.0');
    w.git(w.projects, ['clone', '-q', github, 'mm-gh']);
    // an older tarball in dist/ with a newer mtime than now, which ls -t would otherwise pick
    final dist = p.join(folder(), 'dist');
    final old = File(p.join(dist, 'mm-gh-0.1.0-x86_64.tar.gz'))..createSync(recursive: true);
    old.writeAsStringSync('old');
    old.setLastModifiedSync(DateTime.now().add(const Duration(hours: 1)));

    final job = await run(c, 'release');
    expect(job['state'], 'succeeded', reason: log(job));
    final text = log(job);
    expect(text, contains('mm-gh-0.2.0-x86_64.tar.gz: sha256 $hash matches mm-gh-0.2.0-x86_64.tar.gz.sha256'));
    expect(text, contains('picked mm-gh-0.2.0-x86_64.tar.gz'));
    expect(text, contains('\$ tools/install-local --no-build'));
    expect(File(p.join(w.paths.bin, 'mm-gh-daemon')).readAsStringSync(), contains('release 0.2.0'));
    // the placed copy is gone, the old one untouched; the download stays in the cache
    expect(Directory(dist).listSync().map((e) => p.basename(e.path)).toList(), ['mm-gh-0.1.0-x86_64.tar.gz']);
    expect(File(p.join(w.paths.cache, 'maprisma-settings/downloads/test_mm-gh/v0.2.0/mm-gh-0.2.0-x86_64.tar.gz')).existsSync(), isTrue);
    final rec = jsonDecode(File(receiptFile()).readAsStringSync());
    expect(rec['source'], {
      'kind': 'release',
      'tag': 'v0.2.0',
      'asset': 'mm-gh-0.2.0-x86_64.tar.gz',
      'sha256': hash,
      'url': 'https://github.com/$_slug/releases/tag/v0.2.0',
    });
    expect(rec['version'], '0.2.0');
    expect(rec['kind'], 'release');
    expect(readReceipt(w.paths, 'ghfake').receipt!.fromRelease, isTrue);
    final a = appOf(await c.call('apps.list'), 'ghfake');
    expect(a['updates']['sourceDiffers'], isNull);
    expect(a['updates']['sourceReasons'], ['installed from release v0.2.0']);
    // a folder update after a release builds (the receipt's commit is only the installer's)
    final upd = await run(c, 'update');
    expect(upd['state'], 'succeeded', reason: log(upd));
    expect(log(upd), contains('phase: build'));
    expect(log(upd), isNot(contains('already up to date')));
    expect(File(p.join(w.paths.bin, 'mm-gh-daemon')).readAsStringSync(), contains('folder'));

    // a newer release is offered; a dist/ the script didn't have is removed again afterwards
    // a user's own, different file of the release's name in dist/: moved aside, put back afterwards
    final mine = File(p.join(dist, 'mm-gh-0.2.0-x86_64.tar.gz'))..writeAsStringSync('mine');
    final job1 = await run(c, 'release', {'tag': 'v0.2.0'});
    expect(job1['state'], 'succeeded', reason: log(job1));
    expect(log(job1), contains('was moved aside'));
    expect(mine.readAsStringSync(), 'mine');
    expect(Directory(dist).listSync().map((e) => p.basename(e.path)).toSet(), {'mm-gh-0.1.0-x86_64.tar.gz', 'mm-gh-0.2.0-x86_64.tar.gz'});
    expect(job1['dist'], isNull);

    makeRelease('0.3.0');
    Directory(dist).deleteSync(recursive: true);
    await c.call('github.refresh', {'id': 'ghfake', 'force': true});
    expect(appOf(await c.call('apps.list'), 'ghfake')['updates']['releaseNew'], containsPair('tag', 'v0.3.0'));
    final job2 = await run(c, 'release', {'tag': 'v0.3.0'});
    expect(job2['state'], 'succeeded', reason: log(job2));
    expect(Directory(dist).existsSync(), isFalse);
    expect(appOf(await c.call('apps.list'), 'ghfake')['updates']['releaseNew'], isNull);
  });

  test('release: a wrong or missing sha256 is refused before anything is installed', () async {
    final c = core();
    makeRelease('0.2.0', wrong: true);
    var job = await run(c, 'release');
    expect(job['state'], 'failed');
    expect(job['result']['code'], 'checksum_mismatch', reason: log(job));
    expect(job['committed'], isFalse);
    expect(log(job), isNot(contains('phase: build')));
    expect(File(p.join(w.paths.bin, 'mm-gh-daemon')).existsSync(), isFalse);
    expect(File(receiptFile()).existsSync(), isFalse);
    expect(File(p.join(w.paths.cache, 'maprisma-settings/downloads/test_mm-gh/v0.2.0/mm-gh-0.2.0-x86_64.tar.gz')).existsSync(), isFalse);
    // the folder was cloned first (the script is in it)
    expect(log(job), contains('git clone $github'));

    makeRelease('0.2.0', sum: false);
    File(p.join(assets, 'mm-gh-0.2.0-x86_64.tar.gz.sha256')).deleteSync();
    job = await run(c, 'release', {'tag': 'v0.2.0'}); // a tag is read from GitHub again
    expect(job['result']['code'], 'no_checksum');
    expect(File(p.join(w.paths.bin, 'mm-gh-daemon')).existsSync(), isFalse);

    job = await run(c, 'release', {'tag': 'v9.9.9'});
    expect(job['result']['code'], 'no_release');
  });

  test('release routes: an app without releases unavailable, a bad tag refused', () async {
    final c = core();
    await expectLater(c.call('jobs.start', {'app': 'maprisma', 'kind': 'release', 'options': {'tag': '-x'}}),
        throwsA(isA<RouteError>().having((e) => e.code, 'code', 'bad_params')));
    await expectLater(c.call('jobs.start', {'app': 'wlan', 'kind': 'install', 'options': {'source': 'release'}}),
        throwsA(isA<RouteError>().having((e) => e.code, 'code', 'bad_params')));
    await expectLater(c.call('jobs.start', {'app': 'wlan', 'kind': 'release'}),
        throwsA(isA<RouteError>().having((e) => e.code, 'code', 'unavailable')));
    await expectLater(c.call('jobs.start', {'app': 'ghfake', 'kind': 'release', 'options': {'tag': '../x'}}),
        throwsA(isA<RouteError>().having((e) => e.code, 'code', 'bad_params')));
    expect(calls, isEmpty);
  });
}
