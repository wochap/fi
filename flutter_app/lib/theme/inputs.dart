import 'dart:math' as math;

import 'package:fi/theme/fi_icons.dart';
import 'package:fi/theme/form_errors.dart';
import 'package:fi/theme/nocturne.dart';
import 'package:fi/theme/nocturne_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// Every text, number, select and picker input in feature code is one of the widgets here, so
// inputs of one size share one box height on a screen ([Nocturne.inputHeight]).
//
// The box height is fixed by padding derived from it: the content height is known (a forced
// strut line for text, Flutter's dense dropdown button for a select), and the vertical content
// padding is what is left of the box. `InputDecoration.constraints` can't do this, because it
// also constrains the error lines below the box and squeezes the box when they appear.
//
// Text scaling: the content height follows `MediaQuery.textScaler`, and the padding never drops
// below [_minPadding], so a large text scale grows the box instead of clipping the text.

const double _fontSize = 14;

/// A text input's line height at text scale 1, held by [_strut].
const double _lineHeight = 20;

/// Flutter never makes a dense dropdown button shorter than this.
const double _denseButtonHeight = 24;

/// The select arrow, capped at the line height so it never sets the box height.
const double _selectIconSize = _lineHeight;

const double _minPadding = 2;

const _strut = StrutStyle(
  fontSize: _fontSize,
  height: _lineHeight / _fontSize,
  forceStrutHeight: true,
);

double _textContentHeight(BuildContext context) =>
    MediaQuery.textScalerOf(context).scale(_fontSize) * _lineHeight / _fontSize;

double _selectContentHeight(BuildContext context) => math.max(
  _denseButtonHeight,
  // Flutter's dense button grows with the scaled 14 × 1.4 value line.
  MediaQuery.textScalerOf(context).scale(_fontSize * 1.4),
);

/// The decoration every shared input uses: the label (with the `*` marker when [required]),
/// one error line per issue, and padding that makes the box [size] tall.
///
/// [belowContent] is extra content height under the [contentHeight] line (the slider's label
/// row): it makes the box that much taller without changing the padding around the line.
InputDecoration _decoration(
  BuildContext context, {
  required InputSize size,
  required double contentHeight,
  required String? label,
  required String? hint,
  required bool required,
  required List<String> errors,
  required String? helperText,
  required Widget? prefixIcon,
  required Widget? suffixIcon,
  double belowContent = 0,
}) {
  final height = Nocturne.inputHeight(context, size);
  final vertical = math.max(_minPadding, (height - contentHeight) / 2);
  // Icons may be as tall as the box but never taller, so an IconButton can't grow it.
  final iconConstraints = BoxConstraints(
    minWidth: math.min(height, 40),
    maxHeight: math.max(height, contentHeight + 2 * _minPadding) + belowContent,
  );
  return InputDecoration(
    isDense: true,
    labelText: required ? null : label,
    label: required && label != null ? requiredLabel(label) : null,
    hintText: hint,
    helperText: helperText,
    helperMaxLines: 2,
    // The theme draws the box of an input in error with the accent border.
    error: errorOf(errors),
    contentPadding: EdgeInsets.symmetric(
      horizontal: size == InputSize.small ? 10 : 12,
      vertical: vertical,
    ),
    prefixIcon: prefixIcon,
    prefixIconConstraints: prefixIcon == null ? null : iconConstraints,
    suffixIcon: suffixIcon,
    suffixIconConstraints: suffixIcon == null ? null : iconConstraints,
  );
}

/// A text input: plain text, integer, decimal or search (through [keyboardType],
/// [inputFormatters], [prefixIcon] and [suffixIcon]), or multiline with [maxLines] above 1.
///
/// Builds a `TextFormField`. A multiline input starts at the box height for its first line and
/// grows by whole lines up to [maxLines].
class FiTextInput extends StatelessWidget {
  const FiTextInput({
    this.controller,
    this.initialValue,
    this.label,
    this.hint,
    this.required = false,
    this.errors = const [],
    this.helperText,
    this.size = InputSize.normal,
    this.keyboardType,
    this.inputFormatters,
    this.textInputAction,
    this.onChanged,
    this.onSubmitted,
    this.onTap,
    this.readOnly = false,
    this.enabled,
    this.autofocus = false,
    this.focusNode,
    this.maxLines = 1,
    this.prefixIcon,
    this.suffixIcon,
    this.style,
    this.onClear,
    super.key,
  });

