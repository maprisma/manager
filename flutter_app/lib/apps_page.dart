import 'dart:io';
import 'package:maprisma_manager_core/maprisma_manager_core.dart' show tr, trf, languageNames, systemLanguage;
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_facts.dart';
import 'app_icon.dart';
import 'backend.dart' show ServiceError;
import 'bar_editor.dart';
import 'core_call.dart';
import 'details_dialog.dart';
import 'icon_picker.dart';
import 'job_sheet.dart';
import 'jobs_model.dart';
import 'remove_dialog.dart';
import 'theme.dart';

/// The Maprisma apps in one filterable list, as Maprisma Launcher's Plugins page lists Omarchy's
/// plugins: sections by bar state, a ⋮ menu per app (also on right-click), update marks with the
/// number of new commits, and the log sheet of the jobs at the bottom.
class AppsPage extends StatefulWidget {
  const AppsPage({super.key, required this.core, required this.jobs, this.onRestart, this.checkOnStart = true, this.onLanguageChanged, this.languageSetting = 'auto', this.cornersSetting = 'windows', this.screenshotKey = true, this.onSettingsChanged});
  final Future<void> Function()? onLanguageChanged;
  final String languageSetting;

  /// The settings menu: Corners and F12 saves a screenshot; [onSettingsChanged] reloads them.
  final String cornersSetting;
  final bool screenshotKey;
  final Future<void> Function()? onSettingsChanged;
  final CoreCall core;
  final JobsModel jobs;

  /// The Manager's own update is staged: quit so the helper can swap it in.
  final VoidCallback? onRestart;

  /// git fetch + GitHub refresh (at most every 30 minutes) when the page opens.
  final bool checkOnStart;
  @override
  State<AppsPage> createState() => AppsPageState();
}

class AppsPageState extends State<AppsPage> {
  List<App> apps = [];

  /// New Maprisma apps the catalog doesn't know (apps.list's `discovered`): shown, cloneable.
  List<Map<String, dynamic>> discovered = [];
  String desktop = 'cosmic';
  bool loading = true;
  bool checking = false;
  String? error;
  String query = '';
  bool sheet = false;
  final filter = TextEditingController();
  final filterFocus = FocusNode();

  /// icons.get per app (whether its bar icon was changed): fetched in the background.
  final Map<String, Map<String, dynamic>> icons = {};

  @override
  void initState() {
    super.initState();
    widget.jobs.onFinished = _jobEnded;
    widget.jobs.addListener(_jobsChanged);
    unawaited(_load().then((_) {
      if (widget.checkOnStart) unawaited(checkUpdates());
    }));
  }

  @override
  void dispose() {
    widget.jobs.removeListener(_jobsChanged);
    filter.dispose();
    filterFocus.dispose();
    super.dispose();
  }

