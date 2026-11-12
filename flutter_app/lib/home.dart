import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:maprisma_manager_core/maprisma_manager_core.dart' show tr;

import 'apps_page.dart';
import 'bar_editor.dart';
import 'core_call.dart';
import 'jobs_model.dart';
import 'power_page.dart';
import 'settings_page.dart';
import 'theme.dart';

/// The window's pages, in the sidebar's order.
enum Section { apps, bar, power, settings }

/// The window as COSMIC Settings lays it out: a sidebar of pages left (icon and name, the open
/// one highlighted), the page right. Below [condensedBelow] the sidebar hides behind a toggle
/// that shows it over the whole window until a page is chosen. Ctrl+1…4 open a page, Ctrl+B the
/// bar, Ctrl+, the settings, Ctrl+F the list's filter.
class ManagerHome extends StatefulWidget {
  const ManagerHome({
    super.key,
    required this.core,
    required this.jobs,
    this.onRestart,
    this.checkOnStart = true,
    this.onLanguageChanged,
    this.languageSetting = 'auto',
    this.cornersSetting = 'windows',
    this.screenshotKey = true,
    this.onSettingsChanged,
  });
  final CoreCall core;
  final JobsModel jobs;
  final VoidCallback? onRestart;
  final bool checkOnStart;
  final Future<void> Function()? onLanguageChanged, onSettingsChanged;
  final String languageSetting, cornersSetting;
  final bool screenshotKey;
  @override
  State<ManagerHome> createState() => ManagerHomeState();
}

/// COSMIC's condensed window: below 280 + 8 + 360 px the sidebar hides behind a toggle.
const condensedBelow = 648.0;

class ManagerHomeState extends State<ManagerHome> {
  Section section = Section.apps;

  /// Condensed: the sidebar is shown over the page.
  bool navOpen = false;
  final appsKey = GlobalKey<AppsPageState>();

  /// The desktop as apps.list told it ('other': no bar of ours, so no Bar page).
  String desktop = 'cosmic';

  List<Section> get sections => [for (final s in Section.values) if (s != Section.bar || desktop != 'other') s];

  static IconData icon(Section s, {bool on = false}) => switch (s) {
    Section.apps => on ? Icons.apps : Icons.apps_outlined,
    Section.bar => on ? Icons.view_week : Icons.view_week_outlined,
    Section.power => on ? Icons.power_settings_new : Icons.power_settings_new_outlined,
    Section.settings => on ? Icons.settings : Icons.settings_outlined,
  };

  static String name(Section s) => switch (s) {
    Section.apps => tr('Apps'),
    Section.bar => tr('Bar'),
    Section.power => tr('Power'),
    Section.settings => tr('Settings'),
  };

  void open(Section s) {
    if (navOpen) setState(() => navOpen = false);
    if (!sections.contains(s) || s == section) return;
    final left = section;
    setState(() => section = s);
    // Back on the list: the keyboard goes to its filter again.
    if (s == Section.apps) WidgetsBinding.instance.addPostFrameCallback((_) => appsKey.currentState?.filterFocus.requestFocus());
    // Back from the bar: the list shows the bar states as they are now.
    if (left == Section.bar) unawaited(appsKey.currentState?.reload());
  }

