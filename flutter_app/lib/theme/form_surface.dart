import 'dart:math' as math;

import 'package:fi/theme/fi_icons.dart';
import 'package:fi/theme/form_errors.dart';
import 'package:fi/theme/nocturne.dart';
import 'package:fi/theme/nocturne_widgets.dart';
import 'package:fi/theme/side_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// At or above this screen width a form with an aside shows it as a pane beside the form.
const double formSurfaceTwoPaneBreakpoint = 820;

/// Longest a pinned aside (a phone or narrow dialog preview) may grow.
const double _pinnedAsideMaxHeight = 160;

/// How a [FormSurface] is presented, chosen once by [showFormSurface] when the route opens.
enum FormSurfaceMode {
  /// A bottom sheet on a phone (screen width below 720).
  sheet,

  /// A dialog; an aside is pinned below the body.
  dialog,

  /// A dialog wide enough (820 and up) to show an aside as a 280px pane beside the form.
  twoPane,
}

/// The mode for a screen of [width].
FormSurfaceMode formSurfaceModeFor(double width) => width < sideSheetBreakpoint
    ? FormSurfaceMode.sheet
    : width < formSurfaceTwoPaneBreakpoint
    ? FormSurfaceMode.dialog
    : FormSurfaceMode.twoPane;

/// Publishes the presentation [showFormSurface] chose, so the [FormSurface] inside lays out
/// for it and callers can adjust wording (for example a longer primary label on a phone).
class FormSurfaceScope extends InheritedWidget {
  const FormSurfaceScope({required this.mode, required super.child, super.key});

  final FormSurfaceMode mode;

  /// The enclosing scope's mode, or the mode for the current screen width outside one.
  static FormSurfaceMode modeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<FormSurfaceScope>()?.mode ??
      formSurfaceModeFor(MediaQuery.sizeOf(context).width);

  @override
  bool updateShouldNotify(FormSurfaceScope oldWidget) => mode != oldWidget.mode;
}

/// Opens a create/edit form: a bottom sheet on a phone, a dialog otherwise.
///
/// [builder] is called with the route's context and should return a [FormSurface], usually
/// inside the caller's own `StatefulWidget` or `StatefulBuilder`.
Future<T?> showFormSurface<T>(
  BuildContext context, {
  required WidgetBuilder builder,
}) {
  final mode = formSurfaceModeFor(MediaQuery.sizeOf(context).width);
  Widget scoped(BuildContext route) => FormSurfaceScope(
    mode: mode,
    child: Builder(builder: builder),
  );
  if (mode == FormSurfaceMode.sheet) {
    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: scoped,
    );
  }
  return showDialog<T>(context: context, builder: scoped);
}

/// A secondary form action such as "Remove": an icon button in the title row of a sheet, a
/// text button before Cancel in a dialog. [key] is applied in both modes.
class FormHeaderAction {
  const FormHeaderAction({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.tooltip,
    this.key,
  });

  final Key? key;
  final IconData icon;

  /// The text button label in a dialog.
  final String label;

  /// The icon button tooltip in a sheet; defaults to [label].
  final String? tooltip;
  final VoidCallback? onPressed;
}

/// One item of a [FormSurface]'s phone ⋮ menu, such as "Duplicate".
class FormMenuAction {
  const FormMenuAction({
    required this.label,
    required this.onPressed,
    this.icon,
    this.key,
  });

  final Key? key;
  final String label;
  final IconData? icon;
  final VoidCallback onPressed;
}

/// The layout of a create/edit form opened with [showFormSurface]: title and context, a
/// scrolling [body], an optional [aside] such as a live preview, a form-level [message] slot
/// above the footer, and Cancel beside the primary action.
class FormSurface extends StatelessWidget {
  const FormSurface({
    required this.title,
    required this.body,
    required this.primaryLabel,
    required this.onPrimary,
    this.contextLabel,
    this.message,
    this.errors = const [],
    this.showRequiredLegend = false,
    this.headerActions = const [],
    this.aside,
    this.pinnedAside,
    this.primaryKey,
    this.cancelLabel = 'Cancel',
    this.onCancel,
    this.width = 480,
    this.closeInHeader = false,
    this.menuActions = const [],
    this.leadingFooterAction,
    this.footerHint,
    this.fullWidthPrimaryOnPhone = false,
    this.submitOnCtrlEnter = false,
    this.summary,
    this.showContextInDialog = false,
    super.key,
  });

  final String title;

  /// A short line beside the title on a phone, such as "in Gym".
  final String? contextLabel;
  final Widget body;

  /// Shown directly above the footer in the error color, for messages no single input owns.
  final Widget? message;

  /// Form-level issue lines (see `FormIssues.form`), drawn in the [message] slot one per line
  /// after any [message].
  final List<String> errors;

