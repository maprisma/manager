// The Voice page's core (voice.*) against a fake `maprisma-voice` on PATH: it is only ever run
// with argv lists, settings go through `set KEY <JSON>`, a download and a try run in the
// background with progress, partial text and Cancel. Nothing touches the real config.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:maprisma_manager_core/maprisma_manager_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'fakes.dart';
import 'support.dart';

/// The fake: answers from `$HOME/voice/*`, every call logged to `$HOME/voice.log` (one JSON
/// argv per line). `$HOME/voice/slow` makes a download wait for `$HOME/voice/go`.
const _fake = r'''#!/usr/bin/python3 -I
import json, os, sys, time
home = os.environ['HOME']
d = os.path.join(home, 'voice')
a = sys.argv[1:]
with open(os.path.join(home, 'voice.log'), 'a') as f:
    f.write(json.dumps(a) + '\n')
def read(name, default=None):
    path = os.path.join(d, name)
    return open(path).read() if os.path.exists(path) else default
if a[:1] == ['status']:
    s = read('status.json')
    if s is None:
        sys.stderr.write('The voice service is not running. (no bus)\n'); sys.exit(4)
    print(s); sys.exit(0)
if a == ['models', '--json']:
    print(read('models.json', '{"catalog": [], "models": [], "active": null}')); sys.exit(0)
if a == ['get']:
    print(read('settings.json', '{}')); sys.exit(0)
if a[:1] == ['set']:
    if a[1] == 'language' and a[2] == '"xx"':
        sys.stderr.write('language: not a Whisper language code\n'); sys.exit(2)
    sys.exit(0)
if a[:1] == ['unset']:
    sys.exit(0)
if a[:2] == ['model', 'download']:
    if a[2] == 'bad':
        sys.stderr.write('##   3.0%\rthe download failed (exit status: 22)\n'); sys.exit(1)
    for pct in ('10.0', '45.5'):
        sys.stderr.write('#' * int(float(pct) / 5) + ' ' + pct + '%\r'); sys.stderr.flush(); time.sleep(0.05)
    while os.path.exists(os.path.join(d, 'slow')) and not os.path.exists(os.path.join(d, 'go')):
        time.sleep(0.05)
    print(os.path.join(home, '.local/share/maprisma-voice/models/ggml-' + a[2] + '.bin')); sys.exit(0)
if a[:2] == ['model', 'remove']:
    sys.exit(0)
if a[:1] == ['dictate']:
    sys.stderr.write('Listening for ' + a[2] + ' s…\n'); sys.stderr.flush()
    if os.path.exists(os.path.join(d, 'nospeech')):
        sys.stderr.write('No speech was heard.\n'); sys.exit(3)
    sys.stderr.write('… hello\n'); sys.stderr.flush()
    while os.path.exists(os.path.join(d, 'slow')) and not os.path.exists(os.path.join(d, 'go')):
        time.sleep(0.05)
    sys.stderr.write('… hello world\n')
    print('Hello world.'); sys.exit(0)
sys.exit(2)
''';

const _status = {
  'enabled': true, 'ready': true, 'why_not': '', 'message': 'Ready', 'engine': 'whisper', 'engine_setting': 'auto',
  'engines': ['whisper'], 'model': 'ggml-base.bin', 'models': ['ggml-base.bin'], 'language': 'auto', 'microphone': 'default',
  'state': 'idle', 'version': '0.1.0',
};

