import 'package:fi/l10n/l10n.dart';
import 'package:fi/theme/fi_icons.dart';
import 'package:fi/theme/nocturne.dart';
import 'package:flutter/material.dart';

/// A field's error message under its control: a warning icon, then one line per issue in
/// the theme's danger color; its control gets an accent border. [text] is the lines joined by newlines, as one `Text`.
class FieldErrorMessage extends StatelessWidget {
  const FieldErrorMessage(this.lines, {super.key});

  final List<String> lines;

  String get text => lines.join('\n');

  @override
  Widget build(BuildContext context) {
    final danger = context.nocturne.danger;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(FiIcons.error, size: 14, color: danger),
        ),
        const SizedBox(width: 6),
        Flexible(
          child: Text(text, style: TextStyle(fontSize: 12, color: danger)),
        ),
      ],
    );
  }
}

/// Error lines under a control that has no `InputDecoration` (a switch, a segmented choice),
/// drawn like an input's: a warning icon and one line per issue.
class FieldErrorLines extends StatelessWidget {
  const FieldErrorLines(this.lines, {super.key});

  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    if (lines.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
      child: FieldErrorMessage(lines),
    );
  }
}

/// The summary pinned above a form's footer after a save left fields with errors: "Couldn't
/// save. N fields need attention." with [onShow], which jumps to the first of them.
class FormErrorSummary extends StatelessWidget {
  const FormErrorSummary({
    required this.count,
    required this.onShow,
    super.key,
  });

  final int count;
  final VoidCallback onShow;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Container(
      key: const Key('form-error-summary'),
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
      constraints: const BoxConstraints(minHeight: 44),
      decoration: BoxDecoration(
        color: context.nocturne.bg,
        borderRadius: BorderRadius.circular(Nocturne.radius),
        border: Border.all(color: context.nocturne.danger),
      ),
      child: Row(
        children: [
          Icon(FiIcons.error, size: 18, color: context.nocturne.danger),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              context.l10n.formCouldntSave(count),
              style: TextStyle(fontSize: 13, color: context.nocturne.text),
            ),
          ),
          TextButton(onPressed: onShow, child: Text(context.l10n.commonShow)),
        ],
      ),
    ),
  );
}

/// The form-level slot's contents: issues that name no field or several, and failures that are
/// not validation issues. One 13px line per issue, in the error color.
class FormErrorLines extends StatelessWidget {
  const FormErrorLines(this.lines, {super.key});

  final List<String> lines;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    spacing: 4,
    children: [
      for (final line in lines)
        Text(
          line,
          style: TextStyle(fontSize: 13, color: context.nocturne.danger),
        ),
    ],
  );
}

/// [errors] as `InputDecoration.error`: a [FieldErrorMessage], or null when there are none.
Widget? errorOf(List<String> errors) =>
    errors.isEmpty ? null : FieldErrorMessage(errors);

/// The error lines an input shows, read back from its decoration; null when it shows none.
String? decorationErrorText(InputDecoration? decoration) =>
    switch (decoration?.error) {
      FieldErrorMessage(:final text) => text,
      _ => decoration?.errorText,
    };

/// An input label for a required value: the name, then an `*` in `accentText` (not the error
/// color). Screen readers hear "name, required". Use as `InputDecoration.label`.
Widget requiredLabel(String name) => Builder(
  builder: (context) => Semantics(
    label: context.l10n.formRequiredSemantics(name),
    excludeSemantics: true,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(child: Text(name, overflow: TextOverflow.ellipsis)),
        Text(' *', style: TextStyle(color: context.nocturne.accentText)),
      ],
    ),
  ),
);

/// The one "* required" line a form with any marked input shows.
class RequiredLegend extends StatelessWidget {
  const RequiredLegend({super.key});

  @override
  Widget build(BuildContext context) => Text.rich(
    TextSpan(
      children: [
        TextSpan(
          text: '*',
          style: TextStyle(color: context.nocturne.accentText),
        ),
        TextSpan(
          text: context.l10n.formRequiredLegend,
          style: TextStyle(color: context.nocturne.muted(.55)),
        ),
      ],
    ),
    style: const TextStyle(fontSize: 12),
  );
}
