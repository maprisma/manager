import 'dart:convert';
import 'dart:io';

import 'package:maprisma_manager_core/src/ai/ask_ai.dart';
import 'package:maprisma_manager_core/src/ai/helpers_catalog.dart';
import 'package:maprisma_manager_core/src/ai/helpers_shipped.g.dart';
import 'package:maprisma_manager_core/src/ai/posix.dart' show which;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

String catalogText(int version, List<Object?> helpers) => jsonEncode({'version': version, 'helpers': helpers});

Map<String, Object?> entry(String id, {List<Object?>? argv, bool stdin = false, bool verified = false, Object? ask = const {}}) => {
  'id': id,
  'name': id.toUpperCase(),
  'command': id,
  'ask': ask == null ? null : {'argv': argv ?? [id, '-p', '{prompt}'], 'stdin': stdin},
  'task': {'argv': [id, '{prompt}']},
  'verified': verified,
};

void main() {
  final root = Directory.current.path.endsWith('maprisma_manager_core') ? '.' : 'packages/maprisma_manager_core';
  late World w;
  late String saved;
  setUp(() {
    w = World.create();
    saved = systemHelpersCatalog;
    systemHelpersCatalog = p.join(w.root, 'usr/lib/maprisma/data/helpers.json');
  });
  tearDown(() {
    systemHelpersCatalog = saved;
    w.dispose();
  });

  test('the shipped catalog is data/helpers.json, built in; 13 agents, Claude Code first', () {
    expect(jsonDecode(shippedHelpersJson), jsonDecode(File('$root/data/helpers.json').readAsStringSync()), reason: 'run tools/gen-helpers');
    final c = shippedHelpersCatalog;
    expect(c.version, greaterThanOrEqualTo(1));
    final ids = [for (final h in c.helpers) h.id];
    expect(ids.take(2), ['claude', 'codex']);
    expect(ids, containsAll(['gemini', 'agy', 'cursor-agent', 'copilot', 'grok', 'hermes', 'omp', 'openclaw', 'pi']));
    // no `ask`: not a one-shot helper
    expect(ids, isNot(contains('opencode')));
    expect(ids, isNot(contains('goose')));
    expect(c.helpers.firstWhere((h) => h.id == 'gemini').verified, isFalse);
    expect(c.helpers.firstWhere((h) => h.id == 'claude').verified, isTrue);
  });

  test('catalog parse: broken entries and repeated ids are left out; not a catalog is null', () {
    final c = parseHelpersCatalog(catalogText(3, [
      entry('good', verified: true),
      entry('noask', ask: null),
      {'id': 'nocmd', 'ask': {'argv': ['x', '{prompt}']}},
      entry('../evil'),
      {'id': 'path', 'command': '/bin/sh', 'ask': {'argv': ['/bin/sh', '{prompt}']}},
      entry('noprompt', argv: ['noprompt', '-p']),
      entry('first', argv: ['{prompt}']),
      entry('other', argv: ['sh', '-c', '{prompt}']),
      entry('nums', argv: ['nums', 3, '{prompt}']),
      entry('nul', argv: ['nul', 'a\x00b', '{prompt}']),
      entry('empty', argv: []),
      entry('piped', argv: ['piped', '-'], stdin: true),
      {'id': 'good', 'command': 'again', 'ask': {'argv': ['again', '{prompt}']}},
      'garbage',
      {'id': 'noname', 'command': 'noname', 'ask': {'argv': ['noname', '--p={prompt}']}},
    ]))!;
    expect(c.version, 3);
    expect([for (final h in c.helpers) h.id], ['good', 'piped', 'noname']);
    expect(c.helpers[0].verified, isTrue);
    expect(c.helpers[1].stdin, isTrue);
    expect(c.helpers[2].name, 'noname');
    expect(c.helpers[2].verified, isFalse, reason: 'verified only when it says so');
    for (final bad in ['', '[]', '{}', '{"version": "1", "helpers": []}', '{"version": 1}', '{"version": 1, "helpers": {}}']) {
      expect(parseHelpersCatalog(bad), isNull, reason: bad);
    }
    expect(parseHelpersCatalog('{"version": 1, "helpers": []}')!.helpers, isEmpty);
  });

  test("Maprisma's installed catalog wins when it parses and is at least as new", () {
    final shipped = shippedHelpersCatalog;
    expect(helpersCatalog().version, shipped.version, reason: 'no installed one: the shipped');
    w.writeFile(systemHelpersCatalog, catalogText(shipped.version, [entry('newer')]));
    expect([for (final h in helpersCatalog().helpers) h.id], ['newer'], reason: 'a tie: the installed one');
    w.writeFile(systemHelpersCatalog, catalogText(shipped.version + 1, [entry('newest')]));
    expect([for (final h in helpersCatalog().helpers) h.id], ['newest']);
    w.writeFile(systemHelpersCatalog, catalogText(shipped.version - 1, [entry('older')]));
    expect(helpersCatalog().helpers.first.id, 'claude', reason: 'older: the shipped one');
    w.writeFile(systemHelpersCatalog, 'not json {');
    expect(helpersCatalog().helpers.first.id, 'claude', reason: 'broken: the shipped one');
  });

  test('detection: PATH, ~/.local/bin, ~/.npm-global/bin, else mise which; never run otherwise', () async {
    final env = {'PATH': w.fakeBin};
    expect(await findHelperCommand('gemini', w.home, env), isNull);
    w.writeFile(p.join(w.home, '.npm-global/bin/copilot'), '#!/bin/sh\n', mode: '755');
    expect(await findHelperCommand('copilot', w.home, env), p.join(w.home, '.npm-global/bin/copilot'));
    w.writeFile(p.join(w.home, '.local/bin/agy'), '#!/bin/sh\n', mode: '755');
    expect(await findHelperCommand('agy', w.home, env), p.join(w.home, '.local/bin/agy'));
    w.writeFile(p.join(w.home, '.local/bin/notexec'), '#!/bin/sh\n', mode: '644');
    expect(await findHelperCommand('notexec', w.home, env), isNull);
    // mise knows gemini: its path is used; mise is only asked `which`, nothing is installed
    final gemini = p.join(w.dir, 'mise-installs/gemini');
    w.writeFile(gemini, '#!/bin/sh\necho ran > "${w.dir}/gemini-ran"\n', mode: '755');
    w.fake('mise', 'echo "\$@" >> "${w.dir}/mise-args"\n[ "\$1" = which ] && [ "\$2" = gemini ] && echo "$gemini" && exit 0\nexit 1');
    expect(await findHelperCommand('gemini', w.home, env), isNull, reason: 'mise is asked only about a command it has a shim for');
    expect(File('${w.dir}/mise-args').existsSync(), isFalse);
    for (final c in ['gemini', 'grok']) {
      w.writeFile(p.join(w.home, '.local/share/mise/shims', c), '', mode: '755');
    }
    expect(await findHelperCommand('gemini', w.home, env), gemini);
    expect(await findHelperCommand('grok', w.home, env), isNull);
    expect(File('${w.dir}/mise-args').readAsLinesSync(), ['which gemini', 'which grok']);
    expect(miseShims(w.home, {'MISE_DATA_DIR': '/m'}), '/m/shims');
    expect(miseShims(w.home, {'XDG_DATA_HOME': '/x'}), '/x/mise/shims');
    expect(File('${w.dir}/gemini-ran').existsSync(), isFalse);
    // mise naming something that isn't a program
    w.fake('mise', 'echo relative/path');
    expect(await findHelperCommand('gemini', w.home, env), isNull);
    expect(await findHelperCommand('../x', w.home, env), isNull);
    // on PATH first
    w.fake('gemini', 'exit 0');
    expect(await findHelperCommand('gemini', w.home, env), p.join(w.fakeBin, 'gemini'));
  });

  test('argv: the prompt as ONE element, never an option, NULs dropped; stdin entries drop it', () {
    final c = parseHelpersCatalog(catalogText(1, [
      entry('a', argv: ['a', '-p', '{prompt}', '--x', 'y']),
      entry('b', argv: ['b', '--prompt={prompt}', '--q']),
      entry('s', argv: ['s', '-p', '{prompt}', '-'], stdin: true),
    ]))!.helpers;
    const odd = 'two words; \$(rm -rf ~) `x` "q" \'s\'\nnew line * ?';
    expect(catalogAskArgv(c[0], '/bin/a', odd), ['/bin/a', '-p', odd, '--x', 'y']);
    expect(catalogAskArgv(c[0], '/bin/a', '--help me'), ['/bin/a', '-p', ' --help me', '--x', 'y']);
    expect(catalogAskArgv(c[0], '/bin/a', 'a\x00b'), ['/bin/a', '-p', 'ab', '--x', 'y']);
    expect(catalogAskArgv(c[0], '/bin/a', '{prompt}'), ['/bin/a', '-p', '{prompt}', '--x', 'y']);
    expect(catalogAskArgv(c[1], '/bin/b', '-x {prompt}'), ['/bin/b', '--prompt=-x {prompt}', '--q']);
    expect(catalogAskArgv(c[2], '/bin/s', 'hi'), ['/bin/s', '-p', '-']);
  });

  test('the helpers: catalog order; Claude Code, Codex, pi and Hermes keep their own argv and handling', () {
    final list = helpersFrom(shippedHelpersCatalog);
    final ids = [for (final h in list) h.id];
    expect(ids.take(4), ['claude', 'codex', 'gemini', 'agy']);
    expect(ids, containsAll(['cursor-agent', 'copilot', 'grok', 'omp', 'openclaw', 'pi', 'hermes']));
    expect(ids.indexOf('hermes'), lessThan(ids.indexOf('pi')));
    final claude = list.firstWhere((h) => h.id == 'claude'), codex = list.firstWhere((h) => h.id == 'codex');
    final pi = list.firstWhere((h) => h.id == 'pi'), hermes = list.firstWhere((h) => h.id == 'hermes');
    for (final own in [claude, codex, pi, hermes]) {
      expect(own.catalog, isNull, reason: own.id);
      expect(own.verified, isTrue, reason: '${own.id}: tested with its own argv');
    }
    expect(claude.argv, containsAll(['--disable-slash-commands', '--strict-mcp-config']));
    expect(claude.argv, isNot(contains('{prompt}')), reason: 'its prompt goes on stdin');
    expect(claude.web, isNotNull);
    expect(codex.jail, isNotNull);
    expect(codex.argv, containsAll(['--ignore-user-config', '--output-last-message', '{answer}']));
    expect(pi.argv, contains('--no-context-files'));
    expect(hermes.argv, containsAll(['--query-file', '-']));
    final gemini = list.firstWhere((h) => h.id == 'gemini');
    expect(gemini.catalog, isNotNull);
    expect(gemini.verified, isFalse);
    expect(gemini.jail, isNull);
    expect(gemini.web, isNull);
    expect(gemini.argv.first, 'gemini');
    expect(gemini.env, contains('GEMINI_API_KEY'));
    // one of ours missing from a catalog is still offered, last
    final short = helpersFrom(parseHelpersCatalog(catalogText(1, [entry('gemini'), entry('codex')]))!);
    expect([for (final h in short) h.id], ['gemini', 'codex', 'claude', 'pi', 'hermes']);
  });

  test('helper states: a catalog agent is offered when installed, ready, marked untested', () async {
    w.fake('claude', 'exit 0');
    w.writeFile(p.join(w.home, '.local/bin/gemini'), '#!/bin/sh\n', mode: '755');
    final states = {for (final h in await helperStates(w.home, {'PATH': w.fakeBin})) h['id']: h};
    expect(states['gemini']!['installed'], isTrue);
    expect(states['gemini']!['signed_in'], isTrue);
    expect(states['gemini']!['verified'], isFalse);
    expect(states['gemini']!['name'], 'Gemini CLI');
    expect(states['claude']!['installed'], isTrue);
    expect(states['claude']!['signed_in'], isFalse, reason: 'its own sign-in check');
    expect(states['claude']!['verified'], isTrue);
    expect(states['grok']!['installed'], isFalse);
  });

  test('ai.helpers: a saved helper that is unknown or no longer installed falls back to the first ready', () async {
    w.writeFile(p.join(w.home, '.local/bin/copilot'), '#!/bin/sh\n', mode: '755');
    w.fake('gemini', 'exit 0');
    final core = w.core();
    for (final saved in ['nobody', 'grok', 'gemini', 'copilot', 'auto']) {
      await core.call('ai.set_helper', {'helper': saved});
      final h = await core.call('ai.helpers');
      expect(h['chosen'], saved == 'copilot' ? 'copilot' : 'gemini', reason: saved);
      expect(h['fallback'], saved == 'nobody' || saved == 'grok', reason: saved);
    }
  });

  test('Codex as a mise shim (not on PATH): the jail runs the real program mise names', () async {
    final real = p.join(w.dir, 'installs/codex/bin/codex');
    w.writeFile(real, '#!/bin/sh\n', mode: '755');
    w.fake('mise', '[ "\$1" = which ] && [ "\$2" = codex ] && echo "$real" && exit 0\nexit 1');
    w.fake('bwrap', 'exit 0');
    final shim = p.join(w.home, '.local/share/mise/shims/codex');
    Directory(p.dirname(shim)).createSync(recursive: true);
    Link(shim).createSync(p.join(w.fakeBin, 'mise'));
    final env = {'PATH': w.fakeBin};
    final found = await findHelperCommand('codex', w.home, env);
    expect(found, real, reason: 'found through mise which');
    final codex = helpers.firstWhere((h) => h.id == 'codex');
    final viaShim = await jailArgv(codex, [shim, 'exec', '-'], p.join(w.dir, 'work'), w.home, env);
    expect(viaShim.sublist(viaShim.indexOf('--') + 1), [real, 'exec', '-']);
  });

  group('running', () {
    final tools = which('setsid', Platform.environment) != null && which('prlimit', Platform.environment) != null;

    test('a catalog agent gets the prompt as its argument, empty stdin, and its stdout is the answer', () async {
      if (!tools) {
        markTestSkipped('util-linux missing');
        return;
      }
      w.fake('gemini', r'''
for a in "$@"; do printf '[%s]' "$a"; done > "$HOME/args"
cat > "$HOME/stdin"
pwd > "$HOME/where"
env > "$HOME/env"
echo "the answer"
''');
      final runner = AskRunner(home: w.home, environment: {'PATH': '${w.fakeBin}:/usr/bin:/bin', 'GEMINI_API_KEY': 'k', 'OPENAI_API_KEY': 'other'});
      const prompt = "-rf it's \"odd\"\n\$HOME `x`";
      expect(await runner.run('gemini', prompt), 'the answer\n');
      expect(File('${w.home}/args').readAsStringSync(), '[--approval-mode][default][-o][text][-p][ $prompt]');
      expect(File('${w.home}/stdin').readAsStringSync(), '');
      expect(File('${w.home}/where').readAsStringSync().trim(), isNot(w.home));
      final env = File('${w.home}/env').readAsStringSync();
      expect(env, contains('GEMINI_API_KEY=k'));
      expect(env, isNot(contains('OPENAI_API_KEY')));
    });

    test('a stdin entry gets it on stdin; a prompt too long for one argument is refused', () async {
      if (!tools) {
        markTestSkipped('util-linux missing');
        return;
      }
      w.writeFile(systemHelpersCatalog, catalogText(shippedHelpersCatalog.version, [entry('piped', argv: ['piped', '-'], stdin: true), entry('argy')]));
      w.fake('piped', 'cat');
      w.fake('argy', 'echo should not run > "\$HOME/ran"');
      final runner = AskRunner(home: w.home, environment: {'PATH': '${w.fakeBin}:/usr/bin:/bin'});
      expect(await runner.run('piped', 'hello'), 'hello');
      await expectLater(runner.run('argy', 'x' * (argvPromptMax + 1)), throwsA(isA<AskError>().having((e) => e.message, 'message', contains('too long'))));
      expect(File('${w.home}/ran').existsSync(), isFalse);
    });

    test('Claude Code still gets its prompt on stdin with its own flags', () async {
      if (!tools) {
        markTestSkipped('util-linux missing');
        return;
      }
      w.fake('claude', r'''
for a in "$@"; do printf '[%s]' "$a"; done > "$HOME/args"
cat > "$HOME/stdin"
echo ok
''');
      final runner = AskRunner(home: w.home, environment: {'PATH': '${w.fakeBin}:/usr/bin:/bin'});
      expect(await runner.run('claude', 'the prompt'), 'ok\n');
      expect(File('${w.home}/stdin').readAsStringSync(), 'the prompt');
      final args = File('${w.home}/args').readAsStringSync();
      expect(args, contains('[--disable-slash-commands]'));
      expect(args, isNot(contains('the prompt')));
    });

    test('a helper in ~/.local/bin only (not on PATH) runs too', () async {
      if (!tools) {
        markTestSkipped('util-linux missing');
        return;
      }
      w.writeFile(p.join(w.home, '.local/bin/grok'), '#!/bin/sh\necho grok said\n', mode: '755');
      final runner = AskRunner(home: w.home, environment: {'PATH': '${w.fakeBin}:/usr/bin:/bin'});
      expect(await runner.run('grok', 'hi'), 'grok said\n');
    });
  });
}
