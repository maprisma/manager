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

  /// Esc on the main page: hidden as by `--toggle` (running jobs go on).
  static Future<void> hide() => _call('hide');

  /// The saved size (rule 5a); the runner keeps it within the screen.
  static Future<void> resize(int width, int height) => _call('size', [width, height]);

  /// {width, height, free}: GTK's size; free = shown and neither maximized, fullscreen nor tiled.
  static Future<Object?> geometry() => _channel.invokeMethod<Object?>('geometry');

  static Future<void> _call(String method, [Object? args]) async {
    try {
      await _channel.invokeMethod<void>(method, args);
    } on MissingPluginException {
      // tests
    } on PlatformException {
      // ignore
    }
  }

  /// The title bar follows the palette: dark or light, and GTK's header bar takes the
  /// palette's [background], [foreground] and [border] (`#rrggbb`), also when the theme
  /// changes while the window is open.
  static Future<void> titlebar(bool dark, {String? background, String? foreground, String? border}) async {
    try {
      await _channel.invokeMethod('titlebar', {
        'dark': dark,
        'background': ?background,
        'foreground': ?foreground,
        'border': ?border,
      });
    } on MissingPluginException {
      // tests
    } on PlatformException {
      // ignore
    }
  }
}

/// `#rrggbb` of [c] (alpha dropped), for the runner's header bar.
String hexOf(Color c) => '#${(c.toARGB32() & 0xffffff).toRadixString(16).padLeft(6, '0')}';
