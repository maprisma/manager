// The Notifications page against fake core answers: Maprisma Notifier's settings on every
// desktop, Maprisma Shell's popups on Hyprland, the desktop's own settings on COSMIC/KDE, and the
// Install note when Notifier is missing. `--page notifications` opens it.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma_manager/app.dart';
import 'package:maprisma_manager/home.dart';
import 'package:maprisma_manager/notifications_page.dart' show AppMode;
import 'package:maprisma_manager_core/maprisma_manager_core.dart';

import 'page_shots.dart';

const _dark = {'background': '#1a2234', 'foreground': '#cdd6ee', 'accent': '#4dd6c8', 'muted': '#a0a9c0'};

Map<String, dynamic> _answer({String desktop = 'hyprland', bool installed = true, bool running = true}) => {
  'desktop': desktop,
  'installed': installed,
  'running': running,
  'settings': {
    'file': '/home/u/.config/maprisma-notifier/settings.json',
    'exists': true,
    'dnd': false,
    'dnd_schedule': {'on': true, 'from': '22:00', 'to': '07:00'},
    'dnd_now': false,
    'history_max': 500,
    'history_days': 7,
    'show_count': true,
    'notify_crashes': true,
    'muted_apps': ['Slack'],
    'hidden_apps': ['Spam'],
  },
  'history': {'file': '/h', 'exists': true, 'count': 12, 'apps': ['Firefox', 'Slack']},
  'shell': desktop == 'hyprland' ? {'file': '/home/u/.config/maprisma-shell/shell.json', 'exists': true, 'dnd': false, 'position': 'top-right', 'timeout': 5, 'max': 5} : null,
  'desktop_dnd': switch (desktop) {
    'hyprland' => {'where': 'shell', 'on': false},
    'cosmic' => {'where': 'cosmic', 'on': false},
    _ => {'where': 'recorder'},
  },
  // COSMIC Settings 1.11 has no notifications page: only KDE links to its own
  'native': desktop == 'kde' ? {'name': 'System Settings', 'available': true} : null,
};