  /// A small text input for an inline builder row.
  const FiTextInput.compact({
    this.controller,
    this.initialValue,
    this.label,
    this.hint,
    this.required = false,
    this.errors = const [],
    this.helperText,
    this.keyboardType,
    this.inputFormatters,
    this.textInputAction,
    this.onChanged,
    this.onSubmitted,
    this.onTap,
    this.readOnly = false,
    this.enabled,
    this.autofocus = false,
    this.focusNode,
    this.maxLines = 1,
    this.prefixIcon,
    this.suffixIcon,
    this.style,
    this.onClear,
    super.key,
  }) : size = InputSize.small;

  final TextEditingController? controller;

  /// The starting text when there is no [controller].
  final String? initialValue;
  final String? label;
  final String? hint;

  /// Marks the label with the accent `*`.
  final bool required;

  /// One line per issue, shown under the box in order.
  final List<String> errors;
  final String? helperText;
  final InputSize size;
  final TextInputType? keyboardType;
  final List<TextInputFormatter>? inputFormatters;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final GestureTapCallback? onTap;
  final bool readOnly;
  final bool? enabled;
  final bool autofocus;
  final FocusNode? focusNode;

  /// More than 1 makes a text area that grows up to this many lines.
  final int maxLines;
  final Widget? prefixIcon;
  final Widget? suffixIcon;

  /// Overrides the value's text style, for example a monospace font for formulas.
  final TextStyle? style;

  /// Offers the clear mark while [controller] holds text; null for a required value. Clearing
  /// empties [controller] and then calls this.
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final controller = this.controller;
    if (onClear == null || controller == null) {
      return _field(context, suffixIcon);
    }
    return ValueListenableBuilder(
      valueListenable: controller,
      builder: (context, value, _) => _field(
        context,
        value.text.isEmpty
            ? suffixIcon
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ClearMark(
                    key: const Key('input-clear'),
                    onPressed: () {
                      controller.clear();
                      onClear!();
                    },
                  ),
                  ?suffixIcon,
                  if (suffixIcon == null) const SizedBox(width: 8),
                ],
              ),
      ),
    );
  }

  Widget _field(BuildContext context, Widget? suffixIcon) => TextFormField(
    controller: controller,
    initialValue: initialValue,
    keyboardType:
        keyboardType ?? (maxLines > 1 ? TextInputType.multiline : null),
    inputFormatters: inputFormatters,
    textInputAction: textInputAction,
    onChanged: onChanged,
    onFieldSubmitted: onSubmitted,
    onTap: onTap,
    readOnly: readOnly,
    enabled: enabled,
    autofocus: autofocus,
    focusNode: focusNode,
    minLines: 1,
    maxLines: maxLines,
    style: style,
    strutStyle: _strut,
    decoration: _decoration(
      context,
      size: size,
      contentHeight: _textContentHeight(context),
      label: label,
      hint: hint,
      required: required,
      errors: errors,
      helperText: helperText,
      prefixIcon: prefixIcon,
      suffixIcon: suffixIcon,
    ),
  );
}

/// A select (dropdown). Builds a `DropdownButtonFormField<T>`, dense and expanded, with the
/// arrow capped so it never sets the box height. [value] is kept in sync when it changes.
class FiSelect<T> extends StatelessWidget {
  const FiSelect({
    required this.items,
    required this.onChanged,
    this.value,
    this.label,
    this.hint,
    this.required = false,
    this.errors = const [],
    this.helperText,
    this.size = InputSize.normal,
    this.selectedItemBuilder,
    this.suffixIcon,
    this.style,
    this.onClear,
    super.key,
  });

  /// A small select for an inline builder row (expression builder nodes, query conditions).
  const FiSelect.compact({
    required this.items,
    required this.onChanged,
    this.value,
    this.label,
    this.hint,
    this.required = false,
    this.errors = const [],
    this.helperText,
    this.selectedItemBuilder,
    this.suffixIcon,
    this.style,
    this.onClear,
    super.key,
  }) : size = InputSize.small;

  final List<DropdownMenuItem<T>> items;

