import 'translations.dart';

import 'context.dart';

/// The Time & Language page on Hyprland (COSMIC Settings' Date & time and Region & language):
/// automatic time, the time zone (`timedatectl`), the system language and formats
/// (`localectl`). Changing them needs the administrator: polkit's agent asks for the password,
/// so the calls wait up to two minutes.
final class TimeLangService {
  TimeLangService(this.ctx);
  final Ctx ctx;

  static const _polkit = Duration(minutes: 2);

  /// The format variables "Formats" sets together.
  static const formatVars = ['LC_TIME', 'LC_NUMERIC', 'LC_MONETARY', 'LC_MEASUREMENT', 'LC_PAPER'];

  List<String>? _zones, _locales;

  Future<String> _run(List<String> argv, {Duration timeout = const Duration(seconds: 10)}) async {
    final r = await ctx.runner.run(argv, timeout: timeout);
    if (!r.ok) {
      final why = r.stderr.trim().split('\n').where((l) => l.trim().isNotEmpty).lastOrNull ?? '';
      throw RouteError(r.code == 124 ? 'timeout' : 'failed', why.isEmpty ? trf('exit {0}', [r.code]) : why);
    }
    return r.stdout;
  }

  void _need(String tool) {
    if (ctx.runner.which(tool) == null) throw RouteError('unavailable', trf('{0} is missing', [tool]));
  }

  /// `time.get`.
  Future<Map<String, dynamic>> time() async {
    _need('timedatectl');
    final show = await _run(['timedatectl', 'show', '-p', 'NTP', '-p', 'Timezone', '-p', 'CanNTP']);
    final v = {
      for (final l in show.split('\n'))
        if (l.contains('=')) l.substring(0, l.indexOf('=')): l.substring(l.indexOf('=') + 1).trim(),
    };
    _zones ??= [for (final z in (await _run(['timedatectl', 'list-timezones'])).split('\n')) if (z.trim().isNotEmpty) z.trim()];
    return {'ntp': v['NTP'] == 'yes', 'canNtp': v['CanNTP'] != 'no', 'timezone': v['Timezone'] ?? '', 'zones': _zones};
  }

  /// `time.set_ntp` {on}.
  Future<Map<String, dynamic>> setNtp(Map<String, dynamic> params) async {
    _need('timedatectl');
    final on = params['on'];
    if (on is! bool) throw RouteError('bad_params', 'on');
    await _run(['timedatectl', 'set-ntp', on ? 'true' : 'false'], timeout: _polkit);
    return {'ntp': on};
  }

  /// `time.set_timezone` {zone}: one of timedatectl's list.
  Future<Map<String, dynamic>> setTimezone(Map<String, dynamic> params) async {
    _need('timedatectl');
    final zone = params['zone'];
    final zones = (await time())['zones'] as List;
    if (zone is! String || !zones.contains(zone)) throw RouteError('bad_params', 'zone');
    await _run(['timedatectl', 'set-timezone', zone], timeout: _polkit);
    return {'timezone': zone};
  }

  /// localectl status's "System Locale" variables.
  static Map<String, String> systemLocale(String status) {
    final out = <String, String>{};
    var inLocale = false;
    for (final l in status.split('\n')) {
      final m = RegExp(r'^\s*System Locale:\s*(.*)$').firstMatch(l);
      String? kv;
      if (m != null) {
        inLocale = true;
        kv = m[1];
      } else if (inLocale && RegExp(r'^\s+[A-Z_]+=').hasMatch(l) && !l.contains(':')) {
        kv = l.trim();
      } else {
        inLocale = false;
      }
      if (kv != null && kv.contains('=')) out[kv.substring(0, kv.indexOf('='))] = kv.substring(kv.indexOf('=') + 1).trim();
    }
    return out;
  }

  /// `locale.get`.
  Future<Map<String, dynamic>> locale() async {
    _need('localectl');
    final vars = systemLocale(await _run(['localectl', 'status']));
    _locales ??= [for (final l in (await _run(['localectl', 'list-locales'])).split('\n')) if (l.trim().isNotEmpty) l.trim()];
    final lang = vars['LANG'] ?? '';
    return {'lang': lang, 'formats': vars['LC_TIME'] ?? lang, 'vars': vars, 'locales': _locales};
  }

  /// `locale.set` {lang?, formats?}: LANG and the format variables; the other ones are kept.
  Future<Map<String, dynamic>> setLocale(Map<String, dynamic> params) async {
    _need('localectl');
    final now = await locale();
    final locales = now['locales'] as List;
    final lang = params['lang'], formats = params['formats'];
    if (lang == null && formats == null) throw RouteError('bad_params', 'lang or formats');
    if (lang != null && (lang is! String || !locales.contains(lang))) throw RouteError('bad_params', 'lang');
    if (formats != null && (formats is! String || !locales.contains(formats))) throw RouteError('bad_params', 'formats');
    final vars = Map<String, String>.from(now['vars'] as Map);
    if (lang != null) vars['LANG'] = lang as String;
    if (formats != null) {
      for (final v in formatVars) {
        vars[v] = formats as String;
      }
    }
    await _run(['localectl', 'set-locale', for (final e in vars.entries) '${e.key}=${e.value}'], timeout: _polkit);
    return {'vars': vars};
  }
}
