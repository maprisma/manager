// The Ask AI rules (docs/ask-ai-rules.md): reading (restrictive when malformed), writing under the
// shared lock, the decision, and the log.
import 'dart:convert';
import 'dart:io';

import 'package:maprisma_manager_core/src/ai/rules.dart';
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
}