  /// Null disables the select.
  final ValueChanged<T?>? onChanged;
  final T? value;
  final String? label;
  final String? hint;
  final bool required;
  final List<String> errors;
  final String? helperText;
  final InputSize size;
  final DropdownButtonBuilder? selectedItemBuilder;

  /// Shown in place of the arrow, for example a help button; the whole box still opens the menu.
  final Widget? suffixIcon;
  final TextStyle? style;

  /// Offers the clear mark before the arrow while [value] is set; null for a required value.
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final suffixIcon = onClear != null && value != null
        ? Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ClearMark(key: const Key('input-clear'), onPressed: onClear!),
              Padding(
                padding: const EdgeInsets.only(left: 4, right: 10),
                child:
                    this.suffixIcon ??
                    const Icon(FiIcons.expand, size: _selectIconSize),
              ),
            ],
          )
        : this.suffixIcon;
    final decoration = _decoration(
      context,
      size: size,
      contentHeight: _selectContentHeight(context),
      label: label,
      hint: null,
      required: required,
      errors: errors,
      helperText: helperText,
      prefixIcon: null,
      // The dropdown shows a decoration's suffix in place of its arrow, and replaces the
      // decoration's icon constraints, so the suffix is held to the box height here.
      suffixIcon: suffixIcon == null
          ? null
          : SizedBox(
              height: Nocturne.inputHeight(context, size),
              child: suffixIcon,
            ),
    );
    return DropdownButtonFormField<T>(
      initialValue: value,
      items: items,
      onChanged: onChanged,
      selectedItemBuilder: selectedItemBuilder,
      hint: hint == null ? null : Text(hint!, overflow: TextOverflow.ellipsis),
      isDense: true,
      isExpanded: true,
      iconSize: _selectIconSize,
      style: style,
      decoration: decoration,
    );
  }
}

/// A read-only input that opens a picker (Date, Date & time, time) when tapped.
///
/// [quickAction] ("Today", "Now") is offered only while the input is empty: at 720px and wider
/// as a text button beside the box, below that as an inline accent link at the box's trailing
/// edge. [onClear] offers the clear mark while the input holds a value; leave it null for a
/// required value. [quickActionKey] keys the quick action in both places.
class FiPickerInput extends StatelessWidget {
  const FiPickerInput({
    required this.controller,
    required this.onTap,
    required this.icon,
    this.quickAction,
    this.onQuickAction,
    this.quickActionKey,
    this.onClear,
    this.label,
    this.hint,
    this.required = false,
    this.errors = const [],
    this.helperText,
    this.size = InputSize.normal,
    super.key,
  });

  final TextEditingController controller;
  final GestureTapCallback? onTap;
  final IconData icon;

  /// The quick-fill label, such as "Today"; shown only while the input is empty.
  final String? quickAction;
  final VoidCallback? onQuickAction;
  final Key? quickActionKey;

  /// Clears the value; the input empties [controller] first.
  final VoidCallback? onClear;
  final String? label;
  final String? hint;
  final bool required;
  final List<String> errors;
  final String? helperText;
  final InputSize size;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: controller,
    builder: (context, value, _) {
      final empty = value.text.isEmpty;
      final phone = Nocturne.isPhone(context);
      final quick = empty && quickAction != null && onQuickAction != null;
      final trailing = <Widget>[
        if (!empty && onClear != null)
          ClearMark(
            key: const Key('input-clear'),
            onPressed: () {
              controller.clear();
              onClear!();
            },
          )
        else if (quick && phone)
          TextButton(
            key: quickActionKey,
            style: TextButton.styleFrom(
              foregroundColor: Nocturne.accent300,
              visualDensity: VisualDensity.compact,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
            onPressed: onQuickAction,
            child: Text(quickAction!),
          ),
        Padding(
          padding: const EdgeInsets.only(left: 4, right: 10),
          child: Icon(icon, size: 20),
        ),
      ];
      final input = FiTextInput(
        controller: controller,
        readOnly: true,
        onTap: onTap,
        label: label,
        hint: hint,
        required: required,
        errors: errors,
        helperText: helperText,
        size: size,
        suffixIcon: Row(mainAxisSize: MainAxisSize.min, children: trailing),
      );
      if (!quick || phone) return input;
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: input),
          const SizedBox(width: 8),
          SizedBox(
            height: Nocturne.inputHeight(context, size),
            child: OutlinedButton(
              key: quickActionKey,
              onPressed: onQuickAction,
              child: Text(quickAction!),
            ),
          ),
        ],
      );
    },
  );
}

