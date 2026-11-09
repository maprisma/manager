// Step 5b: Maprisma as a pacman package, and changing an app's bar icon.
//
// Never the real pacman, pkexec, makepkg or systemctl: fakes in the world's bin folder come
// first in PATH, and the jobs refuse a system pkexec/pacman/makepkg when the root is a test root.
// The fake makepkg runs the generated PKGBUILD's package() for real; the fake pacman installs
// into the world's root. Never the real panel: followPanel is replaced.
import 'dart:convert';
import 'dart:io';

import 'package:maprisma_manager_core/maprisma_manager_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

const _sysbin = '/usr/bin:/bin';

const _fakeMakepkg = r'''#!/bin/bash
set -euo pipefail
t="$HOME/.mm-test"
echo "makepkg $*" >> "$t/calls.log"
source ./PKGBUILD
out="$PKGDEST/$pkgname-$pkgver-$pkgrel-x86_64.pkg.tar.zst"
if [[ ${1:-} == --packagelist ]]; then echo "$out"; exit 0; fi
[[ -e $t/makepkg-fail ]] && { echo "==> ERROR: a fake failure" >&2; exit 4; }
entry=${source[0]}; name=${entry%%::*}; url=${entry#*::}; src=${url#file://}
cp "$src" "$SRCDEST/$name"
echo "${sha256sums[0]}  $SRCDEST/$name" | sha256sum -c --quiet
srcdir="$BUILDDIR/src"; pkgdir="$BUILDDIR/pkg"; rm -rf "$BUILDDIR"; mkdir -p "$srcdir" "$pkgdir"
tar -xzf "$SRCDEST/$name" -C "$srcdir"
(cd "$srcdir" && package)
printf 'pkgname = %s\npkgver = %s-%s\narch = %s\n' "$pkgname" "$pkgver" "$pkgrel" "${arch[0]}" > "$pkgdir/.PKGINFO"
tar -cf "$out" -C "$pkgdir" .
echo "==> Finished making: $pkgname $pkgver-$pkgrel"
''';

const _fakePacman = r'''#!/bin/bash
set -euo pipefail
t="$HOME/.mm-test"; root="$(cd "$HOME/.." && pwd)/root"; state="$t/pacman.state"
echo "pacman $*" >> "$t/calls.log"
case "$1" in
  -Q) if [[ -s $state ]]; then echo "maprisma-bin $(cat "$state")"; exit 0; fi
      echo "error: package 'maprisma-bin' was not found" >&2; exit 1;;
  -Qip) info=$(tar -xOf "$2" ./.PKGINFO)
        printf 'Name            : %s\nVersion         : %s\nArchitecture    : %s\nDescription     : x\n' \
          "$(sed -n 's/^pkgname = //p' <<<"$info")" "$(sed -n 's/^pkgver = //p' <<<"$info")" "$(sed -n 's/^arch = //p' <<<"$info")";;
  -Qlp) tar -tf "$2" | grep -v PKGINFO | sed -e 's|^\./|/|' -e 's|/$||' | grep -v '^$' | sed 's|^|maprisma-bin |';;
  -U) [[ -e $t/pacman-fail ]] && { echo "error: failed to commit transaction (conflicting files)" >&2; exit 1; }
      [[ -e $t/pacman-dblock ]] && { echo "error: failed to init transaction (unable to lock database)" >&2; exit 1; }
      pkg=${@: -1}; rm -rf "$root/usr/lib/maprisma"; tar -xf "$pkg" -C "$root" --exclude=./.PKGINFO
      ln -sfn "$root/usr/lib/maprisma/maprisma" "$root/usr/bin/maprisma"
      tar -xOf "$pkg" ./.PKGINFO | sed -n 's/^pkgver = //p' > "$state"
      echo "(1/1) upgrading maprisma-bin";;
  -R) rm -rf "$root/usr/lib/maprisma" "$root/usr/bin/maprisma" "$root/usr/share/applications/com.maprisma.Maprisma.desktop" \
        "$root/usr/share/metainfo/com.maprisma.Maprisma.metainfo.xml" "$root/usr/share/icons/hicolor/scalable/apps/com.maprisma.Maprisma.svg" \
        "$root/usr/share/licenses/maprisma-bin"
      : > "$state"; echo "(1/1) removing maprisma-bin";;
  *) exit 2;;
esac
''';

/// pkexec: cancelled (126), never answered (stays pkexec), or becomes the fake pacman.
const _fakePkexec = r'''#!/bin/sh
t="$HOME/.mm-test"
echo "pkexec $*" >> "$t/calls.log"
[ -e "$t/pkexec-cancel" ] && exit 126
if [ -e "$t/pkexec-hang" ]; then while :; do sleep 0.1; done; fi
[ "$1" = /usr/bin/pacman ] || exit 127
shift
exec "$(dirname "$0")/pacman" "$@"
''';

