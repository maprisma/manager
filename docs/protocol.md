# Maprisma Manager core: protocol

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
(an autostart file without `[Desktop Entry]`), `busy` (another Manager holds the state lock 10 s).

Only `git.fetch` (remote-tracking refs, when asked) and the `bar.*` changes write anything; nothing
installs, removes or stops processes yet.

## Environment

| Variable | Meaning |
| --- | --- |
| `HOME`, `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, `XDG_STATE_HOME`, `XDG_CACHE_HOME` | Every path (relative XDG values are ignored, as the spec says). Binaries are always `$HOME/.local/bin`. |
| `XDG_CURRENT_DESKTOP` | `COSMIC` → cosmic, `KDE` → kde, anything else → other. |
| `MAPRISMA_MANAGER_DESKTOP` | Overrides the desktop (`cosmic`, `kde`, `other`). |
| `MAPRISMA_PROJECTS` | The projects folder (the repos). |
| `MAPRISMA_FLUTTER` | Flutter: the executable or its folder. |
| `MAPRISMA_MANAGER_ROOT`, `MAPRISMA_MANAGER_PROC` | Tests only: the system root for `/usr`, `/etc` and the `/proc` to read. |

The projects folder: `MAPRISMA_PROJECTS`, else `projectsDir` in `~/.config/maprisma-manager/settings.json`,
else the first of `~/Projects`, `/mnt/Data/Projects` that holds a known repo, else the first that
exists, else `~/Projects`. Flutter: the `flutter` setting, `MAPRISMA_FLUTTER`, `PATH`,
`<projects folder>/../flutter`, `~/flutter`.

## Routes

### `core.hello`

`{version, protocol, desktop, projectsDir, projectsSource}`; `projectsSource` is `env`, `settings`,
`found` or `default`.

### `apps.list` `{desktop?}`

Everything the list page needs, for every catalog app. `desktop` shows it as another desktop would.

```
{desktop, projectsDir, projectsSource, flutter, flutterSource, apps: [App]}
```

App:

| Key | |
| --- | --- |
| `id`, `name`, `kind`, `desktops` | From the catalog. |
| `supportedHere` | The app runs on this desktop (Tiling/Icons: KDE only). |
| `state` | `installed`, `partial` (some postconditions fail, see the components), `absent`. Counts the components that apply to this desktop (Launcher's applet: COSMIC only). |
| `components[]` | `{id, name, repo, applies, state, packageVersion?, note?, failing: [{path, part, problem}], missingParts, prerequisitesMissing}`. `problem`: `missing`, `not a file`, `not a folder`, `not executable`, `not a link`, `points to …`, `dangling`. `missingParts`: parts with no path present (e.g. Narrator's `settings window` without cmake). |
| `build` | `{known, receipt?: {id, at, version?, inputs, paths, displaced}, error?}`; `known` = a valid receipt exists. |
| `updates` | The three facts: `buildUnknown` (installed, no receipt); `sourceDiffers` (`true`/`false`, `null` without a receipt) with `sourceReasons`; `upstreamNew` (commits the configured upstream has that HEAD hasn't, as of the last fetch; `null` = no input has an upstream) with `upstreamNotes` (diverged, dirty: no pull). |
| `versions` | `{installed, folder}` where known (pacman, a Flutter bundle's `version.json`; the repo's version line). |
| `repos[]` | Per input repo (`dirty` is `null` when git status failed; `error` says what could not be read): `{repo, folder, present, isRepo, branch, detached, head, dirty, dirtyTracked, untracked, upstream, upstreamRemote, upstreamUrl, ahead, behind, relation, lastFetch, error?, cloneUrl, available}`. `relation`: `upToDate`, `behind`, `ahead`, `diverged` (by ancestry), `unknown` (no upstream). `available`: `here`, `cloneable`, `not available here`. |
| `bar` | COSMIC: `{has, id, state: in/out/unknown, zone, panel, startsAtLogin, running, visible, error?}`: `zone`/`panel` where the applet is (every panel instance is looked at); in a panel = starts at login (cosmic-panel starts it); `running` = its applet program runs as a child of cosmic-panel; a file that doesn't parse gives `unknown` with the error. KDE tray: `{has, id, kind: tray, state, zone?, startsAtLogin, running, visible, where?}`: autostart file not `Hidden=true`; the tray process; `state: out` also when Maprisma Icons hides it; `visible` is `null` for a running tray in the system tray (it may sit in the overflow), `where: systemTray` without the widget. KDE widget entry (Launcher): `{kind: widgetEntry, state, zone?, visible}` from Maprisma Icons (`unknown` with `error` when plasmashell can't be asked). `iconName` is the one the desktop shows (Theme's KDE tray: `com.maprisma.Theme`). `wanted` is the app's entry in bar.json. No icon: `{has: false, state: none}`. |
| `running` | How many of the user's processes belong to it (by `/proc/<pid>/exe`, or the script path in argv for interpreted helpers). |
| `dependsOn`, `neededBy`, `env` | Dependencies; `env.FLUTTER` as the installer wants it (Theme: the folder, Narrator/Video: the executable; `PATH+` for those that take flutter from PATH). |

### `apps.get` `{id, desktop?}`

`{desktop, projectsDir, …, app}`: the App above plus `components[].{install, kind, desktops, checks,
prerequisites: [{command, found, path, part?, optional?, note?}], dependsOn, optionalParts, catalogNote}`,
`processes` (pid, exe, argv, match, startTicks), `processMatches`, `units` (`{name, runtime, unitFile, file,
enabledBy}`), `data` (`{path, exists, sharedWithOmarchy, neverDelete}`), `runtime` (files made at
runtime: `{path, exists, glob?, matches?, marker?, markedOurs?}`), `postSteps`, `barIcon`, `note`.

### `git.fetch` `{id?, force?}`

Fetches the configured upstream's remote of each input repo of app `id` (all apps without it). A repo
fetched within 30 minutes (`FETCH_HEAD`), or tried by this core process within 30 minutes, is skipped
unless `force` is `true`. Failed attempts are remembered in memory only (step 1 writes no state), so a
new CLI process retries an offline fetch. Inspection never uses a transport (`protocol.allow=never`,
no lazy fetch, no fsmonitor); only this route does.

`{force, repos: [{repo, fetched, skipped?: recent/no upstream/missing/not a repo, error?, behind?, relation?, lastFetch?}]}`

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
(`changed` otherwise), copied to `~/.local/state/maprisma-manager/backups/<time>-cosmic-<panel>/` (20 kept),
then each changed file is checked once more and written atomically (temp file + rename), the one that
loses an entry first; only changed lists are rewritten, in the file's own style, comments and unknown ids
kept. `reload`: `{panel, reacted: true}` when cosmic-panel started applets again (cosmic-panel 1.11 does
this by itself), else the panel is restarted once by its PID (`restarted`, `back`), `{panel: null, note}`
without a running panel. KDE: one `evaluateScript` compares the widget's config with what was read and
writes `zoneLeft/zoneCenter/zoneRight/hidden` as string lists (`currentConfigGroup = ['General']`,
`writeConfig`), each id in one zone only; the answer is read back and checked. Autostart files are backed
up and written atomically. Starting and stopping KDE trays comes with the job engine (step 3).

Every change of one of our icons is recorded in `~/.local/state/maprisma-manager/bar.json`:
`{"cosmic": {"wlan": {"placed": true, "area": "center", "index": 4}, "home": {"placed": true, "area": "center", "index": 1, "panel": "Dock"}}, "kde": {"launcher": {"placed": false}}}`.
`panel` / `widget` are kept when the change named one; without, the default panel/widget (and, for a
removal on COSMIC, every panel). A whole change (read, write, bar.json) holds the state lock
(`~/.local/state/maprisma-manager/lock`, plus an in-process queue).

### `bar.apply` `{}`

Puts the wanted state (bar.json) back for this desktop in one write per panel and one reload: an icon
not in its wanted area is placed at its wanted index, in the panel/widget it was put into (gone: the
default one); one wanted out is taken out (KDE: hidden + autostart
flag). Icons already in their area stay where they are. Used after installs (step 3). `{changed: [app ids], reload?}`.

## CLI

```
maprisma-manager-core status [--json] [--desktop cosmic|kde|other] [<id>]
maprisma-manager-core fetch [--force] [<id>]
maprisma-manager-core bar [--json] [--panel <name>]
maprisma-manager-core bar <id> left|center|right|out [--index <n>] [--panel <name>]
maprisma-manager-core bar apply
```

`bar` prints the areas (`[wlan]` = ours, COSMIC's applets shortened: `Time`, `Power`) and the icons that
are out; `bar <id> <area>` places/moves it there (`out` takes it out) and prints the bar again.

`status` prints a table (ID, STATE, VERSION, BUILD, FOLDER, UPSTREAM, BAR, RUN, NOTES); `--json` prints
`apps.list` (or `apps.get` with an id).

## Receipts (read in step 1, written from step 3)

`~/.local/state/maprisma-manager/installed/<id>.json`:

```json
{"id": "wlan", "at": "2026-11-09T10:00:00Z", "version": "…",
 "inputs": [{"repo": "maprisma-wlan-monitor", "commit": "<sha>", "dirty": false, "fingerprint": "…"}],
 "paths": [{"path": "…", "sha256": "…"}, {"path": "…", "link": "…"}, {"path": "…", "dir": true}],
 "displaced": [{"path": "…", "backup": "…"}]}
```

A receipt whose `id` doesn't match its file name, or with missing `at`/`inputs`, is reported in
`build.error` and not trusted.