/// One option of a [FiSegmented].
final class FiSegment<T> {
  const FiSegment(this.value, this.label);

  final T value;
  final String label;
}

/// A choice among a few options drawn as equal-width segments of one control, as tall as a
/// normal input (so at least 44px on a phone).
///
/// Activating the selected segment again clears the value when [allowClear] is set, and does
/// nothing otherwise. [label] (with `*` when [required]) is drawn above the control when given.
class FiSegmented<T> extends StatelessWidget {
  const FiSegmented({
    required this.segments,
    required this.onChanged,
    this.value,
    this.allowClear = false,
    this.label,
    this.required = false,
    this.errors = const [],
    this.size = InputSize.normal,
    super.key,
  });

  final List<FiSegment<T>> segments;
  final T? value;

  /// Receives the picked value, or null when cleared. Null disables the control.
  final ValueChanged<T?>? onChanged;
  final bool allowClear;
  final String? label;
  final bool required;
  final List<String> errors;
  final InputSize size;

  void _tap(T picked) {
    if (picked == value) {
      if (allowClear) onChanged?.call(null);
      return;
    }
    onChanged?.call(picked);
  }

  @override
  Widget build(BuildContext context) {
    final height = math.max(
      Nocturne.inputHeight(context, size),
      Nocturne.isPhone(context) ? Nocturne.touchTarget : 0.0,
    );
    final error = errors.isNotEmpty;
    final enabled = onChanged != null;
    final radius = BorderRadius.circular(Nocturne.radius);
    final control = Container(
      height: height,
      decoration: BoxDecoration(
        borderRadius: radius,
        border: Border.all(color: error ? Nocturne.accent : Nocturne.divider),
      ),
      padding: const EdgeInsets.all(3),
      child: Row(
        children: [
          for (final segment in segments)
            Expanded(
              child: Semantics(
                button: true,
                selected: segment.value == value,
                child: Material(
                  color: segment.value == value
                      ? Nocturne.accent900
                      : Colors.transparent,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(Nocturne.radius - 3),
                    side: segment.value == value
                        ? const BorderSide(color: Nocturne.accent700)
                        : BorderSide.none,
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    key: ValueKey('segment-${segment.label}'),
                    onTap: enabled ? () => _tap(segment.value) : null,
                    child: Center(
                      child: Text(
                        segment.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: _fontSize,
                          color: segment.value == value
                              ? Nocturne.accent100
                              : Nocturne.muted(enabled ? .7 : .4),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (label case final label?)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: DefaultTextStyle.merge(
              style: TextStyle(fontSize: 12, color: Nocturne.muted(.7)),
              child: required ? requiredLabel(label) : Text(label),
            ),
          ),
        control,
        if (error) FieldErrorLines(errors),
      ],
    );
  }
}

/// Parses and formats duration text. The app uses the core's grammar through the bridge; tests
/// install their own through [FiDurationInput.grammar].
abstract interface class DurationGrammar {
  /// Signed milliseconds, or null when [text] does not parse.
  int? parse(String text);

  /// The canonical short form, such as "1h 30m".
  String format(int milliseconds);
}

/// A duration as a person reads it beside the phone input: "1 h 30 min", "−45 s", "0 s".
String formatDurationPreview(int milliseconds) {
  if (milliseconds == 0) return '0 s';
  var remaining = milliseconds.abs();
  final parts = <String>[];
  for (final (size, unit) in const [
    (3600000, 'h'),
    (60000, 'min'),
    (1000, 's'),
    (1, 'ms'),
  ]) {
    final count = remaining ~/ size;
    remaining %= size;
    if (count > 0) parts.add('$count $unit');
  }
  return '${milliseconds < 0 ? '−' : ''}${parts.join(' ')}';
}

/// A signed duration held as whole milliseconds.
///
/// At 720px and wider: a +/− [FiSegmented] sign and four boxes for hours, minutes, seconds and
/// milliseconds. Below 720px: one text input taking unit text ("1h 30m", "90m", "−45s"), with the
/// parsed value shown beside the text ("= 1 h 30 min") and "Use units like 1h 30m" as its error
/// while the text does not parse. [onChanged] receives null when the input is emptied.
class FiDurationInput extends StatefulWidget {
  const FiDurationInput({
    required this.onChanged,
    this.value,
    this.label,
    this.required = false,
    this.allowClear = false,
    this.errors = const [],
    this.size = InputSize.normal,
    super.key,
  });

  /// The grammar every duration input parses and formats with, set once at startup.
  static DurationGrammar? grammar;

  final int? value;
  final ValueChanged<int?> onChanged;
  final String? label;
  final bool required;

  /// Offers the clear mark while the input holds a value.
  final bool allowClear;
  final List<String> errors;
  final InputSize size;

  @override
  State<FiDurationInput> createState() => _FiDurationInputState();
}

class _FiDurationInputState extends State<FiDurationInput> {
  static const _unitSizes = [3600000, 60000, 1000, 1];
  static const _units = ['h', 'm', 's', 'ms'];

  late final TextEditingController _text = TextEditingController(
    text: widget.value == null ? '' : _grammar.format(widget.value!),
  );
  late final List<TextEditingController> _boxes = _split(widget.value);
  late bool _negative = (widget.value ?? 0) < 0;
  bool _unparsed = false;

  DurationGrammar get _grammar =>
      FiDurationInput.grammar ??
      (throw StateError('FiDurationInput.grammar is not set'));

  List<TextEditingController> _split(int? value) {
    if (value == null) {
      return [for (final _ in _units) TextEditingController()];
    }
    var remaining = value.abs();
    return [
      for (final size in _unitSizes)
        TextEditingController(
          text: () {
            final count = remaining ~/ size;
            remaining %= size;
            return '$count';
          }(),
        ),
    ];
  }

  @override
  void dispose() {
    _text.dispose();
    for (final box in _boxes) {
      box.dispose();
    }
    super.dispose();
  }

  void _boxesChanged() {
    if (_boxes.every((box) => box.text.isEmpty)) {
      widget.onChanged(null);
      return;
    }
    var total = 0;
    for (final (index, box) in _boxes.indexed) {
      total += (int.tryParse(box.text) ?? 0) * _unitSizes[index];
    }
    widget.onChanged(_negative ? -total : total);
  }

  void _textChanged(String raw) {
    if (raw.trim().isEmpty) {
      setState(() => _unparsed = false);
      widget.onChanged(null);
      return;
    }
    final parsed = _grammar.parse(raw);
    setState(() => _unparsed = parsed == null);
    if (parsed != null) widget.onChanged(parsed);
  }

  void _clear() {
    setState(() {
      _text.clear();
      for (final box in _boxes) {
        box.clear();
      }
      _negative = false;
      _unparsed = false;
    });
    widget.onChanged(null);
  }

  @override
  Widget build(BuildContext context) =>
      Nocturne.isPhone(context) ? _phone(context) : _wide(context);

  Widget _phone(BuildContext context) => ValueListenableBuilder(
    valueListenable: _text,
    builder: (context, value, _) {
      final parsed = value.text.trim().isEmpty
          ? null
          : _grammar.parse(value.text);
      return FiTextInput(
        key: const Key('duration-text'),
        controller: _text,
        label: widget.label,
        hint: 'e.g. 1h 30m or −45s',
        required: widget.required,
        size: widget.size,
        errors: [
          if (_unparsed && value.text.trim().isNotEmpty)
            'Use units like 1h 30m',
          ...widget.errors,
        ],
        prefixIcon: const Icon(FiIcons.duration, size: 18),
        suffixIcon: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (parsed != null)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Text(
                  '= ${formatDurationPreview(parsed)}',
                  key: const Key('duration-preview'),
                  style: TextStyle(
                    fontSize: 12,
                    color: Nocturne.muted(.55),
                    fontFeatures: Nocturne.tabular,
                  ),
                ),
              ),
            if (widget.allowClear && value.text.isNotEmpty)
              ClearMark(key: const Key('input-clear'), onPressed: _clear),
            const SizedBox(width: 8),
          ],
        ),
        onChanged: _textChanged,
      );
    },
  );

  Widget _wide(BuildContext context) {
    final holds = _boxes.any((box) => box.text.isNotEmpty);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.label case final label?)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: DefaultTextStyle.merge(
              style: TextStyle(fontSize: 12, color: Nocturne.muted(.7)),
              child: widget.required ? requiredLabel(label) : Text(label),
            ),
          ),
        Row(
          children: [
            SizedBox(
              width: 76,
              child: FiSegmented<bool>(
                key: const Key('duration-sign'),
                size: widget.size,
                segments: const [FiSegment(false, '+'), FiSegment(true, '−')],
                value: _negative,
                onChanged: (negative) {
                  if (negative == null) return;
                  setState(() => _negative = negative);
                  _boxesChanged();
                },
              ),
            ),
            for (final (index, unit) in _units.indexed) ...[
              const SizedBox(width: 6),
              Expanded(
                child: FiTextInput(
                  key: Key('duration-$unit'),
                  controller: _boxes[index],
                  hint: '0',
                  size: widget.size,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  suffixIcon: Padding(
                    padding: const EdgeInsets.only(right: 10),
                    child: Text(
                      unit,
                      style: TextStyle(
                        fontSize: 12,
                        color: Nocturne.muted(.55),
                      ),
                    ),
                  ),
                  onChanged: (_) {
                    setState(() {});
                    _boxesChanged();
                  },
                ),
              ),
            ],
            if (widget.allowClear && holds) ...[
              const SizedBox(width: 4),
              ClearMark(key: const Key('input-clear'), onPressed: _clear),
            ],
          ],
        ),
        if (widget.errors.isNotEmpty) FieldErrorLines(widget.errors),
      ],
    );
  }
}

