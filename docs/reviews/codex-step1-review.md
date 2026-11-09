# Codex review of step 1 (commit 4d5f050), with what was done

Run read-only (`codex exec -s read-only`), 2026-11-09. Every finding was checked in the code and the
sources before fixing. Responses are at the end.

## Review

Reviewed commit `4d5f050` and the requested documents against local installers and sources. No files modified; tests were inspected, not executed.

1. **High — Command timeouts can hang indefinitely.** [run.dart:60](/mnt/Data/Projects/maprisma-manager/packages/maprisma_manager_core/lib/src/run.dart:60) sends TERM, then awaits exit without another deadline. A process ignoring TERM hangs forever. Even normal exit can hang at line 64 if a child retains stdout/stderr. **Fix:** bound termination and stream draining, escalate to KILL after a grace period, and manage child processes as a group.

2. **Medium — Tests inherit Git variables that can redirect writes outside temporary HOME.** [support.dart:89](/mnt/Data/Projects/maprisma-manager/packages/maprisma_manager_core/test/support.dart:89) calls `Process.runSync` with parent-environment inheritance enabled. Inherited `GIT_DIR`/`GIT_WORK_TREE` can redirect `add` and `commit` into another checkout; `GIT_CONFIG_COUNT` can inject hooks or URL rewriting affecting pushes. **Fix:** use `includeParentEnvironment: false`, an explicit executable/environment, and restrict test transports to local files.

3. **Medium — Read-only status does not prevent Git-triggered side effects.** [git.dart:78](/mnt/Data/Projects/maprisma-manager/packages/maprisma_manager_core/lib/src/git.dart:78) disables optional locks and prompts, but not configured fsmonitor commands or lazy fetching. `git status` can execute a configured fsmonitor helper; ancestry traversal in a partial clone can fetch missing objects. **Fix:** disable fsmonitor for inspection and prohibit lazy fetching/network transports on read-only commands; permit transports explicitly only for `git.fetch`.

4. **Medium — Narrator’s runtime/config paths are wrong with XDG overrides.** [catalog.dart:382](/mnt/Data/Projects/maprisma-manager/packages/maprisma_manager_core/lib/src/catalog.dart:382) uses `{config}/kindle-reader`; lines 385–386 and `UnitRef` resolve the service through `{units}`. Actual code hardcodes `$HOME/.config`: [setup_backend.py:19](/mnt/Data/Projects/maprisma-narrator/backend/setup_backend.py:19), [bridge.py:176](/mnt/Data/Projects/maprisma-narrator/backend/bridge.py:176). With `XDG_CONFIG_HOME` set, Manager misses the real settings, service and drop-in. **Fix:** model these as `{home}/.config/...`, including the unit discovery path.

5. **Medium — Launcher’s generated KDE desktop entries use the wrong data root.** [catalog.dart:213](/mnt/Data/Projects/maprisma-manager/packages/maprisma_manager_core/lib/src/catalog.dart:213) uses `{homeShare}/applications/maprisma-launcher-*.desktop`. Unlike its installer outputs, runtime shortcuts use `desktopDirectories(session).first`: [shortcuts_kde.dart:241](/mnt/Data/Projects/maprisma-launcher/packages/maprisma_launcher_core/lib/src/shortcuts_kde.dart:241), respecting the runtime applications directory. **Fix:** use `{apps}` for generated shortcuts; retain `{homeShare}` for install-local’s hardcoded outputs.

6. **Medium — Incomplete installations can pass all postconditions.** [catalog.dart:186](/mnt/Data/Projects/maprisma-manager/packages/maprisma_manager_core/lib/src/catalog.dart:186) accepts an empty Flutter-assets directory; Theme, Narrator and Video omit equivalent bundle checks. Backend directories at lines 369/435 and KDE package directories at lines 496/531 also pass when empty. Launcher additionally omits the installed `maprisma-launcher-windows` helper, explicitly bundled by [build-release.py:65](/mnt/Data/Projects/maprisma-launcher/tools/build-release.py:65); Theme omits its installed templates. **Fix:** check required entrypoint files, helper executables, Flutter libraries/assets and package metadata/content, so these cases report `partial`.

7. **Medium — Missing source is reported as matching the installed build.** [status.dart:249](/mnt/Data/Projects/maprisma-manager/packages/maprisma_manager_core/lib/src/status.dart:249) adds “no repo to compare” but leaves `sourceDiffers=false`. Consequently a valid receipt plus a missing/non-repository folder displays `FOLDER same`. **Fix:** return unknown (`null`) when comparison is unavailable, preserving `true` if another input demonstrably differs.

8. **Medium — Git inspection failures become clean/diverged facts.** [git.dart:104](/mnt/Data/Projects/maprisma-manager/packages/maprisma_manager_core/lib/src/git.dart:104) consumes status output without checking success, so a failed status command becomes `dirty=false`. Lines 133–139 treat every nonzero ancestry result—including errors/timeouts—as “not ancestor”, potentially reporting `diverged`. [status.dart:266](/mnt/Data/Projects/maprisma-manager/packages/maprisma_manager_core/lib/src/status.dart:266) then converts unknown counts to zero. **Fix:** distinguish ancestry exit codes 0/1 from errors, propagate inspection errors, and preserve unknown cleanliness/update counts.

