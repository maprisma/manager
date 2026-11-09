import 'package:flutter/services.dart';

/// The native window (linux/runner/my_application.cc, "maprisma-manager/window").
abstract final class AppWindow {
  static const _channel = MethodChannel('maprisma-manager/window');

  /// The title bar follows the palette (dark or light).
  static Future<void> titlebar(bool dark) async {
    try {
      await _channel.invokeMethod('titlebar', dark);
    } on MissingPluginException {
      // tests
    } on PlatformException {
      // ignore
    }
  }
}
