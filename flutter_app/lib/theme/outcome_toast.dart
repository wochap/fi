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

/// [showOutcomeToast] for callers that captured the messenger before an `await`. A
/// [secondaryAction] (Show) sits beside the message as a ghost button, before [action]. With an
/// [actionIcon], [action] renders as an icon button inside the toast.
void showOutcomeToastOn(
  ScaffoldMessengerState messenger,
  AppLocalizations l,
  double screenWidth,
  String message, {
  required bool success,
  SnackBarAction? action,
  SnackBarAction? secondaryAction,
  IconData? actionIcon,
}) {
  final iconAction = success && actionIcon != null ? action : null;
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
            ? (iconAction == null ? action : null)
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
            if (secondaryAction != null)
              Builder(
                builder: (context) => TextButton(
                  key: secondaryAction.key,
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, 24),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: () {
                    messenger.hideCurrentSnackBar();
                    secondaryAction.onPressed();
                  },
                  child: Text(secondaryAction.label),
                ),
              ),
            if (iconAction != null)
              ToastIconAction(
                key: iconAction.key,
                icon: actionIcon!,
                label: iconAction.label,
                onPressed: () {
                  messenger.hideCurrentSnackBar();
                  iconAction.onPressed();
                },
              ),
          ],
        ),
      ),
    );
}

/// A toast action with a leading icon and an optional keyboard [hint]; it never shrinks.
class ToastIconAction extends StatelessWidget {
  const ToastIconAction({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.hint,
  });

  final IconData icon;
  final String label;
  final String? hint;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).snackBarTheme.actionTextColor;
    return TextButton(
      style: TextButton.styleFrom(
        foregroundColor: accent,
        minimumSize: const Size(0, 24),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
      ),
      onPressed: onPressed,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16),
          const SizedBox(width: 6),
          Text(label),
          if (hint case final hint?) ...[
            const SizedBox(width: 8),
            Text(
              hint,
              style: TextStyle(
                fontSize: 11,
                color: accent?.withValues(alpha: .7),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
