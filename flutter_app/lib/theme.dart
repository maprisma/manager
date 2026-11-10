import 'dart:math';

import 'package:flutter/material.dart';

Color? hexColor(Map colors, String key) {
  final value = colors[key];
  if (value is! String || !RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(value)) {
    return null;
  }
  return Color(0xff000000 | int.parse(value.substring(1), radix: 16));
}

/// The corner radius in effect (Settings › Corners; the desktop's windows), in Maprisma
/// Playground's three sizes: cards, dialogs, pop-ups and menus take [radius]; buttons, drop-downs,
/// fields, tooltips and chips [control] (at most 8); check boxes, slider tracks and progress bars
/// [small] (at most 4). Square squares everything; the slider knob stays small (see [KnobShape]).
class Corners extends ThemeExtension<Corners> {
  const Corners(this.radius);
  final double radius;
  double get control => min(radius, 8);
  double get small => min(radius, 4);

  /// Framed areas inside a page (the bar editor's areas): as the cards, up to 12.
  double get board => min(radius, 12);
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

/// Settings › Corners in its three sizes (see [Corners]).
Corners cornerSizes(BuildContext context) => Theme.of(context).extension<Corners>() ?? const Corners(12);

/// "windows" follows the desktop's window corners, "slight" 6 (round controls beside square or
/// tiled windows), "rounded" 12, "square" 0. An unknown value counts as "windows".
const slightRadius = 6, roundedRadius = 12;
double cornerRadius(String setting, int? windowRounding) => switch (setting) {
  'slight' => 6,
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
  final sizes = Corners(radius);
  final control = sizes.control, small = sizes.small;
  final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius));
  final controlShape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(control));
  OutlineInputBorder field([BorderSide side = BorderSide.none]) =>
      OutlineInputBorder(borderRadius: BorderRadius.circular(control), borderSide: side);
  final menu = MenuStyle(
    backgroundColor: WidgetStatePropertyAll(scheme.surfaceContainerHigh),
    shape: WidgetStatePropertyAll(shape),
  );
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    scaffoldBackgroundColor: scheme.surface,
    extensions: [
      sizes,
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
    popupMenuTheme: PopupMenuThemeData(color: scheme.surfaceContainerHigh, shape: shape),
    menuTheme: MenuThemeData(style: menu),
    dropdownMenuTheme: DropdownMenuThemeData(
      menuStyle: menu,
      inputDecorationTheme: InputDecorationTheme(filled: true, fillColor: scheme.surfaceContainer, isDense: true, border: field()),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainer,
      isDense: true,
      border: field(),
      enabledBorder: field(),
      focusedBorder: field(BorderSide(color: scheme.primary, width: 1.5)),
      errorBorder: field(BorderSide(color: scheme.error)),
      focusedErrorBorder: field(BorderSide(color: scheme.error, width: 1.5)),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: scheme.surfaceContainerHigh,
      contentTextStyle: TextStyle(color: scheme.onSurface),
      behavior: SnackBarBehavior.floating,
      shape: shape,
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(color: scheme.inverseSurface, borderRadius: BorderRadius.circular(control)),
    ),
    filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(shape: controlShape)),
    outlinedButtonTheme: OutlinedButtonThemeData(style: OutlinedButton.styleFrom(shape: controlShape)),
    textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(shape: controlShape)),
    elevatedButtonTheme: ElevatedButtonThemeData(style: ElevatedButton.styleFrom(shape: controlShape)),
    iconButtonTheme: IconButtonThemeData(style: IconButton.styleFrom(shape: controlShape)),
    segmentedButtonTheme: SegmentedButtonThemeData(style: SegmentedButton.styleFrom(shape: controlShape)),
    chipTheme: ChipThemeData(shape: controlShape),
    checkboxTheme: CheckboxThemeData(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(small))),
    progressIndicatorTheme: ProgressIndicatorThemeData(borderRadius: BorderRadius.circular(small)),
    // Square squares the slider too, but keeps its knob small (no block).
    sliderTheme: SliderThemeData(
      trackShape: radius <= 0 ? const RectangularSliderTrackShape() : const RoundedRectSliderTrackShape(),
      thumbShape: KnobShape(square: radius <= 0),
    ),
  );
}

/// The slider's knob: 14 px, round, or square with Square corners (not a big block).
class KnobShape extends SliderComponentShape {
  const KnobShape({this.square = false});
  final bool square;
  static const _side = 14.0;

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) => const Size.square(_side);

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    final paint = Paint()..color = sliderTheme.thumbColor ?? Colors.grey;
    final box = Rect.fromCenter(center: center, width: _side, height: _side);
    square ? context.canvas.drawRect(box, paint) : context.canvas.drawOval(box, paint);
  }
}
