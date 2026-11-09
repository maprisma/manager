/// Changing an app's bar icon (plan: "Changing an icon"; docs/protocol.md "icons.*").
///
/// Applets and trays load their icon by name from the icon theme. An app whose bar icon has a
/// name of its own (`io.github.ubruckhaus.CosmicMaprisma*-symbolic`, a file its installer puts in
/// `~/.local/share/icons/hicolor/scalable/apps`) can get another one: the chosen SVG (a theme icon
/// by name, or a file) is checked (SVG only, at most [maxIconBytes], no scripts, event handlers or
/// references outside the file) and written over that file; the installer's original is kept in
/// `~/.local/state/maprisma-manager/icons/<app>/` for "reset"; the choice is applied again after
/// every install or update of the app; then the icon cache and the bar icon are refreshed.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import 'bar_cosmic.dart';
import 'bar_kde.dart';
import 'catalog.dart';
import 'context.dart';
import 'jobs.dart';
import 'ownership.dart';
import 'paths.dart';
import 'receipts.dart';
import 'sysproc.dart';

/// An icon file larger than this is refused.
const maxIconBytes = 256 * 1024;

/// How many choices `icons.get` lists at most (`limit` up to [maxChoices]).
const defaultChoices = 100;
const maxChoices = 500;

/// Entries looked at per theme folder (Breeze has ~10 000): the walk stops there.
const _maxWalk = 60000;

const _svgNs = 'http://www.w3.org/2000/svg';

/// Why [bytes] is not an icon the Manager writes, or null when it is one: UTF-8 XML whose root
/// is `<svg>` in the SVG namespace, no DOCTYPE/entities, no scripts, foreign objects, embedded
/// or linked images, animations, event handlers, and every reference (`href`, `url(…)`) inside the
/// file (`#id`); no `@import` in styles.
String? svgProblem(List<int> bytes) {
  if (bytes.length > maxIconBytes) return 'larger than ${maxIconBytes ~/ 1024} KiB';
  if (bytes.isEmpty) return 'empty';
  final String text;
  try {
    text = utf8.decode(bytes);
  } on FormatException {
    return 'not UTF-8 text';
  }
  final lower = text.toLowerCase();
  if (lower.contains('<!doctype') || lower.contains('<!entity')) return 'has a DOCTYPE or entities';
  final XmlDocument doc;
  try {
    doc = XmlDocument.parse(text);
  } on XmlException catch (e) {
    return 'not well-formed XML (${e.message})';
  }
  final root = doc.rootElement;
  if (root.name.local != 'svg' || (root.namespaceUri ?? root.getAttribute('xmlns')) != _svgNs) return 'not an SVG (the root is <${root.name.qualified}>)';
  for (final node in doc.descendants) {
    if (node is XmlProcessing) return 'has a processing instruction (<?${node.target}?>)';
  }
  const forbidden = {
    'script', 'foreignobject', 'iframe', 'embed', 'object', 'audio', 'video', 'image', 'feimage',
    'animate', 'set', 'animatemotion', 'animatetransform', 'animatecolor', 'discard', 'handler', 'listener', 'a',
  };
  String? cssProblem(String css) {
    // CSS escapes (`u\72l(`, `@\69mport`) could hide a reference: refused, icons don't need them
    if (css.contains('\\')) return 'a CSS escape (backslash)';
    final c = css.toLowerCase();
    if (c.contains('@import')) return '@import';
    if (c.contains('javascript:') || c.contains('expression(')) return 'script in a style';
    for (final m in RegExp(r'url\(\s*([^)]*)\)').allMatches(c)) {
      final target = m.group(1)!.trim().replaceAll(RegExp(r'''^['"]|['"]$'''), '').trim();
      if (!target.startsWith('#')) return 'a reference outside the file (url($target))';
    }
    return null;
  }

  for (final e in [root, ...root.descendantElements]) {
    final name = e.name.local.toLowerCase();
    if (forbidden.contains(name)) return 'has a <${e.name.local}> element';
    if (name == 'style') {
      final why = cssProblem(e.innerText);
      if (why != null) return 'its style has $why';
    }
    for (final a in e.attributes) {
      final an = a.name.local.toLowerCase();
      final v = a.value.trim();
      if (an.startsWith('on')) return 'has an event handler (${a.name.qualified})';
      if (an == 'href' && !v.startsWith('#')) return 'links outside the file (${a.name.qualified}="$v")';
      final why = cssProblem(v);
      if (why != null) return 'has $why in ${a.name.qualified}';
      if (v.toLowerCase().contains('javascript:')) return 'has a script URL in ${a.name.qualified}';
    }
  }
  return null;
}

