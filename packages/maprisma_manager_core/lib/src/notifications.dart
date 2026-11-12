import 'translations.dart';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'bar_cosmic.dart' show atomicWrite;
import 'catalog.dart' show findApp;
import 'catalog_model.dart' show DesktopId;
import 'context.dart';
import 'native.dart';
import 'procs.dart' show runningFor;
import 'run.dart' show isExecutableFile;

/// The Notifications page (`notifications.*`): Maprisma Notifier's settings
/// (`$XDG_CONFIG_HOME/maprisma-notifier/settings.json`), the app names of its history
/// (`$XDG_STATE_HOME/maprisma-notifier/history.jsonl`), and on Hyprland Maprisma Shell's popups
/// (`~/.config/maprisma-shell/shell.json` "notifications"). The file contract is
/// maprisma-notifier's docs/plan.md. Every write changes only the keys it was given (read, modify,
/// re-check that the file is still as read, atomic tmp + rename) and keeps keys it doesn't know.
///
/// Do not disturb is applied per desktop as the recorder does it: settings.json `dnd`, and the
/// effective state (`dnd`, or the schedule's window now) on Hyprland in shell.json
/// notifications.dnd, on COSMIC in cosmic-config's `do_not_disturb`; on KDE the recorder holds
/// the Inhibit itself.
final class NotificationsService {
  NotificationsService(this.ctx, this.native);

  final Ctx ctx;
  final NativeSettings native;

  /// settings.json's keys the Manager reads and writes, with Maprisma Notifier's defaults.
  static const scheduleDefaults = {'on': false, 'from': '22:00', 'to': '07:00'};
  static const historyMaxRange = (min: 50, max: 5000, def: 500);
  static const historyDaysRange = (min: 1, max: 90, def: 7);

  /// Maprisma Shell's popups: shell.json "notifications".
  static const positions = ['top-right', 'top', 'top-left', 'bottom-right', 'bottom-left'];
  static const timeoutRange = (min: 1, max: 60, def: 5);
  static const maxRange = (min: 1, max: 10, def: 5);

  /// The history is read from its last 4 MB at most (the Notifier's own limit); at most this many
  /// app names, each this long, in a muted or hidden list.
  static const historyReadMax = 4 * 1024 * 1024;
  static const appsMax = 500, appNameMax = 200;

  String get settingsFile => p.join(ctx.paths.config, 'maprisma-notifier', 'settings.json');
  String get historyFile => p.join(ctx.paths.state, 'maprisma-notifier', 'history.jsonl');
  String get shellFile => p.join(ctx.paths.config, 'maprisma-shell', 'shell.json');
  String get cosmicDndFile => p.join(ctx.paths.config, 'cosmic', 'com.system76.CosmicNotifications', 'v1', 'do_not_disturb');

  // --- reading -------------------------------------------------------------------------------

  /// `notifications.get`.
  Future<Map<String, dynamic>> get() async {
    final app = findApp('notifier');
    final settings = _settingsView(_read(settingsFile, 'settings.json'));
    final hypr = ctx.desktop == DesktopId.hyprland;
    final shell = hypr ? _shellView(_read(shellFile, 'shell.json')) : null;
    final links = native.links('notifications');
    return {
      'desktop': ctx.desktop.name,
      'installed': isExecutableFile(ctx.paths.expand('{bin}/maprisma-notifier')),
      'running': app != null && runningFor(app, ctx.paths, ctx.processes()).isNotEmpty,
      'settings': settings,
      'history': _history(),
      'shell': shell,
      'desktop_dnd': switch (ctx.desktop) {
        DesktopId.hyprland => {'where': 'shell', 'on': shell?['dnd'] == true},
        DesktopId.cosmic => {'where': 'cosmic', 'on': _cosmicDnd()},
        DesktopId.kde => {'where': 'recorder'},
        _ => null,
      },
      'native': links.isEmpty ? null : {'name': native.appName, 'available': ctx.runner.which(links.first.argv.first) != null},
    };
  }

  /// A JSON object file: its object (null when unreadable), why not, and its text as read
  /// (null: no file).
  _Json _read(String path, String name) {
    final f = File(path);
    String? text;
    try {
      if (!f.existsSync()) return (<String, dynamic>{}, null, null);
      if (f.lengthSync() > 256 * 1024) return (null, trf('{0} is too big', [name]), null);
      text = f.readAsStringSync();
      final v = jsonDecode(text);
      if (v is! Map<String, dynamic>) return (null, trf('{0} is not readable: {1}', [name, 'not an object']), text);
      return (v, null, text);
    } on FormatException catch (e) {
      return (null, trf('{0} is not readable: {1}', [name, e.message]), text);
    } on FileSystemException catch (e) {
      return (null, trf('{0} is not readable: {1}', [name, e.message]), text);
    }
  }

