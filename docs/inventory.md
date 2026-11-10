# What each Maprisma app installs (read from the install scripts, 2026-11-09)

`bin` = `~/.local/bin`, `share` = `~/.local/share`, `apps` = `~/.local/share/applications`,
`icons` = `~/.local/share/icons/hicolor/scalable/apps`, `autostart` = `~/.config/autostart`,
`C` = `io.github.ubruckhaus.CosmicMaprisma`. "Data" is user data: kept on remove unless asked.

General:
- No install script writes the COSMIC panel config, kills cosmic-panel or restarts plasmashell.
- No uninstall scripts exist.
- Rust crates are all 0.1.0 without `--version`; Flutter bundles have `data/flutter_assets/version.json`.
- Process names are cut to 15 characters: find processes by `/proc/<pid>/exe`.
- `install -Dm755` replaces a running binary safely; the old build runs until restarted.

## maprisma (pacman `maprisma-bin`)

- **Build:** `tools/build-release.py`: flutter, `dart compile exe`, adapters from
  `../maprisma-addons/dist/adapters-<ver>.zip`. Output: `dist/maprisma-<ver>-x86_64.tar.gz`.
- **Package:** `../aur-maprisma-bin/PKGBUILD` (committed at 0.12.0; the installed 0.13.1-9 was built
  from an uncommitted local copy).
- **Files:**
  - `/usr/lib/maprisma/`, with `/usr/bin/maprisma` linking to it
  - `/usr/share/applications/com.maprisma.Maprisma.desktop`
  - metainfo, the icon `com.maprisma.Maprisma`, and the license
- **Runtime:** `~/.config/systemd/user/maprisma-providers.service` (enabled;
  `…/maprisma-core provider-watch`).
- **Data:** `~/.config/maprisma/`, `~/.cache/maprisma`, `~/.local/state/maprisma`, `share/maprisma`.
- **Version:** `pacman -Q maprisma-bin`.
- **Processes:** `/usr/lib/maprisma/maprisma` and `maprisma-core` (stop the service first).

## control: maprisma-applet (Maprisma Control)

- **Files:**
  - `bin/maprisma-applet`, `bin/maprisma-control-tray`
  - `apps/C.desktop` (Exec quoted full path)
  - `autostart/com.maprisma.Control.Tray.desktop` (OnlyShowIn=KDE)
- **Icon:** `com.maprisma.Maprisma`, from maprisma.
- **Bar:** COSMIC `C`; KDE tray id `maprisma-control`.
- **Git:** no remote.

## bluetooth: maprisma-bluetooth-monitor

- **Files:**
  - `bin/maprisma-bluetooth-monitor`, `bin/maprisma-bluetooth-monitor-tray`
  - `share/maprisma-bluetooth-monitor/scripts/{bluetooth-monitor.py,audio-default.py,bt-device.sh,bt-power.sh,allow-access.sh}`
  - `icons/CBluetoothMonitor-symbolic.svg`
  - `apps/CBluetoothMonitor.desktop`, `apps/CBluetoothMonitor.Window.desktop`
  - `autostart/CBluetoothMonitor.Tray.desktop` (KDE)
- **Data:** `~/.config/maprisma-bluetooth-monitor/`, `~/.config/bluetooth-monitor/` (shared with Omarchy).
- **System file:** `/etc/udev/rules.d/42-logitech-hidpp-uaccess.rules`, written by allow-access via pkexec.
- **Bar:** tray id `maprisma-bluetooth-monitor`.
- **Processes:** `python3 … bluetooth-monitor.py`.
- **Post:** gtk-update-icon-cache.
- **Git:** origin maprisma/bluetooth-monitor.

## home: maprisma-home

- **Files:**
  - `bin/maprisma-home{,-tray}`
  - `share/maprisma-home/scripts/{stove.py,switchbot.py,stove_map.json}`
  - `icons/CHome-symbolic.svg`
  - `apps/CHome{,.Window}.desktop`
  - `autostart/CHome.Tray.desktop`
- **Data:** `~/.config/maprisma-home/config.json` (seeded if missing), `~/.local/state/ubruckhaus.home/`.
- **Bar:** tray id `maprisma-home`.
- **Processes:** `stove.py`, `switchbot.py`.
- **Git:** no remote.