  /// Adds the single "* required" legend under the title; set it when any input is marked.
  final bool showRequiredLegend;
  final List<FormHeaderAction> headerActions;

  /// A 280px pane beside the form on wide screens.
  final Widget? aside;

  /// What to pin between the body and the footer when [aside] has no room for a pane;
  /// defaults to [aside]. Capped at 160px and hidden on a phone while the keyboard is open.
  final Widget? pinnedAside;
  final String primaryLabel;
  final VoidCallback? onPrimary;
  final Key? primaryKey;
  final String cancelLabel;

  /// Defaults to closing the route.
  final VoidCallback? onCancel;

  /// Width of the dialog body.
  final double width;

  /// On a phone, ends the title row with a close ✕ (the record editor's only way to close
  /// besides dragging the sheet down).
  final bool closeInHeader;

  /// On a phone, items of one ⋮ menu at the end of the title row. Not shown in a dialog.
  final List<FormMenuAction> menuActions;

  /// In a dialog, a text button at the leading edge of the footer, apart from Cancel and the
  /// primary action (for example a destructive "Delete…"). Not shown on a phone.
  final FormHeaderAction? leadingFooterAction;

  /// In a dialog, a muted line at the leading edge of the footer, such as
  /// "* Required · Ctrl+Enter to save". A leading `*` is drawn in accent300.
  final String? footerHint;

  /// On a phone, the footer holds only the primary action, full width and 52px tall.
  final bool fullWidthPrimaryOnPhone;

  /// In a dialog, Ctrl+Enter runs [onPrimary].
  final bool submitOnCtrlEnter;

  /// Pinned above the footer, outside the scrolling body, for example a [FormErrorSummary].
  final Widget? summary;

  /// Shows [contextLabel] beside the title in a dialog too, not only on a phone.
  final bool showContextInDialog;

  @override
  Widget build(BuildContext context) {
    final mode = FormSurfaceScope.modeOf(context);
    return switch (mode) {
      FormSurfaceMode.sheet => _sheet(context),
      FormSurfaceMode.twoPane when aside != null => _twoPane(context),
      _ => _dialog(context),
    };
  }

  void _cancel(BuildContext context) =>
      onCancel != null ? onCancel!() : Navigator.pop(context);