/// A whole-number slider between [min] and [max], with the value as text on the trailing side.
///
/// With no [value] it shows a dashed track with no thumb and a "Set" action that picks [min]; a
/// first touch on the track picks the nearest step. Once set, the clear mark returns it to unset
/// when [allowClear] is on or the input is not [required]. [onChanged]
/// only ever receives integers inside the bounds, or null when cleared; the slider's double stays
/// inside this widget.
class FiSlider extends StatelessWidget {
  const FiSlider({
    required this.min,
    required this.max,
    required this.onChanged,
    this.step = 1,
    this.value,
    this.label,
    this.required = false,
    this.errors = const [],
    this.helperText,
    this.allowClear = false,
    this.size = InputSize.normal,
    super.key,
  }) : assert(min <= max),
       assert(step > 0),
       assert((max - min) % step == 0);

  final int min;
  final int max;

  /// Distance between reachable values; must divide `max - min` exactly.
  final int step;
  final int? value;

  /// Null disables the slider.
  final ValueChanged<int?>? onChanged;
  final String? label;
  final bool required;
  final List<String> errors;
  final String? helperText;

  /// Offers the clear icon even on a required input.
  final bool allowClear;
  final InputSize size;

  int _snap(double position) {
    final k = ((position - min) / step).round();
    return (min + k * step).clamp(min, max);
  }

