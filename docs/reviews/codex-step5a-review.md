# Codex review of step 5a (whole-tree ownership, Launcher/Theme/Narrator/Video removes, KDE steps; commit a10ebc4), with what was done

Run read-only (`codex exec -s read-only`), 2026-11-09. Every finding was checked in the code before
fixing. Responses are at the end.

## Review

Found eight issues, ordered by severity. Paths below are under `packages/maprisma_manager_core/lib/src/`.

1. **High — Generated-style cleanup can delete through symlinked ancestors.**  
   [kde_remove.dart:251](/mnt/Data/Projects/maprisma-manager/packages/maprisma_manager_core/lib/src/kde_remove.dart:251), [kde_remove.dart:277](/mnt/Data/Projects/maprisma-manager/packages/maprisma_manager_core/lib/src/kde_remove.dart:277)  
   Unlike ordinary tree removal, generated styles and cache never pass through `unsafeReach`. If `plasma/desktoptheme` is a symlink, the metadata checks inspect its target and recursive deletion removes files there. Replacing a cleanup root with a symlink between planning and execution is also unchecked.  
   **Fix:** validate ancestors and root types during planning and execution; perform deletion relative to anchored directory descriptors.

2. **High — KDE package deletion bypasses the final ownership checks.**  
   [kde_remove.dart:140](/mnt/Data/Projects/maprisma-manager/packages/maprisma_manager_core/lib/src/kde_remove.dart:140), [kde_remove.dart:245](/mnt/Data/Projects/maprisma-manager/packages/maprisma_manager_core/lib/src/kde_remove.dart:245), [jobs.dart:1658](/mnt/Data/Projects/maprisma-manager/packages/maprisma_manager_core/lib/src/jobs.dart:1658)  
   `kpackagetool6 -r` runs before the per-file rechecks. A package considered unchanged during planning can gain modified or foreign files while shortcuts, D-Bus calls, or style switching run. The package tool then recursively removes them; the later checks merely see missing files.  
   **Fix:** revalidate the complete package immediately before removal and prevent concurrent replacement, or quarantine the verified directory and remove that exact instance.

3. **High — Tree deletion still has an ancestor-swap TOCTOU window.**  
   [jobs.dart:1670](/mnt/Data/Projects/maprisma-manager/packages/maprisma_manager_core/lib/src/jobs.dart:1670)  
   `unsafeReach`, hashing, and deletion are separate pathname operations. Another process can rename an inspected directory and replace it with a symlink after validation. `File(g.path).deleteSync()` then deletes through the replacement ancestor, potentially outside the owned tree.  
   **Fix:** use directory-descriptor-relative traversal/deletion with no-follow checks and identity validation. Repeating pathname checks cannot close this race.

4. **Medium — Arbitrary bytecode files and foreign empty directories are adopted for deletion.**  
   [trees.dart:145](/mnt/Data/Projects/maprisma-manager/packages/maprisma_manager_core/lib/src/trees.dart:145), [trees.dart:154](/mnt/Data/Projects/maprisma-manager/packages/maprisma_manager_core/lib/src/trees.dart:154)  
   Any unrecorded `__pycache__/*.pyc` or `.pyo` is deleted, without checking that it derives from an owned module. Every directory is also scheduled for empty-directory removal, regardless of manifest ownership. This applies even to Launcher/Theme bundles and swap leftovers. The test explicitly accepts a cache file without a corresponding owned Python source.  
   **Fix:** retain unknown entries by default. Restrict cache cleanup to demonstrably owned modules and prune only recorded directories plus explicitly justified cache directories.

5. **Medium — Manifest creation is unbounded before enforcing its limit.**  
   [trees.dart:43](/mnt/Data/Projects/maprisma-manager/packages/maprisma_manager_core/lib/src/trees.dart:43), [trees.dart:130](/mnt/Data/Projects/maprisma-manager/packages/maprisma_manager_core/lib/src/trees.dart:130)  
   Both routines recursively materialize and sort the entire directory listing. `maxTreeEntries` is checked only afterward, and removal has no traversal limit. A large tree can exhaust memory or block the core; manifest creation occurs after installation has changed the system, so failure can leave the new installation without an updated receipt. Receipt reading also reads the whole file before validation.  
   **Fix:** traverse incrementally with entry, byte, and depth limits; cap receipt size before reading and bound aggregate manifest size.

6. **Medium — Revision checks omit the widget instances that will be destroyed.**  
   [kde_remove.dart:219](/mnt/Data/Projects/maprisma-manager/packages/maprisma_manager_core/lib/src/kde_remove.dart:219), [removal.dart:272](/mnt/Data/Projects/maprisma-manager/packages/maprisma_manager_core/lib/src/removal.dart:272)  
   Widget discovery contributes only a count in `notes`. The revision includes the constant “widgets” step, but no widget identities or configuration. Adding or replacing a widget after preview therefore leaves the revision unchanged, and execution removes the newly added widget too.  
   **Fix:** include the exact panel/widget identities and relevant configuration in the revision; revalidate and remove only those approved instances.