const _fakeSystemctl = r'''#!/bin/sh
t="$HOME/.mm-test"
echo "systemctl $*" >> "$t/calls.log"
case "$*" in
  *is-active*) [ -e "$t/unit-active" ] && exit 0; exit 3;;
  *is-enabled*) [ -e "$t/unit-enabled" ] && exit 0; exit 1;;
  *" stop "*) rm -f "$t/unit-active";;
  *" start "*) touch "$t/unit-active";;
  *" disable "*) rm -f "$t/unit-enabled";;
  *" enable "*) touch "$t/unit-enabled";;
esac
exit 0
''';

/// The folder build: `dist/maprisma-<version>-x86_64.tar.gz` from the repo's stage/ folder.
const _fakeBuildRelease = r'''#!/usr/bin/env python3
import hashlib, pathlib, re, subprocess, sys
root = pathlib.Path(__file__).resolve().parent.parent
ver = re.search(r'^MAPRISMA_VERSION = "([0-9.]+)"', (root / 'addons.py').read_text(), re.M).group(1)
addons = pathlib.Path(sys.argv[sys.argv.index('--addons') + 1])
if not (addons / 'dist' / f'adapters-{ver}.zip').is_file():
    sys.exit('adapters missing')
(root / 'dist').mkdir(exist_ok=True)
out = root / 'dist' / f'maprisma-{ver}-x86_64.tar.gz'
subprocess.run(['tar', '-czf', str(out), '-C', str(root / 'stage'), f'maprisma-{ver}'], check=True)
digest = hashlib.sha256(out.read_bytes()).hexdigest()
(root / 'dist' / f'{out.name}.sha256').write_text(f'{digest}  {out.name}\n')
print(f'built {out}')
''';

const _svgA = '<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16"><path fill="currentColor" d="M1 1h14v14H1z"/></svg>\n';

