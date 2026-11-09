/// The 14 apps the Manager knows, as data. Every path was read from the repo's own install
/// script (2026-11-09); docs/inventory.md is the human version of this file.
///
/// Templates: `{bin}` = $HOME/.local/bin, `{lib}` = $HOME/.local/lib, `{data}` = XDG_DATA_HOME,
/// `{homeShare}` = $HOME/.local/share (scripts that hardcode it), `{apps}`, `{icons}`
/// (hicolor/scalable/apps), `{autostart}`, `{units}` (systemd user), `{config}`, `{state}`,
/// `{cache}`; absolute paths are system paths.
library;

import 'catalog_model.dart';

export 'catalog_model.dart';

const _cosmic = {DesktopId.cosmic};
const _kde = {DesktopId.kde};
const _c = 'io.github.ubruckhaus.CosmicMaprisma';

const _gtkIconCache = Prerequisite('gtk-update-icon-cache', optional: true);
const _desktopDb = Prerequisite('update-desktop-database', optional: true);

/// The rust applet + tray apps share one installer layout (install.sh, `cargo build --release`).
AppEntry _rustApp({
  required String id,
  required String name,
  required String repo,
  required String suffix,
  required String binary,
  required List<String> scripts,
  String? github,
  List<DataPath> data = const [],
  List<RuntimePath> runtime = const [],
}) {
  final appId = '$_c$suffix';
  return AppEntry(
    id: id,
    name: name,
    kind: 'rust',
    inputs: [Input(repo, github: github)],
    components: [
      Component(
        id: 'main',
        name: name,
        repo: repo,
        install: const ['./install.sh'],
        prerequisites: const [Prerequisite('cargo'), _gtkIconCache],
        paths: [
          InstalledPath('{bin}/$binary', PathKind.executable, key: true),
          InstalledPath('{bin}/$binary-tray', PathKind.executable),
          for (final s in scripts)
            InstalledPath('{data}/$binary/scripts/$s', s.endsWith('.sh') ? PathKind.executable : PathKind.file),
          InstalledPath('{icons}/$appId-symbolic.svg', PathKind.file),
          InstalledPath('{apps}/$appId.desktop', PathKind.file),
          InstalledPath('{apps}/$appId.Window.desktop', PathKind.file),
          InstalledPath('{autostart}/$appId.Tray.desktop', PathKind.file, note: 'OnlyShowIn=KDE'),
        ],
      ),
    ],
    data: data,
    runtime: runtime,
    processes: [
      ProcessMatch(MatchKind.exe, '{bin}/$binary'),
      ProcessMatch(MatchKind.exe, '{bin}/$binary-tray'),
      // Started as `python3 -I {bin}/../share/<app>/scripts/x.py`: matched after normalizing.
      for (final s in scripts.where((s) => s.endsWith('.py') || s.endsWith('.sh')))
        ProcessMatch(MatchKind.script, '{data}/$binary/scripts/$s'),
    ],
    bar: BarIcon(
      cosmicApplet: appId,
      cosmicAppletExe: '{bin}/$binary',
      kdeId: binary,
      kdeAutostart: '{autostart}/$appId.Tray.desktop',
      kdeTrayExe: '{bin}/$binary-tray',
      iconName: '$appId-symbolic',
    ),
    postSteps: const ['gtk-update-icon-cache'],
  );
}

