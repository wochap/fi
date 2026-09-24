import 'dart:async';

import 'package:fi/help_copy.dart';
import 'package:fi/theme/form_errors.dart';
import 'package:flutter/material.dart';

/// The one help affordance: a `?` beside a control that opens the registry copy for it.
///
/// It reads from [helpCopy] and never carries copy of its own, so the text for a concept stays
/// reviewable in one file. An id with no entry renders nothing rather than an empty popup; the
/// registry test is what turns that into a failure.
final class HelpButton extends StatelessWidget {
  const HelpButton(this.id, {super.key});

  final HelpId id;

  @override
  Widget build(BuildContext context) {
    final entry = helpCopy[id];
    if (entry == null) return const SizedBox.shrink();
    return IconButton(
      key: Key('help-${id.name}'),
      icon: const Icon(Icons.help_outline, size: 18),
      tooltip: 'About ${entry.title}',
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
      // Opening help is a read; it must not touch the form it sits in.
      onPressed: () => unawaited(showHelp(context, id)),
    );
  }
}

/// Opens the dismissible popup for [id]. Tapping outside or Close returns without a result, so no
/// caller can mistake dismissal for a decision.
Future<void> showHelp(BuildContext context, HelpId id) async {
  final entry = helpCopy[id];
  if (entry == null) return;
  await showDialog<void>(
    context: context,
    builder: (dialog) => AlertDialog(
      key: const Key('help-dialog'),
      title: Text(entry.title),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(child: Text(entry.body)),
      ),
      actions: [
        TextButton(
          key: const Key('help-close'),
          onPressed: () => Navigator.pop(dialog),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}

/// An [InputDecoration] carrying the label and the `?` for [id] as its suffix, so attaching help
/// to a text field or dropdown is a one-line change at the call site.
///
/// A `SwitchListTile` has no decoration; there the button goes in `trailing: HelpButton(id)`.
///
/// [errors] show below the input one per line; [required] marks the label with an `*`.
InputDecoration labelWithHelp(
  String label,
  HelpId id, {
  String? helperText,
  List<String> errors = const [],
  bool required = false,
}) => InputDecoration(
  labelText: required ? null : label,
  label: required ? requiredLabel(label) : null,
  helperText: helperText,
  errorText: errorTextOf(errors),
  errorMaxLines: errorLinesOf(errors),
  suffixIcon: HelpButton(id),
);
