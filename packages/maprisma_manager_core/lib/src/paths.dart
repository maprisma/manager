import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Where things are, all derived from the environment (HOME, XDG_*), so tests run
/// against a temporary HOME. System paths (/usr, /etc) go through [root].
final class Paths {
  Paths({
    required this.home,
    required this.config,
    required this.data,
    required this.state,
    required this.cache,
    this.root = '/',
    this.proc = '/proc',
  });

  factory Paths.fromEnvironment(Map<String, String> env) {
    final home = env['HOME'];
    if (home == null || home.isEmpty || !p.isAbsolute(home)) {
      throw StateError('HOME is not set to an absolute path');
    }
    // The XDG spec ignores relative values.
    String xdg(String key, String fallback) {
      final v = env[key];
      return v != null && v.isNotEmpty && p.isAbsolute(v) ? v : p.join(home, fallback);
    }

    return Paths(
      home: home,
      config: xdg('XDG_CONFIG_HOME', '.config'),
      data: xdg('XDG_DATA_HOME', '.local/share'),
      state: xdg('XDG_STATE_HOME', '.local/state'),
      cache: xdg('XDG_CACHE_HOME', '.cache'),
      root: env['MAPRISMA_MANAGER_ROOT'] ?? '/',
      proc: env['MAPRISMA_MANAGER_PROC'] ?? '/proc',
    );
  }

  final String home;
  final String config;
  final String data;
  final String state;
  final String cache;

  /// The system root for /usr and /etc paths (tests: a temp folder).
  final String root;

  /// The /proc to read processes from (tests: a fake one).
  final String proc;

  /// Every installer writes binaries to $HOME/.local/bin (not an XDG variable).
  String get bin => p.join(home, '.local/bin');
  String get lib => p.join(home, '.local/lib');

  /// $HOME/.local/share whatever XDG_DATA_HOME says (Launcher's install-local and
  /// Narrator's backend setup hardcode it).
  String get homeShare => p.join(home, '.local/share');
  String get apps => p.join(data, 'applications');
  String get icons => p.join(data, 'icons/hicolor/scalable/apps');
  String get autostart => p.join(config, 'autostart');
  String get units => p.join(config, 'systemd/user');

  String get managerState => p.join(state, 'maprisma-manager');
  String get receipts => p.join(managerState, 'installed');
  String get settingsFile => p.join(config, 'maprisma-manager/settings.json');

  String sys(String absolute) => root == '/' ? absolute : p.join(root, absolute.substring(1));

  /// Expands `{bin}`, `{data}` … in a catalog path template.
  String expand(String template) {
    var out = template;
    final map = {
      '{bin}': bin,
      '{lib}': lib,
      '{homeShare}': homeShare,
      '{apps}': apps,
      '{icons}': icons,
      '{autostart}': autostart,
      '{units}': units,
      '{config}': config,
      '{data}': data,
      '{state}': state,
      '{cache}': cache,
      '{home}': home,
    };
    for (final e in map.entries) {
      out = out.replaceAll(e.key, e.value);
    }
    if (out.contains('{')) throw ArgumentError.value(template, 'template', 'unknown placeholder');
    return p.isAbsolute(out) && !template.startsWith('{') ? sys(out) : out;
  }
}

/// The user's settings (`~/.config/maprisma-manager/settings.json`); settings routes persist changes.
final class Settings {
  Settings(this.values);

  factory Settings.load(Paths paths) {
    try {
      final data = jsonDecode(File(paths.settingsFile).readAsStringSync());
      if (data is Map<String, dynamic>) return Settings(data);
    } on FileSystemException {
      // no settings yet
    } on FormatException {
      // a broken file counts as none; the UI will offer to fix it later
    }
    return Settings(const {});
  }

  final Map<String, dynamic> values;

  String? str(String key) {
    final v = values[key];
    return v is String && v.isNotEmpty ? v : null;
  }
}

/// Default candidates for the projects folder after MAPRISMA_PROJECTS and the settings file.
const defaultProjectCandidates = ['{home}/Projects', '/mnt/Data/Projects'];

/// Where the repos are: MAPRISMA_PROJECTS, else the `projectsDir` setting, else the first
/// candidate that holds at least one known repo, else the first that exists, else ~/Projects.
({String dir, String source}) resolveProjectsDir(
  Paths paths,
  Map<String, String> env,
  Settings settings,
  Iterable<String> knownRepos, {
  List<String> candidates = defaultProjectCandidates,
}) {
  final fromEnv = env['MAPRISMA_PROJECTS'];
  if (fromEnv != null && fromEnv.isNotEmpty) return (dir: _abs(paths, fromEnv), source: 'env');
  final fromSettings = settings.str('projectsDir');
  if (fromSettings != null) return (dir: _abs(paths, fromSettings), source: 'settings');
  final dirs = [for (final c in candidates) c.replaceAll('{home}', paths.home)];
  for (final d in dirs) {
    if (knownRepos.any((r) => Directory(p.join(d, r)).existsSync())) return (dir: d, source: 'found');
  }
  for (final d in dirs) {
    if (Directory(d).existsSync()) return (dir: d, source: 'default');
  }
  return (dir: dirs.first, source: 'default');
}

String _abs(Paths paths, String v) {
  if (v == '~') return paths.home;
  if (v.startsWith('~/')) return p.join(paths.home, v.substring(2));
  return p.normalize(p.isAbsolute(v) ? v : p.join(paths.home, v));
}
