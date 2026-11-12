import 'dart:io';

import 'package:path/path.dart' as p;

import 'catalog_model.dart';
import 'paths.dart';

/// A running process of the user's, as /proc shows it.
final class ProcInfo {
  ProcInfo(this.pid, this.uid, this.exe, this.argv, this.startTicks, {this.ppid});
  final int pid;

  /// The parent's pid (field 4 of `/proc/<pid>/stat`).
  final int? ppid;
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
    int? start, ppid;
    try {
      final stat = File(p.join(entry.path, 'stat')).readAsStringSync();
      // comm may hold spaces and parentheses: the fields start after the last ')'.
      final fields = stat.substring(stat.lastIndexOf(')') + 2).split(' ');
      if (fields.length > 19) start = int.tryParse(fields[19]);
      if (fields.length > 1) ppid = int.tryParse(fields[1]);
    } on Object {
      start = null;
    }
    out.add(ProcInfo(pid, owner, exe, argv, start, ppid: ppid));
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
      // The script is what the interpreter runs: its first argument that is not an option
      // (`python3 -I <script>`, `bash <script>`). A file named later (an editor, `cat`) is not.
      // …and the process is an interpreter, so `nvim -R <script>` is not the helper.
      final prog = p.basename(proc.exe ?? (proc.argv.isEmpty ? '' : proc.argv.first));
      if (!_interpreter.hasMatch(prog)) return false;
      final arg = proc.argv.skip(1).firstWhere((a) => !a.startsWith('-'), orElse: () => '');
      if (!p.isAbsolute(arg)) return false;
      final n = p.normalize(arg);
      return m.kind == MatchKind.script ? p.equals(n, path) : p.isWithin(path, n);
    case MatchKind.quickshellConfig:
      final prog = p.basename(proc.exe ?? (proc.argv.isEmpty ? '' : proc.argv.first));
      if (prog != 'quickshell' && prog != 'qs') return false;
      final args = proc.argv.skip(1).toList();
      for (var i = 0; i < args.length; i++) {
        final a = args[i];
        String? flag, value;
        final eq = a.indexOf('=');
        if (a.startsWith('--') && eq > 0) {
          flag = a.substring(0, eq);
          value = a.substring(eq + 1);
        } else if (a == '-c' || a == '--config' || a == '-p' || a == '--path') {
          flag = a;
          value = i + 1 < args.length ? args[i + 1] : null;
        }
        if (value == null) continue;
        if (flag == '-c' || flag == '--config') {
          // A name means <the user's config>/quickshell/<name>: only the real folder matches
          // (a test's temp HOME never claims the user's running bar).
          if (p.equals(path, p.join(quickshellConfigRoot ?? _realQuickshellRoot(), value))) return true;
        } else if (flag == '-p' || flag == '--path') {
          if (!p.isAbsolute(value)) continue;
          final n = p.normalize(value);
          if (p.equals(n, path) || p.equals(n, p.join(path, 'shell.qml'))) return true;
        }
      }
      return false;
  }
}

/// Where `qs -c <name>` looks: tests set it, otherwise the real XDG_CONFIG_HOME/quickshell.
String? quickshellConfigRoot;

String _realQuickshellRoot() {
  final env = Platform.environment;
  final xdg = env['XDG_CONFIG_HOME'];
  final config = xdg != null && p.isAbsolute(xdg) ? xdg : p.join(env['HOME'] ?? '/', '.config');
  return p.join(config, 'quickshell');
}

final _interpreter = RegExp(r'^(python[0-9.]*|bash|sh|dash|zsh)$');

/// The app's running processes with the match that found them.
List<(ProcInfo, ProcessMatch)> matchingProcesses(AppEntry app, Paths paths, List<ProcInfo> procs) {
  final out = <(ProcInfo, ProcessMatch)>[];
  // The lexical path and, when it exists, the physical one: /proc shows resolved paths
  // (a symlinked HOME or install folder); a deleted executable only matches lexically.
  final targets = [
    for (final m in app.processes)
      for (final path in {paths.expand(m.path), ?_resolved(paths.expand(m.path))}) (m, path),
  ];
  for (final proc in procs) {
    for (final (m, path) in targets) {
      if (processMatches(m, path, proc)) {
        out.add((proc, m));
        break;
      }
    }
  }
  return out;
}

/// The app's running processes: [{pid, exe, argv0, match}].
List<Map<String, dynamic>> runningFor(AppEntry app, Paths paths, List<ProcInfo> procs) => [
  for (final (proc, m) in matchingProcesses(app, paths, procs))
    {'pid': proc.pid, 'exe': proc.exe, 'argv': proc.argv.take(3).toList(), 'match': m.kind.name, 'startTicks': proc.startTicks},
];

String? _resolved(String path) {
  try {
    final type = FileSystemEntity.typeSync(path);
    if (type == FileSystemEntityType.notFound) return null;
    final r = type == FileSystemEntityType.directory
        ? Directory(path).resolveSymbolicLinksSync()
        : File(path).resolveSymbolicLinksSync();
    return r == path ? null : r;
  } on FileSystemException {
    return null;
  }
}
