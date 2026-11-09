import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:maprisma_manager_core/maprisma_manager_core.dart';

export 'package:maprisma_manager_core/maprisma_manager_core.dart'
    show ServiceError;

void _serve((SendPort, Map<String, String>) args) {
  final inbox = ReceivePort();
  final service = CoreService(environment: args.$2);
  args.$1.send(inbox.sendPort);
  inbox.listen((message) {
    if (message == null) {
      inbox.close();
    } else if (message is String) {
      service.handleAsync(message).then(args.$1.send);
    }
  });
}

/// The core in a background isolate, spoken to with protocol frames.
final class Backend {
  Backend._();
  final _inbox = ReceivePort(), _errors = ReceivePort();
  final _ready = Completer<SendPort>();
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  Isolate? _isolate;
  SendPort? _send;
  var _id = 0;
  var _closed = false;

  static Future<Backend> start() async {
    final b = Backend._();
    b._ready.future.ignore();
    b._inbox.listen(b._receive);
    b._errors.listen((_) => b._fail(StateError('Core isolate failed')));
    b._isolate = await Isolate.spawn(
      _serve,
      (b._inbox.sendPort, Map<String, String>.of(Platform.environment)),
      onError: b._errors.sendPort,
      errorsAreFatal: true,
    );
    b._send = await b._ready.future.timeout(const Duration(seconds: 10));
    return b;
  }

  void _receive(dynamic message) {
    if (message is SendPort) {
      if (!_ready.isCompleted) _ready.complete(message);
      return;
    }
    if (message is! String) return;
    final data = jsonDecode(message) as Map<String, dynamic>;
    final pending = _pending.remove(data['id']);
    if (pending == null) return;
    if (data['error'] case final Map error) {
      pending.completeError(
        ServiceError('${error['code']}', error['message'] as String?),
      );
    } else {
      pending.complete(data['result'] as Map<String, dynamic>);
    }
  }

  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> params = const {},
  ]) {
    if (_closed) return Future.error(StateError('Core closed'));
    final id = ++_id;
    final pending = Completer<Map<String, dynamic>>();
    _pending[id] = pending;
    _send!.send(
      jsonEncode({
        'protocol': protocolVersion,
        'id': id,
        'method': method,
        'params': params,
      }),
    );
    // Fetching every repo and asking GitHub can take a while; icon changes restart applets.
    return pending.future.timeout(
      switch (method) {
        'git.fetch' || 'github.refresh' => const Duration(minutes: 3),
        'icons.set' || 'icons.reset' || 'bar.place' || 'bar.move' || 'bar.remove' => const Duration(minutes: 2),
        _ => const Duration(seconds: 90),
      },
      onTimeout: () {
        _pending.remove(id);
        throw ServiceError('timeout');
      },
    );
  }

  void _fail(Object error) {
    if (_closed) return;
    _closed = true;
    for (final p in _pending.values) {
      p.completeError(error);
    }
    _pending.clear();
    _isolate?.kill(priority: Isolate.immediate);
    _inbox.close();
    _errors.close();
  }

  void dispose() => _fail(StateError('Core closed'));
}