void main() {
  late World w;
  late String assets;
  Map<String, dynamic> release = {};
  final followed = <int>[];

  String t(String f) => p.join(w.home, '.mm-test', f);
  String calls() => File(t('calls.log')).existsSync() ? File(t('calls.log')).readAsStringSync() : '';
  void flag(String f, [bool on = true]) => on ? File(t(f)).writeAsStringSync('') : (File(t(f)).existsSync() ? File(t(f)).deleteSync() : null);
  String sys(String path) => p.join(w.root, path.substring(1));

  /// A maprisma archive as `tools/build-release.py` lays it out.
  void stageArchive(String dir, String version) {
    final top = p.join(dir, 'maprisma-$version');
    w.writeFile(p.join(top, 'app/maprisma'), '#!/bin/sh\necho $version\n', mode: '755');
    w.writeFile(p.join(top, 'app/lib/maprisma-core'), '#!/bin/sh\n', mode: '755');
    w.writeFile(p.join(top, 'app/data/flutter_assets/version.json'), '{"app_name":"maprisma","version":"$version"}');
    w.writeFile(p.join(top, 'share/applications/com.maprisma.Maprisma.desktop'), '[Desktop Entry]\n');
    w.writeFile(p.join(top, 'share/metainfo/com.maprisma.Maprisma.metainfo.xml'), '<component/>\n');
    w.writeFile(p.join(top, 'share/icons/hicolor/scalable/apps/com.maprisma.Maprisma.svg'), _svgA);
    w.writeFile(p.join(top, 'LICENSE'), 'MIT\n');
  }

  String makeRelease(String version) {
    final stage = p.join(w.dir, 'stage-$version');
    stageArchive(stage, version);
    final name = 'maprisma-$version-x86_64.tar.gz';
    final r = Process.runSync('/usr/bin/tar', ['-czf', p.join(assets, name), '-C', stage, 'maprisma-$version']);
    if (r.exitCode != 0) throw StateError('tar: ${r.stderr}');
    final hash = sha256File(p.join(assets, name));
    File(p.join(assets, '$name.sha256')).writeAsStringSync('$hash  $name\n');
    release = {
      'tag_name': 'v$version',
      'published_at': '2026-11-06T00:00:00Z',
      'html_url': 'https://github.com/maprisma/maprisma/releases/tag/v$version',
      'assets': [
        {'name': name, 'size': File(p.join(assets, name)).lengthSync(), 'browser_download_url': 'https://github.com/maprisma/maprisma/releases/download/v$version/$name'},
        {'name': '$name.sha256', 'size': 90, 'browser_download_url': 'https://github.com/maprisma/maprisma/releases/download/v$version/$name.sha256'},
      ],
    };
    return hash;
  }

  setUp(() {
    w = World.create();
    Directory(p.join(w.home, '.mm-test')).createSync(recursive: true);
    w.writeFile(p.join(w.fakeBin, 'makepkg'), _fakeMakepkg, mode: '755');
    w.writeFile(p.join(w.fakeBin, 'pacman'), _fakePacman, mode: '755');
    w.writeFile(p.join(w.fakeBin, 'pkexec'), _fakePkexec, mode: '755');
    w.writeFile(p.join(w.fakeBin, 'systemctl'), _fakeSystemctl, mode: '755');
    for (final f in ['flutter', 'dart', 'gtk-update-icon-cache', 'update-desktop-database', 'cargo']) {
      w.fake(f, 'echo "$f \$*" >> "\$HOME/.mm-test/calls.log"; exit 0');
    }
    assets = p.join(w.dir, 'assets');
    Directory(assets).createSync();
    release = {};
    followed.clear();
  });

  tearDown(() => w.dispose());

  CoreService core({String desktop = 'COSMIC', String? path}) {
    final c = CoreService(
      environment: w.env(desktop: desktop, extra: {'PATH': path ?? '${w.fakeBin}:$_sysbin', 'MAPRISMA_FLUTTER': p.join(w.fakeBin, 'flutter')}),
      uid: currentUid(),
    )..followPanel = (_) async {
        followed.add(1);
        return {'panel': null, 'note': 'test'};
      };
    c.ctx.github.http = (uri) async {
      final path = uri.path.substring(1);
      if (path == 'repos/maprisma/maprisma') {
        return (status: 200, body: jsonEncode({'html_url': 'https://github.com/maprisma/maprisma', 'private': false, 'default_branch': 'main'}), headers: const <String, String>{});
      }
      if (release.isNotEmpty && (path == 'repos/maprisma/maprisma/releases/latest' || path == 'repos/maprisma/maprisma/releases/tags/${release['tag_name']}')) {
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
      ..appletWait = const Duration(milliseconds: 100)
      ..pollEvery = const Duration(milliseconds: 30)
      ..stopGrace = const Duration(seconds: 1)
      ..killAfter = const Duration(seconds: 1);
    return c;
  }

  Future<Map<String, dynamic>> run(CoreService c, String app, String kind, [Map<String, dynamic> options = const {}]) async {
    final j = await c.call('jobs.start', {'app': app, 'kind': kind, 'options': options});
    return c.jobs.done(j['id'] as String)!;
  }

  String log(Map<String, dynamic> job) => File(job['log'] as String).readAsStringSync();
  Map<String, dynamic> receipt(String id) => jsonDecode(File(p.join(w.paths.receipts, '$id.json')).readAsStringSync());
  String installedVersion() => File(t('pacman.state')).existsSync() ? File(t('pacman.state')).readAsStringSync().trim() : '';

  /// Maprisma 0.13.1-9 installed (as the AUR package left it), its provider service on.
  void installedOld() {
    final stage = p.join(w.dir, 'old');
    stageArchive(stage, '0.13.1');
    final top = p.join(stage, 'maprisma-0.13.1');
    Directory(sys('/usr/lib/maprisma')).createSync(recursive: true);
    Process.runSync('/usr/bin/cp', ['-a', '$top/app/.', sys('/usr/lib/maprisma')]);
    Directory(sys('/usr/bin')).createSync(recursive: true);
    Link(sys('/usr/bin/maprisma')).createSync(sys('/usr/lib/maprisma/maprisma'));
    for (final f in ['share/applications/com.maprisma.Maprisma.desktop', 'share/metainfo/com.maprisma.Maprisma.metainfo.xml', 'share/icons/hicolor/scalable/apps/com.maprisma.Maprisma.svg']) {
      w.writeFile(sys('/usr/$f'), File(p.join(top, f)).readAsStringSync());
    }
    w.writeFile(sys('/usr/share/licenses/maprisma-bin/LICENSE'), 'MIT\n');
    File(t('pacman.state')).writeAsStringSync('0.13.1-9\n');
    flag('unit-active');
    flag('unit-enabled');
  }

  group('recipe helpers', () {
    test('pkgrel: one above the installed one for the same version, else 1', () {
      expect(nextPkgrel('0.14.2-3', '0.14.2'), 4);
      expect(nextPkgrel('0.13.1-9', '0.14.2'), 1);
      expect(nextPkgrel('', '0.14.2'), 1);
      expect(nextPkgrel(null, '0.14.2'), 1);
      expect(nextPkgrel('1:0.14.2-2.1', '0.14.2'), 3);
      expect(packageBaseVersion('0.14.2-1'), '0.14.2');
    });

    test('the PKGBUILD: as aur-maprisma-bin, the one archive by file:// and its sha256; odd values refused', () {
      final text = maprismaPkgbuild(version: '0.14.2', pkgrel: 2, url: 'file:///home/u/.cache/x/maprisma-0.14.2-x86_64.tar.gz', sha256: 'a' * 64);
      expect(text, contains('pkgname=maprisma-bin\npkgver=0.14.2\npkgrel=2\n'));
      expect(text, contains('source=("maprisma-\$pkgver-x86_64.tar.gz::file:///home/u/.cache/x/maprisma-0.14.2-x86_64.tar.gz")'));
      expect(text, contains("sha256sums=('${'a' * 64}')"));
      expect(text, contains("provides=('maprisma')\nconflicts=('maprisma')"));
      expect(text, contains('ln -s /usr/lib/maprisma/maprisma "\$pkgdir/usr/bin/maprisma"'));
      expect(() => maprismaPkgbuild(version: '0.14.2; rm -rf /', pkgrel: 1, url: 'file:///x', sha256: 'a' * 64), throwsArgumentError);
      expect(() => maprismaPkgbuild(version: '0.14.2', pkgrel: 1, url: 'file:///a b"\$(x)', sha256: 'a' * 64), throwsArgumentError);
      expect(() => maprismaPkgbuild(version: '0.14.2', pkgrel: 1, url: 'https://x/y', sha256: 'a' * 64), throwsArgumentError);
    });

    test('pacman -Qip fields', () {
      final f = parsePacmanInfo('Name            : maprisma-bin\nVersion         : 0.14.2-1\nArchitecture    : x86_64\nDepends On      : gtk3  glib2\n');
      expect(f['Name'], 'maprisma-bin');
      expect(f['Version'], '0.14.2-1');
      expect(f['Architecture'], 'x86_64');
    });
  });

  group('maprisma (pacman)', () {
    test('update from the release over 0.13.1-9: service stopped before pkexec, started after; receipt; then up to date', () async {
      installedOld();
      final hash = makeRelease('0.14.2');
      final c = core();
      final job = await run(c, 'maprisma', 'update');
      expect(job['state'], 'succeeded', reason: log(job));
      expect(installedVersion(), '0.14.2-1');
      expect(jsonDecode(File(sys('/usr/lib/maprisma/data/flutter_assets/version.json')).readAsStringSync())['version'], '0.14.2');
      final text = calls();
      final stop = text.indexOf('systemctl --user stop maprisma-providers.service');
      final pk = text.indexOf('pkexec /usr/bin/pacman -U --noconfirm ');
      final start = text.indexOf('systemctl --user start maprisma-providers.service');
      expect(stop, greaterThan(0));
      expect(pk, greaterThan(stop));
      expect(start, greaterThan(pk));
      expect(File(t('unit-active')).existsSync(), isTrue);
      // the recipe: in the cache, for this archive
      final recipe = File(p.join(w.paths.cache, 'maprisma-manager/pkg/0.14.2/PKGBUILD')).readAsStringSync();
      expect(recipe, contains("sha256sums=('$hash')"));
      expect(recipe, contains('::file://${p.join(w.paths.cache, 'maprisma-manager/downloads/maprisma_maprisma/v0.14.2/maprisma-0.14.2-x86_64.tar.gz')}"'));
      expect(recipe, contains('pkgrel=1\n'));
      expect(text, contains('makepkg --nodeps --noconfirm --cleanbuild --force --noprogressbar'));
      final rec = receipt('maprisma');
      expect(rec['source'], {'kind': 'release', 'tag': 'v0.14.2', 'asset': 'maprisma-0.14.2-x86_64.tar.gz', 'sha256': hash, 'url': 'https://github.com/maprisma/maprisma/releases/tag/v0.14.2'});
      expect(rec['package']['version'], '0.14.2-1');
      expect(rec['package']['sha256'], sha256File(rec['package']['file'] as String));
      expect(rec['inputs'], isEmpty); // no maprisma folder here
      expect(rec['version'], '0.14.2');
      expect((job['result'] as Map)['before'], '0.13.1-9');
      expect(log(job), contains('source: release 0.14.2'));
      // status: installed, the receipt's version
      final a = appOf(await c.call('apps.list'), 'maprisma');
      expect(a['state'], 'installed');
      expect(a['versions']['installed'], '0.14.2-1');
      expect(a['build']['known'], isTrue);
      // nothing newer: no build, no pkexec
      File(t('calls.log')).writeAsStringSync('');
      final again = await run(c, 'maprisma', 'update');
      expect(again['state'], 'succeeded');
      expect(again['result']['up_to_date'], isTrue);
      expect(calls(), isNot(contains('makepkg')));
      expect(calls(), isNot(contains('pkexec')));
      // reinstall of the same version: the next pkgrel
      final re = await run(c, 'maprisma', 'reinstall');
      expect(re['state'], 'succeeded', reason: log(re));
      expect(installedVersion(), '0.14.2-2');
    });

    test('authentication cancelled: nothing changed, no repair, the service runs again', () async {
      installedOld();
      makeRelease('0.14.2');
      flag('pkexec-cancel');
      final job = await run(core(), 'maprisma', 'update');
      expect(job['state'], 'failed');
      expect(job['result']['code'], 'auth_cancelled');
      expect(job['result']['repair'], isFalse);
      expect(installedVersion(), '0.13.1-9');
      expect(File(t('unit-active')).existsSync(), isTrue);
      expect(calls(), contains('systemctl --user start maprisma-providers.service'));
      expect(File(p.join(w.paths.receipts, 'maprisma.json')).existsSync(), isFalse);
    });

    test('a password dialog never answered: pkexec ended after the wait (never pacman)', () async {
      installedOld();
      makeRelease('0.14.2');
      flag('pkexec-hang');
      final c = core();
      c.jobs.pkexecWait = const Duration(seconds: 1);
      final job = await run(c, 'maprisma', 'update');
      expect(job['state'], 'failed');
      expect(job['result']['code'], 'auth_timeout', reason: log(job));
      expect(installedVersion(), '0.13.1-9');
      expect(log(job), contains('pkexec ended'));
    });

    test('a held pacman lock: reported before anything stops; pacman\'s own lock error after the commit', () async {
      installedOld();
      makeRelease('0.14.2');
      w.writeFile(sys('/var/lib/pacman/db.lck'), '');
      final c = core();
      var job = await run(c, 'maprisma', 'update');
      expect(job['result']['code'], 'pacman_locked');
      expect(job['result']['repair'], isFalse);
      expect(calls(), isNot(contains('pkexec')));
      expect(calls(), isNot(contains('systemctl --user stop')));
      File(sys('/var/lib/pacman/db.lck')).deleteSync();
      flag('pacman-dblock');
      job = await run(c, 'maprisma', 'update');
      expect(job['result']['code'], 'pacman_locked', reason: log(job));
      expect(job['result']['repair'], isFalse);
      expect(File(t('unit-active')).existsSync(), isTrue);
      flag('pacman-dblock', false);
      flag('pacman-fail');
      job = await run(c, 'maprisma', 'update');
      expect(job['result']['code'], 'pacman_failed');
      expect(installedVersion(), '0.13.1-9');
    });

    test('the folder build when it is newer; the signed add-ons must exist; source can be chosen', () async {
      installedOld();
      makeRelease('0.14.2');
      final repo = w.repo('maprisma');
      w.writeFile(p.join(repo, 'addons.py'), 'MAPRISMA_VERSION = "0.15.0"\n');
      w.writeFile(p.join(repo, 'tools/build-release.py'), _fakeBuildRelease, mode: '755');
      stageArchive(p.join(repo, 'stage'), '0.15.0');
      w.git(repo, ['add', '.']);
      w.git(repo, ['commit', '-q', '-m', 'build']);
      final addons = w.repo('maprisma-addons');
      final c = core();
      var job = await run(c, 'maprisma', 'install');
      expect(job['result']['code'], 'missing_addons', reason: log(job));
      expect(log(job), contains('the folder (0.15.0) is newer than the release (0.14.2)'));
      w.writeFile(p.join(addons, 'dist/adapters-0.15.0.zip'), 'zip');
      job = await run(c, 'maprisma', 'install');
      expect(job['state'], 'succeeded', reason: log(job));
      expect(installedVersion(), '0.15.0-1');
      final rec = receipt('maprisma');
      expect(rec['source']['kind'], 'folder');
      expect(rec['source']['archive']['sha256'], sha256File(p.join(repo, 'dist/maprisma-0.15.0-x86_64.tar.gz')));
      expect([for (final i in rec['inputs'] as List) i['repo']], ['maprisma', 'maprisma-addons']);
      expect(rec['inputs'][0]['commit'], w.head('maprisma'));
      // the release asked for: older, installed anyway (an install, not an update)
      job = await run(c, 'maprisma', 'install', {'source': 'release'});
      expect(job['state'], 'succeeded', reason: log(job));
      expect(installedVersion(), '0.14.2-1');
      // a release job is the same as source: release
      job = await run(c, 'maprisma', 'release');
      expect(job['state'], 'succeeded', reason: log(job));
      expect(installedVersion(), '0.14.2-2');
    });

    test('remove: the plan, the service stopped and disabled, pkexec pacman -R, settings only when asked', () async {
      installedOld();
      w.writeFile(p.join(w.paths.config, 'maprisma/settings.json'), '{}');
      final c = core();
      final plan = await c.call('apps.remove_plan', {'id': 'maprisma', 'delete_settings': true});
      expect(plan['goes'], [{'path': 'maprisma-bin', 'kind': 'package', 'version': '0.13.1-9', 'note': 'pacman removes every file of the package'}]);
      expect([for (final s in plan['steps'] as List) s['commands']].expand((x) => x as List),
          containsAll(['systemctl --user disable maprisma-providers.service', 'pkexec /usr/bin/pacman -R --noconfirm maprisma-bin']));
      expect([for (final d in plan['data'] as List) if (d['goes'] == true) d['path']], [p.join(w.paths.config, 'maprisma')]);
      flag('pkexec-cancel');
      var job = await run(c, 'maprisma', 'remove', {'delete_settings': true, 'revision': plan['revision']});
      expect(job['result']['code'], 'auth_cancelled');
      expect(installedVersion(), '0.13.1-9');
      expect(File(t('unit-enabled')).existsSync(), isTrue); // enabled again
      expect(File(t('unit-active')).existsSync(), isTrue);
      expect(Directory(p.join(w.paths.config, 'maprisma')).existsSync(), isTrue);
      flag('pkexec-cancel', false);
      job = await run(c, 'maprisma', 'remove', {'delete_settings': true, 'revision': plan['revision']});
      expect(job['state'], 'succeeded', reason: log(job));
      expect(installedVersion(), '');
      expect(File(t('unit-enabled')).existsSync(), isFalse);
      expect(File(t('unit-active')).existsSync(), isFalse);
      expect(calls(), contains('pkexec /usr/bin/pacman -R --noconfirm maprisma-bin'));
      expect(Directory(p.join(w.paths.config, 'maprisma')).existsSync(), isFalse);
      expect(File(sys('/usr/lib/maprisma/maprisma')).existsSync(), isFalse);
      final after = await c.call('apps.remove_plan', {'id': 'maprisma'});
      expect(after['blocked'], contains('not installed'));
    });

    test('never the system pkexec with a test root', () async {
      installedOld();
      makeRelease('0.14.2');
      File(p.join(w.fakeBin, 'pkexec')).deleteSync();
      final job = await run(core(), 'maprisma', 'update');
      expect(job['state'], 'failed');
      // /usr/bin/pkexec (if installed) is refused; without one it is missing
      expect(job['result']['code'], anyOf('unsafe', 'missing_prerequisite'));
      expect(installedVersion(), '0.13.1-9');
    });
  });

  group('bar icons', () {
    const icon = 'io.github.ubruckhaus.CosmicMaprismaWlanMonitor-symbolic';
    String iconFile() => p.join(w.paths.icons, '$icon.svg');

    /// A theme like COSMIC's: Cosmic inherits Pop and hicolor.
    void themes() {
      w.writeFile(sys('/usr/share/icons/Cosmic/index.theme'), '[Icon Theme]\nName=COSMIC\nInherits=Pop,hicolor\n');
      w.writeFile(sys('/usr/share/icons/Cosmic/scalable/devices/audio-headphones-symbolic.svg'), _svgA);
      w.writeFile(sys('/usr/share/icons/Pop/index.theme'), '[Icon Theme]\nName=Pop\n');
      w.writeFile(sys('/usr/share/icons/Pop/scalable/actions/media-view-subtitles-symbolic.svg'), _svgA.replaceAll('14v14', '12v12'));
      w.writeFile(sys('/usr/share/icons/Pop/scalable/devices/audio-headphones-symbolic.svg'), '<svg xmlns="http://www.w3.org/2000/svg"/>');
      w.writeFile(sys('/usr/share/icons/Pop/scalable/apps/evil-symbolic.svg'), '<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>');
      w.writeFile(sys('/usr/share/icons/Pop/scalable/apps/plain.svg'), _svgA);
    }

    void installWlan() {
      w.install('wlan');
      w.writeFile(iconFile(), '<svg xmlns="http://www.w3.org/2000/svg"><circle r="1"/></svg>\n');
    }

    test('svgProblem: SVG only, no scripts, handlers, outside references, entities; at most 256 KiB', () {
      List<int> b(String s) => utf8.encode(s);
      expect(svgProblem(b(_svgA)), isNull);
      expect(svgProblem(b('<svg xmlns="http://www.w3.org/2000/svg"><defs><style>.a{fill:url(#g)}</style></defs><use href="#a"/></svg>')), isNull);
      expect(svgProblem(b('<svg xmlns="http://www.w3.org/2000/svg"><script>x</script></svg>')), contains('<script>'));
      expect(svgProblem(b('<svg xmlns="http://www.w3.org/2000/svg" onload="x()"/>')), contains('event handler'));
      expect(svgProblem(b('<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink"><use xlink:href="http://x/y#a"/></svg>')), contains('links outside'));
      expect(svgProblem(b('<svg xmlns="http://www.w3.org/2000/svg"><path style="fill:url(http://x/p)"/></svg>')), contains('outside the file'));
      expect(svgProblem(b('<svg xmlns="http://www.w3.org/2000/svg"><style>@import "x.css";</style></svg>')), contains('@import'));
      expect(svgProblem(b('<svg xmlns="http://www.w3.org/2000/svg"><foreignObject/></svg>')), contains('foreignObject'));
      expect(svgProblem(b('<svg xmlns="http://www.w3.org/2000/svg"><image href="data:image/png;base64,AA"/></svg>')), isNotNull);
      expect(svgProblem(b('<!DOCTYPE svg [<!ENTITY x "y">]><svg xmlns="http://www.w3.org/2000/svg"/>')), contains('DOCTYPE'));
      expect(svgProblem(b('<?xml-stylesheet href="x.css"?><svg xmlns="http://www.w3.org/2000/svg"/>')), contains('processing instruction'));
      expect(svgProblem(b('<html xmlns="http://www.w3.org/1999/xhtml"/>')), contains('not an SVG'));
      expect(svgProblem(b('<svg/>')), contains('not an SVG'));
      expect(svgProblem(b('<svg xmlns="http://www.w3.org/2000/svg">')), contains('not well-formed'));
      expect(svgProblem([0xff, 0xfe]), contains('UTF-8'));
      expect(svgProblem(List.filled(maxIconBytes + 1, 32)), contains('larger'));
    });

    test('icons.get: the file, choices from the current theme chain (searchable, bounded); not changeable apps say why', () async {
      themes();
      installWlan();
      final c = core();
      final g = await c.call('icons.get', {'app': 'wlan'});
      expect(g['changeable'], isTrue);
      expect(g['file'], iconFile());
      expect(g['current'], 'original');
      expect(g['shows'], {'cosmic': false, 'kde': true}); // the COSMIC applet draws its built-in radar
      expect(g['theme']['name'], 'Cosmic');
      expect(g['theme']['chain'], ['Cosmic', 'Pop', 'hicolor']);
      final names = [for (final ch in g['choices'] as List) ch['name']];
      expect(names, containsAll(['audio-headphones-symbolic', 'media-view-subtitles-symbolic']));
      expect(names, isNot(contains('plain')));
      // the first theme with a name wins
      expect((g['choices'] as List).firstWhere((ch) => ch['name'] == 'audio-headphones-symbolic')['theme'], 'Cosmic');
      final q = await c.call('icons.get', {'app': 'wlan', 'query': 'SUBTITLES', 'limit': 5});
      expect([for (final ch in q['choices'] as List) ch['name']], ['media-view-subtitles-symbolic']);
      final one = await c.call('icons.get', {'app': 'wlan', 'limit': 1});
      expect(one['truncated'], isTrue);
      expect((one['choices'] as List).length, 1);
      final l = await c.call('icons.get', {'app': 'launcher'});
      expect(l['changeable'], isFalse);
      expect(l['why'], contains('not a name of its own'));
      await expectLater(c.call('icons.set', {'app': 'launcher', 'icon': 'audio-headphones-symbolic'}),
          throwsA(isA<RouteError>().having((e) => e.code, 'code', 'unavailable')));
      expect((await c.call('icons.get', {'app': 'maprisma'}))['changeable'], isFalse);
      // the three apps with an own name since 5b
      for (final id in ['control', 'narrator', 'video']) {
        expect(findApp(id)!.bar.iconName, startsWith('io.github.ubruckhaus.CosmicMaprisma'));
        expect(c.icons.whyNot(findApp(id)!), isNull, reason: id);
      }
    });

    test('icons.set by name and by file, reset gives the original byte for byte; unsafe or missing icons refused', () async {
      themes();
      installWlan();
      final original = File(iconFile()).readAsBytesSync();
      final c = core();
      final set = await c.call('icons.set', {'app': 'wlan', 'icon': 'media-view-subtitles-symbolic'});
      expect(set['choice']['kind'], 'name');
      expect(set['choice']['theme'], 'Pop');
      expect(File(iconFile()).readAsStringSync(), _svgA.replaceAll('14v14', '12v12'));
      final kept = p.join(w.paths.managerState, 'icons/wlan/original.svg');
      expect(File(kept).readAsBytesSync(), original);
      expect(set['iconCache'], 'updated');
      expect((await c.call('icons.get', {'app': 'wlan'}))['current'], 'changed');
      // another one: the original stays the installer's
      final mine = p.join(w.dir, 'mine.svg');
      w.writeFile(mine, _svgA);
      await c.call('icons.set', {'app': 'wlan', 'icon': mine});
      expect(File(iconFile()).readAsStringSync(), _svgA);
      expect(File(kept).readAsBytesSync(), original);
      // refused: a script, too big, not there, not a name
      await expectLater(c.call('icons.set', {'app': 'wlan', 'icon': 'evil-symbolic'}), throwsA(isA<RouteError>().having((e) => e.code, 'code', 'bad_icon')));
      final big = p.join(w.dir, 'big.svg');
      w.writeFile(big, '<svg xmlns="http://www.w3.org/2000/svg"><!--${'x' * maxIconBytes}--></svg>');
      await expectLater(c.call('icons.set', {'app': 'wlan', 'icon': big}), throwsA(isA<RouteError>().having((e) => e.code, 'code', 'bad_icon')));
      await expectLater(c.call('icons.set', {'app': 'wlan', 'icon': 'no-such-symbolic'}), throwsA(isA<RouteError>().having((e) => e.code, 'code', 'not_found')));
      await expectLater(c.call('icons.set', {'app': 'wlan', 'icon': '../x'}), throwsA(isA<RouteError>().having((e) => e.code, 'code', 'bad_params')));
      expect(File(iconFile()).readAsStringSync(), _svgA);
      final reset = await c.call('icons.reset', {'app': 'wlan'});
      expect(reset['reset'], isTrue);
      expect(File(iconFile()).readAsBytesSync(), original);
      expect(Directory(p.join(w.paths.managerState, 'icons/wlan')).existsSync(), isFalse);
      expect((await c.call('icons.reset', {'app': 'wlan'}))['reset'], isFalse);
      expect((await c.call('icons.get', {'app': 'wlan'}))['current'], 'original');
    });

    test('COSMIC: the applet is brought back by its panel file (written without it and back, byte for byte)', () async {
      themes();
      installWlan();
      final panel = p.join(w.paths.config, 'cosmic/com.system76.CosmicPanel.Panel/v1');
      const center = 'Some([\n    "com.system76.CosmicAppletTime",\n    "io.github.ubruckhaus.CosmicMaprismaWlanMonitor",\n])';
      w.writeFile(p.join(panel, 'plugins_wings'), 'Some(([\n    "com.system76.CosmicAppletWorkspaces",\n], [\n    "com.system76.CosmicAppletPower",\n]))');
      w.writeFile(p.join(panel, 'plugins_center'), center);
      final c = core();
      final set = await c.call('icons.set', {'app': 'wlan', 'icon': 'audio-headphones-symbolic'});
      expect(set['bar']['panel']['panel'], 'Panel', reason: '$set');
      expect(followed.length, 2); // written without it, then back
      expect(File(p.join(panel, 'plugins_center')).readAsStringSync(), center);
      expect(set['bar']['note'], contains('built-in'));
      await c.call('icons.reset', {'app': 'wlan'});
      expect(File(p.join(panel, 'plugins_center')).readAsStringSync(), center);
    });

    test('the choice is written again after an install of the app; the receipt follows a change', () async {
      themes();
      catalogOverride = [
        ...builtinCatalog,
        const AppEntry(
          id: 'iconfake',
          name: 'Icon Fake',
          kind: 'test',
          inputs: [Input('mm-iconfake')],
          components: [
            Component(id: 'main', name: 'Icon Fake', repo: 'mm-iconfake', install: ['./install.sh'], paths: [
              InstalledPath('{bin}/mm-iconfake', PathKind.executable, key: true),
              InstalledPath('{icons}/io.github.ubruckhaus.CosmicMaprismaIconFake-symbolic.svg', PathKind.file),
            ]),
          ],
          bar: BarIcon(kdeId: 'mm-iconfake', iconName: 'io.github.ubruckhaus.CosmicMaprismaIconFake-symbolic'),
          postSteps: ['gtk-update-icon-cache'],
        ),
      ];
      addTearDown(() => catalogOverride = null);
      final repo = w.repo('mm-iconfake');
      w.writeFile(p.join(repo, 'install.sh'), r'''#!/bin/sh
set -eu
d="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/scalable/apps"
mkdir -p "$HOME/.local/bin" "$d"
printf '#!/bin/sh\n' > "$HOME/.local/bin/mm-iconfake"; chmod 755 "$HOME/.local/bin/mm-iconfake"
printf '<svg xmlns="http://www.w3.org/2000/svg"><rect width="1" height="1"/></svg>\n' > "$d/io.github.ubruckhaus.CosmicMaprismaIconFake-symbolic.svg"
''', mode: '755');
      w.git(repo, ['add', '.']);
      w.git(repo, ['commit', '-q', '-m', 'x']);
      final c = core();
      expect((await run(c, 'iconfake', 'install'))['state'], 'succeeded');
      final file = p.join(w.paths.icons, 'io.github.ubruckhaus.CosmicMaprismaIconFake-symbolic.svg');
      final original = File(file).readAsBytesSync();
      await c.call('icons.set', {'app': 'iconfake', 'icon': 'audio-headphones-symbolic'});
      final chosen = File(file).readAsBytesSync();
      final entry = (receipt('iconfake')['paths'] as List).firstWhere((e) => e['path'] == file);
      expect(entry['sha256'], sha256Bytes(chosen));
      final job = await run(c, 'iconfake', 'reinstall');
      expect(job['state'], 'succeeded', reason: log(job));
      expect(log(job), contains('written over the installer'));
      expect(File(file).readAsBytesSync(), chosen);
      expect(File(p.join(w.paths.managerState, 'icons/iconfake/original.svg')).readAsBytesSync(), original);
      // the remove plan takes the chosen file as the app's (the receipt has it)
      final plan = await c.call('apps.remove_plan', {'id': 'iconfake'});
      expect([for (final g in plan['goes'] as List) g['path']], contains(file));
      await c.call('icons.reset', {'app': 'iconfake'});
      expect(File(file).readAsBytesSync(), original);
      expect((receipt('iconfake')['paths'] as List).firstWhere((e) => e['path'] == file)['sha256'], sha256Bytes(original));
    });

    test('CLI: icon <id>, icon <id> <name>, icon <id> --reset', () async {
      themes();
      installWlan();
      final original = File(iconFile()).readAsBytesSync();
      final c = core();
      Future<String> cli(List<String> args) async {
        final out = _Sink();
        final code = await runCli(args, service: c, out: out);
        expect(code, 0, reason: out.text);
        return out.text;
      }

      expect(await cli(['icon', 'wlan', '--search', 'headphones']), contains('audio-headphones-symbolic  (Cosmic)'));
      expect(await cli(['icon', 'wlan', 'audio-headphones-symbolic']), contains('is now audio-headphones-symbolic'));
      expect(await cli(['icon', 'wlan', '--reset']), contains('the original icon is back'));
      expect(File(iconFile()).readAsBytesSync(), original);
    });
  });
}

final class _Sink implements IOSink {
  final _b = StringBuffer();
  String get text => '$_b';
  @override
  Encoding encoding = utf8;
  @override
  void write(Object? obj) => _b.write(obj);
  @override
  void writeln([Object? obj = '']) => _b.writeln(obj);
  @override
  void writeAll(Iterable objects, [String sep = '']) => _b.writeAll(objects, sep);
  @override
  void writeCharCode(int c) => _b.writeCharCode(c);
  @override
  void add(List<int> data) => _b.write(utf8.decode(data));
  @override
  void addError(Object error, [StackTrace? stackTrace]) {}
  @override
  Future addStream(Stream<List<int>> stream) async {}
  @override
  Future close() async {}
  @override
  Future get done async {}
  @override
  Future flush() async {}
}
