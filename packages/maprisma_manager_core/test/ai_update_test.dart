import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:maprisma_manager_core/maprisma_manager_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

Map<String, dynamic> status(String id, {String state = 'installed', bool here = true}) => {
  'id': id,
  'state': state,
  'supportedHere': here,
  'updates': {'sourceDiffers': false, 'upstreamNew': 0},
  'versions': {},
  'repos': [],
};

/// Polls ai.get until the run ends.
Future<Map<String, dynamic>> settle(CoreService core) async {
  for (var i = 0; i < 400; i++) {
    final run = (await core.call('ai.get'))['run'] as Map<String, dynamic>;
    if (run['state'] != 'running') return run;
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  throw StateError('the AI run did not end');
}

void main() {
  late World w;
  late CoreService core;

  setUp(() {
    w = World.create();
    // a signed-in Claude Code: on PATH, with a credentials file
    w.fake('claude', 'exit 0');
    w.writeFile(p.join(w.home, '.claude/.credentials.json'), '{}');
    core = w.core();
    core.ai.readApps = () async => [status('wlan'), status('manager'), status('maprisma'), status('hue', state: 'absent')];
  });
  tearDown(() => w.dispose());

  test('parseAnswer takes the JSON object out of words or a code fence', () {
    expect(parseAnswer('Sure:\n```json\n{"say": "hi", "actions": []}\n```'), {'say': 'hi', 'actions': []});
    expect(parseAnswer('no json here'), isNull);
    expect(parseAnswer('[1, 2]'), isNull);
  });

  test('the Manager itself, pacman apps and apps not installed are not the AI\'s', () {
    expect(appFacts(status('wlan'))['ai_may_act'], true);
    expect(appFacts(status('manager'))['ai_may_act'], false);
    expect(appFacts(status('maprisma'))['ai_may_act'], false);
    expect(appFacts(status('hue', state: 'absent'))['ai_may_act'], false);
    expect(appFacts(status('wlan', here: false))['ai_may_act'], false);
  });

  test('settings: off by default; ai_updates and ai_helper are saved; helpers lists Claude Code ready', () async {
    var s = await core.call('settings.get');
    expect(s['ai_updates'], false);
    expect(s['ai_helper'], isNull);
    await core.call('settings.set', {'key': 'ai_updates', 'value': true});
    await core.call('settings.set', {'key': 'ai_helper', 'value': 'claude'});
    expect(() => core.call('settings.set', {'key': 'ai_helper', 'value': '../x y'}), throwsA(isA<RouteError>()));
    s = await core.call('settings.get');
    expect(s['ai_updates'], true);
    expect(s['ai_helper'], 'claude');
    final h = await core.call('ai.helpers');
    expect(h['enabled'], true);
    expect(h['chosen'], 'claude');
    expect((h['helpers'] as List).firstWhere((x) => x['id'] == 'claude')['signed_in'], true);
  });

  test('ai.start is refused while the setting is off', () async {
    await expectLater(core.call('ai.start'), throwsA(isA<RouteError>().having((e) => e.code, 'code', 'off')));
  });

  test('steps outside the list, for blocked apps or unknown apps are refused, nothing runs', () async {
    await core.call('settings.set', {'key': 'ai_updates', 'value': true});
    final prompts = <String>[];
    var round = 0;
    core.ai.ask = (helper, prompt) async {
      prompts.add(prompt);
      round++;
      if (round == 1) {
        return jsonEncode({
          'say': 'Trying',
          'actions': [
            {'do': 'shell', 'app': 'wlan'},
            {'do': 'update', 'app': 'manager'},
            {'do': 'update', 'app': 'maprisma'},
            {'do': 'update', 'app': 'hue'},
            {'do': 'update', 'app': 'nope'},
          ],
          'done': false,
        });
      }
      return jsonEncode({'say': 'Nothing more', 'actions': [], 'done': true});
    };
    await core.call('ai.start');
    final run = await settle(core);
    expect(run['state'], 'succeeded');
    final steps = (run['steps'] as List).cast<Map<String, dynamic>>();
    final refused = steps.where((s) => s['kind'] == 'action').toList();
    expect(refused, hasLength(5));
    expect(refused.every((s) => s['ok'] == false), isTrue);
    expect(prompts, hasLength(2));
    expect(prompts[1], contains('"result": "refused"'));
    expect(prompts[0], contains('"id": "wlan"'));
    // the run is recorded
    expect(Directory(p.join(w.paths.managerState, 'ai')).listSync(), hasLength(1));
  });

  test('pub_get runs flutter pub get in the app\'s Flutter packages, not in build output', () async {
    await core.call('settings.set', {'key': 'ai_updates', 'value': true});
    final repo = p.join(w.projects, 'maprisma-wlan-monitor');
    w.writeFile(p.join(repo, 'flutter_app/pubspec.yaml'), 'name: x\ndependencies:\n  flutter:\n    sdk: flutter\n');
    w.writeFile(p.join(repo, 'packages/core/pubspec.yaml'), 'name: core\n');
    w.writeFile(p.join(repo, 'flutter_app/build/x/pubspec.yaml'), 'name: built\n');
    final calls = p.join(w.dir, 'calls');
    w.fake('flutter', 'echo "flutter \$* in \$PWD" >> $calls');
    w.fake('dart', 'echo "dart \$* in \$PWD" >> $calls');
    var round = 0;
    core.ai.ask = (helper, prompt) async => ++round == 1
        ? jsonEncode({'say': 'Packages first', 'actions': [{'do': 'pub_get', 'app': 'wlan'}], 'done': false})
        : jsonEncode({'say': 'Done', 'actions': [], 'done': true});
    await core.call('ai.start');
    final run = await settle(core);
    expect(run['state'], 'succeeded');
    final lines = File(calls).readAsLinesSync();
    expect(lines, ['flutter pub get in $repo/flutter_app', 'dart pub get in $repo/packages/core']);
    final step = (run['steps'] as List).cast<Map<String, dynamic>>().firstWhere((s) => s['kind'] == 'action');
    expect(step['state'], 'succeeded');
  });

  test('the same step runs at most twice; an unreadable answer ends the run as failed', () async {
    await core.call('settings.set', {'key': 'ai_updates', 'value': true});
    w.fake('flutter', 'exit 1');
    w.writeFile(p.join(w.projects, 'maprisma-wlan-monitor/flutter_app/pubspec.yaml'), 'name: x\n');
    core.ai.ask = (helper, prompt) async => jsonEncode({'say': 'again', 'actions': [{'do': 'pub_get', 'app': 'wlan'}], 'done': false});
    await core.call('ai.start');
    var run = await settle(core);
    final actions = (run['steps'] as List).cast<Map<String, dynamic>>().where((s) => s['kind'] == 'action').toList();
    expect(actions.where((s) => s['state'] == 'failed'), hasLength(2));
    expect(actions.skip(2).every((s) => s['ok'] == false), isTrue);

    core.ai.ask = (helper, prompt) async => 'I will just do it myself.';
    await core.call('ai.start');
    run = await settle(core);
    expect(run['state'], 'failed');
  });

  test('cancel stops a run waiting for its answer', () async {
    await core.call('settings.set', {'key': 'ai_updates', 'value': true});
    final answer = Completer<String>();
    core.ai.ask = (helper, prompt) => answer.future;
    await core.call('ai.start');
    await expectLater(core.call('ai.start'), throwsA(isA<RouteError>().having((e) => e.code, 'code', 'busy')));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await core.call('ai.cancel');
    answer.complete(jsonEncode({'actions': [{'do': 'update', 'app': 'wlan'}]}));
    final run = await settle(core);
    expect(run['state'], 'cancelled');
    expect((run['steps'] as List).where((s) => s['kind'] == 'action'), isEmpty);
  });

  test('pub_get skips a pub workspace member and waits for no job of the app', () async {
    await core.call('settings.set', {'key': 'ai_updates', 'value': true});
    final repo = p.join(w.projects, 'maprisma-wlan-monitor');
    w.writeFile(p.join(repo, 'pkg/pubspec.yaml'), 'name: x\nresolution: workspace\n');
    final calls = p.join(w.dir, 'calls');
    w.fake('flutter', 'echo "flutter \$*" >> $calls');
    var round = 0;
    core.ai.ask = (helper, prompt) async => ++round == 1
        ? jsonEncode({'actions': [{'do': 'pub_get', 'app': 'wlan'}]})
        : jsonEncode({'actions': [], 'done': true});
    await core.call('ai.start');
    final run = await settle(core);
    final step = (run['steps'] as List).cast<Map<String, dynamic>>().firstWhere((s) => s['kind'] == 'action');
    expect(step['state'], 'succeeded');
    expect(step['message'], contains('skipped (a pub workspace member)'));
    expect(File(calls).existsSync(), isFalse);
  });

  test('Stop ends a running pub get with everything it started', () async {
    await core.call('settings.set', {'key': 'ai_updates', 'value': true});
    w.writeFile(p.join(w.projects, 'maprisma-wlan-monitor/app/pubspec.yaml'), 'name: x\n');
    Link(p.join(w.fakeBin, 'sleep')).createSync(Process.runSync('sh', ['-c', 'command -v sleep']).stdout.toString().trim());
    final pidFile = p.join(w.dir, 'child.pid');
    // a child that would outlive a plain kill of the parent
    w.fake('flutter', 'sleep 60 & echo \$! > $pidFile; wait');
    core.ai.ask = (helper, prompt) async => jsonEncode({'actions': [{'do': 'pub_get', 'app': 'wlan'}]});
    await core.call('ai.start');
    for (var i = 0; i < 200 && !File(pidFile).existsSync(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    final child = int.parse(File(pidFile).readAsStringSync().trim());
    await core.call('ai.cancel');
    final run = await settle(core);
    expect(run['state'], 'cancelled');
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(Directory('/proc/$child').existsSync(), isFalse, reason: 'the whole group ended');
  });

  test('Stop while the apps are checked: the helper is never asked', () async {
    await core.call('settings.set', {'key': 'ai_updates', 'value': true});
    final status = Completer<List<Map<String, dynamic>>>();
    core.ai.readApps = () => status.future;
    var asked = false;
    core.ai.ask = (helper, prompt) async {
      asked = true;
      return '{}';
    };
    await core.call('ai.start');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await core.call('ai.cancel');
    status.complete([]);
    final run = await settle(core);
    expect(run['state'], 'cancelled');
    expect(asked, isFalse);
  });
}