## hue: maprisma-hue-lights

- **Files:**
  - `bin/maprisma-hue-lights{,-tray}`
  - `share/maprisma-hue-lights/scripts/hue-lights.py`
  - `icons/CHueLights-symbolic.svg`
  - `apps/CHueLights{,.Window}.desktop`
  - `autostart/CHueLights.Tray.desktop`
- **Data:** `~/.config/hue-lights/` (shared with Omarchy).
- **Bar:** tray id `maprisma-hue-lights`.
- **Git:** origin maprisma/hue-lights.

## llm: maprisma-llm-monitor

- **Files:**
  - `bin/maprisma-llm-monitor{,-tray}`
  - `share/maprisma-llm-monitor/scripts/{llm-monitor.py,free-gpu.sh}`
  - `icons/CLlmMonitor-symbolic.svg`
  - `apps/CLlmMonitor{,.Window}.desktop`
  - `autostart/CLlmMonitor.Tray.desktop`
- **Data:** none of its own.
- **Bar:** tray id `maprisma-llm-monitor`.
- **Git:** origin maprisma/llm-monitor.

## wlan: maprisma-wlan-monitor

- **Files:**
  - `bin/maprisma-wlan-monitor{,-tray}`
  - `share/maprisma-wlan-monitor/scripts/wlan-monitor.py`
  - `icons/CWlanMonitor-symbolic.svg`
  - `apps/CWlanMonitor{,.Window}.desktop`
  - `autostart/CWlanMonitor.Tray.desktop`
- **Data:** `~/.config/ubruckhaus-wlan-monitor/` (shared with Omarchy).
- **Bar:** tray id `maprisma-wlan-monitor`.
- **Git:** origin maprisma/wlan-monitor.

## narrator: maprisma-narrator

- **Build:** cargo `--offline`; the Flutter settings app with `FLUTTER` (default
  `/mnt/Data/flutter/bin/flutter`), which needs cmake and ninja.
- **Files:**
  - `bin/maprisma-narrator-{tray,applet,desktop}`
  - `share/maprisma-narrator/{backend,settings}/`, with `bin/maprisma-narrator` linking to `settings/maprisma-narrator`
  - `apps/com.maprisma.Narrator.desktop`, `apps/com.maprisma.Narrator.Desktop.desktop`, `apps/CNarrator.desktop`
  - `autostart/com.maprisma.Narrator.Tray.desktop`
- **Runtime:** `~/.config/systemd/user/ocrvox.service{,.d}`.
- **Data:** `share/kindle-reader/`, `~/.config/kindle-reader/` (shared with Omarchy).
- **Bar:** tray id `com.maprisma.Narrator.Tray`.
- **Processes:** `maprisma-narrator-desktop`, the Flutter `maprisma-narrator`, ocrvox.
- **Git:** origin maprisma/narrator.

## video: maprisma-video-translator

- **Files:**
  - `bin/maprisma-video-translator-{applet,tray,captions}`
  - `share/maprisma-video-translator/{backend,app}/`, with `bin/maprisma-video-translator` linking to `app/…`
  - `apps/com.maprisma.VideoTranslator.desktop`, `apps/CVideoTranslator.desktop`
  - `autostart/com.maprisma.VideoTranslator.Tray.desktop`
  - Managed `bin/video-trans` and `apps/video-trans.desktop` (marker lines)
- **Data:** `~/.config/video-trans/`, `share/video-trans/` (shared with Omarchy).
- **Bar:** tray id `maprisma-video-translator`.
- **Processes:** `-captions` (lock file), backend python.
- **Git:** no remote.

## launcher: maprisma-launcher (`tools/install-local`) + maprisma-launcher-applet (`install.sh`)

- **Build:** `tools/build-release.py`, flutter from PATH, and cargo for `cosmic-windows`.
- **Files:**
  - `~/.local/lib/maprisma-launcher/` (atomic swap), with `bin/maprisma-launcher` linking to it
  - `apps/com.maprisma.Launcher{,.Toggle}.desktop`, `icons/com.maprisma.Launcher.svg`
  - Applet: `bin/maprisma-launcher-applet`, `apps/CLauncher.desktop`
