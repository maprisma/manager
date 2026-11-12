import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late World w;
  setUp(() {
    w = World.create();
    w.fake('pacman', 'exit 1');
  });
  tearDown(() => w.dispose());

  Map<String, dynamic> repoOf(Map<String, dynamic> app) => (app['repos'] as List).first as Map<String, dynamic>;

  test('provenance: branch, HEAD, clean, the configured upstream', () async {
    w.repo('maprisma-wlan-monitor', upstream: true);
    final g = repoOf(appOf(await w.core().call('apps.list'), 'wlan'));
    expect(g['branch'], 'main');
    expect(g['head'], w.head('maprisma-wlan-monitor'));
    expect(g['dirty'], isFalse);
    expect(g['upstream'], 'origin/main');
    expect(g['upstreamRemote'], 'origin');
    expect(g['relation'], 'upToDate');
    expect([g['ahead'], g['behind']], [0, 0]);
  });

  test('a non-origin upstream on another branch is followed, not origin/main', () async {
    final dir = w.repo('maprisma-wlan-monitor', upstream: true);
    w.git(dir, ['remote', 'rename', 'origin', 'public']);
    w.git(dir, ['checkout', '-q', '-b', 'work']);
    w.git(dir, ['push', '-q', '-u', 'public', 'work']);
    final g = repoOf(appOf(await w.core().call('apps.list'), 'wlan'));
    expect(g['branch'], 'work');
    expect(g['upstream'], 'public/work');
    expect(g['upstreamRemote'], 'public');
  });

  test('no upstream: none; untracked files make it dirty; detached HEAD', () async {
    final dir = w.repo('maprisma-home');
    File(p.join(dir, 'new.txt')).writeAsStringSync('x');
    var a = appOf(await w.core().call('apps.list'), 'home');
    expect(repoOf(a)['upstream'], isNull);
    expect(repoOf(a)['untracked'], 1);
    expect(a['updates']['upstreamNew'], isNull);
    w.git(dir, ['checkout', '-q', '--detach']);
    a = appOf(await w.core().call('apps.list'), 'home');
    expect(repoOf(a)['detached'], isTrue);
  });

  test('a folder inside another repo is not taken as a repo', () async {
    w.git(w.projects, ['init', '-q']);
    Directory(p.join(w.projects, 'maprisma-home')).createSync();
    final g = repoOf(appOf(await w.core().call('apps.list'), 'home'));
    expect(g['present'], isTrue);
    expect(g['isRepo'], isFalse);
    expect(g['error'], 'not a git repository');
  });

  test('fetch: new upstream commits counted with ancestry; throttled; force fetches again', () async {
    w.repo('maprisma-wlan-monitor', upstream: true);
    w.pushUpstreamCommit('maprisma-wlan-monitor');
    var now = DateTime.now();
    final core = w.core(clock: () => now);
    // before a fetch the core knows nothing new
    expect(appOf(await core.call('apps.list'), 'wlan')['updates']['upstreamNew'], 0);

    var r = await core.call('git.fetch', {'id': 'wlan', 'force': true});
    expect(r['repos'].single, containsPair('fetched', true));
    var a = appOf(await core.call('apps.list'), 'wlan');
    expect(repoOf(a)['relation'], 'behind');
    expect(a['updates']['upstreamNew'], 1);
    expect(repoOf(a)['lastFetch'], isNotNull);

    r = await core.call('git.fetch', {'id': 'wlan'});
    expect(r['repos'].single, containsPair('skipped', 'recent'));
    now = now.add(const Duration(minutes: 31));
    r = await core.call('git.fetch', {'id': 'wlan'});
    expect(r['repos'].single, containsPair('fetched', true));
  });

  test('a fetch that fails is reported and counts for the throttle', () async {
    final dir = w.repo('maprisma-wlan-monitor', upstream: true);
    w.git(dir, ['remote', 'set-url', 'origin', p.join(w.dir, 'gone.git')]);
    final now = DateTime.now().add(const Duration(days: 1)); // FETCH_HEAD (from the push) is old by then
    final core = w.core(clock: () => now);
    var r = await core.call('git.fetch', {'id': 'wlan'});
    expect(r['repos'].single['fetched'], isFalse);
    expect(r['repos'].single['error'], isNotNull);
    r = await core.call('git.fetch', {'id': 'wlan'});
    expect(r['repos'].single, containsPair('skipped', 'recent'));
  });

  test('diverged: both sides have commits', () async {
    final dir = w.repo('maprisma-wlan-monitor', upstream: true);
    w.pushUpstreamCommit('maprisma-wlan-monitor');
    File(p.join(dir, 'LOCAL')).writeAsStringSync('x');
    w.git(dir, ['add', '.']);
    w.git(dir, ['commit', '-q', '-m', 'local']);
    final core = w.core();
    await core.call('git.fetch', {'id': 'wlan', 'force': true});
    final a = appOf(await core.call('apps.list'), 'wlan');
    expect(repoOf(a)['relation'], 'diverged');
    expect([repoOf(a)['ahead'], repoOf(a)['behind']], [1, 1]);
    expect(a['updates']['upstreamNotes'].single, contains('diverged'));
  });

  test('diverged history with the very same files: sameContent, nothing new', () async {
    final dir = w.repo('maprisma-wlan-monitor', upstream: true);
    w.pushUpstreamCommit('maprisma-wlan-monitor');
    final core = w.core();
    await core.call('git.fetch', {'id': 'wlan', 'force': true});
    // The upstream's files, committed again under another commit (as a rewritten mirror has them).
    w.git(dir, ['checkout', '-q', 'origin/main', '--', '.']);
    w.git(dir, ['commit', '-q', '-m', 'same files, other commit']);
    final a = appOf(await core.call('apps.list'), 'wlan');
    expect(repoOf(a)['relation'], 'sameContent');
    expect([repoOf(a)['ahead'], repoOf(a)['behind']], [1, 1]);
    expect(a['updates']['upstreamNew'], 0);
    expect(a['updates']['upstreamNotes'], isNull);
  });

  test('a rewritten mirror of older work: ahead, nothing new', () async {
    final dir = w.repo('maprisma-wlan-monitor', upstream: true);
    w.pushUpstreamCommit('maprisma-wlan-monitor');
    final core = w.core();
    await core.call('git.fetch', {'id': 'wlan', 'force': true});
    // The upstream's files under another commit, then more local work on top.
    w.git(dir, ['checkout', '-q', 'origin/main', '--', '.']);
    w.git(dir, ['commit', '-q', '-m', 'same files, other commit']);
    File(p.join(dir, 'LOCAL')).writeAsStringSync('more');
    w.git(dir, ['add', '.']);
    w.git(dir, ['commit', '-q', '-m', 'local work']);
    final a = appOf(await core.call('apps.list'), 'wlan');
    expect(repoOf(a)['relation'], 'ahead');
    expect(a['updates']['upstreamNew'], 0);
    expect(a['updates']['upstreamNotes'], isNull);
  });

  test('repos without an upstream are skipped by fetch', () async {
    w.repo('maprisma-home');
    final r = await w.core().call('git.fetch', {'id': 'home', 'force': true});
    expect(r['repos'].single, containsPair('skipped', 'no upstream'));
  });
}