  void _report(int next) {
    if (next != value) onChanged?.call(next);
  }

  @override
  Widget build(BuildContext context) {
    final value = this.value == null ? null : _snap(this.value!.toDouble());
    final contentHeight = _textContentHeight(context);
    final enabled = onChanged != null;
    final unset = value == null;
    final interactive = enabled && max > min;
    var touched = false;
    final theme = SliderTheme.of(context).copyWith(
      // Kept inside the line height so the thumb never sets the box height.
      trackHeight: 4,
      thumbShape: unset
          ? SliderComponentShape.noThumb
          : const RoundSliderThumbShape(enabledThumbRadius: 7),
      overlayShape: unset
          ? SliderComponentShape.noOverlay
          : const RoundSliderOverlayShape(overlayRadius: 14),
      showValueIndicator: ShowValueIndicator.never,
      // Unset, the track is drawn dashed underneath instead.
      activeTrackColor: unset ? Colors.transparent : null,
      inactiveTrackColor: unset ? Colors.transparent : null,
      activeTickMarkColor: unset ? Colors.transparent : null,
      inactiveTickMarkColor: unset ? Colors.transparent : null,
    );
    final slider = SliderTheme(
      data: theme,
      child: Slider(
        key: Key(unset ? 'slider-unset' : 'slider-set-track'),
        value: (value ?? min).toDouble(),
        min: min.toDouble(),
        max: max.toDouble(),
        divisions: max > min ? (max - min) ~/ step : null,
        onChanged: interactive
            ? (position) {
                touched = true;
                _report(_snap(position));
              }
            : null,
        // Slider skips onChanged when a touch lands on its current position,
        // so a first touch at the minimum reports here.
        onChangeEnd: interactive && unset
            ? (position) {
                if (!touched) _report(_snap(position));
              }
            : null,
      ),
    );
    final Widget content = unset
        ? Stack(
            alignment: Alignment.center,
            children: [
              Positioned.fill(
                child: CustomPaint(
                  key: const Key('slider-dashed-track'),
                  painter: _DashedTrackPainter(
                    color: Nocturne.muted(enabled ? .35 : .2),
                  ),
                ),
              ),
              slider,
            ],
          )
        : slider;
    final trailing = <Widget>[
      if (unset)
        TextButton.icon(
          key: const Key('slider-set-action'),
          style: TextButton.styleFrom(
            foregroundColor: Nocturne.accent300,
            visualDensity: VisualDensity.compact,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            padding: const EdgeInsets.symmetric(horizontal: 8),
          ),
          onPressed: interactive ? () => _report(min) : null,
          icon: const Icon(FiIcons.add, size: 14),
          label: const Text('Set'),
        )
      else
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Text(
            '$value',
            key: const Key('slider-value'),
            strutStyle: _strut,
            style: const TextStyle(
              fontSize: _fontSize,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ),
      if (!unset && (allowClear || !required))
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: ClearMark(
            key: const Key('slider-clear'),
            onPressed: enabled ? () => onChanged!(null) : () {},
          ),
        ),
    ];
    final labelRowHeight = _sliderLabelRowHeight(context);
    return InputDecorator(
      isEmpty: false,
      decoration: _decoration(
        context,
        size: size,
        contentHeight: contentHeight,
        belowContent: labelRowHeight,
        label: label,
        hint: null,
        required: required,
        errors: errors,
        helperText: helperText,
        prefixIcon: null,
        // Lifted by the label row so the value stays beside the track.
        suffixIcon: Padding(
          padding: EdgeInsets.only(bottom: labelRowHeight),
          child: Row(mainAxisSize: MainAxisSize.min, children: trailing),
        ),
      ).copyWith(enabled: enabled),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: contentHeight,
            child: Align(alignment: Alignment.centerLeft, child: content),
          ),
          SizedBox(
            height: labelRowHeight,
            child: _SliderLabels(
              min: min,
              max: max,
              step: step,
              theme: theme,
              enabled: enabled,
            ),
          ),
        ],
      ),
    );
  }
}