/// The built-in catalog; [catalog] is what everything uses (tests may set [catalogOverride]).
final List<AppEntry> builtinCatalog = [
  // --- maprisma: the pacman package -------------------------------------------------------
  const AppEntry(
    id: 'maprisma',
    name: 'Maprisma',
    kind: 'pacman package maprisma-bin',
    inputs: [
      // The folder's origin is the private uBruckhaus/maprisma; GitHub here is its `public` remote.
      Input('maprisma', github: 'maprisma/maprisma'),
      Input('maprisma-addons', github: 'maprisma/maprisma-addons', note: 'dist/adapters-<version>.zip, signed'),
    ],
    components: [
      Component(
        id: 'package',
        name: 'Maprisma (maprisma-bin)',
        repo: 'maprisma',
        kind: InstallKind.pacman,
        install: ['python3', 'tools/build-release.py', '--addons', '../maprisma-addons'],
        flutter: FlutterEnv.path,
        prerequisites: [
          Prerequisite('python3'),
          Prerequisite('flutter'),
          Prerequisite('makepkg'),
          Prerequisite('pacman'),
          Prerequisite('pkexec'),
        ],
        note: 'Packaged from a generated recipe for the exact local archive (plan: maprisma (pacman)).',
        paths: [
          InstalledPath('/usr/lib/maprisma/maprisma', PathKind.executable, key: true),
          InstalledPath('/usr/lib/maprisma/lib/maprisma-core', PathKind.executable),
          InstalledPath('/usr/bin/maprisma', PathKind.link, target: '/usr/lib/maprisma/maprisma'),
          InstalledPath('/usr/share/applications/com.maprisma.Maprisma.desktop', PathKind.file),
          InstalledPath('/usr/share/metainfo/com.maprisma.Maprisma.metainfo.xml', PathKind.file),
          InstalledPath('/usr/share/icons/hicolor/scalable/apps/com.maprisma.Maprisma.svg', PathKind.file),
          InstalledPath('/usr/share/licenses/maprisma-bin/LICENSE', PathKind.file),
        ],
      ),
    ],
    data: [
      DataPath('{config}/maprisma'),
      DataPath('{cache}/maprisma'),
      DataPath('{state}/maprisma'),
      DataPath('{data}/maprisma'),
    ],
    units: [UnitRef('maprisma-providers.service', runtime: true, note: 'written and enabled by Maprisma itself')],
    processes: [
      ProcessMatch(MatchKind.exeUnder, '/usr/lib/maprisma', note: 'maprisma, lib/maprisma-core; stop the provider service first'),
    ],
    bar: BarIcon(),
    version: VersionSource(pacman: 'maprisma-bin', folderFile: 'addons.py', folderPattern: r'^MAPRISMA_VERSION = "([0-9.]+)"'),
    postSteps: ['systemctl --user restart maprisma-providers.service'],
    release: ReleaseSpec(
      tarball: 'maprisma-{version}-x86_64.tar.gz',
      component: 'package',
      supported: false,
      note: 'installed as a pacman package from a recipe for the tarball (step 5)',
    ),
    installation: Support.unsupportedYet,
    removal: Support.unsupportedYet,
    supportNote: 'the pacman package comes in step 5',
    note: 'Maprisma Control is its bar icon.',
  ),

  // --- control: maprisma-applet ------------------------------------------------------------
  const AppEntry(
    id: 'control',
    name: 'Maprisma Control',
    kind: 'rust',
    inputs: [Input('maprisma-applet')],
    dependsOn: ['maprisma'],
    components: [
      Component(
        id: 'main',
        name: 'Maprisma Control',
        repo: 'maprisma-applet',
        install: ['./install.sh'],
        prerequisites: [Prerequisite('cargo')],
        paths: [
          InstalledPath('{bin}/maprisma-applet', PathKind.executable, key: true),
          InstalledPath('{bin}/maprisma-control-tray', PathKind.executable),
          InstalledPath('{apps}/$_c.desktop', PathKind.file),
          InstalledPath('{autostart}/com.maprisma.Control.Tray.desktop', PathKind.file, note: 'OnlyShowIn=KDE'),
        ],
      ),
    ],
    processes: [
      ProcessMatch(MatchKind.exe, '{bin}/maprisma-applet'),
      ProcessMatch(MatchKind.exe, '{bin}/maprisma-control-tray'),
    ],
    bar: BarIcon(
      cosmicApplet: _c,
      cosmicAppletExe: '{bin}/maprisma-applet',
      kdeId: 'maprisma-control',
      kdeAutostart: '{autostart}/com.maprisma.Control.Tray.desktop',
      kdeTrayExe: '{bin}/maprisma-control-tray',
      iconName: 'com.maprisma.Maprisma',
    ),
  ),

  // --- launcher: maprisma-launcher + its COSMIC applet -------------------------------------
  const AppEntry(
    id: 'launcher',
    name: 'Maprisma Launcher',
    kind: 'flutter',
    inputs: [
      Input('maprisma-launcher', github: 'maprisma/launcher'),
      Input('maprisma-launcher-applet'),
    ],
    components: [
      Component(
        id: 'app',
        name: 'Maprisma Launcher',
        repo: 'maprisma-launcher',
        install: ['tools/install-local'],
        flutter: FlutterEnv.path,
        stopsOwnProcesses: true,
        prerequisites: [Prerequisite('python3'), Prerequisite('flutter'), Prerequisite('cargo'), _desktopDb],
        note: 'install-local hardcodes \$HOME/.local/share; it stops the running copies itself and refuses while its terminal runs a command.',
        paths: [
          InstalledPath('{lib}/maprisma-launcher/maprisma-launcher', PathKind.executable, key: true),
          InstalledPath('{lib}/maprisma-launcher/maprisma-launcher-windows', PathKind.executable, note: 'cosmic-windows helper'),
          InstalledPath('{lib}/maprisma-launcher/lib/libapp.so', PathKind.file),
          InstalledPath('{lib}/maprisma-launcher/data/flutter_assets/version.json', PathKind.file),
          InstalledPath('{bin}/maprisma-launcher', PathKind.link, target: '{lib}/maprisma-launcher/maprisma-launcher'),
          InstalledPath('{homeShare}/applications/com.maprisma.Launcher.desktop', PathKind.file),
          InstalledPath('{homeShare}/applications/com.maprisma.Launcher.Toggle.desktop', PathKind.file),
          InstalledPath('{homeShare}/icons/hicolor/scalable/apps/com.maprisma.Launcher.svg', PathKind.file),
        ],
      ),
      Component(
        id: 'applet',
        name: 'Maprisma Launcher applet',
        repo: 'maprisma-launcher-applet',
        install: ['./install.sh'],
        desktops: _cosmic,
        dependsOn: ['launcher/app'],
        prerequisites: [Prerequisite('cargo')],
        paths: [
          InstalledPath('{bin}/maprisma-launcher-applet', PathKind.executable, key: true),
          InstalledPath('{apps}/${_c}Launcher.desktop', PathKind.file),
        ],
      ),
    ],
    data: [
      DataPath('{config}/maprisma-launcher'),
      DataPath('{cache}/maprisma-launcher'),
      DataPath('{data}/maprisma-launcher'),
    ],
    runtime: [
      // The app writes these to XDG_DATA_HOME (desktopDirectories), unlike install-local.
      RuntimePath('{apps}/maprisma-launcher-*.desktop', glob: true, note: 'KDE shortcuts written by the app'),
      RuntimePath('{config}/cosmic/com.system76.CosmicSettings.Shortcuts/v1/custom', note: 'COSMIC shortcut entries (inside a shared file)'),
    ],
    processes: [
      ProcessMatch(MatchKind.exeUnder, '{lib}/maprisma-launcher', note: 'also the dock (--dock) and maprisma-launcher-windows'),
      ProcessMatch(MatchKind.exe, '{bin}/maprisma-launcher-applet'),
    ],
    bar: BarIcon(cosmicApplet: '${_c}Launcher', cosmicAppletExe: '{bin}/maprisma-launcher-applet', kdeId: 'maprisma-launcher', kdeKind: KdeBarKind.widgetEntry, iconName: 'com.maprisma.Launcher'),
    version: VersionSource(
      installedJson: '{lib}/maprisma-launcher/data/flutter_assets/version.json',
      folderFile: 'flutter_app/pubspec.yaml',
      folderPattern: r'^version: *([0-9.]+)',
    ),
    postSteps: ['update-desktop-database'],
    // install-local --no-build installs the newest dist/maprisma-launcher-*-x86_64.tar.gz.
    release: ReleaseSpec(
      tarball: 'maprisma-launcher-{version}-x86_64.tar.gz',
      component: 'app',
      install: ['tools/install-local', '--no-build'],
      dist: 'dist',
      prerequisites: [Prerequisite('bash'), Prerequisite('tar')],
    ),
    removal: Support.unsupportedYet,
    supportNote: 'its Flutter bundle needs whole-tree ownership in the receipt first (step 5)',
  ),

  // --- theme: maprisma-theme ---------------------------------------------------------------
  const AppEntry(
    id: 'theme',
    name: 'Maprisma Theme',
    kind: 'flutter + rust',
    inputs: [Input('maprisma-theme')],
    components: [
      Component(
        id: 'main',
        name: 'Maprisma Theme',
        repo: 'maprisma-theme',
        install: ['tools/install-local'],
        flutter: FlutterEnv.dir,
        stopsOwnProcesses: true,
        prerequisites: [Prerequisite('flutter'), Prerequisite('dart'), Prerequisite('cargo'), _gtkIconCache, _desktopDb],
        note: 'FLUTTER is the folder with flutter in it; on KDE the script starts the tray daemon itself.',
        paths: [
          InstalledPath('{lib}/maprisma-theme/maprisma-theme', PathKind.executable, key: true),
          InstalledPath('{lib}/maprisma-theme/bin/maprisma-theme-core', PathKind.executable),
          InstalledPath('{lib}/maprisma-theme/bin/maprisma-theme-helper', PathKind.executable),
          InstalledPath('{lib}/maprisma-theme/bin/maprisma-theme-applet', PathKind.executable),
          InstalledPath('{lib}/maprisma-theme/lib/libapp.so', PathKind.file),
          InstalledPath('{lib}/maprisma-theme/share/maprisma-theme/themes', PathKind.dir),
          InstalledPath('{lib}/maprisma-theme/share/maprisma-theme/templates', PathKind.dir),
          InstalledPath('{bin}/maprisma-theme', PathKind.link, target: '{lib}/maprisma-theme/maprisma-theme'),
          InstalledPath('{bin}/maprisma-theme-core', PathKind.link, target: '{lib}/maprisma-theme/bin/maprisma-theme-core'),
          InstalledPath('{bin}/maprisma-theme-helper', PathKind.link, target: '{lib}/maprisma-theme/bin/maprisma-theme-helper'),
          InstalledPath('{bin}/maprisma-theme-applet', PathKind.link, target: '{lib}/maprisma-theme/bin/maprisma-theme-applet'),
          InstalledPath('{apps}/com.maprisma.Theme.desktop', PathKind.file),
          InstalledPath('{apps}/com.maprisma.Theme.Toggle.desktop', PathKind.file),
          InstalledPath('{apps}/${_c}Theme.desktop', PathKind.file),
          InstalledPath('{icons}/com.maprisma.Theme.svg', PathKind.file),
          InstalledPath('{icons}/${_c}Theme-symbolic.svg', PathKind.file),
          InstalledPath('{autostart}/com.maprisma.Theme.Daemon.desktop', PathKind.file, note: 'the KDE tray/automation daemon'),
        ],
      ),
    ],
    data: [
      DataPath('{config}/maprisma-theme'),
      DataPath('{state}/maprisma-theme'),
      DataPath('{cache}/maprisma-theme'),
    ],
    runtime: [RuntimePath('{apps}/maprisma-theme-key-*.desktop', glob: true, note: 'KDE keys written by the app')],
    processes: [ProcessMatch(MatchKind.exeUnder, '{lib}/maprisma-theme', note: 'app, core daemon, helper, applet')],
    bar: BarIcon(
      cosmicApplet: '${_c}Theme',
      cosmicAppletExe: '{bin}/maprisma-theme-applet',
      kdeId: 'maprisma-theme',
      kdeAutostart: '{autostart}/com.maprisma.Theme.Daemon.desktop',
      kdeTrayExe: '{lib}/maprisma-theme/bin/maprisma-theme-core',
      kdeTrayArgs: ['daemon'],
      iconName: '${_c}Theme-symbolic',
      kdeIconName: 'com.maprisma.Theme', // the daemon's SNI IconName (daemon.dart)
    ),
    version: VersionSource(
      installedJson: '{lib}/maprisma-theme/data/flutter_assets/version.json',
      folderFile: 'flutter_app/pubspec.yaml',
      folderPattern: r'^version: *([0-9.]+)',
    ),
    postSteps: ['gtk-update-icon-cache', 'update-desktop-database'],
    removal: Support.unsupportedYet,
    supportNote: 'its Flutter bundle needs whole-tree ownership in the receipt first (step 5)',
  ),

  // --- the rust monitors -------------------------------------------------------------------
  _rustApp(
    id: 'bluetooth',
    name: 'Maprisma Bluetooth Monitor',
    repo: 'maprisma-bluetooth-monitor',
    suffix: 'BluetoothMonitor',
    binary: 'maprisma-bluetooth-monitor',
    github: 'maprisma/bluetooth-monitor',
    scripts: const ['bluetooth-monitor.py', 'audio-default.py', 'bt-device.sh', 'bt-power.sh', 'allow-access.sh'],
    data: const [
      DataPath('{config}/maprisma-bluetooth-monitor'),
      DataPath('{config}/bluetooth-monitor', sharedWithOmarchy: true),
    ],
    runtime: const [
      RuntimePath('/etc/udev/rules.d/42-logitech-hidpp-uaccess.rules', note: 'written by allow-access.sh via pkexec'),
    ],
  ),
  _rustApp(
    id: 'home',
    name: 'Maprisma Home',
    repo: 'maprisma-home',
    suffix: 'Home',
    binary: 'maprisma-home',
    scripts: const ['stove.py', 'switchbot.py', 'stove_map.json'],
    data: const [
      DataPath('{config}/maprisma-home', note: 'config.json seeded by the installer if missing'),
      DataPath('{state}/ubruckhaus.home'),
    ],
  ),
  _rustApp(
    id: 'hue',
    name: 'Maprisma Hue Lights',
    repo: 'maprisma-hue-lights',
    suffix: 'HueLights',
    binary: 'maprisma-hue-lights',
    github: 'maprisma/hue-lights',
    scripts: const ['hue-lights.py'],
    data: const [DataPath('{config}/hue-lights', sharedWithOmarchy: true)],
  ),
  _rustApp(
    id: 'llm',
    name: 'Maprisma LLM Monitor',
    repo: 'maprisma-llm-monitor',
    suffix: 'LlmMonitor',
    binary: 'maprisma-llm-monitor',
    github: 'maprisma/llm-monitor',
    scripts: const ['llm-monitor.py', 'free-gpu.sh'],
  ),
  _rustApp(
    id: 'wlan',
    name: 'Maprisma WLAN Monitor',
    repo: 'maprisma-wlan-monitor',
    suffix: 'WlanMonitor',
    binary: 'maprisma-wlan-monitor',
    github: 'maprisma/wlan-monitor',
    scripts: const ['wlan-monitor.py'],
    data: const [DataPath('{config}/ubruckhaus-wlan-monitor', sharedWithOmarchy: true)],
  ),

  // --- narrator ----------------------------------------------------------------------------
  const AppEntry(
    id: 'narrator',
    name: 'Maprisma Narrator',
    kind: 'rust + flutter',
    inputs: [Input('maprisma-narrator', github: 'maprisma/narrator')],
    components: [
      Component(
        id: 'main',
        name: 'Maprisma Narrator',
        repo: 'maprisma-narrator',
        install: ['./install.sh'],
        flutter: FlutterEnv.executable,
        optionalParts: {'settings window'},
        prerequisites: [
          Prerequisite('cargo', note: 'without it, prebuilt binaries in target/release are installed'),
          Prerequisite('python3'),
          Prerequisite('flutter', part: 'settings window'),
          Prerequisite('cmake', part: 'settings window'),
          Prerequisite('ninja', part: 'settings window'),
        ],
        paths: [
          InstalledPath('{bin}/maprisma-narrator-applet', PathKind.executable, key: true),
          InstalledPath('{bin}/maprisma-narrator-tray', PathKind.executable),
          InstalledPath('{bin}/maprisma-narrator-desktop', PathKind.executable),
          InstalledPath('{data}/maprisma-narrator/backend/bridge.py', PathKind.file),
          InstalledPath('{data}/maprisma-narrator/backend/setup_backend.py', PathKind.file),
          InstalledPath('{apps}/${_c}Narrator.desktop', PathKind.file),
          InstalledPath('{apps}/com.maprisma.Narrator.Desktop.desktop', PathKind.file),
          InstalledPath('{autostart}/com.maprisma.Narrator.Tray.desktop', PathKind.file),
          InstalledPath('{data}/maprisma-narrator/settings/maprisma-narrator', PathKind.executable, part: 'settings window'),
          InstalledPath('{data}/maprisma-narrator/settings/lib/libapp.so', PathKind.file, part: 'settings window'),
          InstalledPath('{bin}/maprisma-narrator', PathKind.link,
              target: '{data}/maprisma-narrator/settings/maprisma-narrator', part: 'settings window'),
          InstalledPath('{apps}/com.maprisma.Narrator.desktop', PathKind.file, part: 'settings window'),
        ],
      ),
    ],
    data: [
      DataPath('{homeShare}/kindle-reader', sharedWithOmarchy: true, note: 'the reader runtime (venv, models)'),
      // setup_backend.py and bridge.py hardcode ~/.config (no XDG_CONFIG_HOME).
      DataPath('{home}/.config/kindle-reader', sharedWithOmarchy: true),
    ],
    runtime: [
      RuntimePath('{home}/.config/systemd/user/ocrvox.service', marker: '# Managed by ubruckhaus.simple-reader', note: 'written by "Set up automatically"'),
      RuntimePath('{home}/.config/systemd/user/ocrvox.service.d/read-aloud-runtime.conf', marker: '# Managed by ubruckhaus.simple-reader', note: 'drop-in; other drop-ins are not ours'),
      RuntimePath('{bin}/simple-reader', marker: '# Managed by ubruckhaus.simple-reader', note: 'a prior one is backed up'),
      RuntimePath('{homeShare}/applications/simple-reader.desktop', note: 'written by backend setup'),
    ],
    units: [
      UnitRef('ocrvox.service', runtime: true, file: '{home}/.config/systemd/user/ocrvox.service', note: 'the reader (kindle-reader/app/reader.py)'),
    ],
    processes: [
      ProcessMatch(MatchKind.exe, '{bin}/maprisma-narrator-applet'),
      ProcessMatch(MatchKind.exe, '{bin}/maprisma-narrator-tray'),
      ProcessMatch(MatchKind.exe, '{bin}/maprisma-narrator-desktop'),
      ProcessMatch(MatchKind.exeUnder, '{data}/maprisma-narrator/settings'),
      ProcessMatch(MatchKind.scriptUnder, '{data}/maprisma-narrator/backend'),
    ],
    bar: BarIcon(
      cosmicApplet: '${_c}Narrator',
      cosmicAppletExe: '{bin}/maprisma-narrator-applet',
      kdeId: 'com.maprisma.Narrator.Tray',
      kdeAutostart: '{autostart}/com.maprisma.Narrator.Tray.desktop',
      kdeTrayExe: '{bin}/maprisma-narrator-tray',
      iconName: 'audio-headphones',
    ),
    removal: Support.unsupportedYet,
    supportNote: 'removing the reader runtime (ocrvox, simple-reader) needs its own step (step 5)',
  ),

  // --- video translator --------------------------------------------------------------------
  const AppEntry(
    id: 'video',
    name: 'Maprisma Video Translator',
    kind: 'rust + flutter',
    inputs: [Input('maprisma-video-translator')],
    components: [
      Component(
        id: 'main',
        name: 'Maprisma Video Translator',
        repo: 'maprisma-video-translator',
        install: ['./install.sh'],
        flutter: FlutterEnv.executable,
        optionalParts: {'window'},
        prerequisites: [
          Prerequisite('cargo', note: 'without it, prebuilt binaries in target/release are installed'),
          Prerequisite('python3'),
          Prerequisite('flutter', part: 'window'),
          Prerequisite('cmake', part: 'window'),
          Prerequisite('ninja', part: 'window'),
        ],
        paths: [
          InstalledPath('{bin}/maprisma-video-translator-applet', PathKind.executable, key: true),
          InstalledPath('{bin}/maprisma-video-translator-tray', PathKind.executable),
          InstalledPath('{bin}/maprisma-video-translator-captions', PathKind.executable),
          InstalledPath('{data}/maprisma-video-translator/backend/bridge.sh', PathKind.file),
          InstalledPath('{data}/maprisma-video-translator/backend/bridge.py', PathKind.file),
          InstalledPath('{data}/maprisma-video-translator/backend/backend.py', PathKind.file),
          InstalledPath('{apps}/${_c}VideoTranslator.desktop', PathKind.file),
          InstalledPath('{autostart}/com.maprisma.VideoTranslator.Tray.desktop', PathKind.file),
          InstalledPath('{data}/maprisma-video-translator/app/maprisma-video-translator', PathKind.executable, part: 'window'),
          InstalledPath('{data}/maprisma-video-translator/app/lib/libapp.so', PathKind.file, part: 'window'),
          InstalledPath('{bin}/maprisma-video-translator', PathKind.link,
              target: '{data}/maprisma-video-translator/app/maprisma-video-translator', part: 'window'),
          InstalledPath('{apps}/com.maprisma.VideoTranslator.desktop', PathKind.file, part: 'window'),
        ],
      ),
    ],
    data: [
      DataPath('{config}/video-trans', sharedWithOmarchy: true),
      DataPath('{data}/video-trans', sharedWithOmarchy: true, note: 'the private runtime'),
    ],
    runtime: [
      RuntimePath('{bin}/video-trans', marker: '# Managed by ubruckhaus.video-trans', note: '"Set up now"; refreshed by install.sh when managed'),
      RuntimePath('{apps}/video-trans.desktop', marker: 'X-Video-Trans-Managed=true', note: '"Set up now"'),
    ],
    processes: [
      ProcessMatch(MatchKind.exe, '{bin}/maprisma-video-translator-applet'),
      ProcessMatch(MatchKind.exe, '{bin}/maprisma-video-translator-tray'),
      ProcessMatch(MatchKind.exe, '{bin}/maprisma-video-translator-captions', note: 'holds a lock file'),
      ProcessMatch(MatchKind.exeUnder, '{data}/maprisma-video-translator/app'),
      ProcessMatch(MatchKind.scriptUnder, '{data}/maprisma-video-translator/backend', note: 'bridge.py, backend.py, gui.py'),
    ],
    bar: BarIcon(
      cosmicApplet: '${_c}VideoTranslator',
      cosmicAppletExe: '{bin}/maprisma-video-translator-applet',
      kdeId: 'maprisma-video-translator',
      kdeAutostart: '{autostart}/com.maprisma.VideoTranslator.Tray.desktop',
      kdeTrayExe: '{bin}/maprisma-video-translator-tray',
      iconName: 'media-view-subtitles-symbolic',
    ),
    removal: Support.unsupportedYet,
    supportNote: 'its Flutter bundle and backend need whole-tree ownership in the receipt first (step 5)',
  ),

  // --- KDE: tiling and the icons widget ----------------------------------------------------
  const AppEntry(
    id: 'tiling',
    name: 'Maprisma Tiling (KDE)',
    kind: 'KWin scripts',
    desktops: _kde,
    inputs: [Input('maprisma-kwin-scripts')],
    components: [
      Component(
        id: 'main',
        name: 'Maprisma Tiling',
        repo: 'maprisma-kwin-scripts',
        install: ['./install.sh'],
        desktops: _kde,
        prerequisites: [
          Prerequisite('kpackagetool6'),
          Prerequisite('kreadconfig6'),
          Prerequisite('kwriteconfig6'),
          Prerequisite('qdbus6', note: 'needs a running KWin'),
          Prerequisite('busctl'),
          Prerequisite('python3'),
        ],
        note: 'Replaces Krohnkite and maprisma-active-frame (settings moved, Krohnkite backed up and removed).',
        paths: [
          InstalledPath('{data}/kwin/scripts/maprisma-tiling/metadata.json', PathKind.file, key: true),
          InstalledPath('{data}/kwin/scripts/maprisma-tiling/contents/ui/tiling.qml', PathKind.file, note: 'tiling.qml.in with the engine inside'),
          InstalledPath('{data}/kwin/scripts/omarchy-navigation/metadata.json', PathKind.file, note: 'may exist before (not necessarily ours)'),
          InstalledPath('{bin}/maprisma-tiling-overlay', PathKind.executable),
          InstalledPath('{bin}/maprisma-tiling-shortcuts', PathKind.executable),
          InstalledPath('{data}/dbus-1/services/org.maprisma.TilingOverlay.service', PathKind.file),
        ],
      ),
    ],
    data: [
      DataPath('{data}/maprisma-tiling', note: 'kwinrc and Krohnkite backups'),
      DataPath('{state}/maprisma-tiling', note: 'shortcuts-backup.json for maprisma-tiling-shortcuts --restore'),
    ],
    runtime: [
      RuntimePath('{config}/kwinrc', note: '[Script-maprisma-tiling] keys (build = its hash), [Plugins] …Enabled'),
    ],
    processes: [ProcessMatch(MatchKind.script, '{bin}/maprisma-tiling-overlay', note: 'python, D-Bus activated')],
    installation: Support.unsupportedYet,
    removal: Support.unsupportedYet,
    supportNote: 'the Krohnkite migration needs its own install and remove steps (step 5)',
    note: 'No bar icon; its settings are in Maprisma Theme.',
  ),
  const AppEntry(
    id: 'icons',
    name: 'Maprisma Icons (KDE)',
    kind: 'Plasma widget',
    desktops: _kde,
    inputs: [Input('maprisma-panel')],
    components: [
      Component(
        id: 'main',
        name: 'Maprisma Icons',
        repo: 'maprisma-panel',
        install: ['./install.sh'],
        desktops: _kde,
        prerequisites: [Prerequisite('kpackagetool6'), Prerequisite('python3')],
        paths: [
          InstalledPath('{data}/plasma/plasmoids/com.maprisma.panel/metadata.json', PathKind.file, key: true),
          InstalledPath('{data}/plasma/plasmoids/com.maprisma.panel/contents/ui/main.qml', PathKind.file),
          InstalledPath('{bin}/maprisma-panel-color', PathKind.executable),
        ],
      ),
    ],
    runtime: [
      RuntimePath('{data}/plasma/desktoptheme/maprisma-panel-*', glob: true, note: 'generated Plasma themes (maprisma-panel-color)'),
      RuntimePath('{cache}/maprisma-panel', note: 'colour cache'),
      RuntimePath('{config}/plasmarc', note: '[Theme] name while a generated theme is active'),
    ],
    processes: [ProcessMatch(MatchKind.script, '{bin}/maprisma-panel-color')],
    removal: Support.unsupportedYet,
    supportNote: 'removing the widget must switch away from its generated Plasma themes first (step 5)',
    note: 'It is the bar for the others on KDE.',
  ),

  // --- the Manager itself ------------------------------------------------------------------
  const AppEntry(
    id: 'manager',
    name: 'Maprisma Manager',
    kind: 'flutter',
    inputs: [Input('maprisma-manager')],
    components: [
      Component(
        id: 'main',
        name: 'Maprisma Manager',
        repo: 'maprisma-manager',
        install: ['tools/install-local'],
        flutter: FlutterEnv.path,
        prerequisites: [Prerequisite('flutter'), Prerequisite('dart')],
        note: 'tools/install-local comes in step 6.',
        paths: [
          InstalledPath('{lib}/maprisma-manager/maprisma-manager', PathKind.executable, key: true),
          InstalledPath('{bin}/maprisma-manager', PathKind.link, target: '{lib}/maprisma-manager/maprisma-manager'),
          InstalledPath('{apps}/com.maprisma.Manager.desktop', PathKind.file),
        ],
      ),
    ],
    data: [DataPath('{config}/maprisma-manager'), DataPath('{state}/maprisma-manager')],
    processes: [ProcessMatch(MatchKind.exeUnder, '{lib}/maprisma-manager')],
    installation: Support.unsupportedYet,
    removal: Support.unsupportedYet,
    supportNote: 'the Manager updates itself through its own helper (step 6)',
    note: 'Opens from the app menu.',
  ),
];

/// Tests only: another catalog (e.g. the built-in one plus a fake app).
List<AppEntry>? catalogOverride;

List<AppEntry> get catalog => catalogOverride ?? builtinCatalog;

AppEntry? findApp(String id) {
  for (final a in catalog) {
    if (a.id == id) return a;
  }
  return null;
}

/// Every repo folder the catalog uses (for finding the projects folder).
Set<String> get catalogRepos => {for (final a in catalog) for (final i in a.inputs) i.repo};
