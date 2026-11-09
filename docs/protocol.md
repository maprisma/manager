# Maprisma Manager core: protocol

The UI talks to `packages/maprisma_manager_core` the way Maprisma Theme does: one JSON object per
request, one per answer (`CoreService.handleAsync`), or `CoreService.call(method, params)` in-process.

```
→ {"id": 1, "protocol": 1, "method": "apps.list", "params": {}}
← {"id": 1, "result": {...}}
← {"id": 1, "error": {"code": "bad_params", "message": "id"}}
```

Error codes: `unknown_route`, `bad_request` (not a valid frame), `bad_params`, `not_found`,
`request_too_large` (64 KiB), `response_too_large` (4 MiB), `internal`.

Step 1 is read-only: no route installs, removes, stops or writes anything, except `git.fetch`, which
updates the repos' remote-tracking refs and only when asked.

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
| `bar` | COSMIC: `{has, id, state: in/out/unknown, zone: left/center/right, error?}` (read from the `Panel` instance's `plugins_wings`/`plugins_center`; a file that doesn't parse gives `unknown` with the error). KDE tray: `{has, id, kind: tray, state, startsAtLogin, running}` (autostart file not `Hidden=true`; the tray process). `iconName` is the one the desktop shows (Theme's KDE tray: `com.maprisma.Theme`). KDE widget entry (Launcher): `state: unknown` until step 2. No icon: `{has: false, state: none}`. |
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

## CLI

```
maprisma-manager-core status [--json] [--desktop cosmic|kde|other] [<id>]
maprisma-manager-core fetch [--force] [<id>]
```

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
