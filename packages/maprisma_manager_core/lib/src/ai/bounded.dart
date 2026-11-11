import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

/// launcher_core.read_bounded_output: a command's stdout, at most [maxBytes],
/// within [timeout]; null when it fails, runs too long or says too much.
/// An empty [okCodes] accepts any exit code (pacman -Qo counts its misses).
/// Stderr is discarded; the process is killed when a bound is hit.
Future<Uint8List?> readBoundedBytes(
  List<String> command, {
  int maxBytes = 64 * 1024,
  Duration timeout = const Duration(seconds: 1),
  Set<int> okCodes = const {0},
  Map<String, String>? environment,
}) async {
  Process process;
  try {
    process = await Process.start(
      command.first,
      command.sublist(1),
      environment: environment,
      includeParentEnvironment: environment == null,
    );
  } on ProcessException {
    return null;
  }
  process.stdin.close().ignore();
  final err = process.stderr.drain<void>();
  final out = BytesBuilder(copy: false);
  var tooMuch = false;
  final done = Completer<void>();
  late StreamSubscription<List<int>> sub;
  sub = process.stdout.listen(
    (chunk) {
      if (out.length + chunk.length > maxBytes) {
        tooMuch = true;
        process.kill(ProcessSignal.sigkill);
        sub.cancel();
        if (!done.isCompleted) done.complete();
        return;
      }
      out.add(chunk);
    },
    onDone: () {
      if (!done.isCompleted) done.complete();
    },
    onError: (_) {
      if (!done.isCompleted) done.complete();
    },
  );
  try {
    await done.future.timeout(timeout);
    final code = await process.exitCode.timeout(timeout);
    await err.timeout(timeout, onTimeout: () {});
    if (tooMuch || !(okCodes.contains(code) || okCodes.isEmpty)) return null;
    return out.takeBytes();
  } on TimeoutException {
    process.kill(ProcessSignal.sigkill);
    await sub.cancel();
    return null;
  }
}

Future<String?> readBoundedText(
  List<String> command, {
  int maxBytes = 64 * 1024,
  Duration timeout = const Duration(seconds: 1),
  Set<int> okCodes = const {0},
  Map<String, String>? environment,
}) async {
  final bytes = await readBoundedBytes(command, maxBytes: maxBytes, timeout: timeout, okCodes: okCodes, environment: environment);
  return bytes == null ? null : utf8.decode(bytes, allowMalformed: true);
}

/// updates.run_bounded: (exit code, stdout + stderr) under one byte cap and
/// one deadline; the code is null when the command could not start, ran
/// too long or said too much (then it is killed). [stopWhen], checked every
/// half second while it runs, kills it too when it returns true (e.g. a
/// clone whose folder grew too large). [group]: the command starts its own
/// process group (it is run under `setsid`), and every kill, and the end of
/// a normal run, ends the whole group, so no child (git's transport or
/// checkout helpers) outlives it.
Future<(int?, String)> runBounded(
  List<String> command, {
  int maxBytes = 64 * 1024,
  Duration timeout = const Duration(seconds: 1),
  Map<String, String>? environment,
  Future<bool> Function()? stopWhen,
  bool group = false,
}) async {
  Process process;
  try {
    process = await Process.start(
      command.first,
      command.sublist(1),
      environment: environment,
      includeParentEnvironment: environment == null,
    );
  } on ProcessException {
    return (null, '');
  }
  process.stdin.close().ignore();
  void killAll() {
    if (!group || _killPid(-process.pid, 9) != 0) process.kill(ProcessSignal.sigkill);
  }

  final out = BytesBuilder(copy: false);
  var tooMuch = false;
  void take(List<int> chunk) {
    if (tooMuch) return;
    if (out.length + chunk.length > maxBytes) {
      tooMuch = true;
      killAll();
      return;
    }
    out.add(chunk);
  }

  final streams = [process.stdout.listen(take).asFuture<void>(), process.stderr.listen(take).asFuture<void>()];
  var checking = false; // one check at a time; a slow one is not started again meanwhile
  final watch = stopWhen == null
      ? null
      : Timer.periodic(const Duration(milliseconds: 500), (_) async {
          if (tooMuch || checking) return;
          checking = true;
          try {
            if (await stopWhen()) {
              tooMuch = true;
              killAll();
            }
          } finally {
            checking = false;
          }
        });
  try {
    final code = await process.exitCode.timeout(timeout);
    watch?.cancel();
    if (group) _killPid(-process.pid, 9); // leftovers of its group (none: ESRCH, harmless)
    // killed: a child (git's transport helper) may still hold the pipes open; don't wait for it
    await Future.wait(streams).timeout(tooMuch ? const Duration(seconds: 1) : timeout, onTimeout: () => const []);
    return (tooMuch ? null : code, utf8.decode(out.takeBytes(), allowMalformed: true));
  } on TimeoutException {
    watch?.cancel();
    killAll();
    return (null, utf8.decode(out.takeBytes(), allowMalformed: true));
  }
}

final _killPid = DynamicLibrary.open('libc.so.6').lookupFunction<Int Function(Int, Int), int Function(int, int)>('kill');