  static int? _int(Object? v, ({int min, int max, int def}) range) {
    if (v is! num || !v.isFinite || v != v.roundToDouble()) return null;
    return v.round().clamp(range.min, range.max);
  }

  /// Maprisma Shell's rule for its numbers: any number counts, rounded and clamped; else null.
  static int? _rounded(Object? v, ({int min, int max, int def}) range) =>
      v is num && v.isFinite ? v.round().clamp(range.min, range.max) : null;

  static final _clock = RegExp(r'^([01][0-9]|2[0-3]):[0-5][0-9]$');

  static List<String> _apps(Object? v) => [
    if (v is List)
      for (final a in v)
        if (a is String && a.trim().isNotEmpty) a,
  ];

  /// settings.json as Maprisma Notifier reads it: missing or invalid → the default; a whole
  /// number out of range counts as the nearest end.
  Map<String, dynamic> _settingsView(_Json json) {
    final (raw, error, text) = json;
    final r = raw ?? const <String, dynamic>{};
    final s = r['dnd_schedule'] is Map ? r['dnd_schedule'] as Map : const {};
    final schedule = {
      'on': s['on'] is bool ? s['on'] as bool : scheduleDefaults['on'],
      'from': s['from'] is String && _clock.hasMatch(s['from'] as String) ? s['from'] : scheduleDefaults['from'],
      'to': s['to'] is String && _clock.hasMatch(s['to'] as String) ? s['to'] : scheduleDefaults['to'],
    };
    final dnd = r['dnd'] == true;
    return {
      'file': settingsFile,
      'exists': text != null,
      'error': ?error,
      'dnd': dnd,
      'dnd_schedule': schedule,
      // what applies now: the switch, or the schedule's window (one crossing midnight works)
      'dnd_now': dnd || scheduleActive(schedule, ctx.clock()),
      'history_max': _int(r['history_max'], historyMaxRange) ?? historyMaxRange.def,
      'history_days': _int(r['history_days'], historyDaysRange) ?? historyDaysRange.def,
      'show_count': r['show_count'] is bool ? r['show_count'] : true,
      'muted_apps': _apps(r['muted_apps']),
      'hidden_apps': _apps(r['hidden_apps']),
    };
  }

  /// Whether [now] (local time) is inside the schedule's from–to window; from == to is no window.
  static bool scheduleActive(Map schedule, DateTime now) {
    if (schedule['on'] != true) return false;
    int? minutes(Object? v) {
      if (v is! String || !_clock.hasMatch(v)) return null;
      return int.parse(v.substring(0, 2)) * 60 + int.parse(v.substring(3));
    }

    final from = minutes(schedule['from']), to = minutes(schedule['to']);
    if (from == null || to == null || from == to) return false;
    final m = now.hour * 60 + now.minute;
    return from < to ? m >= from && m < to : m >= from || m < to;
  }

  /// shell.json "notifications" as Maprisma Shell reads it.
  Map<String, dynamic> _shellView(_Json json) {
    final (raw, error, text) = json;
    final n = raw?['notifications'] is Map ? raw!['notifications'] as Map : const {};
    return {
      'file': shellFile,
      'exists': text != null,
      'error': ?error,
      'dnd': n['dnd'] == true,
      'position': positions.contains(n['position']) ? n['position'] : positions.first,
      'timeout': _rounded(n['timeout'], timeoutRange) ?? timeoutRange.def,
      'max': _rounded(n['max'], maxRange) ?? maxRange.def,
    };
  }

  /// COSMIC's do_not_disturb (null: not set, the default off).
  bool? _cosmicDnd() {
    try {
      final f = File(cosmicDndFile);
      if (!f.existsSync() || f.lengthSync() > 64) return null;
      return switch (f.readAsStringSync().trim()) {
        'true' => true,
        'false' => false,
        _ => null,
      };
    } on FileSystemException {
      return null;
    }
  }