- **Data:** `~/.config/maprisma-launcher/`, `~/.cache/maprisma-launcher/`, `share/maprisma-launcher/`.
- **Shortcuts written at runtime:**
  - KDE: `apps/maprisma-launcher-<n>-<hash>.desktop`
  - COSMIC: entries in `com.system76.CosmicSettings.Shortcuts/v1/custom`
- **Processes:** everything whose exe is under `~/.local/lib/maprisma-launcher*`; the script stops them
  itself and restarts the dock.
- **Bar:** COSMIC `CLauncher`; KDE: the Icons widget's fixed entry `maprisma-launcher`.
- **Git:** origin maprisma/launcher.

## theme: maprisma-theme (`tools/install-local`)

- **Files:**
  - `~/.local/lib/maprisma-theme/`
  - `bin/maprisma-theme{,-core,-helper,-applet}` (links)
  - `apps/com.maprisma.Theme{,.Toggle}.desktop`, `apps/CTheme.desktop`
  - `icons/com.maprisma.Theme.svg`, `icons/CTheme-symbolic.svg`
  - `autostart/com.maprisma.Theme.Daemon.desktop` (KDE tray)
- **Data:** `~/.config/maprisma-theme/`, `~/.local/state/maprisma-theme`, `~/.cache/maprisma-theme`.
- **Runtime:** KDE keys `apps/maprisma-theme-key-*.desktop`.
- **Processes:** the script stops everything whose exe is under `~/.local/lib/maprisma-theme*`.
- **Bar:** tray id `maprisma-theme`.
- **Git:** no remote.


## playground: maprisma-playground (`tools/install-local`)

- **Build:** flutter, `dart compile exe` (the core), cargo in `bar/` (applet, tray).
- **Files:**
  - `~/.local/lib/maprisma-playground/` (atomic swap), with the app, `bin/maprisma-playground-{core,applet,tray}`,
    and links in `bin/`
  - `apps/com.maprisma.Playground{,.Toggle}.desktop`, `apps/CPlayground.desktop`
  - `icons/com.maprisma.Playground.svg`, `icons/CPlayground-symbolic.svg`
  - `autostart/com.maprisma.Playground.Tray.desktop` (OnlyShowIn=KDE)
