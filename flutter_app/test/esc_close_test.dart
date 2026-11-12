import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma_manager/esc_close.dart';

/// Rule 5a: Esc closes the innermost thing first, the window last.
void main() {
  test('the order: popup, field, side page, window', () {
    expect(escStep(overPage: true, inField: true, sidePage: true), EscStep.none);
    expect(escStep(overPage: true, inField: false, sidePage: true), EscStep.none);
    expect(escStep(overPage: false, inField: true, sidePage: true), EscStep.leaveField);
    expect(escStep(overPage: false, inField: false, sidePage: true), EscStep.back);
    expect(escStep(overPage: false, inField: false, sidePage: false), EscStep.close);
  });

  group('EscFallback', () {
    late int closed;
    late EscFallback esc;
    final navigator = GlobalKey<NavigatorState>();

    Future<void> pumpApp(WidgetTester tester, {bool side = false, VoidCallback? onBack}) async {
      closed = 0;
      esc = EscFallback(onClose: () => closed++, sidePage: () => side, onBack: onBack)..attach();
      addTearDown(esc.detach);
      await tester.pumpWidget(MaterialApp(
        navigatorKey: navigator,
        navigatorObservers: [esc],
        builder: (context, child) => esc.wrap(child!),
        home: Scaffold(
          body: Focus(
            autofocus: true,
            child: Column(children: [const TextField(key: ValueKey('field')), Text('main')]),
          ),
        ),
      ));
      await tester.pump();
    }

    testWidgets('main page with nothing open: Esc closes', (tester) async {
      await pumpApp(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      expect(closed, 1);
    });

    testWidgets('a dialog takes Esc itself; the window stays', (tester) async {
      await pumpApp(tester);
      showDialog<void>(context: navigator.currentContext!, builder: (_) => const AlertDialog(content: Text('dialog')));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('dialog'), findsNothing);
      expect(closed, 0);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      expect(closed, 1);
    });

    testWidgets('a field in a dialog: Esc closes the dialog, not the window', (tester) async {
      await pumpApp(tester);
      showDialog<void>(
        context: navigator.currentContext!,
        builder: (_) => const AlertDialog(content: TextField(key: ValueKey('note'), autofocus: true)),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('note')), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('note')), findsNothing);
      expect(closed, 0);
    });

    testWidgets('a dialog that refuses Esc is left alone', (tester) async {
      await pumpApp(tester);
      showDialog<void>(
        context: navigator.currentContext!,
        barrierDismissible: false,
        builder: (_) => const PopScope(canPop: false, child: AlertDialog(content: Text('busy'))),
      );
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('busy'), findsOneWidget);
      expect(closed, 0);
    });

    testWidgets('a side page: Esc goes back, then closes', (tester) async {
      await pumpApp(tester);
      navigator.currentState!.push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('side'))));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('side'), findsNothing);
      expect(closed, 0);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      expect(closed, 1);
    });

    testWidgets("the app's own side page: Esc calls onBack", (tester) async {
      var back = 0;
      await pumpApp(tester, side: true, onBack: () => back++);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      expect(back, 1);
      expect(closed, 0);
    });

    testWidgets('in a text field: the first Esc leaves it, the second closes', (tester) async {
      await pumpApp(tester);
      await tester.tap(find.byKey(const ValueKey('field')));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(closed, 0);
      expect(FocusManager.instance.primaryFocus?.context?.findAncestorStateOfType<EditableTextState>(), isNull);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      expect(closed, 1);
    });

    testWidgets('a widget that takes Esc itself wins', (tester) async {
      closed = 0;
      var own = 0;
      esc = EscFallback(onClose: () => closed++)..attach();
      addTearDown(esc.detach);
      await tester.pumpWidget(MaterialApp(
        navigatorObservers: [esc],
        builder: (context, child) => esc.wrap(child!),
        home: Focus(
          autofocus: true,
          onKeyEvent: (_, e) {
            if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.escape) {
              own++;
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: const SizedBox(),
        ),
      ));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      expect(own, 1);
      expect(closed, 0);
    });
  });
}
