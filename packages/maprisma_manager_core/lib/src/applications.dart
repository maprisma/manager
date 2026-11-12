import 'translations.dart';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'bar_cosmic.dart' show atomicWrite;
import 'context.dart';

/// One installed application (a .desktop file).
typedef DesktopApp = ({String id, String name, String path, List<String> mime, bool shown});

/// The Applications page on Hyprland (COSMIC Settings' Default applications and Startup
/// applications): the default app per role through `xdg-mime`, and the user's autostart
/// entries (~/.config/autostart) switched with `Hidden=` as XDG says. Maprisma's own trays are
/// left to the Bar page, which starts and stops them with the bar.
final class ApplicationsService {
  ApplicationsService(this.ctx);
  final Ctx ctx;

  /// The roles in COSMIC's order and their MIME types (the first one is read, all are set).
  static const roles = <String, List<String>>{
    'browser': ['x-scheme-handler/http', 'x-scheme-handler/https', 'text/html'],
    'files': ['inode/directory'],
    'mail': ['x-scheme-handler/mailto'],
    'music': ['audio/mpeg', 'audio/flac', 'audio/ogg'],
    'video': ['video/mp4', 'video/x-matroska', 'video/webm'],
    'photos': ['image/png', 'image/jpeg'],
    'calendar': ['text/calendar'],
    'text': ['text/plain'],
  };

  /// The application folders: the user's first, then XDG_DATA_DIRS (as the system's root).
  List<String> get appDirs {
    final dataDirs = (ctx.environment['XDG_DATA_DIRS'] ?? '').split(':').where((d) => d.startsWith('/')).toList();
    final system = dataDirs.isEmpty ? ['/usr/local/share', '/usr/share'] : dataDirs;
    return [ctx.paths.apps, for (final d in system) ctx.paths.sys(p.join(d, 'applications'))];
  }

  /// The [Desktop Entry] group's keys of a .desktop text (no localized keys).
  static Map<String, String> entry(String text) {
    final out = <String, String>{};
    var inEntry = false;
    for (final raw in text.split('\n')) {
      final l = raw.trim();
      if (l.startsWith('[')) {
        inEntry = l == '[Desktop Entry]';
        continue;
      }
      if (!inEntry || l.startsWith('#')) continue;
      final i = l.indexOf('=');
      if (i <= 0) continue;
      final k = l.substring(0, i).trim();
      if (k.contains('[')) continue;
      out.putIfAbsent(k, () => l.substring(i + 1).trim());
    }
    return out;
  }

  /// The installed apps by id (the first folder that has an id wins, as XDG says).
  Map<String, DesktopApp> installedApps() {
    final out = <String, DesktopApp>{};
    for (final dir in appDirs) {
      final d = Directory(dir);
      if (!d.existsSync()) continue;
      for (final f in d.listSync(recursive: true, followLinks: true).whereType<File>()) {
        if (!f.path.endsWith('.desktop')) continue;
        final id = p.relative(f.path, from: dir).replaceAll('/', '-');
        if (out.containsKey(id)) continue;
        Map<String, String> e;
        try {
          e = entry(f.readAsStringSync());
        } on FileSystemException {
          continue;
        } on FormatException {
          continue;
        }
        if (e['Type'] != null && e['Type'] != 'Application') continue;
        out[id] = (
          id: id,
          name: e['Name'] ?? id,
          path: f.path,
          mime: [for (final m in (e['MimeType'] ?? '').split(';')) if (m.isNotEmpty) m],
          shown: e['NoDisplay'] != 'true' && e['Hidden'] != 'true',
        );
      }
    }
    return out;
  }

  void _needXdgMime() {
    if (ctx.runner.which('xdg-mime') == null) throw RouteError('unavailable', tr('xdg-mime is missing (xdg-utils)'));
  }

  /// `apps_default.get`: per role the current default and the apps that can take it.
  Future<Map<String, dynamic>> defaults() async {
    _needXdgMime();
    final apps = installedApps();
    final out = <Map<String, dynamic>>[];
    for (final MapEntry(key: role, value: mimes) in roles.entries) {
      final r = await ctx.runner.run(['xdg-mime', 'query', 'default', mimes.first], timeout: const Duration(seconds: 10));
      final current = r.ok ? r.stdout.trim() : '';
      final able = [
        for (final a in apps.values)
          if (a.shown && a.mime.any(mimes.contains)) {'id': a.id, 'name': a.name},
      ]..sort((a, b) => '${a['name']}'.toLowerCase().compareTo('${b['name']}'.toLowerCase()));
      out.add({'role': role, 'current': current, 'currentName': apps[current]?.name, 'apps': able});
    }
    return {'roles': out};
  }

