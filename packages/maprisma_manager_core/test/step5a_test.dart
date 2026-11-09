// Step 5a against the real catalog entries with fake repos: whole-tree ownership (Launcher,
// Theme, Narrator, Video Translator), the Launcher's two components in order and its refusal
// while its terminal is busy, Narrator's and Video's runtime things kept, and the KDE apps'
// remove steps (Tiling, Icons) with fake KDE tools. Everything runs in a temp HOME; PATH has only
// fakes and a few links to real tools (no cmake, no qdbus6, no cosmic-panel); the real /proc is
// read for the scripts' own process groups only; the panel follow-up is replaced.
import 'dart:convert';
import 'dart:io';

import 'package:maprisma_manager_core/maprisma_manager_core.dart';
import 'package:maprisma_manager_core/src/kde_remove.dart';
import 'package:maprisma_manager_core/src/trees.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

/// Real tools the fake installers use (linked into a folder of their own: PATH has nothing else).
const _tools = [
  'sh', 'bash', 'cp', 'mv', 'rm', 'mkdir', 'chmod', 'ln', 'cat', 'sleep', 'setsid', 'find', 'head', 'tr', 'grep',
  'sed', 'mktemp', 'readlink', 'ls', 'touch', 'env', 'dirname', 'basename', 'true', 'false', 'printf', 'tar', 'gzip',
  'python3', 'rmdir', 'echo', 'test',
];

const _launcherInstall = r'''#!/bin/sh
set -eu
ctl="$HOME/.mm-test"
force=0
for a in "$@"; do [ "$a" = --force ] && force=1; done
echo "args: $*" >> "$ctl/order.log"
if [ -e "$ctl/busy" ] && [ $force = 0 ]; then
  echo "Maprisma Launcher is running a command in its terminal:" >&2
  echo "  4711: pacman -Syu" >&2
  echo "Let it finish (or close it), then run this again; --force ends it." >&2
  exit 1
fi
lib="$HOME/.local/lib/maprisma-launcher"
mkdir -p "$HOME/.local/lib" "$HOME/.local/bin"
new=$(mktemp -d "$lib.new.XXXXXX")
mkdir -p "$new/lib" "$new/data/flutter_assets/fonts"
printf '#!/bin/sh\nexit 0\n' > "$new/maprisma-launcher"
chmod 755 "$new/maprisma-launcher"
cp "$new/maprisma-launcher" "$new/maprisma-launcher-windows"
echo lib > "$new/lib/libapp.so"
echo flutter > "$new/lib/libflutter_linux_gtk.so"
echo '{"version":"0.1.4"}' > "$new/data/flutter_assets/version.json"
echo font > "$new/data/flutter_assets/fonts/MaterialIcons.otf"
echo "build $(cat "$ctl/build" 2>/dev/null || echo 1)" > "$new/data/icudtl.dat"
chmod 755 "$new"
old=""
if [ -e "$lib" ]; then old=$(mktemp -d "$lib.old.XXXXXX"); rmdir "$old"; mv "$lib" "$old"; fi
mv "$new" "$lib"
if [ -n "$old" ]; then rm -rf "$old"; fi
ln -sfn "$lib/maprisma-launcher" "$HOME/.local/bin/maprisma-launcher"
apps="$HOME/.local/share/applications"
mkdir -p "$apps" "$HOME/.local/share/icons/hicolor/scalable/apps"
printf '[Desktop Entry]\nName=Launcher\n' > "$apps/com.maprisma.Launcher.desktop"
printf '[Desktop Entry]\nName=Launcher toggle\n' > "$apps/com.maprisma.Launcher.Toggle.desktop"
echo '<svg/>' > "$HOME/.local/share/icons/hicolor/scalable/apps/com.maprisma.Launcher.svg"
echo installed
''';

const _appletInstall = r'''#!/bin/sh
set -eu
echo "applet" >> "$HOME/.mm-test/order.log"
bin="$HOME/.local/bin"
apps="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
mkdir -p "$bin" "$apps"
printf '#!/bin/sh\nexit 0\n' > "$bin/.applet.tmp"
chmod 755 "$bin/.applet.tmp"
mv -f "$bin/.applet.tmp" "$bin/maprisma-launcher-applet"
printf '[Desktop Entry]\nExec=%s\n' "$bin/maprisma-launcher-applet" > "$apps/io.github.ubruckhaus.CosmicMaprismaLauncher.desktop"
''';

const _themeInstall = r'''#!/bin/sh
set -eu
echo "FLUTTER=${FLUTTER:-}"
lib="$HOME/.local/lib/maprisma-theme"
bin="$HOME/.local/bin"
data="${XDG_DATA_HOME:-$HOME/.local/share}"
mkdir -p "$HOME/.local/lib" "$bin" "$data/applications" "$data/icons/hicolor/scalable/apps" "$HOME/.config/autostart"
new=$(mktemp -d "$lib.new.XXXXXX")
mkdir -p "$new/bin" "$new/lib" "$new/share/maprisma-theme/themes/nord" "$new/share/maprisma-theme/templates" "$new/data/flutter_assets"
for f in maprisma-theme bin/maprisma-theme-core bin/maprisma-theme-helper bin/maprisma-theme-applet; do printf '#!/bin/sh\n' > "$new/$f"; chmod 755 "$new/$f"; done
echo so > "$new/lib/libapp.so"
echo nord > "$new/share/maprisma-theme/themes/nord/colors.toml"
echo '{"version":"0.1.0"}' > "$new/data/flutter_assets/version.json"
chmod 755 "$new"
old=""
if [ -e "$lib" ]; then old=$(mktemp -d "$lib.old.XXXXXX"); rmdir "$old"; mv "$lib" "$old"; fi
mv "$new" "$lib"
if [ -n "$old" ]; then rm -rf "$old"; fi
ln -sfn "$lib/maprisma-theme" "$bin/maprisma-theme"
for b in maprisma-theme-core maprisma-theme-helper maprisma-theme-applet; do ln -sfn "$lib/bin/$b" "$bin/$b"; done
for f in com.maprisma.Theme.desktop com.maprisma.Theme.Toggle.desktop io.github.ubruckhaus.CosmicMaprismaTheme.desktop; do printf '[Desktop Entry]\nName=%s\n' "$f" > "$data/applications/$f"; done
echo '<svg/>' > "$data/icons/hicolor/scalable/apps/com.maprisma.Theme.svg"
echo '<svg/>' > "$data/icons/hicolor/scalable/apps/io.github.ubruckhaus.CosmicMaprismaTheme-symbolic.svg"
printf '[Desktop Entry]\nExec=x daemon\n' > "$HOME/.config/autostart/com.maprisma.Theme.Daemon.desktop"
''';

