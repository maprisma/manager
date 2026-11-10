// GitHub facts and sources against fixtures: the REST API through an injected GET, gh through a
// fake gh in PATH (named by MAPRISMA_MANAGER_GH), local bare repos standing in for GitHub (the
// URL mapping injected). Never the network (MAPRISMA_MANAGER_OFFLINE=1 in every test env).
import 'dart:convert';
import 'dart:io';

import 'package:maprisma_manager_core/maprisma_manager_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

Map<String, dynamic> repoJson(String slug, {bool private = false, String branch = 'main'}) => {
  'full_name': slug,
  'html_url': 'https://github.com/$slug',
  'private': private,
  'visibility': private ? 'private' : 'public',
  'default_branch': branch,
};

Map<String, dynamic> releaseJson(String slug, String tag, List<String> assets) => {
  'tag_name': tag,
  'name': tag,
  'published_at': '2026-11-06T00:04:28Z',
  'html_url': 'https://github.com/$slug/releases/tag/$tag',
  'draft': false,
  'prerelease': false,
  'assets': [
    for (final a in assets) {'name': a, 'size': 10, 'browser_download_url': 'https://github.com/$slug/releases/download/$tag/$a'},
  ],
};

/// The REST API as a map of paths → (status, JSON); everything else 404. Calls are recorded.
HttpGet restFixture(Map<String, (int, Object?)> routes, List<String> calls, {Map<String, String> headers = const {}}) =>
    (uri) async {
      final path = uri.path.substring(1);
      calls.add(path);
      final r = routes[path];
      if (r == null) return (status: 404, body: '{"message":"Not Found"}', headers: const <String, String>{});
      return (status: r.$1, body: jsonEncode(r.$2), headers: headers);
    };

