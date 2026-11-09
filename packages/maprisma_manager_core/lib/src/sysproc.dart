/// Signals and process identity for the job engine: process groups (the install script runs
/// in its own session, `setsid`), and the safe stop of an app's processes (plan: "Processes").
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'procs.dart';

const sigKill = 9;
const sigTerm = 15;
const sigCont = 18;
const sigStop = 19;

typedef _KillC = Int32 Function(Int32, Int32);
typedef _KillD = int Function(int, int);
final _kill = DynamicLibrary.process().lookupFunction<_KillC, _KillD>('kill');

/// What `/proc/<pid>/stat` says about a process: its identity (pid + start ticks), parent, group.
final class ProcStat {
  ProcStat(this.pid, this.state, this.ppid, this.pgrp, this.start);
  final int pid;
  final String state;
  final int ppid;
  final int pgrp;
  final int start;
  bool get zombie => state == 'Z' || state == 'X';
}

ProcStat? procStat(int pid, {String procRoot = '/proc'}) {
  try {
    final stat = File(p.join(procRoot, '$pid', 'stat')).readAsStringSync();
    final f = stat.substring(stat.lastIndexOf(')') + 2).split(' ');
    return ProcStat(pid, f[0], int.parse(f[1]), int.parse(f[2]), int.parse(f[19]));
  } on Object {
    return null;
  }
}

/// The process [pid] is still the one that started at [start] (and not a zombie).
bool sameProcess(int pid, int? start, {String procRoot = '/proc'}) {
  final s = procStat(pid, procRoot: procRoot);
  return s != null && !s.zombie && (start == null || s.start == start);
}

/// Sends signals. The real one refuses pid ≤ 1 and this process' own group; tests (and a fake
/// /proc, whose pids aren't real) use [Signaller.recording], which signals nothing.
class Signaller {
  Signaller();

  /// Records the signals instead of sending them.
  factory Signaller.recording() = _Recording;

  final List<String> sent = [];

  late final int _ownGroup = procStat(pid)?.pgrp ?? pid;

  bool signal(int target, int sig) {
    if (target <= 1 || target == pid) return false;
    sent.add('$target:$sig');
    return _kill(target, sig) == 0;
  }

  bool group(int pgid, int sig) {
    if (pgid <= 1 || pgid == _ownGroup || pgid == pid) return false;
    sent.add('-$pgid:$sig');
    return _kill(-pgid, sig) == 0;
  }
}

final class _Recording extends Signaller {
  @override
  bool signal(int target, int sig) {
    sent.add('$target:$sig');
    return true;
  }

  @override
  bool group(int pgid, int sig) {
    sent.add('-$pgid:$sig');
    return true;
  }
}

/// The user's uid of a process now (null when gone).
int? procUid(int pid, {String procRoot = '/proc'}) {
  try {
    for (final line in File(p.join(procRoot, '$pid', 'status')).readAsLinesSync()) {
      if (line.startsWith('Uid:')) return int.tryParse(line.substring(4).trim().split(RegExp(r'\s+')).first);
    }
  } on FileSystemException {
    // gone
  }
  return null;
}

/// Stops [procs] the safe way: each one only while it is still the same process (pid + start
/// ticks) and the user's own; TERM, wait up to [grace], then KILL what is left, after checking
/// its identity once more. Never by name. Returns what happened per pid.
Future<List<Map<String, dynamic>>> stopProcesses(
  List<ProcInfo> procs, {
  required Signaller signaller,
  required String procRoot,
  required int? uid,
  Duration grace = const Duration(seconds: 5),
  Duration step = const Duration(milliseconds: 100),
}) async {
  final out = <int, Map<String, dynamic>>{};
  bool still(ProcInfo pr) =>
      sameProcess(pr.pid, pr.startTicks, procRoot: procRoot) && (uid == null || procUid(pr.pid, procRoot: procRoot) == uid);
  final termed = <ProcInfo>[];
  for (final pr in procs) {
    if (pr.pid == pid) continue;
    if (!still(pr)) {
      out[pr.pid] = {'pid': pr.pid, 'exe': pr.exe, 'result': 'gone'};
      continue;
    }
    if (signaller.signal(pr.pid, sigTerm)) {
      termed.add(pr);
      out[pr.pid] = {'pid': pr.pid, 'exe': pr.exe, 'result': 'terminated'};
    } else {
      out[pr.pid] = {'pid': pr.pid, 'exe': pr.exe, 'result': 'could not signal'};
    }
  }
  final until = DateTime.now().add(grace);
  var left = termed.where(still).toList();
  while (left.isNotEmpty && DateTime.now().isBefore(until)) {
    await Future<void>.delayed(step);
    left = left.where(still).toList();
  }
  for (final pr in left) {
    // The identity once more right before KILL: a recycled pid is never hit.
    if (still(pr) && signaller.signal(pr.pid, sigKill)) out[pr.pid]!['result'] = 'killed';
  }
  if (left.isNotEmpty) {
    final until2 = DateTime.now().add(const Duration(seconds: 2));
    while (left.any(still) && DateTime.now().isBefore(until2)) {
      await Future<void>.delayed(step);
    }
    for (final pr in left.where(still)) {
      out[pr.pid]!['result'] = 'still running';
    }
  }
  return out.values.toList();
}
