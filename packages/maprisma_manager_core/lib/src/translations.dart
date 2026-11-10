import 'dart:io';

import 'translations_generated.dart';

const languageNames = <String, String>{
  'en': 'English', 'de': 'Deutsch', 'fr': 'Français', 'es': 'Español',
  'it': 'Italiano', 'pt': 'Português', 'nl': 'Nederlands', 'pl': 'Polski',
};

String systemLanguage(Map<String, String> environment) {
  final locale = ['LC_ALL', 'LC_MESSAGES', 'LANG']
      .map((key) => environment[key] ?? '')
      .firstWhere((value) => value.isNotEmpty, orElse: () => 'en');
  final code = locale.split(RegExp('[_ .@-]')).first.toLowerCase();
  return languageNames.containsKey(code) ? code : 'en';
}

String currentLanguage = 'en';
void configureLanguage(String? setting, [Map<String, String>? environment]) {
  currentLanguage = setting != null && languageNames.containsKey(setting)
      ? setting : systemLanguage(environment ?? Platform.environment);
}

String tr(String english) => catalogs[currentLanguage]?[english] ?? english;
String trf(String english, List<Object?> values) => tr(english).replaceAllMapped(
  RegExp(r'\{(\d+)\}'), (match) {
    final index = int.parse(match[1]!);
    return index < values.length ? '${values[index]}' : match[0]!;
  },
);

String uiLabel(Object? value) => switch (value) {
  'installed' => tr('Installed'),
  'absent' => tr('Not installed'),
  'partial' => tr('Partly installed'),
  'succeeded' => tr('Succeeded'),
  'failed' => tr('Failed'),
  'cancelled' => tr('Cancelled'),
  'interrupted' => tr('Interrupted'),
  'unknown' => tr('unknown'),
  'in' => tr('in the bar'),
  'out' => tr('Not in the bar'),
  'settings window' => tr('settings window'),
  'window' => tr('window'),
  'Maprisma Control is its bar icon.' => tr('Maprisma Control is its bar icon.'),
  'Maprisma\'s coloured logo: the applet draws the icon in its own colours (a symbolic icon shows dark grey)' => tr('Maprisma\'s coloured logo: the applet draws the icon in its own colours (a symbolic icon shows dark grey)'),
  'KDE shortcuts written by the app' => tr('KDE shortcuts written by the app'),
  'COSMIC shortcut entries (inside a shared file)' => tr('COSMIC shortcut entries (inside a shared file)'),
  'KDE keys written by the app' => tr('KDE keys written by the app'),
  'Analyze may add a vision projector entry here' => tr('Analyze may add a vision projector entry here'),
  'shared with the local LLM (llama.cpp): not removed with the app' => tr('shared with the local LLM (llama.cpp): not removed with the app'),
  'the COSMIC panel shows the kind of the connected device (status icons, kept); this icon shows in the popup, the KDE tray and the menus' => tr('the COSMIC panel shows the kind of the connected device (status icons, kept); this icon shows in the popup, the KDE tray and the menus'),
  'written by allow-access.sh via pkexec' => tr('written by allow-access.sh via pkexec'),
  'the COSMIC applet draws its built-in bulb (lit or dim by state, kept): a changed icon shows in the KDE tray and the menus' => tr('the COSMIC applet draws its built-in bulb (lit or dim by state, kept): a changed icon shows in the KDE tray and the menus'),
  'the COSMIC applet draws a built-in copy of its radar (with the signal colours): a changed icon shows in the KDE tray and the menus' => tr('the COSMIC applet draws a built-in copy of its radar (with the signal colours): a changed icon shows in the KDE tray and the menus'),
  'the KDE tray shows it while the reader is idle (playing and paused keep their own icons)' => tr('the KDE tray shows it while the reader is idle (playing and paused keep their own icons)'),
  'without it, prebuilt binaries in target/release are installed' => tr('without it, prebuilt binaries in target/release are installed'),
  'written by "Set up automatically"' => tr('written by "Set up automatically"'),
  'made by the reader\'s setup, shared with Omarchy\'s reader (kindle-reader): not removed with the app' => tr('made by the reader\'s setup, shared with Omarchy\'s reader (kindle-reader): not removed with the app'),
  'drop-in; other drop-ins are not ours' => tr('drop-in; other drop-ins are not ours'),
  'a prior one is backed up' => tr('a prior one is backed up'),
  'written by backend setup' => tr('written by backend setup'),
  '"Set up now"; refreshed by install.sh when managed' => tr('"Set up now"; refreshed by install.sh when managed'),
  'made by "Set up now", shared with Omarchy\'s video-trans: not removed with the app' => tr('made by "Set up now", shared with Omarchy\'s video-trans: not removed with the app'),
  '"Set up now"' => tr('"Set up now"'),
  'No bar icon; its settings are in Maprisma Theme.' => tr('No bar icon; its settings are in Maprisma Theme.'),
  'needs a running KWin' => tr('needs a running KWin'),
  'kwinrc and Krohnkite backups (never deleted)' => tr('kwinrc and Krohnkite backups (never deleted)'),
  '[Script-maprisma-tiling] keys (build = its hash), [Plugins] …Enabled' => tr('[Script-maprisma-tiling] keys (build = its hash), [Plugins] …Enabled'),
  'It is the bar for the others on KDE.' => tr('It is the bar for the others on KDE.'),
  'generated Plasma themes (maprisma-panel-color)' => tr('generated Plasma themes (maprisma-panel-color)'),
  'colour cache' => tr('colour cache'),
  '[Theme] name while a generated theme is active' => tr('[Theme] name while a generated theme is active'),
  'Opens from the app menu.' => tr('Opens from the app menu.'),
  _ => '$value',
};
