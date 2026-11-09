import 'dart:io';

import 'package:maprisma_manager_core/maprisma_manager_core.dart';

Future<void> main(List<String> args) async {
  final code = await runCli(args);
  await stdout.flush();
  exit(code);
}
