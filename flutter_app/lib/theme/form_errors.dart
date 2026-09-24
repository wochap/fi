import 'package:fi/theme/nocturne.dart';
import 'package:flutter/material.dart';

/// Error lines under an input that has no `InputDecoration` (a switch row, a picker), styled like
/// Material's `errorText`: one line per issue, in the error color, no bullets.
class FieldErrorLines extends StatelessWidget {
  const FieldErrorLines(this.lines, {super.key});

  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    if (lines.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 2,
        children: [
          for (final line in lines)
            Text(
              line,
              style: const TextStyle(fontSize: 12, color: Nocturne.error),
            ),
        ],
      ),
    );
  }
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
          style: TextStyle(
            fontSize: 13,
            color: Theme.of(context).colorScheme.error,
          ),
        ),
    ],
  );
}

/// [errors] as `InputDecoration.errorText`: one line per issue, or null when there are none.
String? errorTextOf(List<String> errors) =>
    errors.isEmpty ? null : errors.join('\n');

/// `InputDecoration.errorMaxLines` for [errors]: one line per issue.
int? errorLinesOf(List<String> errors) => errors.isEmpty ? null : errors.length;

/// An input label for a required value: the name, then an `*` in `accent300` (not the error
/// color). Screen readers hear "name, required". Use as `InputDecoration.label`.
Widget requiredLabel(String name) => Semantics(
  label: '$name, required',
  excludeSemantics: true,
  child: Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Flexible(child: Text(name, overflow: TextOverflow.ellipsis)),
      const Text(' *', style: TextStyle(color: Nocturne.accent300)),
    ],
  ),
);

/// The one "* required" line a form with any marked input shows.
class RequiredLegend extends StatelessWidget {
  const RequiredLegend({super.key});

  @override
  Widget build(BuildContext context) => Text.rich(
    TextSpan(
      children: [
        const TextSpan(
          text: '*',
          style: TextStyle(color: Nocturne.accent300),
        ),
        TextSpan(
          text: ' required',
          style: TextStyle(color: Nocturne.muted(.55)),
        ),
      ],
    ),
    style: const TextStyle(fontSize: 12),
  );
}
