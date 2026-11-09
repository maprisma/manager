# Codex review of step 2 (bar control), with what was done

Run read-only (`codex exec -s read-only`), 2026-11-09, on the uncommitted step-2 work in this repo and
the `hidden` change in maprisma-panel. Every finding was checked in the code (and for 1 against the
Plasma/KConfig sources Codex linked) before fixing. Responses are at the end.

## Review

I found these concrete issues. **High** means core functionality can fail or user choices can be lost; **Medium** means incorrect behavior under a specific configuration or race.

1. **High — KDE config reads use an untyped default.** [bar_kde.dart:74](/mnt/Data/Projects/maprisma-manager/packages/maprisma_manager_core/lib/src/bar_kde.dart:74) calls `readConfig(key, null)`. Plasma passes that default to KConfig, whose decoding depends on the default’s QVariant type. Consequently, saved lists cannot be reliably decoded; zones/hidden state, revision comparisons, and verification after writing fail. The Python fake masks this by returning stored JSON directly. **Fix:** distinguish missing keys using `configKeys`, then read existing lists with a typed list default; verify actual Qt conversion in a Plasma integration test. See [Plasma’s implementation](https://github.com/KDE/plasma-workspace/blob/Plasma/6.5/shell/scripting/applet.cpp) and [KConfig decoding](https://github.com/KDE/kconfig/blob/master/src/core/kconfiggroup.cpp).

2. **High — The state lock excludes wanted-state updates and KDE changes.** [bar_cosmic.dart:195](/mnt/Data/Projects/maprisma-manager/packages/maprisma_manager_core/lib/src/bar_cosmic.dart:195) locks only an individual COSMIC write; [bar.dart:310](/mnt/Data/Projects/maprisma-manager/packages/maprisma_manager_core/lib/src/bar.dart:310) subsequently reads/modifies/writes `bar.json` without that lock. KDE’s mutation path never acquires it. Concurrent Managers can overwrite each other’s wanted state, or leave wanted state inconsistent with the last applied configuration. **Fix:** serialize the complete mutation, including wanted-state load/save and autostart changes. Add an in-process queue as well as the filesystem lock.

3. **High — `bar.apply` forgets the selected panel/widget.** [bar.dart:51](/mnt/Data/Projects/maprisma-manager/packages/maprisma_manager_core/lib/src/bar.dart:51) persists only area/index. A placement explicitly targeting COSMIC Dock is later reapplied to the default Panel at [bar.dart:338](/mnt/Data/Projects/maprisma-manager/packages/maprisma_manager_core/lib/src/bar.dart:338); KDE similarly reapplies to the first widget. This can duplicate an applet or change the wrong widget. A panel-specific removal also becomes a removal across all panels. **Fix:** persist the target instance and operation scope, and replay those targets explicitly.

4. **Medium — Manager’s KDE layout differs from what QML actually displays.** [bar.dart:120](/mnt/Data/Projects/maprisma-manager/packages/maprisma_manager_core/lib/src/bar.dart:120) retains all saved entries, including trays that are stopped, and appends implicit entries in catalog order. [main.qml:128](/mnt/Data/Projects/maprisma-panel/package/contents/ui/main.qml:128) displays only discovered entries and alphabetically sorts implicit ones. Manager also ignores QML’s legacy `order` fallback. Thus displayed indices and subsequent moves can disagree with the real panel. **Fix:** model configured placement separately from live entries, read the legacy order, and reproduce QML’s placement/sorting rules for editor data.

5. **Medium — A concurrent drag can undo a Manager placement while preserving its hidden flag.** [main.qml:126](/mnt/Data/Projects/maprisma-panel/package/contents/ui/main.qml:126) skips updates during dragging; [main.qml:162](/mnt/Data/Projects/maprisma-panel/package/contents/ui/main.qml:162) later saves every zone from those stale models. If Manager moves/removes an icon during the drag, dropping another icon overwrites Manager’s zone edits. The new `hidden` list survives, so hiding still works after refresh, but placement is lost. **Fix:** detect configuration changes during dragging and cancel/rebase the drop against current configuration before saving.

6. **Medium — Moving an entry between RON lists loses its comments.** [ron.dart:140](/mnt/Data/Projects/maprisma-manager/packages/maprisma_manager_core/lib/src/ron.dart:140) finds comments only in the destination list. Moving a commented applet between wings or between wings/center drops its attached comments from the source without transferring them. Rendering a commented `None` also discards its surrounding comments. **Fix:** carry item/comment metadata across lists and files, and replace only the `None` value span.

7. **Medium — RON escape handling can corrupt unknown IDs.** [ron.dart:223](/mnt/Data/Projects/maprisma-manager/packages/maprisma_manager_core/lib/src/ron.dart:223) interprets only `\n` and `\t`; for example, valid `\u{61}` becomes literal `u{61}`. Any subsequent rewrite changes that unknown ID. The writer also emits decoded newlines/tabs directly instead of escaping them. **Fix:** implement valid RON string escapes and preserve original string tokens where possible; reject unsupported syntax rather than silently changing values.

8. **Medium — Revision checks omit effective system defaults.** [bar_cosmic.dart:103](/mnt/Data/Projects/maprisma-manager/packages/maprisma_manager_core/lib/src/bar_cosmic.dart:103) hashes only user-file contents. When a user file is missing, changing its system default leaves the revision unchanged. `writeCosmic` can therefore accept a stale layout and write it over a newer effective default. **Fix:** include the effective source and contents in the revision and compare them again before writing.

9. **Medium — Panel reload detection can report success for an unrelated restart.** [bar_cosmic.dart:328](/mnt/Data/Projects/maprisma-manager/packages/maprisma_manager_core/lib/src/bar_cosmic.dart:328) watches only the first cosmic-panel process, accepts any fresh child as proof, and later accepts any other panel PID as recovery. With multiple panel processes, an unaffected existing process can satisfy “back” immediately while the signalled process remains down. **Fix:** track affected panel identities, distinguish pre-existing processes from replacements, and verify their recovery. PID-based TERM is used correctly; there is no `pkill -f`.

The remaining Plasma API constructs—`panels()`, `widgets(type)`, `currentConfigGroup`, `writeConfig`, and printed output returned through `evaluateScript`—are supported by the [Plasma implementation](https://github.com/KDE/plasma-workspace/tree/Plasma/6.5/shell/scripting).

Starting/stopping KDE trays is explicitly deferred to step 3 in the protocol, so I have not counted its absence as a step-2 bug.

Tests could not start: the specified Flutter wrapper attempted to write its cache on the read-only filesystem. No files were modified, and real COSMIC configuration was untouched.
## Responses

1. **Holds, fixed (not testable here).** `Applet::readConfig` hands the default to
   `KConfigGroup::readEntry(key, QVariant)`, which decodes by the default's type; an untyped `null` can't
   decode a StringList. The script now reads `configKeys` to tell a missing key (null) from a set one and
   reads set keys with a list default `[]`. Only a Plasma session can prove it; the fake checks the script.
2. **Holds, fixed.** The lock now covers the whole change (read, write, autostart, bar.json) and
   `bar.apply`; `writeCosmic` no longer takes it (an inner fcntl lock on a second descriptor would also
   have dropped the outer one on close). An in-process queue sits in front of the file lock. Tested with
   three concurrent changes in one process.
3. **Holds, fixed.** bar.json keeps `panel` (COSMIC) / `widget` (KDE) when the change named one;
   `bar.apply` puts the icon back there (a gone panel/widget: the default), and a removal from one
   named panel stays a removal from that panel only. Tested with the Dock.
4. **Partly holds, fixed where it matters.** The legacy `order` fallback and the title sort of entries
   in no zone (case-insensitive, like `localeCompare`) now follow main.qml. Stopped trays stay in the
   saved zones on purpose (they keep their place when they start again; the widget does the same) and
   are marked `shown: false`, so the editor can draw them faded; indices count them as the widget's
   config does.
5. **Holds, fixed in maprisma-panel.** A drag remembers the zones and `hidden` list it began with; when
   they changed by the drop (the Manager wrote them), the drop is cancelled and the rows refreshed
   instead of saving stale rows over the Manager's change.
6. **Holds, fixed for one file.** Comments now move with their id between the two lists of
   plugins_wings, and a `None` with comments around it has only the `None` replaced. Between the two
   files a moved id's comment stays behind (dropped with the item's old place); COSMIC writes these files
   without comments, so this is left.
7. **Holds, fixed.** Ids are written back exactly as they were spelled (the raw token), `\u{…}`, `\xHH`,
   `\0`, `\r` decode, unknown escapes are refused (the file is then `unreadable`, never rewritten), and new
   ids with newlines/tabs are escaped.
8. **Holds, fixed.** The revision covers each file's source (user/system/none) and the text in effect, so
   a changed system default refuses a stale change.
9. **Holds in principle, fixed.** cosmic-panel runs all instances in one process here; with more than one
   cosmic-panel process none is killed (reported instead), children of any of them count as a reaction,
   and "back" needs a panel process that didn't run before (pid + start time).

Not tested: KDE live (this machine runs COSMIC; a Plasma 6 session is needed for the scripting calls and
the widget's `hidden` list), and the panel-restart fallback live (cosmic-panel 1.11 reacts by itself, so
the fallback ran only against fakes).
