import 'translations.dart';
import 'dart:convert';

import 'context.dart';
import 'paths.dart' show Settings;

/// The Sound page on Hyprland (COSMIC Settings' Sound): output and input with volume, mute and
/// device, the applications' streams, the cards' profiles. Through `pactl` (PipeWire's pulse
/// server) and its JSON; no root.
final class SoundService {
  SoundService(this.ctx);
  final Ctx ctx;

  /// The highest volume: 100 %, with Amplification 150 % (COSMIC's toggle).
  static const normalMax = 100, amplifiedMax = 150;

  Future<dynamic> _json(List<String> args) async {
    final r = await ctx.runner.run(['pactl', '-f', 'json', ...args], timeout: const Duration(seconds: 8));
    if (!r.ok) throw RouteError('failed', _firstLine(r.stderr, r.code));
    try {
      return jsonDecode(r.stdout);
    } on FormatException {
      throw RouteError('failed', tr('pactl gave no readable answer'));
    }
  }

  Future<void> _pactl(List<String> args) async {
    final r = await ctx.runner.run(['pactl', ...args], timeout: const Duration(seconds: 8));
    if (!r.ok) throw RouteError('failed', _firstLine(r.stderr, r.code));
  }

  static String _firstLine(String s, int code) {
    final l = s.trim().split('\n').first.trim();
    return l.isEmpty ? trf('exit {0}', [code]) : l;
  }

  /// The average of the channels' volumes in percent.
  static int percent(Object? volume) {
    if (volume is! Map || volume.isEmpty) return 0;
    var sum = 0, n = 0;
    for (final ch in volume.values) {
      final m = RegExp(r'(\d+)%').firstMatch('${(ch as Map)['value_percent']}');
      if (m == null) continue;
      sum += int.parse(m[1]!);
      n++;
    }
    return n == 0 ? 0 : (sum / n).round();
  }

  /// Settings › Amplification (read fresh: the settings route writes the file).
  bool get _amplify => Settings.load(ctx.paths).values['sound_amplify'] == true;

  void _need() {
    if (ctx.runner.which('pactl') == null) throw RouteError('unavailable', tr('pactl is missing (PipeWire\'s pulse server tools)'));
  }

  /// `sound.get`.
  Future<Map<String, dynamic>> get() async {
    _need();
    final info = await _json(['info']) as Map;
    final sinks = (await _json(['list', 'sinks']) as List).cast<Map>();
    final sources = (await _json(['list', 'sources']) as List).cast<Map>();
    final streams = (await _json(['list', 'sink-inputs']) as List).cast<Map>();
    final cards = (await _json(['list', 'cards']) as List).cast<Map>();
    Map<String, dynamic> device(Map d) => {
      'name': d['name'],
      'description': d['description'] ?? d['name'],
      'volume': percent(d['volume']),
      'mute': d['mute'] == true,
    };
    return {
      'default_sink': info['default_sink_name'],
      'default_source': info['default_source_name'],
      'sinks': [for (final s in sinks) device(s)],
      // A sink's monitor is no microphone.
      'sources': [for (final s in sources) if (s['monitor_source'] == null || '${s['monitor_source']}'.isEmpty) device(s)],
      'streams': [
        for (final s in streams)
          {
            'index': s['index'],
            'app': (s['properties'] as Map?)?['application.name'] ?? (s['properties'] as Map?)?['media.name'] ?? '#${s['index']}',
            'media': (s['properties'] as Map?)?['media.name'],
            'volume': percent(s['volume']),
            'mute': s['mute'] == true,
          },
      ],
      'cards': [
        for (final c in cards)
          {
            'name': c['name'],
            'description': (c['properties'] as Map?)?['device.description'] ?? c['name'],
            'active': c['active_profile'],
            'profiles': [
              for (final MapEntry(:key, :value) in ((c['profiles'] as Map?) ?? const {}).entries)
                {'name': key, 'description': (value as Map)['description'] ?? key, 'available': value['available'] != false},
            ],
          },
      ],
      'amplify': _amplify,
    };
  }

  String _target(Map<String, dynamic> params) {
    final t = params['target'];
    if (t != 'sink' && t != 'source') throw RouteError('bad_params', 'target (sink or source)');
    return t as String;
  }

  /// `sound.volume` {target, percent}: the default output's or input's volume.
  Future<Map<String, dynamic>> volume(Map<String, dynamic> params) async {
    _need();
    final t = _target(params);
    final max = _amplify ? amplifiedMax : normalMax;
    final v = params['percent'];
    if (v is! int || v < 0 || v > max) throw RouteError('bad_params', 'percent (0–$max)');
    await _pactl(['set-$t-volume', t == 'sink' ? '@DEFAULT_SINK@' : '@DEFAULT_SOURCE@', '$v%']);
    return {'target': t, 'percent': v};
  }

  /// `sound.mute` {target, mute}.
  Future<Map<String, dynamic>> mute(Map<String, dynamic> params) async {
    _need();
    final t = _target(params);
    final m = params['mute'];
    if (m is! bool) throw RouteError('bad_params', 'mute');
    await _pactl(['set-$t-mute', t == 'sink' ? '@DEFAULT_SINK@' : '@DEFAULT_SOURCE@', m ? '1' : '0']);
    return {'target': t, 'mute': m};
  }

  /// `sound.default` {target, name}: one of the listed devices becomes the default.
  Future<Map<String, dynamic>> setDefault(Map<String, dynamic> params) async {
    _need();
    final t = _target(params);
    final name = params['name'];
    final now = await get();
    final names = [for (final d in (now[t == 'sink' ? 'sinks' : 'sources'] as List)) (d as Map)['name']];
    if (name is! String || !names.contains(name)) throw RouteError('bad_params', 'name');
    await _pactl(['set-default-$t', name]);
    return {'target': t, 'name': name};
  }

  /// `sound.stream` {index, percent?, mute?}: an application's stream.
  Future<Map<String, dynamic>> stream(Map<String, dynamic> params) async {
    _need();
    final index = params['index'];
    if (index is! int || index < 0) throw RouteError('bad_params', 'index');
    final v = params['percent'], m = params['mute'];
    if (v == null && m == null) throw RouteError('bad_params', 'percent or mute');
    final max = _amplify ? amplifiedMax : normalMax;
    if (v != null && (v is! int || v < 0 || v > max)) throw RouteError('bad_params', 'percent (0–$max)');
    if (m != null && m is! bool) throw RouteError('bad_params', 'mute');
    if (v != null) await _pactl(['set-sink-input-volume', '$index', '$v%']);
    if (m != null) await _pactl(['set-sink-input-mute', '$index', m == true ? '1' : '0']);
    return {'index': index};
  }

  /// `sound.profile` {card, profile}: one of the card's listed profiles.
  Future<Map<String, dynamic>> profile(Map<String, dynamic> params) async {
    _need();
    final card = params['card'], profile = params['profile'];
    final cards = ((await get())['cards'] as List).cast<Map>();
    final c = cards.where((c) => c['name'] == card).firstOrNull;
    if (c == null) throw RouteError('bad_params', 'card');
    if (profile is! String || !(c['profiles'] as List).any((p) => (p as Map)['name'] == profile)) throw RouteError('bad_params', 'profile');
    await _pactl(['set-card-profile', card as String, profile]);
    return {'card': card, 'profile': profile};
  }
}
