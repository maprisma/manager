import 'package:maprisma_manager_core/maprisma_manager_core.dart' show configureLanguage;
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'app.dart';
import 'backend.dart';
import 'window.dart';
import 'window_size.dart';

/// `maprisma-settings` (or its old name `maprisma-manager`): the window. With MAPRISMA_MANAGER_READY (the self-update helper started this
/// build) the file gets this process' pid after the first frame: the helper keeps the new build then.
Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final backend = await Backend.start();
  final settings = await backend.call('settings.get');
  configureLanguage(settings['language'] as String?);
  // Rule 5a: the window opens at the size the user left it (before the first frame shows it).
  final size = parseWindowSize(settings['window_size']);
  if (size != null) unawaited(AppWindow.resize(size.$1, size.$2));
  final look = await backend.call('desktop.look').catchError((_) => <String, dynamic>{});
  final ready = Platform.environment['MAPRISMA_MANAGER_READY'];
  if (ready != null && ready.isNotEmpty) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      try {
        File('$ready.tmp')
          ..writeAsStringSync('$pid\n')
          ..renameSync(ready);
      } on FileSystemException {
        // the helper rolls back then
      }
    });
  }
  runApp(ManagerApp(
    // The bar icon's menu: `--page <page>`.
    page: AppWindow.pageOf(args),
    core: backend.call,
    look: look,
    settings: settings,
    // The Manager's own update is staged: quit, the helper swaps it in and starts the new one.
    onRestart: () => exit(0),
  ));
}
