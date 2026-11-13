import 'translations.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'context.dart';
import 'run.dart' show isExecutableFile;
import 'sound.dart';

/// The Voice page (`voice.*`): Maprisma Dictation's voice service `maprisma-voice`, always
/// through its command line (argv lists, never a shell; bounded output, time limits), so the
/// service checks every value in one place: `status --json`, `models --json`, `get`,
/// `set KEY VALUE` (VALUE as JSON), `unset KEY`, `model download|remove NAME` and
/// `dictate --seconds N`. A download and a try run in the background, one of each at a time,
/// and are polled with `voice.tasks`; `voice.cancel` ends them. The contract is
/// maprisma-dictation's docs/protocol.md.
final class VoiceService {
  VoiceService(this.ctx, this.sound);
  final Ctx ctx;
  final SoundService sound;

  static const repoUrl = 'https://github.com/maprisma/dictation';

  /// The engines in the service's order of choice (status `engines` lists the available ones).
  static const engines = ['whisper', 'online', 'omarchy', 'voxtype', 'superwhisper'];

  /// The settings the page sets; the service checks the values.
  static const keys = {'enabled', 'engine', 'model', 'language', 'microphone', 'unload_minutes', 'preload'};

  /// At most this much of a command's stdout and stderr is kept.
  static const maxOutput = 256 * 1024;
  static const _stderrTail = 4096;