void main() {
  setUpAll(loadShotFonts);
  setUp(() => configureLanguage('en'));

  Future<List<(String, Map<String, dynamic>)>> open(WidgetTester tester, Map<String, dynamic> answer, {List<Map<String, dynamic>> apps = const []}) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final calls = <(String, Map<String, dynamic>)>[];
    Future<Map<String, dynamic>> core(String method, [Map<String, dynamic> params = const {}]) async {
      calls.add((method, params));
      return switch (method) {
        'settings.get' => {'language': 'en'},
        'apps.list' => {'apps': apps, 'desktop': answer['desktop']},
        'notifications.get' => answer,
        'notifications.set' => {'settings': answer['settings'], 'written': true},
        'notifications.set_shell' => {'shell': answer['shell'], 'written': true},
        'notifications.clear_history' => {'cleared': true},
        'jobs.start' || 'jobs.get' => {'id': 'j1', 'state': 'succeeded', 'result': {}},
        'jobs.list' => {'jobs': <Object>[]},
        _ => {},
      };
    }

    await tester.pumpWidget(ManagerApp(core: core, look: const {'colors': _dark}, checkOnStart: false, relook: null, page: 'notifications'));
    await tester.pumpAndSettle();
    return calls;
  }

  Future<void> choose<T>(WidgetTester tester, String key, String label) async {
    await tester.ensureVisible(find.byKey(ValueKey(key)));
    await tester.tap(find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(DropdownButton<T>)));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  test('the sidebar has Notifications after Sound, then AI, Voice and Power', () {
    final s = Section.values;
    expect(s.indexOf(Section.notifications), s.indexOf(Section.sound) + 1);
    expect(s.indexOf(Section.ai), s.indexOf(Section.notifications) + 1);
    expect(s.indexOf(Section.voice), s.indexOf(Section.ai) + 1);
    expect(s.indexOf(Section.power), s.indexOf(Section.voice) + 1);
    expect(ManagerHomeState.sectionNamed('notifications'), Section.notifications);
    expect(s.indexOf(Section.theme), s.indexOf(Section.appearance) + 1);
    expect(ManagerHomeState.sectionNamed('theme'), Section.theme);
  });

  testWidgets('Hyprland: do not disturb, history, apps, Shell\'s popups; changes only what was touched', (tester) async {
    final calls = await open(tester, _answer());
    expect(find.byKey(const ValueKey('notifications-page')), findsOneWidget);
    expect(find.text('Do not disturb'), findsWidgets);
    expect(find.text('12 notifications kept'), findsOneWidget);
    for (final app in ['Firefox', 'Slack', 'Spam']) {
      expect(find.byKey(ValueKey('notifications-app-$app')), findsOneWidget);
    }
    expect(find.byKey(const ValueKey('notifications-schedule-from')), findsOneWidget);
    expect(find.text('Popups'), findsOneWidget);
    expect(find.byKey(const ValueKey('notifications-open-native')), findsNothing);
    expect(find.byKey(const ValueKey('notifications-install')), findsNothing);
    if (shotsDir != null) await saveShot(tester, 'page-notifications-hyprland');

    await tester.tap(find.byKey(const ValueKey('notifications-dnd')));
    await tester.pumpAndSettle();
    expect(calls.where((c) => c.$1 == 'notifications.set').last.$2, {'dnd': true});

    await choose<int>(tester, 'notifications-history-days', '30 days');
    expect(calls.where((c) => c.$1 == 'notifications.set').last.$2, {'history_days': 30});

    // Firefox muted: only the muted list is written, with Slack kept
    await choose<AppMode>(tester, 'notifications-app-Firefox', 'Muted');
    expect(calls.where((c) => c.$1 == 'notifications.set').last.$2, {'muted_apps': ['Slack', 'Firefox']});
    // Slack hidden: off the muted list, onto the hidden one
    await choose<AppMode>(tester, 'notifications-app-Slack', 'Hidden');
    expect(calls.where((c) => c.$1 == 'notifications.set').last.$2, {'muted_apps': <String>[], 'hidden_apps': ['Spam', 'Slack']});

    await choose<String>(tester, 'notifications-position', 'Bottom left');
    expect(calls.where((c) => c.$1 == 'notifications.set_shell').last.$2, {'position': 'bottom-left'});
    await choose<int>(tester, 'notifications-max', '3');
    expect(calls.where((c) => c.$1 == 'notifications.set_shell').last.$2, {'max': 3});

    await tester.ensureVisible(find.byKey(const ValueKey('notifications-clear')));
    await tester.tap(find.byKey(const ValueKey('notifications-clear')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('notifications-clear-confirm')));
    await tester.pumpAndSettle();
    expect(calls.where((c) => c.$1 == 'notifications.clear_history'), hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('crash reports: the switch; no helper choice here, a link to the AI page', (tester) async {
    final calls = await open(tester, _answer());
    expect(find.text('Report app crashes'), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('notifications-ai-helper')), matching: find.byType(DropdownButton<String>)), findsNothing);
    await tester.ensureVisible(find.byKey(const ValueKey('notifications-crashes')));
    await tester.tap(find.byKey(const ValueKey('notifications-crashes')));
    await tester.pumpAndSettle();
    expect(calls.where((c) => c.$1 == 'notifications.set').last.$2, {'notify_crashes': false});
    expect(find.text('Check with AI'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('notifications-open-ai')));
    await tester.tap(find.byKey(const ValueKey('notifications-open-ai')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ai-page')), findsOneWidget);
    expect(calls.where((c) => c.$1 == 'notifications.set' && c.$2.containsKey('ai_helper')), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('COSMIC: Notifier\'s settings, no Shell popups, no button to COSMIC Settings (it has no notifications page)', (tester) async {
    final calls = await open(tester, _answer(desktop: 'cosmic'));
    expect(find.text('Popups'), findsNothing);
    expect(find.text('Popups are set in COSMIC Settings'), findsNothing);
    expect(find.byKey(const ValueKey('notifications-open-native')), findsNothing);
    if (shotsDir != null) await saveShot(tester, 'page-notifications-cosmic');
    expect(calls.where((c) => c.$1 == 'native.open'), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('KDE: the button opens System Settings\' notifications page', (tester) async {
    final calls = await open(tester, _answer(desktop: 'kde'));
    expect(find.text('Popups are set in System Settings'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('notifications-open-native')));
    await tester.tap(find.byKey(const ValueKey('notifications-open-native')));
    await tester.pumpAndSettle();
    expect(calls.where((c) => c.$1 == 'native.open').single.$2, {'page': 'notifications'});
    expect(tester.takeException(), isNull);
  });

  testWidgets('KDE without a running Notifier: do not disturb waits for it', (tester) async {
    await open(tester, _answer(desktop: 'kde', running: false));
    expect(find.textContaining('Maprisma Notifier is not running'), findsOneWidget);
    expect(find.text('Popups are set in System Settings'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('not installed: the note with Install (the Apps page\'s job), Shell\'s popups stay', (tester) async {
    final notifier = {'id': 'notifier', 'name': 'Maprisma Notifier', 'kind': 'rust', 'supportedHere': true, 'support': {'install': true}};
    final calls = await open(tester, _answer(installed: false), apps: [notifier]);
    expect(find.text('Maprisma Notifier is not installed'), findsOneWidget);
    expect(find.byKey(const ValueKey('notifications-dnd')), findsNothing);
    if (shotsDir != null) await saveShot(tester, 'page-notifications-missing');
    expect(find.text('Popups'), findsOneWidget);
    // the page is built again once the list knows the app
    await tester.tap(find.byKey(const ValueKey('nav-apps')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('nav-notifications')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('notifications-install')));
    await tester.pumpAndSettle();
    final start = calls.where((c) => c.$1 == 'jobs.start').single.$2;
    expect(start, allOf(containsPair('app', 'notifier'), containsPair('kind', 'install')));
    expect(tester.takeException(), isNull);
  });
}
