import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma_manager/window_size.dart';

/// Rule 5a: the window opens at the size the user left it.
void main() {
  test('parse: missing or broken is no size, small is the minimum', () {
    expect(parseWindowSize(null), isNull);
    expect(parseWindowSize('900x700'), isNull);
    expect(parseWindowSize([900]), isNull);
    expect(parseWindowSize(['900', 700]), isNull);
    expect(parseWindowSize([0, 700]), isNull);
    expect(parseWindowSize([-5, 700]), isNull);
    expect(parseWindowSize([double.nan, 700]), isNull);
    expect(parseWindowSize([90000, 700]), isNull);
    expect(parseWindowSize([900, 700]), (900, 700));
    expect(parseWindowSize([900.4, 700.6]), (900, 701));
    expect(parseWindowSize([100, 50]), (minWindowWidth, minWindowHeight));
  });

  test('save only a free size that changed', () {
    final geo = {'width': 1000, 'height': 720, 'free': true};
    expect(sizeToSave(geo, null), (1000, 720));
    expect(sizeToSave(geo, (1000, 720)), isNull);
    expect(sizeToSave({...geo, 'free': false}, null), isNull); // maximized, fullscreen, tiled, hidden
    expect(sizeToSave(null, null), isNull);
    expect(sizeToSave({'width': 'x', 'height': 720, 'free': true}, null), isNull);
  });

  testWidgets('saved half a second after the last resize', (tester) async {
    final saves = <(int, int)>[];
    var width = 900;
    final keeper = WindowSizeKeeper(
      geometry: () async => {'width': width, 'height': 700, 'free': true},
      save: (w, h) async => saves.add((w, h)),
    );
    addTearDown(keeper.dispose);
    keeper.resized();
    await tester.pump(const Duration(milliseconds: 300));
    width = 950;
    keeper.resized();
    await tester.pump(const Duration(milliseconds: 300));
    expect(saves, isEmpty);
    await tester.pump(const Duration(milliseconds: 250));
    expect(saves, [(950, 700)]);
    keeper.resized();
    await tester.pump(const Duration(milliseconds: 600));
    expect(saves, [(950, 700)], reason: 'the same size is not saved again');
  });
}
