// The AI page's "What Ask AI may do" (docs/ask-ai-rules.md) against fake core answers.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma_manager/ask_ai_rules.dart';
import 'package:maprisma_manager_core/maprisma_manager_core.dart';

Map<String, dynamic> _view({
  String level = 'review',
  bool broken = false,
  bool removeOn = true,
}) => {
  'level': level,
  'broken': broken,
  'actions': [
    {
      'id': 'launcher.install',
      'app': 'launcher',
      'label': 'Install apps',
      'on': true,
      'effective': level == 'review',
    },
    {
      'id': 'launcher.remove',
      'app': 'launcher',
      'label': 'Uninstall apps',
      'on': removeOn,
      'effective': level == 'review' && removeOn,
    },
    {
      'id': 'theme.apply',
      'app': 'theme',
      'label': 'Apply a theme or wallpaper',
      'on': true,
      'effective': level == 'review',
    },
  ],
  'sources': [
    {
      'id': 'aur',
      'app': 'launcher',
      'label': 'AUR',
      'on': true,
      'effective': true,
    },
  ],
  'folders': [
    {
      'id': 'downloads',
      'app': 'launcher',
      'label': 'Downloads (AppImages to install)',
      'on': true,
      'effective': true,
    },
  ],
  'answers': [
    {'id': 'playground.chat', 'app': 'playground', 'label': 'Chat'},
  ],
};

void main() {
  setUp(() => configureLanguage('en'));

  Future<List<(String, Map<String, dynamic>)>> open(
    WidgetTester tester,
    Map<String, dynamic> view, {
    List<Map<String, dynamic>> log = const [],
  }) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final calls = <(String, Map<String, dynamic>)>[];
    var current = view;
    Future<Map<String, dynamic>> core(
      String method, [
      Map<String, dynamic> params = const {},
    ]) async {
      calls.add((method, params));
      switch (method) {
        case 'ai.rules':
          return current;
        case 'ai.log':
          return {'entries': log};
        case 'ai.set_rule':
          current = _view(
            removeOn: params['id'] == 'launcher.remove'
                ? params['on'] as bool
                : true,
            level: (params['level'] ?? current['level']) as String,
          );
          return current;
        case 'ai.reset_rules':
          current = _view();
          return current;
        case 'ai.clear_log':
          return {'entries': <Object>[]};
      }
      return {};
    }

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: AskAiRules(core: core)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return calls;
  }

  testWidgets(
    'switches per app, sources, folders, the answers; a switch calls ai.set_rule',
    (tester) async {
      final calls = await open(tester, _view());
      expect(find.text('Maprisma Launcher'), findsOneWidget);
      expect(find.text('Uninstall apps'), findsOneWidget);
      expect(find.text('AUR'), findsOneWidget);
      expect(find.text('Chat'), findsOneWidget);
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('ask-ai-actions-launcher.remove')),
          matching: find.byType(Switch),
        ),
      );
      await tester.pumpAndSettle();
      expect(calls.where((c) => c.$1 == 'ai.set_rule').single.$2, {
        'kind': 'actions',
        'id': 'launcher.remove',
        'on': false,
      });
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('answers only: the switches say they are off meanwhile', (
    tester,
  ) async {
    await open(tester, _view(level: 'answers'));
    expect(find.text('Off while Ask AI only answers'), findsWidgets);
  });

  testWidgets('a broken file: the notice and Reset', (tester) async {
    final calls = await open(tester, _view(broken: true, level: 'answers'));
    expect(find.text('The rules can\'t be read'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('ask-ai-reset')));
    await tester.pumpAndSettle();
    expect(calls.any((c) => c.$1 == 'ai.reset_rules'), isTrue);
    expect(find.text('The rules can\'t be read'), findsNothing);
  });

  testWidgets('the log, newest first, and Clear', (tester) async {
    final calls = await open(
      tester,
      _view(),
      log: [
        {
          'time': '2026-11-14T12:30:00Z',
          'op': 'a1',
          'app': 'launcher',
          'action': 'launcher.install',
          'target': 'mission-center (pacman)',
          'result': 'started',
        },
        {
          'time': '2026-11-14T12:29:00Z',
          'op': 'b2',
          'app': 'launcher',
          'action': 'launcher.remove',
          'target': 'btop',
          'result': 'blocked',
        },
      ],
    );
    expect(find.text('mission-center (pacman)'), findsOneWidget);
    expect(find.textContaining('blocked'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('ask-ai-clear-log')));
    await tester.pumpAndSettle();
    expect(calls.any((c) => c.$1 == 'ai.clear_log'), isTrue);
    expect(find.text('Nothing yet.'), findsOneWidget);
  });
}
