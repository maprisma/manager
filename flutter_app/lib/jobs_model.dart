import 'package:maprisma_manager_core/maprisma_manager_core.dart' show tr;
import 'dart:async';

import 'package:flutter/foundation.dart';

import 'backend.dart' show ServiceError;
import 'core_call.dart';

/// The jobs this window started (install, update, reinstall, remove, release): the core runs one
/// at a time and queues the rest; this follows them (`jobs.get` + `jobs.log` every [every]) for the
/// log sheet and tells the page when one has ended.
class JobsModel extends ChangeNotifier {
  JobsModel(this.core, {this.every = const Duration(milliseconds: 400)});
  final CoreCall core;
  final Duration every;

  /// Every job started here, oldest first: `{job, app, name, kind, log, next, ...}`.
  final List<JobView> jobs = [];

  /// The one the sheet shows (the running one, else the last).
  JobView? get shown {
    for (final j in jobs) {
      if (j.state == 'running') return j;
    }
    for (final j in jobs) {
      if (j.state == 'queued') return j;
    }
    return jobs.isEmpty ? null : jobs.last;
  }

  /// Jobs waiting behind the shown one.
  int get queued => jobs.where((j) => j.state == 'queued' && j != shown).length;

  bool get busy => jobs.any((j) => !j.finished);

  /// Called once per job when it has ended (the page reloads; the Manager's own update restarts).
  void Function(JobView job)? onFinished;

  Timer? _timer;
  bool _polling = false;

  /// Starts a job; the core refuses with `busy`, `unsupported_yet` … (thrown as [ServiceError]).
  Future<JobView> start({required String app, required String name, required String kind, Map<String, dynamic> options = const {}, bool password = false}) async {
    final r = await core('jobs.start', {'app': app, 'kind': kind, 'options': options});
    final j = JobView(id: r['id'] as String, app: app, name: name, kind: kind, password: password)..data = r;
    jobs.add(j);
    if (jobs.length > 30) jobs.removeAt(0);
    notifyListeners();
    _timer ??= Timer.periodic(every, (_) => _poll());
    unawaited(_poll());
    return j;
  }

  Future<Map<String, dynamic>> cancel(JobView j) async {
    final r = await core('jobs.cancel', {'id': j.id});
    await _poll();
    return r;
  }

  Future<void> _poll() async {
    if (_polling) return;
    _polling = true;
    try {
      var changed = false;
      for (final j in [...jobs]) {
        if (j.finished && j.logDone) continue;
        try {
          if (!j.finished) {
            final d = await core('jobs.get', {'id': j.id});
            j.data = d;
            changed = true;
          }
          // the log: everything new, at most a few reads per tick
          for (var i = 0; i < 4; i++) {
            final l = await core('jobs.log', {'id': j.id, 'from': j.next});
            final text = '${l['text'] ?? ''}';
            j.next = l['next'] as int? ?? j.next;
            if (text.isNotEmpty) {
              j.log.write(text);
              changed = true;
            }
            if (l['finished'] == true && text.isEmpty) j.logDone = j.finished;
            if (text.isEmpty) break;
          }
        } on ServiceError {
          // try again next tick
        }
        if (j.finished && ++j.ticksAfterEnd > 10) j.logDone = true;
        if (j.finished && !j.reported) {
          j.reported = true;
          changed = true;
          onFinished?.call(j);
        }
      }
      if (!busy && jobs.every((j) => j.reported && j.logDone)) {
        _timer?.cancel();
        _timer = null;
      }
      if (changed) notifyListeners();
    } finally {
      _polling = false;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

class JobView {
  JobView({required this.id, required this.app, required this.name, required this.kind, this.password = false});
  final String id, app, name, kind;

  /// It asks for the password (pkexec's dialog: Maprisma's pacman steps).
  final bool password;
  Map<String, dynamic> data = {};
  final log = StringBuffer();
  int next = 0;
  bool logDone = false, reported = false;
  int ticksAfterEnd = 0;

  String get state => '${data['state'] ?? 'queued'}';
  String get phase => '${data['phase'] ?? 'queued'}';
  bool get finished => const {'succeeded', 'failed', 'cancelled', 'interrupted'}.contains(state);
  bool get cancellable => data['cancellable'] == true && !finished;
  Map get result => data['result'] as Map? ?? const {};

  /// "Installing Maprisma WLAN Monitor" …
  String get title => '${switch (kind) {
    'install' => tr('Installing'),
    'update' => tr('Updating'),
    'reinstall' => tr('Reinstalling'),
    'remove' => tr('Uninstalling'),
    'release' => tr('Installing the release of'),
    _ => kind,
  }} $name';
}
