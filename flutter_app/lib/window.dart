import 'package:flutter/services.dart';

/// The native window (linux/runner/my_application.cc, "maprisma-manager/window").
abstract final class AppWindow {
  static const _channel = MethodChannel('maprisma-manager/window');

  /// A second start's words (`--page <page>`), from the bar icon's menu.
  static void onOpen(void Function(List<String> words) handler) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'open' && call.arguments is List) handler([for (final w in call.arguments as List) '$w']);
      return null;
    });
  }

  /// `--page <page>` in [words], or null.
  static String? pageOf(List<String> words) {
    final i = words.indexOf('--page');
    return i >= 0 && i + 1 < words.length ? words[i + 1] : null;
  }

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
