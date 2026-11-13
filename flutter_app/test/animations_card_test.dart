// The Appearance page's Hyprland animations card: on COSMIC and KDE it must not flash up as a
// loading card before the core says "unavailable" (xdesk round 2).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma_manager/animations_card.dart';
import 'package:maprisma_manager/backend.dart' show ServiceError;
import 'package:maprisma_manager_core/maprisma_manager_core.dart' show configureLanguage;

void main() {
  setUp(() => configureLanguage('en'));

  testWidgets('no loading card while animations.get is still out; none after "unavailable"', (tester) async {
    final answer = Completer<Map<String, dynamic>>();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: AnimationsCard(core: (method, [params = const {}]) => answer.future)),
    ));
    await tester.pump();
    expect(find.text('Animations (Hyprland)'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    answer.completeError(ServiceError('unavailable', 'not Hyprland'));
    await tester.pumpAndSettle();
    expect(find.text('Animations (Hyprland)'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a real failure still shows the card with its error', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: AnimationsCard(core: (method, [params = const {}]) async => throw ServiceError('internal', 'boom'))),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Animations (Hyprland)'), findsOneWidget);
  });
}
