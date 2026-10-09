import 'package:fi/l10n/l10n.dart';
import 'package:fi/theme/fi_icons.dart';
import 'package:fi/theme/nocturne.dart';
import 'package:flutter/material.dart';

/// Below this screen width the toast spans the screen; at and above it, it is capped at 440px.
const double _wideScreen = 720;

/// Shows the outcome of an action (mocks collections-outcomes, collections-import-export): a
/// floating toast with a check for [success] or a warning for an abort. A success hides on its
/// own; an abort stays until the user presses Dismiss. A new outcome replaces the shown one.
void showOutcomeToast(
  BuildContext context,
  String message, {
  required bool success,
}) => showOutcomeToastOn(
  ScaffoldMessenger.of(context),
  context.l10n,
  MediaQuery.sizeOf(context).width,
  message,
  success: success,
);

/// [showOutcomeToast] for callers that captured the messenger before an `await`.
void showOutcomeToastOn(
  ScaffoldMessengerState messenger,
  AppLocalizations l,
  double screenWidth,
  String message, {
  required bool success,
  SnackBarAction? action,
}) {
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        key: Key(success ? 'outcome-success' : 'outcome-abort'),
        behavior: SnackBarBehavior.floating,
        width: screenWidth >= _wideScreen ? 440 : null,
        duration: success
            ? const Duration(milliseconds: 4000)
            : const Duration(days: 1),
        action: success
            ? action
            : SnackBarAction(label: l.outcomeDismiss, onPressed: () {}),
        content: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Builder(
              builder: (context) => Icon(
                success ? FiIcons.check : FiIcons.warning,
                key: Key(success ? 'outcome-check' : 'outcome-warning'),
                size: 18,
                color: success
                    ? context.nocturne.success
                    : context.nocturne.warning,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(child: Text(message)),
          ],
        ),
      ),
    );
}