/// The icon theme the desktop uses now and where its name came from.
({String name, String source}) currentIconTheme(Ctx ctx) {
  final paths = ctx.paths;
  switch (ctx.desktop) {
    case DesktopId.cosmic:
      for (final f in [
        p.join(paths.config, 'cosmic/com.system76.CosmicTk/v1/icon_theme'),
        paths.sys('/usr/share/cosmic/com.system76.CosmicTk/v1/icon_theme'),
      ]) {
        try {
          final v = File(f).readAsStringSync().trim().replaceAll('"', '');
          if (v.isNotEmpty) return (name: v, source: f);
        } on FileSystemException {
          continue;
        }
      }
      return (name: 'Cosmic', source: 'COSMIC\'s default');
    case DesktopId.kde:
      final f = p.join(paths.config, 'kdeglobals');
      try {
        var inIcons = false;
        for (final line in File(f).readAsLinesSync()) {
          final l = line.trim();
          if (l.startsWith('[')) inIcons = l == '[Icons]';
          if (inIcons && l.startsWith('Theme=')) return (name: l.substring(6).trim(), source: f);
        }
      } on FileSystemException {
        // Plasma's default
      }
      return (name: 'breeze', source: 'Plasma\'s default');
    case DesktopId.other:
      final f = p.join(paths.config, 'gtk-3.0/settings.ini');
      try {
        for (final line in File(f).readAsLinesSync()) {
          final m = RegExp(r'^\s*gtk-icon-theme-name\s*=\s*(.+?)\s*$').firstMatch(line);
          if (m != null) return (name: m.group(1)!, source: f);
        }
      } on FileSystemException {
        // GTK's default
      }
      return (name: 'Adwaita', source: 'GTK\'s default');
  }
}

/// The folders icon themes are looked up in (the XDG icon theme spec), user ones first.
List<String> iconBaseDirs(Ctx ctx) {
  final dirs = (ctx.environment['XDG_DATA_DIRS'] ?? '').split(':').where((d) => d.isNotEmpty && p.isAbsolute(d)).toList();
  return [
    p.join(ctx.paths.data, 'icons'),
    p.join(ctx.paths.home, '.icons'),
    for (final d in dirs.isEmpty ? ['/usr/local/share', '/usr/share'] : dirs) ctx.paths.sys(p.join(d, 'icons')),
    ctx.paths.sys('/usr/share/pixmaps'),
  ].fold<List<String>>([], (l, d) => l.contains(d) ? l : (l..add(d)));
}

/// [theme] and what it inherits (breadth first, at most 12), then hicolor.
List<String> themeChain(Ctx ctx, String theme) {
  final bases = iconBaseDirs(ctx);
  final out = <String>[];
  final queue = [theme];
  while (queue.isNotEmpty && out.length < 12) {
    final t = queue.removeAt(0);
    if (out.contains(t) || t == 'hicolor' || t.contains('/') || t.isEmpty) continue;
    out.add(t);
    for (final b in bases) {
      final index = File(p.join(b, t, 'index.theme'));
      if (!index.existsSync()) continue;
      try {
        for (final line in index.readAsLinesSync()) {
          if (line.startsWith('Inherits=')) queue.addAll(line.substring(9).split(',').map((s) => s.trim()));
        }
      } on FileSystemException {
        // unreadable: nothing inherited
      }
      break;
    }
  }
  return [...out, 'hicolor'];
}

