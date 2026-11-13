// The AI page against fake core answers: the helper every Maprisma app uses (Automatic and the
// ready helpers, "(untested)" marks, a chosen helper that isn't ready falls back to Automatic)
// and Let AI do the updates. `--page ai` opens it.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma_manager/ai_page.dart';
import 'package:maprisma_manager/app.dart';
import 'package:maprisma_manager/home.dart';
import 'package:maprisma_manager_core/maprisma_manager_core.dart';

import 'page_shots.dart';

const _dark = {'background': '#1a2234', 'foreground': '#cdd6ee', 'accent': '#4dd6c8', 'muted': '#a0a9c0'};

Map<String, dynamic> _helpers({String helper = 'auto', bool fallback = false, bool none = false}) => {
  'helpers': [
    {'id': 'claude', 'name': 'Claude Code', 'installed': !none, 'signed_in': !none, 'local': false, 'verified': true},
    {'id': 'codex', 'name': 'Codex', 'installed': false, 'signed_in': false, 'local': false, 'verified': true},
    {'id': 'gemini', 'name': 'Gemini CLI', 'installed': !none, 'signed_in': !none, 'local': false, 'verified': false},
    {'id': 'pi:ollama/qwen3', 'name': 'pi · qwen3', 'installed': !none, 'signed_in': !none, 'local': true, 'verified': true},
  ],
  'helper': helper,
  'auto': none ? null : 'claude',
  'chosen': none ? null : (fallback ? 'claude' : (helper == 'auto' ? 'claude' : helper)),
  'fallback': fallback,
  'file': '/home/u/.config/maprisma-ai/settings.json',
  'enabled': false,
  'busy': false,
};

void main() {
  setUpAll(loadShotFonts);
  setUp(() => configureLanguage('en'));

  Future<List<(String, Map<String, dynamic>)>> open(WidgetTester tester, Map<String, dynamic> answer) async {
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final calls = <(String, Map<String, dynamic>)>[];
    Future<Map<String, dynamic>> core(String method, [Map<String, dynamic> params = const {}]) async {
      calls.add((method, params));
      return switch (method) {
        'settings.get' => {'language': 'en'},
        'apps.list' => {'apps': <Object>[], 'desktop': 'cosmic'},
        'ai.helpers' => answer,
        'ai.set_helper' => {...answer, 'helper': params['helper']},
        'settings.set' => {'key': params['key'], 'value': params['value']},
        'jobs.list' => {'jobs': <Object>[]},
        _ => {},
      };
    }

    await tester.pumpWidget(ManagerApp(core: core, look: const {'colors': _dark}, checkOnStart: false, relook: null, page: 'ai'));
    await tester.pumpAndSettle();
    return calls;
  }

  test('the sidebar knows the AI page by name', () {
    expect(ManagerHomeState.sectionNamed('ai'), Section.ai);
    expect(ManagerHomeState.name(Section.ai), 'AI');
  });

  test('choices: Automatic naming its pick, then every ready helper with its marks', () {
    expect(AiPageState.choices(_helpers()), [
      ('auto', 'Automatic (Claude Code)'),
      ('claude', 'Claude Code'),
      ('gemini', 'Gemini CLI (untested)'),
      ('pi:ollama/qwen3', 'pi · qwen3 · on this PC'),
    ]);
    expect(AiPageState.choices(_helpers(none: true)), [('auto', 'Automatic')]);
    expect(AiPageState.shown(_helpers(helper: 'gemini')), 'gemini');
    // not ready (codex) or unknown: Automatic is shown
    expect(AiPageState.shown(_helpers(helper: 'codex', fallback: true)), 'auto');
    expect(AiPageState.shown(_helpers(helper: 'nobody', fallback: true)), 'auto');
  });

  testWidgets('the helper choice writes the shared setting; it explains who uses it', (tester) async {
    final calls = await open(tester, _helpers());
    expect(find.byKey(const ValueKey('ai-page')), findsOneWidget);
    expect(find.text('AI helper for all Maprisma apps'), findsOneWidget);
    expect(find.textContaining('Launcher, Theme, Playground, Notifier'), findsOneWidget);
    expect(find.text('Automatic (Claude Code)'), findsOneWidget);
    expect(find.text('Saved in ~/.config/maprisma-ai/settings.json'), findsOneWidget);
    if (shotsDir != null) await saveShot(tester, 'page-ai');
    await tester.tap(find.descendant(of: find.byKey(const ValueKey('ai-page-helper')), matching: find.byType(DropdownButton<String>)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Gemini CLI (untested)').last);
    await tester.pumpAndSettle();
    expect(calls.where((c) => c.$1 == 'ai.set_helper').single.$2, {'helper': 'gemini'});
    expect(tester.takeException(), isNull);
  });

  testWidgets('a chosen helper that is not ready: Automatic is shown and the page says so', (tester) async {
    await open(tester, _helpers(helper: 'codex', fallback: true));
    expect(find.text('Automatic (Claude Code)'), findsOneWidget);
    expect(find.text('codex is not installed or not ready here, so Automatic is used.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('no helper: the choice and Let AI do the updates are off', (tester) async {
    final calls = await open(tester, _helpers(none: true));
    expect(find.text('No AI helper is installed and signed in'), findsOneWidget);
    expect(tester.widget<Switch>(find.descendant(of: find.byKey(const ValueKey('ai-updates')), matching: find.byType(Switch))).onChanged, isNull);
    await tester.tap(find.byKey(const ValueKey('ai-updates')));
    await tester.pumpAndSettle();
    expect(calls.where((c) => c.$1 == 'settings.set'), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Let AI do the updates is saved from here', (tester) async {
    final calls = await open(tester, _helpers());
    await tester.tap(find.byKey(const ValueKey('ai-updates')));
    await tester.pumpAndSettle();
    expect(calls.where((c) => c.$1 == 'settings.set').single.$2, {'key': 'ai_updates', 'value': true});
    expect(tester.takeException(), isNull);
  });
}