void main() {
  late World w;
  setUp(() {
    w = World.create();
    fakePactl(w);
  });
  tearDown(() => w.dispose());

  void installFake({String? where}) => w.writeFile(where ?? p.join(w.fakeBin, 'maprisma-voice'), _fake, mode: '755');
  void answer(String name, Object value) => w.writeFile(p.join(w.home, 'voice', name), value is String ? value : jsonEncode(value));
  List<List<String>> calls() {
    final f = File(p.join(w.home, 'voice.log'));
    return f.existsSync() ? [for (final l in f.readAsLinesSync()) (jsonDecode(l) as List).cast<String>()] : const [];
  }

  Matcher refused(String code) => throwsA(isA<RouteError>().having((e) => e.code, 'code', code));

  Future<Map<String, dynamic>> settle(CoreService core, String kind) async {
    for (var i = 0; i < 200; i++) {
      final t = (await core.call('voice.tasks'))[kind] as Map<String, dynamic>?;
      if (t != null && t['state'] != 'running') return t;
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    fail('$kind did not end');
  }

  test('the catalog entry: Maprisma Dictation, its bar icon, install.sh', () {
    final a = findApp('dictation')!;
    expect(a.name, 'Maprisma Dictation');
    expect(a.inputs.single.repo, 'maprisma-dictation');
    expect(a.inputs.single.github, 'maprisma/dictation');
    expect(a.components.single.install, ['./install.sh']);
    expect(a.components.single.paths.where((x) => x.key).single.path, '{bin}/maprisma-voice');
    expect(a.open, ['{bin}/maprisma-dictation', '--toggle']);
    // The bar icon toggles the overlay: a COSMIC applet, the SNI tray on KDE and Hyprland.
    expect(a.bar.cosmicApplet, 'io.github.ubruckhaus.CosmicMaprismaDictation');
    expect(a.bar.cosmicAppletExe, '{bin}/maprisma-dictation-applet');
    expect(a.bar.kdeId, 'maprisma-dictation');
    expect(a.bar.kdeKind, KdeBarKind.tray);
    expect(a.bar.kdeAutostart, '{autostart}/io.github.ubruckhaus.CosmicMaprismaDictation.Tray.desktop');
    expect(a.bar.kdeTrayExe, '{bin}/maprisma-dictation-tray');
    expect(a.bar.iconName, 'io.github.ubruckhaus.CosmicMaprismaDictation-symbolic');
    expect(hyprBarId(a), 'tray:maprisma-dictation');
    final paths = a.components.single.paths.map((x) => x.path);
    expect(paths, containsAll([
      '{bin}/maprisma-dictation',
      '{bin}/maprisma-dictation-applet',
      '{bin}/maprisma-dictation-tray',
      '{apps}/io.github.ubruckhaus.CosmicMaprismaDictation.desktop',
      '{autostart}/io.github.ubruckhaus.CosmicMaprismaDictation.Tray.desktop',
      '{icons}/io.github.ubruckhaus.CosmicMaprismaDictation-symbolic.svg',
    ]));
    expect(a.processes.map((m) => m.path), containsAll(['{bin}/maprisma-voice', '{bin}/maprisma-dictation', '{bin}/maprisma-dictation-applet', '{bin}/maprisma-dictation-tray']));
    expect(a.units.single.name, 'maprisma-voice.service');
  });

  test('not installed: the page says where to get it; the microphones are listed anyway', () async {
    final r = await w.core().call('voice.get');
    expect(r['installed'], isFalse);
    expect(r['install_url'], 'https://github.com/maprisma/dictation');
    expect([for (final s in (r['microphones'] as Map)['sources'] as List) s['name']], ['mic']);
    await expectLater(w.core().call('voice.set', {'key': 'enabled', 'value': false}), refused('not_installed'));
    await expectLater(w.core().call('voice.try', {}), refused('not_installed'));
  });

  test('installed: status, models, settings and microphones in one answer', () async {
    installFake();
    answer('status.json', _status);
    answer('models.json', {'active': 'ggml-base.bin', 'catalog': [{'id': 'base', 'file': 'ggml-base.bin', 'installed': true}], 'models': []});
    answer('settings.json', {'language': 'de'});
    final r = await w.core().call('voice.get');
    expect(r['installed'], isTrue);
    expect(r['binary'], p.join(w.fakeBin, 'maprisma-voice'));
    expect((r['status'] as Map)['ready'], isTrue);
    expect(r['status_error'], isNull);
    expect((r['models'] as Map)['active'], 'ggml-base.bin');
    expect(r['settings'], {'language': 'de'});
    expect((r['microphones'] as Map)['default'], isNotNull);
    expect(r['tasks'], {'download': null, 'dictate': null});
    expect(calls(), containsAll([
      ['status', '--json'],
      ['models', '--json'],
      ['get'],
    ]));
  });

  test('~/.local/bin/maprisma-voice comes before PATH', () async {
    installFake();
    final own = p.join(w.home, '.local/bin/maprisma-voice');
    installFake(where: own);
    expect(VoiceService(w.core().ctx, SoundService(w.core().ctx)).binary(), own);
  });

  test('the service not running: the status says why', () async {
    installFake();
    final r = await w.core().call('voice.get');
    expect(r['status'], isNull);
    expect(r['status_error'], 'The voice service is not running. (no bus)');
  });

  test('set passes the value as JSON; the service refuses wrong ones; unknown keys never reach it', () async {
    installFake();
    final core = w.core();
    await core.call('voice.set', {'key': 'enabled', 'value': false});
    await core.call('voice.set', {'key': 'language', 'value': 'de'});
    await core.call('voice.set', {'key': 'unload_minutes', 'value': 30});
    await core.call('voice.set', {'key': 'microphone', 'value': 'alsa_input.usb-Mic'});
    await core.call('voice.unset', {'key': 'model'});
    await expectLater(core.call('voice.set', {'key': 'language', 'value': 'xx'}), refused('bad_params'));
    await expectLater(core.call('voice.set', {'key': 'whisper_server', 'value': '/tmp/x'}), refused('bad_params'));
    await expectLater(core.call('voice.set', {'key': 'enabled', 'value': 'yes'}), refused('bad_params'));
    await expectLater(core.call('voice.set', {'key': 'unload_minutes', 'value': -1}), refused('bad_params'));
    await expectLater(core.call('voice.unset', {'key': 'ui_language'}), refused('bad_params'));
    expect(calls(), [
      ['set', 'enabled', 'false'],
      ['set', 'language', '"de"'],
      ['set', 'unload_minutes', '30'],
      ['set', 'microphone', '"alsa_input.usb-Mic"'],
      ['unset', 'model'],
      ['set', 'language', '"xx"'],
    ]);
  });

  test('a download runs in the background with its percent and ends with the path', () async {
    installFake();
    answer('slow', '');
    final core = w.core();
    final started = await core.call('voice.download', {'model': 'small'});
    expect((started['task'] as Map)['state'], 'running');
    await expectLater(core.call('voice.download', {'model': 'base'}), refused('busy'));
    await expectLater(core.call('voice.remove', {'model': 'small'}), refused('busy'));
    // the progress shows while it waits
    for (var i = 0; i < 100 && ((await core.call('voice.tasks'))['download'] as Map)['progress'] != 45.5; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(((await core.call('voice.tasks'))['download'] as Map)['progress'], 45.5);
    answer('go', '');
    final t = await settle(core, 'download');
    expect(t['state'], 'succeeded');
    expect(t['progress'], 100);
    expect(t['path'], endsWith('ggml-small.bin'));
    expect(calls(), [
      ['model', 'download', 'small'],
    ]);
  });

  test('a failed download says why; bad names are refused', () async {
    installFake();
    final core = w.core();
    await core.call('voice.download', {'model': 'bad'});
    final t = await settle(core, 'download');
    expect(t['state'], 'failed');
    expect(t['message'], 'the download failed (exit status: 22)');
    await expectLater(core.call('voice.download', {'model': '../x'}), refused('bad_params'));
    await expectLater(core.call('voice.download', {'model': '-rf'}), refused('bad_params'));
    await expectLater(core.call('voice.remove', {'model': 'a b'}), refused('bad_params'));
  });

  test('Cancel ends a download and removes what it left', () async {
    installFake();
    answer('slow', '');
    final core = w.core();
    await core.call('voice.download', {'model': 'turbo'});
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await core.call('voice.cancel', {'kind': 'download'});
    final t = await settle(core, 'download');
    expect(t['state'], 'cancelled');
    expect(calls().last, ['model', 'remove', 'turbo']);
    await expectLater(core.call('voice.cancel', {'kind': 'download'}), refused('finished'));
    await expectLater(core.call('voice.cancel', {'kind': 'x'}), refused('bad_params'));
  });

  test('remove goes to the service', () async {
    installFake();
    await w.core().call('voice.remove', {'model': 'base'});
    expect(calls(), [['model', 'remove', 'base']]);
  });

  test('Try it: partial text while listening, then the final text', () async {
    installFake();
    answer('slow', '');
    final core = w.core();
    await core.call('voice.try', {});
    await expectLater(core.call('voice.try', {}), refused('busy'));
    for (var i = 0; i < 100 && ((await core.call('voice.tasks'))['dictate'] as Map)['partial'] != 'hello'; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(((await core.call('voice.tasks'))['dictate'] as Map)['partial'], 'hello');
    answer('go', '');
    final t = await settle(core, 'dictate');
    expect(t['state'], 'succeeded');
    expect(t['text'], 'Hello world.');
    expect(t['partial'], 'hello world');
    expect(t['seconds'], 5);
    expect(calls().last, ['dictate', '--seconds', '5']);
    await expectLater(core.call('voice.try', {'seconds': 0}), refused('bad_params'));
    await expectLater(core.call('voice.try', {'seconds': '5'}), refused('bad_params'));
  });

  test('Try it without speech: the service\'s reason', () async {
    installFake();
    answer('nospeech', '');
    final core = w.core();
    await core.call('voice.try', {'seconds': 3});
    final t = await settle(core, 'dictate');
    expect(t['state'], 'failed');
    expect(t['message'], 'No speech was heard.');
    expect(t['text'], '');
  });

  test('a try can be cancelled', () async {
    installFake();
    answer('slow', '');
    final core = w.core();
    await core.call('voice.try', {});
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await core.call('voice.cancel', {'kind': 'dictate'});
    expect((await settle(core, 'dictate'))['state'], 'cancelled');
  });

  test('microphones: no monitors; without pactl none', () async {
    final m = await SoundService(w.core().ctx).microphones();
    expect([for (final s in m['sources'] as List) s['name']], ['mic']);
    File(p.join(w.fakeBin, 'pactl')).deleteSync();
    expect(await SoundService(w.core().ctx).microphones(), {'default': null, 'sources': const []});
  });
}
