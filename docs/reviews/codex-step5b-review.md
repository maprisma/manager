# Codex review of step 5b (Maprisma as a pacman package, bar icon changes; commit 8247cd2), with what was done

Run read-only (`codex exec -s read-only`), 2026-11-09. Every finding was checked in the code before
fixing. Responses are at the end.

## Review

Found seven issues, ordered by severity. Review was read-only; I did not run tests or privileged commands.

1. **P1 — Restart recovery ignores surviving pkexec/pacman.** [jobs_pacman.dart:450](/mnt/Data/Projects/maprisma-manager/packages/maprisma_manager_core/lib/src/jobs_pacman.dart:450) records a `pkexec` identity, but `orphanRunning()` only examines `job['script']`. If the Manager exits during authentication or installation, another Manager can start a job while that process survives. Before authentication, no pacman lock prevents the new job from deleting and rebuilding the same package directory.
   **Fix:** Include the recorded pkexec/pacman PID and start time in recovery and exclusion checks. Block new jobs until it exits, without signalling it.

2. **P1 — Exceptions can leave the provider service stopped or disabled.** [jobs_pacman.dart:228](/mnt/Data/Projects/maprisma-manager/packages/maprisma_manager_core/lib/src/jobs_pacman.dart:228) stops the service before `_pkexecPacman()`, but restoration only handles returned exit codes and explicit verification failures. A launch exception bypasses restoration. Removal has the same problem after stopping/disabling units at line 530. Furthermore, `_restoreUnits()` logs failed starts while allowing installation to succeed.
   **Fix:** Protect the stopped interval with exception-safe restoration; retain disabled units only after verified removal. Report restoration failures as failures requiring repair.

3. **P1 — Test-root protection does not cover systemctl.** [jobs_pacman.dart:392](/mnt/Data/Projects/maprisma-manager/packages/maprisma_manager_core/lib/src/jobs_pacman.dart:392) resolves and runs `systemctl` without `_tool()`’s test-root guard. With fake makepkg/pacman/pkexec but a missing fake systemctl, installation/removal reaches the host user’s provider service through the inherited session bus. The supplied setup installs the fake, but there is no fail-closed protection if it is omitted.
   **Fix:** Validate systemctl before any service operations, including `_stopApp()`, and require an explicitly injected fake for test roots.

4. **P2 — CSS escaping bypasses SVG external-reference checks.** [icons.dart:70](/mnt/Data/Projects/maprisma-manager/packages/maprisma_manager_core/lib/src/icons.dart:70) checks raw CSS with substring searches and a `url(` regex. Valid CSS such as `fill:u\72l(https://example.com/x.svg#g)` or `@\69mport "https://example.com/x.css";` passes validation despite containing external references.
   **Fix:** Parse and normalize CSS before checking references, or reject CSS escapes and unsupported constructs conservatively. Add these cases to `svgProblem` tests.

5. **P2 — Interrupted icon writes can destroy the saved original.** [icons.dart:385](/mnt/Data/Projects/maprisma-manager/packages/maprisma_manager_core/lib/src/icons.dart:385) replaces `chosen.svg` and the installed icon before saving `icon.json`. A crash or metadata-write failure leaves the installed choice inconsistent with metadata. The next `set` treats that choice as a new original and overwrites `original.svg`. With missing metadata, `reset` can instead delete the backup without restoring it.
   **Fix:** Make the multi-file operation recoverable with pending transaction metadata or versioned files. Preserve an existing original when metadata is missing or inconsistent.

6. **P2 — Icon operations race with job startup.** [icons.dart:366](/mnt/Data/Projects/maprisma-manager/packages/maprisma_manager_core/lib/src/icons.dart:366) checks `activeFor()` before awaiting the state lock; `reset` does likewise. A job can start between that check and the mutation. Jobs use a separate lock, so icon writes, receipt updates, and subsequent tray refresh can overlap installation/removal.
   **Fix:** Coordinate icon mutations and job admission through shared exclusion, covering refresh as well as file writes. Merely repeating the check inside the state lock does not protect against independently admitted jobs.

7. **P2 — An unchanged package version does not prove a failed transaction changed nothing.** [jobs_pacman.dart:233](/mnt/Data/Projects/maprisma-manager/packages/maprisma_manager_core/lib/src/jobs_pacman.dart:233) clears `committed` whenever the installed version remains unchanged. A failed extraction can modify package files before pacman updates its database, producing `repair: false` for a damaged installation. Removal repeats the inference at line 544.
   **Fix:** Clear `committed` only for demonstrable pre-transaction failures, such as rejected authentication or lock acquisition. Keep repair enabled for other pacman failures unless filesystem integrity is verified.

I found no additional actionable issue in the three app icon-name commits or the generated PKGBUILD’s interpolation checks.

## Responses

1. **Holds, fixed.** `orphanRunning` also looks at the job's recorded `pkexec` (pid + start time; after
   authentication the same pid is pacman): an interrupted job whose pkexec/pacman still runs is
   `orphan` and every `jobs.start` is `busy` until it has ended. It is never signalled (no SIGCONT
   either: it has no group of ours). Tested with a stand-in process.
2. **Holds, fixed.** Stopping the app and running pkexec are inside a try: any exception starts the
   units again (remove: enables and starts them) before it is passed on. A unit that doesn't start
   again after a successful install is not a failure of the install (Maprisma is installed and
   verified) but a warning in the job and `result.unitsNotStarted`.
3. **Holds, fixed.** systemctl goes through the same guard as makepkg/pacman/pkexec (found in PATH,
   never a system one with a test root) in prepare, before any unit is touched. Tested.
4. **Holds, fixed.** A backslash anywhere in CSS (a `<style>` or any attribute value) is refused:
   icons don't need CSS escapes, and refusing them is simpler and safer than decoding them. Tested
   with both examples.
5. **Holds, fixed.** `set` saves each step before the next (original + its metadata, then
   `chosen.svg` + the choice, then the app's file) and treats a file as "ours" when it matches the
   recorded choice or `chosen.svg`, so a lost `icon.json` never makes a choice the new original; a
   kept original is replaced only by another file of the installer's. `reset` restores when the file
   is ours (or missing) and refuses (`changed`) when the original is missing instead of deleting the
   folder. Tested with `icon.json` deleted between steps.
6. **Holds, fixed.** `icons.set`/`reset` run under the jobs' lock (`JobEngine.exclusive`: `busy` while a
   job of this or another Manager runs; `jobs.start` is `busy` while an icon change runs), the file
   writes, receipt update and the bar refresh included. Tested against another process holding the
   lock.
7. **Holds, fixed.** `committed` is cleared (no repair) only for failures before pacman's transaction:
   `auth_cancelled`, `auth_timeout`, `pacman_locked`; any other pacman failure keeps `repair: true`.
   Tested.

## Found live (not by the review)

The live upgrade (`maprisma-manager-core update maprisma`, 2026-11-09 17:44) downloaded and checked
v0.14.2, built `maprisma-bin-0.14.2-1` with makepkg, stopped the provider service and started `pkexec
/usr/bin/pacman -U`; the password dialog was not answered within 300 s, so pkexec was ended
(`auth_timeout`), the service started again, and nothing changed (still 0.13.1-9; `~/.config/maprisma`
identical). Not retried. It works as designed; the upgrade itself is still to be done with someone at
the dialog.