9. **Medium — Failed-fetch throttling disappears between CLI invocations.** [core.dart:103](/mnt/Data/Projects/maprisma-manager/packages/maprisma_manager_core/lib/src/core.dart:103) relies on in-memory `fetchAttempts` when `FETCH_HEAD` remains old after failure. Each CLI invocation constructs a fresh service, so repeated offline fetch commands retry immediately, violating the documented 30-minute attempt throttle. **Fix:** persist attempt timestamps under Manager state and coordinate concurrent fetch requests.

10. **Medium — Process matching accepts ordinary file arguments and misses symlinked installations.** [procs.dart:93](/mnt/Data/Projects/maprisma-manager/packages/maprisma_manager_core/lib/src/procs.dart:93) treats any absolute argument as an executed script: an editor opening a collector file counts as that app. Exact executable comparisons at line 81 also fail when `/proc/exe` resolves a symlinked install directory to its physical location. **Fix:** validate interpreter/script argument positions and canonicalize existing install roots, retaining lexical fallback for deleted executables.

11. **Medium — Broken receipts can still establish a “known” build.** [receipts.dart:61](/mnt/Data/Projects/maprisma-manager/packages/maprisma_manager_core/lib/src/receipts.dart:61) accepts missing/null commits, empty repository names and duplicate inputs. Lines 66–69 accept ownership entries containing only `path`, without a hash/link/directory discriminator or displaced backup. These receipts become `build.known=true`. **Fix:** validate the receipt schema and input identity/uniqueness, require usable provenance, and validate ownership-entry variants before trusting the receipt.

12. **Low — Theme’s catalog icon name does not describe its KDE tray.** [catalog.dart:275](/mnt/Data/Projects/maprisma-manager/packages/maprisma_manager_core/lib/src/catalog.dart:275) supplies the COSMIC symbolic name for both desktops. The KDE daemon publishes `com.maprisma.Theme`: [daemon.dart:163](/mnt/Data/Projects/maprisma-theme/packages/maprisma_theme_core/lib/src/daemon.dart:163). **Fix:** store separate COSMIC/KDE icon names and return the desktop-specific value.

13. **Low — COSMIC parse errors silently become “out of the bar”.** [bar_read.dart:34](/mnt/Data/Projects/maprisma-manager/packages/maprisma_manager_core/lib/src/bar_read.dart:34) records a parse error, but line 93 discards it and reports `out`. The scanner also interprets brackets/quotes inside RON comments as actual entries. **Fix:** propagate an unknown/error bar state and tokenize comments correctly; full instance discovery/writing can remain in step 2.
## Responses

1. **Holds, fixed.** `Runner.run` now escalates TERM → KILL after 2 s and stops waiting for the output
   pipes 2 s after exit (a child keeping them open no longer holds the answer). Process groups come
   with the job engine (step 3); step 1 only runs git and `pacman -Q`.
2. **Holds, fixed.** The tests' git runs with `includeParentEnvironment: false`, only PATH, an
   isolated config, `GIT_ALLOW_PROTOCOL=file`; the core under test gets the same.
3. **Holds, fixed.** Inspection runs `git -c core.fsmonitor=false -c protocol.allow=never` with
   `GIT_NO_LAZY_FETCH=1`; only `git.fetch` may use a transport.
4. **Holds, fixed.** Narrator's `kindle-reader` config, `ocrvox.service` and its drop-in are
   `{home}/.config/…` in the catalog; `UnitRef` got a `file` for units outside `{units}`.
5. **Holds, fixed.** Launcher's runtime shortcuts are `{apps}/maprisma-launcher-*.desktop`.
6. **Holds, fixed.** Postconditions now include Launcher's `maprisma-launcher-windows`,
   `lib/libapp.so` and `version.json`; Theme's `lib/libapp.so` and `templates`; Narrator's and Video's
   bundle `lib/libapp.so` (in their optional parts) and backend entry files; the KWin scripts' and the
   plasmoid's `metadata.json` and main QML instead of bare folders. All still pass on this machine.
7. **Holds, fixed.** With a receipt but no repo to compare (and nothing provably different),
   `sourceDiffers` is `null`; tested.
8. **Holds, fixed.** A failed `git status` leaves `dirty` `null` (never "clean"); ancestry uses exit
   codes 0/1 only, anything else is `relation: unknown` with `error`; unknown counts stay unknown in
   `upstreamNew` (noted in `upstreamNotes`).
9. **Holds, not fixed in step 1, documented.** Persisting attempts means writing
   `~/.local/state/maprisma-manager`, which step 1 must not do; the UI keeps one core process, so its
   in-memory attempts throttle it. The persisted state comes with the job engine (step 3).
10. **Holds, fixed.** A script matches only as the first non-option argument of an interpreter
    (`python*`, `bash`, `sh`, `dash`, `zsh`); match paths are tried lexically and resolved (symlinked
    HOME or install folder). Tested with `nvim -R <script>`, `cat … <script>`, a symlinked `~/.local/lib`.
11. **Holds, fixed.** Receipts need a 40/64-hex commit, a non-empty unique repo per input, each owned
    path exactly one of `sha256` (64 hex) / `link` / `dir: true`, and a `backup` for each displaced path.
12. **Holds, fixed.** `BarIcon.kdeIconName` (`com.maprisma.Theme`, from `daemon.dart`); the bar state
    returns the desktop's icon name. The other trays use the same name as their applet.
13. **Holds, fixed.** A panel file that doesn't parse gives `state: unknown` with the error; `//` and
    nested `/* */` comments are skipped. Panel instance discovery stays in step 2.
