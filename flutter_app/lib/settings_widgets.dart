import 'package:flutter/material.dart';

import 'theme.dart';

/// COSMIC Settings' page parts in Flutter (libcosmic `settings::section`, `settings::item`,
/// `list_column`): a page title, sections with a heading over a rounded card whose rows are
/// split by thin dividers, a row = title (+ dimmer description) left, its control right.
abstract final class SettingsMetrics {
  /// The content column's widest (COSMIC's page_container; wider windows centre it).
  static const maxWidth = 800.0;

  /// Left and right of the page: 32, in a condensed window 16.
  static double sidePadding(BuildContext context) => MediaQuery.sizeOf(context).width < 648 ? 16 : 32;
  static const sectionGap = 24.0;
  static const headingGap = 8.0;
  static const rowPadding = EdgeInsets.symmetric(horizontal: 24, vertical: 8);
  static const rowMinHeight = 48.0;
  static const rowSpacing = 12.0;
}

/// COSMIC's title3: 24 px bold.
TextStyle pageTitleStyle(BuildContext context) => Theme.of(context).textTheme.headlineSmall!.copyWith(height: 1.5, fontWeight: FontWeight.w700, color: Theme.of(context).colorScheme.onSurface);

/// The page's title, as COSMIC Settings shows it above the sections.
class SettingsTitle extends StatelessWidget {
  const SettingsTitle(this.text, {super.key, this.trailing = const []});
  final String text;
  final List<Widget> trailing;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Row(
      children: [
        Expanded(
          child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageTitleStyle(context)),
        ),
        ...trailing,
      ],
    ),
  );
}

/// A scrolling settings page: title and sections in a centred column of at most [SettingsMetrics.maxWidth].
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.title, required this.children, this.actions = const []});
  final String title;
  final List<Widget> actions;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => ListView(
    padding: EdgeInsets.fromLTRB(SettingsMetrics.sidePadding(context), 16, SettingsMetrics.sidePadding(context), 24),
    children: [
      Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: SettingsMetrics.maxWidth),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SettingsTitle(title, trailing: actions),
              for (var i = 0; i < children.length; i++) ...[
                if (i > 0) const SizedBox(height: SettingsMetrics.sectionGap),
                children[i],
              ],
            ],
          ),
        ),
      ),
    ],
  );
}

/// A heading over a rounded card of rows with dividers between them.
class SettingsSection extends StatelessWidget {
  const SettingsSection({super.key, this.title, this.note, required this.children});
  final String? title;

  /// A line under the card (where a value is saved, why something is missing).
  final String? note;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final radius = cornerSizes(context).control;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (title != null)
          Padding(
            padding: const EdgeInsets.only(left: 2, bottom: SettingsMetrics.headingGap),
            child: Text(title!, style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
          ),
        Container(
          decoration: BoxDecoration(color: scheme.surfaceContainer, borderRadius: BorderRadius.circular(radius)),
          clipBehavior: Clip.antiAlias,
          child: Material(
            type: MaterialType.transparency,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < children.length; i++) ...[
                  if (i > 0) Divider(height: 1, thickness: 1, color: scheme.outlineVariant.withValues(alpha: .6)),
                  children[i],
                ],
              ],
            ),
          ),
        ),
        if (note != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(2, 6, 2, 0),
            child: Text(note!, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
          ),
      ],
    );
  }
}

/// One row: title and an optional description left, the control right; [onTap] makes the
/// whole row clickable (a switch row toggles from anywhere on it, as in COSMIC).
class SettingsItem extends StatelessWidget {
  const SettingsItem({super.key, required this.title, this.description, this.trailing, this.onTap, this.leading});
  final String title;
  final String? description;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final row = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: SettingsMetrics.rowMinHeight),
      child: Padding(
        padding: SettingsMetrics.rowPadding,
        child: Row(
          children: [
            if (leading != null) ...[leading!, const SizedBox(width: SettingsMetrics.rowSpacing)],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title),
                  if (description != null && description!.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(description!, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                    ),
                ],
              ),
            ),
            if (trailing != null) ...[const SizedBox(width: SettingsMetrics.rowSpacing), trailing!],
          ],
        ),
      ),
    );
    return onTap == null ? row : InkWell(onTap: onTap, child: row);
  }
}

