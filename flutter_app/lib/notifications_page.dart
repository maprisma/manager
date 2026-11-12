import 'package:flutter/material.dart';
import 'package:maprisma_manager_core/maprisma_manager_core.dart' show tr, trf;

import 'backend.dart' show ServiceError;
import 'core_call.dart';
import 'desktop_page.dart';
import 'power_page.dart' show idleLabel;
import 'settings_widgets.dart';

/// Notifications: Maprisma Notifier's settings (do not disturb with its schedule, how long the
/// history is kept, the unread count, crash reports and their AI helper, muted and hidden apps,
/// Clear history) on every desktop;
/// on Hyprland also Maprisma Shell's popups (position, how long, how many); on COSMIC and KDE a
/// link to the desktop's own notification settings (`notifications.*`, `native.open`).
class NotificationsPage extends StatefulWidget {
  const NotificationsPage({super.key, required this.core, this.onInstall});
  final CoreCall core;

  /// Installs Maprisma Notifier (the Apps page's job); null: not possible here or not known yet.
  final VoidCallback? onInstall;
  @override
  State<NotificationsPage> createState() => NotificationsPageState();
}

/// Choices of the drop-downs (a stored value that isn't listed is shown too).
const historyMaxChoices = [50, 100, 200, 500, 1000, 2000, 5000];
const historyDaysChoices = [1, 3, 7, 14, 30, 60, 90];
const popupTimeoutChoices = [1, 2, 3, 5, 8, 10, 15, 20, 30, 45, 60];
const popupPositions = ['top-right', 'top', 'top-left', 'bottom-right', 'bottom-left'];

/// The times of the schedule: every half hour.
final scheduleTimes = [
  for (var m = 0; m < 24 * 60; m += 30) '${(m ~/ 60).toString().padLeft(2, '0')}:${(m % 60).toString().padLeft(2, '0')}',
];

String positionLabel(String id) => switch (id) {
  'top-right' => tr('Top right'),
  'top' => tr('Top centre'),
  'top-left' => tr('Top left'),
  'bottom-right' => tr('Bottom right'),
  'bottom-left' => tr('Bottom left'),
  _ => id,
};

String daysLabel(int n) => n == 1 ? tr('1 day') : trf('{0} days', [n]);

/// An app's place: shown (counted), muted (kept, not counted) or hidden (not kept).
enum AppMode { shown, muted, hidden }

class NotificationsPageState extends State<NotificationsPage> with RoutePage {
  @override
  CoreCall get core => widget.core;
  @override
  String get getRoute => 'notifications.get';

  List<T> _with<T>(List<T> base, T value) => base.contains(value) ? base : ([...base, value]..sort((a, b) => (a as Comparable).compareTo(b)));

