/// The 16 apps the Manager knows, as data. Every path was read from the repo's own install
/// script (2026-11-09); docs/inventory.md is the human version of this file.
///
/// Templates: `{bin}` = $HOME/.local/bin, `{lib}` = $HOME/.local/lib, `{data}` = XDG_DATA_HOME,
/// `{homeShare}` = $HOME/.local/share (scripts that hardcode it), `{apps}`, `{icons}`
/// (hicolor/scalable/apps), `{autostart}`, `{units}` (systemd user), `{config}`, `{state}`,
/// `{cache}`; absolute paths are system paths.
library;

import 'catalog_model.dart';
import 'paths.dart' show selfAppId, legacySelfAppId;

export 'catalog_model.dart';

const _cosmic = {DesktopId.cosmic};
const _kde = {DesktopId.kde};
const _hyprland = {DesktopId.hyprland};
const _c = 'io.github.ubruckhaus.CosmicMaprisma';

const _gtkIconCache = Prerequisite('gtk-update-icon-cache', optional: true);
const _desktopDb = Prerequisite('update-desktop-database', optional: true);

const _readerStays = 'made by the reader\'s setup, shared with Omarchy\'s reader (kindle-reader): not removed with the app';
const _videoTransStays = 'made by "Set up now", shared with Omarchy\'s video-trans: not removed with the app';

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
  String? iconNote,
  bool cosmicIconBuiltIn = false,
  Set<DesktopId> desktops = const {DesktopId.cosmic, DesktopId.kde, DesktopId.hyprland, DesktopId.other},
  List<ProcessMatch> moreProcesses = const [],
}) {
  final appId = '$_c$suffix';
  return AppEntry(
    id: id,
    name: name,
    kind: 'rust',
    desktops: desktops,
    open: ['{bin}/$binary', '--window'],
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
      ...moreProcesses,
    ],
    bar: BarIcon(
      cosmicApplet: appId,
      cosmicAppletExe: '{bin}/$binary',
      kdeId: binary,
      kdeAutostart: '{autostart}/$appId.Tray.desktop',
      kdeTrayExe: '{bin}/$binary-tray',
      iconName: '$appId-symbolic',
      iconNote: iconNote,
      cosmicIconBuiltIn: cosmicIconBuiltIn,
    ),
    postSteps: const ['gtk-update-icon-cache'],
  );
}