  void _jobsChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    try {
      final r = await widget.core('apps.list');
      if (!mounted) return;
      setState(() {
        apps = [for (final x in r['apps'] as List) Map<String, dynamic>.from(x as Map)];
        discovered = [
          for (final x in ((r['discovered'] as Map?)?['apps'] as List?) ?? const [])
            if (x is Map) Map<String, dynamic>.from(x),
        ];
        desktop = '${r['desktop'] ?? 'other'}';
        loading = false;
        error = null;
      });
      unawaited(_loadIcons());
    } on ServiceError catch (e) {
      if (mounted) {
        setState(() {
          loading = false;
          error = trf('The list could not be read ({0}{1})', [e.code, e.reason == null ? '' : ': ${e.reason}']);
        });
      }
    }
  }

  Future<void> reload() => _load();

  Future<void> _loadIcons() async {
    for (final a in [...apps]) {
      if (!installed(a) || !hasBar(a)) continue;
      try {
        final r = await widget.core('icons.get', {'app': a['id'], 'limit': 1});
        icons[a['id'] as String] = r;
      } on ServiceError {
        icons.remove(a['id']);
      }
    }
    if (mounted) setState(() {});
  }

  /// "Check for updates": git fetch and the GitHub facts (forced from the button).
  Future<void> checkUpdates({bool force = false}) async {
    if (checking) return;
    setState(() => checking = true);
    try {
      await Future.wait([
        widget.core('git.fetch', {'force': force}).catchError((_) => <String, dynamic>{}),
        widget.core('github.refresh', {'force': force}).catchError((_) => <String, dynamic>{}),
      ]);
      await _load();
      if (force && mounted) {
        final n = apps.where((a) => updateReasons(a).isNotEmpty).length;
        tell(n == 0 ? tr('Everything is up to date') : (n == 1 ? tr('1 app has an update') : trf('{0} apps have updates', [n])));
      }
    } finally {
      if (mounted) setState(() => checking = false);
    }
  }

  void tell(String text) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));

  void _jobEnded(JobView j) {
    unawaited(_load());
    if (!mounted) return;
    final r = j.result;
    if (j.app == 'manager' && r['restart'] == true) {
      // Jobs this window already started finish first (the core starts no new one meanwhile).
      if (widget.jobs.busy) {
        tell(tr('Maprisma Manager restarts with the new build when the other jobs have finished'));
        void waitThem() {
          if (widget.jobs.busy) return;
          widget.jobs.removeListener(waitThem);
          Timer(const Duration(milliseconds: 1500), () => widget.onRestart?.call());
        }

        widget.jobs.addListener(waitThem);
        return;
      }
      tell(tr('Maprisma Manager restarts with the new build…'));
      Timer(const Duration(milliseconds: 1500), () => widget.onRestart?.call());
      return;
    }
    tell(switch (j.state) {
      'succeeded' => r['up_to_date'] == true ? trf('{0} is up to date', [j.name]) : trf('{0}: done', [j.name]),
      'cancelled' => trf('{0}: cancelled, nothing was changed', [j.name]),
      _ => '${j.name}: ${r['message'] ?? r['code'] ?? j.state}',
    });
  }

  Future<void> _do(String route, Map<String, dynamic> params, {String? done}) async {
    try {
      await widget.core(route, params);
      if (done != null) tell(done);
    } on ServiceError catch (e) {
      tell(trf('That did not work ({0}){1}', [e.code, e.reason == null || e.reason!.isEmpty ? '' : ': ${e.reason}']));
    }
    await _load();
  }

  Future<void> startJob(App a, String kind, {Map<String, dynamic> options = const {}}) async {
    try {
      await widget.jobs.start(
        app: a['id'] as String,
        name: '${a['name']}',
        kind: kind,
        options: options,
        password: a['id'] == 'maprisma' || '${a['kind']}'.contains('pacman'),
      );
      setState(() => sheet = true);
    } on ServiceError catch (e) {
      tell('${a['name']}: ${e.reason ?? e.code}');
    }
  }

  /// Move left/right inside its area (the bar's real order, read from bar.get).
  Future<void> _nudge(App a, int by) async {
    try {
      final bar = await widget.core('bar.get');
      final areas = bar['areas'] as Map? ?? const {};
      final id = (a['bar'] as Map)['id'];
      for (final area in ['left', 'center', 'right']) {
        final list = (areas[area] as List?) ?? [];
        final i = list.indexWhere((e) => (e as Map)['app'] == a['id'] || e['id'] == id);
        if (i < 0) continue;
        final to = i + by;
        if (to < 0 || to >= list.length) {
          tell(trf('It is already at the {0} of the {1} area', [by < 0 ? tr('start') : tr('end'), zoneName(area)]));
          return;
        }
        await _do('bar.move', {'app': a['id'], 'area': area, 'index': to, 'revision': bar['revision']});
        return;
      }
      tell(tr('It is not in the bar'));
    } on ServiceError catch (e) {
      tell(trf('That did not work ({0})', [e.code]));
    }
  }

  Future<void> _openGithub(App a) async {
    final url = githubUrl(a);
    if (url == null) return;
    await _do('links.open', {'url': url});
  }

  Future<void> openBarEditor() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => BarEditorPage(core: widget.core, apps: apps)));
    await _load();
  }

  Future<void> openDetails(App a) async {
    await showDialog<void>(context: context, builder: (_) => DetailsDialog(core: widget.core, app: a, desktop: desktop));
  }

  Future<void> _changeIcon(App a) async {
    final changed = await showDialog<bool>(context: context, builder: (_) => IconPicker(core: widget.core, app: a));
    if (changed == true) {
      icons.remove(a['id']);
      await _load();
    }
  }

  Future<void> _uninstall(App a) async {
    final go = await showDialog<Map<String, dynamic>>(context: context, builder: (_) => RemoveDialog(core: widget.core, app: a));
    if (go != null) await startJob(a, 'remove', options: go);
  }

  List<PopupMenuEntry<String>> menuItems(App a) {
    final inst = installed(a);
    final here = supportedHere(a);
    final support = a['support'] as Map? ?? const {};
    final busy = widget.jobs.jobs.any((j) => j.app == a['id'] && !j.finished);
    final canInstall = here && support['install'] != false && !busy;
    final rel = latestRelease(a);
    final newer = newerRelease(a);
    final bar = a['bar'] as Map? ?? {};
    final barHere = desktop != 'other' && hasBar(a) && inst;
    final icon = icons[a['id']];
    final folder = mainFolder(a);
    PopupMenuItem<String> item(String value, String text, {bool enabled = true, IconData? icon}) =>
        PopupMenuItem(value: value, enabled: enabled, child: Text(text));
    return [
      item('open', tr('Open'), enabled: inst && a['open'] == true),
      item('details', tr('Details…')),
      PopupMenuDivider(),
      if (!inst) ...[
        item('install', tr('Install'), enabled: canInstall),
        if (releaseInstallable(a)) item('release', trf('Install release {0}', [rel!['tag']]), enabled: canInstall),
      ] else ...[
        if (canUpdate(a)) item('update', tr('Update'), enabled: canInstall),
        if (newer != null) item('release', trf('Update to release {0}', [newer['tag']]), enabled: canInstall),
        if (needsRepair(a) || a['state'] == 'partial')
          item('reinstall', tr('Repair'), enabled: canInstall)
        else
          item('reinstall', tr('Reinstall'), enabled: canInstall),
      ],
      if (barHere) ...[
        PopupMenuDivider(),
        if (bar['state'] == 'in') ...[
          item('out', tr('Take out of the bar')),
          item('left1', tr('Move left')),
          item('right1', tr('Move right')),
          for (final area in ['left', 'center', 'right'])
            if (bar['zone'] != area) item('in:$area', trf('Move to the {0} area', [zoneName(area)])),
        ] else
          for (final area in ['left', 'center', 'right']) item('in:$area', trf('Put into the bar: {0}', [zoneName(area)])),
        item('icon', tr('Change icon…')),
        item('reseticon', tr('Reset icon'), enabled: icon == null || icon['current'] != 'original'),
      ],
      const PopupMenuDivider(),
      item('github', tr('Open on GitHub'), enabled: githubUrl(a) != null),
      item('copyurl', tr('Copy GitHub URL'), enabled: githubUrl(a) != null),
      item('copyfolder', tr('Copy folder path'), enabled: folder?['path'] != null),
      if (inst) ...[
        const PopupMenuDivider(),
        item('remove', tr('Uninstall…'), enabled: !busy),
      ],
    ];
  }

  Future<void> menu(App a, Offset at) async {
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
      items: menuItems(a),
    );
    if (choice != null) await act(a, choice);
  }

  Future<void> act(App a, String choice) async {
    switch (choice) {
      case 'open':
        await _do('apps.open', {'id': a['id']});
      case 'details':
        await openDetails(a);
      case 'install' || 'update' || 'reinstall':
        await startJob(a, choice);
      case 'release':
        final tag = (newerRelease(a) ?? latestRelease(a))?['tag'];
        await startJob(a, 'release', options: {'tag': ?tag});
      case 'out':
        await _do('bar.remove', {'app': a['id']}, done: trf('{0} is out of the bar', [a['name']]));
      case 'left1':
        await _nudge(a, -1);
      case 'right1':
        await _nudge(a, 1);
      case final String c when c.startsWith('in:'):
        await _do('bar.place', {'app': a['id'], 'area': c.substring(3)}, done: trf('{0}: bar, {1}', [a['name'], zoneName(c.substring(3))]));
      case 'icon':
        await _changeIcon(a);
      case 'reseticon':
        await _do('icons.reset', {'app': a['id']}, done: trf('{0}: the original icon is back', [a['name']]));
        icons.remove(a['id']);
        unawaited(_loadIcons());
      case 'github':
        await _openGithub(a);
      case 'copyurl':
        await Clipboard.setData(ClipboardData(text: githubUrl(a)!));
        tell(tr('Copied'));
      case 'copyfolder':
        await Clipboard.setData(ClipboardData(text: '${mainFolder(a)!['path']}'));
        tell(tr('Copied'));
      case 'remove':
        await _uninstall(a);
    }
  }

  /// A new app's ⋮ menu: clone (GitHub only), its GitHub page, its folder.
  Future<void> _newMenu(Map<String, dynamic> n, Offset at) async {
    final gh = n['github'] as Map?;
    final folder = n['folder'] as String?;
    PopupMenuItem<String> item(String value, String text, {bool enabled = true}) =>
        PopupMenuItem(value: value, enabled: enabled, child: Text(text));
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
      items: [
        if (folder == null && gh != null)
          n['cloneTo'] != null ? item('clone', trf('Clone into {0}', [n['cloneTo']])) : item('clone', trf('Not cloneable: {0}', [n['cloneBlocked']]), enabled: false),
        if (folder != null) item('folder', tr('Open folder')),
        item('github', tr('Open on GitHub'), enabled: gh != null),
        PopupMenuDivider(),
        item('copyurl', tr('Copy GitHub URL'), enabled: gh != null),
        item('copyfolder', tr('Copy folder path'), enabled: folder != null),
      ],
    );
    switch (choice) {
      case 'clone':
        await _clone(n);
      case 'folder':
        await _do('discovered.open_folder', {'name': n['name']});
      case 'github':
        await _do('links.open', {'url': gh!['url']});
      case 'copyurl':
        await Clipboard.setData(ClipboardData(text: '${gh!['url']}'));
        tell(tr('Copied'));
      case 'copyfolder':
        await Clipboard.setData(ClipboardData(text: folder!));
        tell(tr('Copied'));
    }
  }

  bool cloning = false;

  Future<void> _clone(Map<String, dynamic> n) async {
    if (cloning) return;
    setState(() => cloning = true);
    final gh = n['github'] as Map;
    tell(trf('Cloning {0}…', [gh['repo']]));
    try {
      final r = await widget.core('discovered.clone', {'repo': gh['repo']});
      tell(trf('{0} is in {1}', [n['name'], r['folder']]));
    } on ServiceError catch (e) {
      tell(trf('{0} could not be cloned ({1}){2}', [n['name'], e.code, e.reason == null || e.reason!.isEmpty ? '' : ': ${e.reason}']));
    } finally {
      if (mounted) setState(() => cloning = false);
    }
    await _load();
  }

  Widget _newRow(Map<String, dynamic> n) {
    final scheme = Theme.of(context).colorScheme;
    final gh = n['github'] as Map?;
    final folder = n['folder'] as String?;
    final about = [
      if (gh?['description'] is String && (gh!['description'] as String).isNotEmpty) gh['description'],
      folder ?? trf('on GitHub only: {0}', [gh?['url']]),
    ].join(' · ');
    return GestureDetector(
      onSecondaryTapDown: (d) => _newMenu(n, d.globalPosition),
      child: ListTile(
        key: ValueKey('new-${n['name']}'),
        leading: Icon(Icons.fiber_new_outlined, color: scheme.onSurfaceVariant),
        title: Row(
          children: [
            Flexible(child: Text('${n['name']}', overflow: TextOverflow.ellipsis)),
            if (gh?['public'] == false) _sourceChip(tr('private')),
          ],
        ),
        subtitle: Row(
          children: [
            Flexible(child: Text(about, maxLines: 1, overflow: TextOverflow.ellipsis)),
            if (folder != null) _sourceChip(tr('Folder')),
            if (gh != null) _sourceChip(tr('GitHub')),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (folder == null && gh != null && n['cloneTo'] != null)
              TextButton(onPressed: cloning ? null : () => _clone(n), child: Text(tr('Clone'))),
            Builder(
              builder: (context) => IconButton(
                tooltip: tr('Actions'),
                icon: Icon(Icons.more_vert, size: 18),
                onPressed: () {
                  final box = context.findRenderObject()! as RenderBox;
                  _newMenu(n, box.localToGlobal(box.size.bottomLeft(Offset.zero)));
                },
              ),
            ),
          ],
        ),
        onTap: () => folder != null ? _do('discovered.open_folder', {'name': n['name']}) : (gh != null ? _do('links.open', {'url': gh['url']}) : null),
      ),
    );
  }

  Widget _mark(String tooltip, IconData icon, Color color) => Padding(
    padding: const EdgeInsets.only(left: 6),
    child: Tooltip(message: tooltip, child: Icon(icon, size: 16, color: color)),
  );

  Widget _sourceChip(String text) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(left: 6),
      padding: EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(cornerSizes(context).control),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Text(text, style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
    );
  }

  Widget _row(App a) {
    final scheme = Theme.of(context).colorScheme;
    final marks = markColors(context);
    final inst = installed(a);
    final version = '${(a['versions'] as Map?)?['installed'] ?? ''}';
    final reasons = updateReasons(a);
    final job = widget.jobs.jobs.where((j) => j.app == a['id'] && !j.finished).firstOrNull;
    final icon = a['icon'] as Map? ?? {};
    final missing = missingParts(a);
    return GestureDetector(
      onSecondaryTapDown: (d) => menu(a, d.globalPosition),
      child: Builder(
        builder: (rowContext) => Focus(
          canRequestFocus: false,
          skipTraversal: true,
          onKeyEvent: (_, event) {
            // The menu key (or Shift+F10) opens the ⋮ menu of the focused row.
            final k = event.logicalKey;
            if (event is KeyDownEvent &&
                (k == LogicalKeyboardKey.contextMenu || (k == LogicalKeyboardKey.f10 && HardwareKeyboard.instance.isShiftPressed))) {
              final box = rowContext.findRenderObject()! as RenderBox;
              menu(a, box.localToGlobal(box.size.centerRight(Offset.zero) - const Offset(40, 0)));
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: ListTile(
            key: ValueKey('app-${a['id']}'),
            leading: AppIcon(icon['file'] as String?, symbolic: icon['symbolic'] == true, dim: !inst),
            title: Row(
              children: [
                Flexible(child: Text('${a['name']}', overflow: TextOverflow.ellipsis)),
                if (version.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  Text(version, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                ],
                if (reasons.isNotEmpty) _mark(reasons.join('\n'), Icons.arrow_circle_up, marks.update),
                if (a['state'] == 'partial')
                  _mark(
                    trf('Partly installed{0}{1}', [missing.isEmpty ? '' : trf(': no {0}', [missing.join(', ')]), prerequisitesMissing(a).isEmpty ? '' : trf(' (missing: {0})', [prerequisitesMissing(a).join(', ')])]),
                    Icons.incomplete_circle,
                    marks.fresh,
                  ),
                if (inst && buildUnknown(a))
                  _mark(tr('Installed before the Manager: the build is unknown (Reinstall records it)'), Icons.help_outline, scheme.onSurfaceVariant),
                if (needsRepair(a))
                  _mark(
                    trf('The last job was interrupted or failed while it changed files: {0}', [(a['job'] as Map?)?['result']?['message'] ?? tr('Repair reinstalls it')]),
                    Icons.warning_amber_rounded,
                    scheme.error,
                  ),
                if (job != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Tooltip(
                      message: '${job.title}: ${phaseName(job.phase)}',
                      child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                    ),
                  ),
              ],
            ),
            subtitle: Row(
              children: [
                Flexible(child: Text(subtitle(a, desktop), maxLines: 1, overflow: TextOverflow.ellipsis)),
                for (final c in sourceChips(a)) _sourceChip(c),
              ],
            ),
            trailing: Builder(
              builder: (context) => IconButton(
                tooltip: tr('App actions'),
                icon: Icon(Icons.more_vert, size: 18),
                onPressed: () {
                  final box = context.findRenderObject()! as RenderBox;
                  menu(a, box.localToGlobal(box.size.bottomLeft(Offset.zero)));
                },
              ),
            ),
            // As the Plugins page: a click opens it (its window); the details otherwise.
            onTap: () => inst && a['open'] == true ? act(a, 'open') : openDetails(a),
          ),
        ),
      ),
    );
  }

  KeyEventResult _keys(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final k = event.logicalKey;
    if (k == LogicalKeyboardKey.escape) {
      // A menu above the page that didn't get the focus: Esc closes it.
      if (ModalRoute.of(context)?.isCurrent == false) {
        Navigator.of(context).maybePop();
        return KeyEventResult.handled;
      }
      // Esc: the filter first, then the log sheet.
      if (filter.text.isNotEmpty) {
        filter.clear();
        setState(() => query = '');
        filterFocus.requestFocus();
        return KeyEventResult.handled;
      }
      if (sheet) {
        setState(() => sheet = false);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (k == LogicalKeyboardKey.f5 || (k == LogicalKeyboardKey.keyR && HardwareKeyboard.instance.isControlPressed)) {
      unawaited(checkUpdates(force: true));
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.keyB && HardwareKeyboard.instance.isControlPressed) {
      unawaited(openBarEditor());
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.keyL && HardwareKeyboard.instance.isControlPressed) {
      setState(() => sheet = !sheet);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final shown = [for (final a in apps) if (matches(a, query)) a];
    final q = query.trim().toLowerCase();
    final shownNew = [for (final n in discovered) if (q.isEmpty || '${n['name']}'.toLowerCase().contains(q)) n];
    final secs = sections(shown, desktop);
    final running = widget.jobs.busy;
    final narrow = MediaQuery.sizeOf(context).width < 560;
    return Scaffold(
      body: Focus(
        autofocus: true,
        onKeyEvent: _keys,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
              child: Row(
                children: [
                  // In a narrow window the title gives way to the toolbar's buttons.
                  Expanded(
                    child: Text(
                      tr('MAPRISMA APPS'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(letterSpacing: 1.2, fontWeight: FontWeight.w700, color: scheme.onSurfaceVariant),
                    ),
                  ),
                  PopupMenuButton<String>(
                    tooltip: tr('Language'),
                    icon: Icon(Icons.language),
                    itemBuilder: (_) => [
                      CheckedPopupMenuItem(value: 'auto', checked: widget.languageSetting == 'auto', child: Text(trf('System ({0})', [languageNames[systemLanguage(Platform.environment)]]))),
                      for (final entry in languageNames.entries)
                        CheckedPopupMenuItem(value: entry.key, checked: entry.key == widget.languageSetting, child: Text(entry.value)),
                    ],
                    onSelected: (value) async {
                      try {
                        await widget.core('settings.language', {'language': value});
                        await widget.onLanguageChanged?.call();
                        await _load();
                      } on Object {
                        if (mounted) tell(tr('Could not save the language setting.'));
                      }
                    },
                  ),
                  PopupMenuButton<String>(
                    key: const ValueKey('settings-menu'),
                    tooltip: tr('Settings'),
                    icon: Icon(Icons.tune),
                    itemBuilder: (_) => [
                      PopupMenuItem<String>(
                        enabled: false,
                        height: 32,
                        child: Text(tr('Corners'), style: TextStyle(fontWeight: FontWeight.w700, color: scheme.onSurfaceVariant)),
                      ),
                      for (final (value, label) in [
                        ('windows', tr('Like windows')),
                        ('slight', trf('Slightly rounded ({0} px)', [slightRadius])),
                        ('rounded', trf('Rounded ({0} px)', [roundedRadius])),
                        ('square', tr('Square')),
                      ])
                        CheckedPopupMenuItem(value: 'corners:$value', checked: widget.cornersSetting == value, child: Text(label)),
                      const PopupMenuDivider(),
                      CheckedPopupMenuItem(
                        value: 'screenshot_key',
                        checked: widget.screenshotKey,
                        child: Tooltip(
                          message: tr('A picture of this window goes to ~/Pictures/Maprisma Manager; then you can add a note about what is wrong, saved next to it.'),
                          child: Text(tr('F12 saves a screenshot')),
                        ),
                      ),
                    ],
                    onSelected: (choice) async {
                      final (key, value) = choice == 'screenshot_key'
                          ? ('screenshot_key', !widget.screenshotKey)
                          : ('corners', choice.substring('corners:'.length));
                      try {
                        await widget.core('settings.set', {'key': key, 'value': value});
                        await widget.onSettingsChanged?.call();
                      } on Object {
                        if (mounted) tell(tr('Could not save the setting.'));
                      }
                    },
                  ),
                  IconButton(
                    tooltip: tr('Check for updates (F5)'),
                    onPressed: checking ? null : () => checkUpdates(force: true),
                    icon: checking
                        ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.refresh),
                  ),
                  if (desktop != 'other')
                    IconButton(
                      tooltip: tr('Bar editor (Ctrl+B)'),
                      onPressed: openBarEditor,
                      icon: Icon(Icons.view_week_outlined),
                    ),
                  IconButton(
                    tooltip: tr('Job log (Ctrl+L)'),
                    isSelected: sheet,
                    onPressed: widget.jobs.jobs.isEmpty ? null : () => setState(() => sheet = !sheet),
                    icon: Badge(
                      isLabelVisible: running,
                      smallSize: 7,
                      backgroundColor: markColors(context).update,
                      child: const Icon(Icons.terminal),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              child: TextField(
                key: ValueKey('filter'),
                controller: filter,
                focusNode: filterFocus,
                autofocus: true,
                decoration: InputDecoration(hintText: tr('Type to filter'), prefixIcon: Icon(Icons.search, size: 20)),
                onChanged: (v) => setState(() => query = v),
                onSubmitted: (_) {
                  final first = secs.expand((s) => s.$2).firstOrNull;
                  if (first != null) unawaited(openDetails(first));
                },
              ),
            ),
            Expanded(
              child: loading
                  ? const Center(child: CircularProgressIndicator())
                  : error != null
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(error!, style: TextStyle(color: scheme.error)),
                          const SizedBox(height: 8),
                          TextButton(onPressed: _load, child: Text(tr('Try again'))),
                        ],
                      ),
                    )
                  : ListView(
                      key: const ValueKey('app-list'),
                      padding: EdgeInsets.symmetric(horizontal: 8),
                      children: [
                        for (final (title, items) in secs)
                          if (items.isNotEmpty) ...[
                            Padding(
                              padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                              child: Text(title, style: TextStyle(fontWeight: FontWeight.w700)),
                            ),
                            for (final x in items) _row(x),
                          ],
                        if (shownNew.isNotEmpty) ...[
                          Padding(
                            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                            child: Text(tr('New, not in the catalog'), style: TextStyle(fontWeight: FontWeight.w700)),
                          ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(12, 2, 12, 4),
                            child: Text(
                              tr('Found in the projects folder or the maprisma GitHub org. The Manager can install them once they have a catalog entry.'),
                              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                            ),
                          ),
                          for (final n in shownNew) _newRow(n),
                        ],
                        if (shown.isEmpty && shownNew.isEmpty)
                          Padding(
                            padding: const EdgeInsets.all(24),
                            child: Center(child: Text(trf('No app matches "{0}"', [query]), style: TextStyle(color: scheme.onSurfaceVariant))),
                          ),
                      ],
                    ),
            ),
            if (sheet && widget.jobs.shown != null)
              JobSheet(
                jobs: widget.jobs,
                height: narrow ? 220 : 260,
                onClose: () => setState(() => sheet = false),
              ),
          ],
        ),
      ),
    );
  }
}