/// Narrator and Video Translator: binaries, a backend copied to `<backend>.new` and renamed,
/// the Flutter bundle only with cmake and ninja (else "skipped"), desktop entries.
String _rustFlutterInstall({required String name, required List<String> bins, required String window, required String windowLink, required List<String> entries, required String autostart, String extra = ''}) => '''#!/bin/sh
set -eu
data="\${XDG_DATA_HOME:-\$HOME/.local/share}"
bin="\$HOME/.local/bin"
mkdir -p "\$bin" "\$data/applications" "\$HOME/.config/autostart" "\$data/$name"
for b in ${bins.join(' ')}; do printf '#!/bin/sh\\n' > "\$bin/.tmp"; chmod 755 "\$bin/.tmp"; mv -f "\$bin/.tmp" "\$bin/\$b"; done
rm -rf "\$data/$name/backend.new"
cp -r backend "\$data/$name/backend.new"
rm -rf "\$data/$name/backend"
mv "\$data/$name/backend.new" "\$data/$name/backend"
if command -v cmake >/dev/null && command -v ninja >/dev/null; then
  rm -rf "\$data/$name/$window"
  mkdir -p "\$data/$name/$window/lib"
  printf '#!/bin/sh\\n' > "\$data/$name/$window/$name"
  chmod 755 "\$data/$name/$window/$name"
  echo so > "\$data/$name/$window/lib/libapp.so"
  ln -sf "\$data/$name/$window/$name" "\$bin/$windowLink"
  printf '[Desktop Entry]\\n' > "\$data/applications/${entries.first}"
else
  echo "window skipped: needs cmake and ninja" >&2
fi
for e in ${entries.skip(1).join(' ')}; do printf '[Desktop Entry]\\nName=%s\\n' "\$e" > "\$data/applications/\$e"; done
printf '[Desktop Entry]\\nName=tray\\n' > "\$HOME/.config/autostart/$autostart"
$extra
''';

/// The bar icon an installer writes (its own name since step 5b).
String _iconLine(String name) => 'mkdir -p "\$data/icons/hicolor/scalable/apps"; printf \'<svg xmlns="http://www.w3.org/2000/svg"/>\\n\' > "\$data/icons/hicolor/scalable/apps/$name.svg"';

const _tilingInstall = r'''#!/bin/sh
set -eu
data="${XDG_DATA_HOME:-$HOME/.local/share}"
for s in omarchy-navigation maprisma-tiling; do
  kpackagetool6 -t KWin/Script -u "$s" >/dev/null 2>&1 || kpackagetool6 -t KWin/Script -i "$s"
done
mkdir -p "$HOME/.local/bin" "$data/dbus-1/services" "$data/maprisma-tiling"
cp tools/tiling-shortcuts "$HOME/.local/bin/maprisma-tiling-shortcuts"
chmod 755 "$HOME/.local/bin/maprisma-tiling-shortcuts"
printf '#!/bin/sh\n' > "$HOME/.local/bin/maprisma-tiling-overlay"
chmod 755 "$HOME/.local/bin/maprisma-tiling-overlay"
printf '[D-BUS Service]\nName=org.maprisma.TilingOverlay\n' > "$data/dbus-1/services/org.maprisma.TilingOverlay.service"
kwriteconfig6 --file kwinrc --group Script-maprisma-tiling --key build abc123
kwriteconfig6 --file kwinrc --group Plugins --key omarchy-navigationEnabled true
kwriteconfig6 --file kwinrc --group Plugins --key maprisma-tilingEnabled true
if [ -d "$data/kwin/scripts/krohnkite" ]; then
  tar -czf "$data/maprisma-tiling/krohnkite-backup.tar.gz" -C "$data/kwin/scripts" krohnkite
  kpackagetool6 -t KWin/Script -r krohnkite
  kwriteconfig6 --file kwinrc --group Plugins --key krohnkiteEnabled --delete
fi
''';

const _iconsInstall = r'''#!/bin/sh
set -eu
if kpackagetool6 -t Plasma/Applet -s com.maprisma.panel >/dev/null 2>&1; then
  kpackagetool6 -t Plasma/Applet -u package
else
  kpackagetool6 -t Plasma/Applet -i package
fi
mkdir -p "$HOME/.local/bin"
cp tools/maprisma-panel-color "$HOME/.local/bin/maprisma-panel-color"
chmod 755 "$HOME/.local/bin/maprisma-panel-color"
''';

/// kpackagetool6: -i/-u copies the package (id from its metadata.json), -r deletes it, -s tells.
const _kpackagetool = r'''#!/bin/sh
echo "kpackagetool6 $*" >> "$HOME/.mm-test/order.log"
data="${XDG_DATA_HOME:-$HOME/.local/share}"
case "$2" in KWin/Script) dir="$data/kwin/scripts" ;; *) dir="$data/plasma/plasmoids" ;; esac
case "$3" in
  -i|-u)
    id=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["KPlugin"]["Id"])' "$4/metadata.json")
    rm -rf "$dir/$id"; mkdir -p "$dir"; cp -r "$4" "$dir/$id" ;;
  -r) [ -d "$dir/$4" ] || exit 1; rm -rf "$dir/$4" ;;
  -s) [ -d "$dir/$4" ] ;;
esac
''';

/// kwriteconfig6 --file F --group G --key K (V | --delete), editing $XDG_CONFIG_HOME/F in place.
const _kwriteconfig = r'''#!/usr/bin/python3 -I
import os, sys
a = sys.argv[1:]
with open(os.path.join(os.environ['HOME'], '.mm-test/order.log'), 'a') as log:
    log.write('kwriteconfig6 ' + ' '.join(a) + '\n')
f = os.path.join(os.environ.get('XDG_CONFIG_HOME') or os.path.join(os.environ['HOME'], '.config'), a[a.index('--file') + 1])
group, key = a[a.index('--group') + 1], a[a.index('--key') + 1]
delete = '--delete' in a
value = None if delete else a[-1]
lines = open(f).read().split('\n') if os.path.exists(f) else []
out, cur, done = [], None, False
for i, l in enumerate(lines):
    t = l.strip()
    if t.startswith('['):
        if cur == group and not done and not delete:
            out.append(key + '=' + value); done = True
        cur = t[1:-1]
    elif cur == group and t.split('=', 1)[0] == key:
        if not delete and not done:
            out.append(key + '=' + value); done = True
        continue
    out.append(l)
if not done and not delete:
    if cur != group:
        out.append('[' + group + ']')
    out.append(key + '=' + value)
os.makedirs(os.path.dirname(f), exist_ok=True)
open(f, 'w').write('\n'.join(out))
''';

