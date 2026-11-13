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

  /// The app's own folders: `maprisma-settings` (Maprisma Settings was Maprisma Manager; the
  /// folders of the old name are renamed once and left as links, [migrateLegacyFolders]).
  String get managerState => p.join(state, appFolder);
  String get receipts => p.join(managerState, 'installed');
  String get settingsFile => p.join(config, appFolder, 'settings.json');

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

/// The folder name of the app's settings, state, data, cache and bundle.
const appFolder = 'maprisma-settings';

/// The folder name before the rename to Maprisma Settings.
const legacyAppFolder = 'maprisma-manager';

/// The rename from Maprisma Manager to Maprisma Settings, once (the same rule as tools/procs.sh
/// `migrate_legacy`, which install-local and the self-update helper run, also for ~/.local/lib):
/// each folder of the old name (config, state, data, cache) that is a real folder, while none of the
/// new name exists, is renamed (never copied) and a link of the old name is left pointing to the new
/// one, so an older build, its self-update helper and other tools that still use the old name find
/// the same files. Then the state keyed by the app's old id (`manager`) gets its new id
/// ([migrateLegacyIds]). Returns what it did (for a note), empty when nothing was to do.
List<String> migrateLegacyFolders(Paths paths) {
  final done = <String>[];
  for (final base in {paths.config, paths.state, paths.data, paths.cache}) {
    final note = migrateFolder(p.join(base, legacyAppFolder), p.join(base, appFolder));
    if (note != null) done.add(note);
  }
  done.addAll(migrateLegacyIds(paths));
  return done;
}

/// [old] → [renamed] by rename with a link left at [old] (see [migrateLegacyFolders]); null when
/// there was nothing to do (no real folder at [old], or [renamed] exists, or another file system).
String? migrateFolder(String old, String renamed) {
  if (FileSystemEntity.typeSync(old, followLinks: false) != FileSystemEntityType.directory) return null;
  if (FileSystemEntity.typeSync(renamed, followLinks: false) != FileSystemEntityType.notFound) return null;
  try {
    // a mount point (another device than its parent) can't be renamed: left alone
    if (_device(old) != _device(p.dirname(old))) return null;
    Directory(old).renameSync(renamed);
  } on FileSystemException {
    return null; // another process did it first, or it can't be renamed: the old one stays in use
  }
  try {
    Link(old).createSync(p.basename(renamed));
  } on FileSystemException catch (e) {
    return 'moved $old to $renamed (no link left: ${e.osError?.message ?? e.message})';
  }
  return 'moved $old to $renamed (link left)';
}

int? _device(String path) {
  try {
    final r = Process.runSync('stat', ['-c', '%d', '--', path]);
    return r.exitCode == 0 ? int.tryParse('${r.stdout}'.trim()) : null;
  } on ProcessException {
    return null;
  }
}

/// The app's id was `manager` before the rename (now [selfAppId]): its receipt, kept record, icon
/// state, displaced files and the Bar page's wish get the new id. Never over an entry of the new id.
List<String> migrateLegacyIds(Paths paths) {
  const old = legacySelfAppId, now = selfAppId;
  final done = <String>[];
  final state = paths.managerState;
  // the receipt names its id inside: rewritten with the new one, then the old file goes
  final receipt = File(p.join(state, 'installed', '$old.json'));
  final newReceipt = File(p.join(state, 'installed', '$now.json'));
  if (receipt.existsSync() && !newReceipt.existsSync()) {
    try {
      final data = jsonDecode(receipt.readAsStringSync());
      if (data is Map<String, dynamic> && data['id'] == old) {
        data['id'] = now;
        final tmp = File('${newReceipt.path}.tmp.$pid');
        tmp.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(data));
        tmp.renameSync(newReceipt.path);
        receipt.deleteSync();
        done.add('receipt $old -> $now');
      }
    } on Object {
      // a broken receipt stays as it is (it is reported as broken under the old id: never trusted)
    }
  }
  for (final (dir, suffix) in [('kept', '.json'), ('icons', ''), ('displaced', '')]) {
    final from = p.join(state, dir, '$old$suffix'), to = p.join(state, dir, '$now$suffix');
    if (FileSystemEntity.typeSync(from, followLinks: false) == FileSystemEntityType.notFound) continue;
    if (FileSystemEntity.typeSync(to, followLinks: false) != FileSystemEntityType.notFound) continue;
    try {
      if (FileSystemEntity.isDirectorySync(from)) {
        Directory(from).renameSync(to);
      } else {
        File(from).renameSync(to);
      }
      done.add('$dir/$old$suffix -> $now$suffix');
    } on FileSystemException {
      // left under the old id
    }
  }
  // the Bar page's wishes: {desktop: {app: …}}
  final bar = File(p.join(state, 'bar.json'));
  try {
    final data = jsonDecode(bar.readAsStringSync());
    if (data is Map<String, dynamic>) {
      var changed = false;
      for (final d in data.values) {
        if (d is Map && d.containsKey(old)) {
          final v = d.remove(old);
          d.putIfAbsent(now, () => v);
          changed = true;
        }
      }
      if (changed) {
        final tmp = File('${bar.path}.tmp.$pid');
        tmp.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(data));
        tmp.renameSync(bar.path);
        done.add('bar.json $old -> $now');
      }
    }
  } on Object {
    // none, or broken: the Bar page treats it as none
  }
  return done;
}

/// The app's own catalog id, and the one it had as Maprisma Manager (accepted everywhere an id is
/// given: [findApp], jobs of before the rename).
const selfAppId = 'settings';
const legacySelfAppId = 'manager';

/// The user's settings (`~/.config/maprisma-settings/settings.json`); settings routes persist changes.
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

  /// Corners: "windows" (the desktop's window corners, also for a missing or unknown value),
  /// "slight" 6 px, "rounded" 12 px, "square".
  String get corners {
    final v = values['corners'];
    return cornerSettings.contains(v) ? v as String : 'windows';
  }

  /// F12 saves a screenshot: on unless switched off.
  bool get screenshotKey => values['screenshot_key'] != false;
}

/// The values of the Corners setting.
const cornerSettings = ['windows', 'slight', 'rounded', 'square'];

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
