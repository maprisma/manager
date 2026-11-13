import 'dart:async';

import 'package:flutter/material.dart';
import 'package:maprisma_manager_core/maprisma_manager_core.dart' show tr, trf;

import 'animations_card.dart';
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
          description: trf('This desktop has its own settings app for {0}; Maprisma Settings leaves it to it.', [what]),
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
/// on every desktop, so the page opens it; on Hyprland the animations are set here too.
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
        // Hyprland only (the card hides itself elsewhere).
        AnimationsCard(core: core),
      ],
    );
  }
}

/// A page that shows one route's answer and changes things through others: [load] keeps only
/// the newest answer, [act] keeps the page busy until it shows the values as they are after the
/// change, and nothing touches the page once it is gone.
mixin RoutePage<T extends StatefulWidget> on State<T> {
  CoreCall get core;
  String get getRoute;
  Map<String, dynamic> get getParams => const {};

  Map<String, dynamic>? data;
  String? error;
  bool working = false;
  int _loads = 0;

  @override
  void initState() {
    super.initState();
    unawaited(load());
  }

  Future<void> load() => loadFrom(getRoute, getParams);

  /// The page's data from [route] (a scan, say): only the newest load or scan is shown, so a slow
  /// scan can't put back what a later change replaced.
  Future<void> loadFrom(String route, Map<String, dynamic> params) async {
    final mine = ++_loads;
    try {
      final r = await core(route, params);
      if (mounted && mine == _loads) {
        setState(() {
          data = r;
          error = null;
        });
      }
    } on ServiceError catch (e) {
      if (!mounted || mine != _loads) return;
      // With the page shown, the values stay and the failure is said; else it is the page.
      if (data != null) {
        tellOn(this, failure(e));
      } else {
        setState(() => error = failure(e));
      }
    }
  }

  /// [route] with [params]; false when it was refused (the snack bar says why).
  Future<bool> act(String route, Map<String, dynamic> params, {bool reload = true}) async {
    if (working) return false;
    setState(() => working = true);
    var ok = true;
    try {
      try {
        await core(route, params);
      } on ServiceError catch (e) {
        ok = false;
        tellOn(this, failure(e));
      }
      if (reload && mounted) await load();
    } finally {
      if (mounted) setState(() => working = false);
    }
    return ok;
  }

  /// The page's busy spinner and Reload, for the title.
  List<Widget> reloadActions() => [
    if (working) const Padding(padding: EdgeInsets.only(right: 8), child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))),
    IconButton(tooltip: tr('Reload'), onPressed: load, icon: const Icon(Icons.refresh)),
  ];

  /// While nothing is loaded: the spinner or the error.
  List<Widget> loadingOrError(BuildContext context) => [
    if (error != null)
      Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error))
    else
      const Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator())),
  ];
}

/// A dialog that picks one of many (time zones, apps) with a filter field; the value or null.
Future<String?> pickOne(BuildContext context, {required String title, required List<(String, String)> choices, String? current}) =>
    showDialog<String>(context: context, builder: (_) => _PickOne(title: title, choices: choices, current: current));

class _PickOne extends StatefulWidget {
  const _PickOne({required this.title, required this.choices, this.current});
  final String title;
  final List<(String, String)> choices;
  final String? current;
  @override
  State<_PickOne> createState() => _PickOneState();
}

class _PickOneState extends State<_PickOne> {
  String query = '';

  @override
  Widget build(BuildContext context) {
    final q = query.toLowerCase();
    final shown = [for (final c in widget.choices) if (q.isEmpty || c.$2.toLowerCase().contains(q) || c.$1.toLowerCase().contains(q)) c];
    return AlertDialog(
      title: Text(widget.title),
      contentPadding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      content: SizedBox(
        width: 420,
        height: 420,
        child: Column(
          children: [
            TextField(
              key: const ValueKey('pick-filter'),
              autofocus: true,
              decoration: InputDecoration(hintText: tr('Type to filter'), prefixIcon: const Icon(Icons.search, size: 20)),
              onChanged: (v) => setState(() => query = v),
              onSubmitted: (_) => shown.isEmpty ? null : Navigator.pop(context, shown.first.$1),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                itemCount: shown.length,
                itemBuilder: (_, i) => ListTile(
                  key: ValueKey('pick-${shown[i].$1}'),
                  dense: true,
                  selected: shown[i].$1 == widget.current,
                  title: Text(shown[i].$2),
                  onTap: () => Navigator.pop(context, shown[i].$1),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Cancel')))],
    );
  }
}