- **Data:** `~/.config/maprisma-playground/` (settings, games, scores), `share/maprisma-playground/`
  (Generate's program and model, about 11 GB), `~/.cache/maprisma-playground/`.
- **Shared, stays:** `~/.config/llama.cpp/models.ini` (Analyze may add a vision projector).
- **Bar:** COSMIC `CPlayground`; KDE tray id `maprisma-playground`.
- **Processes:** everything whose exe is under `~/.local/lib/maprisma-playground`; agents it asks
  end with the app.
- **Git:** origin maprisma/playground.
## tiling: maprisma-kwin-scripts (KDE)

- **Files:**
  - KWin scripts `omarchy-navigation`, `maprisma-tiling` (kpackagetool6)
  - `bin/maprisma-tiling-{overlay,shortcuts}`
  - `share/dbus-1/services/org.maprisma.TilingOverlay.service`
- **kwinrc:** `[Script-maprisma-tiling]` keys; `[Plugins]` sets `…Enabled=true`.
- **Data:**
  - Backups: `share/maprisma-tiling/`
  - `~/.local/state/maprisma-tiling/shortcuts-backup.json`; `maprisma-tiling-shortcuts --restore` undoes the keys
- **Build hash:** kwinrc `Script-maprisma-tiling/build`.
- **Git:** no remote.

## icons: maprisma-panel (Maprisma Icons, KDE)

- **Files:**
  - Plasma package `com.maprisma.panel`
  - `bin/maprisma-panel-color`
- **Runtime:** `share/plasma/desktoptheme/maprisma-panel-{a,b}`, `~/.cache/maprisma-panel/`, plasmarc `[Theme] name`.
- **Zones:** in `plasma-org.kde.plasma.desktop-appletsrc`, under the widget's
  `[Configuration][General]`: `zoneLeft`, `zoneCenter`, `zoneRight` (comma lists of tray ids, plus
  `maprisma-launcher` and `clock`).
- **Git:** no remote.

## COSMIC panel files (this machine)

`~/.config/cosmic/com.system76.CosmicPanel.Panel/v1/plugins_wings` holds the left and right lists:

```
Some(([
    "com.system76.CosmicAppletWorkspaces",
    "io.github.ubruckhaus.CosmicMaprismaLauncher",
    …
], [
    "io.github.ubruckhaus.CosmicMaprismaHome",
    …
    "com.system76.CosmicAppletPower",
]))
```

`plugins_center` has the form `Some([ … ])`.

Both files use a 4-space indent and trailing commas, and end without a newline.

## Corrections and additions (step 1, checked against the scripts and this machine, 2026-11-09)

The catalog (`packages/maprisma_manager_core/lib/src/catalog.dart`) is the exact version of this file.

- **Interpreted helpers run as `python3 -I ~/.local/bin/../share/<app>/scripts/<x>.py`**: the
  script path in argv is not normalized, so it has to be normalized before it is compared.
- **`$HOME/.local/share` vs `XDG_DATA_HOME`:** the rust installers, Narrator, Video and Theme use
  `XDG_DATA_HOME`; Launcher's `install-local` and Narrator's backend setup (`kindle-reader`,
  `simple-reader`) hardcode `$HOME/.local/share`. Binaries always go to `$HOME/.local/bin`.
- **Narrator's backend setup hardcodes `~/.config`** (not `XDG_CONFIG_HOME`): `~/.config/kindle-reader/`
  and `~/.config/systemd/user/ocrvox.service{,.d}` (`setup_backend.py:19`, `bridge.py:176`).
- **Launcher's KDE shortcuts** (`maprisma-launcher-<n>-<hash>.desktop`) go to `XDG_DATA_HOME/applications`
  (`desktopDirectories`), unlike install-local's own entries in `$HOME/.local/share/applications`.
- **Theme's KDE tray icon** is `com.maprisma.Theme` (the COSMIC applet uses `C`Theme-symbolic).
- **Narrator's processes:** "ocrvox" is the `ocrvox.service` unit running the shared reader
  (`~/.local/share/kindle-reader/venv/bin/python …/app/reader.py`, plus its `kokoro_tts.py --worker`
  and an `mpv`). The unit isn't linked in any `.wants` here (not enabled). The marker line on this
  machine is `# Managed by ubruckhaus.simple-reader (Screen Narrator for COSMIC)`: markers are
  matched as a line prefix, as `setup_backend.py` does.
- **Video Translator:** `bin/video-trans` and `apps/video-trans.desktop` are made by
  `backend/install-shortcuts.sh` ("Set up now"), not by `install.sh`, which only refreshes them when
  they carry the marker. The backend runs as `python3 …/backend/bridge.py` (or the private runtime's
  python), matched by the backend folder. Neither Narrator nor Video installs an icon file.
- **Bluetooth Monitor:** `bt-device.sh`, `bt-power.sh`, `allow-access.sh` are installed `755`; the
  tray reads `~/.config/maprisma-bluetooth-monitor/settings.json`.
- **Launcher:** the icons folder also holds a stale `io.github.ubruckhaus.Launcher.svg` that no
  current installer writes (left alone). Its applet's desktop entry gets an unquoted Exec (sed).
- **Theme's KDE tray** is the daemon `~/.local/lib/maprisma-theme/bin/maprisma-theme-core daemon`
  (SNI Id `maprisma-theme`, in `daemon.dart`).
- **Tiling/Icons helpers** (`maprisma-tiling-overlay`, `maprisma-tiling-shortcuts`,
  `maprisma-panel-color`) are python scripts. Tiling's installer needs a running KWin (qdbus6).
- **maprisma:** the repo has two remotes, `origin` (github.com/uBruckhaus/maprisma) and `public`
  (github.com/maprisma/maprisma); `main` tracks `origin/main`. The folder is at 0.14.2
  (`MAPRISMA_VERSION` in `addons.py`), the installed package 0.13.1-9.
- **Upstreams here:** maprisma, maprisma-addons, bluetooth-monitor, hue-lights, launcher,
  llm-monitor, narrator and wlan-monitor track `origin/main`; the others have no remote.