/// The unset slider's track: a dashed line across the middle, inset like the real track.
final class _DashedTrackPainter extends CustomPainter {
  const _DashedTrackPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    final y = size.height / 2;
    const inset = 2.0;
    for (var x = inset; x < size.width - inset; x += 8) {
      canvas.drawLine(
        Offset(x, y),
        Offset(math.min(x + 4, size.width - inset), y),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_DashedTrackPainter oldDelegate) =>
      color != oldDelegate.color;
}

const double _sliderLabelFontSize = 12;
const double _sliderLabelLineHeight = 16;

/// Gap kept between neighbouring step labels in the full row.
const double _sliderLabelGap = 8;

double _sliderLabelRowHeight(BuildContext context) =>
    MediaQuery.textScalerOf(context).scale(_sliderLabelFontSize) *
    _sliderLabelLineHeight /
    _sliderLabelFontSize;

/// The row under a [FiSlider]'s track: every step value centred under its tick when all of them
/// fit, otherwise only the minimum under the leading end and the maximum under the trailing end.
class _SliderLabels extends StatelessWidget {
  const _SliderLabels({
    required this.min,
    required this.max,
    required this.step,
    required this.theme,
    required this.enabled,
  });

  final int min;
  final int max;
  final int step;
  final SliderThemeData theme;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    final style = TextStyle(
      fontSize: _sliderLabelFontSize,
      height: _sliderLabelLineHeight / _sliderLabelFontSize,
      color: Theme.of(context).hintColor.withValues(alpha: enabled ? 1 : 0.6),
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final rtl = Directionality.of(context) == TextDirection.rtl;
    double widthOf(int value) {
      final painter = TextPainter(
        text: TextSpan(text: '$value', style: style),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
      )..layout();
      final width = painter.width;
      painter.dispose();
      return width;
    }

    // The widest label is one of the bounds (the minimum when it is negative).
    final labelWidth = math.max(widthOf(min), widthOf(max));
    final divisions = (max - min) ~/ step;
    // The same geometry the Slider's track shape uses: inset by the wider of the thumb and the
    // overlay, and discrete ticks kept a track height inside the rounded ends.
    final inset =
        math.max(
          theme.thumbShape!.getPreferredSize(false, true).width,
          theme.overlayShape!.getPreferredSize(false, true).width,
        ) /
        2;
    final trackHeight = theme.trackHeight!;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final trackWidth = math.max(0.0, width - 2 * inset);
        Widget label(
          int value, {
          double? left,
          double? right,
          TextAlign align = TextAlign.center,
        }) => Positioned(
          key: Key('slider-tick-$value'),
          top: 0,
          left: left,
          right: right,
          width: labelWidth,
          child: Text(
            '$value',
            maxLines: 1,
            softWrap: false,
            textAlign: align,
            style: style,
          ),
        );
        final children = <Widget>[];
        final fits =
            (divisions + 1) * (labelWidth + _sliderLabelGap) <= trackWidth;
        if (divisions == 0) {
          children.add(
            label(
              min,
              left: rtl ? null : inset,
              right: rtl ? inset : null,
              align: TextAlign.start,
            ),
          );
        } else if (fits) {
          final usable = trackWidth - trackHeight;
          for (var i = 0; i <= divisions; i++) {
            final dx = inset + trackHeight / 2 + usable * i / divisions;
            final x = rtl ? width - dx : dx;
            children.add(label(min + i * step, left: x - labelWidth / 2));
          }
        } else {
          // Clamped inside the track: the leading label starts at its left end, the trailing one
          // ends at its right end.
          children.addAll([
            label(
              min,
              left: rtl ? null : inset,
              right: rtl ? inset : null,
              align: TextAlign.start,
            ),
            label(
              max,
              left: rtl ? inset : null,
              right: rtl ? null : inset,
              align: TextAlign.end,
            ),
          ]);
        }
        return Stack(clipBehavior: Clip.none, children: children);
      },
    );
  }
}

