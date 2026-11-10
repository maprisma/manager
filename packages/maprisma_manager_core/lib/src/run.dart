import 'translations.dart';
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
    if (exe == null) return RunResult(127, '', trf('{0}: not found', [argv.first]));
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
    final out = StringBuffer(), err = StringBuffer();
    final outDone = process.stdout.transform(utf8.decoder).forEach(out.write);
    final errDone = process.stderr.transform(utf8.decoder).forEach(err.write);
    int code;
    var timedOut = false;
    try {
      code = await process.exitCode.timeout(timeout);
    } on TimeoutException {
      timedOut = true;
      process.kill(ProcessSignal.sigterm);
      try {
        code = await process.exitCode.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        process.kill(ProcessSignal.sigkill);
        code = await process.exitCode.timeout(const Duration(seconds: 2), onTimeout: () => -9);
      }
    }
    // A child that keeps the pipes open must not hold the answer back.
    try {
      await Future.wait([outDone, errDone]).timeout(const Duration(seconds: 2));
    } on TimeoutException {
      // keep what came
    }
    if (timedOut) return RunResult(124, '$out', trf('{0}\ntimed out', [err]));
    return RunResult(code, '$out', '$err');
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