  Future<void> _set(Map<String, dynamic> params) async {
    if (working) return;
    setState(() => working = true);
    try {
      try {
        final r = await core('notifications.set', params);
        final applied = r['applied'];
        if (applied is Map && applied['error'] != null) tellOn(this, trf('Do not disturb is saved, but not passed on: {0}', [applied['error']]));
      } on ServiceError catch (e) {
        tellOn(this, failure(e));
      }
      if (mounted) await load();
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  Future<void> _clear(Map history) async {
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('Clear the history?')),
        content: Text(tr('Every notification Maprisma Notifier has kept is deleted. This cannot be undone.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Cancel'))),
          FilledButton(
            key: const ValueKey('notifications-clear-confirm'),
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error, foregroundColor: Theme.of(context).colorScheme.onError),
            onPressed: () => Navigator.pop(context, true),
            child: Text(tr('Clear history')),
          ),
        ],
      ),
    );
    if (go == true && mounted) await act('notifications.clear_history', const {});
  }

  Future<void> _openNative() async {
    try {
      await core('native.open', {'page': 'notifications'});
    } on ServiceError catch (e) {
      tellOn(this, failure(e));
    }
  }

  Widget _install() => SettingsSection(
    children: [
      SettingsItem(
        leading: const Icon(Icons.notifications_off_outlined),
        title: tr('Maprisma Notifier is not installed'),
        description: tr('It keeps a history of your notifications, shows the unread count in the bar and sets do not disturb. Install it to use these settings.'),
        trailing: FilledButton(key: const ValueKey('notifications-install'), onPressed: widget.onInstall, child: Text(tr('Install'))),
      ),
    ],
  );

  Widget _dnd(Map d, Map s) {
    final schedule = s['dnd_schedule'] as Map;
    final off = working || s['error'] != null;
    final desktop = d['desktop_dnd'] as Map?;
    final String? note;
    if (s['error'] != null) {
      note = '${s['error']}';
    } else if (desktop?['where'] == 'recorder' && d['running'] != true) {
      note = tr('Maprisma Notifier is not running: on this desktop do not disturb applies once it runs.');
    } else {
      note = null;
    }
    final scheduled = s['dnd_now'] == true && s['dnd'] != true;
    return SettingsSection(
      title: tr('Do not disturb'),
      note: note,
      children: [
        SettingsToggle(
          key: const ValueKey('notifications-dnd'),
          title: tr('Do not disturb'),
          description: scheduled ? tr('On now through the schedule. Notifications still go to the history.') : tr('No popups; notifications still go to the history.'),
          value: s['dnd'] == true,
          onChanged: off ? null : (v) => _set({'dnd': v}),
        ),
        SettingsToggle(
          key: const ValueKey('notifications-schedule'),
          title: tr('On a schedule'),
          description: tr('Do not disturb turns on by itself every day in this time.'),
          value: schedule['on'] == true,
          onChanged: off ? null : (v) => _set({'dnd_schedule': {'on': v}}),
        ),
        if (schedule['on'] == true)
          for (final (key, title) in [('from', tr('From')), ('to', tr('Until'))])
            SettingsChoice<String>(
              key: ValueKey('notifications-schedule-$key'),
              title: title,
              value: '${schedule[key]}',
              choices: [for (final t in _with(scheduleTimes, '${schedule[key]}')) (t, t)],
              onChanged: off ? null : (v) => _set({'dnd_schedule': {key: v}}),
            ),
      ],
    );
  }

  Widget _history(Map s, Map history) {
    final off = working || s['error'] != null;
    final count = history['count'] as int? ?? 0;
    return SettingsSection(
      title: tr('History'),
      note: history['error'] != null ? '${history['error']}' : null,
      children: [
        SettingsChoice<int>(
          key: const ValueKey('notifications-history-max'),
          title: tr('Keep at most'),
          value: s['history_max'] as int,
          choices: [for (final n in _with(historyMaxChoices, s['history_max'] as int)) (n, trf('{0} notifications', [n]))],
          onChanged: off ? null : (v) => _set({'history_max': v}),
        ),
        SettingsChoice<int>(
          key: const ValueKey('notifications-history-days'),
          title: tr('Keep for'),
          value: s['history_days'] as int,
          choices: [for (final n in _with(historyDaysChoices, s['history_days'] as int)) (n, daysLabel(n))],
          onChanged: off ? null : (v) => _set({'history_days': v}),
        ),
        SettingsToggle(
          key: const ValueKey('notifications-show-count'),
          title: tr('Show the unread count'),
          description: tr('The number on the bar icon.'),
          value: s['show_count'] == true,
          onChanged: off ? null : (v) => _set({'show_count': v}),
        ),
        SettingsItem(
          title: tr('Clear history'),
          description: count == 1 ? tr('1 notification kept') : trf('{0} notifications kept', [count]),
          trailing: OutlinedButton(
            key: const ValueKey('notifications-clear'),
            style: OutlinedButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
            onPressed: working || count == 0 ? null : () => _clear(history),
            child: Text(tr('Clear history')),
          ),
        ),
      ],
    );
  }

  /// Crash reports: the switch, and which AI helper "Check with AI" opens (when one is installed).
  Widget _crashes(Map s, List helpers) {
    final off = working || s['error'] != null;
    final ids = [for (final h in helpers) '${(h as Map)['id']}'];
    // a chosen helper that isn't installed works as Automatic
    final chosen = ids.contains(s['ai_helper']) ? s['ai_helper'] as String : 'auto';
    return SettingsSection(
      title: tr('Crashes'),
      children: [
        SettingsToggle(
          key: const ValueKey('notifications-crashes'),
          title: tr('Report app crashes'),
          description: tr('A notification when one of your programs crashes, with its details.'),
          value: s['notify_crashes'] != false,
          onChanged: off ? null : (v) => _set({'notify_crashes': v}),
        ),
        if (helpers.isNotEmpty)
          SettingsChoice<String>(
            key: const ValueKey('notifications-ai-helper'),
            title: tr('AI helper'),
            description: tr('Check with AI on a crash opens it in a terminal.'),
            value: chosen,
            choices: [
              ('auto', trf('Automatic ({0})', [(helpers.first as Map)['name']])),
              for (final h in helpers) ('${(h as Map)['id']}', '${h['name']}'),
            ],
            onChanged: off || s['notify_crashes'] == false ? null : (v) => _set({'ai_helper': v}),
          ),
      ],
    );
  }

  Widget _apps(Map s, Map history) {
    final muted = (s['muted_apps'] as List).cast<String>();
    final hidden = (s['hidden_apps'] as List).cast<String>();
    final names = {...(history['apps'] as List).cast<String>(), ...muted, ...hidden}.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    final off = working || s['error'] != null;
    AppMode mode(String n) => hidden.contains(n) ? AppMode.hidden : (muted.contains(n) ? AppMode.muted : AppMode.shown);
    void change(String n, AppMode to) {
      final m = [...muted]..remove(n);
      final h = [...hidden]..remove(n);
      if (to == AppMode.muted) m.add(n);
      if (to == AppMode.hidden) h.add(n);
      // only the lists that change
      _set({
        if (m.length != muted.length || !m.every(muted.contains)) 'muted_apps': m,
        if (h.length != hidden.length || !h.every(hidden.contains)) 'hidden_apps': h,
      });
    }

    return SettingsSection(
      title: tr('Apps'),
      note: tr('Muted: kept in the history but never counted as unread. Hidden: not kept at all.'),
      children: [
        if (names.isEmpty)
          SettingsItem(title: tr('No apps yet'), description: tr('An app shows here after its first notification.'))
        else
          for (final n in names)
            SettingsChoice<AppMode>(
              key: ValueKey('notifications-app-$n'),
              title: n,
              value: mode(n),
              choices: [(AppMode.shown, tr('Shown')), (AppMode.muted, tr('Muted')), (AppMode.hidden, tr('Hidden'))],
              onChanged: off ? null : (v) => v == mode(n) ? null : change(n, v),
            ),
      ],
    );
  }

  Widget _popups(Map shell) {
    final off = working || shell['error'] != null;
    final timeout = shell['timeout'] as int, max = shell['max'] as int;
    final position = '${shell['position']}';
    return SettingsSection(
      title: tr('Popups'),
      note: shell['error'] != null ? '${shell['error']}' : trf('Maprisma Shell, saved in {0}', [_short('${shell['file']}')]),
      children: [
        SettingsChoice<String>(
          key: const ValueKey('notifications-position'),
          title: tr('Position'),
          value: position,
          choices: [for (final p in popupPositions) (p, positionLabel(p))],
          onChanged: off ? null : (v) => act('notifications.set_shell', {'position': v}),
        ),
        SettingsChoice<int>(
          key: const ValueKey('notifications-timeout'),
          title: tr('Shown for'),
          description: tr('Critical ones stay until they are closed.'),
          value: timeout,
          choices: [for (final t in _with(popupTimeoutChoices, timeout)) (t, idleLabel(t))],
          onChanged: off ? null : (v) => act('notifications.set_shell', {'timeout': v}),
        ),
        SettingsChoice<int>(
          key: const ValueKey('notifications-max'),
          title: tr('At most at once'),
          description: tr('The oldest leave first.'),
          value: max,
          choices: [for (var n = 1; n <= 10; n++) (n, '$n')],
          onChanged: off ? null : (v) => act('notifications.set_shell', {'max': v}),
        ),
      ],
    );
  }

  Widget _native(Map n) => SettingsSection(
    note: n['available'] == true ? null : trf('{0} was not found.', [n['name']]),
    children: [
      SettingsItem(
        title: trf('Popups are set in {0}', [n['name']]),
        description: tr('This desktop shows the notification popups itself; where they appear, their sounds and the per-app rules are in its own settings.'),
        trailing: FilledButton.tonal(
          key: const ValueKey('notifications-open-native'),
          onPressed: n['available'] == true ? _openNative : null,
          child: Text(trf('Open {0}', [n['name']])),
        ),
      ),
    ],
  );

  static String _short(String path) {
    final home = RegExp(r'^/home/[^/]+').firstMatch(path)?.group(0);
    return home == null ? path : '~${path.substring(home.length)}';
  }

  @override
  Widget build(BuildContext context) {
    final d = data;
    if (d == null) return SettingsPage(title: tr('Notifications'), actions: reloadActions(), children: loadingOrError(context));
    final s = d['settings'] as Map;
    final history = d['history'] as Map;
    return SettingsPage(
      title: tr('Notifications'),
      actions: reloadActions(),
      children: [
        if (d['installed'] != true) _install() else ...[_dnd(d, s), _history(s, history), _crashes(s, d['ai_helpers'] is List ? d['ai_helpers'] as List : const []), _apps(s, history)],
        if (d['shell'] is Map) _popups(d['shell'] as Map),
        if (d['native'] is Map) _native(d['native'] as Map),
      ],
    );
  }
}
