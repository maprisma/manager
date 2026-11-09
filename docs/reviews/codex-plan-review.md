The plan needs revisions before implementation, especially around removal, persistent bar state, cancellation and package installation. I reviewed both documents against the local installers and relevant runtime code. No files were modified.

1. **High — Removing Launcher’s KDE icon is currently impossible.**  
   [plan.md:80](/mnt/Data/Projects/maprisma-manager/docs/plan.md:80) assumes bar visibility can be controlled through tray processes and widget zones. However, [main.qml:37](/mnt/Data/Projects/maprisma-panel/package/contents/ui/main.qml:37) unconditionally adds Launcher as a fixed entry, and its `update()` puts entries absent from all zones back into the left zone. Removing Launcher leaves a broken icon; removing its zone entry does not hide it.  
   **Change:** add a supported visibility setting to Maprisma Icons first. Launcher also needs a separate KDE path because it has no SNI tray process.

2. **High — Updates undo “Not in the bar”.**  
   Most installers rewrite their autostart desktop files, losing `Hidden=true`. Theme’s installer also starts its daemon immediately on KDE. The generic post step then starts trays regardless of prior visibility. See [plan.md:58](/mnt/Data/Projects/maprisma-manager/docs/plan.md:58).  
   **Change:** persist desired visibility independently, snapshot it before installation, and reapply it afterward. Restore only processes that should run. For Theme, establish whether stopping the tray daemon also disables automation the user expects to retain.

3. **High — Catalog paths alone do not establish ownership for deletion.**  
   [plan.md:64](/mnt/Data/Projects/maprisma-manager/docs/plan.md:64) permits deleting catalog files and optionally settings, including resources shared with Omarchy. An existing file may have been replaced by another installer since Manager installed it. A receipt containing only a commit cannot resolve this.  
   **Change:** record installed paths, file hashes, symlink targets and prior-file backups. On removal, preserve modified or foreign files and report conflicts. Unlink symlinks without following their targets. Keep shared Omarchy data outside the ordinary “delete settings” option, with explicit resource-specific handling.

4. **High — Narrator’s runtime inventory is incomplete and unsafe to remove wholesale.**  
   [inventory.md:113](/mnt/Data/Projects/maprisma-manager/docs/inventory.md:113) lists `ocrvox.service{,.d}`, but runtime setup also writes `~/.local/bin/simple-reader` and `simple-reader.desktop`, backing up prior versions. It can retain an existing managed service and add `read-aloud-runtime.conf`. See [setup_backend.py:117](/mnt/Data/Projects/maprisma-narrator/backend/setup_backend.py:117).  
   **Change:** distinguish installer outputs from optional backend setup outputs. Never recursively delete the entire service drop-in directory. Inspect ownership, preserve unrelated overrides, restore displaced launchers where appropriate, and reload systemd after changes. Shared reader runtimes should normally remain.

5. **High — Tiling installation and removal need a migration transaction.**  
   [install.sh](/mnt/Data/Projects/maprisma-kwin-scripts/install.sh) disables Krohnkite and the old active-frame script, removes their packages after loading, deletes settings and changes shortcuts. The plan describes only installing KWin scripts and restoring shortcuts on removal. It does not restore the displaced desktop setup.  
   **Change:** expose these effects before installation and capture package/config/enablement state. Uninstall must unload and disable the running scripts, restore only settings still owned by this installation, and reconfigure KWin. Treat `omarchy-navigation` as potentially pre-existing rather than automatically owned.

6. **High — Removing Maprisma Icons can leave Plasma using a deleted theme.**  
   [inventory.md:180](/mnt/Data/Projects/maprisma-manager/docs/inventory.md:180) records generated desktop themes, but removal only mentions `kpackagetool6 -r`. The widget periodically invokes the color helper, which applies those themes globally.  
   **Change:** remove the selected widget instances first, stop further helper invocations, switch away from a generated theme if it is active, then remove generated assets. Save the prior theme; `maprisma-panel-color --off` selects Breeze rather than restoring that prior choice.

7. **High — `/proc/<pid>/exe` is insufficient for helper processes.**  
   [plan.md:56](/mnt/Data/Projects/maprisma-manager/docs/plan.md:56) will miss Python and shell helpers because their executable is the interpreter. Matching `/usr/bin/python3` instead would threaten unrelated applications. Services and panels can also respawn processes during replacement.  
   **Change:** stop owned systemd units first; identify interpreted helpers using exact script arguments and verified paths, or manage them in dedicated units. Restrict signals to the current UID, handle deleted executable paths, and revalidate PID identity before escalation. Build before stopping applications. Preserve Launcher’s existing refusal to interrupt active terminal commands.

8. **High — Cancellation needs phase boundaries and recovery.**  
   [plan.md:54](/mnt/Data/Projects/maprisma-manager/docs/plan.md:54) promises process-group SIGTERM cancellation, but scripts perform destructive replacements and package transactions. Detached children can escape that group. Cancelling after deletion can leave a partial installation.  
   **Change:** distinguish cancellable build/download phases from commit phases. Use a verified isolated process group or job unit, persist operation state, and define recovery after termination. Do not kill pacman during its transaction; cancellation should wait for completion.

