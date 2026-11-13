// The rename from Maprisma Manager to Maprisma Settings: the folders of the old name are renamed
// once with links left (paths.dart migrateLegacyFolders), the state of the old id `manager` gets the
// new one, and the old id still names the app.
import 'dart:convert';
import 'dart:io';

import 'package:maprisma_manager_core/maprisma_manager_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late World w;
  setUp(() => w = World.create());
  tearDown(() => w.dispose());

  String old(String base) => p.join(base, 'maprisma-manager');
  String now(String base) => p.join(base, 'maprisma-settings');

  test('the folders of the old name are renamed, a link left; the files stay the same files', () {
    final paths = w.paths;
    w.writeFile(p.join(old(paths.config), 'settings.json'), '{"corners":"square"}');
    w.writeFile(p.join(old(paths.state), 'github.json'), '{}');
    w.writeFile(p.join(old(paths.cache), 'downloads/x'), 'x');
    final mtime = FileStat.statSync(p.join(old(paths.config), 'settings.json')).modified;
    final notes = migrateLegacyFolders(paths);
    expect(notes, hasLength(3));
    for (final base in [paths.config, paths.state, paths.cache]) {
      expect(FileSystemEntity.isLinkSync(old(base)), isTrue);
      expect(Link(old(base)).targetSync(), 'maprisma-settings');
      expect(FileSystemEntity.isDirectorySync(now(base)), isTrue);
    }
    expect(File(paths.settingsFile).readAsStringSync(), '{"corners":"square"}');
    expect(FileStat.statSync(paths.settingsFile).modified, mtime);
    expect(Settings.load(paths).corners, 'square');
    // nothing where there was nothing
    expect(FileSystemEntity.typeSync(old(paths.data), followLinks: false), FileSystemEntityType.notFound);
    // once only
    expect(migrateLegacyFolders(paths), isEmpty);
  });

  test('when both exist the new folder is used and the old one is left alone', () {
    final paths = w.paths;
    w.writeFile(p.join(old(paths.config), 'settings.json'), '{"corners":"square"}');
    w.writeFile(p.join(now(paths.config), 'settings.json'), '{"corners":"slight"}');
    expect(migrateLegacyFolders(paths), isEmpty);
    expect(FileSystemEntity.isDirectorySync(old(paths.config)) && !FileSystemEntity.isLinkSync(old(paths.config)), isTrue);
    expect(Settings.load(paths).corners, 'slight');
  });

  test('the state of the old id: receipt (id rewritten), kept record, icons, displaced files, bar wishes', () {
    final paths = w.paths;
    final st = old(paths.state);
    w.writeFile(p.join(st, 'installed/manager.json'), jsonEncode({'schema': 1, 'id': 'manager', 'at': '2026-11-13T00:00:00Z', 'inputs': []}));
    w.writeFile(p.join(st, 'installed/wlan.json'), jsonEncode({'id': 'wlan'}));
    w.writeFile(p.join(st, 'kept/manager.json'), '{}');
    w.writeFile(p.join(st, 'icons/manager/original.svg'), '<svg/>');
    w.writeFile(p.join(st, 'displaced/manager/index.json'), '[]');
    w.writeFile(p.join(st, 'bar.json'), jsonEncode({'kde': {'wlan': {'placed': true}}, 'hyprland': {'manager': {'placed': true, 'area': 'left', 'index': 2}}}));
    final notes = migrateLegacyFolders(paths);
    expect(notes, containsAll(['receipt manager -> settings', 'kept/manager.json -> settings.json', 'icons/manager -> settings', 'displaced/manager -> settings', 'bar.json manager -> settings']));
    final s = paths.managerState;
    expect(File(p.join(s, 'installed/manager.json')).existsSync(), isFalse);
    expect(jsonDecode(File(p.join(s, 'installed/settings.json')).readAsStringSync())['id'], 'settings');
    expect(File(p.join(s, 'installed/wlan.json')).existsSync(), isTrue);
    expect(File(p.join(s, 'kept/settings.json')).existsSync(), isTrue);
    expect(File(p.join(s, 'icons/settings/original.svg')).existsSync(), isTrue);
    expect(File(p.join(s, 'displaced/settings/index.json')).existsSync(), isTrue);
    final bar = jsonDecode(File(p.join(s, 'bar.json')).readAsStringSync());
    expect(bar['hyprland'], {'settings': {'placed': true, 'area': 'left', 'index': 2}});
    expect(bar['kde'], {'wlan': {'placed': true}});
    expect(WantedBar.load(paths).of(DesktopId.hyprland, 'settings'), isNotNull);
    expect(migrateLegacyFolders(paths), isEmpty);
  });

  test('a receipt of the new id is never overwritten by the old one', () {
    final paths = w.paths;
    w.writeFile(p.join(paths.receipts, 'manager.json'), jsonEncode({'id': 'manager', 'version': 'old'}));
    w.writeFile(p.join(paths.receipts, 'settings.json'), jsonEncode({'id': 'settings', 'version': 'new'}));
    migrateLegacyIds(paths);
    expect(jsonDecode(File(p.join(paths.receipts, 'settings.json')).readAsStringSync())['version'], 'new');
    expect(File(p.join(paths.receipts, 'manager.json')).existsSync(), isTrue);
  });

  test('the old id names the app; the repo folder may carry the new name', () async {
    expect(findApp('manager')!.id, 'settings');
    expect(findApp('settings')!.name, 'Maprisma Settings');
    expect(canonicalAppId('manager'), 'settings');
    expect(canonicalAppId('wlan'), 'wlan');
    final c = w.core();
    expect((await c.call('apps.get', {'id': 'manager'}))['app']['id'], 'settings');
    // the folder renamed by the user: found under its new name
    Directory(p.join(w.projects, 'maprisma-settings')).createSync(recursive: true);
    expect(c.ctx.repoFolder('maprisma-manager'), p.join(w.projects, 'maprisma-settings'));
    // the catalog's name wins while it exists
    Directory(p.join(w.projects, 'maprisma-manager')).createSync(recursive: true);
    expect(c.ctx.repoFolder('maprisma-manager'), p.join(w.projects, 'maprisma-manager'));
    expect(orgNamesFor('maprisma-manager'), containsAll(['manager', 'settings']));
  });

  test('the core answers `version` with the name it was started by', () {
    expect(cliName('/x/bin/maprisma-settings-core'), 'maprisma-settings-core');
    expect(cliName('/x/bin/maprisma-manager-core'), 'maprisma-manager-core');
    expect(cliName('dart'), 'maprisma-settings-core');
  });
}