7. **Medium — A failed style restoration leaves Icons widgets permanently removed.**  
   [kde_remove.dart:225](/mnt/Data/Projects/maprisma-manager/packages/maprisma_manager_core/lib/src/kde_remove.dart:225), [kde_remove.dart:241](/mnt/Data/Projects/maprisma-manager/packages/maprisma_manager_core/lib/src/kde_remove.dart:241)  
   Widget removal runs before the required style-switch command. If the saved style was uninstalled or applying it fails, removal aborts after destroying widget instances and their zone configuration. No rollback restores them. Retrying cannot recover that configuration.  
   **Fix:** validate/apply the replacement style before destroying widgets, or snapshot and restore complete widget configuration on failure.

8. **Medium — Remove/install loses KDE widget placement.**  
   [jobs.dart:1259](/mnt/Data/Projects/maprisma-manager/packages/maprisma_manager_core/lib/src/jobs.dart:1259)  
   The new remove-time snapshot records index and panel only for COSMIC. On KDE, an app never positioned through Manager gets only its area recorded. Removal deletes its zone entry; reinstall appends it to that area on the default widget, losing its original index and potentially its widget.  
   **Fix:** snapshot the KDE widget identity and exact zone index too. Add coverage with multiple widgets and foreign entries surrounding the app.

Read-only review completed against `a10ebc4` and the supplied local installers. No files changed and no tests or installer/remove commands executed.
## Responses

1. **Holds, fixed.** The generated styles and the colour cache now go through `unsafeReach` (below the
   data/cache roots, no linked folder on the way) and must be real folders, in the plan and again right
   before the delete; `Directory.deleteSync(recursive: true)` doesn't follow links inside. Tested with
   a linked `plasma/desktoptheme` (the style stays). Descriptor-relative deletes: see 3.
2. **Holds, fixed.** The `packages` step checks each package folder again right before
   `kpackagetool6 -r`: still all the manifest's files, the same digest as in the plan, no linked folder
   on the way; otherwise kpackagetool6 isn't run and only the unchanged files go one by one. Tested
   with a file added after the plan. The milliseconds between that check and kpackagetool6's own
   delete remain (like git's own check in step 4b #5).
3. **Holds in principle, not fixed.** As in step 3 #7: dart:io has no `openat`/`unlinkat`, so the
   pathname check right before each delete (`unsafeReach`, type, sha256) is the compromise. Swapping a
   folder of the user's own home for a link in that window needs a process of the same user, which
   could delete those files itself.
4. **Holds, fixed.** A byte-code cache goes only when its module is the manifest's
   (`a/__pycache__/m.*.pyc` for an owned `a/m.py`); other `.pyc` stay. Only the manifest's folders and
   the `__pycache__` folders of owned folders are removed when empty, then the root; a folder of the
   user's stays. Tested.
5. **Holds, fixed.** The walk is bounded (it stops after `maxTreeEntries + 1` entries, depth 64), a
   tree that big is recorded `overflow` (it stays on remove) and `checkTree` keeps a folder that grew
   past the limit whole; a receipt over 32 MiB is not read (broken). A manifest is taken after verify;
   a too-big folder doesn't fail the install.
6. **Holds, fixed.** The widgets step names the widget ids it removes (so they are in the plan's
   revision), and the script removes only those ids. Tested: a widget added after the plan makes the
   job fail with `changed` and nothing is removed.
7. **Holds, fixed.** The style is switched back first (a failure stops the remove with the widgets in
   place), then the widgets go. A saved style that is no longer installed (neither the user's nor the
   system's) falls back to `default` with a note in the plan. Tested.
8. **Holds, fixed.** On KDE the bar state recorded before a remove/install now has the index in the
   widget's zone and the widget id, so a reinstall puts the tray back at its place. Tested with a fake
   plasmashell.

## Found live (not by the review)

Reinstalling Control, Launcher and Theme one after the other through the Manager restarted
cosmic-panel three times (the step-3 fallback when an applet doesn't start again after an install).
cosmic-session restarts a killed panel with a delay that doubles (`restart 13`: 65.5 s): after the
third, the panel was away for about a minute and came back by itself. Fixed in 00d69bb: the applet's
panel file is written once without it and back with its exact bytes (the panel rebuilds twice and
starts it; the panel process keeps running; checked live first by hand, then for Bluetooth, Home, Hue,
LLM, Narrator, Video and the Home round trip; no panel restart since). The Manager never restarts
cosmic-panel any more.
