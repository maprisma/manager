/// The catalog's types: what an app is made of, as plain data (docs/inventory.md).
library;

enum DesktopId { cosmic, kde, other }

enum PathKind { file, executable, dir, link }

/// One path an installer writes. Templates use `{bin}`, `{data}` … (see Paths.expand).
final class InstalledPath {
  const InstalledPath(this.path, this.kind, {this.target, this.part = 'main', this.key = false, this.note});

  final String path;
  final PathKind kind;

  /// For links: where it must point (also a template).
  final String? target;

  /// Which part of the component it belongs to (e.g. `settings window`): a part that
  /// the installer may skip makes the component "partly installed".
  final String part;

  /// The key file: when absent, the component counts as not installed.
  final bool key;
  final String? note;

  Map<String, dynamic> toJson() => {
    'path': path,
    'kind': kind.name,
    if (target != null) 'target': target,
    'part': part,
    if (key) 'key': true,
    if (note != null) 'note': note,
  };
}

/// Something made at runtime (by the app, its setup, or later steps), not by the
/// installer: never a postcondition, removed only by its own step (plan: "not removed blindly").
final class RuntimePath {
  const RuntimePath(this.path, {required this.note, this.glob = false, this.marker});
  final String path;
  final String note;

  /// [path] is a glob of the last segment (e.g. `maprisma-theme-key-*.desktop`).
  final bool glob;

  /// The start of a line that marks the file as written by this app (others are foreign).
  final String? marker;

  Map<String, dynamic> toJson() => {
    'path': path,
    'note': note,
    if (glob) 'glob': true,
    if (marker != null) 'marker': marker,
  };
}

/// User data: kept on remove unless asked; Omarchy-shared data never deleted.
final class DataPath {
  const DataPath(this.path, {this.sharedWithOmarchy = false, this.note});
  final String path;
  final bool sharedWithOmarchy;
  final String? note;

  bool get neverDelete => sharedWithOmarchy;

  Map<String, dynamic> toJson() => {
    'path': path,
    if (sharedWithOmarchy) 'sharedWithOmarchy': true,
    'neverDelete': neverDelete,
    if (note != null) 'note': note,
  };
}

enum MatchKind {
  /// `/proc/<pid>/exe` is this file (" (deleted)" stripped).
  exe,

  /// `/proc/<pid>/exe` is inside this folder (or a `<folder>.*` sibling: atomic swaps).
  exeUnder,

  /// An argv element after argv[0], normalized, is this script (never the interpreter).
  script,

  /// An argv element after argv[0], normalized, is inside this folder.
  scriptUnder,
}

final class ProcessMatch {
  const ProcessMatch(this.kind, this.path, {this.note});
  final MatchKind kind;
  final String path;
  final String? note;

  Map<String, dynamic> toJson() => {'match': kind.name, 'path': path, if (note != null) 'note': note};
}

/// A systemd user unit belonging to the app (stopped before its processes).
final class UnitRef {
  const UnitRef(this.name, {this.runtime = false, this.file, this.note});
  final String name;

  /// Where its unit file is (template); default `{units}/<name>`.
  final String? file;
  String get fileTemplate => file ?? '{units}/$name';

  /// Written at runtime (e.g. by the app or its setup), not by the installer.
  final bool runtime;
  final String? note;

  Map<String, dynamic> toJson() => {'name': name, if (runtime) 'runtime': true, 'unitFile': fileTemplate, 'note': ?note};
}

enum KdeBarKind {
  /// A StatusNotifierItem tray process started from an autostart file.
  tray,

  /// A fixed entry of the Maprisma Icons widget (no tray process).
  widgetEntry,
}

final class BarIcon {
  const BarIcon({
    this.cosmicApplet,
    this.kdeId,
    this.kdeKind = KdeBarKind.tray,
    this.kdeAutostart,
    this.kdeTrayExe,
    this.iconName,
    this.kdeIconName,
  });

  /// The COSMIC applet id (the panel config lists it), e.g. io.github.ubruckhaus.CosmicMaprismaHome.
  final String? cosmicApplet;

  /// The KDE id: the tray's SNI Id, or the widget entry's id.
  final String? kdeId;
  final KdeBarKind kdeKind;

  /// The tray's autostart file (template), for KDE trays.
  final String? kdeAutostart;

  /// The tray's program (template), to tell whether it runs.
  final String? kdeTrayExe;