/// Every `.svg` icon of the theme chain by name (the first theme that has a name wins; within a
/// theme a scalable one first), bounded per folder.
Map<String, ({String file, String theme})> themeSvgs(Ctx ctx, List<String> chain, {bool symbolicOnly = true}) {
  final out = <String, ({String file, String theme})>{};
  for (final t in chain) {
    final found = <String, String>{};
    for (final b in iconBaseDirs(ctx)) {
      final dir = Directory(p.join(b, t));
      if (!dir.existsSync()) continue;
      var n = 0;
      try {
        for (final e in dir.listSync(recursive: true, followLinks: true)) {
          if (++n > _maxWalk) break;
          final base = p.basename(e.path);
          if (!base.endsWith('.svg')) continue;
          final name = base.substring(0, base.length - 4);
          if (symbolicOnly && !name.endsWith('-symbolic')) continue;
          final prev = found[name];
          // scalable over fixed sizes
          if (prev == null || (!prev.contains('/scalable/') && e.path.contains('/scalable/'))) found[name] = e.path;
        }
      } on FileSystemException {
        continue;
      }
    }
    for (final f in found.entries) {
      out.putIfAbsent(f.key, () => (file: f.value, theme: t));
    }
  }
  return out;
}

/// The icon state of one app: `~/.local/state/maprisma-manager/icons/<app>/`.
final class _IconState {
  _IconState(this.dir, this.data);
  final String dir;
  final Map<String, dynamic> data;
  String get original => p.join(dir, 'original.svg');
  String get chosen => p.join(dir, 'chosen.svg');
  Map<String, dynamic>? get choice => data['choice'] as Map<String, dynamic>?;

  static _IconState load(Paths paths, String app) {
    final dir = p.join(paths.managerState, 'icons', app);
    try {
      final d = jsonDecode(File(p.join(dir, 'icon.json')).readAsStringSync());
      if (d is Map<String, dynamic>) return _IconState(dir, d);
    } on Object {
      // none (or broken: counts as none; the original file is still there)
    }
    return _IconState(dir, {'schema': 1, 'app': app});
  }

  void save() => atomicWrite(p.join(dir, 'icon.json'), const JsonEncoder.withIndent('  ').convert(data));
}

/// Writes [bytes] next to [path] and renames it over it (mode 644).
void atomicWriteBytes(String path, List<int> bytes) {
  Directory(p.dirname(path)).createSync(recursive: true);
  final tmp = File(p.join(p.dirname(path), '.${p.basename(path)}.maprisma-manager.$pid.tmp'));
  tmp.writeAsBytesSync(bytes, flush: true);
  try {
    Process.runSync('/usr/bin/chmod', ['644', tmp.path], includeParentEnvironment: false);
    tmp.renameSync(path);
  } on Object {
    if (tmp.existsSync()) tmp.deleteSync();
    rethrow;
  }
}

String _sha(List<int> bytes) => sha256Bytes(bytes);

/// `icons.get`, `icons.set`, `icons.reset`, and the choice applied again after installs.
final class IconService {
  IconService(this.ctx, this.jobs);
  final Ctx ctx;
  final JobEngine jobs;
  Paths get paths => ctx.paths;

  AppEntry _app(Map<String, dynamic> params) {
    final id = params['app'] ?? params['id'];
    if (id is! String || id.isEmpty) throw RouteError('bad_params', 'app');
    final app = findApp(id);
    if (app == null) throw RouteError('not_found', 'no app $id');
    return app;
  }

  /// Why the app's bar icon can't be changed, or null. Only an own name whose file the app's
  /// installer writes (shared and system names would change other apps' icons too).
  String? whyNot(AppEntry app) {
    final name = app.bar.iconName;
    if (app.bar.none || name == null) return '${app.name} has no bar icon';
    if (!name.startsWith('io.github.ubruckhaus.CosmicMaprisma') || !name.endsWith('-symbolic')) {
      return '${app.name}\'s bar icon $name is not a name of its own (changing it would change other icons too)';
    }
    final file = iconFile(app)!;
    final installed = app.components.any((c) => c.paths.any((ip) => paths.expand(ip.path) == file));
    if (!installed) return '${app.name}\'s installer doesn\'t install $file';
    return null;
  }

  String? iconFile(AppEntry app) => app.bar.iconName == null ? null : p.join(paths.icons, '${app.bar.iconName}.svg');