/// A switch row.
class SettingsToggle extends StatelessWidget {
  const SettingsToggle({super.key, required this.title, this.description, required this.value, required this.onChanged});
  final String title;
  final String? description;
  final bool value;
  final ValueChanged<bool>? onChanged;
  @override
  Widget build(BuildContext context) => SettingsItem(
    title: title,
    description: description,
    onTap: onChanged == null ? null : () => onChanged!(!value),
    trailing: Switch(value: value, onChanged: onChanged),
  );
}

/// A drop-down row ([choices]: value → label).
class SettingsChoice<T> extends StatelessWidget {
  const SettingsChoice({super.key, required this.title, this.description, required this.value, required this.choices, required this.onChanged, this.disabled = const {}});
  final String title;
  final String? description;
  final T value;
  final List<(T, String)> choices;

  /// Choices shown but not selectable (an engine that isn't available).
  final Set<T> disabled;
  final ValueChanged<T>? onChanged;
  @override
  Widget build(BuildContext context) => SettingsItem(
    title: title,
    description: description,
    trailing: DropdownButtonHideUnderline(
      child: DropdownButton<T>(
        value: choices.any((c) => c.$1 == value) ? value : null,
        isDense: true,
        borderRadius: BorderRadius.circular(cornerSizes(context).radius),
        dropdownColor: Theme.of(context).colorScheme.surfaceContainerHigh,
        items: [for (final (v, label) in choices) DropdownMenuItem<T>(
            value: v,
            enabled: !disabled.contains(v),
            child: Text(label, style: disabled.contains(v) ? TextStyle(color: Theme.of(context).disabledColor) : null),
          ),
        ],
        onChanged: onChanged == null ? null : (v) => v == null ? null : onChanged!(v),
      ),
    ),
  );
}

/// A slider row (COSMIC: the value's label at the slider's right). [onChangeEnd] saves; while
/// dragging only the shown value moves.
class SettingsSlider extends StatefulWidget {
  const SettingsSlider({
    super.key,
    required this.title,
    this.description,
    required this.value,
    required this.min,
    required this.max,
    this.divisions,
    required this.label,
    required this.onChangeEnd,
    this.leading,
  });
  final String title;
  final String? description;
  final double value, min, max;
  final int? divisions;
  final String Function(double value) label;
  final ValueChanged<double>? onChangeEnd;

  /// A button left of the slider (mute).
  final Widget? leading;
  @override
  State<SettingsSlider> createState() => _SettingsSliderState();
}

class _SettingsSliderState extends State<SettingsSlider> {
  double? _dragging;

  @override
  Widget build(BuildContext context) {
    final v = (_dragging ?? widget.value).clamp(widget.min, widget.max);
    return SettingsItem(
      title: widget.title,
      description: widget.description,
      trailing: SizedBox(
        width: 280,
        child: Row(
          children: [
            ?widget.leading,
            Expanded(
              child: Slider(
                value: v,
                min: widget.min,
                max: widget.max,
                divisions: widget.divisions,
                onChanged: widget.onChangeEnd == null ? null : (x) => setState(() => _dragging = x),
                onChangeEnd: widget.onChangeEnd == null
                    ? null
                    : (x) {
                        widget.onChangeEnd!(x);
                        setState(() => _dragging = null);
                      },
              ),
            ),
            SizedBox(width: 64, child: Text(widget.label(v), textAlign: TextAlign.end, maxLines: 1, softWrap: false)),
          ],
        ),
      ),
    );
  }
}
