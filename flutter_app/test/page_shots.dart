import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Offscreen pictures of the pages for the visual check (as Maprisma Theme's page_shots.dart):
/// only when MAPRISMA_SHOTS names a folder; then real fonts are loaded so the text is readable
/// (the test font draws boxes).
final shotsDir = Platform.environment['MAPRISMA_SHOTS'];

Future<void> loadShotFonts() async {
  if (shotsDir == null) return;
  final fonts = '${Platform.environment['FLUTTER_ROOT'] ?? '/mnt/Data/flutter'}/bin/cache/artifacts/material_fonts';
  Future<void> family(String name, List<String> files) async {
    final loader = FontLoader(name);
    var any = false;
    for (final f in files) {
      final file = File(f.startsWith('/') ? f : '$fonts/$f');
      if (!file.existsSync()) continue;
      any = true;
      loader.addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
    }
    if (any) await loader.load();
  }

  await family('Roboto', ['Roboto-Regular.ttf', 'Roboto-Medium.ttf', 'Roboto-Bold.ttf']);
  // Text without a family falls back to the test font: real letters there too.
  await family('FlutterTest', ['Roboto-Regular.ttf', 'Roboto-Medium.ttf', 'Roboto-Bold.ttf']);
  await family('MaterialIcons', ['MaterialIcons-Regular.otf']);
  await family('monospace', ['/usr/share/fonts/noto/NotoSansMono-Regular.ttf']);
}

/// The whole test window as `<MAPRISMA_SHOTS>/<name>.png` (nothing without MAPRISMA_SHOTS).
Future<void> saveShot(WidgetTester tester, String name) async {
  final dir = shotsDir;
  if (dir == null) return;
  await tester.runAsync(() async {
    final view = tester.binding.renderViews.first;
    final layer = view.debugLayer! as OffsetLayer;
    final image = await layer.toImage(Offset.zero & view.size);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    Directory(dir).createSync(recursive: true);
    File('$dir/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}