  Future<Map<String, dynamic>> get(Map<String, dynamic> params) async {
    final app = _app(params);
    final query = params['query'] ?? '';
    final limit = params['limit'] ?? defaultChoices;
    if (query is! String) throw RouteError('bad_params', 'query');
    if (limit is! int || limit < 0 || limit > maxChoices) throw RouteError('bad_params', 'limit (0…$maxChoices)');
    final why = whyNot(app);
    final file = iconFile(app);
    final st = _IconState.load(paths, app.id);
    final exists = file != null && FileSystemEntity.typeSync(file, followLinks: false) == FileSystemEntityType.file;
    final now = exists ? sha256File(file) : null;
    final originalKept = File(st.original).existsSync();
    final origSha = originalKept ? sha256File(st.original) : null;
    final choice = st.choice;
    final theme = currentIconTheme(ctx);
    final chain = themeChain(ctx, theme.name);
    final q = query.toLowerCase().trim();
    final all = why != null ? const <String, ({String file, String theme})>{} : themeSvgs(ctx, chain);
    final names = [for (final n in all.keys) if (q.isEmpty || n.toLowerCase().contains(q)) n]..sort();
    return {
      'app': app.id,
      'name': app.name,
      'iconName': app.bar.iconName,
      'kdeIconName': ?app.bar.kdeIconName,
      'file': file,
      'exists': exists,
      'sha256': now,
      'changeable': why == null,
      'why': ?why,
      'note': ?app.bar.iconNote,
      'shows': {
        'cosmic': !app.bar.cosmicIconBuiltIn && app.bar.cosmicApplet != null,
        'kde': app.bar.kdeTrayExe != null && app.bar.kdeIconName == null,
      },
      'current': choice == null
          ? 'original'
          : (now == choice['sha256'] ? 'changed' : 'changed, not applied (the file is not the choice)'),
      'choice': choice,
      'original': {'kept': originalKept, if (originalKept) 'file': st.original, 'sha256': ?origSha},
      'theme': {'name': theme.name, 'source': theme.source, 'chain': chain},
      'query': query,
      'total': names.length,
      'truncated': names.length > limit,
      'choices': [for (final n in names.take(limit)) {'name': n, 'file': all[n]!.file, 'theme': all[n]!.theme}],
    };
  }

