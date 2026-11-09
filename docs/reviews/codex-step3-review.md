# Codex review of step 3 (job engine, commit fbed7ba), with what was done

Run read-only (`codex exec -s read-only`), 2026-11-09. Every finding was checked in the code (and 2 in
coreutils' `install` and the installers) before fixing. Responses are at the end.

## Review

Reviewed `fbed7ba` read-only against the requested documents, tests, and local installers. No files modified; no install/update/remove operations or tests executed. Paths below are relative to `packages/maprisma_manager_core/lib/src/`.

1. **High — SIGSTOP does not establish a safe cancellation boundary.** `jobs.dart:310–322` sends SIGSTOP and immediately checks signatures. Successful `kill()` means the signal was sent; group members may still be executing or completing filesystem operations. The code also proceeds with TERM when stopping failed. A writer can therefore modify installed files after the check and then be killed. **Fix:** fail closed on pause failure and use an acknowledged, explicit installer boundary between build and commit. A process-group signal followed by stat checks cannot provide the stated guarantee.

2. **High — Process stopping happens after the first destructive write.** `jobs.dart:747–748`, `jobs.dart:789–791` detect commitment only after a catalog path changes. The real Rust installers, including WLAN’s `install.sh:15`, begin replacement with `install -Dm755` directly onto the installed executable. A running executable can cause `ETXTBSY` before anything changes, so Manager never stops it; other files may already be overwritten before stopping occurs. The fake test uses temporary-file-plus-rename and masks this behavior. **Fix:** split building from installation and stop processes before invoking the installation phase.

3. **High — An asynchronous commit transition can outlive the job and its lock.** `jobs.dart:743–755` cancels the periodic timer without awaiting an already-running callback. `_enterCommit()` sets `committed` before awaiting `_stopApp()`, so script exit bypasses the later transition check and proceeds through verification, receipt writing and queue advancement while stopping continues. This can stop freshly restarted processes or overlap the next job. **Fix:** retain one shared commit-transition future and await it on every exit, cancellation and failure path before finishing or releasing the lock.

4. **High — Cancellation escalation is abandoned when the script leader exits.** `jobs.dart:323–329`, `jobs.dart:753–756` tie KILL to the leader remaining alive and cancel the timer upon its exit. A shell can exit on TERM while a child ignores TERM and continues writing. After the two-second output timeout, Manager can release the lock with that child still running. **Fix:** supervise the complete job, preferably in a dedicated cgroup, and complete cancellation only after all members have exited or been killed.

5. **High — Interrupted installers do not exclude replacement jobs.** `jobs.dart:1089–1105` resumes an orphan installer and marks its job finished. `_acquire()` at `jobs.dart:341` checks only the Manager’s lock, which becomes available when the old Manager dies. A repair or remove can therefore run concurrently with the resumed installer. **Fix:** preserve an active-orphan state and reject conflicting mutations until the installer and its descendants have finished or recovery has explicitly taken control.

6. **High — Group signals lack a stable identity check.** `jobs.dart:307–323` signals a stored numeric PGID without checking its recorded start time; the escalation start time is sampled only after TERM. `jobs.dart:789–793` similarly sends CONT after an asynchronous wait. If the leader exits and the number is reused, these signals can target another group. `sysproc.dart:44–47` also treats a missing start time as matching any process. **Fix:** require known identities, validate session/group membership before signaling, and use supervised job containment. For individual processes, use pidfds where possible and fail closed when identity is unavailable.

7. **High — Removal follows symlinked parent directories outside the app.** `jobs.dart:954–959` checks only the final path component; intermediate symlinks are followed during hashing and deletion. For example, a symlinked app `scripts/` directory can cause removal of files in another directory, especially in the no-receipt path. Settings deletion at `jobs.dart:987–994` has the same ancestor problem. **Fix:** anchor operations to validated directory descriptors, reject unexpected symlink traversal below approved roots, and perform verification and deletion relative to those descriptors.

8. **High — Dropping the receipt makes preserved files deletable on the next remove.** `jobs.dart:1006–1008` always deletes the receipt, even when changed or foreign files were retained or displaced files restored. A second remove enters the no-receipt fallback in `removal.dart:87`, adopts the current hashes and deletes those files as “unverified.” **Fix:** retain a removal tombstone or residual receipt recording preserved/restored paths, and exclude them from automatic fallback deletion.

9. **High — Displaced-file metadata authorizes arbitrary restore and delete paths.** `ownership.dart:125–130` validates only that `path` is a string. `restoreEntry()` at line 194 writes that destination, and `drop()` at line 168 deletes the recorded backup path without checking containment. A malformed or edited index can thus write or delete outside the app and backup directory. **Fix:** validate destinations against the app’s approved paths, require backups beneath its displaced directory, reject symlinked backups and ancestors, and verify backup hashes before restoration.

10. **Medium — Cancellation during process creation is acknowledged but not enforced.** `jobs.dart:718–724` awaits `Process.start()` while `run.process` is null. A concurrent cancel sets `cancelRequested` and returns success, but `_runScript()` never checks that flag again before allowing the script to run through installation. **Fix:** serialize launch and cancellation, then immediately service any pending cancellation once the process group is established.

11. **Medium — Existing bar state is never snapshotted before installation.** `jobs.dart:850` reapplies only existing `bar.json` entries. When an app has never been changed through Manager, its current hidden autostart state is absent there. Installers overwrite `Hidden=true`, and Manager can then start the tray. **Fix:** capture actual per-app visibility and placement before launching the installer, seed missing wanted state, and restore it after both success and relevant failure paths.

12. **Medium — Theme’s tray restart omits the required `daemon` argument.** `jobs.dart:889`, `jobs.dart:905` launch only the configured executable. Theme’s installer and autostart entry invoke `maprisma-theme-core daemon`; launching the bare core does not restart its daemon. **Fix:** model detached launch commands as executable plus arguments and configure Theme with `daemon`.

13. **Medium — Receipts cover postcondition samples rather than the complete installation.** `jobs.dart:642` records only catalog paths, and removal deletes only those entries. Launcher, Theme and Video install entire Flutter bundles; their catalogs list selected executables/libraries but omit many installed assets and libraries. Theme directories are recorded only as empty-directory removal candidates. Remove can report success while leaving most installed content behind. **Fix:** inventory every installed file/link in owned bundle trees, hash each entry, and remove matching entries individually while retaining unknown additions.

14. **Medium — `jobs.log` can permanently stall on a long line.** `jobs.dart:261–269` reads at most 256 KiB and discards the entire chunk if it contains no newline. With a longer line, every request returns the same `next`, including after completion when more than one chunk remains. The CLI then loops indefinitely. Separately, `JobLog` feeds unbounded lines into `LineSplitter` at `jobs.dart:66–83`, so bounded disk output does not bound memory. **Fix:** allow partial-line chunks with advancing byte offsets, preserve UTF-8 boundaries, and cap or chunk live-line buffering.
## Responses

1. **Holds, fixed.** `kill()` returning means the stop is queued, not reached: a member could still
   finish a `rename` after the check. A cancel now sends SIGSTOP and waits (up to 1 s) until every
   member of the script's session/group shows state `T` in `/proc/<pid>/stat` (a stopped process runs no
   code and is in no system call); only then are the signatures compared. Pause not sent or not reached
   in time → the group continues and the cancel is refused (`not_cancellable`, fail closed). A script
   that traps TERM and writes anyway is caught by the check after its exit (`cancelled` failure with
   repair). An explicit installer boundary would need changes in every repo; not done in step 3.
