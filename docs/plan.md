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

### Position and order (asked 2026-11-09: "change the position incl. left, center, right area")

A bar editor shows the three areas (left / centre / right) as rows of icon chips in their real order, the
desktop's own icons included (COSMIC's clock, network …; KDE's clock entry), so a Maprisma icon can be
placed between them. Drag within an area or into another; the menu has "Move left/right" and "Move to
left/centre/right". COSMIC: the order in `plugins_wings` / `plugins_center`; KDE: the order in Maprisma
Icons' zones. Foreign entries are never removed or reordered except by the user's own drag.

### Changing an icon (asked 2026-11-09: "change an existing bar icon")

Applets (libcosmic `icon::from_name`) and trays (SNI `icon_name`) load their icon by name from the icon
theme. An app whose bar icon has a name of its own (`io.github.ubruckhaus.CosmicMaprisma*-symbolic`,
file in `~/.local/share/icons/hicolor/scalable/apps`) can get another icon: the Manager writes the chosen
SVG (a system icon by name, or a file the user picks, checked as SVG and size-limited) over that file,
keeps the original in `~/.local/state/maprisma-manager/icons/` for "Reset to the original icon", refreshes
the icon cache, restarts the bar icon, and applies the choice again after every install/update.
- Apps that use a system or shared name today (Video Translator `media-view-subtitles-symbolic`,
  Narrator `audio-headphones`, Control `com.maprisma.Maprisma`, Launcher/Theme `com.maprisma.*`) first get
  an own bar icon name in their repo (a small change each, separate commits there).
- Apps with live status icons (Bluetooth, Hue switch names by state) only get their default icon replaced;
  the status variants stay.

## Parts

- `packages/maprisma_manager_core` (Dart): catalog, status, git, receipts, jobs, bar (COSMIC, KDE),
  routes behind one `call(method, params)` (like Maprisma Theme's core) and a CLI
  (`maprisma-manager-core status|install <id>|update <id>|remove <id>|bar <id> left|center|right|out`).
- `flutter_app` (com.maprisma.Manager): the list page and the log sheet; `--toggle` like the others.
- `tools/install-local`: build and install into `~/.local/lib/maprisma-manager` (atomic swap, as the
  Launcher), link, desktop entry, icon.

## Changes after the plan review (docs/reviews/codex-plan-review.md, all 14 findings verified)

- **Ownership:** a receipt per app records every installed path with its hash (or link target), the
  inputs' commits and dirty state, and the files it displaced. Remove deletes only files whose hash still
  matches; links are unlinked, never followed; anything changed or foreign is kept and listed. Data
  shared with Omarchy (hue-lights, bluetooth-monitor, ubruckhaus-wlan-monitor, video-trans,
  kindle-reader) is never part of "Also delete its settings".
- **Wanted bar state** is kept by the Manager (`~/.local/state/maprisma-manager/bar.json`), snapshotted
  before an install and applied again after it (installers rewrite autostart files; Theme starts its
  daemon). Status shows separately: starts at login / running / visible.
- **Processes:** systemd user units are stopped first; interpreted helpers are matched by their exact
  script path in the argv (never by the interpreter); only the user's own processes; PID identity
  (start time) checked again before KILL; build first, stop as late as possible.
- **Jobs:** phases build (cancellable) → commit (not cancellable; pacman is never killed) → verify.
  The job state is written to disk; an interrupted job is shown on the next start with Repair offered.
  Jobs run in their own process group via `setsid`, not in a login shell.
- **Postconditions** per app (all its key files, links resolving, Flutter parts present): an install
  that skipped a part (Narrator/Video without cmake/ninja) is "partly installed". Per-app environment:
  Theme gets `FLUTTER=<dir>`, Narrator/Video `FLUTTER=<executable>`.
- **Update status** is three separate facts: the folder differs from the installed build; the
  upstream (the branch's configured upstream, ancestry checked) has new commits; the build is unknown.
- **Runtime-made things are not removed blindly:** Narrator's ocrvox unit and drop-ins, simple-reader,
  Tiling's Krohnkite migration, Icons' generated Plasma themes each get their own remove step, which
  is shown before it runs; unknown overrides are kept.
- **COSMIC panel:** RON parsed (also `None` and missing keys), panel instances discovered (Panel, Dock),
  unknown ids kept, a change applied to both files under a backup, re-read before writing. Whether the
  installed cosmic-panel follows the files live is tested first (upstream issue #674); otherwise the
  panel is restarted once per batch and checked.
- **KDE:** zones written through `evaluateScript` as string lists on the chosen `com.maprisma.panel`
  instance and read back. Maprisma Icons first gets a `hidden` list (the Launcher is a fixed entry
  today and can't be taken out). Without the widget, an icon in the system tray may sit in its overflow:
  shown as such.
- **maprisma (pacman):** a package recipe is generated for the exact local archive (version, sha256),
  built unprivileged, its metadata checked, installed with `pkexec /usr/bin/pacman -U --noconfirm
  <file>`; authentication cancelled and a held pacman lock are reported. The add-ons ZIP must exist
  and match the version (the Manager doesn't sign add-ons). Remove: `pkexec /usr/bin/pacman -R
  --noconfirm maprisma-bin`, the provider service stopped and disabled first.
- **Self-update:** stage and check the new bundle, copy a small helper to `~/.local/state/
  maprisma-manager/`, start it detached, it waits for the Manager to exit, swaps, starts the new one and
  waits for its "ready" file; no ready in 20 s → the old bundle comes back. Logged.
- **More for the user:** Open, Reinstall/Repair, prerequisites (cargo, flutter, cmake, ninja,
  kpackagetool6) per app, "restart needed" marks, offline and error states, dependency previews.

## Steps (in the review's order)

1. Read-only: catalog, status per component, receipts read, git provenance, prerequisites; CLI `status`.
2. Bar, proven on both desktops: COSMIC RON read/write + reload behaviour; KDE zones via
   evaluateScript; Maprisma Icons' `hidden` list. Bar editor data (areas, order) and moves.
3. Job engine: queue, phases, persisted state, logs, process handling, receipts with hashes.
4. One simple Rust app end to end (WLAN Monitor): install, update, remove with ownership, bar state kept.
5. The others: Flutter apps, Narrator/Video, Launcher (+ applet), Theme, then Tiling, Icons, maprisma
   (pacman); icon changes (and the small own-icon-name changes in the apps' repos).
6. Self-update; then the Flutter UI (list, bar editor, icon picker, log sheet) and tools/install-local.
7. Checks on COSMIC live, KDE in a later Plasma session: interrupted installs, hidden icons kept, shared
   data kept, concurrent config edits.

Codex reviews every step (read-only); findings are verified before fixing.
