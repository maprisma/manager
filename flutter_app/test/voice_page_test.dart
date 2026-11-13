// The Voice page against fake core answers (voice.*): the status, the engine drop-down with
// unavailable engines disabled, the settings it writes, a model download with progress and
// Cancel, Remove, Use, Try it with partial and final text, and the note when Maprisma
// Dictation is missing. `--page voice` opens it.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma_manager/app.dart';
import 'package:maprisma_manager/home.dart';
import 'package:maprisma_manager/voice_page.dart';
import 'package:maprisma_manager_core/maprisma_manager_core.dart';

import 'page_shots.dart';

const _dark = {'background': '#1a2234', 'foreground': '#cdd6ee', 'accent': '#4dd6c8', 'muted': '#a0a9c0', 'green': '#7fd88f', 'red': '#f38ba8'};

Map<String, dynamic> _status({bool ready = true, List<String> engines = const ['whisper']}) => {
  'enabled': true, 'ready': ready, 'why_not': ready ? '' : 'no_model', 'message': ready ? 'Ready' : 'No Whisper model is installed.',
  'engine': 'whisper', 'engine_setting': 'auto', 'engines': engines, 'model': 'ggml-large-v3-turbo-q5_0.bin',
  'language': 'auto', 'microphone': 'default', 'state': 'idle', 'version': '0.1.0', 'typed_by_engine': false,
};

Map<String, dynamic> _models() => {
  'active': 'ggml-large-v3-turbo-q5_0.bin',
  'folder': '/home/u/.local/share/maprisma-voice/models',
  'catalog': [
    {'id': 'base', 'file': 'ggml-base.bin', 'installed': true, 'label': 'Whisper base (148 MB · fast, any PC)', 'size': 147951465},
    {'id': 'small', 'file': 'ggml-small.bin', 'installed': false, 'label': 'Whisper small (488 MB · balanced)', 'size': 487601967},
    {'id': 'turbo', 'file': 'ggml-large-v3-turbo-q5_0.bin', 'installed': true, 'label': 'Whisper large-v3-turbo (574 MB · best accuracy)', 'size': 574041195},
  ],
  'models': [
    {'name': 'ggml-base.bin', 'managed': true, 'active': false, 'path': '/home/u/.local/share/maprisma-voice/models/ggml-base.bin', 'size': 147951465},
    {'name': 'ggml-large-v3-turbo-q5_0.bin', 'managed': true, 'active': true, 'path': '/home/u/.local/share/maprisma-voice/models/ggml-large-v3-turbo-q5_0.bin', 'size': 574041195},
    {'name': 'ggml-medium.bin', 'managed': false, 'active': false, 'path': '/home/u/.local/share/voxtype/models/ggml-medium.bin', 'size': 1500000000},
  ],
};

Map<String, dynamic> _get({bool installed = true, bool ready = true, Map<String, dynamic>? status, Map<String, dynamic> settings = const {}}) => installed
    ? {
        'installed': true,
        'binary': '/home/u/.local/bin/maprisma-voice',
        'install_url': 'https://github.com/maprisma/dictation',
        'status': status ?? _status(ready: ready),
        'status_error': null,
        'models': _models(),
        'settings': settings,
        'microphones': {
          'default': 'alsa_input.usb-Mic',
          'sources': [
            {'name': 'alsa_input.usb-Mic', 'description': 'USB Microphone'},
            {'name': 'alsa_input.pci-analog', 'description': 'Built-in Audio'},
          ],
        },
        'tasks': {'download': null, 'dictate': null},
      }
    : {'installed': false, 'binary': null, 'install_url': 'https://github.com/maprisma/dictation', 'microphones': {'default': null, 'sources': []}, 'tasks': {'download': null, 'dictate': null}};

/// A fake core: voice.get answers [answer]; download and try move on with every voice.tasks.
class _Fake {
  _Fake(this.answer);
  Map<String, dynamic> answer;
  final calls = <(String, Map<String, dynamic>)>[];
  Map<String, dynamic>? download, dictate;
  int polls = 0;

  Future<Map<String, dynamic>> call(String method, [Map<String, dynamic> params = const {}]) async {
    calls.add((method, params));
    switch (method) {
      case 'settings.get':
        return {'language': 'en'};
      case 'apps.list':
        return {'apps': <Object>[], 'desktop': 'cosmic'};
      case 'jobs.list':
        return {'jobs': <Object>[]};
      case 'voice.get':
        return {...answer, 'tasks': {'download': download, 'dictate': dictate}};
      case 'voice.download':
        download = {'kind': 'download', 'state': 'running', 'model': params['model'], 'progress': null};
        return {'task': download};
      case 'voice.try':
        dictate = {'kind': 'dictate', 'state': 'running', 'seconds': params['seconds'], 'partial': '', 'text': ''};
        return {'task': dictate};
      case 'voice.cancel':
        if (params['kind'] == 'download') download = {...?download, 'state': 'cancelled'};
        if (params['kind'] == 'dictate') dictate = {...?dictate, 'state': 'cancelled'};
        return {};
      case 'voice.tasks':
        polls++;
        if (download?['state'] == 'running') download = {...download!, 'progress': 42.0};
        if (dictate?['state'] == 'running') {
          dictate = polls < 3 ? {...dictate!, 'partial': 'hallo'} : {...dictate!, 'state': 'succeeded', 'partial': 'hallo welt', 'text': 'Hallo Welt.'};
        }
        return {'download': download, 'dictate': dictate};
      default:
        return {};
    }
  }