  Widget? _message(BuildContext context, EdgeInsets padding) {
    if (message == null && errors.isEmpty && summary == null) return null;
    return Padding(
      padding: padding,
      child: DefaultTextStyle.merge(
        style: TextStyle(color: Theme.of(context).colorScheme.error),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 4,
          children: [
            ?summary,
            ?message,
            if (errors.isNotEmpty) FormErrorLines(errors),
          ],
        ),
      ),
    );
  }

  Widget? _menu() => menuActions.isEmpty
      ? null
      : PopupMenuButton<int>(
          key: const Key('form-menu'),
          tooltip: 'More',
          icon: const Icon(FiIcons.more, size: 20),
          onSelected: (index) => menuActions[index].onPressed(),
          itemBuilder: (_) => [
            for (final (index, action) in menuActions.indexed)
              PopupMenuItem<int>(
                key: action.key,
                value: index,
                child: Row(
                  children: [
                    if (action.icon case final icon?) ...[
                      Icon(icon, size: 18),
                      const SizedBox(width: 12),
                    ],
                    Text(action.label),
                  ],
                ),
              ),
          ],
        );

  Widget _hint(String hint) {
    final starred = hint.startsWith('*');
    return Text.rich(
      key: const Key('form-footer-hint'),
      TextSpan(
        children: [
          if (starred)
            const TextSpan(
              text: '*',
              style: TextStyle(color: Nocturne.accent300),
            ),
          TextSpan(text: starred ? hint.substring(1) : hint),
        ],
      ),
      style: TextStyle(fontSize: 12, color: Nocturne.muted(.55)),
    );
  }

  Widget? _legend(EdgeInsets padding) => showRequiredLegend
      ? Padding(
          key: const Key('required-legend'),
          padding: padding,
          child: const RequiredLegend(),
        )
      : null;

  Widget? _pinned(EdgeInsets padding) {
    final pinned = pinnedAside ?? aside;
    if (pinned == null) return null;
    return Padding(
      padding: padding,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: _pinnedAsideMaxHeight),
        child: ClipRect(child: pinned),
      ),
    );
  }

  Widget _sheet(BuildContext context) {
    final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;
    final theme = Theme.of(context);
    // Inputs take their phone height from the shared input tokens (`inputs.dart`).
    return BottomSheetInsets(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(
              18,
              0,
              headerActions.isEmpty && !closeInHeader && menuActions.isEmpty
                  ? 18
                  : 8,
              10,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Expanded(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleLarge,
                        ),
                      ),
                      if (contextLabel case final label?)
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 160),
                          child: Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: Nocturne.muted(.55),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                for (final action in headerActions)
                  IconButton(
                    key: action.key,
                    tooltip: action.tooltip ?? action.label,
                    onPressed: action.onPressed,
                    icon: Icon(action.icon),
                  ),
                ?_menu(),
                if (closeInHeader)
                  FiIconButton(
                    key: const Key('form-close'),
                    icon: FiIcons.close,
                    tooltip: 'Close',
                    onPressed: () => _cancel(context),
                  ),
              ],
            ),
          ),
          ?_legend(const EdgeInsets.fromLTRB(18, 0, 18, 4)),
          Flexible(
            child: SingleChildScrollView(
              // Room above the first field so its floating label is not clipped.
              padding: const EdgeInsets.fromLTRB(18, 8, 18, 8),
              child: body,
            ),
          ),
          if (!keyboardOpen) ?_pinned(const EdgeInsets.fromLTRB(18, 8, 18, 0)),
          ?_message(context, const EdgeInsets.fromLTRB(18, 10, 18, 0)),
          if (fullWidthPrimaryOnPhone)
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
              child: FilledButton(
                key: primaryKey,
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(52),
                ),
                onPressed: onPrimary,
                child: Text(primaryLabel),
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 48),
                      ),
                      onPressed: () => _cancel(context),
                      child: Text(cancelLabel),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 2,
                    child: FilledButton(
                      key: primaryKey,
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(0, 48),
                      ),
                      onPressed: onPrimary,
                      child: Text(primaryLabel),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _title(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(22, 22, 22, 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Flexible(
          child: Text(title, style: Theme.of(context).textTheme.titleLarge),
        ),
        if (contextLabel case final label? when showContextInDialog) ...[
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: Nocturne.muted(.55)),
            ),
          ),
        ],
      ],
    ),
  );

  Widget _footer(BuildContext context) {
    final action = leadingFooterAction;
    final hint = footerHint;
    if (action == null && hint == null) return _trailingFooter(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 14, 22, 20),
      child: Row(
        children: [
          if (action != null) ...[
            TextButton(
              key: action.key,
              onPressed: action.onPressed,
              child: Text(action.label),
            ),
            const SizedBox(width: 12),
          ],
          // The hint gives way (wrapping) before the buttons do.
          Expanded(child: hint == null ? const SizedBox() : _hint(hint)),
          const SizedBox(width: 8),
          TextButton(
            onPressed: () => _cancel(context),
            child: Text(cancelLabel),
          ),
          const SizedBox(width: 8),
          FilledButton(
            key: primaryKey,
            onPressed: onPrimary,
            child: Text(primaryLabel),
          ),
        ],
      ),
    );
  }

  Widget _trailingFooter(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(22, 14, 22, 20),
    child: Wrap(
      alignment: WrapAlignment.end,
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final action in headerActions)
          TextButton(
            key: action.key,
            onPressed: action.onPressed,
            child: Text(action.label),
          ),
        TextButton(onPressed: () => _cancel(context), child: Text(cancelLabel)),
        FilledButton(
          key: primaryKey,
          onPressed: onPrimary,
          child: Text(primaryLabel),
        ),
      ],
    ),
  );

  /// Ctrl+Enter runs the primary action when [submitOnCtrlEnter] is set.
  Widget _shortcuts(Widget child) => submitOnCtrlEnter && onPrimary != null
      ? CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.enter, control: true):
                onPrimary!,
          },
          child: child,
        )
      : child;

  Widget _dialog(BuildContext context) => _shortcuts(
    Dialog(
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: width + 44,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _title(context),
            ?_legend(const EdgeInsets.fromLTRB(22, 0, 22, 4)),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(22, 8, 22, 8),
                child: body,
              ),
            ),
            ?_pinned(const EdgeInsets.fromLTRB(22, 8, 22, 0)),
            ?_message(context, const EdgeInsets.fromLTRB(22, 10, 22, 0)),
            _footer(context),
          ],
        ),
      ),
    ),
  );

  Widget _twoPane(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    return Dialog(
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: 820,
        height: math.min(screen.height - 96, 900),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _title(context),
                  ?_legend(const EdgeInsets.fromLTRB(22, 0, 22, 4)),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(22, 8, 22, 8),
                      child: body,
                    ),
                  ),
                  ?_message(context, const EdgeInsets.fromLTRB(22, 10, 22, 0)),
                  _footer(context),
                ],
              ),
            ),
            Container(
              width: 280,
              color: Nocturne.bg,
              padding: const EdgeInsets.all(22),
              child: aside,
            ),
          ],
        ),
      ),
    );
  }
}
