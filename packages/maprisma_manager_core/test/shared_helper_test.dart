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
  String managerSettings() => p.join(w.home, '.config/maprisma-manager/settings.json');
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

  test('fallback to auto: a chosen helper that isn\'t ready', () {
    expect(resolveHelper('auto', ['claude', 'codex']), 'claude');
    expect(resolveHelper('codex', ['claude', 'codex']), 'codex');
    expect(resolveHelper('grok', ['claude', 'codex']), 'claude');
    expect(resolveHelper('codex', const []), isNull);
  });
}
