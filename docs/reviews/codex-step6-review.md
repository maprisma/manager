# Codex review of step 6 (the Flutter app, self-update, install-local; commits 623a496, 9eb5fba, beb1a36), with what was done

Run read-only (`codex exec -s read-only`), 2026-11-09. Every finding was checked in the code before
fixing. Responses are at the end.

## Review

Found ten actionable issues, ordered by severity. Review was read-only; no builds, tests, installers, or process-changing commands were run.

1. **P1 — Failed renames can leave the Manager uninstalled, with rollback unable to restore it.**  
   [tools/self-update:143](/mnt/Data/Projects/maprisma-manager/tools/self-update:143) does not check either swap rename. If moving the old bundle succeeds but placing the new bundle fails, execution continues with `$lib` missing. Rollback then requires moving that missing `$lib` before restoring `$prev`, so restoration never happens. Nevertheless, it reports “the old build is back.” The default installer has a similar restoration gap at [tools/install-local:105](/mnt/Data/Projects/maprisma-manager/tools/install-local:105).  
   **Fix:** check every rename, track which steps succeeded, and restore `$prev` directly when `$lib` is absent. Preserve recovery artifacts until restoration is verified.

2. **P1 — Symlinked install paths bypass the wait for the running Manager.**  
   [jobs_self.dart:128](/mnt/Data/Projects/maprisma-manager/packages/maprisma_manager_core/lib/src/jobs_self.dart:128) compares `/proc/<pid>/exe` against one lexical path. With a symlinked HOME or `.local/lib`, `/proc` reports the resolved path, so `waitFor` is empty: the helper swaps immediately and does not restart the window. The shell process scans have the same lexical-path problem.  
   **Fix:** match both lexical and canonical install paths, as the existing generic process matcher does. Require usable PID/start identities for every detected window.

3. **P1 — Automatic self-update restart abandons subsequent queued jobs.**  
   [apps_page.dart:134](/mnt/Data/Projects/maprisma-manager/flutter_app/lib/apps_page.dart:134) schedules unconditional process exit after 1.5 seconds. Meanwhile, the core’s queue immediately advances after the self-update staging job succeeds. A queued install/remove can therefore be running when the UI exits, losing its supervisor; remaining queued jobs never execute.  
   **Fix:** make self-update handoff a queue barrier. Drain previously accepted work before handing over, refuse new work during handoff, and exit only when the core confirms it is safe.

4. **P1 — Uninstall can race with the detached helper and delete its rollback bundle.**  
   [tools/uninstall-local:41](/mnt/Data/Projects/maprisma-manager/tools/uninstall-local:41) deletes the installed bundle and every `.new.*`/`.old.*` sibling without coordinating with the helper. The helper is Bash outside those directories, so uninstall’s process scan leaves it running. It can subsequently reinstall the Manager, or lose its only rollback copy while waiting for readiness. Default installation is likewise uncoordinated.  
   **Fix:** use one persistent transaction lock shared by the helper, default installation, and uninstall. Refuse conflicting operations while a handoff is active.

5. **P2 — Integration failure still commits the update and destroys the previous bundle.**  
   [tools/self-update:149](/mnt/Data/Projects/maprisma-manager/tools/self-update:149) only logs a failed `--integrate`. A directly launched GUI can still signal ready, after which the helper deletes the previous bundle. `self-update-done` may then detect missing links or desktop files, but rollback is already unavailable.  
   **Fix:** treat integration as a required transaction step; roll back on failure and retain the previous bundle through final verification.

6. **P2 — Failed outcome recording becomes permanent false success.**  
   [tools/self-update:83](/mnt/Data/Projects/maprisma-manager/tools/self-update:83) logs and ignores `self-update-done` failure, then writes `done` and removes recovery artifacts. The persisted job can remain `succeeded` with `selfUpdate.state: waiting` and an obsolete receipt. One trigger is closing the captured window before the originating job has persisted its result: `finishSelfUpdate` rejects a job without a result map.  
   **Fix:** acknowledge handoff before allowing the original job/window to finish; retry outcome recording and reconcile terminal helper statuses on subsequent core startup. Do not declare completion until recording succeeds.

7. **P2 — Bar dragging mounts the same GlobalKey multiple times.**  
   [bar_editor.dart:186](/mnt/Data/Projects/maprisma-manager/flutter_app/lib/bar_editor.dart:186) uses the same keyed `body` for drag feedback and `childWhenDragging`. During dragging both are mounted, causing duplicate-GlobalKey failures and potentially reparenting the render object used for drop-position measurements.  
   **Fix:** build independent, unkeyed feedback and placeholder widgets. Keep the measurement key exclusively on the chip in the bar.