  /// The history's app names (sorted, distinct), from its last [historyReadMax] bytes.
  Map<String, dynamic> _history() {
    final path = historyFile;
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return {'file': path, 'exists': false, 'count': 0, 'apps': const <String>[]};
    if (type != FileSystemEntityType.file) return {'file': path, 'exists': true, 'count': 0, 'apps': const <String>[], 'error': tr('history.jsonl is not a regular file')};
    try {
      final raf = File(path).openSync();
      List<int> bytes;
      var partial = false;
      try {
        final length = raf.lengthSync();
        if (length > historyReadMax) {
          raf.setPositionSync(length - historyReadMax);
          partial = true;
        }
        bytes = raf.readSync(historyReadMax);
      } finally {
        raf.closeSync();
      }
      var lines = const LineSplitter().convert(utf8.decode(bytes, allowMalformed: true));
      // the first line of a tail may be cut
      if (partial && lines.isNotEmpty) lines = lines.sublist(1);
      final apps = <String>{};
      var count = 0;
      for (final line in lines) {
        if (line.trim().isEmpty) continue;
        Object? v;
        try {
          v = jsonDecode(line);
        } on FormatException {
          continue;
        }
        if (v is! Map) continue;
        count++;
        final app = v['app'];
        if (app is String && app.trim().isNotEmpty && app.length <= appNameMax && apps.length < appsMax) apps.add(app);
      }
      final sorted = apps.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      return {'file': path, 'exists': true, 'count': count, 'apps': sorted, if (partial) 'partial': true};
    } on FileSystemException catch (e) {
      return {'file': path, 'exists': true, 'count': 0, 'apps': const <String>[], 'error': trf('{0} is not readable: {1}', ['history.jsonl', e.message])};
    }
  }

  // --- writing -------------------------------------------------------------------------------

  /// Read, change, write [path] (a JSON object) only when it is still as read (Maprisma
  /// Notifier, Shell and Theme write these files too; else read it again, 3 tries), atomically.
  /// No write when nothing changes. True when it was written.
  bool _update(String path, String name, Map<String, dynamic> Function(Map<String, dynamic> raw) change) {
    for (var attempt = 0; attempt < 3; attempt++) {
      final (raw, error, text) = _read(path, name);
      if (raw == null) throw RouteError('unreadable', error);
      final next = change(Map<String, dynamic>.from(raw));
      if (text != null && jsonEncode(next) == jsonEncode(raw)) return false;
      final out = '${const JsonEncoder.withIndent('  ').convert(next)}\n';
      if (_textNow(path) != text) continue; // changed meanwhile: read it again
      Directory(p.dirname(path)).createSync(recursive: true);
      atomicWrite(path, out);
      return true;
    }
    throw RouteError('changed', trf('{0} keeps changing; try again', [name]));
  }

  static String? _textNow(String path) {
    try {
      final f = File(path);
      return f.existsSync() ? f.readAsStringSync() : null;
    } on FileSystemException {
      return '';
    }
  }

  static int _clamped(Map<String, dynamic> params, String key, ({int min, int max, int def}) range) {
    final v = params[key];
    if (v is! int) throw RouteError('bad_params', '$key (${range.min}–${range.max})');
    return v.clamp(range.min, range.max);
  }

  static List<String> _appList(Object? v, String key) {
    if (v is! List) throw RouteError('bad_params', '$key (a list of app names)');
    final out = <String>[];
    for (final a in v) {
      if (a is! String || a.length > appNameMax) throw RouteError('bad_params', '$key (app names up to $appNameMax characters)');
      final name = a.trim();
      if (name.isNotEmpty && !out.contains(name)) out.add(name);
    }
    if (out.length > appsMax) throw RouteError('bad_params', '$key (at most $appsMax apps)');
    return out;
  }

  static const _settingKeys = {'dnd', 'dnd_schedule', 'history_max', 'history_days', 'show_count', 'muted_apps', 'hidden_apps'};

  /// `notifications.set`: any of dnd, dnd_schedule {on?, from?, to?}, history_max, history_days,
  /// show_count, muted_apps, hidden_apps. Only these keys change (in dnd_schedule only the given
  /// ones). With dnd or dnd_schedule the effective do-not-disturb goes to the desktop too.
  Future<Map<String, dynamic>> set(Map<String, dynamic> params) async {
    final unknown = params.keys.where((k) => !_settingKeys.contains(k)).toList();
    if (unknown.isNotEmpty || params.isEmpty) throw RouteError('bad_params', _settingKeys.join(', '));
    final change = <String, Object>{};
    Map<String, Object>? schedule;
    for (final key in ['dnd', 'show_count']) {
      if (!params.containsKey(key)) continue;
      final v = params[key];
      if (v is! bool) throw RouteError('bad_params', key);
      change[key] = v;
    }
    if (params.containsKey('history_max')) change['history_max'] = _clamped(params, 'history_max', historyMaxRange);
    if (params.containsKey('history_days')) change['history_days'] = _clamped(params, 'history_days', historyDaysRange);
    for (final key in ['muted_apps', 'hidden_apps']) {
      if (params.containsKey(key)) change[key] = _appList(params[key], key);
    }
    if (params.containsKey('dnd_schedule')) {
      final s = params['dnd_schedule'];
      if (s is! Map || s.isEmpty || s.keys.any((k) => !scheduleDefaults.containsKey(k))) throw RouteError('bad_params', 'dnd_schedule {on, from, to}');
      schedule = {};
      if (s.containsKey('on')) {
        if (s['on'] is! bool) throw RouteError('bad_params', 'dnd_schedule.on');
        schedule['on'] = s['on'] as bool;
      }
      for (final k in ['from', 'to']) {
        if (!s.containsKey(k)) continue;
        if (s[k] is! String || !_clock.hasMatch(s[k] as String)) throw RouteError('bad_params', 'dnd_schedule.$k (HH:MM)');
        schedule[k] = s[k] as String;
      }
    }
    final written = _update(settingsFile, 'settings.json', (raw) {
      raw.addAll(change);
      if (schedule != null) {
        raw['dnd_schedule'] = {if (raw['dnd_schedule'] is Map) ...Map<String, dynamic>.from(raw['dnd_schedule'] as Map), ...schedule};
      }
      return raw;
    });
    final settings = _settingsView(_read(settingsFile, 'settings.json'));
    return {
      'settings': settings,
      'written': written,
      if (change.containsKey('dnd') || schedule != null) 'applied': _applyDnd(settings['dnd_now'] == true),
    };
  }