/// In-place editing of a displayed title or label: the text in the caller's style with a caret
/// and selection, and no box. Unlike the inputs above it has no size token and no fixed height;
/// its height is the style's line height and its width follows the text, from [minWidth] (a few
/// characters in the style when null) up to the width the parent allows. Past that the text
/// scrolls to keep the caret in view.
class FiEditableText extends StatelessWidget {
  const FiEditableText({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.style,
    this.onSubmitted,
    this.textInputAction = TextInputAction.done,
    this.minWidth,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final TextStyle style;
  final ValueChanged<String>? onSubmitted;
  final TextInputAction textInputAction;
  final double? minWidth;

  static const double _cursorWidth = 2;

  /// Width added to the measured text for the caret at the end, so it is never clipped. A
  /// display widget the editor replaces can reserve the same room to keep its neighbours still.
  static const double caretAllowance = _cursorWidth + 2;

  double _measure(String text, TextScaler scaler, TextDirection direction) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: direction,
      textScaler: scaler,
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    final floor = minWidth ?? _measure('———', scaler, direction);
    return LayoutBuilder(
      builder: (context, constraints) => ValueListenableBuilder(
        valueListenable: controller,
        builder: (context, value, child) {
          final wanted =
              _measure(value.text, scaler, direction) + caretAllowance;
          final cap = constraints.maxWidth;
          final width = math.min(math.max(wanted, floor), cap);
          return SizedBox(width: width, child: child);
        },
        child: EditableText(
          controller: controller,
          focusNode: focusNode,
          style: style,
          textScaler: scaler,
          maxLines: 1,
          cursorWidth: _cursorWidth,
          cursorColor:
              theme.textSelectionTheme.cursorColor ?? theme.colorScheme.primary,
          backgroundCursorColor: theme.colorScheme.onSurface,
          selectionColor:
              theme.textSelectionTheme.selectionColor ??
              theme.colorScheme.primary.withValues(alpha: .4),
          selectionControls: materialTextSelectionControls,
          enableInteractiveSelection: true,
          textInputAction: textInputAction,
          onSubmitted: onSubmitted,
        ),
      ),
    );
  }
}
