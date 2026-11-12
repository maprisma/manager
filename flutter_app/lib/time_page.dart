import 'package:flutter/material.dart';
import 'package:maprisma_manager_core/maprisma_manager_core.dart' show tr;

import 'core_call.dart';
import 'desktop_page.dart';
import 'settings_widgets.dart';

/// Time & Language, as COSMIC Settings' Date & time and Region & language: automatic time, the
/// time zone (timedatectl), the system language and formats (localectl). Changes ask for the
/// administrator's password (polkit). Hyprland: `timelang.get`, `time.*`, `locale.set`.
class TimePage extends StatelessWidget {
  const TimePage({super.key, required this.core});
  final CoreCall core;
  @override
  Widget build(BuildContext context) => DesktopSettingsPage(
    core: core,
    page: 'time',
    title: tr('Time & Language'),
    what: tr('the date, time and language'),
    own: (_) => _Time(core: core),
  );
}

class _Time extends StatefulWidget {
  const _Time({required this.core});
  final CoreCall core;
  @override
  State<_Time> createState() => _TimeState();
}

class _TimeState extends State<_Time> with RoutePage {
  @override
  CoreCall get core => widget.core;
  @override
  String get getRoute => 'timelang.get';

  /// "de_DE.UTF-8" → "de_DE (UTF-8)".
  static String locale(String l) => l.contains('.') ? '${l.substring(0, l.indexOf('.'))} (${l.substring(l.indexOf('.') + 1)})' : l;

  @override
  Widget build(BuildContext context) {
    final d = data;
    if (d == null) return SettingsPage(title: tr('Time & Language'), actions: reloadActions(), children: loadingOrError(context));
    final t = d['time'] as Map, l = d['locale'] as Map;
    final zones = (t['zones'] as List).cast<String>();
    final locales = (l['locales'] as List).cast<String>();
    List<(String, String)> localeChoices(String current) => [
      if (!locales.contains(current)) (current, current.isEmpty ? tr('None') : locale(current)),
      for (final x in locales) (x, locale(x)),
    ];
    return SettingsPage(
      title: tr('Time & Language'),
      actions: reloadActions(),
      children: [
        SettingsSection(
          title: tr('Date & time'),
          note: tr('Changes ask for the administrator\'s password.'),
          children: [
            SettingsToggle(
              key: const ValueKey('time-ntp'),
              title: tr('Automatic date and time'),
              description: tr('Set the time from the internet.'),
              value: t['ntp'] == true,
              onChanged: working || t['canNtp'] == false ? null : (v) => act('time.set_ntp', {'on': v}),
            ),
            SettingsItem(
              title: tr('Time zone'),
              trailing: TextButton(
                key: const ValueKey('time-zone'),
                onPressed: working
                    ? null
                    : () async {
                        final z = await pickOne(context, title: tr('Time zone'), choices: [for (final z in zones) (z, z.replaceAll('_', ' '))], current: '${t['timezone']}');
                        if (z != null && z != t['timezone']) await act('time.set_timezone', {'zone': z});
                      },
                child: Text('${t['timezone']}'.replaceAll('_', ' ')),
              ),
            ),
          ],
        ),
        SettingsSection(
          title: tr('Region & language'),
          note: tr('Takes effect after logging in again.'),
          children: [
            SettingsChoice<String>(
              key: const ValueKey('locale-lang'),
              title: tr('Language'),
              description: tr('The system\'s language (LANG).'),
              value: '${l['lang']}',
              choices: localeChoices('${l['lang']}'),
              onChanged: working ? null : (v) => act('locale.set', {'lang': v}),
            ),
            SettingsChoice<String>(
              key: const ValueKey('locale-formats'),
              title: tr('Formats'),
              description: tr('Dates, times, numbers, money and measurements.'),
              value: '${l['formats']}',
              choices: localeChoices('${l['formats']}'),
              onChanged: working ? null : (v) => act('locale.set', {'formats': v}),
            ),
          ],
        ),
      ],
    );
  }
}