  /// `apps_default.set` {role, app}: [app] becomes the default for all the role's MIME types.
  Future<Map<String, dynamic>> setDefault(Map<String, dynamic> params) async {
    _needXdgMime();
    final role = params['role'], app = params['app'];
    final mimes = roles[role];
    if (mimes == null) throw RouteError('bad_params', 'role');
    final a = installedApps()[app];
    if (app is! String || a == null || !a.shown || !a.mime.any(mimes.contains)) throw RouteError('bad_params', 'app');
    final r = await ctx.runner.run(['xdg-mime', 'default', app, ...mimes], timeout: const Duration(seconds: 15));
    if (!r.ok) throw RouteError('failed', r.stderr.trim().isEmpty ? trf('exit {0}', [r.code]) : r.stderr.trim().split('\n').first);
    return {'role': role, 'app': app};
  }

  /// Maprisma's trays and services: the Bar page starts and stops them.
  static bool maprismas(String id) => id.startsWith('com.maprisma.') || id.startsWith('io.github.ubruckhaus.');

  /// `autostart.list`: the user's autostart entries and the apps that can be added.
  Map<String, dynamic> autostart() {
    final dir = Directory(ctx.paths.autostart);
    final entries = <Map<String, dynamic>>[];
    var bar = 0;
    if (dir.existsSync()) {
      for (final f in dir.listSync().whereType<File>()) {
        final id = p.basename(f.path);
        if (!id.endsWith('.desktop')) continue;
        if (maprismas(id)) {
          bar++;
          continue;
        }
        Map<String, String> e;
        try {
          e = entry(f.readAsStringSync());
        } on FileSystemException {
          continue;
        } on FormatException {
          continue;
        }
        final only = e['OnlyShowIn'], not = e['NotShowIn'];
        final desktop = (ctx.environment['XDG_CURRENT_DESKTOP'] ?? '').split(':');
        final here = (only == null || only.split(';').any(desktop.contains)) && (not == null || !not.split(';').any(desktop.contains));
        entries.add({'file': id, 'name': e['Name'] ?? id, 'on': e['Hidden'] != 'true' && e['X-GNOME-Autostart-enabled'] != 'false', 'here': here});
      }
    }
    entries.sort((a, b) => '${a['name']}'.toLowerCase().compareTo('${b['name']}'.toLowerCase()));
    final present = {for (final e in entries) e['file']};
    final addable = [
      for (final a in installedApps().values)
        if (a.shown && !present.contains(a.id) && !maprismas(a.id)) {'id': a.id, 'name': a.name},
    ]..sort((a, b) => '${a['name']}'.toLowerCase().compareTo('${b['name']}'.toLowerCase()));
    return {'entries': entries, 'addable': addable, 'maprismaTrays': bar};
  }

  String _autostartFile(Object? file) {
    if (file is! String || file.contains('/') || !file.endsWith('.desktop') || file.startsWith('.') || maprismas(file)) throw RouteError('bad_params', 'file');
    final path = p.join(ctx.paths.autostart, file);
    if (!File(path).existsSync()) throw RouteError('not_found', tr('no such autostart entry'));
    return path;
  }

  /// `autostart.set` {file, on}: `Hidden=` in the entry's [Desktop Entry] group.
  Map<String, dynamic> setAutostart(Map<String, dynamic> params) {
    final path = _autostartFile(params['file']);
    final on = params['on'];
    if (on is! bool) throw RouteError('bad_params', 'on');
    final lines = File(path).readAsStringSync().split('\n');
    final out = <String>[];
    var inEntry = false, done = false;
    for (final l in lines) {
      final t = l.trim();
      if (t.startsWith('[')) {
        if (inEntry && !done) {
          out.add('Hidden=${!on}');
          done = true;
        }
        inEntry = t == '[Desktop Entry]';
      } else if (inEntry && (t.startsWith('Hidden=') || t.startsWith('X-GNOME-Autostart-enabled='))) {
        if (!done && t.startsWith('Hidden=')) {
          out.add('Hidden=${!on}');
          done = true;
        }
        continue;
      }
      out.add(l);
    }
    if (inEntry && !done) {
      while (out.isNotEmpty && out.last.trim().isEmpty) {
        out.removeLast();
      }
      out.add('Hidden=${!on}');
      out.add('');
    }
    atomicWrite(path, out.join('\n'));
    return {'file': params['file'], 'on': on};
  }

  /// `autostart.add` {app}: a copy of the app's entry in ~/.config/autostart.
  Map<String, dynamic> add(Map<String, dynamic> params) {
    final app = params['app'];
    final a = installedApps()[app];
    if (app is! String || a == null || !a.shown || maprismas(app)) throw RouteError('bad_params', 'app');
    final target = p.join(ctx.paths.autostart, app);
    if (File(target).existsSync()) throw RouteError('exists', tr('It starts already at login'));
    Directory(ctx.paths.autostart).createSync(recursive: true);
    atomicWrite(target, File(a.path).readAsStringSync());
    return {'file': app};
  }

  /// `autostart.remove` {file}: an entry the user added (the file goes).
  Map<String, dynamic> remove(Map<String, dynamic> params) {
    final path = _autostartFile(params['file']);
    File(path).deleteSync();
    return {'file': params['file'], 'removed': true};
  }
}
