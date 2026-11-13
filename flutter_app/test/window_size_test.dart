import 'dart:io';

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

  testWidgets('closed or hidden within half a second: the size it had while shown is kept', (tester) async {
    final saves = <(int, int)>[];
    var geo = <String, Object>{'width': 1000, 'height': 760, 'free': true};
    final keeper = WindowSizeKeeper(geometry: () async => geo, save: (w, h) async => saves.add((w, h)), saved: (900, 700));
    addTearDown(keeper.dispose);
    keeper.resized();
    await tester.pump(const Duration(milliseconds: 100));
    geo = {'width': 1000, 'height': 760, 'free': false}; // hidden (Esc, the bar): not free any more
    await tester.pump(const Duration(milliseconds: 500));
    expect(saves, [(1000, 760)]);
    // closing right after a resize: flush saves it at once, the timer adds nothing
    geo = {'width': 1100, 'height': 800, 'free': true};
    keeper.resized();
    await tester.pump(const Duration(milliseconds: 10));
    geo = {'width': 1100, 'height': 800, 'free': false};
    await keeper.flush();
    expect(saves, [(1000, 760), (1100, 800)]);
    await tester.pump(const Duration(milliseconds: 600));
    expect(saves, hasLength(2));
    // maximized: no size of the user's, nothing saved
    geo = {'width': 1920, 'height': 1080, 'free': false};
    keeper.resized();
    await tester.pump(const Duration(milliseconds: 600));
    expect(saves, hasLength(2));
  });

  group('Maprisma Tiling on KDE sizes windows itself (D7)', () {
    late Directory home;
    setUp(() => home = Directory.systemTemp.createTempSync('ws-kwin'));
    tearDown(() => home.deleteSync(recursive: true));
    Map<String, String> env([String desktop = 'KDE']) => {'HOME': home.path, 'XDG_CURRENT_DESKTOP': desktop};
    void kwinrc(String text) => File('${home.path}/.config/kwinrc')
      ..createSync(recursive: true)
      ..writeAsStringSync(text);
    bool tiled(String app, [String desktop = 'KDE']) =>
        tiledByMaprismaTiling(app, environment: env(desktop), systemData: '${home.path}/none');

    test('on only when the script is on (switched on, or installed and not switched off)', () {
      expect(tiled('com.maprisma.Settings'), isFalse, reason: 'not installed, not switched');
      Directory('${home.path}/.local/share/kwin/scripts/maprisma-tiling').createSync(recursive: true);
      expect(tiled('com.maprisma.Settings'), isTrue, reason: 'on by default once installed');
      kwinrc('[Plugins]\nmaprisma-tilingEnabled=false\n');
      expect(tiled('com.maprisma.Settings'), isFalse);
      kwinrc('[Plugins]\nblurEnabled=true\nmaprisma-tilingEnabled=true\n');
      expect(tiled('com.maprisma.Settings'), isTrue);
      expect(tiled('com.maprisma.Settings', 'COSMIC'), isFalse, reason: 'KDE only');
      expect(tiled('com.maprisma.Settings', 'Hyprland'), isFalse);
    });

    test('an app the script always floats keeps its size (by default the Launcher)', () {
      kwinrc('[Plugins]\nmaprisma-tilingEnabled=true\n');
      expect(tiled('com.maprisma.Launcher'), isFalse);
      kwinrc('[Plugins]\nmaprisma-tilingEnabled=true\n\n[Script-maprisma-tiling]\nfloatingClasses=com.maprisma.Theme, com.maprisma.Mail\n');
      expect(tiled('com.maprisma.Mail'), isFalse);
      expect(tiled('com.maprisma.Launcher'), isTrue);
    });

    testWidgets('the keeper saves nothing while the tiler sizes the window', (tester) async {
      final saves = <(int, int)>[];
      var tiledNow = true;
      final keeper = WindowSizeKeeper(
        geometry: () async => {'width': 960, 'height': 1040, 'free': true}, // GTK sees no tiled state
        save: (w, h) async => saves.add((w, h)),
        tiled: () => tiledNow,
      );
      addTearDown(keeper.dispose);
      keeper.resized();
      await tester.pump(const Duration(milliseconds: 600));
      expect(saves, isEmpty);
      tiledNow = false;
      keeper.resized();
      await tester.pump(const Duration(milliseconds: 600));
      expect(saves, [(960, 1040)]);
    });
  });
}