  /// The SVG for `icon` (a theme name, or a file path): checked, at most [maxIconBytes].
  ({List<int> bytes, Map<String, dynamic> choice}) _resolve(Object? icon) {
    if (icon is! String || icon.trim().isEmpty) throw RouteError('bad_params', 'icon (a theme icon name or an SVG file)');
    String file;
    Map<String, dynamic> choice;
    if (icon.contains('/')) {
      final f = icon.startsWith('~/') ? p.join(paths.home, icon.substring(2)) : icon;
      if (!p.isAbsolute(f)) throw RouteError('bad_params', 'icon: a file must be an absolute path');
      if (FileSystemEntity.typeSync(f) != FileSystemEntityType.file) throw RouteError('not_found', 'no file $f');
      file = f;
      choice = {'kind': 'file', 'from': p.normalize(f)};
    } else {
      if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._+-]{0,200}$').hasMatch(icon)) throw RouteError('bad_params', 'icon: not an icon name');
      final theme = currentIconTheme(ctx);
      final all = themeSvgs(ctx, themeChain(ctx, theme.name), symbolicOnly: false);
      final hit = all[icon];
      if (hit == null) throw RouteError('not_found', 'no SVG icon $icon in ${theme.name} or what it inherits');
      file = hit.file;
      choice = {'kind': 'name', 'name': icon, 'theme': hit.theme, 'from': hit.file};
    }
    final len = File(file).lengthSync();
    if (len > maxIconBytes) throw RouteError('bad_icon', '$file is larger than ${maxIconBytes ~/ 1024} KiB');
    final bytes = File(file).readAsBytesSync();
    final why = svgProblem(bytes);
    if (why != null) throw RouteError('bad_icon', '$file: $why');
    return (bytes: bytes, choice: choice);
  }

  void _checkFree(AppEntry app) {
    final why = whyNot(app);
    if (why != null) throw RouteError('unavailable', why);
    if (jobs.activeFor(app.id)) throw RouteError('busy', 'a job for ${app.name} runs: try again when it has ended');
  }

  /// The bytes the Manager wrote as a choice (the recorded one and `chosen.svg`): a file with
  /// one of them is ours, anything else is the installer's.
  Set<String> _ours(_IconState st) => {
    if (st.choice?['sha256'] is String) st.choice!['sha256'] as String,
    if (File(st.chosen).existsSync()) sha256File(st.chosen),
  };

  Future<Map<String, dynamic>> set(Map<String, dynamic> params) async {
    final app = _app(params);
    _checkFree(app);
    final icon = _resolve(params['icon']);
    final file = iconFile(app)!;
    // no job starts meanwhile (the jobs' lock), the files under the state lock
    return jobs.exclusive(() async {
      final written = await withStateLock(paths, () async {
        if (FileSystemEntity.typeSync(file, followLinks: false) != FileSystemEntityType.file) {
          throw RouteError('not_installed', '$file is missing (or not a file): install ${app.name} first');
        }
        final st = _IconState.load(paths, app.id);
        final now = File(file).readAsBytesSync();
        final nowSha = _sha(now);
        Directory(st.dir).createSync(recursive: true);
        // The file is the installer's unless it is a choice of ours; a kept original is replaced
        // only by another installer's file (a new default), never by a choice. Each step is saved
        // before the next, so an interruption never costs the original.
        final hasOriginal = File(st.original).existsSync();
        if (!_ours(st).contains(nowSha) && (!hasOriginal || sha256File(st.original) != nowSha)) {
          atomicWriteBytes(st.original, now);
          st.data['original'] = {'sha256': nowSha, 'at': ctx.clock().toUtc().toIso8601String()};
          st.save();
        } else if (!hasOriginal) {
          throw RouteError('changed', '$file is an earlier choice but the original is missing: reinstall ${app.name}, then try again');
        }
        final sha = _sha(icon.bytes);
        atomicWriteBytes(st.chosen, icon.bytes);
        st.data['iconName'] = app.bar.iconName;
        st.data['file'] = file;
        st.data['choice'] = {...icon.choice, 'sha256': sha, 'at': ctx.clock().toUtc().toIso8601String()};
        st.save();
        atomicWriteBytes(file, icon.bytes);
        _receiptFollows(app, file, sha);
        return st.data['choice'] as Map<String, dynamic>;
      });
      final refreshed = await _refresh(app);
      return {'app': app.id, 'iconName': app.bar.iconName, 'file': file, 'choice': written, 'original': _IconState.load(paths, app.id).original, ...refreshed};
    });
  }

  Future<Map<String, dynamic>> reset(Map<String, dynamic> params) async {
    final app = _app(params);
    _checkFree(app);
    final file = iconFile(app)!;
    return jobs.exclusive(() async {
      final out = await withStateLock(paths, () async {
        final st = _IconState.load(paths, app.id);
        final hasOriginal = File(st.original).existsSync();
        if (!Directory(st.dir).existsSync() || (st.choice == null && !hasOriginal && !File(st.chosen).existsSync())) {
          return {'reset': false, 'note': 'the icon is the original'};
        }
        final now = File(file).existsSync() ? sha256File(file) : null;
        if (now == null || _ours(st).contains(now)) {
          if (!hasOriginal) throw RouteError('changed', 'the kept original of ${app.name}\'s icon is missing: reinstall ${app.name}');
          final bytes = File(st.original).readAsBytesSync();
          atomicWriteBytes(file, bytes);
          _receiptFollows(app, file, _sha(bytes));
        }
        // the file is the installer's again (restored, or a newer default): nothing of ours is kept
        Directory(st.dir).deleteSync(recursive: true);
        return {'reset': true, 'sha256': File(file).existsSync() ? sha256File(file) : null};
      });
      final refreshed = out['reset'] == true ? await _refresh(app) : const <String, dynamic>{};
      return {'app': app.id, 'iconName': app.bar.iconName, 'file': file, ...out, ...refreshed};
    });
  }

  /// After an install or update of [app]: a choice is written again over the installer's file
  /// (which becomes the kept original). A line for the log, or null when there is no choice.
  String? reapply(AppEntry app) {
    if (whyNot(app) != null) return null;
    final st = _IconState.load(paths, app.id);
    final choice = st.choice;
    if (choice == null || !File(st.chosen).existsSync()) return null;
    final file = iconFile(app)!;
    if (FileSystemEntity.typeSync(file, followLinks: false) != FileSystemEntityType.file) {
      return 'the chosen bar icon is not applied: the installer wrote no $file';
    }
    final now = File(file).readAsBytesSync();
    final chosen = File(st.chosen).readAsBytesSync();
    if (_sha(chosen) != choice['sha256']) return 'the chosen bar icon is not applied: ${st.chosen} changed';
    if (_sha(now) == choice['sha256']) return 'the chosen bar icon is in place';
    atomicWriteBytes(st.original, now);
    st.data['original'] = {'sha256': _sha(now), 'at': ctx.clock().toUtc().toIso8601String()};
    st.save();
    atomicWriteBytes(file, chosen);
    return 'the chosen bar icon (${choice['name'] ?? choice['from']}) written over the installer\'s $file again';
  }

  /// The receipt's entry for [file] follows a change the Manager made (so a remove still takes it).
  void _receiptFollows(AppEntry app, String file, String sha) {
    final path = p.join(paths.receipts, '${app.id}.json');
    if (readReceipt(paths, app.id).receipt == null) return;
    final data = jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
    var changed = false;
    for (final e in (data['paths'] as List).cast<Map<String, dynamic>>()) {
      if (e['path'] == file && e['sha256'] != null && e['sha256'] != sha) {
        e['sha256'] = sha;
        changed = true;
      }
    }
    if (!changed) return;
    Receipt.parse(app.id, data);
    atomicWrite(path, const JsonEncoder.withIndent('  ').convert(data));
  }

  /// Icon cache, then the bar icon: COSMIC: the applet's panel file written without it and back
  /// (the panel rebuilds and starts it again, as after installs; never a panel restart); KDE: the
  /// tray started again (when it runs and starts at login).
  Future<Map<String, dynamic>> _refresh(AppEntry app) async {
    final out = <String, dynamic>{};
    final cacheDir = p.join(paths.data, 'icons/hicolor');
    if (ctx.runner.which('gtk-update-icon-cache') != null && Directory(cacheDir).existsSync()) {
      final r = await ctx.runner.run(['gtk-update-icon-cache', '-q', '-t', cacheDir], timeout: const Duration(seconds: 60));
      out['iconCache'] = r.ok ? 'updated' : 'failed: ${r.stderr.trim()}';
    }
    final procs = ctx.processes();
    if (ctx.desktop == DesktopId.cosmic && app.bar.cosmicApplet != null) {
      final placed = cosmicInstances(paths).any((i) {
        final c = CosmicPanelConfig.read(paths, i);
        return c.error == null && c.layout.find(app.bar.cosmicApplet!) != null;
      });
      if (!placed) {
        out['bar'] = {'note': 'not in a panel'};
      } else {
        try {
          out['bar'] = <String, dynamic>{'panel': await jobs.nudgeApplet(app.bar.cosmicApplet!)};
        } on RouteError catch (e) {
          out['bar'] = <String, dynamic>{'error': '${e.code}: ${e.message}'};
        }
        if (app.bar.cosmicIconBuiltIn) (out['bar'] as Map)['note'] = 'the applet draws a built-in icon: ${app.bar.iconNote ?? ''}';
      }
    } else if (ctx.desktop == DesktopId.kde && app.bar.kdeTrayExe != null && app.bar.kdeAutostart != null) {
      final exe = paths.expand(app.bar.kdeTrayExe!);
      final trays = [for (final pr in procs) if (pr.exe == exe) pr];
      final autostart = paths.expand(app.bar.kdeAutostart!);
      final shown = File(autostart).existsSync() && !desktopHidden(autostart);
      if (trays.isEmpty || !shown) {
        out['bar'] = {'note': trays.isEmpty ? 'the tray doesn\'t run' : 'the tray is out of the bar'};
      } else {
        await stopProcesses(trays, signaller: jobs.signaller, procRoot: paths.proc, uid: ctx.uid, grace: jobs.stopGrace);
        out['bar'] = {'trayRestarted': await jobs.startDetached(exe, app.bar.kdeTrayArgs)};
      }
    } else {
      out['bar'] = {'note': 'no bar icon on this desktop'};
    }
    return out;
  }
}