  List<Map<String, dynamic>> of(String method) => [for (final c in calls) if (c.$1 == method) c.$2];
}

void main() {
  setUpAll(loadShotFonts);
  setUp(() => configureLanguage('en'));

  Future<_Fake> open(WidgetTester tester, Map<String, dynamic> answer) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final fake = _Fake(answer);
    await tester.pumpWidget(ManagerApp(core: fake.call, look: const {'colors': _dark}, checkOnStart: false, relook: null, page: 'voice'));
    await tester.pumpAndSettle();
    return fake;
  }

  Future<void> tapKey(WidgetTester tester, String key) async {
    final f = find.byKey(ValueKey(key));
    await tester.ensureVisible(f);
    await tester.pumpAndSettle();
    await tester.tap(f);
  }

  Future<void> pick(WidgetTester tester, String key, String label) async {
    await tester.ensureVisible(find.byKey(ValueKey(key)));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byKey(ValueKey(key)), matching: find.byWidgetPredicate((w) => w is DropdownButton)));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  test('the sidebar knows the Voice page by name, after AI', () {
    expect(ManagerHomeState.sectionNamed('voice'), Section.voice);
    expect(ManagerHomeState.name(Section.voice), 'Voice');
    expect(Section.values.indexOf(Section.voice), Section.values.indexOf(Section.ai) + 1);
  });

  test('engines: Automatic naming the one in use; unavailable ones disabled with why', () {
    final s = _status(engines: ['whisper', 'online']);
    expect(VoicePageState.engineChoices(s), [
      ('auto', 'Automatic (Local Whisper)'),
      ('whisper', 'Local Whisper'),
      ('online', 'Online'),
      ('voxtype', 'Voxtype · not installed'),
      ('superwhisper', 'Superwhisper · not installed'),
      ('omarchy', 'Omarchy · not installed'),
    ]);
    expect(VoicePageState.enginesOff(s), {'voxtype', 'superwhisper', 'omarchy'});
    // the saved engine stays selectable
    expect(VoicePageState.enginesOff({...s, 'engine_setting': 'voxtype'}), {'superwhisper', 'omarchy'});
    expect(VoicePageState.languageChoices('sv').map((c) => c.$1), ['auto', 'de', 'en', 'fr', 'es', 'it', 'pt', 'nl', 'pl', 'sv', '*']);
  });

  testWidgets('ready: status, settings, models and Try it', (tester) async {
    await open(tester, _get(settings: {'unload_minutes': 10}));
    expect(find.byKey(const ValueKey('voice-page')), findsOneWidget);
    expect(find.text('Ready'), findsOneWidget);
    expect(find.textContaining('Engine: Local Whisper'), findsOneWidget);
    expect(find.text('Automatic (Local Whisper)'), findsOneWidget);
    expect(find.text('Default (USB Microphone)'), findsOneWidget);
    expect(find.text('After 10 minutes'), findsOneWidget);
    expect(find.text('Whisper small (488 MB · balanced)'), findsOneWidget);
    expect(find.byKey(const ValueKey('voice-download-small')), findsOneWidget);
    expect(find.byKey(const ValueKey('voice-remove-base')), findsOneWidget);
    expect(find.text('In use'), findsOneWidget);
    // not ours: Use, but no Remove
    expect(find.byKey(const ValueKey('voice-use-ggml-medium.bin')), findsOneWidget);
    expect(find.byKey(const ValueKey('voice-remove-ggml-medium.bin')), findsNothing);
    if (shotsDir != null) await saveShot(tester, 'page-voice');
    expect(tester.takeException(), isNull);
  });

  testWidgets('settings go to voice.set with their types', (tester) async {
    final fake = await open(tester, _get());
    await tapKey(tester, 'voice-enabled');
    await tester.pumpAndSettle();
    await pick(tester, 'voice-language', 'Deutsch');
    await pick(tester, 'voice-microphone', 'Built-in Audio');
    await pick(tester, 'voice-unload', 'Never');
    await tapKey(tester, 'voice-preload');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('voice-use-ggml-base.bin')));
    await tester.pumpAndSettle();
    expect(fake.of('voice.set'), [
      {'key': 'enabled', 'value': false},
      {'key': 'language', 'value': 'de'},
      {'key': 'microphone', 'value': 'alsa_input.pci-analog'},
      {'key': 'unload_minutes', 'value': 0},
      {'key': 'preload', 'value': true},
      {'key': 'model', 'value': 'ggml-base.bin'},
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('another language code is typed', (tester) async {
    final fake = await open(tester, _get());
    await pick(tester, 'voice-language', 'Other code…');
    await tester.enterText(find.byKey(const ValueKey('voice-language-code')), 'SV');
    await tapKey(tester, 'voice-language-ok');
    await tester.pumpAndSettle();
    expect(fake.of('voice.set'), [{'key': 'language', 'value': 'sv'}]);
  });

  testWidgets('an unavailable engine cannot be picked', (tester) async {
    final fake = await open(tester, _get());
    await pick(tester, 'voice-engine', 'Voxtype · not installed');
    expect(fake.of('voice.set'), isEmpty);
    // the menu stays open: close it
    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();
    await pick(tester, 'voice-engine', 'Local Whisper');
    expect(fake.of('voice.set'), [{'key': 'engine', 'value': 'whisper'}]);
  });

  testWidgets('a download shows its progress and can be cancelled', (tester) async {
    final fake = await open(tester, _get());
    await tapKey(tester, 'voice-download-small');
    await tester.pump();
    expect(fake.of('voice.download'), [{'model': 'small'}]);
    expect(find.byKey(const ValueKey('voice-download-progress')), findsOneWidget);
    // others wait
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('voice-try'))).onPressed, isNotNull);
    await tester.pump(const Duration(milliseconds: 450));
    await tester.pump();
    expect(find.text('Downloading… 42 %'), findsOneWidget);
    await tapKey(tester, 'voice-download-cancel');
    await tester.pump(const Duration(milliseconds: 450));
    await tester.pumpAndSettle();
    expect(fake.of('voice.cancel'), [{'kind': 'download'}]);
    expect(find.byKey(const ValueKey('voice-download-progress')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Remove asks first', (tester) async {
    final fake = await open(tester, _get());
    await tapKey(tester, 'voice-remove-base');
    await tester.pumpAndSettle();
    expect(find.text('Remove Whisper base (148 MB · fast, any PC)?'), findsOneWidget);
    await tapKey(tester, 'voice-remove-confirm');
    await tester.pumpAndSettle();
    expect(fake.of('voice.remove'), [{'model': 'base'}]);
  });

  testWidgets('Try it: partial text, then the final text', (tester) async {
    final fake = await open(tester, _get());
    await tapKey(tester, 'voice-try');
    await tester.pump();
    expect(fake.of('voice.try'), [{'seconds': 5}]);
    expect(find.text('Listening for 5 s… speak now'), findsOneWidget);
    expect(find.byKey(const ValueKey('voice-try-stop')), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 450));
    await tester.pump();
    expect(find.text('hallo'), findsOneWidget);
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 450));
    }
    await tester.pumpAndSettle();
    expect(find.text('Hallo Welt.'), findsOneWidget);
    expect(find.byKey(const ValueKey('voice-try')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('not ready: the service\'s reason; Try it is off', (tester) async {
    await open(tester, _get(ready: false));
    expect(find.text('No Whisper model is installed.'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('voice-try'))).onPressed, isNull);
    expect(find.text('Dictation has to be ready first.'), findsOneWidget);
  });

  testWidgets('an engine that types itself (Omarchy): Try it is off and the note says why', (tester) async {
    final fake = await open(tester, _get(status: {..._status(engines: ['whisper', 'omarchy']), 'engine': 'omarchy', 'typed_by_engine': true}));
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('voice-try'))).onPressed, isNull);
    expect(find.text('This engine types the text itself, into the window that has the focus, so it can\'t be tried here.'), findsOneWidget);
    expect(find.text('Dictation has to be ready first.'), findsNothing);
    expect(fake.of('voice.try'), isEmpty);
  });

  testWidgets('not installed: Install and the GitHub link', (tester) async {
    final fake = await open(tester, _get(installed: false));
    expect(find.text('Maprisma Dictation is not installed'), findsOneWidget);
    expect(find.textContaining('github.com/maprisma/dictation'), findsOneWidget);
    expect(find.byKey(const ValueKey('voice-install')), findsOneWidget);
    expect(find.byKey(const ValueKey('voice-enabled')), findsNothing);
    if (shotsDir != null) await saveShot(tester, 'page-voice-missing');
    await tapKey(tester, 'voice-github');
    await tester.pumpAndSettle();
    expect(fake.of('links.open'), [{'url': 'https://github.com/maprisma/dictation'}]);
  });
}
