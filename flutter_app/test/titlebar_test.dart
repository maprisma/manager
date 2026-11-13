// The header bar takes the palette's colours (the runner draws it with them), also after a
// theme change while the window is open.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma_manager/app.dart';
import 'package:maprisma_manager/window.dart';

void main() {
  test('hexOf: #rrggbb without alpha', () {
    expect(hexOf(const Color(0xff1a2234)), '#1a2234');
    expect(hexOf(const Color(0x80000a0b)), '#000a0b');
  });

  testWidgets('the titlebar call carries dark/light and the palette\'s header colours, again when the look changes', (tester) async {
    final calls = <Object?>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('maprisma-manager/window'), (call) async {
      if (call.method == 'titlebar') calls.add(call.arguments);
      return null;
    });
    var look = {'background': '#1a2234', 'foreground': '#cdd6ee', 'accent': '#4dd6c8'};
    Future<Map<String, dynamic>> core(String method, [Map<String, dynamic> params = const {}]) async => switch (method) {
      'desktop.look' => {'colors': look},
      'apps.list' => {'apps': <Map<String, dynamic>>[], 'desktop': 'other'},
      _ => {},
    };
    await tester.pumpWidget(ManagerApp(core: core, look: {'colors': look}, checkOnStart: false, relook: const Duration(milliseconds: 100)));
    await tester.pump();
    final first = calls.last as Map;
    expect(first['dark'], isTrue);
    expect(first['background'], matches(RegExp(r'^#[0-9a-f]{6}$')));
    expect(first['foreground'], matches(RegExp(r'^#[0-9a-f]{6}$')));
    look = {'background': '#eff1f5', 'foreground': '#4c4f69', 'accent': '#1e66f5'};
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    final second = calls.last as Map;
    expect(second['dark'], isFalse);
    expect(second['background'], isNot(first['background']));
    await tester.pumpWidget(const SizedBox());
  });
}
