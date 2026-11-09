import 'package:flutter/material.dart';

Color? hexColor(Map colors, String key) {
  final value = colors[key];
  if (value is! String || !RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(value)) {
    return null;
  }
  return Color(0xff000000 | int.parse(value.substring(1), radix: 16));
}

/// The corner radius in effect (Settings › Corners; the desktop's windows).
class Corners extends ThemeExtension<Corners> {
  const Corners(this.radius);
  final double radius;
  @override
  Corners copyWith({double? radius}) => Corners(radius ?? this.radius);
  @override
  Corners lerp(Corners? other, double t) => other ?? this;
}

/// The marks' colours: running (green), update (orange), new (yellow),
/// from the desktop's palette.
class MarkColors extends ThemeExtension<MarkColors> {
  const MarkColors({required this.running, required this.update, required this.fresh});
  final Color running, update, fresh;
  @override
  MarkColors copyWith({Color? running, Color? update, Color? fresh}) =>
      MarkColors(running: running ?? this.running, update: update ?? this.update, fresh: fresh ?? this.fresh);
  @override
  MarkColors lerp(MarkColors? other, double t) => other ?? this;
}

MarkColors markColors(BuildContext context) =>
    Theme.of(context).extension<MarkColors>() ??
    const MarkColors(running: Color(0xff3a944a), update: Color(0xffed5b00), fresh: Color(0xffc88800));

double corners(BuildContext context) => Theme.of(context).extension<Corners>()?.radius ?? 12;

/// "windows" follows the desktop's window corners, "rounded" 12, "square" 0.
double cornerRadius(String setting, int? windowRounding) => switch (setting) {
  'rounded' => 12,
  'square' => 0,
  _ => (windowRounding ?? 12).toDouble(),
};

/// The desktop's palette (desktop.look colors) as a Material theme; an
/// empty palette (generic desktops) follows the platform's light or dark.
ThemeData appTheme(Brightness platform, Map colors, double radius) {
  final background = hexColor(colors, 'background');
  final brightness = background == null
      ? platform
      : (background.computeLuminance() < .5 ? Brightness.dark : Brightness.light);
  var scheme = ColorScheme.fromSeed(
    seedColor: hexColor(colors, 'accent') ?? const Color(0xff3584e4),
    brightness: brightness,
  );
  if (background != null) {
    final foreground = hexColor(colors, 'foreground') ?? scheme.onSurface;
    Color step(double amount) => Color.lerp(background, foreground, amount)!;
    scheme = scheme.copyWith(
      primary: hexColor(colors, 'accent') ?? scheme.primary,
      surface: background,
      onSurface: foreground,
      onSurfaceVariant: hexColor(colors, 'muted') == null
          ? step(.6)
          : Color.lerp(hexColor(colors, 'muted'), foreground, .35),
      surfaceContainerLowest: step(.02),
      surfaceContainerLow: step(.05),
      surfaceContainer: step(.08),
      surfaceContainerHigh: step(.11),
      surfaceContainerHighest: step(.14),
      outlineVariant: step(.18),
      secondaryContainer: hexColor(colors, 'selection') ?? step(.2),
      error: hexColor(colors, 'red') ?? scheme.error,
    );
  }
  final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius));
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    scaffoldBackgroundColor: scheme.surface,
    extensions: [
      Corners(radius),
      MarkColors(
        running: hexColor(colors, 'green') ?? const Color(0xff3a944a),
        update: hexColor(colors, 'orange') ?? const Color(0xffed5b00),
        fresh: hexColor(colors, 'yellow') ?? const Color(0xffc88800),
      ),
    ],
    cardTheme: CardThemeData(
      color: scheme.surfaceContainerLow,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radius),
        side: BorderSide(color: scheme.outlineVariant),
      ),
    ),
    dialogTheme: DialogThemeData(shape: shape),
    popupMenuTheme: PopupMenuThemeData(
      color: scheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius.clamp(0, 8))),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainer,
      isDense: true,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(radius.clamp(0, 10)), borderSide: BorderSide.none),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: scheme.surfaceContainerHigh,
      contentTextStyle: TextStyle(color: scheme.onSurface),
      behavior: SnackBarBehavior.floating,
    ),
  );
}