void main() {
  late World w;
  late String ctl;
  late String sysbin;

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
    for (final f in ['cargo', 'flutter', 'dart', 'gtk-update-icon-cache', 'update-desktop-database', 'kreadconfig6']) {
      w.fake(f, 'exit 0');
    }
    w.fake('pacman', 'exit 1');
    w.fake('busctl', r'echo "busctl $*" >> "$HOME/.mm-test/order.log"');
    w.fake('systemctl', r'''echo "$*" >> "$HOME/.mm-test/systemctl.log"
case "$*" in *is-active*) [ -e "$HOME/.mm-test/unit-active" ] && exit 0; exit 3;; esac
exit 0''');
    final panel = p.join(w.paths.config, 'cosmic/com.system76.CosmicPanel.Panel/v1');
    w.writeFile(p.join(panel, 'plugins_wings'), 'Some(([\n    "com.system76.CosmicAppletWorkspaces",\n], [\n    "com.system76.CosmicAppletPower",\n]))');
    w.writeFile(p.join(panel, 'plugins_center'), 'Some([\n    "com.system76.CosmicAppletTime",\n])');
  });

  tearDown(() => w.dispose());

  Map<String, String> env({String desktop = 'COSMIC', Map<String, String> extra = const {}}) => w.env(desktop: desktop, extra: {
    'PATH': '${w.fakeBin}:$sysbin',
    'MAPRISMA_MANAGER_PROC': '/proc',
    'MAPRISMA_FLUTTER': p.join(w.fakeBin, 'flutter'),
    ...extra,
  });

  CoreService core({String desktop = 'COSMIC', Map<String, String> extra = const {}}) {
    // never the real panel: the follow-up and the panel restart are replaced
    final c = CoreService(environment: env(desktop: desktop, extra: extra), uid: currentUid())
      ..followPanel = (_) async => {'panel': null, 'note': 'test'};
    c.jobs
      ..appletWait = const Duration(milliseconds: 100)
      ..pollEvery = const Duration(milliseconds: 30)
      ..stopGrace = const Duration(seconds: 2)
      ..killAfter = const Duration(seconds: 2);
    return c;
  }

  Future<Map<String, dynamic>> run(CoreService c, String app, String kind, [Map<String, dynamic> options = const {}]) async {
    final j = await c.call('jobs.start', {'app': app, 'kind': kind, 'options': options});
    return c.jobs.done(j['id'] as String)!;
  }

  String log(Map<String, dynamic> job) => File(job['log'] as String).readAsStringSync();
  Map<String, dynamic> receipt(String app) => jsonDecode(File(p.join(w.paths.receipts, '$app.json')).readAsStringSync()) as Map<String, dynamic>;
  String home(String rel) => p.join(w.home, rel);
  bool exists(String path) => FileSystemEntity.typeSync(path, followLinks: false) != FileSystemEntityType.notFound;
  String orderLog() => File(p.join(ctl, 'order.log')).existsSync() ? File(p.join(ctl, 'order.log')).readAsStringSync() : '';
  List<Map<String, dynamic>> stays(Map<String, dynamic> plan) => (plan['stays'] as List).cast<Map<String, dynamic>>();
  Map<String, dynamic>? stayOf(Map<String, dynamic> plan, String path) => stays(plan).where((s) => s['path'] == path).firstOrNull;

  void launcherRepos() {
    final repo = w.repo('maprisma-launcher');
    w.writeFile(p.join(repo, 'tools/install-local'), _launcherInstall, mode: '755');
    w.git(repo, ['add', '.']);
    w.git(repo, ['commit', '-q', '-m', 'installer']);
    final applet = w.repo('maprisma-launcher-applet');
    w.writeFile(p.join(applet, 'install.sh'), _appletInstall, mode: '755');
    w.git(applet, ['add', '.']);
    w.git(applet, ['commit', '-q', '-m', 'installer']);
  }

  group('trees', () {
    test('a manifest lists every entry; changed, added and linked-away entries stay; caches of its own modules go', () {
      final root = home('.local/lib/t');
      w.writeFile(p.join(root, 'a'), 'a');
      w.writeFile(p.join(root, 'sub/b'), 'b', mode: '755');
      w.writeFile(p.join(root, 'sub/x.py'), 'x');
      Link(p.join(root, 'l')).createSync('a');
      final m = treeManifest(root)!;
      expect(m['files'], 3);
      expect(m['links'], 1);
      expect(m['dirs'], 1);
      validateTree(m);
      expect(() => validateTree({...m, 'digest': 'x'}), throwsFormatException);
      expect(() => validateTree({...m, 'entries': [{'p': '../x', 'sha256': '0' * 64}]}), throwsFormatException);
      expect(treeManifest(root, max: 2)!['overflow'], isTrue);

      w.writeFile(p.join(root, 'sub/b'), 'changed');
      w.writeFile(p.join(root, 'mine.txt'), 'user');
      w.writeFile(p.join(root, 'sub/__pycache__/x.cpython-314.pyc'), 'pyc');
      w.writeFile(p.join(root, 'sub/__pycache__/other.cpython-314.pyc'), 'pyc of a module that isn\'t ours');
      Directory(p.join(root, 'empty-of-mine')).createSync();
      Link(p.join(root, 'l')).deleteSync();
      Link(p.join(root, 'l')).createSync('/etc/passwd');
      final c = checkTree(root, (m['entries'] as List).cast<Map<String, dynamic>>(), foreignWhy: (_) => 'foreign');
      expect(c.goes.map((g) => p.relative(g.path, from: root)), unorderedEquals(['a', 'sub/x.py', 'sub/__pycache__/x.cpython-314.pyc']));
      expect(c.derived, 1);
      expect({for (final s in c.stays) p.relative(s['path'] as String, from: root): s['why']}, {
        'l': 'the link points elsewhere now',
        'mine.txt': 'foreign',
        'sub/b': 'changed since the Manager installed it',
        'sub/__pycache__/other.cpython-314.pyc': 'foreign',
      });
      expect(c.whole, isFalse);
      // only the manifest's folders (and caches' folders) are removed when empty: not one of the user's
      expect(c.dirs.map((d) => p.relative(d, from: root)), ['sub/__pycache__', 'sub', '.']);
    });

    test('swap leftovers: only <name>.new.XXXXXX / .old.XXXXXX (and <name>.new when staged)', () {
      final root = home('.local/lib/app');
      for (final n in ['app.new.Ab12Cd', 'app.old.zzzzzz', 'app.new', 'app.newer', 'app.old.toolong1', 'other.new.Ab12Cd']) {
        Directory(home('.local/lib/$n')).createSync(recursive: true);
      }
      expect(swapLeftovers(root).map(p.basename), ['app.new.Ab12Cd', 'app.old.zzzzzz']);
      expect(swapLeftovers(root, swap: false, staged: true).map(p.basename), ['app.new']);
    });
  });

  group('launcher', () {
    test('install: the bundle first, then the applet; the receipt owns the whole bundle', () async {
      launcherRepos();
      final c = core();
      final job = await run(c, 'launcher', 'install');
      expect(job['state'], 'succeeded', reason: log(job));
      expect(orderLog().trim().split('\n'), ['args: ', 'applet']);
      final rec = receipt('launcher');
      final tree = (rec['trees'] as List).single as Map;
      expect(tree['root'], home('.local/lib/maprisma-launcher'));
      expect(tree['files'], 7);
      expect((tree['entries'] as List).map((e) => e['p']), containsAll(['lib/libflutter_linux_gtk.so', 'data/flutter_assets/fonts/MaterialIcons.otf', 'data/icudtl.dat']));
      expect(rec['components'], ['app', 'applet']);
      expect(readReceipt(w.paths, 'launcher').receipt!.trees, hasLength(1));
      // no backups of bundle files (the installer swaps the folder as a whole)
      expect(Directory(p.join(w.paths.managerState, 'displaced/launcher')).existsSync(), isFalse);
      final app = appOf(await c.call('apps.list'), 'launcher');
      expect(app['support'], containsPair('remove', true));
      expect(app['build']['receipt']['trees'].single['files'], 7);
    });

    test('its refusal while the terminal runs a command: app_busy, nothing changed; force only when asked', () async {
      launcherRepos();
      final c = core();
      expect((await run(c, 'launcher', 'install'))['state'], 'succeeded');
      final before = receipt('launcher');
      File(p.join(ctl, 'busy')).createSync();
      File(p.join(ctl, 'build')).writeAsStringSync('2');
      final busy = await run(c, 'launcher', 'reinstall');
      expect(busy['state'], 'failed');
      expect(busy['result']['code'], 'app_busy');
      expect(busy['result']['message'], contains('force'));
      expect(busy['result']['repair'], isFalse);
      expect(receipt('launcher')['job'], before['job']);
      expect(File(home('.local/lib/maprisma-launcher/data/icudtl.dat')).readAsStringSync(), 'build 1\n');
      // force is a launcher option, a bool, and not for other apps or removes
      await expectLater(c.call('jobs.start', {'app': 'home', 'kind': 'install', 'options': {'force': true}}),
          throwsA(isA<RouteError>().having((e) => e.code, 'code', 'bad_params')));
      await expectLater(c.call('jobs.start', {'app': 'launcher', 'kind': 'install', 'options': {'force': 'yes'}}),
          throwsA(isA<RouteError>().having((e) => e.code, 'code', 'bad_params')));
      final forced = await run(c, 'launcher', 'reinstall', {'force': true});
      expect(forced['state'], 'succeeded', reason: log(forced));
      expect(log(forced), contains('\$ tools/install-local --force'));
      expect(File(home('.local/lib/maprisma-launcher/data/icudtl.dat')).readAsStringSync(), 'build 2\n');
    });

    test('remove: unchanged bundle files go, changed and added ones stay; a matching leftover goes', () async {
      launcherRepos();
      final c = core();
      expect((await run(c, 'launcher', 'install'))['state'], 'succeeded');
      final lib = home('.local/lib/maprisma-launcher');
      w.writeFile(p.join(lib, 'data/icudtl.dat'), 'edited');
      w.writeFile(p.join(lib, 'notes.txt'), 'mine');
      // an interrupted swap's copies: one holds only the build's files, one something else
      final old = home('.local/lib/maprisma-launcher.old.Ab12Cd');
      w.writeFile(p.join(old, 'lib/libapp.so'), 'lib\n');
      final foreign = home('.local/lib/maprisma-launcher.new.Zz98Yx');
      w.writeFile(p.join(foreign, 'lib/libapp.so'), 'other build\n');
      final plan = await c.call('apps.remove_plan', {'id': 'launcher'});
      expect(plan['blocked'], isNull);
      final trees = (plan['goes'] as List).where((g) => g['kind'] == 'tree').toList();
      expect(trees.map((t) => t['path']), unorderedEquals([lib, old]));
      expect(trees.firstWhere((t) => t['path'] == lib)['files'], 6);
      expect(stayOf(plan, p.join(lib, 'data/icudtl.dat'))!['why'], 'changed since the Manager installed it');
      expect(stayOf(plan, p.join(lib, 'notes.txt'))!['why'], contains('not installed by the Manager'));
      expect(stayOf(plan, foreign)!['why'], contains('interrupted install'));
      // the catalog's sample paths inside the bundle are the tree's, not entries of their own
      expect((plan['goes'] as List).where((g) => g['kind'] != 'tree').map((g) => g['path']), isNot(contains(p.join(lib, 'lib/libapp.so'))));

      final job = await run(c, 'launcher', 'remove', {'revision': plan['revision']});
      expect(job['state'], 'succeeded', reason: log(job));
      expect(exists(p.join(lib, 'lib/libapp.so')), isFalse);
      expect(exists(p.join(lib, 'data/flutter_assets')), isFalse);
      expect(File(p.join(lib, 'data/icudtl.dat')).readAsStringSync(), 'edited');
      expect(File(p.join(lib, 'notes.txt')).readAsStringSync(), 'mine');
      expect(exists(old), isFalse);
      expect(exists(p.join(foreign, 'lib/libapp.so')), isTrue);
      expect(exists(home('.local/bin/maprisma-launcher')), isFalse);
      expect(exists(home('.local/bin/maprisma-launcher-applet')), isFalse);
      expect(exists(home('.local/lib')), isTrue);
      expect(exists(p.join(w.paths.receipts, 'launcher.json')), isFalse);
    });

    test('without a receipt a bundle app is not removed (blocked), nothing is deleted', () async {
      w.install('launcher');
      final c = core();
      final plan = await c.call('apps.remove_plan', {'id': 'launcher'});
      expect(plan['blocked'], contains('Reinstall'));
      final job = await run(c, 'launcher', 'remove');
      expect(job['state'], 'failed');
      expect(job['result']['code'], 'blocked');
      expect(job['result']['repair'], isFalse);
      expect(exists(home('.local/lib/maprisma-launcher/lib/libapp.so')), isTrue);
      expect(exists(home('.local/bin/maprisma-launcher')), isTrue);
    });
  });

  test('theme: reinstall over an install from before the Manager; FLUTTER is the folder; owned and removed', () async {
    w.install('theme');
    final repo = w.repo('maprisma-theme');
    w.writeFile(p.join(repo, 'tools/install-local'), _themeInstall, mode: '755');
    w.git(repo, ['add', '.']);
    w.git(repo, ['commit', '-q', '-m', 'installer']);
    final c = core();
    final job = await run(c, 'theme', 'reinstall');
    expect(job['state'], 'succeeded', reason: log(job));
    expect(log(job), contains('FLUTTER=${w.fakeBin}\n'));
    final lib = home('.local/lib/maprisma-theme');
    expect((receipt('theme')['trees'] as List).single['root'], lib);
    // files before the Manager outside the bundle were backed up; none inside it
    final index = jsonDecode(File(p.join(w.paths.managerState, 'displaced/theme/index.json')).readAsStringSync()) as Map;
    final backed = [for (final e in index['entries'] as List) e['path'] as String];
    expect(backed, isNotEmpty);
    expect(backed.where((b) => p.isWithin(lib, b)), isEmpty);
    final remove = await run(c, 'theme', 'remove');
    expect(remove['state'], 'succeeded', reason: log(remove));
    expect(exists(lib), isFalse);
    expect(exists(home('.local/bin/maprisma-theme-core')), isFalse);
  });

  test('home: remove and install again: back at its place in the panel, files byte-identical, its config kept', () async {
    final repo = w.repo('maprisma-home');
    w.writeFile(p.join(repo, 'install.sh'), r'''#!/bin/sh
set -eu
bin="$HOME/.local/bin"; data="${XDG_DATA_HOME:-$HOME/.local/share}"; c=io.github.ubruckhaus.CosmicMaprismaHome
mkdir -p "$bin" "$data/maprisma-home/scripts" "$data/applications" "$data/icons/hicolor/scalable/apps" "$HOME/.config/autostart" "$HOME/.config/maprisma-home"
for b in maprisma-home maprisma-home-tray; do printf '#!/bin/sh\n' > "$bin/$b"; chmod 755 "$bin/$b"; done
for s in stove.py switchbot.py stove_map.json; do echo "$s" > "$data/maprisma-home/scripts/$s"; done
echo '<svg/>' > "$data/icons/hicolor/scalable/apps/$c-symbolic.svg"
printf '[Desktop Entry]\n' > "$data/applications/$c.desktop"
printf '[Desktop Entry]\n' > "$data/applications/$c.Window.desktop"
printf '[Desktop Entry]\nOnlyShowIn=KDE;\n' > "$HOME/.config/autostart/$c.Tray.desktop"
[ -e "$HOME/.config/maprisma-home/config.json" ] || echo '{"seeded": true}' > "$HOME/.config/maprisma-home/config.json"
''', mode: '755');
    w.git(repo, ['add', '.']);
    w.git(repo, ['commit', '-q', '-m', 'installer']);
    final c = core();
    expect((await run(c, 'home', 'install'))['state'], 'succeeded');
    final panel = p.join(w.paths.config, 'cosmic/com.system76.CosmicPanel.Panel/v1');
    final wings = p.join(panel, 'plugins_wings');
    const placed = 'Some(([\n    "com.system76.CosmicAppletWorkspaces",\n], [\n    "io.github.ubruckhaus.CosmicMaprismaHome",\n'
        '    "io.github.ubruckhaus.CosmicMaprismaVideoTranslator",\n    "com.system76.CosmicAppletPower",\n]))';
    w.writeFile(wings, placed);
    final config = home('.config/maprisma-home/config.json');
    w.writeFile(config, '{"stove": "mine"}');
    final remove = await run(c, 'home', 'remove');
    expect(remove['state'], 'succeeded', reason: log(remove));
    expect(File(wings).readAsStringSync(), isNot(contains('CosmicMaprismaHome')));
    expect(WantedBar.load(w.paths).of(DesktopId.cosmic, 'home'), {'placed': true, 'area': 'right', 'index': 0});
    final again = await run(c, 'home', 'install');
    expect(again['state'], 'succeeded', reason: log(again));
    expect(File(wings).readAsStringSync(), placed);
    expect(File(config).readAsStringSync(), '{"stove": "mine"}');
  });

  group('narrator and video', () {
    void narratorRepo() {
      final repo = w.repo('maprisma-narrator');
      w.writeFile(p.join(repo, 'install.sh'), _rustFlutterInstall(
        name: 'maprisma-narrator',
        bins: ['maprisma-narrator-tray', 'maprisma-narrator-applet', 'maprisma-narrator-desktop'],
        window: 'settings',
        windowLink: 'maprisma-narrator',
        entries: ['com.maprisma.Narrator.desktop', 'io.github.ubruckhaus.CosmicMaprismaNarrator.desktop', 'com.maprisma.Narrator.Desktop.desktop'],
        autostart: 'com.maprisma.Narrator.Tray.desktop',
        extra: _iconLine('io.github.ubruckhaus.CosmicMaprismaNarrator-symbolic'),
      ), mode: '755');
      for (final f in ['bridge.py', 'setup_backend.py', 'reader/ocr.py']) {
        w.writeFile(p.join(repo, 'backend', f), '# $f\n');
      }
      w.git(repo, ['add', '.']);
      w.git(repo, ['commit', '-q', '-m', 'installer']);
    }

    test('narrator without cmake: partly installed; its reader unit stopped and started again; the reader runtime stays on remove', () async {
      narratorRepo();
      File(p.join(ctl, 'unit-active')).createSync();
      final c = core();
      final job = await run(c, 'narrator', 'install');
      expect(job['state'], 'succeeded', reason: log(job));
      expect(job['result']['partial'], ['settings window']);
      final sys = File(p.join(ctl, 'systemctl.log')).readAsStringSync();
      expect(sys, contains('--user stop ocrvox.service'));
      expect(sys.indexOf('--user start ocrvox.service'), greaterThan(sys.indexOf('--user stop ocrvox.service')));
      expect(job['result']['unitsStarted'], ['ocrvox.service']);
      final backend = p.join(w.paths.data, 'maprisma-narrator/backend');
      expect([for (final t in receipt('narrator')['trees'] as List) t['root']], [backend]);

      // what the reader's setup made (shared with Omarchy's reader)
      const marker = '# Managed by ubruckhaus.simple-reader (Maprisma Narrator)';
      final unit = home('.config/systemd/user/ocrvox.service');
      final dropIn = home('.config/systemd/user/ocrvox.service.d/read-aloud-runtime.conf');
      final reader = home('.local/bin/simple-reader');
      for (final f in [unit, dropIn, reader]) {
        w.writeFile(f, '$marker\nx\n');
      }
      w.writeFile(home('.local/share/kindle-reader/venv/bin/python'), 'x');
      w.writeFile(p.join(backend, 'reader/__pycache__/ocr.cpython-314.pyc'), 'pyc');
      final plan = await c.call('apps.remove_plan', {'id': 'narrator', 'delete_settings': true});
      for (final f in [unit, dropIn, reader]) {
        expect(stayOf(plan, f)!['why'], contains('shared with Omarchy\'s reader'));
        expect(stayOf(plan, f)!['marked'], isTrue);
      }
      expect((plan['data'] as List).firstWhere((d) => (d['path'] as String).endsWith('kindle-reader'))['goes'], isFalse);
      final remove = await run(c, 'narrator', 'remove', {'delete_settings': true});
      expect(remove['state'], 'succeeded', reason: log(remove));
      for (final f in [unit, dropIn, reader, home('.local/share/kindle-reader/venv/bin/python')]) {
        expect(exists(f), isTrue, reason: f);
      }
      expect(exists(p.join(w.paths.data, 'maprisma-narrator')), isFalse); // the byte-code cache went too
      expect(exists(home('.local/bin/maprisma-narrator-applet')), isFalse);
    });

    test('video with cmake and ninja: both folders owned; the managed video-trans command stays on remove', () async {
      w.fake('cmake', 'exit 0');
      w.fake('ninja', 'exit 0');
      final repo = w.repo('maprisma-video-translator');
      w.writeFile(p.join(repo, 'install.sh'), _rustFlutterInstall(
        name: 'maprisma-video-translator',
        bins: ['maprisma-video-translator-applet', 'maprisma-video-translator-tray', 'maprisma-video-translator-captions'],
        window: 'app',
        windowLink: 'maprisma-video-translator',
        entries: ['com.maprisma.VideoTranslator.desktop', 'io.github.ubruckhaus.CosmicMaprismaVideoTranslator.desktop'],
        autostart: 'com.maprisma.VideoTranslator.Tray.desktop',
        extra: _iconLine('io.github.ubruckhaus.CosmicMaprismaVideoTranslator-symbolic'),
      ), mode: '755');
      for (final f in ['bridge.sh', 'bridge.py', 'backend.py']) {
        w.writeFile(p.join(repo, 'backend', f), '# $f\n');
      }
      w.git(repo, ['add', '.']);
      w.git(repo, ['commit', '-q', '-m', 'installer']);
      final command = home('.local/bin/video-trans');
      w.writeFile(command, '#!/usr/bin/env bash\n# Managed by ubruckhaus.video-trans\nexec bash x\n', mode: '755');
      final c = core();
      final job = await run(c, 'video', 'install');
      expect(job['state'], 'succeeded', reason: log(job));
      expect(job['result']['partial'], isNull);
      final data = p.join(w.paths.data, 'maprisma-video-translator');
      expect([for (final t in receipt('video')['trees'] as List) t['root']], [p.join(data, 'backend'), p.join(data, 'app')]);
      // an interrupted earlier install's staging copy
      w.writeFile(p.join(data, 'backend.new/bridge.py'), '# bridge.py\n');
      final plan = await c.call('apps.remove_plan', {'id': 'video'});
      expect(stayOf(plan, command)!['why'], contains('video-trans'));
      expect((plan['goes'] as List).where((g) => g['leftover'] == true).single['path'], p.join(data, 'backend.new'));
      final remove = await run(c, 'video', 'remove', {'revision': plan['revision']});
      expect(remove['state'], 'succeeded', reason: log(remove));
      expect(exists(command), isTrue);
      expect(exists(data), isFalse);
      expect(exists(home('.local/bin/maprisma-video-translator')), isFalse);
    });
  });

  group('KDE', () {
    late String plasma;

    setUp(() {
      plasma = p.join(w.dir, 'plasma.json');
      File(plasma).writeAsStringSync('[]');
      final fake = p.join(w.fakeBin, 'qdbus6');
      File(p.join(Directory.current.path, 'test/fake_qdbus6.py')).copySync(fake);
      chmod(fake, '755');
      w.writeFile(p.join(w.fakeBin, 'kpackagetool6'), _kpackagetool, mode: '755');
      w.writeFile(p.join(w.fakeBin, 'kwriteconfig6'), _kwriteconfig, mode: '755');
      w.fake('plasma-apply-desktoptheme', r'''echo "plasma-apply-desktoptheme $*" >> "$HOME/.mm-test/order.log"
printf '[Theme]\nname=%s\n' "$1" > "${XDG_CONFIG_HOME:-$HOME/.config}/plasmarc"''');
    });

    CoreService kde({Map<String, String> extra = const {}}) => core(desktop: 'KDE', extra: {'FAKE_PLASMA': plasma, ...extra});

    void tilingRepo() {
      final repo = w.repo('maprisma-kwin-scripts');
      w.writeFile(p.join(repo, 'install.sh'), _tilingInstall, mode: '755');
      w.writeFile(p.join(repo, 'tools/tiling-shortcuts'), '#!/bin/sh\necho "shortcuts \$*" >> "\$HOME/.mm-test/order.log"\n', mode: '755');
      w.writeFile(p.join(repo, 'maprisma-tiling/metadata.json'), '{"KPlugin": {"Id": "maprisma-tiling"}}');
      w.writeFile(p.join(repo, 'maprisma-tiling/contents/ui/tiling.qml'), 'Item {}');
      w.writeFile(p.join(repo, 'omarchy-navigation/metadata.json'), '{"KPlugin": {"Id": "omarchy-navigation"}}');
      w.writeFile(p.join(repo, 'omarchy-navigation/contents/code/main.js'), '// nav');
      w.git(repo, ['add', '.']);
      w.git(repo, ['commit', '-q', '-m', 'installer']);
    }

    test('tiling and icons are refused on COSMIC (install, remove and its plan)', () async {
      tilingRepo();
      final c = core();
      for (final app in ['tiling', 'icons']) {
        await expectLater(c.call('jobs.start', {'app': app, 'kind': 'install'}), throwsA(isA<RouteError>().having((e) => e.code, 'code', 'unavailable')));
        await expectLater(c.call('jobs.start', {'app': app, 'kind': 'remove'}), throwsA(isA<RouteError>().having((e) => e.code, 'code', 'unavailable')));
        await expectLater(c.call('apps.remove_plan', {'id': app}), throwsA(isA<RouteError>().having((e) => e.code, 'code', 'unavailable')));
      }
    });

    test('tiling: Krohnkite migration shown and kept, omarchy-navigation from before kept, only its kwinrc keys deleted', () async {
      tilingRepo();
      final scripts = p.join(w.paths.data, 'kwin/scripts');
      w.writeFile(p.join(scripts, 'omarchy-navigation/metadata.json'), '{"KPlugin": {"Id": "omarchy-navigation"}}');
      w.writeFile(p.join(scripts, 'krohnkite/metadata.json'), '{"KPlugin": {"Id": "krohnkite"}}');
      final kwinrc = p.join(w.paths.config, 'kwinrc');
      w.writeFile(kwinrc, '[Plugins]\nkrohnkiteEnabled=true\notherEnabled=true\n\n[Script-maprisma-tiling]\ngapTop=8\n\n[Other]\nx=1\n');
      final c = kde();
      final job = await run(c, 'tiling', 'install');
      expect(job['state'], 'succeeded', reason: log(job));
      final trees = {for (final t in receipt('tiling')['trees'] as List) t['root']: t};
      expect(trees[p.join(scripts, 'omarchy-navigation')]['preexisting'], isTrue);
      expect(trees[p.join(scripts, 'maprisma-tiling')]['preexisting'], isNull);
      final backup = p.join(w.paths.data, 'maprisma-tiling/krohnkite-backup.tar.gz');
      expect(exists(backup), isTrue);

      final plan = await c.call('apps.remove_plan', {'id': 'tiling', 'delete_settings': true});
      expect(plan['blocked'], isNull);
      expect([for (final s in plan['steps'] as List) s['id']], ['shortcuts', 'unload', 'kwinrc', 'packages', 'reconfigure', 'dbus']);
      final kwinStep = (plan['steps'] as List).firstWhere((s) => s['id'] == 'kwinrc');
      expect(kwinStep['commands'], [
        'kwriteconfig6 --file kwinrc --group Plugins --key maprisma-tilingEnabled --delete',
        'kwriteconfig6 --file kwinrc --group Script-maprisma-tiling --key gapTop --delete',
        'kwriteconfig6 --file kwinrc --group Script-maprisma-tiling --key build --delete',
      ]);
      expect(stayOf(plan, backup)!['why'], contains('tar -xzf'));
      expect(stayOf(plan, p.join(scripts, 'omarchy-navigation'))!['why'], contains('before the Manager'));
      expect((plan['data'] as List).single['goes'], isFalse);

      File(p.join(ctl, 'order.log')).writeAsStringSync('');
      final remove = await run(c, 'tiling', 'remove', {'delete_settings': true, 'revision': plan['revision']});
      expect(remove['state'], 'succeeded', reason: log(remove));
      final order = orderLog().trim().split('\n');
      expect(order.first, 'shortcuts --restore');
      expect(order, contains('kpackagetool6 -t KWin/Script -r maprisma-tiling'));
      expect(order.where((l) => l.contains('-r omarchy-navigation')), isEmpty);
      expect(order.last, startsWith('busctl --user call'));
      final kwin = File('$plasma.kwin.log').readAsStringSync();
      expect(kwin, contains('unloadScript maprisma-tiling'));
      expect(kwin, isNot(contains('unloadScript omarchy-navigation')));
      expect(kwin.trim().split('\n').last, 'org.kde.KWin /KWin reconfigure');
      final rc = File(kwinrc).readAsStringSync();
      expect(rc, contains('otherEnabled=true'));
      expect(rc, contains('omarchy-navigationEnabled=true'));
      expect(rc, contains('[Other]\nx=1'));
      expect(rc, isNot(contains('maprisma-tilingEnabled')));
      expect(rc, isNot(contains('gapTop')));
      expect(exists(p.join(scripts, 'maprisma-tiling')), isFalse);
      expect(exists(p.join(scripts, 'omarchy-navigation/metadata.json')), isTrue);
      expect(exists(backup), isTrue);
      expect(exists(home('.local/bin/maprisma-tiling-shortcuts')), isFalse);
      expect(exists(p.join(w.paths.data, 'dbus-1/services/org.maprisma.TilingOverlay.service')), isFalse);
    });

    test('tiling: a package that changed after the plan is not removed by kpackagetool6', () async {
      tilingRepo();
      final scripts = p.join(w.paths.data, 'kwin/scripts');
      final c = kde();
      expect((await run(c, 'tiling', 'install'))['state'], 'succeeded');
      final plan = await removePlan(c.ctx, findApp('tiling')!);
      final packages = plan.recipe!.steps.firstWhere((s) => s.id == 'packages');
      w.writeFile(p.join(scripts, 'maprisma-tiling/contents/ui/extra.qml'), 'added after the plan');
      File(p.join(ctl, 'order.log')).writeAsStringSync('');
      final lines = <String>[];
      await runRecipe(c.ctx, [packages], StepWhen.before, lines.add);
      expect(lines.join('\n'), contains('maprisma-tiling changed since the plan: kpackagetool6 not run'));
      expect(orderLog(), isNot(contains('-r maprisma-tiling')));
      expect(orderLog(), contains('-r omarchy-navigation'));
      expect(File(p.join(scripts, 'maprisma-tiling/contents/ui/extra.qml')).existsSync(), isTrue);
    });

    test('KDE: remove and install again puts the tray back at its place in the widget', () async {
      final repo = w.repo('maprisma-home');
      w.writeFile(p.join(repo, 'install.sh'), r'''#!/bin/sh
set -eu
bin="$HOME/.local/bin"; data="${XDG_DATA_HOME:-$HOME/.local/share}"; c=io.github.ubruckhaus.CosmicMaprismaHome
mkdir -p "$bin" "$data/maprisma-home/scripts" "$data/applications" "$data/icons/hicolor/scalable/apps" "$HOME/.config/autostart"
for b in maprisma-home maprisma-home-tray; do printf '#!/bin/sh\n' > "$bin/$b"; chmod 755 "$bin/$b"; done
for s in stove.py switchbot.py stove_map.json; do echo "$s" > "$data/maprisma-home/scripts/$s"; done
echo '<svg/>' > "$data/icons/hicolor/scalable/apps/$c-symbolic.svg"
printf '[Desktop Entry]\n' > "$data/applications/$c.desktop"
printf '[Desktop Entry]\n' > "$data/applications/$c.Window.desktop"
printf '[Desktop Entry]\nOnlyShowIn=KDE;\n' > "$HOME/.config/autostart/$c.Tray.desktop"
''', mode: '755');
      w.git(repo, ['add', '.']);
      w.git(repo, ['commit', '-q', '-m', 'installer']);
      final c = kde();
      expect((await run(c, 'home', 'install'))['state'], 'succeeded');
      File(plasma).writeAsStringSync(jsonEncode([
        {'panel': 1, 'widget': 3, 'zoneLeft': ['maprisma-wlan-monitor', 'maprisma-home', 'maprisma-hue-lights'], 'zoneCenter': ['clock'], 'zoneRight': [], 'hidden': []},
      ]));
      final remove = await run(c, 'home', 'remove');
      expect(remove['state'], 'succeeded', reason: log(remove));
      expect(WantedBar.load(w.paths).of(DesktopId.kde, 'home'), {'placed': true, 'area': 'left', 'index': 1, 'widget': 3});
      // (the widget's own Launcher entry is added to the left zone as the widget does)
      expect((jsonDecode(File(plasma).readAsStringSync()) as List).single['zoneLeft'], ['maprisma-wlan-monitor', 'maprisma-hue-lights', 'maprisma-launcher']);
      final again = await run(c, 'home', 'install');
      expect(again['state'], 'succeeded', reason: log(again));
      final widget = (jsonDecode(File(plasma).readAsStringSync()) as List).single as Map;
      expect(widget['zoneLeft'], ['maprisma-wlan-monitor', 'maprisma-home', 'maprisma-hue-lights', 'maprisma-launcher']);
      expect(widget['hidden'], isEmpty);
    });

    test('tiling: omarchy-navigation it installed goes; a changed package stays whole', () async {
      tilingRepo();
      final scripts = p.join(w.paths.data, 'kwin/scripts');
      final c = kde();
      expect((await run(c, 'tiling', 'install'))['state'], 'succeeded');
      w.writeFile(p.join(scripts, 'maprisma-tiling/contents/ui/tiling.qml'), 'Item { edited }');
      final plan = await c.call('apps.remove_plan', {'id': 'tiling'});
      expect(stayOf(plan, p.join(scripts, 'maprisma-tiling'))!['why'], contains('stays as a whole'));
      final packages = (plan['steps'] as List).firstWhere((s) => s['id'] == 'packages');
      expect(packages['commands'], ['kpackagetool6 -t KWin/Script -r omarchy-navigation']);
      final remove = await run(c, 'tiling', 'remove');
      expect(remove['state'], 'succeeded', reason: log(remove));
      expect(exists(p.join(scripts, 'omarchy-navigation')), isFalse);
      expect(File(p.join(scripts, 'maprisma-tiling/contents/ui/tiling.qml')).readAsStringSync(), 'Item { edited }');
      expect(exists(p.join(scripts, 'maprisma-tiling/metadata.json')), isTrue);
      expect(File(p.join(w.paths.config, 'kwinrc')).readAsStringSync(), isNot(contains('omarchy-navigationEnabled')));
    });

    group('icons', () {
      void iconsRepo() {
        final repo = w.repo('maprisma-panel');
        w.writeFile(p.join(repo, 'install.sh'), _iconsInstall, mode: '755');
        w.writeFile(p.join(repo, 'package/metadata.json'), '{"KPlugin": {"Id": "com.maprisma.panel"}}');
        w.writeFile(p.join(repo, 'package/contents/ui/main.qml'), 'Item {}');
        w.writeFile(p.join(repo, 'tools/maprisma-panel-color'), '#!/bin/sh\n', mode: '755');
        w.git(repo, ['add', '.']);
        w.git(repo, ['commit', '-q', '-m', 'installer']);
      }

      String style(String name, {String? extra}) {
        final dir = p.join(w.paths.data, 'plasma/desktoptheme', name);
        w.writeFile(p.join(dir, 'metadata.json'), jsonEncode({'KPlugin': {'Id': name, 'Description': 'Breeze with the panel in a colour from the wallpaper (maprisma-panel-color)'}}));
        w.writeFile(p.join(dir, 'plasmarc'), '[Theme]\nFallbackTheme=default\n');
        w.writeFile(p.join(dir, 'widgets/panel-background.svgz'), 'svg');
        if (extra != null) w.writeFile(p.join(dir, extra), 'mine');
        return dir;
      }

      test('remove: widgets out first, the style before put back, package, generated styles and cache', () async {
        iconsRepo();
        final plasmarc = p.join(w.paths.config, 'plasmarc');
        w.writeFile(plasmarc, '[Theme]\nname=breeze-dark\n');
        Directory(p.join(w.root, 'usr/share/plasma/desktoptheme/breeze-dark')).createSync(recursive: true);
        File(plasma).writeAsStringSync(jsonEncode([{'panel': 1, 'widget': 7, 'zoneLeft': ['maprisma-home']}]));
        final c = kde();
        final job = await run(c, 'icons', 'install');
        expect(job['state'], 'succeeded', reason: log(job));
        expect(receipt('icons')['saved'], {'plasmaTheme': 'breeze-dark'});
        // maprisma-panel-color ran: two generated styles (one holds a file of someone else), the cache
        final a = style('maprisma-panel-a');
        final b = style('maprisma-panel-b', extra: 'colors');
        w.writeFile(plasmarc, '[Theme]\nname=maprisma-panel-a\n');
        final cache = p.join(w.paths.cache, 'maprisma-panel');
        w.writeFile(p.join(cache, 'state.json'), '{}');
        // a reinstall while a generated style is active keeps the style from before
        expect((await run(c, 'icons', 'reinstall'))['state'], 'succeeded');
        expect(receipt('icons')['saved'], {'plasmaTheme': 'breeze-dark'});

        var plan = await c.call('apps.remove_plan', {'id': 'icons'});
        // a widget added after the plan was shown: the plan's revision no longer holds
        File(plasma).writeAsStringSync(jsonEncode([{'panel': 1, 'widget': 7}, {'panel': 2, 'widget': 9}]));
        final stale = await run(c, 'icons', 'remove', {'revision': plan['revision']});
        expect(stale['result']['code'], 'changed');
        expect(jsonDecode(File(plasma).readAsStringSync()), hasLength(2));
        plan = await c.call('apps.remove_plan', {'id': 'icons'});
        // the style first (a failure keeps the widgets), then exactly the widgets shown
        expect([for (final s in plan['steps'] as List) s['id']], ['style', 'widgets', 'packages', 'generated']);
        expect((plan['steps'] as List)[0]['commands'], ['plasma-apply-desktoptheme breeze-dark']);
        expect((plan['steps'] as List)[1]['title'], contains('7, 9'));
        expect([for (final g in plan['generated'] as List) g['path']], [a, cache]);
        expect(stayOf(plan, b)!['why'], contains('colors'));
        File(p.join(ctl, 'order.log')).writeAsStringSync('');
        final remove = await run(c, 'icons', 'remove', {'revision': plan['revision']});
        expect(remove['state'], 'succeeded', reason: log(remove));
        expect(jsonDecode(File(plasma).readAsStringSync()), isEmpty);
        expect(File('$plasma.log').readAsStringSync(), contains('// mm:remove-widgets'));
        expect(orderLog().trim().split('\n'), ['plasma-apply-desktoptheme breeze-dark', 'kpackagetool6 -t Plasma/Applet -r com.maprisma.panel']);
        expect(remove['result']['ok'], isTrue);
        expect(File(plasmarc).readAsStringSync(), contains('name=breeze-dark'));
        expect(exists(p.join(w.paths.data, 'plasma/plasmoids/com.maprisma.panel')), isFalse);
        expect(exists(a), isFalse);
        expect(exists(p.join(b, 'colors')), isTrue);
        expect(exists(cache), isFalse);
        expect(exists(home('.local/bin/maprisma-panel-color')), isFalse);
      });

      test('a style the user had is gone: back to default; styles behind a linked folder stay', () async {
        iconsRepo();
        final plasmarc = p.join(w.paths.config, 'plasmarc');
        w.writeFile(plasmarc, '[Theme]\nname=some-removed-style\n');
        final c = kde();
        expect((await run(c, 'icons', 'install'))['state'], 'succeeded');
        w.writeFile(plasmarc, '[Theme]\nname=maprisma-panel-a\n');
        // the styles folder is a link to somewhere else
        final elsewhere = p.join(w.dir, 'elsewhere');
        final dir = p.join(elsewhere, 'maprisma-panel-a');
        w.writeFile(p.join(dir, 'metadata.json'), jsonEncode({'KPlugin': {'Id': 'maprisma-panel-a', 'Description': 'maprisma-panel-color'}}));
        Directory(p.join(w.paths.data, 'plasma')).createSync(recursive: true);
        Link(p.join(w.paths.data, 'plasma/desktoptheme')).createSync(elsewhere);
        final plan = await c.call('apps.remove_plan', {'id': 'icons'});
        expect((plan['steps'] as List).first['commands'], ['plasma-apply-desktoptheme default']);
        expect(plan['notes'], contains(contains('some-removed-style')));
        expect(stayOf(plan, p.join(w.paths.data, 'plasma/desktoptheme/maprisma-panel-a'))!['why'], contains('linked folder'));
        expect((await run(c, 'icons', 'remove'))['state'], 'succeeded');
        expect(File(p.join(dir, 'metadata.json')).existsSync(), isTrue);
      });

      test('plasmashell not reachable: the remove is blocked before anything changes', () async {
        iconsRepo();
        final c = kde();
        expect((await run(c, 'icons', 'install'))['state'], 'succeeded');
        final down = kde(extra: {'FAKE_PLASMA_DOWN': '1'});
        final plan = await down.call('apps.remove_plan', {'id': 'icons'});
        expect(plan['blocked'], contains('plasmashell'));
        final job = await run(down, 'icons', 'remove');
        expect(job['state'], 'failed');
        expect(job['result']['code'], 'blocked');
        expect(exists(p.join(w.paths.data, 'plasma/plasmoids/com.maprisma.panel/metadata.json')), isTrue);
        expect(exists(home('.local/bin/maprisma-panel-color')), isTrue);
      });
    });
  });
}
