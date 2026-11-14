# Review: Ask AI rules contract (docs/ask-ai-rules.md)

## Round 1 — Codex (2026-11-14)

The contract needs revision before implementation. The largest gaps are AI-step provenance, incomplete Theme coverage, and a log rotation protocol that loses synchronization.

Reviewed the current code, including Launcher’s checked-out `ask-local-appimage` branch. No changes made.

1. **High — “AI-proposed only” cannot currently be enforced reliably at execution.**  
   The promise in [ask-ai-rules.md:8](/mnt/Data/Projects/maprisma-settings/docs/ask-ai-rules.md:8) requires information the mutation routes do not have.

   - **Launcher:** Ask cards reuse manual callbacks, including uninstall ([ask_page.dart:1082](/mnt/Data/Projects/maprisma-launcher/flutter_app/lib/ask_page.dart:1082)). Install, uninstall, hide and shortcut routes receive ordinary parameters without AI origin ([core.dart:736](/mnt/Data/Projects/maprisma-launcher/packages/maprisma_launcher_core/lib/src/core.dart:736), [core.dart:528](/mnt/Data/Projects/maprisma-launcher/packages/maprisma_launcher_core/lib/src/core.dart:528)).
   - **Theme:** Ask calls ordinary `themes.apply`, import and wallpaper routes. Its editor’s `fromAsk` flag is UI context; `custom.save` receives no origin ([ask_page.dart:736](/mnt/Data/Projects/maprisma-theme/flutter_app/lib/pages/ask_page.dart:736), [editor_page.dart:216](/mnt/Data/Projects/maprisma-theme/flutter_app/lib/pages/editor_page.dart:216)).
   - **Settings:** Origin is structurally known inside `AiUpdater._perform`, but is lost when it calls the ordinary job engine ([ai_update.dart:366](/mnt/Data/Projects/maprisma-settings/packages/maprisma_manager_core/lib/src/ai_update.dart:366)).

   Specify an execution context carried through cards, reviews, editors, queues and jobs. Prefer core-issued proposal identifiers binding action, target and source. A caller-supplied `origin: ai` alone cannot prevent an older GUI from omitting it and being treated as manual. Explicitly define legacy-client behavior and the trust boundary: unrestricted manual routes prevent this from being a boundary against a deliberately dishonest client.

2. **High — Theme has substantial unmapped mutations; several routes combine actions.**  
   The two Theme IDs at [ask-ai-rules.md:44](/mnt/Data/Projects/maprisma-settings/docs/ask-ai-rules.md:44) do not cover:

   | Ask-driven operation | Real execution | Contract gap |
   |---|---|---|
   | Install catalog theme, optionally apply | [ask_page.dart:813](/mnt/Data/Projects/maprisma-theme/flutter_app/lib/pages/ask_page.dart:813) | Theme installation has no ID |
   | Create/copy/edit custom theme, optionally apply | [ask_page.dart:759](/mnt/Data/Projects/maprisma-theme/flutter_app/lib/pages/ask_page.dart:759), [editor_page.dart:216](/mnt/Data/Projects/maprisma-theme/flutter_app/lib/pages/editor_page.dart:216) | Saving/editing has no ID |
   | Generate picture | [ask_page.dart:654](/mnt/Data/Projects/maprisma-theme/flutter_app/lib/pages/ask_page.dart:654) | Generation has no ID |
   | Set up generator | [ask_page.dart:693](/mnt/Data/Projects/maprisma-theme/flutter_app/lib/pages/ask_page.dart:693) | Setup needs an explicit classification |
   | Add generated wallpaper | [wallpaper_routes.dart:233](/mnt/Data/Projects/maprisma-theme/packages/maprisma_theme_core/lib/src/wallpaper_routes.dart:233) | Neither web download nor necessarily application |
   | Download/add wallpaper and optionally apply | [wallpaper_routes.dart:196](/mnt/Data/Projects/maprisma-theme/packages/maprisma_theme_core/lib/src/wallpaper_routes.dart:196) | Crosses both existing Theme IDs |

   Add IDs for install, save/edit, generation and wallpaper addition—or explicitly broaden existing definitions. Split compound workflows into checked substeps so **each mutation maps to exactly one ID**. Reject an unavailable compound operation before its first mutation; Theme currently applies the theme before adding its selected wallpaper.

