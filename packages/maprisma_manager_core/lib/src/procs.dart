import 'dart:io';

import 'package:path/path.dart' as p;

import 'catalog_model.dart';
import 'paths.dart';

/// A running process of the user's, as /proc shows it.
final class ProcInfo {
  ProcInfo(this.pid, this.uid, this.exe, this.argv, this.startTicks);
  final int pid;
  final int? uid;

  /// `/proc/<pid>/exe` with " (deleted)" stripped; null when unreadable.
  final String? exe;
  final List<String> argv;

  /// Field 22 of `/proc/<pid>/stat`: with the pid, the process' identity (plan: checked before KILL).
  final int? startTicks;
}

/// The current user's id (from the real /proc, whatever [Paths.proc] is).
int? currentUid() => _uidOf(File('/proc/self/status'));

int? _uidOf(File status) {
  try {
    for (final line in status.readAsLinesSync()) {
      if (line.startsWith('Uid:')) return int.tryParse(line.substring(4).trim().split(RegExp(r'\s+')).first);
    }
  } on FileSystemException {
    // gone
  }
  return null;
}

/// The processes of [uid] (all readable ones when null).
List<ProcInfo> listProcesses(String procRoot, {int? uid}) {
  final out = <ProcInfo>[];
  final Directory root = Directory(procRoot);
  if (!root.existsSync()) return out;
  for (final entry in root.listSync(followLinks: false)) {
    final pid = int.tryParse(p.basename(entry.path));
    if (pid == null) continue;
    final owner = _uidOf(File(p.join(entry.path, 'status')));
    if (uid != null && owner != uid) continue;
    String? exe;
    try {
      exe = Link(p.join(entry.path, 'exe')).targetSync();
      if (exe.endsWith(' (deleted)')) exe = exe.substring(0, exe.length - ' (deleted)'.length);
    } on FileSystemException {
      exe = null;
    }
    var argv = const <String>[];
    try {
      final raw = File(p.join(entry.path, 'cmdline')).readAsBytesSync();
      argv = String.fromCharCodes(raw).split('\u0000');
      if (argv.isNotEmpty && argv.last.isEmpty) argv = argv.sublist(0, argv.length - 1);
    } on FileSystemException {
      // gone or unreadable
    }
    int? start;
    try {
      final stat = File(p.join(entry.path, 'stat')).readAsStringSync();
      // comm may hold spaces and parentheses: the fields start after the last ')'.
      final fields = stat.substring(stat.lastIndexOf(')') + 2).split(' ');
      if (fields.length > 19) start = int.tryParse(fields[19]);
    } on Object {
      start = null;
    }
    out.add(ProcInfo(pid, owner, exe, argv, start));
  }
  return out;
}

/// Whether [proc] is one of [m]'s processes. Interpreted helpers match by their script's
/// path in argv after argv[0] (normalized: they are started as `{bin}/../share/…`), never by
/// the interpreter.
bool processMatches(ProcessMatch m, String path, ProcInfo proc) {
  switch (m.kind) {
    case MatchKind.exe:
      return proc.exe != null && p.equals(proc.exe!, path);
    case MatchKind.exeUnder:
      final exe = proc.exe;
      if (exe == null) return false;
      if (p.isWithin(path, exe)) return true;
      // the atomic swap's siblings: <dir>.new.XXXX/…, <dir>.old.XXXX/…
      final parent = p.dirname(path), base = p.basename(path);
      if (!p.isWithin(parent, exe)) return false;
      final first = p.split(p.relative(exe, from: parent)).first;
      return first.startsWith('$base.') && p.split(p.relative(exe, from: parent)).length > 1;
    case MatchKind.script:
    case MatchKind.scriptUnder:
      for (final arg in proc.argv.skip(1)) {
        if (!p.isAbsolute(arg)) continue;
        final n = p.normalize(arg);
        if (m.kind == MatchKind.script ? p.equals(n, path) : p.isWithin(path, n)) return true;
      }
      return false;
  }
}

/// The app's running processes: [{pid, exe, argv0, match}].
List<Map<String, dynamic>> runningFor(AppEntry app, Paths paths, List<ProcInfo> procs) {
  final out = <Map<String, dynamic>>[];
  for (final proc in procs) {
    for (final m in app.processes) {
      if (processMatches(m, paths.expand(m.path), proc)) {
        out.add({'pid': proc.pid, 'exe': proc.exe, 'argv': proc.argv.take(3).toList(), 'match': m.kind.name, 'startTicks': proc.startTicks});
        break;
      }
    }
  }
  return out;
}
