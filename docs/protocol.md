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
(an autostart file without `[Desktop Entry]`), `busy` (another Manager holds the state lock 10 s, or
runs a job; a job for that app is already queued); for jobs: `unsupported_yet` (the app's install or
remove needs a step of its own that comes later; the catalog says why), `not_cancellable` (the job is
in its commit phase, or its script has started writing the app's files), `finished`, `not_owner` (the
job runs in another Manager process: only that one can cancel it).

Writes: `git.fetch` (remote-tracking refs, when asked), the `bar.*` changes, and the jobs
(`jobs.start`: install, update, reinstall, remove). `apps.list` / `apps.get` / `jobs.*` reads mark
an unfinished job of a Manager that is gone as `interrupted` in its state file.

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
| `support` | `{install, remove, note?}`: whether jobs can install/remove it yet (`false` → `unsupported_yet`). |
| `job`, `repair` | The app's latest job (the `jobs.list` form, null without one); `repair: true` after an interrupted job or a failed one that had started writing: offer Repair (= reinstall). |

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

### `apps.remove_plan` `{id, delete_settings?}`

What a remove would do, before anything is touched (the remove job plans again and deletes only what
its plan says; pass `revision` to refuse a plan that changed since it was shown):

```
{app, name, receipt: valid/none/broken, receiptError?, verified, revision,
 goes:  [{path, kind: file/link/dir, sha256?/link?, normalized?, onlyIfEmpty?, unverified?}],
 stays: [{path, why}],            changed since the install / not what the Manager installed / not in the receipt / …
 data:  [{path, goes, why?}],     user data: goes only with delete_settings; Omarchy-shared data never
 runtime: [{path, why}],          made at runtime: not removed by this step
 restores: [{path, backup, reason}], backupsKept: [...],
 dependents: [{id, name}], units, running, bar: {has, id?, takenOut?}, postSteps}
```

With a valid receipt, a file goes only while its sha256 is the receipt's (an autostart file's
`Hidden=` line left out: hiding the icon is not a change), a link only while it points where it did
(unlinked, never followed), a folder only when empty; catalog paths not in the receipt stay. Without
a receipt (installed before the Manager, or a broken one) the catalog's paths go, each marked
`unverified`; a link only when it points where the installer points it. Refused with `unsupported_yet`
for Maprisma (pacman), Narrator (reader runtime), Tiling (Krohnkite migration), Icons (generated
Plasma themes), Launcher, Theme and Video Translator (their Flutter bundles need whole-tree ownership
in the receipt first) and the Manager (step 6).

Never touched: a path outside the shared install folders (`~/.local/bin`, `~/.local/lib`, the data,
config, applications, icons, autostart … folders) or reached through a symlinked folder below them
(checked in the plan and again right before each delete). Paths a remove kept are recorded in
`kept/<app>.json`; a later remove without a receipt never takes them while they are unchanged (an
install clears the record). Displaced files are put back only at the app's catalog paths, when the
backup's sha256 still matches.

## Jobs

One job at a time: a queue in the core process and an fcntl lock on
`~/.local/state/maprisma-manager/jobs/lock` held while the queue runs, so a second Manager or the CLI
gets `busy`. Every job's state is `jobs/<id>.json`, its log `logs/<id>.log` (100 finished jobs kept).

```
{id: "20261109T101500Z-wlan-install", app, kind: install/update/reinstall/remove, options,
 state: queued/running/succeeded/failed/cancelled/interrupted, phase: queued/prepare/build/commit/verify/finish,
 component?, created, started?, ended?, finished?, committed, owner: {pid, start}, script?: {pid, pgid, start},
 log, stopped?: [{pid, exe, result}], units?, warnings?, result?: {ok, code?, message?, repair?, partial?, …}}
```

An unfinished job whose owner (pid + start time) is gone is `interrupted` (`repair: true` unless it was
still queued); if its script still runs it gets SIGCONT (it may have been paused at the commit) and
`orphan: true`, and every `jobs.start` is `busy` until it has ended.

