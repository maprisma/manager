import 'dart:async';

import 'package:flutter/material.dart';
import 'package:maprisma_manager_core/maprisma_manager_core.dart' show tr, trf;

import 'app_facts.dart' show installed;
import 'backend.dart' show ServiceError;
import 'core_call.dart';
import 'settings_widgets.dart';

/// Shows a snack bar (when the page is still there).
void tellOn(State state, String text) {
  if (!state.mounted) return;
  ScaffoldMessenger.of(state.context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));
}

String failure(ServiceError e) => trf('That did not work ({0}){1}', [e.code, e.reason == null || e.reason!.isEmpty ? '' : ': ${e.reason}']);

/// The card that sends a page to the desktop's own settings app (`native.*`): "Sound is set in
/// COSMIC Settings" and a button per module (KDE splits some pages).
class NativeSection extends StatelessWidget {
  const NativeSection({super.key, required this.core, required this.native, required this.what});
  final CoreCall core;

  /// `native.get`'s answer (with links).
  final Map<String, dynamic> native;

  /// What the page sets ("the sound", …) for the description.
  final String what;

  @override
  Widget build(BuildContext context) {
    final name = '${native['name']}';
    final links = (native['links'] as List).cast<Map>();
    final missing = links.every((l) => l['available'] != true);
    Future<void> open(int i) async {
      try {
        await core('native.open', {'page': native['page'], 'index': i});
      } on ServiceError catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(SnackBar(content: Text(failure(e))));
        }
      }
    }

    return SettingsSection(
      note: missing ? trf('{0} was not found.', [name]) : null,
      children: [
        SettingsItem(
          title: trf('This is set in {0}', [name]),
          description: trf('This desktop has its own settings app for {0}; the Manager leaves it to it.', [what]),
          trailing: links.length == 1
              ? FilledButton.tonal(
                  key: const ValueKey('native-open-0'),
                  onPressed: links.first['available'] == true ? () => open(0) : null,
                  child: Text(trf('Open {0}', [name])),
                )
              : null,
        ),
        if (links.length > 1)
          for (var i = 0; i < links.length; i++)
            SettingsItem(
              title: '${links[i]['label']}',
              onTap: links[i]['available'] == true ? () => open(i) : null,
              trailing: IconButton(
                key: ValueKey('native-open-$i'),
                tooltip: trf('Open {0}', [name]),
                onPressed: links[i]['available'] == true ? () => open(i) : null,
                icon: const Icon(Icons.open_in_new, size: 18),
              ),
            ),
      ],
    );
  }
}

/// A page of the sidebar that COSMIC and KDE set in their own app: there the native card; on
/// Hyprland (and other desktops) [own] builds the Manager's own sections.
class DesktopSettingsPage extends StatefulWidget {
  const DesktopSettingsPage({super.key, required this.core, required this.page, required this.title, required this.what, required this.own, this.actions});
  final CoreCall core;
  final String page, title, what;

  /// The Manager's own sections (called only where the desktop has no settings app for it) and
  /// the title's buttons.
  final Widget Function(BuildContext context) own;
  final List<Widget> Function(BuildContext context)? actions;
  @override
  State<DesktopSettingsPage> createState() => _DesktopSettingsPageState();
}

class _DesktopSettingsPageState extends State<DesktopSettingsPage> {
  Map<String, dynamic>? native;
  String? error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final r = await widget.core('native.get', {'page': widget.page});
      if (mounted) setState(() => native = r);
    } on ServiceError catch (e) {
      if (mounted) setState(() => error = failure(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final n = native;
    if (n == null) {
      return SettingsPage(
        title: widget.title,
        children: [
          if (error != null)
            Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error))
          else
            const Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator())),
        ],
      );
    }
    if ((n['links'] as List).isNotEmpty) {
      return SettingsPage(title: widget.title, children: [NativeSection(core: widget.core, native: n, what: widget.what)]);
    }
    return widget.own(context);
  }
}

/// The Appearance page: Maprisma Theme does the look (colours, wallpaper, fonts, icons, corners)
/// on every desktop, so the page opens it.
class AppearancePage extends StatelessWidget {
  const AppearancePage({super.key, required this.core, required this.theme, this.onShowApps});
  final CoreCall core;

  /// Maprisma Theme's entry of apps.list (null: not known yet).
  final Map<String, dynamic>? theme;

  /// "Install it on the Apps page".
  final VoidCallback? onShowApps;

  @override
  Widget build(BuildContext context) {
    final ready = theme != null && installed(theme!) && theme!['open'] == true;
    return SettingsPage(
      title: tr('Appearance'),
      children: [
        SettingsSection(
          children: [
            SettingsItem(
              leading: const Icon(Icons.palette_outlined),
              title: tr('Maprisma Theme'),
              description: tr('Colours, light and dark, wallpaper, fonts, icons and window corners are set in Maprisma Theme, on every desktop.'),
              trailing: ready
                  ? FilledButton.tonal(
                      key: const ValueKey('appearance-open-theme'),
                      onPressed: () async {
                        try {
                          await core('apps.open', {'id': 'theme'});
                        } on ServiceError catch (e) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context)
                              ..hideCurrentSnackBar()
                              ..showSnackBar(SnackBar(content: Text(failure(e))));
                          }
                        }
                      },
                      child: Text(tr('Open Maprisma Theme')),
                    )
                  : OutlinedButton(key: const ValueKey('appearance-install-theme'), onPressed: onShowApps, child: Text(tr('Install it on the Apps page'))),
            ),
          ],
        ),
      ],
    );
  }
}