void main() {
  late World w;
  setUp(() {
    w = World.create();
    w.fake('pacman', 'exit 1');
  });
  tearDown(() => w.dispose());

  final launcherRoutes = <String, (int, Object?)>{
    'repos/maprisma/launcher': (200, repoJson('maprisma/launcher')),
    'repos/maprisma/launcher/releases/latest': (
      200,
      releaseJson('maprisma/launcher', 'v0.1.4', ['maprisma-launcher-0.1.4-x86_64.tar.gz', 'maprisma-launcher-0.1.4-x86_64.tar.gz.sha256']),
    ),
    'repos/maprisma/narrator': (200, repoJson('maprisma/narrator')),
  };

  group('facts', () {
    test('gh absent: the REST fixture; cached with age; no release = null; throttled; force', () async {
      var now = DateTime.utc(2026, 11, 9, 12);
      final core = w.core(clock: () => now);
      final calls = <String>[];
      core.ctx.github.http = restFixture(launcherRoutes, calls);
      var r = await core.call('github.refresh', {'id': 'launcher'});
      expect(r['via'], 'rest');
      expect(r['repos'].single, containsPair('checked', true));
      expect(r['repos'].single['release'], 'v0.1.4');
      final f = core.ctx.github.facts('maprisma/launcher');
      expect(f['public'], isTrue);
      expect(f['defaultBranch'], 'main');
      expect(f['url'], 'https://github.com/maprisma/launcher');
      expect((f['release'] as Map)['assets'], hasLength(2));
      expect(f['age'], 0);
      expect(File(p.join(w.paths.managerState, 'github.json')).existsSync(), isTrue);

      r = await core.call('github.refresh', {'id': 'narrator'});
      expect(core.ctx.github.facts('maprisma/narrator')['release'], isNull);
      expect(core.ctx.github.facts('maprisma/narrator')['known'], isTrue);

      // within 30 min: skipped; after: read again; force: always
      calls.clear();
      now = now.add(const Duration(minutes: 10));
      r = await core.call('github.refresh', {'id': 'launcher'});
      expect(r['repos'].single, containsPair('skipped', 'recent'));
      expect(calls, isEmpty);
      r = await core.call('github.refresh', {'id': 'launcher', 'force': true});
      expect(r['repos'].single, containsPair('checked', true));
      now = now.add(const Duration(minutes: 31));
      expect(core.ctx.github.facts('maprisma/launcher')['stale'], isTrue);
      r = await core.call('github.refresh', {'id': 'launcher'});
      expect(r['repos'].single, containsPair('checked', true));
      // an app that isn't on GitHub
      r = await core.call('github.refresh', {'id': 'home'});
      expect(r['note'], 'not on GitHub');
    });

    test('offline: the last known facts stay, with their age and the error; the rest is skipped', () async {
      var now = DateTime.utc(2026, 11, 9, 12);
      final core = w.core(clock: () => now);
      core.ctx.github.http = restFixture(launcherRoutes, []);
      await core.call('github.refresh', {'id': 'launcher'});
      now = now.add(const Duration(hours: 2));
      core.ctx.github.http = (uri) async => throw const SocketException('no network');
      final r = await core.call('github.refresh', {'force': true});
      final first = (r['repos'] as List).first as Map;
      expect(first['error'], startsWith('offline'));
      expect((r['repos'] as List).skip(1).every((e) => e['skipped'] == 'offline'), isTrue);
      await core.call('github.refresh', {'id': 'launcher', 'force': true});
      final f = core.ctx.github.facts('maprisma/launcher');
      expect(f['known'], isTrue);
      expect((f['release'] as Map)['tag'], 'v0.1.4');
      expect(f['age'], 7200);
      expect(f['error'], startsWith('offline'));
    });

    test('rate limited: reported with its reset; no more requests in that refresh', () async {
      final core = w.core();
      final calls = <String>[];
      core.ctx.github.http = restFixture({
        for (final s in GitHub.slugs()) 'repos/$s': (403, {'message': 'API rate limit exceeded'}),
      }, calls, headers: {'x-ratelimit-remaining': '0', 'x-ratelimit-reset': '1794225600'});
      final r = await core.call('github.refresh', {'force': true});
      expect((r['repos'] as List).first['error'], startsWith('rate limited until 2026-'));
      expect((r['repos'] as List).skip(1).every((e) => (e['skipped'] as String).startsWith('rate limited')), isTrue);
      expect(calls, hasLength(1));
    });

    test('gh present and logged in: gh api is used; not logged in: REST', () async {
      final fixtures = p.join(w.home, '.gh-fixtures');
      w.writeFile(p.join(fixtures, 'repos_maprisma_launcher.json'), jsonEncode(repoJson('maprisma/launcher')));
      w.writeFile(p.join(fixtures, 'repos_maprisma_launcher_releases_latest.json'),
          jsonEncode(releaseJson('maprisma/launcher', 'v0.1.4', ['maprisma-launcher-0.1.4-x86_64.tar.gz'])));
      w.fake('gh', r'''echo "$*" >> "$HOME/.gh-calls"
case "$1" in
  auth) [ -e "$HOME/.gh-logged-in" ] && exit 0; echo "You are not logged into any GitHub hosts" >&2; exit 1;;
  api) f="$HOME/.gh-fixtures/$(echo "$4" | tr '/' '_').json"
       [ -e "$f" ] && { cat "$f"; exit 0; }
       echo '{"message":"Not Found","status":"404"}'; echo "gh: Not Found (HTTP 404)" >&2; exit 1;;
esac
exit 1''');
      // the fake needs cat and tr; a real gh in /usr/bin is never used (offline, gh named)
      final ghEnv = {'MAPRISMA_MANAGER_GH': p.join(w.fakeBin, 'gh'), 'PATH': '${w.fakeBin}:/usr/bin:/bin'};
      // not logged in: REST
      var core = w.core(extra: ghEnv);
      core.ctx.github.http = restFixture(launcherRoutes, []);
      var r = await core.call('github.refresh', {'id': 'launcher', 'force': true});
      expect(r['via'], 'rest');
      // logged in: gh api, the 404 of a missing release is "no release"
      File(p.join(w.home, '.gh-logged-in')).createSync();
      core = w.core(extra: ghEnv);
      core.ctx.github.http = (uri) async => throw StateError('REST must not be used');
      r = await core.call('github.refresh', {'id': 'launcher', 'force': true});
      expect(r['via'], 'gh');
      expect(r['repos'].single['release'], 'v0.1.4');
      expect(File(p.join(w.home, '.gh-calls')).readAsStringSync(), contains('api -H Accept: application/vnd.github+json repos/maprisma/launcher'));
      w.writeFile(p.join(fixtures, 'repos_maprisma_narrator.json'), jsonEncode(repoJson('maprisma/narrator')));
      r = await core.call('github.refresh', {'id': 'narrator', 'force': true});
      expect(r['repos'].single, containsPair('checked', true));
      expect(core.ctx.github.facts('maprisma/narrator')['release'], isNull);
      expect(core.ctx.github.facts('maprisma/narrator')['via'], 'gh');
    });

    test('gh offline (no connection): the refresh stops, the last facts stay', () async {
      w.fake('gh', r'''case "$1" in
  auth) exit 0;;
  api) echo "error connecting to api.github.com" >&2; echo "check your internet connection or https://githubstatus.com" >&2; exit 1;;
esac
exit 1''');
      final core = w.core(extra: {'MAPRISMA_MANAGER_GH': p.join(w.fakeBin, 'gh')});
      final r = await core.call('github.refresh', {'force': true});
      expect(r['via'], 'gh');
      expect((r['repos'] as List).first['error'], startsWith('offline: gh: error connecting'));
      expect((r['repos'] as List).skip(1).every((e) => e['skipped'] == 'offline'), isTrue);
    });

    test('gh absent from the test PATH and offline: the built-in REST refuses (no network)', () async {
      final core = w.core();
      final r = await core.call('github.refresh', {'id': 'launcher', 'force': true});
      expect(r['repos'].single['error'], contains('offline'));
    });
  });

  group('helpers', () {
    test('GitHub URLs, versions, sha256 files', () {
      expect(githubSlugOf('https://github.com/maprisma/maprisma.git'), 'maprisma/maprisma');
      expect(githubSlugOf('git@github.com:uBruckhaus/Maprisma.git'), 'ubruckhaus/maprisma');
      expect(githubSlugOf('ssh://git@github.com/maprisma/launcher'), 'maprisma/launcher');
      expect(githubSlugOf('/tmp/x.git'), isNull);
      expect(compareVersions('v0.14.2', '0.13.1-9'), greaterThan(0));
      expect(compareVersions('v0.1.4', '0.1.4'), 0);
      expect(compareVersions('v0.1.10', '0.1.9+3'), greaterThan(0));
      expect(compareVersions('nightly', '0.1'), isNull);
      final h = 'a' * 64;
      expect(parseSha256File('$h  x.tar.gz\n', 'x.tar.gz'), h);
      expect(parseSha256File(h, 'x.tar.gz'), h);
      expect(parseSha256File('$h  other.tar.gz', 'x.tar.gz'), isNull);
      expect(parseSha256File('nothing', 'x.tar.gz'), isNull);
      expect(validTag('v0.1.4'), isTrue);
      expect(validTag('../x'), isFalse);
      expect(validTag('a/b'), isFalse);
    });

    test('the catalog: GitHub repos as checked 2026-11-10', () {
      final slugs = {for (final a in builtinCatalog) for (final i in a.inputs) i.repo: i.github};
      expect(slugs, {
        'maprisma': 'maprisma/maprisma',
        'maprisma-addons': 'maprisma/maprisma-addons',
        'maprisma-applet': null,
        'maprisma-launcher': 'maprisma/launcher',
        'maprisma-launcher-applet': null,
        'maprisma-theme': null,
        'maprisma-bluetooth-monitor': 'maprisma/bluetooth-monitor',
        'maprisma-home': null,
        'maprisma-hue-lights': 'maprisma/hue-lights',
        'maprisma-llm-monitor': 'maprisma/llm-monitor',
        'maprisma-wlan-monitor': 'maprisma/wlan-monitor',
        'maprisma-narrator': 'maprisma/narrator',
        'maprisma-video-translator': null,
        'maprisma-kwin-scripts': 'maprisma/maprisma-kwin-scripts',
        'maprisma-panel': null,
        'maprisma-manager': null,
      });
      expect(findApp('launcher')!.release!.asset('0.1.4'), 'maprisma-launcher-0.1.4-x86_64.tar.gz');
      expect(findApp('maprisma')!.release!.supported, isTrue);
    });
  });

  group('sources in the status', () {
    /// The wlan folder: origin a private stand-in, `gh` the GitHub stand-in (a local bare repo).
    (String folder, String github) twoRemotes() {
      final dir = w.repo('maprisma-wlan-monitor', upstream: true); // origin = remotes/<name>.git
      final gh = p.join(w.dir, 'github', 'wlan-monitor.git');
      Directory(p.dirname(gh)).createSync(recursive: true);
      w.git(w.dir, ['init', '-q', '--bare', gh]);
      w.git(dir, ['remote', 'add', 'gh', gh]);
      w.git(dir, ['push', '-q', 'gh', 'main']);
      return (dir, gh);
    }

    void pushTo(String bare) {
      final other = p.join(w.dir, 'push-${DateTime.now().microsecondsSinceEpoch}');
      w.git(w.dir, ['clone', '-q', bare, other]);
      File(p.join(other, 'GH')).writeAsStringSync('new\n');
      w.git(other, ['add', '.']);
      w.git(other, ['commit', '-q', '-m', 'on github']);
      w.git(other, ['push', '-q', 'origin', 'main']);
    }

    test('folder + GitHub: the GitHub remote by URL (not by name), compared after git.fetch fetched it explicitly', () async {
      final (_, gh) = twoRemotes();
      final core = w.core();
      core.ctx.cloneUrlFor = (slug) => slug == 'maprisma/wlan-monitor' ? gh : 'https://github.com/$slug.git';
      var a = appOf(await core.call('apps.list'), 'wlan');
      final src = a['sources'] as Map<String, dynamic>;
      expect(src['where'], 'both');
      final input = (src['inputs'] as List).single as Map<String, dynamic>;
      expect(input['folder']['path'], p.join(w.projects, 'maprisma-wlan-monitor'));
      expect(input['folder']['present'], isTrue);
      expect(input['github']['url'], 'https://github.com/maprisma/wlan-monitor');
      expect(input['github']['known'], isFalse);
      expect(input['remote'], {'name': 'gh', 'url': gh, 'isUpstream': false});
      expect(input['compare']['ref'], 'gh/main');
      expect(input['compare']['relation'], 'upToDate');
      expect(a['updates']['githubNew'], 0);

      pushTo(gh);
      final f = await core.call('git.fetch', {'id': 'wlan', 'force': true});
      final repo = (f['repos'] as List).single as Map;
      expect([for (final r in repo['remotes'] as List) r['remote']], ['origin', 'gh']);
      expect(repo['github'], containsPair('behind', 1));
      a = appOf(await core.call('apps.list'), 'wlan');
      expect(a['updates']['githubNew'], 1);
      expect(a['updates']['upstreamNew'], 0); // the configured upstream (origin) has nothing new
      expect(statusTable(await core.call('apps.list')), contains('GitHub +1'));
    });

    test('a folder without a GitHub remote, a missing folder, local only; SOURCE column and sources table', () async {
      w.repo('maprisma-wlan-monitor'); // no remote
      w.repo('maprisma-home');
      final core = w.core();
      final list = await core.call('apps.list');
      expect(appOf(list, 'wlan')['sources']['where'], 'both');
      expect(appOf(list, 'wlan')['updates']['githubNotes'].single, contains('no remote of the folder is https://github.com/maprisma/wlan-monitor'));
      expect(appOf(list, 'llm')['sources']['where'], 'GitHub');
      expect(appOf(list, 'llm')['repos'][0]['available'], 'cloneable');
      expect(appOf(list, 'home')['sources']['where'], 'folder');
      expect(appOf(list, 'theme')['sources']['where'], 'none');
      final table = statusTable(list);
      expect(table.split('\n')[1], contains('SOURCE'));
      expect(RegExp(r'^home\s+not installed\s+-\s+folder', multiLine: true).hasMatch(table), isTrue, reason: table);
      final sources = sourcesTable(list);
      expect(sources, contains('https://github.com/maprisma/llm-monitor'));
      expect(RegExp(r'^llm\s+maprisma-llm-monitor\s+missing\s+https://github.com/maprisma/llm-monitor\s+unknown', multiLine: true).hasMatch(sources), isTrue, reason: sources);
      expect(RegExp(r'^theme\s+maprisma-theme\s+missing\s+local only', multiLine: true).hasMatch(sources), isTrue, reason: sources);
      expect(sources, contains('never checked'));
    });

    test('a newer release than the installed version; status <id> shows folder, GitHub URL and release', () async {
      final now = DateTime.utc(2026, 11, 9, 12);
      final core = w.core(clock: () => now);
      core.ctx.github.http = restFixture(launcherRoutes, []);
      await core.call('github.refresh', {'id': 'launcher'});
      w.install('launcher');
      w.writeFile(w.paths.expand('{lib}/maprisma-launcher/data/flutter_assets/version.json'), '{"app_name":"x","version":"0.1.2","build_number":"1"}');
      w.repo('maprisma-launcher');
      final a = appOf(await core.call('apps.list'), 'launcher');
      expect(a['updates']['releaseNew'], {'tag': 'v0.1.4', 'version': '0.1.4', 'installed': '0.1.2', 'installable': true});
      expect(a['versions']['release'], '0.1.4');
      expect(a['sources']['release']['tag'], 'v0.1.4');
      final out = _Capture();
      expect(await runCli(['status', 'launcher'], service: core, out: out), 0);
      expect(out.text, contains('Folder:  ${p.join(w.projects, 'maprisma-launcher')} (main @'));
      expect(out.text, contains('GitHub:  https://github.com/maprisma/launcher (public; no remote of the folder;'));
      expect(out.text, contains('Release: v0.1.4 (2026-11-06)  https://github.com/maprisma/launcher/releases/tag/v0.1.4'));
      expect(out.text, contains('Newer release: v0.1.4 (installed 0.1.2); install with: release launcher'));
      expect(out.text, contains('maprisma-launcher-applet:'));
      expect(out.text, contains('GitHub:  - (local only)'));
      // same version: nothing newer
      w.writeFile(w.paths.expand('{lib}/maprisma-launcher/data/flutter_assets/version.json'), '{"version":"0.1.4"}');
      expect(appOf(await core.call('apps.list'), 'launcher')['updates']['releaseNew'], isNull);
      // the sources CLI
      final out2 = _Capture();
      expect(await runCli(['sources'], service: core, out: out2), 0);
      expect(out2.text, contains('v0.1.4 (2026-11-06)'));
    });
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