3. **High — Checking proposal generation or review routes leaves execution bypasses.**  
   [ask-ai-rules.md:68](/mnt/Data/Projects/maprisma-settings/docs/ask-ai-rules.md:68) needs an explicit execution-path inventory.

   - **Launcher:** Check `packages.install`, including cached local reviews, plus the embedded terminal path: `term.start` calls `_termCommand` independently ([core.dart:309](/mnt/Data/Projects/maprisma-launcher/packages/maprisma_launcher_core/lib/src/core.dart:309)). Also cover direct uninstall, batch terminal operations, update routes, hide and shortcut mutations. Checking only `packages.install_plan` misses execution after policy changes.
   - **Theme:** Check apply, import installation, custom save, generation/setup and wallpaper download/add execution—not just `ask.run`. Recheck after asynchronous preparation before committing changes.
   - **Settings:** Check each `_perform`, including `pub_get`; checking only `start` lets an already-running loop continue after revocation ([ai_update.dart:312](/mnt/Data/Projects/maprisma-settings/packages/maprisma_manager_core/lib/src/ai_update.dart:312)).

   Define revocation as blocking future execution boundaries; it cannot undo an already-running installer or detached terminal.

4. **High — Locking the log file and then replacing it breaks mutual exclusion.**  
   [ask-ai-rules.md:74](/mnt/Data/Projects/maprisma-settings/docs/ask-ai-rules.md:74) locks the file being renamed at line 82. The lock remains associated with the old inode. Another writer can open and lock the replacement while an existing writer still holds—or waits on—the old file, causing lost or invisible records.

   Specify one persistent, never-renamed lock file. Every Dart/Rust writer and Settings clear operation must:

   - Acquire the same OS `flock` lock.
   - Open the current log **after** acquiring it.
   - Append a complete UTF-8 JSON line, handling partial writes.
   - Trim or clear under that lock; close the data descriptor before releasing it.

   Dart and Rust must use compatible locking primitives; do not assume Dart `RandomAccessFile.lock` interoperates with `flock`. Settings already has a libc-based helper ([posix.dart:151](/mnt/Data/Projects/maprisma-settings/packages/maprisma_manager_core/lib/src/ai/posix.dart:151)).

   Also specify no-follow opens, regular-file/owner checks, secure temporary creation, parent-directory handling, record/byte limits, incomplete-line handling and durability expectations. “Never through a link” alone is not an implementable race-safe protocol.

5. **High — Existing shared-file writers can erase permissions.**  
   [shared_helper.dart:78](/mnt/Data/Projects/maprisma-settings/packages/maprisma_manager_core/lib/src/ai/shared_helper.dart:78) performs an unlocked read–modify–rename. Concurrent helper/web-search changes can overwrite a newer `ask_ai` object despite preserving keys in the snapshot read.

   Additionally, `_readObject` returns null for malformed, unreadable or oversized content; `_writeKey` then reconstructs the file with only its requested key ([shared_helper.dart:38](/mnt/Data/Projects/maprisma-settings/packages/maprisma_manager_core/lib/src/ai/shared_helper.dart:38)). That can erase restrictions and activate the contract’s allow-all defaults.

   All shared-file writers across apps/languages need the same stable lock protocol. Distinguish a missing file from an existing file that cannot safely be read; refuse destructive read–modify–write on the latter.

