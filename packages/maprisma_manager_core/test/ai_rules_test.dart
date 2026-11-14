// The Ask AI rules (docs/ask-ai-rules.md): reading (restrictive when malformed), writing under the
// shared lock, the decision, and the log.
import 'dart:convert';
import 'dart:io';

import 'package:maprisma_manager_core/src/ai/rules.dart';
import 'package:maprisma_manager_core/src/ai/posix.dart';
import 'package:maprisma_manager_core/src/ai/shared_helper.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late World w;
  setUp(() => w = World.create());
  tearDown(() => w.dispose());
  File shared() => File(sharedAiFile(w.paths));
  void write(Object v) => shared()
    ..createSync(recursive: true)
    ..writeAsStringSync(jsonEncode(v));

  test('no file: everything allowed, level review', () {
    final r = readAskAiRules(w.paths);
    expect(r.level, 'review');
    expect(r.broken, isFalse);
    expect(askAiAllowed(w.paths, 'launcher.remove'), isTrue);
    expect(askAiAllowed(w.paths, 'launcher.install', source: 'aur'), isTrue);
  });

  test('switches, sources and the Downloads folder decide; answers switches all off', () {
    write({
      'helper': 'auto',
      'ask_ai': {
        'level': 'review',
        'actions': {'launcher.remove': false},
        'sources': {'aur': false},
        'folders': {'downloads': false},
      },
    });
    expect(askAiAllowed(w.paths, 'launcher.remove'), isFalse);
    expect(askAiAllowed(w.paths, 'launcher.install', source: 'pacman'), isTrue);
    expect(askAiAllowed(w.paths, 'launcher.install', source: 'aur'), isFalse);
    expect(askAiAllowed(w.paths, 'launcher.install', source: 'local'), isFalse); // downloads off
    write({'ask_ai': {'level': 'answers'}});
    expect(askAiAllowed(w.paths, 'theme.apply'), isFalse);
  });

  test('malformed is restrictive and reported', () {
    write({'ask_ai': 'off'});
    expect(readAskAiRules(w.paths).level, 'answers');
    write({'ask_ai': {'actions': {'launcher.remove': 'false'}}});
    expect(askAiAllowed(w.paths, 'launcher.remove'), isFalse);
    expect(readAskAiRules(w.paths).broken, isTrue);
    write({'ask_ai': {'sources': ['aur']}});
    expect(askAiAllowed(w.paths, 'launcher.install', source: 'pacman'), isFalse);
    write({'ask_ai': {'actions': null}}); // null isn't an object: restrictive, like the apps
    expect(askAiAllowed(w.paths, 'launcher.install'), isFalse);
    write({'ask_ai': null});
    expect(readAskAiRules(w.paths).level, 'answers');
    write({'ask_ai': {'level': 'yolo'}});
    expect(readAskAiRules(w.paths).level, 'answers');
    shared().writeAsStringSync('{not json');
    expect(readAskAiRules(w.paths).broken, isTrue);
    expect(askAiAllowed(w.paths, 'theme.apply'), isFalse);
  });

  test('a switch keeps the other keys; a broken file is never rewritten, only reset', () {
    write({'helper': 'claude', 'web_search': true});
    writeAskAiRule(w.paths, kind: 'actions', id: 'launcher.remove', on: false);
    writeAskAiRule(w.paths, level: 'answers');
    final v = jsonDecode(shared().readAsStringSync()) as Map;
    expect(v['helper'], 'claude');
    expect(v['web_search'], isTrue);
    expect((v['ask_ai'] as Map)['actions'], {'launcher.remove': false});
    expect((v['ask_ai'] as Map)['level'], 'answers');
    expect(() => writeAskAiRule(w.paths, kind: 'actions', id: 'nope', on: false), throwsArgumentError);
    shared().writeAsStringSync('{broken');
    expect(() => writeAskAiRule(w.paths, level: 'review'), throwsA(isA<FileSystemException>()));
    expect(() => writeSharedHelper(w.paths, 'auto'), throwsA(isA<FileSystemException>()));
    expect(shared().readAsStringSync(), '{broken');
    resetAskAiRules(w.paths);
    expect(readAskAiRules(w.paths).broken, isFalse);
    expect(Directory(p.dirname(shared().path)).listSync().where((e) => e.path.contains('.broken-')), hasLength(1));
  });

  test('the log: appended, newest first, trimmed, cleared; private', () {
    for (var i = 0; i < askAiLogMax + 5; i++) {
      appendAskAiLog(w.paths, op: 'op$i', app: 'launcher', action: 'launcher.install', target: 'x$i', result: 'started');
    }
    final entries = readAskAiLog(w.paths, limit: 3);
    expect([for (final e in entries) e['op']], ['op1004', 'op1003', 'op1002']);
    final lines = File(askAiLogFile(w.paths)).readAsLinesSync();
    expect(lines.length, lessThanOrEqualTo(askAiLogKeep + 5));
    expect(File(askAiLogFile(w.paths)).statSync().mode & 0x1ff, 0x180);
    expect(readAskAiLog(w.paths).first['target'], 'x1004');
    clearAskAiLog(w.paths);
    expect(readAskAiLog(w.paths), isEmpty);
  });

  test('ai.rules view: effective state follows the level', () {
    write({'ask_ai': {'level': 'answers', 'actions': {'theme.apply': false}}});
    final v = askAiRulesView(w.paths);
    final apply = (v['actions'] as List).firstWhere((a) => a['id'] == 'theme.apply') as Map;
    final install = (v['actions'] as List).firstWhere((a) => a['id'] == 'launcher.install') as Map;
    expect(apply['on'], isFalse);
    expect(install['on'], isTrue);
    expect(install['effective'], isFalse);
  });
  test('nested edits preserve unknown and malformed fields', () {
    write({'ask_ai': {'future': {'x': 1}, 'actions': {'unknown': null, 'theme.apply': 'bad'}}});
    writeAskAiRule(w.paths, kind: 'actions', id: 'launcher.remove', on: false);
    final rules = (jsonDecode(shared().readAsStringSync()) as Map)['ask_ai'] as Map;
    expect(rules['future'], {'x': 1});
    expect(rules['actions'], {'unknown': null, 'theme.apply': 'bad', 'launcher.remove': false});
    expect(askAiAllowed(w.paths, 'theme.apply'), isFalse);
  });

  test('view distinguishes partial damage and dependent local source', () {
    write({'ask_ai': {'actions': {'theme.apply': null}, 'folders': {'downloads': false}}});
    final view = askAiRulesView(w.paths);
    expect(view['broken'], isTrue);
    expect(view['answers_only_error'], isFalse);
    expect((view['sources'] as List).firstWhere((i) => i['id'] == 'local')['effective'], isFalse);
    expect(askAiAllowed(w.paths, 'launcher.remove'), isTrue);
    write({'ask_ai': null});
    expect(askAiRulesView(w.paths)['answers_only_error'], isTrue);
  });

  test('append repairs incomplete tails and tolerates invalid UTF8 during rotation', () {
    final log = File(askAiLogFile(w.paths))..createSync(recursive: true);
    log.writeAsBytesSync([255, 10, ...utf8.encode('{"time":')]);
    appendAskAiLog(w.paths, op: 'recovered', app: 'settings', action: 'settings.updates', target: 'x', result: 'done');
    expect(readAskAiLog(w.paths).single['op'], 'recovered');
    log.writeAsBytesSync([...List.filled(askAiLogBytes + 1, 255), 10]);
    expect(() => appendAskAiLog(w.paths, op: 'rotated', app: 'settings', action: 'settings.updates', target: 'x', result: 'done'), returnsNormally);
    expect(readAskAiLog(w.paths).first['op'], 'rotated');
  });

  test('append and clear refuse symlink data files', () {
    final log = File(askAiLogFile(w.paths));
    log.parent.createSync(recursive: true);
    final target = File(p.join(w.paths.state, 'untouched'))..writeAsStringSync('keep');
    Link(log.path).createSync(target.path);
    appendAskAiLog(w.paths, op: 'x', app: 'settings', action: 'settings.updates', target: 'x', result: 'done');
    clearAskAiLog(w.paths);
    expect(target.readAsStringSync(), 'keep');
  });

  test('locks reject special files and links and correct regular file permissions', () {
    final lock = File(sharedAiLock(w.paths));
    lock.parent.createSync(recursive: true);
    lock.writeAsStringSync('');
    chmodPath(lock.path, 0x1ff);
    expect(Posix.instance.withFlock(lock.path, () => 42), 42);
    expect(lock.statSync().mode & 0x1ff, 0x180);
    lock.deleteSync();
    final target = File('${lock.path}.target')..writeAsStringSync('keep');
    Link(lock.path).createSync(target.path);
    expect(() => Posix.instance.withFlock(lock.path, () => fail('called')), throwsA(isA<FileSystemException>()));
    Link(lock.path).deleteSync();
    expect(Process.runSync('mkfifo', [lock.path]).exitCode, 0);
    expect(() => Posix.instance.withFlock(lock.path, () => fail('called')), throwsA(isA<FileSystemException>()));
    expect(target.readAsStringSync(), 'keep');
  });

}
