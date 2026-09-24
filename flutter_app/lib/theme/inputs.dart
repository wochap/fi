import 'dart:math' as math;

import 'package:fi/theme/form_errors.dart';
import 'package:fi/theme/nocturne.dart';
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
}) {
  final height = Nocturne.inputHeight(context, size);
  final vertical = math.max(_minPadding, (height - contentHeight) / 2);
  // Icons may be as tall as the box but never taller, so an IconButton can't grow it.
  final iconConstraints = BoxConstraints(
    minWidth: math.min(height, 40),
    maxHeight: math.max(height, contentHeight + 2 * _minPadding),
  );
  return InputDecoration(
    isDense: true,
    labelText: required ? null : label,
    label: required && label != null ? requiredLabel(label) : null,
    hintText: hint,
    helperText: helperText,
    helperMaxLines: 2,
    errorText: errorTextOf(errors),
    errorMaxLines: errorLinesOf(errors),
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

  @override
  Widget build(BuildContext context) => TextFormField(
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

  @override
  Widget build(BuildContext context) {
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
/// [icon] is the trailing picker icon; [actions] (such as a "Today" text button or a clear
/// button) sit before it, or replace it when [replaceIcon] is set.
class FiPickerInput extends StatelessWidget {
  const FiPickerInput({
    required this.controller,
    required this.onTap,
    required this.icon,
    this.actions = const [],
    this.replaceIcon,
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

  /// Compact actions before the trailing icon.
  final List<Widget> actions;

  /// Shown instead of [icon], for example a clear button once there is a value.
  final Widget? replaceIcon;
  final String? label;
  final String? hint;
  final bool required;
  final List<String> errors;
  final String? helperText;
  final InputSize size;

  @override
  Widget build(BuildContext context) {
    final trailing = replaceIcon ?? Icon(icon, size: 20);
    return FiTextInput(
      controller: controller,
      readOnly: true,
      onTap: onTap,
      label: label,
      hint: hint,
      required: required,
      errors: errors,
      helperText: helperText,
      size: size,
      suffixIcon: actions.isEmpty
          ? trailing
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ...actions,
                Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: trailing,
                ),
              ],
            ),
    );
  }
}