2. **Does not hold as stated.** coreutils `install` unlinks the destination before opening it
   (`unlink_dest_before_opening`), so a running binary gives no ETXTBSY (docs/inventory.md: "replaces a
   running binary safely"); the installers that copy bundles (`cp -r`/`cp -a`) remove or swap the target
   first. Stopping at the first changed path (script paused meanwhile) is the plan's "build first, stop
   as late as possible"; that some files are replaced before the stop is harmless with unlink semantics.
   Splitting build from install needs the repos' scripts to change; kept for later if an app needs it.
3. **Holds, fixed.** One commit transition per job (`_Run.committing`); the poll starts it without a
   second one, and the script's exit, a cancel and a failure await it before the job goes on.
4. **Holds, fixed.** The KILL timer is no longer tied to the leader: after a cancelled leader exits,
   the job waits until no member of its session/group is left, sending KILL once `killAfter` has
   passed since the cancel (tested with a child that ignores TERM). A cgroup per job would also catch
   members that `setsid` away; not done (they leave the group on purpose, e.g. daemons the installer starts).
5. **Holds, fixed.** `jobs.start` is refused (`busy`) while the script of an interrupted job (its
   leader by pid + start time, or any member of its session) still runs; tested.
6. **Holds, fixed.** Group signals go through `_signalGroup`: only while the leader is the process that
   started at the recorded time, or members of the session it created exist. The start time is taken
   before the child is reaped. The interrupted-job check needs the owner's start time (none: not alive).
   Individual processes were already checked by start time and uid before TERM and KILL.
7. **Holds, fixed.** A remove touches only paths below the shared install folders with no symlinked
   folder between that root and the path (`unsafeReach`), in the plan and again right before each
   delete, restore and settings delete; such paths stay with the reason. Tested with a linked
   `scripts/` folder. Descriptor-relative deletes (`openat`) aren't available in dart:io; the re-check
   right before the delete is the compromise.
8. **Holds, fixed.** A remove that keeps catalog paths records them (`kept/<app>.json`, with their hash
   or link); a later remove without a receipt never takes a kept path that is unchanged, and an install
   clears the record. Tested.
9. **Holds, fixed.** The displaced index only accepts absolute normalized paths and backups inside
   `displaced/<app>/` (or links); restores happen only at the app's catalog paths, when the backup's
   sha256 still matches, never through a linked folder; dropping deletes only inside that folder.
10. **Holds, fixed.** A cancel while the script is being started is remembered and carried out as soon
    as its group is known (or refused in the log if it had already written).
11. **Holds, fixed.** Before an install of an installed app without a bar.json entry, its current bar
    state (in, and where, or out) is recorded there, so the post-install `bar.apply` keeps it; tested.
    After a failure that had written, `bar.apply` runs too.
12. **Holds, fixed.** `BarIcon.kdeTrayArgs`; Theme's tray is started as `maprisma-theme-core daemon`.
13. **Holds, not fixed in step 3; made safe.** The catalog lists sample paths of the Flutter bundles, so
    a remove would leave most of a bundle. Removing Launcher, Theme and Video Translator is now
    `unsupported_yet` until step 5 adds whole-tree ownership (every file of a bundle hashed in the
    receipt); the rust apps' catalogs list every file their installers write.
14. **Holds, fixed.** A read without a newline that fills `maxLogRead` (or the rest of a finished log) is
    handed out cut at a UTF-8 boundary, so `next` always advances (tested with a 300 kB line); the live
    line stream cuts lines at 64 Ki characters instead of `LineSplitter`'s unbounded buffer.

Not tested: the COSMIC applet restart (needs a cosmic-panel child running from the temp HOME) and the
KDE tray start/stop after an install (needs a Plasma session); cancel during `Process.start` (timing).
