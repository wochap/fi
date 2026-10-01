import 'dart:async';

import 'package:fi/theme/fi_icons.dart';
import 'package:fi/help_copy.dart';
import 'package:fi/l10n/l10n.dart';
import 'package:flutter/material.dart';

/// The one help affordance: a `?` beside a control that opens the registry copy for it.
///
/// It reads from [helpEntry] and never carries copy of its own, so the text for a concept stays
/// reviewable in one place.
final class HelpButton extends StatelessWidget {
  const HelpButton(this.id, {super.key});

  final HelpId id;

  @override
  Widget build(BuildContext context) {
    final entry = helpEntry(context.l10n, id);
    return IconButton(
      key: Key('help-${id.name}'),
      icon: const Icon(FiIcons.help, size: 18),
      tooltip: context.l10n.helpAboutTooltip(entry.title),
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
  final entry = helpEntry(context.l10n, id);
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
          child: Text(context.l10n.commonClose),
        ),
      ],
    ),
  );
}
