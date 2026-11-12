import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:maprisma_manager_core/maprisma_manager_core.dart' show tr;

import 'core_call.dart';
import 'desktop_page.dart';
import 'settings_widgets.dart';

/// About, as COSMIC Settings' page, read only: device name, hardware and the system. A click on
/// a row copies its value. Hyprland: `about.get`.
class AboutPage extends StatelessWidget {
  const AboutPage({super.key, required this.core});
  final CoreCall core;
  @override
  Widget build(BuildContext context) => DesktopSettingsPage(
    core: core,
    page: 'about',
    title: tr('About'),
    what: tr('the system information'),
    own: (_) => _About(core: core),
  );
}

class _About extends StatefulWidget {
  const _About({required this.core});
  final CoreCall core;
  @override
  State<_About> createState() => _AboutState();
}

class _AboutState extends State<_About> with RoutePage {
  @override
  CoreCall get core => widget.core;
  @override
  String get getRoute => 'about.get';

  Widget row(String key, String title, Object? value) {
    final text = value is List ? value.join('\n') : '${value ?? ''}';
    return SettingsItem(
      key: ValueKey('about-$key'),
      title: title,
      onTap: text.isEmpty
          ? null
          : () async {
              await Clipboard.setData(ClipboardData(text: text));
              tellOn(this, tr('Copied'));
            },
      trailing: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: Text(text.isEmpty ? '—' : text, textAlign: TextAlign.end, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = data;
    if (d == null) return SettingsPage(title: tr('About'), actions: reloadActions(), children: loadingOrError(context));
    return SettingsPage(
      title: tr('About'),
      actions: reloadActions(),
      children: [
        SettingsSection(children: [row('hostname', tr('Device name'), d['hostname'])]),
        SettingsSection(
          title: tr('Hardware'),
          children: [
            row('model', tr('Hardware model'), d['model']),
            row('memory', tr('Memory'), d['memory']),
            row('processor', tr('Processor'), d['processor']),
            row('graphics', tr('Graphics'), d['graphics']),
            row('disk', tr('Disk capacity'), d['disk']),
          ],
        ),
        SettingsSection(
          title: tr('Operating system'),
          children: [
            row('os', tr('Operating system'), d['os']),
            row('arch', tr('Operating system architecture'), d['arch']),
            row('kernel', tr('Kernel version'), d['kernel']),
            row('desktop', tr('Desktop environment'), d['desktop']),
            row('session', tr('Windowing system'), d['session']),
          ],
        ),
      ],
    );
  }
}
