import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:maprisma_manager_core/maprisma_manager_core.dart'
    show tr, trf, configureLanguage, currentLanguage, languageNames, homeShort, saveScreenshot, saveScreenshotNote, screenshotFolder, screenshotNoteLimit;

import 'home.dart';
import 'core_call.dart';
import 'jobs_model.dart';
import 'theme.dart';
import 'window.dart';

/// Maprisma Manager's window: the list page in the desktop's colours (`desktop.look`, read as
/// Maprisma Launcher reads them).
class ManagerApp extends StatefulWidget {
  const ManagerApp({super.key, required this.core, this.look = const {}, this.onRestart, this.checkOnStart = true, this.jobs, this.screenshots, this.settings = const {}});
  final CoreCall core;
  final Map<String, dynamic> look;
  final VoidCallback? onRestart;
  final bool checkOnStart;

  /// Tests pass their own (a shorter poll).
  final JobsModel? jobs;

  /// Where F12 saves its pictures (tests); null: ~/Pictures/Maprisma Manager.
  final String? screenshots;

  /// `settings.get` as main read it before the first frame (the corners from the start).
  final Map<String, dynamic> settings;
  @override
  State<ManagerApp> createState() => _ManagerAppState();
}

/// The whole window, dialogs included, for F12's picture (MaterialApp.builder).
final windowShot = GlobalKey(debugLabel: 'window');

class _ManagerAppState extends State<ManagerApp> with WidgetsBindingObserver {
  String languageSetting = 'auto';

  /// Settings › Corners (windows, slight, rounded, square) and F12 saves a screenshot.
  late String cornersSetting = widget.settings['corners'] as String? ?? 'windows';
  late bool screenshotKey = widget.settings['screenshot_key'] != false;
  final _navigator = GlobalKey<NavigatorState>();
  final _messenger = GlobalKey<ScaffoldMessengerState>();
  late Map<String, dynamic> look = widget.look;
  late final JobsModel jobs = widget.jobs ?? JobsModel(widget.core);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    HardwareKeyboard.instance.addHandler(_f12);
    _titlebar();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    try {
      final settings = await widget.core('settings.get');
      languageSetting = settings['language'] as String? ?? 'auto';
      configureLanguage(languageSetting);
      cornersSetting = settings['corners'] as String? ?? 'windows';
      screenshotKey = settings['screenshot_key'] != false;
      if (mounted) setState(() {});
    } on Object {
      // Older cores and test doubles can omit settings.
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    HardwareKeyboard.instance.removeHandler(_f12);
    if (widget.jobs == null) jobs.dispose();
    super.dispose();
  }

  @override
  void didChangePlatformBrightness() => _reloadLook();

  Future<void> _reloadLook() async {
    try {
      final fresh = await widget.core('desktop.look');
      if (mounted) setState(() => look = fresh);
      _titlebar();
    } on Object {
      // the old look stays
    }
  }

  void _titlebar() {
    final platform = WidgetsBinding.instance.platformDispatcher.platformBrightness;
    AppWindow.titlebar(appTheme(platform, look['colors'] as Map? ?? {}, 12).brightness == Brightness.dark);
  }

  // --- F12: a picture of the window ------------------------------------------------------------

  bool _shooting = false;

  /// F12 without Ctrl, Shift, Alt or Super, wherever the keyboard is (also in a dialog).
  bool _f12(KeyEvent event) {
    if (event is! KeyDownEvent || event.logicalKey != LogicalKeyboardKey.f12) return false;
    final keys = HardwareKeyboard.instance;
    if (keys.isControlPressed || keys.isShiftPressed || keys.isAltPressed || keys.isMetaPressed) return false;
    if (!screenshotKey) return false;
    takeScreenshot();
    return true;
  }

  static String _why(Object error) => switch (error) {
    FileSystemException(:final osError?) => osError.message,
    FileSystemException(:final message) => message,
    _ => '$error',
  };

  void _toast(String text) => _messenger.currentState?.showSnackBar(SnackBar(content: Text(text)));

