import 'dart:io';

import 'package:flutter/material.dart';

import 'app.dart';
import 'backend.dart';

/// `maprisma-manager`: the window. With MAPRISMA_MANAGER_READY (the self-update helper started this
/// build) the file gets this process' pid after the first frame: the helper keeps the new build then.
Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final backend = await Backend.start();
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
    core: backend.call,
    look: look,
    // The Manager's own update is staged: quit, the helper swaps it in and starts the new one.
    onRestart: () => exit(0),
  ));
}
