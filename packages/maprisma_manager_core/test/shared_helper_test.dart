// The AI helper shared by all Maprisma apps: `maprisma-ai/settings.json` (ai/shared_helper.dart).
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

  String file() => p.join(w.home, '.config/maprisma-ai/settings.json');
  String managerSettings() => p.join(w.home, '.config/maprisma-settings/settings.json');
  Map<String, dynamic> stored() => jsonDecode(File(file()).readAsStringSync()) as Map<String, dynamic>;
  int mode(String path) => File(path).statSync().mode & 0x1ff;

  test('the file follows XDG_CONFIG_HOME', () {
    final paths = Paths.fromEnvironment({'HOME': w.home, 'XDG_CONFIG_HOME': p.join(w.dir, 'xdg')});
    expect(sharedAiFile(paths), p.join(w.dir, 'xdg/maprisma-ai/settings.json'));
    expect(sharedAiFile(w.paths), file());
  });

  test('valid values: auto, catalog ids, local models; nothing else', () {
    for (final ok in ['auto', 'claude', 'cursor-agent', 'pi:ollama/qwen3:8b', 'x@y+z', 'a' * 161]) {
      expect(validSharedHelper(ok), isTrue, reason: ok);
    }
    for (final bad in [null, 3, '', '-x', '.x', '../x', 'a b', 'a\n', 'a' * 162, 'ä']) {
      expect(validSharedHelper(bad), isFalse, reason: '$bad');
    }
  });

  test('missing, broken or invalid reads as auto', () {
    expect(readSharedHelper(w.paths), 'auto');
    expect(sharedHelperExists(w.paths), isFalse);
    for (final text in ['', '{broken', '[]', '"codex"', '{}', '{"helper": 3}', '{"helper": "../x"}', '{"helper": ""}']) {
      w.writeFile(file(), text);
      expect(readSharedHelper(w.paths), 'auto', reason: text);
    }
    w.writeFile(file(), '{"helper": "pi:ollama/qwen"}');
    expect(readSharedHelper(w.paths), 'pi:ollama/qwen');
    // too big: not read
    w.writeFile(file(), '{"helper": "codex", "pad": "${'x' * sharedAiFileMax}"}');
    expect(readSharedHelper(w.paths), 'auto');
  });

  test('write: unknown keys kept, folder 0700, file 0600, no temporary file left, bad values refused', () {
    w.writeFile(file(), jsonEncode({'helper': 'claude', 'future': {'x': 1}, 'other': true}));
    writeSharedHelper(w.paths, 'codex');
    expect(stored(), {'helper': 'codex', 'future': {'x': 1}, 'other': true});
    expect(mode(file()), 0x180);
    expect(mode(p.dirname(file())), 0x1c0);
    expect(Directory(p.dirname(file())).listSync().map((e) => p.basename(e.path)), ['settings.json']);
    // a broken file is replaced by a fresh object
    w.writeFile(file(), '{broken');
    writeSharedHelper(w.paths, 'auto');
    expect(stored(), {'helper': 'auto'});
    expect(() => writeSharedHelper(w.paths, '../x'), throwsArgumentError);
    expect(stored(), {'helper': 'auto'});
  });

  test('write is atomic: a rename over the old file (a reader never sees half a file)', () {
    writeSharedHelper(w.paths, 'claude');
    final before = File(file()).statSync();
    final inode = Process.runSync('stat', ['-c', '%i', file()]).stdout;
    writeSharedHelper(w.paths, 'codex');
    expect(Process.runSync('stat', ['-c', '%i', file()]).stdout, isNot(inode), reason: 'a new file renamed into place');
    expect(before.type, FileSystemEntityType.file);
    expect(stored(), {'helper': 'codex'});
  });

  test('a new folder made by the write is 0700 whatever the umask allows', () {
    expect(Directory(p.dirname(file())).existsSync(), isFalse);
    writeSharedHelper(w.paths, 'claude');
    expect(mode(p.dirname(file())), 0x1c0);
  });

  group('migration', () {
    test('no shared file: seeded once from the Manager\'s old ai_helper', () {
      w.writeFile(managerSettings(), jsonEncode({'ai_helper': 'codex', 'language': 'de'}));
      expect(seedSharedHelper(w.paths, Settings.load(w.paths)), isTrue);
      expect(stored(), {'helper': 'codex'});
      // never again: the shared file wins from now on
      writeSharedHelper(w.paths, 'auto');
      expect(seedSharedHelper(w.paths, Settings.load(w.paths)), isFalse);
      expect(sharedHelper(w.paths), 'auto');
    });

    test('an invalid or missing old value seeds nothing (auto)', () {
      expect(sharedHelper(w.paths), 'auto');
      expect(sharedHelperExists(w.paths), isFalse);
      w.writeFile(managerSettings(), jsonEncode({'ai_helper': '../x y'}));
      expect(sharedHelper(w.paths), 'auto');
      expect(sharedHelperExists(w.paths), isFalse);
    });

    test('an existing shared file (even broken) is never overwritten by the seed', () {
      w.writeFile(managerSettings(), jsonEncode({'ai_helper': 'codex'}));
      w.writeFile(file(), '{broken');
      expect(sharedHelper(w.paths), 'auto');
      expect(File(file()).readAsStringSync(), '{broken');
    });

    test('ai.helpers seeds it; ai.set_helper after an old value keeps the new choice', () async {
      w.writeFile(managerSettings(), jsonEncode({'ai_helper': 'codex'}));
      final core = w.core();
      expect((await core.call('ai.helpers'))['helper'], 'codex');
      await core.call('ai.set_helper', {'helper': 'auto'});
      expect((await core.call('ai.helpers'))['helper'], 'auto');
      expect(stored(), {'helper': 'auto'});
    });
  });

  group('web_search', () {
    test('missing, broken or not a boolean reads as false', () {
      expect(readSharedWebSearch(w.paths), isFalse);
      for (final text in ['', '{broken', '[]', '{}', '{"web_search": "true"}', '{"web_search": 1}', '{"web_search": null}', '{"web_search": false}']) {
        w.writeFile(file(), text);
        expect(readSharedWebSearch(w.paths), isFalse, reason: text);
      }
      w.writeFile(file(), '{"web_search": true}');
      expect(readSharedWebSearch(w.paths), isTrue);
    });

    test('write keeps the helper and unknown keys; the helper write keeps web_search', () {
      w.writeFile(file(), jsonEncode({'helper': 'codex', 'future': {'x': 1}}));
      writeSharedWebSearch(w.paths, true);
      expect(stored(), {'helper': 'codex', 'future': {'x': 1}, 'web_search': true});
      expect(mode(file()), 0x180);
      expect(mode(p.dirname(file())), 0x1c0);
      writeSharedHelper(w.paths, 'claude');
      expect(stored(), {'helper': 'claude', 'future': {'x': 1}, 'web_search': true});
      writeSharedWebSearch(w.paths, false);
      expect(stored(), {'helper': 'claude', 'future': {'x': 1}, 'web_search': false});
      expect(readSharedWebSearch(w.paths), isFalse);
    });

    test('only helpers with a web-only mode can do it (Claude Code)', () {
      expect(helperCanSearchWeb('claude'), isTrue);
      for (final other in [null, 'codex', 'pi:ollama/qwen3', 'hermes', 'nobody']) {
        expect(helperCanSearchWeb(other), isFalse, reason: '$other');
      }
    });

    test('ai.set_web_search writes it, ai.helpers returns it; bad values refused; the old helper is seeded first', () async {
      w.writeFile(managerSettings(), jsonEncode({'ai_helper': 'codex'}));
      final core = w.core();
      var h = await core.call('ai.helpers');
      expect(h['web_search'], isFalse);
      h = await core.call('ai.set_web_search', {'on': true});
      expect(h['web_search'], isTrue);
      expect(stored(), {'helper': 'codex', 'web_search': true});
      for (final bad in [null, 'true', 1]) {
        await expectLater(core.call('ai.set_web_search', {'on': bad}), throwsA(isA<RouteError>()), reason: '$bad');
      }
      h = await core.call('ai.set_web_search', {'on': false});
      expect(h['web_search'], isFalse);
      expect(stored(), {'helper': 'codex', 'web_search': false});
    });

    test('ai.helpers: whether the resolved helper can search the web, with a reason when not', () async {
      final core = w.core();
      var h = await core.call('ai.helpers');
      expect(h['chosen'], isNull);
      expect(h['web_search_supported'], isFalse);
      expect(h['web_search_reason'], isA<String>());
      w.fake('claude', 'exit 0');
      w.writeFile(p.join(w.home, '.claude/.credentials.json'), '{}');
      h = await core.call('ai.helpers');
      expect(h['chosen'], 'claude');
      expect(h['web_search_supported'], isTrue);
      expect(h['web_search_reason'], isNull);
      w.fake('cursor-agent', 'exit 0');
      h = await core.call('ai.set_helper', {'helper': 'cursor-agent'});
      expect(h['chosen'], 'cursor-agent');
      expect(h['web_search_supported'], isFalse);
      expect(h['web_search_reason'], contains('Claude Code'));
    });
  });

  test('fallback to auto: a chosen helper that isn\'t ready', () {
    expect(resolveHelper('auto', ['claude', 'codex']), 'claude');
    expect(resolveHelper('codex', ['claude', 'codex']), 'codex');
    expect(resolveHelper('grok', ['claude', 'codex']), 'claude');
    expect(resolveHelper('codex', const []), isNull);
  });
}