/// The built-in catalog; [catalog] is what everything uses (tests may set [catalogOverride]).
final List<AppEntry> builtinCatalog = [
  // --- maprisma: the pacman package -------------------------------------------------------
  const AppEntry(
    id: 'maprisma',
    open: ['/usr/bin/maprisma'],
    appIcon: 'com.maprisma.Maprisma',
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
    barVia: 'control',
    version: VersionSource(pacman: 'maprisma-bin', folderFile: 'addons.py', folderPattern: r'^MAPRISMA_VERSION = "([0-9.]+)"'),
    postSteps: ['systemctl --user restart maprisma-providers.service'],
    release: ReleaseSpec(
      tarball: 'maprisma-{version}-x86_64.tar.gz',
      component: 'package',
      note: 'installed as the pacman package maprisma-bin from a recipe for the tarball',
    ),
    supportNote: 'installed as the pacman package maprisma-bin (pkexec asks for the password); the newer of the release and a folder build by default',
    note: 'Maprisma Control is its bar icon.',
  ),

  // --- control: maprisma-applet ------------------------------------------------------------
  const AppEntry(
    id: 'control',
    appIcon: 'com.maprisma.Maprisma',
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
          InstalledPath('{icons}/$_c-symbolic.svg', PathKind.file, note: 'the bar icon (Maprisma\'s logo)'),
          InstalledPath('{apps}/$_c.desktop', PathKind.file),
          InstalledPath('{autostart}/com.maprisma.Control.Tray.desktop', PathKind.file, note: 'OnlyShowIn=KDE'),
        ],
      ),
    ],
    postSteps: ['gtk-update-icon-cache'],
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
      iconName: '$_c-symbolic',
      iconNote: 'Maprisma\'s coloured logo: the applet draws the icon in its own colours (a symbolic icon shows dark grey)',
    ),
  ),

  // --- launcher: maprisma-launcher + its COSMIC applet -------------------------------------
  const AppEntry(
    id: 'launcher',
    open: ['{bin}/maprisma-launcher'],
    appIcon: 'com.maprisma.Launcher',
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
        trees: [TreeRoot('{lib}/maprisma-launcher', swap: true, note: 'the Flutter bundle, swapped in atomically')],
        // install-local refuses while the app's terminal runs a command; --force ends it (only when asked)
        flags: {'force': '--force'},
        busyMarker: 'is running a command in its terminal',
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
  ),

  // --- theme: maprisma-theme ---------------------------------------------------------------
  const AppEntry(
    id: 'theme',
    open: ['{bin}/maprisma-theme'],
    appIcon: 'com.maprisma.Theme',
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
        trees: [TreeRoot('{lib}/maprisma-theme', swap: true, note: 'the Flutter bundle with bin/ and share/, swapped in atomically')],
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
  ),

  // --- playground: maprisma-playground -----------------------------------------------------
  const AppEntry(
    id: 'playground',
    open: ['{bin}/maprisma-playground'],
    appIcon: 'com.maprisma.Playground',
    name: 'Maprisma Playground',
    kind: 'flutter + rust',
    inputs: [Input('maprisma-playground', github: 'maprisma/playground')],
    components: [
      Component(
        id: 'main',
        name: 'Maprisma Playground',
        repo: 'maprisma-playground',
        install: ['tools/install-local'],
        flutter: FlutterEnv.dir,
        stopsOwnProcesses: true,
        trees: [TreeRoot('{lib}/maprisma-playground', swap: true, note: 'the Flutter bundle with bin/ (core, applet, tray), swapped in atomically')],
        prerequisites: [Prerequisite('flutter'), Prerequisite('dart'), Prerequisite('cargo'), _gtkIconCache, _desktopDb],
        note: 'FLUTTER is the folder with flutter in it; on KDE the script starts the tray itself.',
        paths: [
          InstalledPath('{lib}/maprisma-playground/maprisma-playground', PathKind.executable, key: true),
          InstalledPath('{lib}/maprisma-playground/bin/maprisma-playground-core', PathKind.executable),
          InstalledPath('{lib}/maprisma-playground/bin/maprisma-playground-applet', PathKind.executable),
          InstalledPath('{lib}/maprisma-playground/bin/maprisma-playground-tray', PathKind.executable),
          InstalledPath('{lib}/maprisma-playground/lib/libapp.so', PathKind.file),
          InstalledPath('{bin}/maprisma-playground', PathKind.link, target: '{lib}/maprisma-playground/maprisma-playground'),
          InstalledPath('{bin}/maprisma-playground-core', PathKind.link, target: '{lib}/maprisma-playground/bin/maprisma-playground-core'),
          InstalledPath('{bin}/maprisma-playground-applet', PathKind.link, target: '{lib}/maprisma-playground/bin/maprisma-playground-applet'),
          InstalledPath('{bin}/maprisma-playground-tray', PathKind.link, target: '{lib}/maprisma-playground/bin/maprisma-playground-tray'),
          InstalledPath('{apps}/com.maprisma.Playground.desktop', PathKind.file),
          InstalledPath('{apps}/com.maprisma.Playground.Toggle.desktop', PathKind.file),
          InstalledPath('{apps}/${_c}Playground.desktop', PathKind.file),
          InstalledPath('{icons}/com.maprisma.Playground.svg', PathKind.file),
          InstalledPath('{icons}/${_c}Playground-symbolic.svg', PathKind.file),
          InstalledPath('{autostart}/com.maprisma.Playground.Tray.desktop', PathKind.file, note: 'the KDE tray'),
        ],
      ),
    ],
    data: [
      DataPath('{config}/maprisma-playground', note: 'settings, saved chess games, Head to head scores'),
      DataPath('{data}/maprisma-playground', note: 'Generate: stable-diffusion.cpp and the Z-Image-Turbo model (about 11 GB)'),
      DataPath('{cache}/maprisma-playground'),
    ],
    runtime: [
      RuntimePath('{config}/llama.cpp/models.ini', note: 'Analyze may add a vision projector entry here', stays: 'shared with the local LLM (llama.cpp): not removed with the app'),
    ],
    processes: [ProcessMatch(MatchKind.exeUnder, '{lib}/maprisma-playground', note: 'app, core, applet, tray')],
    bar: BarIcon(
      cosmicApplet: '${_c}Playground',
      cosmicAppletExe: '{bin}/maprisma-playground-applet',
      kdeId: 'maprisma-playground',
      kdeAutostart: '{autostart}/com.maprisma.Playground.Tray.desktop',
      kdeTrayExe: '{lib}/maprisma-playground/bin/maprisma-playground-tray',
      iconName: '${_c}Playground-symbolic',
    ),
    version: VersionSource(
      installedJson: '{lib}/maprisma-playground/data/flutter_assets/version.json',
      folderFile: 'flutter_app/pubspec.yaml',
      folderPattern: r'^version: *([0-9.]+)',
    ),
    postSteps: ['gtk-update-icon-cache', 'update-desktop-database'],
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
    iconNote: 'the COSMIC panel shows the kind of the connected device (status icons, kept); this icon shows in the popup, the KDE tray and the menus',
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
    iconNote: 'the COSMIC applet draws its built-in bulb (lit or dim by state, kept): a changed icon shows in the KDE tray and the menus',
    cosmicIconBuiltIn: true,
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
    iconNote: 'the COSMIC applet draws a built-in copy of its radar (with the signal colours): a changed icon shows in the KDE tray and the menus',
    cosmicIconBuiltIn: true,
  ),

  // The notification centre (history, unread count, do not disturb); the desktops keep showing
  // the popups (docs/plan.md of maprisma-notifier). Its settings page is the Manager's
  // Notifications page (notifications.dart).
  _rustApp(
    id: 'notifier',
    name: 'Maprisma Notifier',
    repo: 'maprisma-notifier',
    suffix: 'Notifier',
    binary: 'maprisma-notifier',
    github: 'maprisma/notifier',
    scripts: const [],
    desktops: const {DesktopId.cosmic, DesktopId.kde, DesktopId.hyprland},
    data: const [
      DataPath('{config}/maprisma-notifier', note: 'settings.json'),
      DataPath('{state}/maprisma-notifier', note: 'history.jsonl: the recorded notifications'),
    ],
    // The recorder runs inside the tray (KDE, Hyprland) or the applet (COSMIC), or on its own.
    moreProcesses: const [ProcessMatch(MatchKind.exe, '{bin}/maprisma-notifier-recorder', note: 'the recorder, when it runs on its own')],
  ),

  // The voice service for every Maprisma app (speech to text on the session bus) and the
  // dictation overlay; its settings are the Manager's Voice page (voice.dart). The bar icon
  // toggles the overlay (`maprisma-dictation --toggle`): a COSMIC applet and, like the Notifier,
  // an SNI tray on KDE and Hyprland.
  const AppEntry(
    id: 'dictation',
    name: 'Maprisma Dictation',
    kind: 'rust',
    appIcon: 'com.maprisma.Dictation',
    open: ['{bin}/maprisma-dictation', '--toggle'],
    desktops: {DesktopId.cosmic, DesktopId.kde, DesktopId.hyprland},
    inputs: [Input('maprisma-dictation', github: 'maprisma/dictation')],
    components: [
      Component(
        id: 'main',
        name: 'Maprisma Dictation',
        repo: 'maprisma-dictation',
        install: ['./install.sh'],
        prerequisites: [Prerequisite('cargo'), Prerequisite('pw-record', optional: true, note: 'the recorder; parecord or arecord work too'), _gtkIconCache],
        note: 'The local engine (whisper.cpp\'s whisper-server) is built separately, see its README.',
        paths: [
          InstalledPath('{bin}/maprisma-voice', PathKind.executable, key: true),
          InstalledPath('{units}/maprisma-voice.service', PathKind.file),
          InstalledPath('{data}/dbus-1/services/com.maprisma.Voice1.service', PathKind.file, note: 'D-Bus activation'),
          InstalledPath('{bin}/maprisma-dictation', PathKind.executable, note: 'the overlay'),
          InstalledPath('{apps}/com.maprisma.Dictation.desktop', PathKind.file),
          InstalledPath('{icons}/com.maprisma.Dictation.svg', PathKind.file),
          InstalledPath('{icons}/com.maprisma.Dictation-symbolic.svg', PathKind.file),
          InstalledPath('{bin}/maprisma-dictation-applet', PathKind.executable, note: 'the COSMIC panel applet'),
          InstalledPath('{bin}/maprisma-dictation-tray', PathKind.executable, note: 'the tray (KDE, Hyprland)'),
          InstalledPath('{apps}/${_c}Dictation.desktop', PathKind.file),
          InstalledPath('{autostart}/${_c}Dictation.Tray.desktop', PathKind.file, note: 'OnlyShowIn=KDE;Hyprland'),
          InstalledPath('{icons}/${_c}Dictation-symbolic.svg', PathKind.file),
          InstalledPath('{icons}/${_c}Dictation-open-symbolic.svg', PathKind.file),
          InstalledPath('{icons}/${_c}Dictation-listening-symbolic.svg', PathKind.file),
          InstalledPath('{icons}/${_c}Dictation-speaking-symbolic.svg', PathKind.file),
        ],
      ),
    ],
    data: [
      DataPath('{config}/maprisma-voice', note: 'settings.json'),
      DataPath('{data}/maprisma-voice', note: 'models/ (downloaded Whisper models) and whisper.cpp/ (the local engine, built by hand)'),
      DataPath('{config}/maprisma-dictation', note: 'settings.json of the overlay'),
      DataPath('{state}/maprisma-dictation', note: 'actions.jsonl: the overlay\'s action log'),
    ],
    units: [UnitRef('maprisma-voice.service', note: 'started through D-Bus activation')],
    processes: [
      ProcessMatch(MatchKind.exe, '{bin}/maprisma-voice', note: 'the daemon (and whisper-server as its child)'),
      ProcessMatch(MatchKind.exe, '{bin}/maprisma-dictation', note: 'the overlay, while it is open'),
      ProcessMatch(MatchKind.exe, '{bin}/maprisma-dictation-applet'),
      ProcessMatch(MatchKind.exe, '{bin}/maprisma-dictation-tray'),
    ],
    bar: BarIcon(
      cosmicApplet: '${_c}Dictation',
      cosmicAppletExe: '{bin}/maprisma-dictation-applet',
      kdeId: 'maprisma-dictation',
      kdeAutostart: '{autostart}/${_c}Dictation.Tray.desktop',
      kdeTrayExe: '{bin}/maprisma-dictation-tray',
      iconName: '${_c}Dictation-symbolic',
      iconNote: 'shows the state with its own variants (-open, -listening, -speaking): a changed icon replaces only the idle one',
    ),
    postSteps: ['gtk-update-icon-cache'],
    note: 'Its settings are on the Voice page; the bar icon opens and closes the dictation overlay.',
  ),

  // --- narrator ----------------------------------------------------------------------------
  const AppEntry(
    id: 'narrator',
    open: ['{bin}/maprisma-narrator'],
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
        trees: [
          TreeRoot('{data}/maprisma-narrator/backend', staged: true, note: 'copied to backend.new, then renamed'),
          TreeRoot('{data}/maprisma-narrator/settings', part: 'settings window', note: 'the Flutter bundle'),
        ],
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
          InstalledPath('{icons}/${_c}Narrator-symbolic.svg', PathKind.file, note: 'the bar icon'),
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
      RuntimePath('{home}/.config/systemd/user/ocrvox.service', marker: '# Managed by ubruckhaus.simple-reader', note: 'written by "Set up automatically"', stays: _readerStays),
      RuntimePath('{home}/.config/systemd/user/ocrvox.service.d/read-aloud-runtime.conf', marker: '# Managed by ubruckhaus.simple-reader', note: 'drop-in; other drop-ins are not ours', stays: _readerStays),
      RuntimePath('{bin}/simple-reader', marker: '# Managed by ubruckhaus.simple-reader', note: 'a prior one is backed up', stays: _readerStays),
      RuntimePath('{homeShare}/applications/simple-reader.desktop', note: 'written by backend setup', stays: _readerStays),
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
      iconName: '${_c}Narrator-symbolic',
      iconNote: 'the KDE tray shows it while the reader is idle (playing and paused keep their own icons)',
    ),
    postSteps: ['gtk-update-icon-cache'],
    supportNote: 'the reader runtime (ocrvox.service, simple-reader, kindle-reader) stays on remove: it is shared with Omarchy\'s reader',
  ),

  // --- video translator --------------------------------------------------------------------
  const AppEntry(
    id: 'video',
    open: ['{bin}/maprisma-video-translator'],
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
        trees: [
          TreeRoot('{data}/maprisma-video-translator/backend', staged: true, note: 'copied to backend.new, then renamed'),
          TreeRoot('{data}/maprisma-video-translator/app', part: 'window', note: 'the Flutter bundle'),
        ],
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
          InstalledPath('{icons}/${_c}VideoTranslator-symbolic.svg', PathKind.file, note: 'the bar icon'),
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
      RuntimePath('{bin}/video-trans', marker: '# Managed by ubruckhaus.video-trans', note: '"Set up now"; refreshed by install.sh when managed', stays: _videoTransStays),
      RuntimePath('{apps}/video-trans.desktop', marker: 'X-Video-Trans-Managed=true', note: '"Set up now"', stays: _videoTransStays),
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
      iconName: '${_c}VideoTranslator-symbolic',
    ),
    postSteps: ['gtk-update-icon-cache'],
    supportNote: 'the video-trans command and its desktop entry ("Set up now") stay on remove: shared with Omarchy\'s video-trans',
  ),

  // --- KDE: tiling and the icons widget ----------------------------------------------------
  const AppEntry(
    id: 'tiling',
    name: 'Maprisma Tiling (KDE)',
    kind: 'KWin scripts',
    desktops: _kde,
    inputs: [Input('maprisma-kwin-scripts', github: 'maprisma/maprisma-kwin-scripts')],
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
        trees: [
          TreeRoot('{data}/kwin/scripts/maprisma-tiling', wholeOnly: true, note: 'kpackagetool6 package'),
          TreeRoot('{data}/kwin/scripts/omarchy-navigation', mayPreexist: true, wholeOnly: true, note: 'kpackagetool6 package; may be there before'),
        ],
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
      DataPath('{data}/maprisma-tiling', keep: true, note: 'kwinrc and Krohnkite backups (never deleted)'),
      DataPath('{state}/maprisma-tiling', note: 'shortcuts-backup.json for maprisma-tiling-shortcuts --restore'),
    ],
    runtime: [
      RuntimePath('{config}/kwinrc', note: '[Script-maprisma-tiling] keys (build = its hash), [Plugins] …Enabled'),
    ],
    processes: [ProcessMatch(MatchKind.script, '{bin}/maprisma-tiling-overlay', note: 'python, D-Bus activated')],
    removeRecipe: RemoveRecipe.kwinTiling,
    supportNote: 'remove restores the shortcuts, unloads the scripts and deletes only its own kwinrc keys; the Krohnkite backup stays',
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
        trees: [TreeRoot('{data}/plasma/plasmoids/com.maprisma.panel', wholeOnly: true, note: 'kpackagetool6 package')],
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
    removeRecipe: RemoveRecipe.plasmaIcons,
    supportNote: 'remove takes its widgets out of the panels and switches away from its generated Plasma style first',
    note: 'It is the bar for the others on KDE.',
  ),

  // --- Hyprland: Maprisma Shell ------------------------------------------------------------
  const AppEntry(
    id: 'shell',
    name: 'Maprisma Shell (Hyprland)',
    kind: 'Quickshell config',
    desktops: _hyprland,
    inputs: [Input('maprisma-shell', github: 'maprisma/shell')],
    components: [
      Component(
        id: 'main',
        name: 'Maprisma Shell',
        repo: 'maprisma-shell',
        install: ['./install.sh'],
        desktops: _hyprland,
        stopsOwnProcesses: true,
        prerequisites: [
          Prerequisite('qs'),
          Prerequisite('qml6', note: 'runs the layout tests before installing'),
          Prerequisite('grim', note: 'screenshots'),
          Prerequisite('slurp', note: 'region screenshots and recordings'),
          Prerequisite('fuzzel', note: 'app launcher, clipboard and emoji pickers'),
          Prerequisite('gpu-screen-recorder', optional: true, note: 'screen recording'),
        ],
        note: 'install.sh runs the tests, copies the config to <dest>.new, swaps it in, installs the helper '
            'commands and restarts the shell. Hyprland starts it (`qs -c maprisma-shell -n -d` in execs.lua).',
        trees: [TreeRoot('{config}/quickshell/maprisma-shell', staged: true, note: 'the Quickshell config, copied to maprisma-shell.new, then renamed')],
        paths: [
          InstalledPath('{config}/quickshell/maprisma-shell/shell.qml', PathKind.file, key: true),
          InstalledPath('{config}/quickshell/maprisma-shell/Bar.qml', PathKind.file),
          InstalledPath('{config}/quickshell/maprisma-shell/Slot.qml', PathKind.file),
          InstalledPath('{config}/quickshell/maprisma-shell/BarModel.js', PathKind.file),
          InstalledPath('{config}/quickshell/maprisma-shell/services/Settings.qml', PathKind.file),
          InstalledPath('{config}/quickshell/maprisma-shell/modules/Lock.qml', PathKind.file),
          InstalledPath('{config}/quickshell/maprisma-shell/modules/Notifications.qml', PathKind.file),
          InstalledPath('{config}/quickshell/maprisma-shell/assets/pam.d/passwd', PathKind.file, note: 'the lock screen\'s PAM stack'),
          InstalledPath('{bin}/maprisma-screenshot', PathKind.executable),
          InstalledPath('{bin}/maprisma-record', PathKind.executable),
          InstalledPath('{bin}/maprisma-clipboard', PathKind.executable),
          InstalledPath('{bin}/maprisma-emoji', PathKind.executable),
        ],
      ),
    ],
    data: [
      DataPath('{config}/maprisma-shell', note: 'bar.json (layout, hidden icons, background; the Manager writes it too) and shell.json (idle, wallpaper)'),
      DataPath('{state}/maprisma-shell', note: 'scheme.json: the colours Maprisma Theme writes'),
    ],
    processes: [ProcessMatch(MatchKind.quickshellConfig, '{config}/quickshell/maprisma-shell', note: 'qs -c maprisma-shell')],
    supportNote: 'the shell of the Hyprland session (bar, wallpaper, notifications, lock, idle); the Maprisma icons are placed in its bar from the Bar page',
    note: 'Its bar is the bar for the others on Hyprland.',
  ),

  // --- the app itself (Maprisma Settings, formerly Maprisma Manager) ------------------------
  // The old names stay working: id `manager` ([legacySelfAppId], [findApp]), the repo folder
  // maprisma-manager ([repoFolderAliases]), the programs maprisma-manager{,-core,-applet,-tray}
  // (links), the hidden com.maprisma.Manager entry and the folders of the old name (links,
  // [migrateLegacyFolders]). The bar icon keeps its ids (COSMIC applet, tray item `maprisma-manager`,
  // icon name): the panels and Maprisma Shell's bar.json name it by them.
  const AppEntry(
    id: selfApp,
    name: 'Maprisma Settings',
    kind: 'flutter',
    inputs: [Input('maprisma-manager')],
    appIcon: 'com.maprisma.Settings',
    components: [
      Component(
        id: 'main',
        name: 'Maprisma Settings',
        repo: 'maprisma-manager',
        install: ['tools/install-local'],
        flutter: FlutterEnv.path,
        stopsOwnProcesses: true,
        optionalParts: {'bar icon'},
        prerequisites: [Prerequisite('flutter'), Prerequisite('dart'), Prerequisite('bash'), Prerequisite('setsid')],
        trees: [TreeRoot('{lib}/maprisma-settings', swap: true, note: 'the Flutter bundle with bin/ (core CLI, COSMIC applet, tray); swapped in by the self-update helper once the app has quit')],
        note: 'Updates itself: tools/install-local --stage builds and checks the new bundle, a helper swaps it in after the app quit and starts it again.',
        paths: [
          InstalledPath('{lib}/maprisma-settings/maprisma-settings', PathKind.executable, key: true),
          InstalledPath('{lib}/maprisma-settings/lib/libapp.so', PathKind.file),
          InstalledPath('{lib}/maprisma-settings/data/flutter_assets/version.json', PathKind.file),
          InstalledPath('{lib}/maprisma-settings/bin/maprisma-settings-core', PathKind.executable, note: 'the core CLI'),
          InstalledPath('{bin}/maprisma-settings', PathKind.link, target: '{lib}/maprisma-settings/maprisma-settings'),
          InstalledPath('{bin}/maprisma-settings-core', PathKind.link, target: '{lib}/maprisma-settings/bin/maprisma-settings-core'),
          // the old names: links in the bundle, and in ~/.local/bin to those
          InstalledPath('{lib}/maprisma-settings/maprisma-manager', PathKind.link, target: '{lib}/maprisma-settings/maprisma-settings', note: 'the old name'),
          InstalledPath('{lib}/maprisma-settings/bin/maprisma-manager-core', PathKind.link, target: '{lib}/maprisma-settings/bin/maprisma-settings-core', note: 'the old name'),
          InstalledPath('{bin}/maprisma-manager', PathKind.link, target: '{lib}/maprisma-settings/maprisma-manager', note: 'the old name'),
          InstalledPath('{bin}/maprisma-manager-core', PathKind.link, target: '{lib}/maprisma-settings/bin/maprisma-manager-core', note: 'the old name'),
          InstalledPath('{apps}/com.maprisma.Settings.desktop', PathKind.file),
          InstalledPath('{apps}/com.maprisma.Manager.desktop', PathKind.file, note: 'the old id: hidden, starts maprisma-settings'),
          InstalledPath('{icons}/com.maprisma.Settings.svg', PathKind.file),
          InstalledPath('{icons}/com.maprisma.Manager.svg', PathKind.file, note: 'the old icon name'),
          // installed also without the bar icon (a no-cargo build): it is the bar icon's picture
          InstalledPath('{icons}/${_c}Manager-symbolic.svg', PathKind.file),
          // The bar icon (bar/: Rust; the build leaves it out without cargo).
          InstalledPath('{lib}/maprisma-settings/bin/maprisma-settings-applet', PathKind.executable, note: 'the COSMIC applet', part: 'bar icon'),
          InstalledPath('{lib}/maprisma-settings/bin/maprisma-settings-tray', PathKind.executable, note: 'the tray (KDE, Maprisma Shell)', part: 'bar icon'),
          InstalledPath('{bin}/maprisma-settings-applet', PathKind.link, target: '{lib}/maprisma-settings/bin/maprisma-settings-applet', part: 'bar icon'),
          InstalledPath('{bin}/maprisma-settings-tray', PathKind.link, target: '{lib}/maprisma-settings/bin/maprisma-settings-tray', part: 'bar icon'),
          InstalledPath('{lib}/maprisma-settings/bin/maprisma-manager-applet', PathKind.link, target: '{lib}/maprisma-settings/bin/maprisma-settings-applet', note: 'the old name', part: 'bar icon'),
          InstalledPath('{lib}/maprisma-settings/bin/maprisma-manager-tray', PathKind.link, target: '{lib}/maprisma-settings/bin/maprisma-settings-tray', note: 'the old name', part: 'bar icon'),
          InstalledPath('{bin}/maprisma-manager-applet', PathKind.link, target: '{lib}/maprisma-settings/bin/maprisma-manager-applet', note: 'the old name', part: 'bar icon'),
          InstalledPath('{bin}/maprisma-manager-tray', PathKind.link, target: '{lib}/maprisma-settings/bin/maprisma-manager-tray', note: 'the old name', part: 'bar icon'),
          InstalledPath('{apps}/${_c}Manager.desktop', PathKind.file, note: 'the COSMIC applet', part: 'bar icon'),

          InstalledPath('{autostart}/com.maprisma.Settings.Tray.desktop', PathKind.file, note: 'the tray', part: 'bar icon'),
        ],
      ),
    ],
    data: [DataPath('{config}/maprisma-settings'), DataPath('{state}/maprisma-settings')],
    processes: [ProcessMatch(MatchKind.exeUnder, '{lib}/maprisma-settings', note: 'app, core, applet, tray')],
    bar: BarIcon(
      cosmicApplet: '${_c}Manager',
      cosmicAppletExe: '{bin}/maprisma-settings-applet',
      kdeId: 'maprisma-manager',
      kdeAutostart: '{autostart}/com.maprisma.Settings.Tray.desktop',
      kdeTrayExe: '{lib}/maprisma-settings/bin/maprisma-settings-tray',
      iconName: '${_c}Manager-symbolic',
    ),
    version: VersionSource(
      installedJson: '{lib}/maprisma-settings/data/flutter_assets/version.json',
      folderFile: 'flutter_app/pubspec.yaml',
      folderPattern: r'^version: *([0-9.]+)',
    ),
    postSteps: ['gtk-update-icon-cache', 'update-desktop-database'],
    removal: Support.terminal,
    supportNote: 'it updates itself (the new build is checked, swapped in once it has quit, and rolled back when it doesn\'t start); '
        'it doesn\'t remove itself: run tools/uninstall-local in its folder from a terminal',
    note: 'Opens from the app menu or its bar icon.',
  ),
];

/// The app's own id (its install and update go through the self-update helper): `settings`; the
/// one of before the rename (`manager`) is accepted by [findApp].
const selfApp = selfAppId;

/// Old ids → the current ones (ids from before a rename: receipts, jobs, the CLI, other apps).
const appIdAliases = {legacySelfAppId: selfAppId};

/// Repo folders under another name: a folder of the catalog's name wins, else the first alias
/// that exists (the user may rename maprisma-manager to maprisma-settings any time).
const repoFolderAliases = {'maprisma-manager': ['maprisma-settings']};

/// Tests only: another catalog (e.g. the built-in one plus a fake app).
List<AppEntry>? catalogOverride;

List<AppEntry> get catalog => catalogOverride ?? builtinCatalog;

AppEntry? findApp(String id) {
  for (final a in catalog) {
    if (a.id == id) return a;
  }
  final now = appIdAliases[id];
  return now == null ? null : findApp(now);
}

/// [id] with an old id replaced by its current one.
String canonicalAppId(String id) => appIdAliases[id] ?? id;

/// Every repo folder the catalog uses (for finding the projects folder).
Set<String> get catalogRepos => {for (final a in catalog) for (final i in a.inputs) i.repo};
