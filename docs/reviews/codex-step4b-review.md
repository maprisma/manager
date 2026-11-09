# Codex review of step 4b (GitHub sources, commit 6526975), with what was done

Run read-only (`codex exec -s read-only`), 2026-11-09. Every finding was checked in the code before
fixing. Responses are at the end.

## Review

1. **P1 — Failed tarball placement can strand a user’s file.**  
   `jobs.dart:1065`: An existing tarball is moved aside before copying and setting the replacement’s mtime. If either operation throws, `_placeTarball` never returns its undo callback, so the caller’s `finally` cannot restore the original. This contradicts the documented cleanup guarantee. **Fix:** establish rollback before the first mutation and execute it on every placement failure; persist recovery information for interrupted jobs.

2. **P1 — Tarball cleanup can delete or overwrite a concurrent user file.**  
   `jobs.dart:1082`: Cleanup unconditionally deletes whatever currently occupies `target`, then renames the saved original over that path. A build or user replacing the tarball while installation runs loses their replacement. The Manager’s job lock does not protect external writers. **Fix:** record the placed file’s identity and verify it before deletion; restore backups without replacement, retaining and reporting both files when a conflict occurs.

3. **P1 — The fast-forward checks and merge can resolve different refs.**  
   `git.dart:269`: `compare()` explicitly checks `refs/remotes/public/main`, but `mergeFfOnly()` passes the ambiguous name `public/main`. A local branch or tag with that name can resolve instead, installing different code from the GitHub ref that passed the ancestry check. **Fix:** resolve the fully qualified remote-tracking ref to a commit ID and merge that exact ID.

4. **P2 — Ordinary GitHub updates can silently miss new commits.**  
   `jobs.dart:936`: When GitHub is the configured upstream remote, `_githubUpdate` returns immediately. The preceding pull runs only if the *previously fetched* tracking ref already reports `behind`. A repo locally marked up to date therefore performs no fetch or pull and can return `up_to_date` despite new GitHub commits. Matching only the remote also skips comparison with GitHub’s default branch when the configured upstream tracks another branch. **Fix:** fetch and compare the intended GitHub ref before deciding whether to fast-forward or skip.

5. **P2 — Clean-tree and branch checks become stale during fetch.**  
   `jobs.dart:929`: The job inspects branch and cleanliness before fetching, then uses those old facts to authorize the merge. During that network wait, the user can edit files, detach HEAD, or switch branches. Git permits fast-forwards with some nonconflicting dirty changes, so `--ff-only` does not enforce the promised rule. **Fix:** re-inspect immediately before mutation and reject changed HEAD, branch, or dirty state; use the exact checked commit as the merge target.

6. **P2 — A release receipt can incorrectly suppress a folder build.**  
   `jobs.dart:722`: The update shortcut compares input commits without excluding release receipts. Release inputs describe the checkout whose installer ran, not the release’s build. On KDE/other desktops, an unchanged Launcher checkout can therefore make `update launcher` report “already up to date” while the installed release contains different code. **Fix:** require `!rec.fromRelease` before applying the folder-build shortcut.

7. **P2 — Cancelling a clone leaves its helper processes unmanaged.**  
   `jobs.dart:882`: Clone starts without a separate process group; cancellation signals only the Git parent. SSH, remote helpers, or checkout filters can survive, retain output pipes, or continue accessing the temporary directory after cleanup. The cancellation test uses `exec sleep`, which replaces the parent and misses this case. **Fix:** run clone in an owned session/process group, terminate and await all members before cleanup, and test a helper that remains a child.

8. **P2 — Offline failures through `gh` do not stop refresh.**  
   `github.dart:83`: A logged-in `gh` reporting DNS, connection, or timeout failure becomes an ordinary `GitHubError`. `refresh()` stops only for rate-limited `GitHubError`s or non-`GitHubError` exceptions, so it continues invoking `gh` for every repository while offline. This differs from REST behavior and the protocol’s stated stop-on-offline behavior. **Fix:** classify transport failures explicitly and stop the refresh while retaining cached facts; add a fake-`gh` offline test.

The inspected tests restrict Git transports to local files, inject GitHub responses/downloads, and replace panel follow/restart callbacks for jobs using real `/proc`. I found no direct network or real cosmic-panel action in these two test files.
## Responses

1. **Holds, fixed.** Moving a user's file aside, the copy and the mtime were outside any rollback.
   The undo now exists before the first change and runs at once when placing fails; the copy goes
   to a `.part` name and is renamed; the moved-aside path is in the job's state (`dist`) until it is
   back, so an interrupted job shows where the user's file is. Automatic recovery of an interrupted
   job's `dist/` is not done (Repair = reinstall places and cleans up again).
2. **Holds, fixed.** Cleanup deletes the placed file only while its sha256 is still the release's;
   a moved-aside file is put back only where the name is free, otherwise both stay and the log says
   where. Tested: a user's own different file of the release's name is moved aside and back.
3. **Holds, fixed.** `compare()` resolves the full remote-tracking ref to a commit id once and
   compares and counts against that id; the merge is `git merge --ff-only <that id>`. Tested with a
   local branch named `public/main`.
4. **Holds in part, fixed.** Step 3 kept fetching separate (`git.fetch`, "Check for updates"); the
   plan's "Update from GitHub" says fetch + fast-forward. An update now fetches the folder's GitHub
   remote first, also when it is the configured upstream's remote, so the pull/fast-forward sees what
   GitHub has now. When the upstream is on the GitHub remote but another branch, the pull follows the
   configured branch (the user's choice) and the GitHub default branch is not merged.
5. **Holds, fixed.** The folder is inspected again right before the merge: on a branch, clean, and
   at the HEAD and branch that were compared (else "changed while checking"); the merge target is
   the exact checked commit. A change in the milliseconds between that check and git's own is left
   to git (`--ff-only` refuses conflicts).
6. **Holds, fixed.** The "nothing new" shortcut is skipped for a release receipt. Tested: an update
   after a release install builds from the folder.
7. **Holds, fixed.** The clone runs through `setsid`; a cancel sends TERM to its group (identity:
   leader pid + start time, or members left), KILL after 5 s, and waits until no member is left
   before the temporary folder is deleted. Tested with a fake git whose helper stays a child.
8. **Holds, fixed.** gh's transport failures (no HTTP status; "error connecting to", "dial tcp",
   "no such host", timeouts, exit 124) are classified as offline and stop the refresh like the REST
   path. Tested with a fake offline gh.