  bool _keys(KeyEvent event) {
    if (event is! KeyDownEvent || !HardwareKeyboard.instance.isControlPressed) return false;
    if (HardwareKeyboard.instance.isAltPressed || HardwareKeyboard.instance.isMetaPressed) return false;
    // Only while no dialog or menu is above the window.
    if (ModalRoute.of(context)?.isCurrent == false) return false;
    final k = event.logicalKey;
    final digits = [LogicalKeyboardKey.digit1, LogicalKeyboardKey.digit2, LogicalKeyboardKey.digit3, LogicalKeyboardKey.digit4];
    final i = digits.indexOf(k);
    if (i >= 0 && i < sections.length) {
      open(sections[i]);
      return true;
    }
    if (k == LogicalKeyboardKey.keyB && desktop != 'other') {
      open(section == Section.bar ? Section.apps : Section.bar);
      return true;
    }
    if (k == LogicalKeyboardKey.comma) {
      open(Section.settings);
      return true;
    }
    if (k == LogicalKeyboardKey.keyF) {
      open(Section.apps);
      appsKey.currentState?.filterFocus.requestFocus();
      return true;
    }
    return false;
  }

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_keys);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_keys);
    super.dispose();
  }

  Widget _page(Section s) => switch (s) {
    // The list stays alive (its filter, scroll and job sheet) while another page is open.
    Section.apps => const SizedBox.shrink(),
    Section.bar => BarEditorPage(key: const ValueKey('bar-page'), core: widget.core, apps: appsKey.currentState?.apps ?? const [], embedded: true, onLeave: () => open(Section.apps)),
    Section.power => PowerPage(key: const ValueKey('power-page'), core: widget.core),
    Section.settings => ManagerSettingsPage(
      key: const ValueKey('settings-page'),
      core: widget.core,
      languageSetting: widget.languageSetting,
      cornersSetting: widget.cornersSetting,
      screenshotKey: widget.screenshotKey,
      onLanguageChanged: () async {
        await widget.onLanguageChanged?.call();
        await appsKey.currentState?.reload();
      },
      onSettingsChanged: widget.onSettingsChanged,
      onAiChanged: () => appsKey.currentState?.reload(),
    ),
  };

  @override
  Widget build(BuildContext context) {
    final condensed = MediaQuery.sizeOf(context).width < condensedBelow;
    final apps = AppsPage(
      key: appsKey,
      core: widget.core,
      jobs: widget.jobs,
      onRestart: widget.onRestart,
      checkOnStart: widget.checkOnStart,
      onOpenBar: () => open(Section.bar),
      onDesktop: (d) {
        if (d != desktop && mounted) {
          setState(() {
            desktop = d;
            if (!sections.contains(section)) section = Section.apps;
          });
        }
      },
    );
    final pages = Stack(
      children: [
        // Hidden, the list keeps its state but not the keyboard (Esc, F5 there act on the list).
        Offstage(
          offstage: section != Section.apps,
          child: ExcludeFocus(excluding: section != Section.apps, child: TickerMode(enabled: section == Section.apps, child: apps)),
        ),
        if (section != Section.apps) Positioned.fill(child: _page(section)),
        if (condensed && navOpen)
          Positioned.fill(
            child: CallbackShortcuts(
              bindings: {const SingleActivator(LogicalKeyboardKey.escape): () => setState(() => navOpen = false)},
              child: Focus(
                autofocus: true,
                child: Container(
                  color: Theme.of(context).colorScheme.surface,
                  alignment: Alignment.topLeft,
                  child: Sidebar(sections: sections, selected: section, onSelected: open, full: true),
                ),
              ),
            ),
          ),
      ],
    );
    if (!condensed) {
      return Scaffold(
        body: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Sidebar(sections: sections, selected: section, onSelected: open),
            Expanded(child: pages),
          ],
        ),
      );
    }
    // Condensed: a header with the toggle, as COSMIC's header bar (the page shows its own title).
    return Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
            child: Row(
              children: [
                IconButton(
                  key: const ValueKey('nav-toggle'),
                  tooltip: navOpen ? tr('Hide the pages') : tr('Show the pages'),
                  isSelected: navOpen,
                  onPressed: () => setState(() => navOpen = !navOpen),
                  icon: const Icon(Icons.menu),
                ),
              ],
            ),
          ),
          Expanded(child: pages),
        ],
      ),
    );
  }
}

/// COSMIC Settings' navigation: a rounded panel of entries, icon and name, the open one on a
/// light pill in the accent's colour. [full]: the condensed window's, as wide as the window.
class Sidebar extends StatelessWidget {
  const Sidebar({super.key, required this.sections, required this.selected, required this.onSelected, this.full = false});
  final List<Section> sections;
  final Section selected;
  final ValueChanged<Section> onSelected;
  final bool full;

  /// COSMIC's nav_bar: at most 280 wide, 8 padding, 32 px rows 8 apart, 16 px icons.
  static const width = 240.0, itemHeight = 32.0, gap = 8.0;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final radius = cornerSizes(context);
    return Container(
      key: const ValueKey('sidebar'),
      width: full ? double.infinity : width,
      margin: EdgeInsets.fromLTRB(8, full ? 4 : 8, full ? 8 : 0, 8),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(color: scheme.surfaceContainer, borderRadius: BorderRadius.circular(radius.control)),
      child: FocusTraversalGroup(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final s in sections)
              Padding(
                padding: const EdgeInsets.only(bottom: Sidebar.gap),
                child: _Entry(section: s, on: s == selected, onTap: () => onSelected(s), radius: min(radius.radius, 16)),
              ),
          ],
        ),
      ),
    );
  }
}

class _Entry extends StatelessWidget {
  const _Entry({required this.section, required this.on, required this.onTap, required this.radius});
  final Section section;
  final bool on;
  final VoidCallback onTap;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // As COSMIC's NavBar style: the open one on a 20 % neutral, accent text, semibold; hover 30 %.
    final color = on ? scheme.primary : scheme.onSurface;
    final neutral = scheme.onSurface;
    final label = ManagerHomeState.name(section);
    final entry = Material(
      color: on ? neutral.withValues(alpha: .12) : Colors.transparent,
      borderRadius: BorderRadius.circular(radius),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: ValueKey('nav-${section.name}'),
        onTap: onTap,
        hoverColor: neutral.withValues(alpha: .08),
        child: SizedBox(
          height: Sidebar.itemHeight,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Icon(ManagerHomeState.icon(section, on: on), size: 16, color: color),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, color: color, fontWeight: on ? FontWeight.w600 : FontWeight.w400)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    return Semantics(selected: on, button: true, child: entry);
  }
}
