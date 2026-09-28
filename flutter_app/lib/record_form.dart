import 'package:fi/theme/form_errors.dart';
import 'package:fi/theme/nocturne.dart';
import 'package:fi/theme/nocturne_widgets.dart';
import 'package:flutter/material.dart';

/// Width of the label column beside the controls at 720px and wider.
const double recordFormLabelWidth = 140;

/// One field of a [RecordFormBody]: its name and markers, and the control that edits it.
final class RecordFormRow {
  const RecordFormRow({
    required this.id,
    required this.name,
    required this.control,
    this.required = false,
    this.defaulted = false,
    this.needed = false,
    this.key,
  });

  final String id;
  final String name;
  final Widget control;

  /// Adds the accent `*` after the name.
  final bool required;

  /// Shows the Default marker: the field still holds its seeded default.
  final bool defaulted;

  /// Shows the Needed marker and "Needed to complete this record" under the control.
  final bool needed;

  /// Keys the whole row, for scrolling to it.
  final Key? key;
}

/// The record editor's fields: labels in a 140px column beside the controls at 720px and wider,
/// labels above the controls below 720px, one field per row either way. A label row holds the
/// name, the required `*`, and trailing markers (Default, Needed).
class RecordFormBody extends StatelessWidget {
  const RecordFormBody({required this.rows, super.key});

  final List<RecordFormRow> rows;

  @override
  Widget build(BuildContext context) {
    final wide = !Nocturne.isPhone(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: wide ? 14 : 16,
      children: [for (final row in rows) _row(context, row, wide)],
    );
  }

  Widget _row(BuildContext context, RecordFormRow row, bool wide) {
    final laidOut = _layout(context, row, wide);
    return row.needed
        ? KeyedSubtree(key: Key('needed-${row.id}'), child: laidOut)
        : laidOut;
  }

  Widget _layout(BuildContext context, RecordFormRow row, bool wide) {
    final name = DefaultTextStyle.merge(
      style: TextStyle(fontSize: 13, color: Nocturne.muted(.75)),
      child: row.required ? requiredLabel(row.name) : Text(row.name),
    );
    final markers = [
      if (row.needed) const NeededMarker(),
      if (row.defaulted && !row.needed)
        DefaultMarker(key: Key('default-${row.id}')),
    ];
    Widget control = row.control;
    if (row.needed) {
      control = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        spacing: 4,
        children: [
          control,
          const Text(
            'Needed to complete this record',
            style: TextStyle(fontSize: 12, color: fieldErrorColor),
          ),
        ],
      );
    }
    if (!wide) {
      return Column(
        key: row.key,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        spacing: 6,
        children: [
          Row(
            children: [
              Expanded(child: name),
              for (final marker in markers) ...[
                const SizedBox(width: 8),
                marker,
              ],
            ],
          ),
          control,
        ],
      );
    }
    // The label's first line sits level with the middle of a normal input box.
    final top = (Nocturne.inputHeight(context, InputSize.normal) - 18) / 2;
    return Row(
      key: row.key,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: recordFormLabelWidth,
          child: Padding(
            padding: EdgeInsets.only(top: top),
            child: Wrap(
              spacing: 6,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [name, ...markers],
            ),
          ),
        ),
        const SizedBox(width: 18),
        Expanded(child: control),
      ],
    );
  }
}