Phases of install/update/reinstall:

1. **prepare** (cancellable): dependencies installed, prerequisites found (a missing one of an
   optional part is a warning), every input repo present with a commit; for `update` only: `git pull
   --ff-only` when the repo is clean, behind and has an upstream (otherwise the reason is logged and
   the folder is built as it is). The inputs (HEAD, dirty, fingerprint) are recorded. The catalog paths
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
   files the script left as they were dropped, then the receipt written (below).

A failure leaves everything as it is (nothing is deleted, no receipt); `repair: true` when it had
reached the commit. Remove: **prepare** (the plan, `revision`, dependents need `dependents_ok`) →
**commit** (bar icon out of the panel/widget without changing bar.json, so a reinstall puts it back;
units and processes stopped; the plan's files deleted, each checked again; emptied folders below the
shared roots removed; displaced files with `restore` put back where the path is free; with
`delete_settings` the app's own data, never Omarchy-shared data) → **verify** → **finish** (post steps,
receipt dropped).

### `jobs.start` `{app, kind, options?}`

`options`: remove `{delete_settings?, dependents_ok?, revision?}`. Answers the job (short form) at once;
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

## CLI

```
maprisma-manager-core status [--json] [--desktop cosmic|kde|other] [<id>]
maprisma-manager-core fetch [--force] [<id>]
maprisma-manager-core bar [--json] [--panel <name>]
maprisma-manager-core bar <id> left|center|right|out [--index <n>] [--panel <name>]
maprisma-manager-core bar apply
maprisma-manager-core install|update|reinstall <id>
maprisma-manager-core remove <id> [--delete-settings] [--yes]
maprisma-manager-core jobs [<app>]
maprisma-manager-core log <job>
```

`install`/`update`/`reinstall` run the job in the CLI process and print its output; Ctrl-C cancels
(refused in the commit). Exit code 0 done, 1 failed, 130 cancelled. `remove` prints the plan and asks
(`--yes` without asking; without a terminal it needs `--yes`). `log` follows a running job's log.

`bar` prints the areas (`[wlan]` = ours, COSMIC's applets shortened: `Time`, `Power`) and the icons that
are out; `bar <id> <area>` places/moves it there (`out` takes it out) and prints the bar again.

`status` prints a table (ID, STATE, VERSION, BUILD, FOLDER, UPSTREAM, BAR, RUN, NOTES); `--json` prints
`apps.list` (or `apps.get` with an id).

## Receipts (written by install jobs after verify)

`~/.local/state/maprisma-manager/installed/<id>.json`:

```json
{"schema": 1, "id": "wlan", "at": "2026-11-09T10:00:00Z", "version": "…", "manager": "0.1.0",
 "job": "<job id>", "kind": "install", "components": ["main"], "partial": ["settings window"],
 "inputs": [{"repo": "maprisma-wlan-monitor", "commit": "<sha>", "dirty": false, "fingerprint": "tree:<sha>"}],
 "paths": [{"path": "…", "sha256": "…", "mode": "755"}, {"path": "…autostart….desktop", "sha256": "…", "mode": "644", "normalized": "hidden"},
           {"path": "…", "link": "…"}, {"path": "…", "dir": true}],
 "displaced": [{"path": "…", "backup": "…/displaced/wlan/<hash>-<name>", "restore": true, "reason": "changed since the install"}]}
```

`fingerprint`: `tree:<HEAD's tree>` for a clean folder, else `dirty:<sha256 over HEAD and every
changed/untracked file's path and content hash>`. Every catalog path present after the install is
recorded (files with sha256 and mode, links with their target as written). `displaced/<app>/index.json`
keeps the backups across jobs (the oldest backup of a path wins).

A receipt whose `id` doesn't match its file name, or with missing `at`/`inputs`, is reported in
`build.error` and not trusted.
