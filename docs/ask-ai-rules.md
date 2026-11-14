# Ask AI rules (shared by every Maprisma app)

Uwe, 2026-11-14: Maprisma Settings › AI shows what each app's **Ask AI** may do and lets the user
switch it: per action, install sources, folder access, an overall level, and a log of what Ask AI
changed. Research behind it (desktop AI assistants, Windows agent settings, Claude Code permissions):
the *program* decides, never the AI; a switched-off action always wins. Reviewed by Codex (round 1:
docs/reviews/ask-ai-rules.md).

## Scope and trust boundary

- The rules apply to steps **Ask AI proposed**. What the user does by hand is never limited.
- Provenance: each app's **core** turns every Ask AI answer into **proposals** and gives each one an id
  (random, kept in the core's memory for the session) bound to its action id, target and source. Every
  execution route takes an optional `proposal`; with one, the core looks the proposal up (unknown or
  expired → refused), checks that the requested step is the one the proposal names, and applies the
  rules. Without one the step is manual. GUI and core ship together, so there is no older GUI to
  consider. **The id must travel with the step** through every card, review dialog, editor, queue and
  terminal command the step passes; a path that drops it is a bug (it would make the step manual).
  A proposal names all action ids of a compound step. When the user changes the target in an editor
  (e.g. edits a proposed theme), it stays the same proposal: the action ids are bound, the user's edit
  of the target is the user's own. Settings' AI updates check inside their own loop before each step. This protects against the AI, not against a deliberately dishonest client of the core.
- A switched-off action is still **proposed**: its button is disabled with "Switched off in Maprisma
  Settings › AI" and a link (`maprisma-settings --page ai`). Most changes also keep their review dialog;
  some steps run directly (Launcher hide/unhide, Settings' AI updates): the switches are their gate.
- Checks happen at every **execution boundary** (listed below), again after any asynchronous
  preparation and before the first change. Switching something off stops future steps; it can't undo
  an installer or terminal that is already running.

## The file

`${XDG_CONFIG_HOME:-~/.config}/maprisma-ai/settings.json` (folder 0700, file 0600; also holds `helper`
and `web_search`). New key:

```json
"ask_ai": {
  "level": "review",
  "actions": { "launcher.remove": false },
  "sources": { "aur": false },
  "folders": { "downloads": true }
}
```

- `level`: `"review"` (actions allowed by the switches) or `"answers"` (Ask AI only answers and
  suggests; every action is off).
- `actions`, `sources`, `folders`: id → boolean. `false` switches something off; a missing id or `true`
  = allowed. Unknown ids are kept and ignored.
- **Malformed values are restrictive:** a `level` other than the two = `answers`; an `actions`,
  `sources` or `folders` that isn't an object = everything of that kind off; a known id whose value isn't
  a boolean = off. Settings shows such a file as broken and offers to reset the rules.
- **Reading:** a missing file or a file without `ask_ai` = defaults (all allowed, level review). A file
  that exists but can't be read or parsed, is over 64 KiB, or has an `ask_ai` that isn't an object =
  **restrictive**: level `answers` (Settings shows the error and offers to reset the rules).
- **Writing (every app, every key):** take an exclusive `flock` (libc, LOCK_EX) on the lock file
  `maprisma-ai/settings.lock` (never renamed, 0600), then read, change one key, write a temp file
  (0600, O_EXCL) in the folder, fsync, rename over `settings.json`, release. If the file exists but
  can't be read or parsed, **refuse** to write (never rebuild it from one key). Only Settings writes
  `ask_ai`; Launcher and Theme write `helper` with the same protocol.

### Action ids (fixed) and their execution boundaries

| id | what | execution routes (core), with a proposal |
|---|---|---|
| `launcher.install` | install an app (any source) | `packages.install` (incl. cached local reviews); `term.start` with an install command |
| `launcher.remove` | uninstall apps | `apps.uninstall`; `term.start` with `action: uninstall` or `uninstall_all` |
| `launcher.update` | update apps | `updates.flatpak`, `updates.appimage`, `updates.appimage_restore` |
| `launcher.update_system` | system update | `updates.system`; `term.start` with `action: system` |
| `launcher.hide` | hide and unhide apps | `apps.hide` (`hidden: true` or `false`) |
| `launcher.shortcuts` | add, remove, disable, restore shortcuts | `shortcuts.set`, `shortcuts.remove`, `shortcuts.disable`, `shortcuts.restore` |
| `theme.apply` | apply a theme or a wallpaper | `themes.apply`, `wallpapers.set`; the `apply`/`set` part of the routes below |
| `theme.install` | install a theme from a catalog | `import.omarchy_install`, `import.cosmic_install`, `import.kde_install` |
| `theme.edit` | create, copy or save a custom theme | `custom.save` (it also **reapplies the current theme** when that one is edited: then `theme.apply` too) |
| `theme.generate` | generate a picture, set up the generator | `create.make`, `create.setup` |
| `theme.wallpapers` | add wallpapers (downloaded or generated) | `wallhaven.add`, `webimg.add`, `create.add` (with `set: true` also `theme.apply`) |
| `settings.updates` | update, reinstall, refresh packages of Maprisma apps | each step of Settings' AI update loop (update, reinstall, pub_get) |

A compound step (e.g. install a theme and apply it, add a wallpaper and apply it) needs **all** its ids
and is checked completely before its first change. Batch steps apply the id to each target.
`settings.updates` applies only while "Let AI do the updates" (`ai_updates`) is on: that switch stays the
opt-in; the rule can switch it off on top. `git fetch` before an update is preparation, not gated.

Answers only, always on (shown on the page, no switch): Launcher suggestions, explanations and lists
(shortcuts, hidden apps), Theme answers and previews, Notifier "Check with AI", Playground chat.

### Source ids (Launcher installs)

`pacman`, `aur`, `apt`, `dnf`, `zypper`, `flatpak`, `snap`, `github`, `local` (an AppImage in the
Downloads folder). A switched-off source: its suggestions are still found and shown, their Install… is
blocked.

### Folder ids

`downloads`: Launcher scans the Downloads folder for AppImages for Ask AI. Off: no scan for Ask AI
(manual Install apps search still shows them) and source `local` is blocked for AI proposals.

### The decision (each app's core, at each execution boundary)

```
allowed(action, source?) = level != "answers"
                           && actions[action] != false
                           && (source == null || sources[source] != false)
                           && (source != "local" || folders["downloads"] != false)
```

## The log

Data: `${XDG_STATE_HOME:-~/.local/state}/maprisma-ai/actions.jsonl`; lock: `actions.lock` next to it
(never renamed). The folder must be a real folder owned by the user (no link; created 0700); files are
0600, opened with O_NOFOLLOW and checked to be regular files owned by the user; otherwise nothing is
logged. Protocol for every writer (and Settings' clear):

1. open and `flock` (LOCK_EX) `actions.lock`;
2. open `actions.jsonl` (O_WRONLY|O_APPEND|O_CREAT|O_NOFOLLOW, 0600) after the lock;
3. write one complete UTF-8 JSON line (loop until fully written);
4. above 1000 lines **or 1 MiB** keep the newest 500 complete lines (an unterminated last line is
   dropped): temp file created O_EXCL 0600 in the same folder, written, fsync, renamed over the log,
   still under the lock;
5. close the data file, then release the lock.

Readers read at most the last 1 MiB and skip incomplete or malformed lines. The log is a record:
fsync only on rotation, and a failure to log never blocks or undoes a step.

```json
{"time": "2026-11-14T12:30:00Z", "op": "3f9c…", "app": "launcher", "action": "launcher.install",
 "target": "mission-center (pacman)", "result": "started"}
```

- `op`: the proposal id (one per executed step), so later lines can complete it.
- `result`: `started` (handed to an installer/terminal whose end isn't known), `done`, `failed`,
  `blocked` (an execution was attempted and refused by the rules; a disabled button that isn't pressed
  is not logged), `cancelled`.
- `target`: at most 200 characters, no secrets.