9. **High — The pacman build/install path is underspecified and can install the wrong artifact.**  
   [plan.md:61](/mnt/Data/Projects/maprisma-manager/docs/plan.md:61) says to copy the PKGBUILD and increment `pkgrel`, but the actual [PKGBUILD](/mnt/Data/Projects/aur-maprisma-bin/PKGBUILD) downloads version `0.12.0` with a fixed checksum. Incrementing `pkgrel` alone does not package the newly built local archive. The release builder also requires an already signed, matching-version adapters ZIP; it does not build/sign add-ons itself.  
   **Change:** generate an isolated package recipe with the exact local archive, version and checksum; build unprivileged; inspect package metadata and compare versions using pacman’s version rules. Promote only the verified package with an absolute `pkexec`/pacman command. Handle authentication cancellation and package-lock contention. `pacman -R` needs an explicit noninteractive confirmation strategy because the proposed log sheet cannot answer its terminal prompt. Restore provider-service state on failure and disable it appropriately on removal.

10. **High — Self-update needs an external supervisor and rollback contract.**  
    [plan.md:68](/mnt/Data/Projects/maprisma-manager/docs/plan.md:68) gives only `setsid`, wait, swap and restart. That does not establish helper independence, readiness, single-instance exclusion or crash recovery. A helper inside the bundle being replaced is particularly fragile.  
    **Change:** stage and validate first; launch a helper from a stable external location; acknowledge readiness before Manager exits; retain the old bundle until the replacement reports successful startup. Define timeout, rollback, durable logs and recovery on next launch. Self-removal needs a similarly explicit path.

11. **Medium — COSMIC config watching does not guarantee live structural reload.**  
    [plan.md:75](/mnt/Data/Projects/maprisma-manager/docs/plan.md:75) is too optimistic. Upstream has an open report specifically describing `plugins_wings`/`plugins_center` changes requiring a panel restart. Current source has config watchers, but that alone does not prove correct applet-list reconciliation. Treat this as version-dependent and verify the installed build. [Upstream issue](https://github.com/pop-os/cosmic-panel/issues/674), [watcher source](https://raw.githubusercontent.com/pop-os/cosmic-panel/master/cosmic-panel-bin/src/config_watching.rs).  
    **Change:** define a controlled, batched restart fallback with recovery verification. Discover panel instances rather than hardcoding only `Panel`; support dock/multiple-panel selection. Parse actual RON, including `None` and missing defaults. Preserve unknown IDs and comments, detect concurrent edits, and back up both files: two atomic renames are not one atomic move between wings and center.

12. **Medium — Keep KDE’s scripting approach, but specify instance selection and types.**  
    [plan.md:82](/mnt/Data/Projects/maprisma-manager/docs/plan.md:82) correctly chooses `plasmashell.evaluateScript` and `writeConfig`. Directly editing live `appletsrc` risks conflicting with Plasma’s in-memory configuration. The widget’s zones are **StringList** values, not merely arbitrary comma-separated text.  
    **Change:** enumerate panels/widgets, select the intended `com.maprisma.panel` instance, use its `General` config group and proper list values, preserve unrelated entries, deduplicate across zones, then read back. Handle multiple instances and unavailable session D-Bus. Package installation also does not add a widget to a panel. [KDE scripting API](https://develop.kde.org/docs/plasma/scripting/api/).

13. **Medium — Successful script exit does not mean a complete installation.**  
    [plan.md:40](/mnt/Data/Projects/maprisma-manager/docs/plan.md:40) uses one key file, and receipts are written after script success. Narrator and Video Translator can succeed while skipping Flutter; without cargo they can reuse prebuilt Rust binaries. Theme expects `FLUTTER` as a **directory**, while Narrator/Video expect an **executable**. PATH alone does not fix their hardcoded fallback.  
    **Change:** add per-component prerequisites and postconditions, explicit “partially installed” status, and app-specific environment adapters. Verify links, executables and required assets before recording success. Avoid a login shell that executes unrelated user startup commands.

14. **Medium — Git receipts do not identify the actual build reliably.**  
    [plan.md:42](/mnt/Data/Projects/maprisma-manager/docs/plan.md:42) assumes one clean `main` commit. Launcher includes a second repo; Maprisma includes signed add-on artifacts. Dirty rebuilds, detached HEADs, alternate branches, force-pushes and external reinstalls invalidate the proposed comparison.  
    **Change:** record each input repo’s HEAD, dirty state/content fingerprint and relevant artifact hashes. Separate “source differs”, “remote commits available” and “installed build unknown”. Resolve the configured upstream rather than assuming `origin/main`; verify ancestry before presenting commit counts. Build the revision actually displayed to the user.

The user-facing scope should also include Open/Settings, Repair/Reinstall, prerequisite diagnostics, pending-restart status, offline/error states, dependency previews and clear distinction between “enabled at login”, “running” and “actually visible”. KDE’s ordinary system tray may hide an item in its overflow, so starting a tray does not guarantee a visible panel icon.

A better implementation order is:

1. Correct the inventory and define ownership, shared-data and migration rules.
2. Implement read-only discovery, component health, Git provenance and prerequisite checks.
3. Prove COSMIC reload behavior and KDE visibility control—including the required Launcher widget change.
4. Build the job engine with persistent state, locking, cancellation boundaries and recovery.
5. Implement and verify one simple Rust app end to end; then composite apps, KDE migrations and pacman.
6. Add self-update with failure/rollback tests, then finish the Flutter UI.
7. Validate both desktops, including interrupted installs, preserved hidden icons, shared-data removal and concurrent config edits. The current final step tests only COSMIC and misses the highest-risk paths.