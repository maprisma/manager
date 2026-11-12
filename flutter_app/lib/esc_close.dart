import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// What an Esc that no widget took does (Maprisma layout rule 5a: the innermost thing first).
enum EscStep {
  /// A dialog, menu, drop-down or sheet is open: it has its own Esc (or refuses it on purpose).
  none,

  /// The keyboard is in a text field: leave it; the next Esc goes on.
  leaveField,

  /// A side page is open: Back.
  back,

  /// The main page with nothing open: close (or hide) the window.
  close,
}

/// [overPage]: a popup route (dialog, menu, drop-down, bottom sheet) is above the pages.
/// [inField]: the keyboard is in a text field. [sidePage]: a page above the main one.
EscStep escStep({required bool overPage, required bool inField, required bool sidePage}) {
  // A dialog closes by Esc, also from its text field (the field passes "dismiss" on to it).
  if (overPage) return EscStep.none;
  // On a page a text field takes Esc and does nothing with it: leave it; the next Esc goes on.
  if (inField) return EscStep.leaveField;
  if (sidePage) return EscStep.back;
  return EscStep.close;
}

/// The last word on Esc. Pages keep their own Esc (clear the filter, cancel an edit, …); what
/// is left comes here: leave a text field, then Back on a side page, then [onClose] on the main
/// page. It listens twice: [wrap] around the navigator (MaterialApp.builder), which sees Esc
/// before the app's Esc = DismissIntent (a text field takes that one and does nothing with it;
/// dialogs, menus and sheets close by it, so it is left to them), and a late key handler for
/// when the keyboard is nowhere below that. A navigator observer tells which routes are open.
final class EscFallback extends NavigatorObserver {
  EscFallback({required this.onClose, this.sidePage, this.onBack});

  /// Close or hide the window, as the app's own close does.
  final VoidCallback onClose;

  /// The app's own side page (not a route) is open; [onBack] leaves it.
  final bool Function()? sidePage;
  final VoidCallback? onBack;

  final _routes = <Route<dynamic>>[];

  bool get _overPage => _routes.isNotEmpty && _routes.last is! PageRoute;
  bool get _routePage => _routes.length > 1;

  void attach() => FocusManager.instance.addLateKeyEventHandler(handle);
  void detach() => FocusManager.instance.removeLateKeyEventHandler(handle);

  /// Around the navigator: MaterialApp(builder: (context, child) => esc.wrap(child!)).
  Widget wrap(Widget child) =>
      Focus(canRequestFocus: false, skipTraversal: true, onKeyEvent: (_, event) => handle(event), child: child);

  static bool _inField(FocusNode? focus) {
    final context = focus?.context;
    if (context == null) return false;
    if (context.widget is EditableText) return true;
    return context.findAncestorStateOfType<EditableTextState>() != null;
  }

  KeyEventResult handle(KeyEvent event) {
    if (event is! KeyDownEvent || event.logicalKey != LogicalKeyboardKey.escape) return KeyEventResult.ignored;
    final keys = HardwareKeyboard.instance;
    if (keys.isControlPressed || keys.isAltPressed || keys.isMetaPressed || keys.isShiftPressed) {
      return KeyEventResult.ignored;
    }
    final focus = FocusManager.instance.primaryFocus;
    final step = escStep(
      overPage: _overPage,
      inField: _inField(focus),
      sidePage: _routePage || (sidePage?.call() ?? false),
    );
    switch (step) {
      case EscStep.none:
        return KeyEventResult.ignored;
      case EscStep.leaveField:
        focus?.unfocus();
      case EscStep.back:
        if (_routePage) {
          navigator?.maybePop();
        } else {
          onBack?.call();
        }
      case EscStep.close:
        onClose();
    }
    return KeyEventResult.handled;
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) => _routes.add(route);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) => _routes.remove(route);

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) => _routes.remove(route);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final i = oldRoute == null ? -1 : _routes.indexOf(oldRoute);
    if (newRoute == null) return;
    if (i < 0) {
      _routes.add(newRoute);
    } else {
      _routes[i] = newRoute;
    }
  }
}