  /// The effective do-not-disturb to the desktop (changed only): where, and why not.
  Map<String, dynamic> _applyDnd(bool on) {
    try {
      switch (ctx.desktop) {
        case DesktopId.hyprland:
          _update(shellFile, 'shell.json', (raw) => {...raw, 'notifications': {..._notifications(raw), 'dnd': on}});
          return {'where': 'shell', 'on': on};
        case DesktopId.cosmic:
          if (_cosmicDnd() != on) atomicWrite(cosmicDndFile, on ? 'true' : 'false');
          return {'where': 'cosmic', 'on': on};
        case DesktopId.kde:
          // the recorder holds org.freedesktop.Notifications.Inhibit while it is on
          return {'where': 'recorder', 'on': on};
        default:
          return {'where': null, 'on': on};
      }
    } on RouteError catch (e) {
      return {'where': ctx.desktop == DesktopId.hyprland ? 'shell' : ctx.desktop.name, 'on': on, 'error': e.message ?? e.code};
    } on FileSystemException catch (e) {
      return {'where': ctx.desktop.name, 'on': on, 'error': e.message};
    }
  }

  static Map<String, dynamic> _notifications(Map<String, dynamic> raw) =>
      raw['notifications'] is Map ? Map<String, dynamic>.from(raw['notifications'] as Map) : <String, dynamic>{};

  /// `notifications.set_shell` (Hyprland): any of dnd, position, timeout (1–60 s), max (1–10) of
  /// shell.json "notifications"; only these keys change, every other key of the file stays.
  /// Maprisma Shell's reading: dnd a real bool (else false), position one of [positions] (else
  /// top-right), timeout/max any number rounded and clamped (a non-number: 5).
  Future<Map<String, dynamic>> setShell(Map<String, dynamic> params) async {
    if (ctx.desktop != DesktopId.hyprland) {
      throw RouteError('unavailable', tr('The popups are Maprisma Shell\'s (Hyprland); this desktop shows its own'));
    }
    const keys = {'dnd', 'position', 'timeout', 'max'};
    if (params.isEmpty || params.keys.any((k) => !keys.contains(k))) throw RouteError('bad_params', keys.join(', '));
    final change = <String, Object>{};
    if (params.containsKey('dnd')) {
      if (params['dnd'] is! bool) throw RouteError('bad_params', 'dnd');
      change['dnd'] = params['dnd'] as bool;
    }
    if (params.containsKey('position')) {
      if (!positions.contains(params['position'])) throw RouteError('bad_params', 'position (${positions.join(', ')})');
      change['position'] = params['position'] as String;
    }
    for (final (key, range) in [('timeout', timeoutRange), ('max', maxRange)]) {
      if (!params.containsKey(key)) continue;
      // as the shell reads it: a number, rounded and clamped
      final v = _rounded(params[key], range);
      if (v == null) throw RouteError('bad_params', '$key (${range.min}–${range.max})');
      change[key] = v;
    }
    final written = _update(shellFile, 'shell.json', (raw) => {...raw, 'notifications': {..._notifications(raw), ...change}});
    return {'shell': _shellView(_read(shellFile, 'shell.json')), 'written': written};
  }

  /// `notifications.clear_history`: the history emptied in one step (truncated in place, so the
  /// file keeps its mode and a recorder's open handle).
  Future<Map<String, dynamic>> clearHistory() async {
    final path = historyFile;
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return {'cleared': false, 'history': _history()};
    if (type != FileSystemEntityType.file) throw RouteError('unavailable', tr('history.jsonl is not a regular file'));
    try {
      File(path).openSync(mode: FileMode.write).closeSync();
    } on FileSystemException catch (e) {
      throw RouteError('failed', e.message);
    }
    return {'cleared': true, 'history': _history()};
  }
}

typedef _Json = (Map<String, dynamic>? raw, String? error, String? text);
