import 'package:flutter/material.dart';
import 'package:maprisma_manager_core/maprisma_manager_core.dart' show tr, trf;

import 'core_call.dart';
import 'desktop_page.dart';
import 'settings_widgets.dart';

/// Applications, as COSMIC Settings' Default applications and Startup applications: the
/// default app per role (xdg-mime) and what starts at login (~/.config/autostart, switched with
/// Hidden=). Maprisma's trays are left to the Bar page. Hyprland: `applications.get`,
/// `apps_default.set`, `autostart.*`.
class ApplicationsPage extends StatelessWidget {
  const ApplicationsPage({super.key, required this.core});
  final CoreCall core;
  @override
  Widget build(BuildContext context) => DesktopSettingsPage(
    core: core,
    page: 'applications',
    title: tr('Applications'),
    what: tr('the default and startup applications'),
    own: (_) => _Applications(core: core),
  );
}

class _Applications extends StatefulWidget {
  const _Applications({required this.core});
  final CoreCall core;
  @override
  State<_Applications> createState() => _ApplicationsState();
}

class _ApplicationsState extends State<_Applications> with RoutePage {
  @override
  CoreCall get core => widget.core;
  @override
  String get getRoute => 'applications.get';

  static String role(String r) => switch (r) {
    'browser' => tr('Web browser'),
    'files' => tr('File manager'),
    'mail' => tr('Mail client'),
    'music' => tr('Music'),
    'video' => tr('Video'),
    'photos' => tr('Photos'),
    'calendar' => tr('Calendar'),
    'text' => tr('Text editor'),
    _ => r,
  };

  Future<void> addApp(List<Map> addable) async {
    final app = await pickOne(context, title: tr('Add app'), choices: [for (final a in addable) ('${a['id']}', '${a['name']}')]);
    if (app != null) await act('autostart.add', {'app': app});
  }

  @override
  Widget build(BuildContext context) {
    final d = data;
    if (d == null) return SettingsPage(title: tr('Applications'), actions: reloadActions(), children: loadingOrError(context));
    final roles = (d['roles'] as List).cast<Map>();
    final auto = d['autostart'] as Map;
    final entries = (auto['entries'] as List).cast<Map>();
    final addable = (auto['addable'] as List).cast<Map>();
    final trays = auto['maprismaTrays'] as int? ?? 0;
    return SettingsPage(
      title: tr('Applications'),
      actions: reloadActions(),
      children: [
        SettingsSection(
          title: tr('Default applications'),
          children: [
            for (final r in roles)
              SettingsChoice<String>(
                key: ValueKey('default-${r['role']}'),
                title: role('${r['role']}'),
                value: '${r['current']}',
                choices: [
                  if (!(r['apps'] as List).any((a) => (a as Map)['id'] == r['current']))
                    ('${r['current']}', '${r['current']}'.isEmpty ? tr('None') : '${r['currentName'] ?? r['current']}'),
                  for (final a in (r['apps'] as List).cast<Map>()) ('${a['id']}', '${a['name']}'),
                ],
                onChanged: working ? null : (v) => v.isEmpty ? null : act('apps_default.set', {'role': r['role'], 'app': v}),
              ),
          ],
        ),
        SettingsSection(
          title: tr('Startup applications'),
          note: trays > 0 ? trf('Maprisma\'s {0} tray apps start with the bar: put them in or out on the Bar page.', [trays]) : null,
          children: [
            for (final e in entries)
              SettingsItem(
                key: ValueKey('autostart-${e['file']}'),
                title: '${e['name']}',
                description: e['here'] == true ? null : tr('Not started on this desktop'),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Switch(value: e['on'] == true, onChanged: working ? null : (v) => act('autostart.set', {'file': e['file'], 'on': v})),
                    IconButton(
                      key: ValueKey('autostart-remove-${e['file']}'),
                      tooltip: tr('Remove'),
                      onPressed: working ? null : () => act('autostart.remove', {'file': e['file']}),
                      icon: const Icon(Icons.delete_outline, size: 20),
                    ),
                  ],
                ),
              ),
            SettingsItem(
              title: tr('Add app'),
              trailing: IconButton(key: const ValueKey('autostart-add'), tooltip: tr('Add app'), onPressed: working || addable.isEmpty ? null : () => addApp(addable), icon: const Icon(Icons.add)),
            ),
          ],
        ),
      ],
    );
  }
}