8. **P2 — Process termination does not revalidate PID identity.**  
   [tools/install-local:100](/mnt/Data/Projects/maprisma-manager/tools/install-local:100), [tools/uninstall-local:33](/mnt/Data/Projects/maprisma-manager/tools/uninstall-local:33), and [tools/self-update:157](/mnt/Data/Projects/maprisma-manager/tools/self-update:157) collect numeric PIDs and later signal them without checking start time again. A process exiting and its PID being reused between scan and signal can cause TERM/KILL to hit an unrelated process.  
   **Fix:** capture PID/start time together and revalidate identity, ownership, and executable immediately before each signal; preferably use pidfds.

9. **P2 — `apps.open` escapes the configured test root.**  
   [core.dart:84](/mnt/Data/Projects/maprisma-manager/packages/maprisma_manager_core/lib/src/core.dart:84) expands catalog placeholders but does not root system paths. Maprisma’s `/usr/bin/maprisma` therefore resolves to the host executable even with `MAPRISMA_MANAGER_ROOT` set. The detached launch also retains the desktop session environment. Status can incorrectly advertise this host executable as openable.  
   **Fix:** resolve system executables through `Paths.sys` in both status and launch, and fail closed on host launch tools under a test root unless explicitly injected.

10. **P3 — Row activation differs from Launcher’s Plugins page.**  
    [apps_page.dart:415](/mnt/Data/Projects/maprisma-manager/flutter_app/lib/apps_page.dart:415) opens Details on row click; Launcher’s corresponding row opens the plugin. This changes the primary interaction despite the stated parity requirement.  
    **Fix:** invoke `apps.open` for openable rows and retain Details in the actions menu.

I found no additional concrete issue in `desktop_look.dart` or `links.open` URL validation. The bar move/index calculations correctly account for removal of the moving icon. Removal confirmation passes the selected plan’s revision and app identity correctly; I found no wrong-target removal in that UI flow. I found no direct leak into the real HOME in the inspected self-update test setup; finding 9 concerns host executable/session isolation.
## Responses

1. **Holds, fixed.** Every rename in `tools/self-update` is checked: a failed move aside or into place
   puts the old bundle back (or says where it is and fails), the rollback moves `$lib` aside only when
   it exists and reports success only after the old bundle is back in place. `tools/install-local`'s
   default swap puts the old bundle back when the new one can't be moved in.
2. **Holds, fixed.** The windows to wait for are matched by the bundle path as written and as /proc
   reports it (the parent resolved), and only with a start time. The scripts' process scans
   (`tools/procs.sh`, shared by all three) match both forms as well.
3. **Holds, fixed.** While a self-update waits to be swapped in, `jobs.start` refuses every job
   (`busy`: "close Maprisma Manager to finish it"); jobs the window had already started run to their
   end and the window quits only then (it waits for its own jobs). Tested (core).
4. **Holds, fixed.** One lock (`~/.local/state/maprisma-manager/self-update/lock`, `flock`): the helper
   holds it from start to end; `install-local` (default) and `uninstall-local` refuse while it is held,
   and a helper that can't get it changes nothing (`aborted`). Tested with another holder.
5. **Holds, fixed.** `install-local --integrate` failing rolls back before the new build starts; the
   old bundle is deleted only after the outcome is recorded. Tested (core).
6. **Holds, fixed.** `self-update-done` is tried three times; when it still fails the old bundle is kept
   and the status says so (`done: the outcome could not be recorded …`). `self-update-done` also finishes
   a job whose window closed before it wrote its result (an `interrupted` job with a waiting
   self-update becomes `succeeded`). Tested.
7. **Holds, fixed.** The measuring GlobalKey is only on the chip in the bar; the drag feedback and the
   placeholder are unkeyed copies. A widget test now drags a chip into an area (no exception, the panel
   file written).
8. **Holds, fixed.** `tools/procs.sh` collects pid:start pairs and checks the start time and the
   program path again right before each TERM and KILL (install-local, uninstall-local, the helper's
   rollback). pidfds aren't reachable from bash; the check closes the window to the length of one
   `kill`.
9. **Doesn't hold.** `Paths.expand` roots absolute catalog paths through `sys()` (paths.dart:
   `p.isAbsolute(out) && !template.startsWith('{') ? sys(out)`), so `/usr/bin/maprisma` is
   `<root>/usr/bin/maprisma` under a test root, in the status and in `apps.open` alike. No change.
10. **Holds, fixed.** A click on a row opens the app's window as the Plugins page does; apps without a
    window (and not installed ones) open the details; Details… stays in the ⋮ menu.
