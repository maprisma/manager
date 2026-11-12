import 'translations.dart';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'bar_cosmic.dart' show atomicWrite;
import 'catalog_model.dart' show DesktopId;
import 'context.dart';

/// The Power page (`power.*`). Where the desktop has a settings app of its own (COSMIC Settings,
/// KDE System Settings) the Manager only opens its power page; on Hyprland it edits Maprisma
/// Shell's idle times (`~/.config/maprisma-shell/shell.json` "idle", seconds, 0 = never; the
/// shell watches the file) and the power profile (powerprofilesctl), as COSMIC Settings' Power
/// & Battery page offers them.
final class PowerService {
  PowerService(this.ctx, this.startDetached);

  final Ctx ctx;
  final Future<bool> Function(String exe, [List<String> args]) startDetached;

  /// Maprisma Shell's defaults (its services/Settings.qml).
  static const idleDefaults = {'lock': 180, 'screenOff': 300, 'suspend': 600, 'whilePlaying': false};

  /// The longest idle time accepted (a day).
  static const idleMax = 86400;

  String get shellFile => p.join(ctx.paths.config, 'maprisma-shell', 'shell.json');

  /// The desktop's own power settings: [name, command...].
  List<String>? get _native => switch (ctx.desktop) {
    DesktopId.cosmic => ['COSMIC Settings', 'cosmic-settings', 'power'],
    DesktopId.kde => ['System Settings', 'systemsettings', 'kcm_powerdevilprofilesconfig'],
    _ => null,
  };

  Future<Map<String, dynamic>> get() async {
    final native = _native;
    final ownSettings = native != null;
    return {
      'desktop': ctx.desktop.name,
      'native': native == null ? null : {'name': native[0], 'available': ctx.runner.which(native[1]) != null},
      'idle': ctx.desktop == DesktopId.hyprland ? _readIdle() : null,
      'profiles': ownSettings ? null : await _profiles(),
    };
  }

  /// The idle part of shell.json as Maprisma Shell reads it (a bad value counts as its default).
  Map<String, dynamic> _readIdle() {
    final (raw, error) = _readShell();
    final idle = raw?['idle'] is Map ? raw!['idle'] as Map : const {};
    int num(String key) {
      final v = idle[key];
      return v is int && v >= 0 ? v : idleDefaults[key] as int;
    }

    return {
      'file': shellFile,
      'exists': File(shellFile).existsSync(),
      'error': ?error,
      'lock': num('lock'),
      'screenOff': num('screenOff'),
      'suspend': num('suspend'),
      'whilePlaying': idle['whilePlaying'] == true,
    };
  }

  (Map<String, dynamic>?, String?) _readShell() {
    final f = File(shellFile);
    if (!f.existsSync()) return (<String, dynamic>{}, null);
    try {
      if (f.lengthSync() > 256 * 1024) return (null, tr('shell.json is too big'));
      final v = jsonDecode(f.readAsStringSync());
      if (v is! Map<String, dynamic>) return (null, trf('shell.json is not readable: {0}', ['not an object']));
      return (v, null);
    } on FormatException catch (e) {
      return (null, trf('shell.json is not readable: {0}', [e.message]));
    } on FileSystemException catch (e) {
      return (null, trf('shell.json is not readable: {0}', [e.message]));
    }
  }

  /// `power.set_idle`: any of lock, screenOff, suspend (seconds, 0 = never) and whilePlaying;
  /// every other key of shell.json (the wallpaper Maprisma Theme writes, …) is kept.
  Future<Map<String, dynamic>> setIdle(Map<String, dynamic> params) async {
    if (ctx.desktop != DesktopId.hyprland) {
      throw RouteError('unavailable', tr('The idle times are Maprisma Shell\'s (Hyprland); this desktop has its own settings'));
    }
    final change = <String, Object>{};
    for (final key in ['lock', 'screenOff', 'suspend']) {
      if (!params.containsKey(key)) continue;
      final v = params[key];
      if (v is! int || v < 0 || v > idleMax) throw RouteError('bad_params', '$key (0–$idleMax seconds)');
      change[key] = v;
    }
    if (params.containsKey('whilePlaying')) {
      final v = params['whilePlaying'];
      if (v is! bool) throw RouteError('bad_params', 'whilePlaying');
      change['whilePlaying'] = v;
    }
    if (change.isEmpty) throw RouteError('bad_params', 'lock, screenOff, suspend or whilePlaying');
    final (raw, error) = _readShell();
    if (raw == null) throw RouteError('unreadable', error);
    final idle = raw['idle'] is Map ? Map<String, dynamic>.from(raw['idle'] as Map) : <String, dynamic>{};
    // Keys the shell doesn't know yet stay as they are; the known ones get their read value first,
    // so the file always holds all four.
    final now = _readIdle();
    for (final k in idleDefaults.keys) {
      idle[k] = now[k];
    }
    idle.addAll(change);
    final out = {...raw, 'idle': idle};
    Directory(p.dirname(shellFile)).createSync(recursive: true);
    atomicWrite(shellFile, '${const JsonEncoder.withIndent('  ').convert(out)}\n');
    return {'idle': _readIdle(), 'written': true};
  }

  /// powerprofilesctl's profiles (power-profiles-daemon); null when it is missing.
  Future<Map<String, dynamic>?> _profiles() async {
    if (ctx.runner.which('powerprofilesctl') == null) return null;
    final r = await ctx.runner.run(['powerprofilesctl', 'list'], timeout: const Duration(seconds: 10));
    if (!r.ok) return {'available': false, 'error': r.stderr.trim().split('\n').first};
    final list = <String>[];
    String? current;
    for (final line in const LineSplitter().convert(r.stdout)) {
      final m = RegExp(r'^(\*?)\s*([a-z][a-z-]*):\s*$').firstMatch(line);
      if (m == null) continue;
      list.add(m[2]!);
      if (m[1] == '*') current = m[2];
    }
    return {'available': list.isNotEmpty, 'list': list, 'current': current};
  }

  /// `power.set_profile`: one of powerprofilesctl's profiles.
  Future<Map<String, dynamic>> setProfile(Map<String, dynamic> params) async {
    if (_native != null) throw RouteError('unavailable', tr('This desktop sets the power profile in its own settings'));
    final profile = params['profile'];
    final now = await _profiles();
    if (now == null || now['available'] != true) throw RouteError('unavailable', tr('powerprofilesctl is missing'));
    if (profile is! String || !(now['list'] as List).contains(profile)) throw RouteError('bad_params', 'profile');
    final r = await ctx.runner.run(['powerprofilesctl', 'set', profile], timeout: const Duration(seconds: 10));
    if (!r.ok) throw RouteError('failed', r.stderr.trim().isEmpty ? trf('exit {0}', [r.code]) : r.stderr.trim().split('\n').first);
    return {'profiles': await _profiles()};
  }

  /// `power.open_native`: the desktop's own power settings.
  Future<Map<String, dynamic>> openNative() async {
    final native = _native;
    if (native == null) throw RouteError('unavailable', tr('This desktop has no power settings app of its own'));
    final exe = ctx.runner.which(native[1]);
    if (exe == null) throw RouteError('unavailable', trf('{0} is missing', [native[1]]));
    if (!await startDetached(exe, native.sublist(2))) throw RouteError('internal', trf('could not start {0}', [native[1]]));
    return {'opened': native[0]};
  }
}