6. **Medium — Launcher source IDs omit `apt`, `dnf`, and `zypper`; cargo/npm/brew are not install managers here.**  
   The actual manager registry includes those three omitted sources ([packages.dart:18](/mnt/Data/Projects/maprisma-launcher/packages/maprisma_launcher_core/lib/src/packages.dart:18)), with install commands at line 104. Add them to [ask-ai-rules.md:53](/mnt/Data/Projects/maprisma-settings/docs/ask-ai-rules.md:53).

   I found no cargo/npm/brew Ask-install backend. Cargo/npm mentions concern CLI/helper discovery, not package-manager installation.

   Launcher’s action IDs otherwise cover its model action vocabulary, with explicit mapping needed for:
   
   - `hide` and `unhide` → `launcher.hide`.
   - Shortcut set/remove/**disable/restore** → `launcher.shortcuts`; broaden its description accordingly.
   - Listing shortcuts/hidden apps remains read-only, but mutation buttons within those results remain governed.
   - Batch operations apply the mapping to each affected target.

   See [ask_ai.dart:615](/mnt/Data/Projects/maprisma-launcher/packages/maprisma_launcher_core/lib/src/ask_ai.dart:615) and [core.dart:760](/mnt/Data/Projects/maprisma-launcher/packages/maprisma_launcher_core/lib/src/core.dart:760).

7. **Medium — “Proposed then blocked” is feasible, but requires different treatment in each app.**  
   [ask-ai-rules.md:9](/mnt/Data/Projects/maprisma-settings/docs/ask-ai-rules.md:9):

   - **Launcher:** Existing proposal cards suit disabled buttons. Keep policy-disabled sources discoverable; do not remove them from model/search inputs merely to enforce installation restrictions. Existing manager availability/preferences still apply.
   - **Theme:** Cards can remain, but result presentation already performs downloads: `_loadThumb` calls `webimg.get`, which fetches the full image into cache ([ask_page.dart:591](/mnt/Data/Projects/maprisma-theme/flutter_app/lib/pages/ask_page.dart:591), [web_images.dart:116](/mnt/Data/Projects/maprisma-theme/packages/maprisma_theme_core/lib/src/web_images.dart:116)). Define whether `theme.wallpapers` blocks network previews or only saving wallpapers. Otherwise a disabled “download” action still downloads before its button is used. Generation likewise needs gating before work starts.
   - **Settings:** There is no proposal approval button per step: the loop checks and immediately performs AI actions ([ai_update.dart:318](/mnt/Data/Projects/maprisma-settings/packages/maprisma_manager_core/lib/src/ai_update.dart:318)). Show blocked steps in its run view, or introduce a review phase. The statement that every change retains a review dialog is not true for this workflow; Launcher hide also executes directly ([ask_page.dart:83](/mnt/Data/Projects/maprisma-launcher/flutter_app/lib/ask_page.dart:83)).

8. **Medium — Keep `ai_updates` as explicit opt-in unless migration preserves its default-off behavior.**  
   Today `ai_updates` must be exactly true to start ([ai_update.dart:224](/mnt/Data/Projects/maprisma-settings/packages/maprisma_manager_core/lib/src/ai_update.dart:224)). Replacing it with the shared action’s default-allowed semantics would remove that opt-in.

   Recommended effective permission:

   `ai_updates == true && allowed(settings.updates)`

   Present these as activation versus permission, with a clear effective-state explanation. Alternatively merge into one setting only with an explicit migration preserving disabled installations.

   Map **update, reinstall and `pub_get`** to `settings.updates`; its current description omits dependency refresh ([ai_update.dart:39](/mnt/Data/Projects/maprisma-settings/packages/maprisma_manager_core/lib/src/ai_update.dart:39)). Decide whether preparatory `git fetch` is an audited mutation or an explicitly permitted preparation step.

9. **Medium — Log results and failure behavior need definitions that match execution.**  
   Launcher’s detached installs/system updates return `started`, not confirmed success ([core.dart:737](/mnt/Data/Projects/maprisma-launcher/packages/maprisma_launcher_core/lib/src/core.dart:737), [core.dart:520](/mnt/Data/Projects/maprisma-launcher/packages/maprisma_launcher_core/lib/src/core.dart:520)). Logging `done` then would be misleading. Add `started`/unknown outcome or track completion.

   Define whether logging failure prevents execution, how crashes leave unfinished actions, and whether `blocked` means an attempted execution or merely a disabled displayed proposal. Include an operation ID for correlating outcomes. Settings currently writes a separate whole-run log only at completion ([ai_update.dart:478](/mnt/Data/Projects/maprisma-settings/packages/maprisma_manager_core/lib/src/ai_update.dart:478)).

10. **Medium — Fail-open behavior and folder access weaken “switched-off always wins.”**  
    [ask-ai-rules.md:27](/mnt/Data/Projects/maprisma-settings/docs/ask-ai-rules.md:27) deliberately allows malformed values and unreadable files. A typo, corruption or transient read failure can therefore restore denied actions. Document that limitation or retain a last-known-valid restrictive policy and surface read errors.

    Folder denial also needs propagation into shared discovery. Downloads are scanned directly in Ask and again inside `_searchApps`, which serves both manual and AI search ([core.dart:1353](/mnt/Data/Projects/maprisma-launcher/packages/maprisma_launcher_core/lib/src/core.dart:1353), [core.dart:1116](/mnt/Data/Projects/maprisma-launcher/packages/maprisma_launcher_core/lib/src/core.dart:1116)). Define whether disabling access also invalidates cached local proposals and prevents execution from an earlier local review. The current decision formula has no folder check.
### Answers (Claude)

All ten taken; the contract was rewritten: proposal ids issued by each core (1), Theme ids install/edit/generate/wallpapers/apply with compound checks (2), an execution-boundary inventory (3), a never-renamed flock lock file for the log (4) and for the shared settings file, refusing to rewrite an unreadable file (5), sources apt/dnf/zypper (6), per-app 'proposed then blocked' incl. Settings' run view and the corrected review claim (7), ai_updates stays the opt-in (8), results started/op id and blocked defined (9), unreadable rules are restrictive and the folder switch blocks local installs (10).
