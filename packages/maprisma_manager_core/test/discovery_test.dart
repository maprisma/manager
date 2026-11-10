// Found GitHub repos and new apps: catalog apps without a GitHub repo in the catalog get the one
// of their folder's remote or the org repo of their name; maprisma* folders and org repos the
// catalog doesn't know are listed, and a GitHub-only one can be cloned. Never the network.
import 'dart:convert';
import 'dart:io';

import 'package:maprisma_manager_core/maprisma_manager_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'github_test.dart' show restFixture;
import 'support.dart';

Map<String, dynamic> orgRepo(String name, {bool private = false, bool archived = false, String? description}) => {
  'name': name,
  'html_url': 'https://github.com/maprisma/$name',
  'private': private,
  'archived': archived,
  'fork': false,
  'description': description,
};

Map<String, dynamic> appOf(Map<String, dynamic> list, String id) =>
    (list['apps'] as List).cast<Map<String, dynamic>>().firstWhere((a) => a['id'] == id);

void main() {
  late World w;
  setUp(() {
    w = World.create();
    w.fake('pacman', 'exit 1');
  });
  tearDown(() => w.dispose());

  /// The org's list as the REST API gives it (everything else 404).
  HttpGet org(List<Map<String, dynamic>> repos, List<String> calls) => restFixture({'orgs/maprisma/repos': (200, repos)}, calls);

  test('a catalog app without a GitHub repo gets its folder\'s GitHub remote', () async {
    final dir = w.repo('maprisma-theme');
    w.git(dir, ['remote', 'add', 'origin', 'https://github.com/maprisma/theme.git']);
    final core = w.core();
    final a = appOf(await core.call('apps.list'), 'theme');
    final input = ((a['sources'] as Map)['inputs'] as List).first as Map;
    expect(input['github']['repo'], 'maprisma/theme');
    expect(input['github']['linkedBy'], 'remote');
    expect(input['remote']['name'], 'origin');
    expect((a['sources'] as Map)['where'], 'both');
    expect(core.ctx.github.slugs(), contains('maprisma/theme'));
  });

  test('without a GitHub remote: the org repo of its name, once the org was listed', () async {
    w.repo('maprisma-home'); // no remote
    final core = w.core();
    expect(((appOf(await core.call('apps.list'), 'home')['sources'] as Map)['inputs'] as List).first['github'], isNull);

    final calls = <String>[];
    core.ctx.github.http = org([orgRepo('home'), orgRepo('launcher')], calls);
    final r = await core.call('github.refresh', {'force': true});
    expect((r['org'] as Map)['checked'], isTrue);
    expect(calls.first, 'orgs/maprisma/repos'); // (the query, page=1, isn't in the recorded path)
    // the found repo is refreshed in the same run
    expect([for (final x in r['repos'] as List) x['repo']], contains('maprisma/home'));

    final input = ((appOf(await core.call('apps.list'), 'home')['sources'] as Map)['inputs'] as List).first as Map;
    expect(input['github']['repo'], 'maprisma/home');
    expect(input['github']['linkedBy'], 'org');
    expect(input['remote'], isNull); // the folder has no remote that is it
  });

  test('a catalog GitHub repo is never replaced by a folder remote', () async {
    final dir = w.repo('maprisma-wlan-monitor');
    w.git(dir, ['remote', 'add', 'origin', 'https://github.com/someone/fork.git']);
    final core = w.core();
    final input = ((appOf(await core.call('apps.list'), 'wlan')['sources'] as Map)['inputs'] as List).first as Map;
    expect(input['github']['repo'], 'maprisma/wlan-monitor');
    expect(input['github']['linkedBy'], 'catalog');
  });

  test('new apps: unknown maprisma* folders and org repos; known ones, copies, omarchy and archived are not listed', () async {
    // a new local app with its GitHub remote, a local-only one, a copy of a known app
    final sky = w.repo('maprisma-sky');
    w.git(sky, ['remote', 'add', 'origin', 'git@github.com:maprisma/sky.git']);
    w.repo('maprisma-notes');
    final copy = w.repo('maprisma-wlan-old');
    w.git(copy, ['remote', 'add', 'origin', 'https://github.com/maprisma/wlan-monitor.git']);
    Directory(p.join(w.projects, 'maprisma-plain')).createSync(recursive: true); // no git repo
    w.repo('other-thing');

    final core = w.core();
    final calls = <String>[];
    core.ctx.github.http = org([
      orgRepo('sky', description: 'Sky'),
      orgRepo('notes'), // the local-only folder of its name
      orgRepo('clock', private: true, description: 'A clock'),
      orgRepo('wlan-monitor'),
      orgRepo('omarchy-maprisma'),
      orgRepo('old', archived: true),
      orgRepo('maprisma-addons'),
      orgRepo('../escape'),
      orgRepo('.github'),
    ], calls);
    await core.call('github.refresh', {'force': true});

    final d = (await core.call('apps.list'))['discovered'] as Map;
    final apps = (d['apps'] as List).cast<Map<String, dynamic>>();
    expect([for (final a in apps) a['name']], ['clock', 'maprisma-notes', 'maprisma-sky']);
    final clock = apps[0], notes = apps[1], skyApp = apps[2];
    expect(clock['folder'], isNull);
    expect(clock['cloneTo'], p.join(w.projects, 'maprisma-clock'));
    expect(clock['github'], containsPair('public', false));
    expect(clock['github'], containsPair('linkedBy', 'org'));
    expect(notes['folder'], p.join(w.projects, 'maprisma-notes'));
    expect(notes['github'], containsPair('linkedBy', 'name'));
    expect(skyApp['github'], containsPair('repo', 'maprisma/sky'));
    expect(skyApp['github'], containsPair('linkedBy', 'remote'));
    expect(skyApp['github'], containsPair('description', 'Sky'));
    expect((d['org'] as Map)['known'], isTrue);
  });

  test('a GitHub-only new app is cloned into the projects folder; nothing else is', () async {
    final bare = p.join(w.dir, 'github', 'clock.git');
    final src = p.join(w.dir, 'src-clock');
    Directory(src).createSync(recursive: true);
    w.git(src, ['init', '-q', '-b', 'main']);
    File(p.join(src, 'README.md')).writeAsStringSync('clock\n');
    w.git(src, ['add', '.']);
    w.git(src, ['commit', '-q', '-m', 'one']);
    w.git(w.dir, ['clone', '-q', '--bare', src, bare]);

    final core = w.core();
    core.ctx.cloneUrlFor = (slug) => slug == 'maprisma/clock' ? bare : '/nowhere/$slug.git';
    core.ctx.github.http = org([orgRepo('clock')], <String>[]);
    await core.call('github.refresh', {'force': true});

    await expectLater(core.call('discovered.clone', {'repo': 'maprisma/launcher'}), throwsA(isA<RouteError>().having((e) => e.code, 'code', 'not_found')));
    await expectLater(core.call('discovered.clone', {'repo': '../x'}), throwsA(isA<RouteError>().having((e) => e.code, 'code', 'bad_params')));

    final r = await core.call('discovered.clone', {'repo': 'maprisma/clock'});
    final to = p.join(w.projects, 'maprisma-clock');
    expect(r['folder'], to);
    expect(File(p.join(to, 'README.md')).readAsStringSync(), 'clock\n');
    expect(Directory(w.projects).listSync().map((e) => p.basename(e.path)).where((n) => n.contains('.clone-')), isEmpty);

    // now it has a folder: listed with it, and not cloned again
    final d = (await core.call('discovered.list'))['apps'] as List;
    expect((d.single as Map)['folder'], to);
    await expectLater(core.call('discovered.clone', {'repo': 'maprisma/clock'}), throwsA(isA<RouteError>().having((e) => e.code, 'code', 'exists')));
  });

  test('a failed clone leaves nothing behind', () async {
    final core = w.core();
    core.ctx.cloneUrlFor = (slug) => p.join(w.dir, 'gone.git');
    core.ctx.github.http = org([orgRepo('clock')], <String>[]);
    await core.call('github.refresh', {'force': true});
    await expectLater(core.call('discovered.clone', {'repo': 'maprisma/clock'}), throwsA(isA<RouteError>().having((e) => e.code, 'code', 'clone_failed')));
    expect(Directory(w.projects).existsSync() ? Directory(w.projects).listSync().map((e) => p.basename(e.path)).where((n) => n.contains('clock')) : const [], isEmpty);
  });

  test('the org list: refreshed at most every 30 minutes; a failure keeps the last list', () async {
    var now = DateTime.utc(2026, 11, 10, 8);
    final core = w.core(clock: () => now);
    final calls = <String>[];
    core.ctx.github.http = org([orgRepo('clock')], calls);
    expect((await core.ctx.github.refreshOrg())['checked'], isTrue);
    expect((await core.ctx.github.refreshOrg())['skipped'], 'recent');
    now = now.add(const Duration(minutes: 31));
    core.ctx.github.http = restFixture({'orgs/maprisma/repos': (500, {'message': 'boom'})}, calls);
    expect((await core.ctx.github.refreshOrg())['checked'], isFalse);
    expect([for (final r in core.ctx.github.orgRepos()) r['name']], ['clock']);
    expect(core.ctx.github.orgFacts()['error'], contains('500'));
  });

  test('the org list: every page is read; a failing later page keeps the last full list', () async {
    final core = w.core();
    final pages = <String>[];
    var failPage2 = false;
    core.ctx.github.http = (uri) async {
      final page = int.parse(uri.queryParameters['page'] ?? '1');
      pages.add('$page');
      if (failPage2 && page == 2) return (status: 500, body: '{"message":"boom"}', headers: const <String, String>{});
      final names = page == 1 ? [for (var i = 0; i < 100; i++) 'app$i'] : (page == 2 ? ['last'] : <String>[]);
      return (status: 200, body: jsonEncode([for (final n in names) orgRepo(n)]), headers: const <String, String>{});
    };
    final r = await core.ctx.github.refreshOrg(force: true);
    expect(r['repos'], 101);
    expect(pages, ['1', '2']);
    expect(core.ctx.github.orgRepos().last['name'], 'last');

    failPage2 = true;
    pages.clear();
    expect((await core.ctx.github.refreshOrg(force: true))['checked'], isFalse);
    expect(core.ctx.github.orgRepos(), hasLength(101)); // the last full list stays
  });

  test('a new app\'s clone folder is never a catalog app\'s nor another new app\'s', () async {
    final core = w.core();
    core.ctx.github.http = org([orgRepo('maprisma-launcher'), orgRepo('clock'), orgRepo('maprisma-clock')], <String>[]);
    await core.call('github.refresh', {'force': true});
    final apps = ((await core.call('discovered.list'))['apps'] as List).cast<Map<String, dynamic>>();
    Map<String, dynamic> named(String n) => apps.firstWhere((a) => a['name'] == n);
    // the catalog's Launcher is maprisma/launcher, in the folder maprisma-launcher
    expect(named('maprisma-launcher')['cloneTo'], isNull);
    expect(named('maprisma-launcher')['cloneBlocked'], contains('a catalog app'));
    // clock and maprisma-clock would both go to maprisma-clock: only the first one may
    expect(named('clock')['cloneTo'], p.join(w.projects, 'maprisma-clock'));
    expect(named('maprisma-clock')['cloneTo'], isNull);
    await expectLater(core.call('discovered.clone', {'repo': 'maprisma/maprisma-launcher'}),
        throwsA(isA<RouteError>().having((e) => e.code, 'code', 'exists')));
    expect(Directory(p.join(w.projects, 'maprisma-launcher')).existsSync(), isFalse);
  });
}
