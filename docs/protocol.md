# Maprisma Settings core: protocol

The UI talks to `packages/maprisma_manager_core` the way Maprisma Theme does: one JSON object per
request, one per answer (`CoreService.handleAsync`), or `CoreService.call(method, params)` in-process.

```
→ {"id": 1, "protocol": 1, "method": "apps.list", "params": {}}
← {"id": 1, "result": {...}}
← {"id": 1, "error": {"code": "bad_params", "message": "id"}}
```

Error codes: `unknown_route`, `bad_request` (not a valid frame), `bad_params`, `not_found`,
`request_too_large` (64 KiB), `response_too_large` (4 MiB), `internal`; for the bar: `changed` (the
config changed since it was read: read again and retry), `unreadable` (a panel file doesn't parse),
`unavailable` (no plasmashell / qdbus6, or not possible on this desktop), `no_bar_icon`, `bad_file`
(an autostart file without `[Desktop Entry]`), `busy` (another Manager holds the state lock 10 s, or
runs a job; a job for that app is already queued); for jobs: `unsupported_yet` (the app's install or
remove needs a step of its own that comes later; the catalog says why), `not_cancellable` (the job is
in its commit phase, or its script has started writing the app's files), `finished`, `not_owner` (the
job runs in another Manager process: only that one can cancel it). Job results (`result.code`) add
`app_busy` (the installer refused because the app is busy, nothing changed: Launcher while its terminal
runs a command), `blocked` (a remove that can't run now: the plan's `blocked` says why), `step_failed`
(a required remove step failed before any file was deleted); Maprisma's pacman steps add
`pacman_locked`, `auth_cancelled`, `auth_timeout`, `pacman_failed`, `missing_addons`, `bad_package`,
`build_failed`, `unsafe` (a system pkexec/pacman/makepkg with a test root). Icons: `bad_icon` (not an SVG
the Manager writes: the message says why), `not_installed` (the app's icon file is missing).
The Manager itself: `self_remove` (it doesn't remove itself: `tools/uninstall-local` from a terminal);
self-update job results add `bad_stage` (the staged build isn't complete; nothing was touched) and
`self_update_failed` (the helper rolled back, or didn't finish).

Writes: `git.fetch` (remote-tracking refs, when asked), `github.refresh` (`github.json`), the `bar.*`
changes, `icons.set`/`icons.reset` (the app's icon file, `icons/<app>/`), and the jobs (`jobs.start`: install, update, reinstall, remove, release; a job may clone a
missing folder from GitHub and download release assets into `~/.cache/maprisma-settings/downloads/`). `apps.list` / `apps.get` / `jobs.*` reads mark
an unfinished job of a Manager that is gone as `interrupted` in its state file.

## Environment

| Variable | Meaning |
| --- | --- |
| `HOME`, `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, `XDG_STATE_HOME`, `XDG_CACHE_HOME` | Every path (relative XDG values are ignored, as the spec says). Binaries are always `$HOME/.local/bin`. |
| `XDG_CURRENT_DESKTOP` | `COSMIC` → cosmic, `KDE` → kde, `Hyprland` → hyprland, anything else → other. Unset: the session's name, then a Hyprland whose socket exists (`HYPRLAND_INSTANCE_SIGNATURE` alone is not enough), then `KDE_FULL_SESSION`. |
| `MAPRISMA_MANAGER_DESKTOP` | Overrides the desktop (`cosmic`, `kde`, `hyprland`, `other`). |
| `MAPRISMA_PROJECTS` | The projects folder (the repos). |
| `MAPRISMA_FLUTTER` | Flutter: the executable or its folder. |
| `MAPRISMA_MANAGER_ROOT`, `MAPRISMA_MANAGER_PROC` | Tests only: the system root for `/usr`, `/etc` and the `/proc` to read. |
| `MAPRISMA_MANAGER_OFFLINE`, `MAPRISMA_MANAGER_GH` | Tests only: `1` = the built-in GitHub reads and downloads refuse (no network) and gh is used only when `MAPRISMA_MANAGER_GH` names it (a fake). |

The projects folder: `MAPRISMA_PROJECTS`, else `projectsDir` in `~/.config/maprisma-settings/settings.json`,
else the first of `~/Projects`, `/mnt/Data/Projects` that holds a known repo, else the first that
exists, else `~/Projects`. Flutter: the `flutter` setting, `MAPRISMA_FLUTTER`, `PATH`,
`<projects folder>/../flutter`, `~/flutter`.

## Routes

### `core.hello`

`{version, protocol, desktop, projectsDir, projectsSource, migrated?}`; `projectsSource` is `env`, `settings`,
`found` or `default`; `migrated` lists what this start moved from the folders and id of the old name.

### `desktop.look`

`{desktop, colors: {accent, background, foreground, muted, selection, red, yellow, orange, green}, rounding, is_dark}`:
the desktop's palette and window corners, read as Maprisma Launcher reads them (COSMIC: the
`com.system76.CosmicTheme.{Dark,Light}` accent/background/success/warning/destructive and
`corner_radii.radius_s`; KDE: kdeglobals' colour scheme; other: no colours, the platform's light or dark).

### `settings.get` / `settings.language` `{language}` / `settings.set` `{key, value}`

`settings.get`: `{language, systemLanguage, corners, screenshot_key}` from `settings.json`.
`settings.language` saves `auto` or a supported code (docs/localization.md). `settings.set` saves one
of the toolbar's Settings menu (tune icon): `corners` = `windows` (the desktop's window corners,
`desktop.look` `rounding`; also what a missing or unknown stored value means), `slight` (6 px),
`rounded` (12 px) or `square`; `screenshot_key` = `true`/`false` (F12, on by default). Anything else:
`bad_params`. Every write keeps the other settings. Corners come in three sizes in the window
(`flutter_app/lib/theme.dart` `Corners`, as Maprisma Playground): cards, dialogs, pop-ups, menus and
messages the radius; buttons, drop-downs, fields, tooltips and chips at most 8 px; check boxes,
slider tracks and progress bars at most 4 px; Square squares everything, the slider knob stays a
14 px square.

**F12** (no Ctrl, Shift, Alt or Super; also in a dialog) saves a picture the window draws of itself
(no screenshot program, nothing uploaded) to `<XDG_PICTURES_DIR or ~/Pictures>/Maprisma Settings/`
`maprisma-settings-<date>-<time>.png`, then asks for an optional note (at most 4000 characters), saved
next to it as `.txt` when the dialog closes (Done, Enter, Esc). Private: the folder is made 0700 and
used only when it is a real folder of yours that others cannot write to (checked on its opened
handle; a link in its place is refused); every file is new (O_EXCL|O_NOFOLLOW, 0600, never over an
older one: `-2`, `-3` …), written completely and synced, or removed again. `user-dirs.dirs` is read
bounded and never through a link (`packages/maprisma_manager_core/lib/src/screenshot.dart`,
`private_files.dart`, ported from Maprisma Playground).

### `apps.open` `{id}` / `links.open` `{url}`

`apps.open` starts the app's window (the catalog's `open` command, detached in its own session):
`unavailable` when it has none (Control, the KDE apps, the Manager), `not_installed` when its program
is missing. `links.open` opens a `https://github.com/…` page with `xdg-open` (anything else: `bad_params`).

### `apps.list` `{desktop?}`

Everything the list page needs, for every catalog app. `desktop` (`cosmic`, `kde`, `hyprland`, `other`) shows it as that desktop would.

```
{desktop, projectsDir, projectsSource, flutter, flutterSource, apps: [App], discovered: Discovered}
```

`discovered` is `discovered.list`'s answer (new apps, below).

App:

| Key | |
| --- | --- |
| `id`, `name`, `kind`, `desktops` | From the catalog. |
| `supportedHere` | The app runs on this desktop (Tiling/Icons: KDE only). |
| `state` | `installed`, `partial` (some postconditions fail, see the components), `absent`. Counts the components that apply to this desktop (Launcher's applet: COSMIC only). |
| `components[]` | `{id, name, repo, applies, state, packageVersion?, note?, failing: [{path, part, problem}], missingParts, prerequisitesMissing}`. `problem`: `missing`, `not a file`, `not a folder`, `not executable`, `not a link`, `points to …`, `dangling`. `missingParts`: parts with no path present (e.g. Narrator's `settings window` without cmake). |
| `build` | `{known, receipt?: {id, at, version?, inputs, paths, displaced}, error?}`; `known` = a valid receipt exists. |
| `updates` | `buildUnknown` (installed, no receipt); `sourceDiffers` (`true`/`false`, `null` without a receipt, and for a release install: `sourceReasons: ["installed from release vX"]`) with `sourceReasons`; `upstreamNew` (commits the configured upstream has that HEAD hasn't, as of the last fetch; `null` = no input has an upstream) with `upstreamNotes` (diverged, dirty: no pull); `githubNew` (commits the GitHub remote's branch has that HEAD hasn't, as of the last fetch, also when the configured upstream is another remote; `null` = nothing to compare) with `githubNotes` (no folder, no GitHub remote in the folder, not fetched yet, diverged, dirty); `releaseNew` (`{tag, version, installed, installable}` when the latest release's version is newer than the installed one, else `null`). |
| `versions` | `{installed, folder, release}` where known (pacman, a Flutter bundle's `version.json`; the repo's version line; the latest GitHub release's tag without `v`). |
| `sources` | Where it exists (below): `{where: folder/GitHub/both/none (the main input), url (GitHub web URL), release (latest, as last checked), releaseInstall: {supported, note?} or null, inputs: [Source]}`. |
| `repos[]` | Per input repo (`dirty` is `null` when git status failed; `error` says what could not be read): `{repo, folder, present, isRepo, branch, detached, head, dirty, dirtyTracked, untracked, upstream, upstreamRemote, upstreamUrl, ahead, behind, relation, lastFetch, error?, cloneUrl, available}`. `relation`: `upToDate`, `behind`, `ahead`, `diverged` (by ancestry), `unknown` (no upstream). `available`: `here`, `cloneable`, `not available here`. |
| `bar` | COSMIC: `{has, id, state: in/out/unknown, zone, panel, startsAtLogin, running, visible, error?}`: `zone`/`panel` where the applet is (every panel instance is looked at); in a panel = starts at login (cosmic-panel starts it); `running` = its applet program runs as a child of cosmic-panel; a file that doesn't parse gives `unknown` with the error. KDE tray: `{has, id, kind: tray, state, zone?, startsAtLogin, running, visible, where?}`: autostart file not `Hidden=true`; the tray process; `state: out` also when Maprisma Icons hides it; `visible` is `null` for a running tray in the system tray (it may sit in the overflow), `where: systemTray` without the widget. KDE widget entry (Launcher): `{kind: widgetEntry, state, zone?, visible}` from Maprisma Icons (`unknown` with `error` when plasmashell can't be asked). `iconName` is the one the desktop shows (Theme's KDE tray: `com.maprisma.Theme`). `wanted` is the app's entry in bar.json. No icon: `{has: false, state: none}`. |
| `running` | How many of the user's processes belong to it (by `/proc/<pid>/exe`, or the script path in argv for interpreted helpers). |
| `icon` | The row icon: `{name, file, symbolic}`: the app's own icon name (else its bar icon's) and the SVG found for it in the user's or the system's hicolor (`null` when missing). |
| `open` | It has a window of its own and its program is there (`apps.open`). |
| `dependsOn`, `neededBy`, `env` | Dependencies; `env.FLUTTER` as the installer wants it (Theme: the folder, Narrator/Video: the executable; `PATH+` for those that take flutter from PATH). |
| `support` | `{install, remove, note?}`: whether jobs can install/remove it yet (`false` → `unsupported_yet`). |
| `job`, `repair` | The app's latest job (the `jobs.list` form, null without one); `repair: true` after an interrupted job or a failed one that had started writing: offer Repair (= reinstall). |

Source (one per input repo):

```
{repo,
 folder:  {path, present, isRepo, branch, head, dirty},
 github:  null (local only) | {repo: "org/name", url: "https://github.com/org/name", cloneUrl, known, public?, defaultBranch?,
          release?: {tag, name, published, url, prerelease, assets: [{name, size, url, digest?}]} | null,
          checked, age (seconds), stale, error?, lastTry?, via?: gh/rest},
 remote:  null | {name, url, isUpstream}       the folder's remote whose URL is the GitHub repo (by URL, not by name)
 compare: null | {ref: "<remote>/<branch>", fetched, ahead, behind, relation},
 newSinceBuild?}                              commits on that ref since the receipt's commit (folder builds)
```

The GitHub branch is the repo's default branch as last checked, else the folder's branch, else `main`.
maprisma: origin is the private `uBruckhaus/maprisma`, the GitHub remote is `public`.

### `apps.get` `{id, desktop?}`

`{desktop, projectsDir, …, app}`: the App above plus `components[].{install, kind, desktops, checks,
prerequisites: [{command, found, path, part?, optional?, note?}], dependsOn, optionalParts, catalogNote}`,
`processes` (pid, exe, argv, match, startTicks), `processMatches`, `units` (`{name, runtime, unitFile, file,
enabledBy}`), `data` (`{path, exists, sharedWithOmarchy, neverDelete}`), `runtime` (files made at
runtime: `{path, exists, glob?, matches?, marker?, markedOurs?}`), `postSteps`, `barIcon`, `note`.

### `git.fetch` `{id?, force?}`

Fetches the configured upstream's remote of each input repo of app `id` (all apps without it), and
the folder's GitHub remote when that is another remote (so `githubNew` is known for maprisma, whose
upstream is the private origin). A repo
fetched within 30 minutes (`FETCH_HEAD`), or tried by this core process within 30 minutes, is skipped
unless `force` is `true`. Failed attempts are remembered in memory only (step 1 writes no state), so a
new CLI process retries an offline fetch. Inspection never uses a transport (`protocol.allow=never`,
no lazy fetch, no fsmonitor); only this route does.

`{force, repos: [{repo, fetched, skipped?: recent/no upstream/missing/not a repo, error?, remotes?: [{remote, fetched, error?, github?}], behind?, relation?, github?: {remote, ref, fetched, behind, relation}, lastFetch?}]}`
(`no upstream` = neither an upstream nor a GitHub remote.)

### `github.refresh` `{id?, force?}`

Reads the GitHub facts of every GitHub repo of app `id` (all without it): `repos/<org>/<name>` (web
URL, public, default branch) and `repos/<org>/<name>/releases/latest` (404 = no release). Through `gh
api` when `gh` is installed and `gh auth status` succeeds, else the public REST API
(`https://api.github.com/`, no token). A repo checked or tried within 30 minutes is skipped unless
`force`. A failure keeps the last known facts and records `error`/`lastTry`; offline (no connection,
also when gh says so) or rate limited
(403/429 with `x-ratelimit-remaining: 0`, the reset time in the message) stops the refresh, the rest
is `skipped: offline` / `rate limited …`. Cached in `~/.local/state/maprisma-settings/github.json`
(`{schema: 1, repos: {"org/name": {checked, via, facts: {url, public, defaultBranch, release}} | {…, lastTry, error}}}`,
written under the state lock). `apps.list` only reads this cache (no network).

`{force, via: gh/rest/null, org?, repos: [{repo, checked, via?, release?, skipped?: recent/offline/rate limited…, error?}], facts: {"org/name": github facts}}`;
`{…, note: "not on GitHub"}` for an app without GitHub repos.

Without `id` it first lists the org's repos (`orgs/maprisma/repos?per_page=100&type=all`: through gh
also the private ones the login sees, through REST the public ones), at most every 30 minutes unless
`force`, a failure keeping the last list; cached as `org: {checked, via, repos: [{name, url, public,
description, archived, fork}]} | {…, lastTry, error}` in the same file. `org` in the answer is
`{checked, via?, repos?, error?, rateLimited?}` or `{checked: false, skipped: recent}`; rate limited there
stops the refresh.

**Found GitHub repos.** Before every call the core links each catalog input that has no GitHub repo
in the catalog: the first GitHub URL among its folder's remotes (`origin` first), else the org repo of
its name as last listed (`maprisma-theme` → `maprisma/maprisma-theme` or `maprisma/theme`). A catalog
repo is never replaced. A found repo counts like a catalog one everywhere (facts, fetch, compare,
clone when the folder is missing, update); its sources' `github` says how it was found:
`linkedBy: catalog | remote | org`.

### `discovered.list` `{}`

New Maprisma apps the catalog doesn't know, by name: git folders `maprisma*` in the projects folder
that are no catalog input (nor a clone of one: a remote that is a catalog app's GitHub repo), and the
org's repos that no catalog input is (archived ones, `omarchy-*`, `aur-*`, `.github`, `maprisma`
left out). A folder and a repo are one app when the folder's remote is the repo, or, without a GitHub
remote, when the names match (`clock` ↔ `maprisma-clock`). No network.

```
{org: {org, url, known, checked, age, stale, error?}, projectsDir,
 apps: [{name, folder: path | null, github: {repo, url, public?, description?, linkedBy: remote | name | org} | null, cloneTo?}]}
```

They are only shown: installing needs a catalog entry (what it installs, so that remove can take it
away again).

### `discovered.clone` `{repo}` / `discovered.open_folder` `{name}`

`discovered.clone` clones a GitHub-only new app (`org/name`, one of `discovered.list`'s without a
folder) into its `cloneTo` (`<projects>/maprisma-<name>`, or its own name when that starts with
maprisma): `git clone` into a hidden temporary folder next to it, renamed when complete, nothing left
on failure. `not_found` (no such new app), `exists` (has a folder, or `cloneTo` is taken),
`clone_failed`. Answer `{repo, folder, cloned: url}`. `discovered.open_folder` opens a new app's folder
with `xdg-open`.

### `bar.get` `{panel?, widget?}`

The bar editor's data: the three areas with their entries in order, the desktop's own ones included.

```
COSMIC: {desktop: cosmic, kind: cosmicPanel, panel, panels: [..], files: {plugins_wings, plugins_center: user/system/none},
         revision, areas: {left: [Entry], center: [...], right: [...]}, out: [{id, app, name, iconName}], error?}
KDE:    {desktop: kde, kind: maprismaIcons, widget, widgets: [{panel, widget, screen, location, zoneLeft, zoneCenter, zoneRight, hidden}],
         revision, hidden, areas, out, trays}
        {desktop: kde, kind: systemTray, note?/error?, trays: [{app, id, startsAtLogin, running}]}   (no widget / no plasmashell)
other:  {desktop: other, kind: none}
Entry:  {id, ours, app?, name?, iconName?, shown?}
```

COSMIC: `panel` is an instance from `com.system76.CosmicPanel/v1/entries` (default `Panel`); a missing
user file shows the system default (`files` says which). Foreign applets are named from their desktop
file. KDE: the first Maprisma Icons instance unless `widget` (its id) is given; the areas are what the
widget shows: its saved zones, plus the Launcher and running Maprisma trays it adds at the end of the left
zone sorted by title, and the clock in the centre, hidden ids left out; an old single `order` counts as
the left zone, as in the widget. `shown: false` marks a saved tray that isn't running: it keeps its place
(and counts for indices) but the widget doesn't draw it. `revision` is passed back to a change to refuse it
(`changed`) when the config changed since.

### `bar.place` `{app, area, index?, panel?, widget?, revision?}`

Puts the app's icon into `area` (`left`, `center`, `right`) at `index` (counted without the icon itself;
clamped). Without `index`: COSMIC: the end of left and centre, the right wing before COSMIC's own
applets (`com.system76.*`); KDE: the end, the start of the right zone. Already in that area and no index:
nothing changes.

### `bar.move` `{app | entry, area, index, panel?, widget?, revision?}`

Moves an app's icon, or any entry by its id (a foreign applet, KDE's `clock`), to `area` at `index`.

### `bar.remove` `{app, panel?, widget?, revision?}`

COSMIC: the applet id is taken out of every panel instance (only `panel` when given). KDE: out of the
zones and into Maprisma Icons' `hidden` list (the widget would put a running tray back otherwise), and
`Hidden=true` in the tray's autostart file.

Changes answer `{id, app?, placed, …}`: COSMIC `panels: [{panel, written: [files], backup?, area?, index?}]`
and `reload` (below); KDE `widget, area?, index?, hidden` (read back from Plasma) and `autostart:
changed/unchanged/missing`.

How it writes: COSMIC: under the state lock, both files are read again and compared with what was read
(`changed` otherwise), copied to `~/.local/state/maprisma-settings/backups/<time>-cosmic-<panel>/` (20 kept),
then each changed file is checked once more and written atomically (temp file + rename), the one that
loses an entry first; only changed lists are rewritten, in the file's own style, comments and unknown ids
kept. `reload`: `{panel, reacted: true}` when cosmic-panel started applets again (cosmic-panel 1.11 does
this by itself), else the panel is restarted once by its PID (`restarted`, `back`), `{panel: null, note}`
without a running panel. KDE: one `evaluateScript` compares the widget's config with what was read and
writes `zoneLeft/zoneCenter/zoneRight/hidden` as string lists (`currentConfigGroup = ['General']`,
`writeConfig`), each id in one zone only; the answer is read back and checked. Autostart files are backed
up and written atomically. Starting and stopping KDE trays comes with the job engine (step 3).

Every change of one of our icons is recorded in `~/.local/state/maprisma-settings/bar.json`:
`{"cosmic": {"wlan": {"placed": true, "area": "center", "index": 4}, "home": {"placed": true, "area": "center", "index": 1, "panel": "Dock"}}, "kde": {"launcher": {"placed": false}}}`.
`panel` / `widget` are kept when the change named one; without, the default panel/widget (and, for a
removal on COSMIC, every panel). A whole change (read, write, bar.json) holds the state lock
(`~/.local/state/maprisma-settings/lock`, plus an in-process queue).

### `bar.apply` `{}`

Puts the wanted state (bar.json) back for this desktop in one write per panel and one reload: an icon
not in its wanted area is placed at its wanted index, in the panel/widget it was put into (gone: the
default one); one wanted out is taken out (KDE: hidden + autostart
flag). Icons already in their area stay where they are. Used after installs (step 3). `{changed: [app ids], reload?}`.

### `apps.remove_plan` `{id, delete_settings?}`

What a remove would do, before anything is touched (the remove job plans again and deletes only what
its plan says; pass `revision` to refuse a plan that changed since it was shown):

```
{app, name, receipt: valid/none/broken, receiptError?, verified, revision,
 goes:  [{path, kind: file/link/dir, sha256?/link?, normalized?, onlyIfEmpty?, unverified?}
         | {path, kind: tree, files, links, bytes, derived?, leftover?, whole}],
 stays: [{path, why, runtime?, marked?}],   changed since the install / not what the Manager installed / not in the receipt / …
 data:  [{path, goes, why?}],     user data: goes only with delete_settings; Omarchy-shared data and `keep` data never
 runtime: [{path, why, markedOurs?}],   made at runtime: not removed by this step
 restores: [{path, backup, reason}], backupsKept: [...],
 dependents: [{id, name}], units, running, bar: {has, id?, takenOut?}, postSteps,
 steps?: [{id, title, commands?, when: before/after, required?}],   the app's own steps (KDE apps)
 generated?: [{path, kind: generated, why}], notes?: [...],
 blocked?}                        why the remove can't run now (the job fails with `blocked`)
```

With a valid receipt, a file goes only while its sha256 is the receipt's (an autostart file's
`Hidden=` line left out: hiding the icon is not a change), a link only while it points where it did
(unlinked, never followed), a folder only when empty; catalog paths not in the receipt stay. Without
a receipt (installed before the Manager, or a broken one) the catalog's paths go, each marked
`unverified`; a link only when it points where the installer points it. Maprisma (pacman): below,
"Maprisma (pacman)". Refused with `self_remove` for the Manager (`tools/uninstall-local` removes it from a terminal); `unavailable` for an app of another desktop
(Tiling and Icons are removed only on KDE: their steps need Plasma).

**Owned folders** (step 5a; the catalog's `trees`: Launcher's and Theme's bundles in `~/.local/lib`,
Narrator's `backend`/`settings`, Video Translator's `backend`/`app`, Tiling's two KWin script packages,
Icons' plasmoid): the receipt has a manifest of every entry below the folder (below). A file goes only
while its sha256 is the manifest's, a link only while it points where it did (never followed);
Python's byte-code caches (`__pycache__/*.pyc`) go as derived; anything else stays and is listed
(at most 100 per folder, then a count); then the folders left empty, deepest first, and the folder
itself when empty. The catalog's paths inside such a folder are handled only by its manifest. Left
by an interrupted installer: `<folder>.new.XXXXXX` / `<folder>.old.XXXXXX` (atomic swaps: Launcher,
Theme) and `<folder>.new` (staging copies: Narrator, Video) go (`leftover: true`) only when they hold
nothing but the manifest's files, else they stay. A folder stays as a whole (`why` says so) when the
receipt has no manifest for it, it was too big to own (`overflow`), it was there before the Manager
first installed the app and may not be only its own (`preexisting`: Tiling's omarchy-navigation), or
it is a package (`wholeOnly`: KWin scripts, the plasmoid) with any changed entry. Without a receipt an
app with owned folders isn't removed at all (`blocked`: "Reinstall … first").

**Runtime things that outlive the app** are listed under `stays` with the reason (`runtime: true`,
`marked: true` when its marker line shows it is the app's): Narrator's `ocrvox.service`, its
`read-aloud-runtime.conf` drop-in, `simple-reader` and its desktop entry (made by the reader's setup,
shared with Omarchy's reader) and Video Translator's `video-trans` command and desktop entry ("Set up
now", shared with Omarchy's video-trans). The Manager doesn't remove them: their owner is the shared
reader / video-trans setup, and an unchanged copy can't be told from one the user adjusted.

**KDE steps** (`steps`, shown before they run; `kde_remove.dart`):
- Tiling: `maprisma-tiling-shortcuts --restore` (required: a failure stops the remove before any file
  goes), `qdbus6 org.kde.KWin /Scripting …unloadScript <script>`, `kwriteconfig6 --file kwinrc … --delete`
  for `[Plugins] <script>Enabled` and each key of `[Script-maprisma-tiling]` (nothing else in kwinrc),
  `kpackagetool6 -t KWin/Script -r <script>` for a package that goes; after the files: `qdbus6
  org.kde.KWin /KWin reconfigure` and D-Bus `ReloadConfig` (the overlay service file is gone).
  omarchy-navigation is unloaded/disabled/removed only when it goes (installed by the Manager,
  unchanged). The Krohnkite backup (`~/.local/share/maprisma-tiling/krohnkite-backup.tar.gz`, with
  the old kwinrc groups) stays with how to get Krohnkite back; that data folder is never deleted.
- Icons: every `com.maprisma.panel` widget is removed from the panels (`evaluateScript`; required),
  a generated `maprisma-panel-*` Plasma style in plasmarc is switched back to the style the install
  found (`saved.plasmaTheme` in the receipt, else `default`; `plasma-apply-desktoptheme`, required),
  `kpackagetool6 -t Plasma/Applet -r com.maprisma.panel`; after the files the generated styles
  (`desktoptheme/maprisma-panel-{a,b}`, only when their metadata names maprisma-panel-color and they
  hold only its files, never the active one) and the colour cache (`~/.cache/maprisma-panel`, only
  `state.json`) are deleted. No plasmashell / qdbus6 / kpackagetool6: `blocked`.

A remove first records where the icon is (bar.json, when the user never placed it through the
Manager; COSMIC: area, index and panel), so installing the app again puts it back at the same place.

Never touched: a path outside the shared install folders (`~/.local/bin`, `~/.local/lib`, the data,
config, applications, icons, autostart … folders) or reached through a symlinked folder below them
(checked in the plan and again right before each delete). Paths a remove kept are recorded in
`kept/<app>.json`; a later remove without a receipt never takes them while they are unchanged (an
install clears the record). Displaced files are put back only at the app's catalog paths, when the
backup's sha256 still matches.

## Jobs

One job at a time: a queue in the core process and an fcntl lock on
`~/.local/state/maprisma-settings/jobs/lock` held while the queue runs, so a second Manager or the CLI
gets `busy`. Every job's state is `jobs/<id>.json`, its log `logs/<id>.log` (100 finished jobs kept).

```
{id: "20261109T101500Z-wlan-install", app, kind: install/update/reinstall/remove/release, options,
 state: queued/running/succeeded/failed/cancelled/interrupted, phase: queued/prepare/build/commit/verify/finish,
 component?, created, started?, ended?, finished?, committed, owner: {pid, start}, script?: {pid, pgid, start},
 log, stopped?: [{pid, exe, result}], units?, warnings?, sources?: [..], release?: {tag, asset, sha256, file},
 result?: {ok, code?, message?, repair?, partial?, sources?, release?, …}}
```

An unfinished job whose owner (pid + start time) is gone is `interrupted` (`repair: true` unless it was
still queued); if its script still runs it gets SIGCONT (it may have been paused at the commit) and
`orphan: true`, and every `jobs.start` is `busy` until it has ended.

Phases of install/update/reinstall:

1. **prepare** (cancellable): dependencies installed, prerequisites found (a missing one of an
   optional part is a warning), every input repo present with a commit. A missing folder of an input
   on GitHub is cloned: `git clone <github url>` (through `setsid`: its own session and group) into a
   hidden sibling (`.<repo>.clone-<job>`), renamed to `<projects>/<repo>` when complete (logged; a
   cancel sends TERM to the clone's group, KILL to what is left after 5 s, waits until none is left,
   then deletes the sibling; `clone_failed`; not on GitHub: `no_source`). For `update` only: the
   folder's GitHub remote (by URL) is fetched first; then `git pull --ff-only` when the repo is clean,
   behind and has an upstream (otherwise the reason is logged and the folder is built as it is); then,
   when the GitHub remote isn't the configured upstream's remote, HEAD is fast-forwarded to the exact
   commit of `<remote>/<branch>` (`git merge --ff-only <commit id>`, never a short ref name a local
   branch or tag could shadow) only when that commit contains HEAD and is ahead and, checked again
   right before the merge, the folder is clean, on a branch, at the HEAD that was compared; otherwise
   why not (up to date, ahead, diverged, uncommitted changes, detached HEAD, changed while checking, no
   GitHub remote, fetch failed) is logged and returned in `result.sources: [{repo, remote?, ref?,
   commit?, fastForward, why?, new?} | {repo, cloned}]`. A configured upstream on the GitHub remote is
   followed by the pull (its branch is the user's choice). An update after a release install always
   builds (a release receipt's commit is only the installer's). The inputs (HEAD, dirty, fingerprint) are recorded. The catalog paths
   are snapshotted; an installed app without a bar.json entry gets its current bar state recorded
   there (so the installer's rewritten autostart file doesn't change it); a file at one of them that isn't the Manager's (per the receipt) is copied to
   `displaced/<app>/` first (`restore: true` when a receipt existed, `false` for files from before the
   Manager: those are most likely an earlier install of the same app).
2. **build** (cancellable): the component's install command runs from its repo folder through
   `setsid` (its own session and process group), stdin closed, with an explicit environment (no login
   shell): HOME, USER, LANG/LC_*, XDG_*, DISPLAY/WAYLAND_DISPLAY, DBUS_SESSION_BUS_ADDRESS, CARGO_HOME
   …; PATH = flutter's folder, `~/.cargo/bin`, then the core's PATH; FLUTTER per app (Theme the
   folder, Narrator/Video the executable); the catalog's own variables; `MAPRISMA_MANAGER_JOB`.
   stdout and stderr go to the log (4 MiB, then its last 256 KiB at the end) and to `lines(id)`.
3. **commit** (not cancellable): **the rule**: the stat signature of every catalog path (type, size,
   mode, mtime, ctime, link target) is compared every 150 ms; the first changed path starts the commit.
   `jobs.cancel` pauses the script's group (SIGSTOP), waits until every member is stopped (state `T`;
   not reached within 1 s → refused, fail closed) and compares once more: unchanged → TERM to the group
   (then SIGCONT; KILL to what is left 5 s after the cancel; the job ends when no member is left),
   changed → the group continues, the job enters its commit and the cancel is refused with
   `not_cancellable`. Group signals go out only while the group is still the script's (leader pid +
   start time, or members of the session it made). So a cancel never ends a script that has touched one of the
   app's files. At the commit (unless the installer does it itself: Launcher, Theme) the script is
   paused while the app's systemd user units are stopped (`systemctl --user stop`, when active) and then
   its processes (by `/proc/<pid>/exe` under its paths or its scripts' exact normalized path in argv;
   the user's own, not the job's group; TERM, 5 s, identity (start time) checked again, KILL); then it
   continues. A script that writes and ends between two polls has them stopped right after.
4. **verify**: the postconditions (`checkPath`); a missing optional part (Narrator's settings window
   without cmake) is `partial`, anything else failing is `verify_failed`.
5. **finish**: post steps (`gtk-update-icon-cache -q -t <data>/icons/hicolor`, `update-desktop-database
   -q <apps>`), the bar state from bar.json applied (`bar.apply`), the bar icon's old process ended
   (COSMIC: an applet of cosmic-panel running from before; the panel starts the new one) or the KDE tray
   started again (`setsid`, when its autostart file isn't hidden; kept stopped when it is), backups of
   files the script left as they were dropped, then the receipt written (below). Units stopped at the
   commit are started again (`systemctl --user start`, `result.unitsStarted`: Narrator's reader).
   Components run in dependency order (Launcher: `app`, then the COSMIC `applet`). A script that
   exits non-zero before the commit with the component's busy text in its output (Launcher's
   install-local: "is running a command in its terminal") fails with `app_busy`; `options.force`
   (Launcher only) passes `--force`, which ends that command.

A **release** job (`kind: release`, `options.tag?`; only apps whose catalog has a release spec:
Launcher, and Maprisma as below; other apps `unavailable`)
installs one component (Launcher: `app`) from a GitHub release instead of building: in **prepare** the
installer's folder is cloned when missing, the release is read (the tag asked for from GitHub, else the
latest from the cache, refreshed when older than 30 minutes; `no_release`, `github_failed`), its tarball
asset (`maprisma-launcher-<version>-x86_64.tar.gz`) and that name plus `.sha256` must exist (`no_asset`,
`no_checksum`), both are downloaded into `~/.cache/maprisma-settings/downloads/<org>_<name>/<tag>/`
(`.part`, renamed when complete; cancellable; `download_failed`), and the tarball's sha256 must be
the `.sha256` file's (whose file name, if any, must be the asset; `bad_checksum`, `checksum_mismatch`:
the download is deleted, nothing installed). Then the snapshot as above, the tarball is placed in the
repo's `dist/` with an mtime newer than every other `maprisma-launcher-*-x86_64.tar.gz` there (so the
script's `ls -t … | head -1` picks it; copied to a `.part` name and renamed; a different file of
that name is moved aside to `.<asset>.maprisma-settings-<job>`, recorded in the job's `dist` until it
is back), and **build** runs `tools/install-local --no-build`; afterwards (also on failure, and at once
when placing fails) a copy placed by the job is removed only while it is still that file (its sha256),
a moved one is put back only where the name is free (else both stay and the log says where), a reused
identical one gets its mtime back and a `dist/` made by the job is removed when empty. verify/finish as above; the
receipt's `source` is `{kind: release, tag, asset, sha256, url}`, the paths of the app's other
components (the COSMIC applet) and their inputs are carried over from the last receipt.

A failure leaves everything as it is (nothing is deleted, no receipt); `repair: true` when it had
reached the commit. Remove: **prepare** (the plan, `revision`, dependents need `dependents_ok`) →
**commit** (bar icon out of the panel/widget without changing bar.json, so a reinstall puts it back;
units and processes stopped; the plan's files deleted, each checked again; emptied folders below the
shared roots removed; displaced files with `restore` put back where the path is free; with
`delete_settings` the app's own data, never Omarchy-shared data) → **verify** → **finish** (post steps,
receipt dropped).

### Maprisma (pacman)

`maprisma` is the package `maprisma-bin` (`jobs_pacman.dart`). install/update/reinstall/release:

1. **prepare**: makepkg, pacman, pkexec and systemctl found (with a test root a system one is refused:
   `unsafe`). The
   source: `kind: release` or `options.source: release` → the GitHub release (`options.tag`, else the
   latest); `options.source: folder` → a folder build; otherwise the newer of the latest release and
   the folder's `MAPRISMA_VERSION` (`addons.py`), the release when both are the same (no folder or no
   release: the other one). `update` with the installed version at least that one: `up_to_date`,
   nothing built.
2. The archive: a release's tarball downloaded and checked as for the Launcher; a folder build checks
   `maprisma-addons/dist/adapters-<version>.zip` (`missing_addons`: the Manager doesn't sign add-ons),
   runs `python3 tools/build-release.py --addons <maprisma-addons>` (**build**, cancellable; it replaces
   `dist/maprisma-<version>-x86_64.tar.gz` and its `.sha256`, as the script always does) and takes the
   new tarball (its `.sha256` must match).
3. **build** (cancellable): the recipe `~/.cache/maprisma-settings/pkg/<version>/PKGBUILD` (the folder is
   made afresh; never through a link) modelled on aur-maprisma-bin: the same name, files,
   dependencies, provides/conflicts; `source=("maprisma-$pkgver-x86_64.tar.gz::file://<the archive>")`
   (an archive path with other characters is copied into the folder first), its sha256, `pkgver` = the
   version, `pkgrel` = one above the installed one for the same version, else 1. `makepkg --nodeps
   --noconfirm --cleanbuild --force` with PKGDEST/SRCDEST/BUILDDIR/… in that folder (`--nodeps`: the
   recipe has only runtime dependencies, which pacman checks when it installs); `makepkg --packagelist`
   names the package; `pacman -Qip` must say `maprisma-bin`, `<version>-<pkgrel>`, `x86_64`, and `pacman
   -Qlp` must list `/usr/lib/maprisma/maprisma`, `lib/maprisma-core`, `/usr/bin/maprisma`
   (`bad_package`).
4. **commit** (from here not cancellable): `/var/lib/pacman/db.lck` present → `pacman_locked` before
   anything is stopped. The provider service's state (active, enabled) is read, it is stopped
   (`systemctl --user stop`, when active), Maprisma's processes (exe under `/usr/lib/maprisma`) are
   stopped, then `pkexec /usr/bin/pacman -U --noconfirm <package>` runs: pkexec shows the password
   dialog; while the process is still named `pkexec` after `pkexecWait` (5 minutes) it is ended
   (`auth_timeout`); once it has become pacman (the same pid) it is waited for without a limit and
   never signalled (it runs as root). Exit 126/127: `auth_cancelled`; pacman's "unable to lock
   database": `pacman_locked`; else `pacman_failed`. On any of these (and on any exception) the
   service is started again; `repair` is false only for `auth_cancelled`, `auth_timeout` and
   `pacman_locked` (pacman changed nothing), true for any other failure. The job records `pkexec: {pid,
   start}`: when the Manager ends meanwhile, the interrupted job is `orphan` while that process (pkexec,
   or the pacman it became) lives, and every `jobs.start` is `busy` until it has ended; it is never
   signalled.
5. **verify**: `pacman -Q maprisma-bin` is `<version>-<pkgrel>`, `/usr/lib/maprisma/data/flutter_assets/version.json`
   says the version, the catalog's paths are there.
6. **finish**: the service is started when it was active or enabled (one that doesn't start is a
   warning and `result.unitsNotStarted`, not a failure); the receipt: `source` `{kind:
   release, tag, asset, sha256, url}` or `{kind: folder, archive: {file, sha256}}`, `package: {name,
   version, file, sha256, recipe}`, `inputs` (a folder build: both repos' commits; a release: the folder
   when there is one, else none), the catalog paths.

Remove: `apps.remove_plan` gives `goes: [{path: "maprisma-bin", kind: package, version}]`, `steps`
(stop and disable each unit, `pkexec /usr/bin/pacman -R --noconfirm maprisma-bin`), `data` (Maprisma's
own folders, only with `delete_settings`), `dependents` (Control); `blocked` when it isn't installed or
pkexec is missing. The job (lock checked, commit) stops and disables the provider service, stops the
processes, runs pkexec pacman -R; a cancelled dialog enables and starts the service again; verify:
`pacman -Q` finds nothing; then the settings (when asked) and the receipt go.

### `jobs.start` `{app, kind, options?}`

`options`: remove `{delete_settings?, dependents_ok?, revision?}`; release `{tag?}` (also accepted as a
top-level `tag`; `[A-Za-z0-9][A-Za-z0-9._+-]*`, else `bad_params`); install/update/reinstall of the
Launcher `{force?: bool}` (its install-local's `--force`; only when the user chose it; other apps:
`bad_params`); Maprisma `{source?: release/folder, tag?}`. Answers the job (short form) at once;
it runs in the background of the core. `unavailable` for an app not for this desktop.

### `jobs.get` `{id}` / `jobs.list` `{app?, limit?}`

The job (`jobs.get` adds `cancellable`), or `{jobs: [...]}` newest first in the short form
(`id, app, kind, state, phase, component, created, started, ended, committed, log, result`).

### `jobs.cancel` `{id}`

`{id, cancelled: true}` for a queued job, `{id, cancelling: true}` for one in prepare/build (it ends
with `state: cancelled`); `not_cancellable`, `finished`, `not_owner`.

### `jobs.log` `{id, from?}`

`{id, from, next, size, text, finished}`: the log from byte `from`, at most 256 KiB; while the job runs
the text ends at a full line (a line longer than one read comes in pieces, cut at a UTF-8 boundary).
Poll with `from = next`. In-process, `CoreService.jobs.lines(id)` streams
the lines and `jobs.done(id)` completes with the job.

## Self-update (the Manager, step 6)

The Manager's install/update/reinstall (`jobs_self.dart`) never touches the bundle it runs from:

1. **prepare** as for any app (an update pulls; nothing new → `up_to_date`); refused (`busy`) while the
   helper of an earlier self-update still runs.
2. **build** (cancellable): `tools/install-local --stage ~/.local/state/maprisma-settings/self-update/<job>`
   builds the Flutter bundle and the core CLI and copies them with `tools/install-local`,
   `tools/self-update` and the desktop entry and icon into that stage; nothing is installed.
3. The stage is checked: the bundle's program, `lib/libapp.so`, `lib/libflutter_linux_gtk.so`,
   `data/icudtl.dat`, `data/flutter_assets/version.json` (with a version), `bin/maprisma-settings-core`,
   the scripts and the packaging files; `ldd` finds every library; the new core answers `version`.
   Anything missing: `bad_stage`, the stage is deleted, nothing changed.
4. **commit**: the helper is copied to `self-update/helper` and started detached (`setsid`) with the
   pids (and start times) of the running Manager windows (`/proc/<pid>/exe` is the installed
   `maprisma-settings`). It writes `self-update/<job>.status` (`waiting|swapping|starting <pid>`, then
   `done`, `rolled back: …`, `failed: …`, `aborted: …`) and logs to `self-update/<job>.log`. It waits
   for those windows to quit (10 minutes, then `aborted`, nothing changed), copies the stage's bundle
   next to the installed one and swaps it in by rename (the old one kept as `maprisma-settings.old.*`),
   keeps copies of the desktop entry and icon and runs the stage's `install-local --integrate` (links,
   entry, icon). Then:
   - a window was open (`restart`): it starts the new Manager with `MAPRISMA_MANAGER_READY=<state>/<job>.ready`;
     the app writes its pid there after its first frame. No ready file within 20 s: the new build's
     processes are ended, the old bundle, entry and icon come back and the old Manager is started again.
     The job itself has already ended (`succeeded`, `result: {restart: true, selfUpdate: {state:
     waiting, waitFor, log}}`; the window that ran it quits after 1.5 s); the helper then runs
     `maprisma-settings-core self-update-done <job>` of the installed core (the new one: verify, receipt,
     `selfUpdate.state: done`) or, after a rollback, `self-update-done <job> --failed <why>` (the old one:
     the job becomes `failed`, `self_update_failed`).
   - no window (the CLI, a first install): the new core must answer `version` (else the rollback); the
     job waits for the helper and does **verify** and **finish** (receipt) itself.
5. The old bundle and the stage are deleted once the new one is ready.

### The rename from Maprisma Manager (2026-11-13)

Maprisma Settings was Maprisma Manager. The old names keep working:

| Old | New | How the old one keeps working |
| --- | --- | --- |
| `maprisma-manager`, `maprisma-manager-core`, `-applet`, `-tray` | `maprisma-settings`, `maprisma-settings-core`, … | links in the bundle and in `~/.local/bin`; the core answers `version` with the name it was started by |
| `com.maprisma.Manager` (app id, desktop entry, icon) | `com.maprisma.Settings` | a hidden (`NoDisplay`) `com.maprisma.Manager.desktop` that starts `maprisma-settings`; the old icon name is installed too |
| `~/.config`, `~/.local/state`, `~/.local/share`, `~/.cache`, `~/.local/lib` `/maprisma-manager` | `…/maprisma-settings` | renamed once (never copied) and a link of the old name left (`migrateLegacyFolders` at the core's start; `tools/procs.sh migrate_legacy` in install-local, uninstall-local and the self-update helper); when both exist the new one is used and the old one is left alone |
| catalog id `manager` | `settings` | `findApp`/`canonicalAppId` accept it (CLI, jobs, AI steps, old job files); the receipt, kept record, icon state, displaced files and `bar.json` wishes of the old id are moved to the new one once |
| repo folder `maprisma-manager` | may be renamed to `maprisma-settings` | `repoFolderAliases`: the catalog's folder name wins while it exists |
| `com.maprisma.Manager.Tray.desktop` (autostart) | `com.maprisma.Settings.Tray.desktop` | install-local replaces it, keeping a `Hidden=true` |

Kept as they were (ids other configs name): the bar icon's COSMIC applet id and icon name
(`io.github.ubruckhaus.CosmicMaprismaManager`), the tray's item id `maprisma-manager` (Maprisma Shell's
`bar.json`, the KDE widget), the `MAPRISMA_MANAGER_*` variables, the Dart packages
(`maprisma_manager_core`, `maprisma_manager`) and the window channel `maprisma-manager/window`.

A Manager from before the rename updates itself into this build: the stage has the old names it checks
(`bundle/maprisma-manager`, `bundle/bin/maprisma-manager-core`, `packaging/com.maprisma.Manager.*`), and
the new helper, started with `--lib ~/.local/lib/maprisma-manager`, renames the folders first and swaps
the bundle in under the new name.

The receipt is the usual one (the bundle as an owned folder, the links, the entry and icon); a job
finished by the helper is read from its file (`jobs.get` prefers the file for a finished job).

## Bar icons

### `icons.get` `{app, query?, limit?}`

```
{app, name, iconName, kdeIconName?, file, exists, sha256, changeable, why?, note?, shows: {cosmic, kde},
 current: original/changed/…, choice?: {kind: name/file, name?, theme?, from, sha256, at},
 original: {kept, file?, sha256?}, theme: {name, source, chain}, query, total, truncated,
 choices: [{name, file, theme}]}
```

Changeable only when the bar icon has a name of its own (`io.github.ubruckhaus.CosmicMaprisma*-symbolic`)
whose file (`<data>/icons/hicolor/scalable/apps/<name>.svg`) the app's installer writes; otherwise `why`
(Launcher's `com.maprisma.Launcher`, Theme's KDE tray `com.maprisma.Theme`, apps without a bar icon).
`note`/`shows` tell where a change is seen: WLAN Monitor's and Hue Lights' COSMIC applets draw a built-in
copy (`shows.cosmic: false`: the change shows in the KDE tray and the menus); Bluetooth's COSMIC panel
shows the connected device's kind; Narrator's KDE tray shows it while idle; Control's applet draws the
file in its own colours (Maprisma's logo; a symbolic icon shows dark grey there). The choices: every
`*-symbolic.svg` of the current icon theme (COSMIC: `com.system76.CosmicTk/v1/icon_theme`, default
`Cosmic`; KDE: `kdeglobals [Icons] Theme`, default `breeze`; other: GTK's), what it inherits (`Inherits=`,
at most 12) and hicolor, in `<data>/icons`, `~/.icons`, `XDG_DATA_DIRS/icons`; the first theme with a name
wins, a scalable one first; `query` matches part of the name (any case); `limit` 100, at most 500.

### `icons.set` `{app, icon}` / `icons.reset` `{app}`

`icon`: a theme icon's name (any `.svg` of the chain, symbolic or not) or an absolute path (`~/` allowed)
of an SVG file. It must be UTF-8 XML, at most 256 KiB, rooted in `<svg>` in the SVG namespace, without a
DOCTYPE/entities, processing instructions, `script`, `foreignObject`, `image`, `iframe`/`embed`/`object`,
`audio`/`video`, `a`, animation elements, `on*` attributes, `javascript:`, `@import`, CSS escapes (any
backslash in a style or attribute), and every `href` and `url(…)` must point inside the file (`#id`):
else `bad_icon` (nothing is changed). Refused while any job runs (`busy`: the change holds the jobs'
lock, so no job starts meanwhile) and for an app that isn't installed (`not_installed`). Under the state lock, each step
saved before the next: the file as it is now is kept as `~/.local/state/maprisma-settings/icons/<app>/original.svg`
unless it is ours (the recorded choice or `chosen.svg`) or already the original; then the choice goes to
`chosen.svg` and `icon.json`; then atomically over the app's file; and the receipt's entry for the file follows (so a remove still takes it). Then
`gtk-update-icon-cache -q -t <data>/icons/hicolor` and the bar icon: COSMIC: when the applet is in a
panel, its panel file is written without it and back with its exact bytes (the panel rebuilds and
starts the applet with the new icon; as after installs, never a panel restart); KDE: a running tray
that starts at login is ended and started again (`setsid`). `{app, iconName, file, choice, original,
iconCache, bar}`.

`icons.reset` writes `original.svg` back over the file when the file is ours (or missing; `changed` when
the original is missing then), drops the app's `icons/<app>/` folder, refreshes as above: `{reset: true, sha256}`, or `{reset: false, note}` when
there is nothing to reset.

After every install/update/reinstall/release of the app (finish, before the post steps): a choice is
written again over the installer's new file, which becomes the kept original (logged).

## Let AI do the updates (`ai.*`)

The **AI** page (sidebar, `--page ai`): **Helper** — the AI helper every Maprisma app uses
(Launcher, Theme, Playground, Notifier's *Check with AI* and the AI updates here; see "The shared
AI helper" below) — and **Let AI do the updates** (`ai_updates` in the Manager's settings, off by
default; it can only be switched on while a helper is ready). The helpers
are Maprisma Theme's Ask AI helpers (`lib/src/ai/ask_ai.dart`, copied): Claude Code, Codex, pi,
Hermes and pi's local models, each shown when installed and signed in, and every other agent of
Maprisma's helpers catalog (`lib/src/ai/helpers_catalog.dart`: `data/helpers.json`, or Maprisma's
`/usr/lib/maprisma/data/helpers.json` when it is at least as new) with an `ask` whose program is
installed (PATH, `~/.local/bin`, `~/.npm-global/bin`, else `mise which` for a command mise has a
shim for), in the catalog's order. Such an agent runs by the catalog's `ask` argv (the prompt as
one argument, its stdout the answer, the same folder, limits and time); its sign-in can't be told
(it counts as ready), and one with `verified: false` is labelled "(untested)" (`verified` in
`ai.helpers`). A saved helper that is unknown or no longer ready falls back to the first ready one.
After a newer Maprisma catalog: copy it to `packages/maprisma_manager_core/data/` and run
`tools/gen-helpers`. The toolbar's ✦ button
opens the AI dialog (Helper: [name ▾], Start/Stop, what the AI said and did).

The helper gets no tools (Codex: its read-only sandbox in a bubblewrap jail). Each round it gets
the apps' status (no paths) and the results of the steps so far, and answers with one JSON object
`{"say", "actions": [{"do", "app"}], "done"}`. The Manager checks every step and runs it itself:

| `do` | what the Manager does |
|---|---|
| `update` | the app's update job |
| `reinstall` | the app's reinstall job |
| `pub_get` | `flutter pub get` / `dart pub get` in the app's packages (pubspec.yaml up to 3 levels, not build output, hidden folders, links or pub workspace members), in its own process group; refused while a job for the app is queued or running |

Refused: any other step, unknown apps, apps not installed or not for this desktop, the Manager
itself (it has to quit to update) and pacman apps (Maprisma: they need the password). At most 5
answers, 6 steps per answer, 20 steps per run; the same step at most twice. Stop ends the helper,
a running `pub get` group and a job that can still be cancelled. Each run is saved as
`$XDG_STATE_HOME/maprisma-settings/ai/<id>.json`.

- `ai.helpers` → `{helpers: [{id, name, installed, signed_in, local, login, note, verified}], helper, auto, chosen, fallback, file, enabled, busy, web_search, web_search_supported, web_search_reason}`:
  `helper` the shared choice (`"auto"` or an id), `auto` the first ready helper, `chosen` the one
  an AI update uses (the shared choice when it is ready, else `auto`), `fallback` true when a chosen
  helper isn't ready (so `auto` is used), `file` the shared file; `web_search` the shared
  `web_search` key, `web_search_supported` whether `chosen` can search the web (it has a web-only
  mode; only Claude Code for now), `web_search_reason` why not (null when it can)
- `ai.set_helper` `{helper}` → as `ai.helpers`; `helper` is `"auto"` or an id matching
  `^[A-Za-z0-9][A-Za-z0-9._:/@+-]{0,160}$` (else `bad_params`; a write error: `write_failed`).
  The AI dialog's Helper: [name ▾] writes it too: there is one choice for all apps
- `ai.set_web_search` `{on}` → as `ai.helpers`; `on` a boolean (else `bad_params`; a write error:
  `write_failed`). Writes the shared `web_search` key (the AI page's *Let the AI helper search the
  web* switch)
- `ai.start` `{helper?}` → `{run}`; refused with `off`, `busy` or `unavailable` (no helper ready)
- `ai.get` → `{run}` (null before the first): `{id, helper, helperName, state: running|succeeded|failed|cancelled, phase: checking|asking|working|done, round, steps: [{kind: say|note|action, …}], message?}`
- `ai.cancel` → `{run}`

CLI: `ai-helpers`, `ai-update [<helper>]`.

### The shared AI helper (`maprisma-ai/settings.json`)

`${XDG_CONFIG_HOME:-$HOME/.config}/maprisma-ai/settings.json`, a JSON object; `"helper"` is
`"auto"` or a helper id as above (catalog ids such as `claude`, `codex`, `agy`; local models
`pi:<provider>/<model>`). A missing or broken file, or a missing or invalid value, means `"auto"`:
the first installed helper in the catalog's order that can do what the app needs (a one-shot
`ask` here and in Launcher/Theme/Playground, an interactive `task` for Notifier's crash check). A
chosen helper that isn't installed or can't do it falls back to auto. Every Maprisma app reads it
when it needs a helper and any app's own helper drop-down writes it. Writes keep unknown keys and
go through a temporary file in the same folder and a rename; the folder is 0700, the file 0600
(`lib/src/ai/shared_helper.dart`). Migration: while the file doesn't exist, the Manager seeds it
once from its old `ai_helper` setting when that is set and valid (the old key is no longer
written or offered; `settings.set` refuses it).

`"web_search"` (a boolean; missing or anything else means `false`, the default): whether the shared
helper may search the web when an app can't find something (Maprisma Launcher's Ask AI, e.g. an
app to install; more apps later). Only a helper with a web-only mode may do it: Claude Code with
only its WebSearch and WebFetch tools (`--tools WebSearch,WebFetch`, nothing else; `Helper.web` in
`lib/src/ai/ask_ai.dart`). Any other helper keeps no tools and the app doesn't search. The app
checks every result itself before it offers anything; the question and the helper's searches go to
the helper's provider. Written with the same atomic, key-keeping write as `helper`.

Notifications: the crash reports' helper is no longer a Notifier setting on this page
(`notifications.get` has no `ai_helpers`, `notifications.set` refuses `ai_helper`); *Check with
AI* uses the shared helper.

## Voice (`voice.*`)

The **Voice** page (sidebar after AI, `--page voice`): Maprisma Dictation's voice service
`maprisma-voice` (catalog id `dictation`, repo `maprisma/dictation`, installed by its
`install.sh`; its bar icon, a COSMIC applet and a tray on KDE and Hyprland, toggles the
dictation overlay `maprisma-dictation --toggle`). The Manager talks to it only through its command line
(`lib/src/voice.dart`): `~/.local/bin/maprisma-voice`, else the one on PATH, run with an argv
list (never a shell), at most 256 KB of output and a time limit (10 s; a download 2 h, a try its
length + 90 s, a wake test its length + 130 s). The service checks every value, so the rules live in one place
(maprisma-dictation's `docs/protocol.md`, settings in `~/.config/maprisma-voice/settings.json`).

- `voice.get` → `{installed, binary, install_url, status, status_error, models, settings, microphones, tasks}`:
  `status` is `maprisma-voice status --json` (null when the service doesn't answer; then
  `status_error` says why), `models` is `models --json` (`catalog`, `models`, `active`, `folder`),
  `settings` is `get` (only the keys that are set), `microphones` is `{default, sources: [{name,
  description}]}` from `pactl -f json` (monitors left out; empty without pactl). Without the
  binary only `installed: false`, `install_url`, `microphones` and `tasks`.
- `voice.status` → `{status, status_error}`: only `status --json` (the wake line's live
  refresh, every 3 s while `wake_enabled` is on).
- `voice.set` `{key, value}` → `maprisma-voice set KEY <value as JSON>`; `key` is one of
  `enabled`, `engine`, `model`, `language`, `microphone`, `unload_minutes`, `preload`,
  `wake_enabled`, `wake_phrase`, `wake_language`, `wake_model`, `wake_sensitivity` (booleans,
  0–1440, strings up to 200 characters; `wake_phrase` by the service's rule: 2–40 characters,
  letters, digits, spaces and `,.!?'-`, at least two letters or digits, no spaces at the ends;
  `wake_language` `auto` or a 2–3 letter code; `wake_model` empty or a model name;
  `wake_sensitivity` `strict|normal|loose`; else `bad_params`); the service's refusal (exit 2) is
  `bad_params` with its message, another failure `failed`; `not_installed` without the binary.
- `voice.unset` `{key}` → `unset KEY` (back to the default; Model › Automatic).
- `voice.download` `{model}` → `{task}`: `model download NAME` in the background (a catalog id;
  names `^[A-Za-z0-9][A-Za-z0-9._-]{0,80}$`); the percent comes from curl's progress bar on
  stderr, the path from stdout. One download at a time (`busy`).
- `voice.remove` `{model}` → `model remove NAME` (only the service's own models; refused with
  `busy` while that model downloads).
- `voice.try` `{seconds?}` → `{task}`: `dictate --seconds N` (1–30, default 5) in the
  background; stderr lines `… text` are the partial text, stdout the final text; exit 3 (no
  speech) and other failures end it `failed` with the service's last line. One try at a time.
- `voice.wake_test` `{seconds?}` → `{task}`: `wake test --seconds N --json` (1–10, default 8) in
  the background: the service listens once with the wake recogniser; nothing is started on a
  match. Exit 0 (match), 1 (no match) and 3 (no speech) end it `succeeded` with `result`
  `{heard, matched, score, needed, rest, phrase, model, speech}`; 4 (no service) or no readable
  answer `failed` with the service's last line. Refused (`busy`) while a try or another wake
  test runs (and a try while a wake test runs): one microphone test at a time.
- `voice.tasks` → `{download, dictate, wake}`, each null before the first, else `{kind, state:
  running|succeeded|failed|cancelled, model?, seconds?, started, ended?, progress (download),
  partial and text (dictate), result (wake), path?, message?}`; the page polls it while one runs.
- `voice.cancel` `{kind}` (`download`, `dictate` or `wake`) → SIGTERM to the command (the service's curl
  dies with it and a leftover `.part` is removed with `model remove`; a try's session is
  cancelled by the service when its client leaves); `finished` when nothing runs.

The page: Status (ready or the service's reason, engine and model in use; when it is missing,
Install through the Apps page's job and the GitHub link), Dictation (on/off, Engine: Automatic and
the five engines, those the service can't use disabled with why; Language: Automatic, the eight
languages, another Whisper code; Microphone: Default and the PipeWire inputs; Free GPU memory
after: never/5/10/30/60 minutes; Load the model at start), Wake phrase (on/off with the note that
the microphone stays open while it listens and only short stretches are turned into text
locally; the phrase, checked like the service and saved on Enter or when the field is left;
Language of the phrase: Automatic and the eight languages; Sensitivity strict/normal/loose;
Model: Smallest installed and the installed models; a live line from `wake_why_not` — listening
for the phrase, paused (dictation off, a session, an answer read aloud, just heard) or why not;
Try the phrase: 8 s, "Say your phrase now…", then what was heard, match or not and the score,
Cancel while it listens), Models (Automatic, the catalog with
Download/progress/Cancel, Use, Remove after asking, other installed models with Use only) and
Try it (5 s, the partial and the final text, shown only).

TODO (Maprisma Dictation steps 4 and 5): the overlay's key and mode (hold/toggle), its
animation, the Assistant options (key, speak answers, history and private mode, action levels,
the action log), Speech (Kokoro voice and speed) and "Use Maprisma Dictation for Omarchy's
dictation keys" are added to this page when the service has them; none is shown before.

## CLI

```
maprisma-settings-core status [--json] [--desktop cosmic|kde|other] [<id>]
maprisma-settings-core sources [--json]
maprisma-settings-core fetch [--force] [<id>]
maprisma-settings-core github [--force] [<id>]
maprisma-settings-core new [--json]
maprisma-settings-core clone-new <org/repo>
maprisma-settings-core bar [--json] [--panel <name>]
maprisma-settings-core bar <id> left|center|right|out [--index <n>] [--panel <name>]
maprisma-settings-core bar apply
maprisma-settings-core install|update|reinstall <id> [--force] [--source release|folder]
maprisma-settings-core release <id> [<tag>]
maprisma-settings-core remove <id> [--delete-settings] [--yes]
maprisma-settings-core icon <id> [<name>|<file>|--reset] [--search <text>] [--json]
maprisma-settings-core jobs [<app>]
maprisma-settings-core log <job>
maprisma-settings-core version
maprisma-settings-core self-update-done <job> [--failed <why>]
```

`install`/`update`/`reinstall` run the job in the CLI process and print its output; Ctrl-C cancels
(refused in the commit). Exit code 0 done, 1 failed, 130 cancelled. `remove` prints the plan and asks
(`--yes` without asking; without a terminal it needs `--yes`). `log` follows a running job's log.

`bar` prints the areas (`[wlan]` = ours, COSMIC's applets shortened: `Time`, `Power`) and the icons that
are out; `bar <id> <area>` places/moves it there (`out` takes it out) and prints the bar again.

`status` prints a table (ID, STATE, VERSION, SOURCE (folder / GitHub / both / -), BUILD, FOLDER,
UPSTREAM, BAR, RUN, NOTES: a newer release, `GitHub +N` or `diverged from GitHub` when the GitHub
remote isn't the upstream); `status <id>` adds per input the folder (path, branch, HEAD, clean), the
GitHub URL (public/private, which remote, the facts' age), the latest release with its URL and the
comparison with the GitHub branch; `--json` prints `apps.list` (or `apps.get` with an id). `sources`
lists every app and input with its folder (or `missing`), GitHub URL (or `local only`) and latest
release. `github` runs `github.refresh`. `new` lists `discovered.list` (folder, GitHub URL, the
`clone-new` command for a GitHub-only one, the org list's age); `clone-new` runs `discovered.clone`. `release` runs a release job like `install`. `icon <id>`
prints `icons.get` (40 choices, `--search` filters), `icon <id> <name|file>` runs `icons.set`, `--reset`
`icons.reset`.

## Receipts (written by install jobs after verify)

`~/.local/state/maprisma-settings/installed/<id>.json`:

```json
{"schema": 1, "id": "wlan", "at": "2026-11-09T10:00:00Z", "version": "…", "manager": "0.1.0",
 "job": "<job id>", "kind": "install", "components": ["main"], "partial": ["settings window"],
 "source": {"kind": "folder"},
 "inputs": [{"repo": "maprisma-wlan-monitor", "commit": "<sha>", "dirty": false, "fingerprint": "tree:<sha>"}],
 "paths": [{"path": "…", "sha256": "…", "mode": "755"}, {"path": "…autostart….desktop", "sha256": "…", "mode": "644", "normalized": "hidden"},
           {"path": "…", "link": "…"}, {"path": "…", "dir": true}],
 "displaced": [{"path": "…", "backup": "…/displaced/wlan/<hash>-<name>", "restore": true, "reason": "changed since the install"}]}
```

`fingerprint`: `tree:<HEAD's tree>` for a clean folder, else `dirty:<sha256 over HEAD and every
changed/untracked file's path and content hash>`. Every catalog path present after the install is
recorded (files with sha256 and mode, links with their target as written). `displaced/<app>/index.json`
keeps the backups across jobs (the oldest backup of a path wins).

`source` is `{"kind": "folder"}` for a build from the folder, `{"kind": "release", "tag", "asset",
"sha256", "url"}` for a release install (its `inputs` then name the folder whose installer ran); a
receipt without `source` (before step 4b) is a folder build.

A receipt whose `id` doesn't match its file name, with missing `at`/`inputs` (empty `inputs` only for a
release install: Maprisma's package without a folder), or a malformed `source`,
is reported in `build.error` and not trusted.

Owned folders (step 5a): `"trees": [{"root": "/home/u/.local/lib/maprisma-launcher", "files": 21, "links": 0,
"dirs": 8, "bytes": …, "entries": [{"p": "lib/libapp.so", "sha256": "…", "mode": "644"}, {"p": "x", "link": "…"},
{"p": "data", "dir": true}, …], "digest": "<sha256 of the entries' JSON>", "preexisting"?: true}]` (at most
20000 entries, else `{"root", "overflow": true, "files"}`; `__pycache__` left out); a receipt whose entries
aren't relative normalized paths or whose digest differs is broken. `"saved": {"plasmaTheme": "…"}` (Icons):
the Plasma style before a generated one, kept across reinstalls. A release install carries the other
components' trees over like their paths. Files inside an owned folder are never backed up to
`displaced/` (the installer replaces the folder as a whole).