  static final _name = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,80}$');

  /// Test hooks: the time limits of a download and of the answers.
  Duration downloadTimeout = const Duration(hours: 2);
  Duration quickTimeout = const Duration(seconds: 10);

  final Map<String, VoiceTask> _tasks = {};

  /// `~/.local/bin/maprisma-voice` (where install.sh puts it), else the one on PATH.
  String? binary() {
    final own = p.join(ctx.paths.bin, 'maprisma-voice');
    if (isExecutableFile(own)) return own;
    return ctx.runner.which('maprisma-voice');
  }

  String _need() => binary() ?? (throw RouteError('not_installed', tr('maprisma-voice is not installed')));

  Future<Process?> _start(String exe, List<String> args) async {
    try {
      final process = await Process.start(exe, args, environment: ctx.environment, includeParentEnvironment: false);
      process.stdin.close().ignore();
      return process;
    } on ProcessException {
      return null;
    }
  }

  /// One short command: (exit code, stdout, stderr); the code is null when it could not start,
  /// ran too long or said too much (then it is killed).
  Future<(int?, String, String)> _run(String exe, List<String> args, {Duration? timeout}) async {
    final process = await _start(exe, args);
    if (process == null) return (null, '', trf('could not start {0}', [exe]));
    final out = BytesBuilder(copy: false), err = BytesBuilder(copy: false);
    var tooMuch = false;
    void take(BytesBuilder into, List<int> chunk) {
      if (tooMuch) return;
      if (out.length + err.length + chunk.length > maxOutput) {
        tooMuch = true;
        process.kill(ProcessSignal.sigkill);
        return;
      }
      into.add(chunk);
    }

    final streams = [process.stdout.listen((c) => take(out, c)).asFuture<void>(), process.stderr.listen((c) => take(err, c)).asFuture<void>()];
    int? code;
    try {
      code = await process.exitCode.timeout(timeout ?? quickTimeout);
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
    }
    await Future.wait(streams).timeout(const Duration(seconds: 1), onTimeout: () => const []);
    String text(BytesBuilder b) => utf8.decode(b.takeBytes(), allowMalformed: true);
    return (tooMuch ? null : code, text(out), text(err));
  }

  static String _firstLine(String s, int? code) {
    final l = s.trim().split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).firstOrNull;
    return l ?? (code == null ? tr('no answer in time') : trf('exit {0}', [code]));
  }

  Future<Object?> _json(String exe, List<String> args) async {
    final (code, out, _) = await _run(exe, args);
    if (code != 0) return null;
    try {
      return jsonDecode(out);
    } on FormatException {
      return null;
    }
  }

  // --- reading -------------------------------------------------------------------------------

  /// `voice.get`: whether it is installed, the service's status (or why there is none), the
  /// models, the settings file's values, the microphones and the running tasks.
  Future<Map<String, dynamic>> get() async {
    final exe = binary();
    final microphones = sound.microphones();
    if (exe == null) {
      return {'installed': false, 'binary': null, 'install_url': repoUrl, 'microphones': await microphones, 'tasks': tasks()};
    }
    final status = _run(exe, ['status', '--json']);
    final models = _json(exe, ['models', '--json']);
    final settings = _json(exe, ['get']);
    final (code, out, err) = await status;
    Map<String, dynamic>? state;
    String? why;
    if (code == 0) {
      try {
        final v = jsonDecode(out);
        if (v is Map<String, dynamic>) state = v;
      } on FormatException {
        // said below
      }
      if (state == null) why = tr('the voice service gave no readable answer');
    } else {
      why = _firstLine(err, code);
    }
    final m = await models, s = await settings;
    return {
      'installed': true,
      'binary': exe,
      'install_url': repoUrl,
      'status': state,
      'status_error': why,
      'models': m is Map ? m : null,
      'settings': s is Map ? s : const <String, dynamic>{},
      'microphones': await microphones,
      'tasks': tasks(),
    };
  }

  /// `voice.tasks`: {download, dictate}, each null before the first.
  Map<String, dynamic> tasks() => {'download': _tasks['download']?.toJson(), 'dictate': _tasks['dictate']?.toJson()};

  // --- settings ------------------------------------------------------------------------------

  static bool _valueOk(String key, Object? value) => switch (key) {
    'enabled' || 'preload' => value is bool,
    'unload_minutes' => value is int && value >= 0 && value <= 1440,
    _ => value is String && value.length <= 200 && !value.contains('\n') && !value.contains('\x00'),
  };

  String _key(Map<String, dynamic> params) {
    final key = params['key'];
    if (key is! String || !keys.contains(key)) throw RouteError('bad_params', 'key (${keys.join(', ')})');
    return key;
  }

  Future<void> _write(List<String> args) async {
    final (code, _, err) = await _run(_need(), args);
    if (code == 0) return;
    throw RouteError(code == 2 ? 'bad_params' : 'failed', _firstLine(err, code));
  }

  /// `voice.set` {key, value}: `maprisma-voice set KEY <value as JSON>`.
  Future<Map<String, dynamic>> set(Map<String, dynamic> params) async {
    final key = _key(params);
    final value = params['value'];
    if (!_valueOk(key, value)) throw RouteError('bad_params', 'value');
    await _write(['set', key, jsonEncode(value)]);
    return {'key': key, 'value': value};
  }

  /// `voice.unset` {key}: back to the service's default.
  Future<Map<String, dynamic>> unset(Map<String, dynamic> params) async {
    final key = _key(params);
    await _write(['unset', key]);
    return {'key': key};
  }

  // --- models --------------------------------------------------------------------------------

  String _model(Map<String, dynamic> params) {
    final m = params['model'];
    if (m is! String || !_name.hasMatch(m) || m.contains('..')) throw RouteError('bad_params', 'model');
    return m;
  }

  bool _running(String kind) => _tasks[kind]?.state == 'running';

  /// `voice.remove` {model}: only a model the service installed (its own folder).
  Future<Map<String, dynamic>> remove(Map<String, dynamic> params) async {
    final model = _model(params);
    final exe = _need();
    if (_running('download') && _tasks['download']!.model == model) throw RouteError('busy', tr('the model is being downloaded'));
    final (code, _, err) = await _run(exe, ['model', 'remove', model], timeout: const Duration(seconds: 20));
    if (code != 0) throw RouteError('failed', _firstLine(err, code));
    return {'model': model, 'removed': true};
  }

  /// `voice.download` {model}: `model download NAME` in the background (curl's progress bar on
  /// stderr gives the percent; the path on stdout when done).
  Map<String, dynamic> download(Map<String, dynamic> params) {
    final model = _model(params);
    final exe = _need();
    if (_running('download')) throw RouteError('busy', tr('a model is already being downloaded'));
    final task = _tasks['download'] = VoiceTask('download', ctx.clock(), model: model);
    unawaited(_follow(task, exe, ['model', 'download', model], downloadTimeout));
    return {'task': task.toJson()};
  }

  // --- try it --------------------------------------------------------------------------------

  /// `voice.try` {seconds?}: `dictate --seconds N` (1–30, default 5) in the background; the
  /// partial text comes on stderr as "… text", the final text on stdout.
  Map<String, dynamic> tryIt(Map<String, dynamic> params) {
    final seconds = params['seconds'] ?? 5;
    if (seconds is! int || seconds < 1 || seconds > 30) throw RouteError('bad_params', 'seconds (1–30)');
    final exe = _need();
    if (_running('dictate')) throw RouteError('busy', tr('a try is already running'));
    final task = _tasks['dictate'] = VoiceTask('dictate', ctx.clock(), seconds: seconds);
    unawaited(_follow(task, exe, ['dictate', '--seconds', '$seconds'], Duration(seconds: seconds + 90)));
    return {'task': task.toJson()};
  }

  /// `voice.cancel` {kind}: ends a running download (the service's curl dies with it; a
  /// leftover `.part` is removed) or try (the service cancels a session whose client left).
  Future<Map<String, dynamic>> cancel(Map<String, dynamic> params) async {
    final kind = params['kind'];
    if (kind != 'download' && kind != 'dictate') throw RouteError('bad_params', 'kind (download or dictate)');
    final task = _tasks[kind];
    if (task == null || task.state != 'running') throw RouteError('finished', tr('nothing is running'));
    task.cancelled = true;
    task.process?.kill(ProcessSignal.sigterm);
    return {'task': task.toJson()};
  }

  static final _percent = RegExp(r'(\d{1,3}(?:[.,]\d+)?)\s*%');

  Future<void> _follow(VoiceTask task, String exe, List<String> args, Duration timeout) async {
    final process = await _start(exe, args);
    if (process == null) {
      task.finish('failed', ctx.clock(), message: trf('could not start {0}', [exe]));
      return;
    }
    task.process = process;
    if (task.cancelled) process.kill(ProcessSignal.sigterm);
    final out = BytesBuilder(copy: false);
    var tail = '';
    final lines = <String>[];
    void line(String l) {
      final t = l.trim();
      if (t.isEmpty) return;
      if (task.kind == 'download') {
        final m = _percent.allMatches(t).lastOrNull;
        if (m != null && (t.contains('#') || t.endsWith('%'))) {
          task.progress = (double.tryParse(m[1]!.replaceAll(',', '.')) ?? 0).clamp(0, 100).toDouble();
          return;
        }
      } else if (t.startsWith('… ') || t.startsWith('... ')) {
        task.partial = t.substring(t.indexOf(' ') + 1).trim();
        return;
      }
      lines.add(t);
      if (lines.length > 20) lines.removeAt(0);
    }

    final outDone = process.stdout.listen((c) {
      if (out.length + c.length <= maxOutput) out.add(c);
    }).asFuture<void>();
    final errDone = process.stderr.transform(const Utf8Decoder(allowMalformed: true)).listen((chunk) {
      tail += chunk;
      final parts = tail.split(RegExp(r'[\r\n]'));
      tail = parts.removeLast();
      if (tail.length > _stderrTail) tail = tail.substring(tail.length - _stderrTail);
      parts.forEach(line);
      // a progress bar without a line end yet
      if (task.kind == 'download') {
        final m = _percent.allMatches(tail).lastOrNull;
        if (m != null) task.progress = (double.tryParse(m[1]!.replaceAll(',', '.')) ?? 0).clamp(0, 100).toDouble();
      }
    }).asFuture<void>();
    int? code;
    try {
      code = await process.exitCode.timeout(timeout);
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      code = null;
    }
    await Future.wait([outDone, errDone]).timeout(const Duration(seconds: 1), onTimeout: () => const []);
    line(tail);
    final stdout = utf8.decode(out.takeBytes(), allowMalformed: true).trim();
    final said = lines.lastOrNull;
    if (task.cancelled) {
      if (task.kind == 'download' && task.model != null) {
        // a .part left behind by the killed curl (nothing else: the model wasn't there)
        await _run(exe, ['model', 'remove', task.model!], timeout: const Duration(seconds: 20));
      }
      task.finish('cancelled', ctx.clock());
    } else if (code == null) {
      task.finish('failed', ctx.clock(), message: tr('it took too long and was stopped'));
    } else if (task.kind == 'download') {
      if (code == 0) {
        task.progress = 100;
        task.path = stdout.split('\n').last.trim();
        task.finish('succeeded', ctx.clock());
      } else {
        task.finish('failed', ctx.clock(), message: said ?? trf('exit {0}', [code]));
      }
    } else {
      // dictate: 0 text (or an engine typed it: said), 3 no speech, else the reason
      task.text = stdout;
      if (code == 0) {
        task.finish('succeeded', ctx.clock(), message: stdout.isEmpty ? said : null);
      } else {
        task.finish('failed', ctx.clock(), message: said ?? trf('exit {0}', [code]));
      }
    }
  }
}

/// A download or a try, as `voice.tasks` shows it.
final class VoiceTask {
  VoiceTask(this.kind, this.started, {this.model, this.seconds});
  final String kind;
  final String? model;
  final int? seconds;
  final DateTime started;
  DateTime? ended;
  String state = 'running';
  double? progress;
  String partial = '';
  String text = '';
  String? path, message;
  Process? process;
  bool cancelled = false;

  void finish(String to, DateTime at, {String? message}) {
    state = to;
    ended = at;
    if (message != null) this.message = message;
    process = null;
  }

  Map<String, dynamic> toJson() => {
    'kind': kind,
    'state': state,
    'model': ?model,
    'seconds': ?seconds,
    'started': started.toUtc().toIso8601String(),
    if (ended != null) 'ended': ended!.toUtc().toIso8601String(),
    if (kind == 'download') 'progress': progress,
    if (kind == 'dictate') ...{'partial': partial, 'text': text},
    'path': ?path,
    'message': ?message,
  };
}
