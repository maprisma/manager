# Interface languages

Maprisma Manager supports English, Deutsch, Français, Español, Italiano,
Português, Nederlands and Polski. The globe button in the main toolbar opens
**Language**. **System (<name>)** follows the first nonempty LC_ALL,
LC_MESSAGES or LANG. Region, encoding and modifiers are ignored; unsupported
languages use English. An explicit choice overrides the environment.

The choice takes effect immediately in the UI and core isolate and is saved as
`language` (`auto` or a supported code) in
`$XDG_CONFIG_HOME/maprisma-manager/settings.json` (default
`~/.config/maprisma-manager/settings.json`). Other settings are preserved.
Previously recorded logs retain the language in which they were produced.

English is the translation key: `tr('Close')` and
`trf('Install release {0}', [tag])`. Missing keys fall back to English, and
placeholder substitution never recursively substitutes values. Names, paths,
versions, external descriptions and subprocess output are data, not translated.
Flutter's standard Material controls use its bundled localization delegates.

Manager has no Omarchy original catalog. All its translations are authored in
`translations/<code>.json`; Launcher `i18n/extra.json` and Playground
`translations/` were consulted read-only for shared wording and terminology.
`translations/extra/<code>.json` is intentionally empty: Manager's own texts all
belong to its base catalog. Catalog technical notes used only by the CLI remain
English. Notes that actually appear in the interface are translated through the
presentation mapping in `translations.dart`, keeping catalog data intact.
Desktop Name and Comment also have all seven localized entries; the product
name remains Maprisma Manager.

Run `tools/gen-translations` after changing a catalog. It uses only Python's
standard library and embeds all catalogs in
`packages/maprisma_manager_core/lib/src/translations_generated.dart`.
`tools/install-local` regenerates them before building. No runtime translation
files or downloads are required. The core translation test scans both libraries
for literal tr/trf keys, verifies every language and its placeholders, and
checks that the generated source matches the JSON catalogs. It also tests locale
precedence, fallback, settings persistence and immediate core-language changes.
Flutter tests cover every supported locale and switching from the Language menu.

## Change inventory and validation

782 literal translation call sites are wrapped. Each language has 694 base keys
and zero extra keys. The seven desktop Comment translations are included in the
same catalog inventory; product names intentionally stay unchanged.

Validation: all 179 core tests passed (serial run), including the new coverage,
locale and persistence tests. Dart analysis reports no issues. The core executable
and Flutter Linux release assets/AOT compile successfully using cached tools.
The normal Linux build is blocked when its nested Flutter wrapper writes the
read-only SDK cache. Both Flutter test files are blocked before loading because
the sandbox denies the runner's localhost listening socket.

Changed files:

- `docs/localization.md`
- `flutter_app/lib/app.dart`
- `flutter_app/lib/app_facts.dart`
- `flutter_app/lib/apps_page.dart`
- `flutter_app/lib/backend.dart`
- `flutter_app/lib/bar_editor.dart`
- `flutter_app/lib/details_dialog.dart`
- `flutter_app/lib/icon_picker.dart`
- `flutter_app/lib/job_sheet.dart`
- `flutter_app/lib/jobs_model.dart`
- `flutter_app/lib/main.dart`
- `flutter_app/lib/remove_dialog.dart`
- `flutter_app/pubspec.lock`
- `flutter_app/pubspec.yaml`
- `flutter_app/test/translations_test.dart`
- `packages/maprisma_manager_core/lib/maprisma_manager_core.dart`
- `packages/maprisma_manager_core/lib/src/bar.dart`
- `packages/maprisma_manager_core/lib/src/bar_cosmic.dart`
- `packages/maprisma_manager_core/lib/src/bar_kde.dart`
- `packages/maprisma_manager_core/lib/src/bar_read.dart`
- `packages/maprisma_manager_core/lib/src/core.dart`
- `packages/maprisma_manager_core/lib/src/discovery.dart`
- `packages/maprisma_manager_core/lib/src/git.dart`
- `packages/maprisma_manager_core/lib/src/github.dart`
- `packages/maprisma_manager_core/lib/src/icons.dart`
- `packages/maprisma_manager_core/lib/src/jobs.dart`
- `packages/maprisma_manager_core/lib/src/jobs_pacman.dart`
- `packages/maprisma_manager_core/lib/src/jobs_self.dart`
- `packages/maprisma_manager_core/lib/src/kde_remove.dart`
- `packages/maprisma_manager_core/lib/src/ownership.dart`
- `packages/maprisma_manager_core/lib/src/paths.dart`
- `packages/maprisma_manager_core/lib/src/receipts.dart`
- `packages/maprisma_manager_core/lib/src/removal.dart`
- `packages/maprisma_manager_core/lib/src/run.dart`
- `packages/maprisma_manager_core/lib/src/status.dart`
- `packages/maprisma_manager_core/lib/src/sysproc.dart`
- `packages/maprisma_manager_core/lib/src/translations.dart`
- `packages/maprisma_manager_core/lib/src/translations_generated.dart`
- `packages/maprisma_manager_core/lib/src/trees.dart`
- `packages/maprisma_manager_core/test/translations_test.dart`
- `packaging/com.maprisma.Manager.desktop`
- `tools/gen-translations`
- `tools/install-local`
- `translations/de.json`
- `translations/en.json`
- `translations/es.json`
- `translations/extra/de.json`
- `translations/extra/en.json`
- `translations/extra/es.json`
- `translations/extra/fr.json`
- `translations/extra/it.json`
- `translations/extra/nl.json`
- `translations/extra/pl.json`
- `translations/extra/pt.json`
- `translations/fr.json`
- `translations/it.json`
- `translations/nl.json`
- `translations/pl.json`
- `translations/pt.json`
