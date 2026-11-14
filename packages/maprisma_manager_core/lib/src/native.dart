import 'translations.dart';

import 'catalog_model.dart' show DesktopId;
import 'context.dart';

/// One way into the desktop's own settings app: a label and the command.
typedef NativeLink = ({String label, List<String> argv});

/// The desktop's own settings app for a page of the sidebar. COSMIC and KDE have one, so there
/// the Manager only opens it (`cosmic-settings <page>`, `systemsettings <kcm>`); on Hyprland the
/// Manager's own page sets things itself. KDE splits some pages into several modules.
final class NativeSettings {
  NativeSettings(this.ctx, this.startDetached);

  final Ctx ctx;
  final Future<bool> Function(String exe, [List<String> args]) startDetached;

  /// The pages that have a native counterpart.
  static const pages = ['network', 'bluetooth', 'sound', 'notifications', 'displays', 'power', 'input', 'applications', 'time', 'about'];

  String? get appName => switch (ctx.desktop) {
    DesktopId.cosmic => tr('COSMIC Settings'),
    DesktopId.kde => tr('System Settings'),
    _ => null,
  };

  List<NativeLink> links(String page) {
    List<NativeLink> cosmic(List<(String, String)> subs) => [for (final (label, sub) in subs) (label: label, argv: ['cosmic-settings', sub])];
    List<NativeLink> kde(List<(String, String)> kcms) => [for (final (label, kcm) in kcms) (label: label, argv: ['systemsettings', kcm])];
    switch (ctx.desktop) {
      case DesktopId.cosmic:
        return switch (page) {
          'network' => cosmic([(tr('Network & Wireless'), 'network')]),
          'bluetooth' => cosmic([(tr('Bluetooth'), 'bluetooth')]),
          'sound' => cosmic([(tr('Sound'), 'sound')]),
          // cosmic-settings 1.11 has no notifications page (`cosmic-settings notifications` is an
          // unknown command): do not disturb is in the panel's applet, nothing else is settable.
          'notifications' => const [],
          'displays' => cosmic([(tr('Displays'), 'displays')]),
          'power' => cosmic([(tr('Power & battery'), 'power')]),
          'input' => cosmic([(tr('Keyboard'), 'keyboard'), (tr('Mouse'), 'mouse'), (tr('Touchpad'), 'touchpad')]),
          'applications' => cosmic([(tr('Default applications'), 'default-apps'), (tr('Startup applications'), 'startup-apps')]),
          'time' => cosmic([(tr('Date & time'), 'date-time'), (tr('Region & language'), 'region-language')]),
          'about' => cosmic([(tr('About'), 'about')]),
          _ => const [],
        };
      case DesktopId.kde:
        return switch (page) {
          'network' => kde([(tr('Network & Wireless'), 'kcm_networkmanagement')]),
          'bluetooth' => kde([(tr('Bluetooth'), 'kcm_bluetooth')]),
          'sound' => kde([(tr('Sound'), 'kcm_pulseaudio')]),
          'notifications' => kde([(tr('Notifications'), 'kcm_notifications')]),
          'displays' => kde([(tr('Displays'), 'kcm_kscreen'), (tr('Night light'), 'kcm_nightlight')]),
          'power' => kde([(tr('Power & battery'), 'kcm_powerdevilprofilesconfig')]),
          'input' => kde([(tr('Keyboard'), 'kcm_keyboard'), (tr('Mouse'), 'kcm_mouse'), (tr('Touchpad'), 'kcm_touchpad')]),
          'applications' => kde([(tr('Default applications'), 'kcm_componentchooser'), (tr('Startup applications'), 'kcm_autostart')]),
          'time' => kde([(tr('Date & time'), 'kcm_clock'), (tr('Region & language'), 'kcm_regionandlang')]),
          'about' => kde([(tr('About'), 'kcm_about-distro')]),
          _ => const [],
        };
      default:
        return const [];
    }
  }

  /// `native.get`: the app's name and the page's links (empty: the Manager sets it itself).
  Map<String, dynamic> get(Map<String, dynamic> params) {
    final page = _page(params);
    final list = links(page);
    return {
      'desktop': ctx.desktop.name,
      'page': page,
      'name': list.isEmpty ? null : appName,
      'links': [for (final l in list) {'label': l.label, 'available': ctx.runner.which(l.argv.first) != null}],
    };
  }

  /// `native.open`: link [index] of the page.
  Future<Map<String, dynamic>> open(Map<String, dynamic> params) async {
    final page = _page(params);
    final list = links(page);
    final index = params['index'] ?? 0;
    if (index is! int || index < 0 || index >= list.length) {
      throw RouteError(list.isEmpty ? 'unavailable' : 'bad_params', list.isEmpty ? tr('This desktop has no settings app of its own for it') : 'index');
    }
    final link = list[index];
    final exe = ctx.runner.which(link.argv.first);
    if (exe == null) throw RouteError('unavailable', trf('{0} is missing', [link.argv.first]));
    if (!await startDetached(exe, link.argv.sublist(1))) throw RouteError('internal', trf('could not start {0}', [link.argv.first]));
    return {'opened': link.label};
  }

  static String _page(Map<String, dynamic> params) {
    final page = params['page'];
    if (page is! String || !pages.contains(page)) throw RouteError('bad_params', 'page');
    return page;
  }
}