  /// The icon name the applet/tray loads (an own name can be replaced; plan "Changing an icon").
  final String? iconName;

  /// The KDE tray's icon name when it differs from [iconName].
  final String? kdeIconName;

  bool get none => cosmicApplet == null && kdeId == null;

  Map<String, dynamic> toJson() => {
    'cosmicApplet': cosmicApplet,
    'kdeId': kdeId,
    if (kdeId != null) 'kdeKind': kdeKind.name,
    if (kdeAutostart != null) 'kdeAutostart': kdeAutostart,
    if (kdeTrayExe != null) 'kdeTrayExe': kdeTrayExe,
    'iconName': ?iconName,
    'kdeIconName': ?kdeIconName,
  };
}

/// A tool a component needs to build or install. [part] limits it to one part (an
/// installer that skips that part without it).
final class Prerequisite {
  const Prerequisite(this.command, {this.part, this.optional = false, this.note});
  final String command;
  final String? part;

  /// Used when present, nothing fails without it (e.g. gtk-update-icon-cache).
  final bool optional;
  final String? note;
}

/// How an install script wants Flutter.
enum FlutterEnv {
  none,

  /// `FLUTTER=<the folder with the flutter executable>` (Theme's install-local puts it in PATH).
  dir,

  /// `FLUTTER=<the flutter executable>` (Narrator, Video Translator).
  executable,

  /// flutter found in PATH (Launcher, Maprisma's build-release.py).
  path,
}

enum InstallKind { script, pacman }

/// One installable unit: a repo and its install command.
final class Component {
  const Component({
    required this.id,
    required this.name,
    required this.repo,
    required this.install,
    required this.paths,
    this.kind = InstallKind.script,
    this.desktops = const {DesktopId.cosmic, DesktopId.kde, DesktopId.other},
    this.prerequisites = const [],
    this.flutter = FlutterEnv.none,
    this.optionalParts = const {},
    this.dependsOn = const [],
    this.note,
  });

  final String id;
  final String name;

  /// Folder name under the projects folder.
  final String repo;

  /// argv, run in the repo folder.
  final List<String> install;
  final InstallKind kind;
  final List<InstalledPath> paths;
  final Set<DesktopId> desktops;
  final List<Prerequisite> prerequisites;
  final FlutterEnv flutter;

  /// Parts the installer skips when a tool is missing (the script still succeeds).
  final Set<String> optionalParts;

  /// Other components (`app` or `app/component`) needed first.
  final List<String> dependsOn;
  final String? note;
}

/// A repo whose state goes into a build (Maprisma: the add-ons checkout).
final class Input {
  const Input(this.repo, {this.remote, this.note});
  final String repo;

  /// The URL to clone from when the folder is missing; null = not available elsewhere.
  final String? remote;
  final String? note;
}

/// Where the installed and the folder's version can be read (optional).
final class VersionSource {
  const VersionSource({this.pacman, this.installedJson, this.folderFile, this.folderPattern});

  /// pacman package name.
  final String? pacman;

  /// A Flutter bundle's version.json (template).
  final String? installedJson;

  /// A file in the main repo and a regex whose group 1 is the version.
  final String? folderFile;
  final String? folderPattern;
}

final class AppEntry {
  const AppEntry({
    required this.id,
    required this.name,
    required this.kind,
    required this.inputs,
    required this.components,
    this.desktops = const {DesktopId.cosmic, DesktopId.kde, DesktopId.other},
    this.data = const [],
    this.runtime = const [],
    this.processes = const [],
    this.units = const [],
    this.bar = const BarIcon(),
    this.dependsOn = const [],
    this.version = const VersionSource(),
    this.postSteps = const [],
    this.note,
  });

  final String id;
  final String name;

  /// rust, flutter, rust + flutter, KWin scripts …
  final String kind;

  /// The repos that make a build, the first is the main one.
  final List<Input> inputs;
  final List<Component> components;
  final Set<DesktopId> desktops;
  final List<DataPath> data;
  final List<RuntimePath> runtime;
  final List<ProcessMatch> processes;
  final List<UnitRef> units;
  final BarIcon bar;

  /// Apps needed by this one.
  final List<String> dependsOn;
  final VersionSource version;

  /// What runs after an install (icon cache, desktop database …), as words for now.
  final List<String> postSteps;
  final String? note;

  Input get mainInput => inputs.first;
}
