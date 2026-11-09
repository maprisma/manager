# Maprisma Manager: plan

Asked 2026-11-09: "a Flutter app Maprisma Manager, which allows to manage our Maprisma apps on COSMIC
or KDE desktops: install, update, remove, together with bar icon installation and bar icon
selection", and "a new app, so that we also manage Maprisma Launcher".

English only. COSMIC and KDE Plasma 6; other desktops get install/update/remove without bar icons.
It looks and works like Maprisma Launcher's Plugins page (the Omarchy plugin manager): one
filterable list, sections by bar state, a ⋮ menu per app, update marks with the number of commits.

## What it manages (docs/inventory.md has every path)

| id | Name | Repo | Kind | Bar icon (COSMIC applet / KDE tray SNI id) |
| --- | --- | --- | --- | --- |
| maprisma | Maprisma | maprisma (+ maprisma-addons) | pacman package maprisma-bin | – (Maprisma Control is its icon) |
| control | Maprisma Control | maprisma-applet | rust, needs maprisma | CosmicMaprisma / maprisma-control |
| launcher | Maprisma Launcher | maprisma-launcher (+ maprisma-launcher-applet on COSMIC) | flutter | CosmicMaprismaLauncher / fixed widget entry `maprisma-launcher` |
| theme | Maprisma Theme | maprisma-theme | flutter + rust | CosmicMaprismaTheme / maprisma-theme |
| bluetooth | Maprisma Bluetooth Monitor | maprisma-bluetooth-monitor | rust | CosmicMaprismaBluetoothMonitor / maprisma-bluetooth-monitor |
| home | Maprisma Home | maprisma-home | rust | CosmicMaprismaHome / maprisma-home |
| hue | Maprisma Hue Lights | maprisma-hue-lights | rust | CosmicMaprismaHueLights / maprisma-hue-lights |
| llm | Maprisma LLM Monitor | maprisma-llm-monitor | rust | CosmicMaprismaLlmMonitor / maprisma-llm-monitor |
| wlan | Maprisma WLAN Monitor | maprisma-wlan-monitor | rust | CosmicMaprismaWlanMonitor / maprisma-wlan-monitor |
| narrator | Maprisma Narrator | maprisma-narrator | rust + flutter | CosmicMaprismaNarrator / com.maprisma.Narrator.Tray |
| video | Maprisma Video Translator | maprisma-video-translator | rust + flutter | CosmicMaprismaVideoTranslator / maprisma-video-translator |
| tiling | Maprisma Tiling (KDE) | maprisma-kwin-scripts | KWin scripts | – |
| icons | Maprisma Icons (KDE) | maprisma-panel | Plasma widget | – (it is the bar for the others on KDE) |
| manager | Maprisma Manager | maprisma-manager | flutter | – (opens from the app menu) |

