import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

final class RunResult {
  RunResult(this.code, this.stdout, this.stderr);
  final int code;
  final String stdout;
  final String stderr;
  bool get ok => code == 0;
}

/// Runs read-only helper commands (git, pacman -Q) with the given environment only; the
/// program is looked up in that environment's PATH, so tests can put fakes first.
final class Runner {
  Runner(this.environment);

  final Map<String, String> environment;

  /// The program's full path from PATH, or null.
  String? which(String command) {
    if (command.contains('/')) return _isExecutable(command) ? command : null;
    for (final dir in (environment['PATH'] ?? '').split(':')) {
      if (dir.isEmpty) continue;
      final candidate = p.join(dir, command);
      if (_isExecutable(candidate)) return candidate;
    }
    return null;
  }

  Future<RunResult> run(
    List<String> argv, {
    String? cwd,
    Map<String, String> extraEnv = const {},
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final exe = which(argv.first);
    if (exe == null) return RunResult(127, '', '${argv.first}: not found');
    final Process process;
    try {
      process = await Process.start(
        exe,
        argv.sublist(1),
        workingDirectory: cwd,
        environment: {...environment, ...extraEnv},
        includeParentEnvironment: false,
      );
    } on ProcessException catch (e) {
      return RunResult(126, '', e.message);
    }
    await process.stdin.close();
    final out = process.stdout.transform(utf8.decoder).join();
    final err = process.stderr.transform(utf8.decoder).join();
    final int code;
    try {
      code = await process.exitCode.timeout(timeout);
    } on TimeoutException {
      process.kill(ProcessSignal.sigterm);
      await process.exitCode;
      return RunResult(124, await out, '${await err}\ntimed out');
    }
    return RunResult(code, await out, await err);
  }
}

bool _isExecutable(String path) {
  try {
    final st = File(path).statSync();
    return st.type == FileSystemEntityType.file && st.mode & 0x49 != 0; // any x bit
  } on FileSystemException {
    return false;
  }
}

bool isExecutableFile(String path) => _isExecutable(path);