  /// The window as it is now into a PNG (it draws itself: no screenshot program), then the
  /// dialog for a note.
  Future<void> takeScreenshot() async {
    if (_shooting) return;
    _shooting = true;
    String path;
    try {
      final boundary = windowShot.currentContext?.findRenderObject();
      if (boundary is! RenderRepaintBoundary || !boundary.hasSize || boundary.size.isEmpty) {
        throw _NoPicture();
      }
      final image = await boundary.toImage(pixelRatio: View.of(context).devicePixelRatio);
      final ByteData? png;
      try {
        png = await image.toByteData(format: ui.ImageByteFormat.png);
      } finally {
        image.dispose();
      }
      if (png == null) throw _NoPicture();
      path = saveScreenshot(widget.screenshots ?? screenshotFolder(), png.buffer.asUint8List());
    } on Object catch (e) {
      _shooting = false;
      if (mounted) _toast(trf('The screenshot could not be saved: {0}', [_why(e)]));
      return;
    }
    try {
      // F12 again while the note is asked for takes no second picture and opens no second dialog.
      if (mounted) await _screenshotNote(path);
    } finally {
      _shooting = false;
    }
  }

  /// "Screenshot saved": where, and an optional note about what is wrong, saved next to it as a
  /// .txt when the dialog closes (Done, Enter, Esc).
  Future<void> _screenshotNote(String path) async {
    final where = _navigator.currentContext;
    if (where == null) return;
    final note = await showDialog<String>(context: where, builder: (_) => ScreenshotNoteDialog(path: path));
    try {
      saveScreenshotNote(path, note ?? '');
    } on Object catch (e) {
      if (mounted) _toast(trf('The note could not be saved: {0}', [_why(e)]));
    }
  }

  @override
  Widget build(BuildContext context) {
    final radius = cornerRadius(cornersSetting, look['rounding'] as int?);
    return MaterialApp(
      title: tr('Maprisma Manager'),
      navigatorKey: _navigator,
      scaffoldMessengerKey: _messenger,
      builder: (context, child) => RepaintBoundary(key: windowShot, child: child),
      locale: Locale(currentLanguage),
      supportedLocales: [for (final code in languageNames.keys) Locale(code)],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      debugShowCheckedModeBanner: false,
      theme: appTheme(MediaQuery.platformBrightnessOf(context), look['colors'] as Map? ?? {}, radius),
      home: ManagerHome(core: widget.core, jobs: jobs, onRestart: widget.onRestart, checkOnStart: widget.checkOnStart, onLanguageChanged: _loadSettings, languageSetting: languageSetting,
          cornersSetting: cornersSetting, screenshotKey: screenshotKey, onSettingsChanged: _loadSettings),
    );
  }
}

/// "Screenshot saved": where, and a field for what is wrong. Done, Enter, Esc and a click beside it
/// all close it with the text typed (the field's controller lives and goes with the dialog).
class ScreenshotNoteDialog extends StatefulWidget {
  const ScreenshotNoteDialog({super.key, required this.path});
  final String path;
  @override
  State<ScreenshotNoteDialog> createState() => _ScreenshotNoteDialogState();
}

class _ScreenshotNoteDialogState extends State<ScreenshotNoteDialog> {
  final _note = TextEditingController();

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  void _done() => Navigator.pop(context, _note.text);

  @override
  Widget build(BuildContext context) => PopScope<String>(
    canPop: false,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) _done(); // Esc or a click beside it: the note is kept too
    },
    child: AlertDialog(
      title: Text(tr('Screenshot saved')),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectableText(trf('Saved as {0}', [homeShort(widget.path)])),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('screenshot-note'),
              controller: _note,
              autofocus: true,
              maxLength: screenshotNoteLimit,
              decoration: InputDecoration(hintText: tr('What is wrong? (optional)'), counterText: ''),
              onSubmitted: (_) => _done(),
            ),
          ],
        ),
      ),
      actions: [FilledButton(onPressed: _done, child: Text(tr('Done')))],
    ),
  );
}

final class _NoPicture implements Exception {
  @override
  String toString() => tr('The window drew nothing.');
}