The catalog is data in the core (`catalog.dart`): repo folder, GitHub remote (to clone when the folder
is missing), desktops it runs on, install command, the files and folders it installs, its user data
(kept on remove unless asked), its processes, post steps, dependencies (control → maprisma,
launcher's applet → launcher) and its bar icon per desktop.

## Source, versions, updates

- Source: the local repos in `/mnt/Data/Projects/<repo>` (the projects folder is a setting; on Omarchy the
  disk is mounted elsewhere). A missing repo with a remote can be cloned ("Get"); one without is
  "not available here".
- Installed: the catalog's key file exists (e.g. `~/.local/bin/maprisma-wlan-monitor`); maprisma by
  `pacman -Q maprisma-bin`.
- Which build: a receipt per app, `~/.local/state/maprisma-manager/installed/<id>.json`
  `{commit, at, version?}`, written after every install through the Manager. Apps installed before the
  Manager have no receipt: "installed, build unknown" with Reinstall offered.
- Update available: the repo's `main` has commits the receipt's build hasn't (local work), or `origin/main`
  is ahead after `git fetch` (only repos with a remote; fetch at most every 30 min unless forced).
  "Update" = `git pull --ff-only` when the working tree is clean and behind, then reinstall. A dirty tree
  or diverged branch: no pull, the reason is shown, "Reinstall from the folder" stays possible.

## Install / update / remove

- Runs the repo's own install script (no copies of their logic) in a login-like environment with
  `PATH=<flutter>/bin:~/.cargo/bin:$PATH`, the output streamed to the UI (a log sheet, kept per app in
  `~/.local/state/maprisma-manager/logs/<id>.log`). One job at a time (a queue), cancellable (SIGTERM to
  the process group).
- Before: the app's processes are found by `/proc/<pid>/exe` under its install paths and stopped
  (TERM, KILL after 5 s) where the script doesn't do that itself; never by `pkill -f`.
- After: the post steps (icon cache, desktop database), the bar icon process restarted (COSMIC: the
  applet process is ended, the panel starts it again; KDE: the tray started again with `setsid`), the
  receipt written.
- maprisma (pacman): build with `tools/build-release.py --addons ../maprisma-addons`, package with a
  local copy of the aur-maprisma-bin PKGBUILD (next pkgrel), `pkexec pacman -U --noconfirm`, then
  `systemctl --user restart maprisma-providers.service`. Remove: `pkexec pacman -R maprisma-bin`.
- Remove: confirm dialog (names what goes and what stays); stop processes, take the bar icon out,
  delete the catalog's files, post steps, drop the receipt. User data stays unless "Also delete its
  settings" is ticked. KDE extras: Tiling runs `maprisma-tiling-shortcuts --restore`, `kpackagetool6 -r`
  and removes its kwinrc keys; Icons `kpackagetool6 -r`. Removing an app others need asks first.
- The Manager updates itself: build, then a detached `setsid` helper waits for the app to quit, swaps the
  bundle and starts it again.

## Bar icons

"In the bar" sections like the Plugins page: In the bar / Not in the bar / No bar icon.

- **COSMIC**: `com.system76.CosmicPanel.Panel/v1/plugins_wings` (`Some((left, right))`) and
  `plugins_center` (`Some([...])`), RON. Put in: left (end of the left wing), centre, right (start of the
  right wing, before COSMIC's own applets); take out: remove the id everywhere. Written atomically, the
  rest of the file kept; COSMIC's panel follows its config (if it doesn't, the panel process is restarted).
  Moving within a zone: "Move left/right".
- **KDE**: the tray process + its autostart file (`OnlyShowIn=KDE`). Take out: stop the tray, mark the
  autostart file `Hidden=true`. Put in: unmark, start the tray (`setsid`). With Maprisma Icons in the
  panel, "Put into the bar: left/centre/right" also writes its zones (zoneLeft/zoneCenter/zoneRight)
  through plasmashell's scripting API (`evaluateScript`, `writeConfig`), so Plasma keeps them; without the
  widget the icon goes to the system tray.
- Other desktops: no bar icon actions.

## Parts

- `packages/maprisma_manager_core` (Dart): catalog, status, git, receipts, jobs, bar (COSMIC, KDE),
  routes behind one `call(method, params)` (like Maprisma Theme's core) and a CLI
  (`maprisma-manager-core status|install <id>|update <id>|remove <id>|bar <id> left|center|right|out`).
- `flutter_app` (com.maprisma.Manager): the list page and the log sheet; `--toggle` like the others.
- `tools/install-local`: build and install into `~/.local/lib/maprisma-manager` (atomic swap, as the
  Launcher), link, desktop entry, icon.

## Steps

1. Core: catalog, status, receipts, git/update check, job runner with streamed log, install/update/remove,
   CLI. Tests with fake repos, fake scripts and a temporary HOME.
2. Bar icons: COSMIC RON and KDE (autostart, tray, widget zones). Tests on copies of real files.
3. Flutter UI (the Plugins page's look) with the log sheet; tools/install-local; desktop entry and icon.
4. Install, then live checks on COSMIC that change nothing lasting (status, update check, one bar icon
   moved and moved back).

Codex reviews the plan and every step (read-only); findings are verified before fixing.
