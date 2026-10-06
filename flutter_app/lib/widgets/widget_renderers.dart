import 'package:fi/l10n/error_text.dart';
import 'package:fi/l10n/l10n.dart';
import 'package:fi/theme/fi_icons.dart';
import 'package:fi/exact_format.dart';
import 'package:fi/src/rust/api/models.dart';
import 'package:fi/theme/action_sheet.dart';
import 'package:fi/theme/nocturne.dart';
import 'package:fi/theme/nocturne_widgets.dart';
import 'package:fi/widgets/chart_renderers.dart';
import 'package:flutter/material.dart';

/// Renders one widget from its definition and current evaluation.
typedef WidgetRenderer = Widget Function(WidgetRenderContext context);

/// Everything a renderer may read. Deliberately free of any chart-package type so the registry
/// stays independent of both persisted configuration classes and the drawing backend.
final class WidgetRenderContext {
  const WidgetRenderContext({
    required this.definition,
    required this.evaluation,
    this.enumLabels = const {},
    this.summary,
    this.onEdit,
  });

  final WidgetDefinitionDto definition;

  /// Null while the widget is still evaluating.
  final WidgetEvaluationDto? evaluation;

  /// Enum option id to label, so category axes stay readable while values stay exact.
  final Map<String, String> enumLabels;

  /// The query in words, shown under a headline number. Null when the query is not known here.
  final String? summary;

  /// Opens the widget editor; offered by a failed tile. Null where editing is not possible.
  final VoidCallback? onEdit;

  /// The decoded presentation body. Unknown keys stay present and are ignored.
  StructuredValueDto get configuration => definition.configuration.body;
}

/// Renderer lookup keyed by the open widget type string.
///
/// An unrecognized type is not an error: [build] falls back to [UnsupportedWidgetPlaceholder],
/// which keeps the definition inspectable and never rewrites it.
final class WidgetRendererRegistry {
  const WidgetRendererRegistry({Map<String, WidgetRenderer>? renderers})
    : _renderers = renderers ?? defaultRenderers;

  static const Map<String, WidgetRenderer> defaultRenderers = {
    'core.aggregate-number': renderAggregateNumber,
    'core.line-chart': renderLineChart,
    'core.bar-chart': renderBarChart,
    'core.scatter-plot': renderScatterPlot,
  };

  final Map<String, WidgetRenderer> _renderers;

  bool isSupported(String widgetType) => _renderers.containsKey(widgetType);

  WidgetRenderer? lookup(String widgetType) => _renderers[widgetType];

  /// Resolves and invokes the renderer, containing any construction failure inside this one tile.
  Widget build(WidgetRenderContext widget) {
    final renderer = lookup(widget.definition.widgetType);
    if (renderer == null) {
      return UnsupportedWidgetPlaceholder(definition: widget.definition);
    }
    try {
      return renderer(widget);
    } catch (error) {
      return Builder(
        builder: (context) => WidgetFailureCard(
          title: widget.definition.title,
          kind: WidgetErrorKindDto.invalidConfiguration,
          message: context.l10n.widgetCouldNotRender('$error'),
          onEdit: widget.onEdit,
        ),
      );
    }
  }
}

/// Reads typed values out of the generic structured configuration. Unknown keys are ignored, so
/// a configuration written by a newer build still renders here.
final class WidgetConfig {
  const WidgetConfig(this.body);

  final StructuredValueDto body;

  StructuredValueDto? _at(String key) {
    if (body.kind != StructuredValueKindDto.map) return null;
    for (final entry in body.entries) {
      if (entry.key == key) return entry.value;
    }
    return null;
  }

  bool booleanAt(String key, {bool fallback = false}) {
    final value = _at(key);
    if (value == null || value.kind != StructuredValueKindDto.boolean) {
      return fallback;
    }
    return value.booleanValue ?? fallback;
  }

  String? textAt(String key) {
    final value = _at(key);
    if (value == null || value.kind != StructuredValueKindDto.text) return null;
    return value.textValue;
  }

  int? integerAt(String key) {
    final value = _at(key);
    if (value == null || value.kind != StructuredValueKindDto.integer) {
      return null;
    }
    return value.integerValue;
  }
}

/// Renders a Scalar result exactly. Counts, sums, averages, minima, and maxima all arrive as a
/// typed value with its own scale, so no aggregation or rounding happens here.
Widget renderAggregateNumber(WidgetRenderContext context) {
  final evaluation = context.evaluation;
  final title = context.definition.title;
  if (evaluation == null) {
    return WidgetTile(
      title: title,
      child: WidgetLoading(widgetType: context.definition.widgetType),
    );
  }
  if (!evaluation.ready) return WidgetFailure.from(context, evaluation);
  final result = evaluation.result;
  final value = exactFromTypedValue(
    result?.value,
    enumLabels: context.enumLabels,
  );
  if (result?.value == null) {
    return WidgetTile(title: title, child: const WidgetEmpty());
  }
  final suffix = WidgetConfig(context.configuration).textAt('suffix');
  return WidgetTile(
    title: context.definition.title,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Builder(
              builder: (context) {
                final valueLabel = value.label(
                  context.l10n,
                  decimalSeparator: decimalSeparatorOf(context),
                );
                return Text(
                  suffix == null || suffix.isEmpty
                      ? valueLabel
                      : '$valueLabel $suffix',
                  maxLines: 1,
                  style: const TextStyle(
                    fontSize: 40,
                    fontWeight: FontWeight.w500,
                    letterSpacing: -.8,
                    height: 1.1,
                    fontFeatures: Nocturne.tabular,
                  ),
                );
              },
            ),
          ),
        ),
        if (context.summary case final summary?)
          Text(
            summary,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, color: Nocturne.muted(.5)),
          ),
      ],
    ),
  );
}

/// Placeholder for a widget type this build cannot render. It shows the preserved type and title
/// and offers no action that could rewrite the opaque configuration.
final class UnsupportedWidgetPlaceholder extends StatelessWidget {
  const UnsupportedWidgetPlaceholder({super.key, required this.definition});

  final WidgetDefinitionDto definition;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = context.l10n;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return WidgetTile(
      title: definition.title.isEmpty
          ? l.widgetUntitledWidget
          : definition.title,
      // Long explanations scroll inside the tile rather than overflowing it.
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(
                  FiIcons.widget,
                  size: 18,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    l.widgetUnsupported,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(l.widgetUnsupportedExplanation, style: muted),
            const SizedBox(height: 4),
            // The exact synchronized type stays visible so the user can tell what is missing.
            SelectableText(
              definition.widgetType,
              style: muted?.copyWith(
                fontSize: 11,
                fontFamily: Nocturne.monoFamily,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

final class WidgetTile extends StatelessWidget {
  const WidgetTile({super.key, required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // The kicker keeps the title's own case so it reads as the name it was given.
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11,
                    letterSpacing: 1.1,
                    color: Nocturne.accent,
                    height: 1.4,
                  ),
                ),
              ),
              if (WidgetTileActions.maybeOf(context) case final actions?)
                _TileMenu(title: title, actions: actions),
            ],
          ),
          const SizedBox(height: 4),
          Expanded(child: child),
        ],
      ),
    );
  }
}

/// The ⋮ actions of one dashboard tile, provided by the dashboard around the tile. A tile without
/// them (the editor preview, reorder mode) shows no menu.
final class WidgetTileActions extends InheritedWidget {
  const WidgetTileActions({
    super.key,
    required this.onEdit,
    required this.onReorder,
    required this.onRemove,
    required super.child,
  });

  final VoidCallback onEdit;

  /// Null while the dashboard holds fewer than two widgets.
  final VoidCallback? onReorder;
  final VoidCallback onRemove;

  static WidgetTileActions? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<WidgetTileActions>();

  @override
  bool updateShouldNotify(WidgetTileActions oldWidget) =>
      onEdit != oldWidget.onEdit ||
      onReorder != oldWidget.onReorder ||
      onRemove != oldWidget.onRemove;
}

enum _TileAction { edit, reorder, remove }

/// The tile's ⋮ button: a menu anchored to it on a wide screen, an action sheet headed by the
/// widget title on a phone.
final class _TileMenu extends StatelessWidget {
  const _TileMenu({required this.title, required this.actions});

  final String title;
  final WidgetTileActions actions;

  void _run(_TileAction action) => switch (action) {
    _TileAction.edit => actions.onEdit(),
    _TileAction.reorder => actions.onReorder?.call(),
    _TileAction.remove => actions.onRemove(),
  };

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    if (Nocturne.isPhone(context)) {
      return FiIconButton(
        key: const Key('widget-menu'),
        icon: FiIcons.more,
        size: 16,
        tooltip: l.widgetMenuTooltip,
        color: Nocturne.muted(.6),
        onPressed: () async {
          final chosen = await showActionSheet<_TileAction>(
            context,
            icon: FiIcons.widget,
            title: title,
            groups: [
              ActionSheetGroup([
                ActionSheetItem(
                  value: _TileAction.edit,
                  label: l.widgetEdit,
                  icon: FiIcons.edit,
                ),
                if (actions.onReorder != null)
                  ActionSheetItem(
                    value: _TileAction.reorder,
                    label: l.widgetReorder,
                    icon: FiIcons.reorder,
                  ),
              ]),
              ActionSheetGroup([
                ActionSheetItem(
                  value: _TileAction.remove,
                  label: l.widgetMenuRemove,
                  icon: FiIcons.delete,
                ),
              ]),
            ],
          );
          if (chosen != null) _run(chosen);
        },
      );
    }
    return PopupMenuButton<_TileAction>(
      key: const Key('widget-menu'),
      tooltip: l.widgetMenuTooltip,
      padding: EdgeInsets.zero,
      iconSize: 16,
      constraints: const BoxConstraints(minWidth: 180),
      style: const ButtonStyle(
        minimumSize: WidgetStatePropertyAll(Size(28, 28)),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      icon: Icon(FiIcons.more, size: 16, color: Nocturne.muted(.6)),
      onSelected: _run,
      itemBuilder: (context) => [
        PopupMenuItem(
          key: const Key('widget-menu-edit'),
          value: _TileAction.edit,
          child: Text(l.widgetEdit),
        ),
        PopupMenuItem(
          key: const Key('widget-menu-reorder'),
          value: _TileAction.reorder,
          enabled: actions.onReorder != null,
          child: Text(l.widgetReorder),
        ),
        PopupMenuItem(
          key: const Key('widget-menu-remove'),
          value: _TileAction.remove,
          child: Text(l.widgetMenuRemove),
        ),
      ],
    );
  }
}

/// A quiet skeleton in the shape of [widgetType]: a number bar, a line band, three bars, or a
/// dot cloud. No spinner and no text, so a loading dashboard stays calm.
final class WidgetLoading extends StatelessWidget {
  const WidgetLoading({super.key, required this.widgetType});

  final String widgetType;

  @override
  Widget build(BuildContext context) {
    final color = Nocturne.muted(.08);
    Widget block(double width, double height) => Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(Nocturne.radiusSm / 2),
      ),
    );
    return Padding(
      key: const Key('widget-loading'),
      padding: const EdgeInsets.only(top: 6),
      child: switch (widgetType) {
        'core.aggregate-number' => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [block(96, 30), const SizedBox(height: 10), block(140, 8)],
        ),
        'core.bar-chart' => Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          spacing: 10,
          children: [
            for (final share in const [.45, .8, .6])
              Expanded(
                child: FractionallySizedBox(
                  heightFactor: share,
                  alignment: Alignment.bottomCenter,
                  child: block(double.infinity, double.infinity),
                ),
              ),
          ],
        ),
        _ => CustomPaint(
          size: Size.infinite,
          painter: _SkeletonPainter(
            color: color,
            dots: widgetType == 'core.scatter-plot',
          ),
        ),
      },
    );
  }
}

/// A polyline band for a line chart, or a scattered dot cloud.
final class _SkeletonPainter extends CustomPainter {
  const _SkeletonPainter({required this.color, required this.dots});

  final Color color;
  final bool dots;

  static const _points = [
    (.05, .7),
    (.2, .45),
    (.35, .6),
    (.5, .3),
    (.65, .5),
    (.8, .25),
    (.95, .4),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    if (dots) {
      for (final (x, y) in _points) {
        canvas.drawCircle(Offset(x * size.width, y * size.height), 5, paint);
        canvas.drawCircle(
          Offset((x + .04) * size.width, (y + .25) * size.height),
          4,
          paint,
        );
      }
      return;
    }
    paint
      ..style = PaintingStyle.stroke
      ..strokeWidth = 8
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;
    final path = Path();
    for (final (index, (x, y)) in _points.indexed) {
      final point = Offset(x * size.width, y * size.height);
      index == 0
          ? path.moveTo(point.dx, point.dy)
          : path.lineTo(point.dx, point.dy);
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_SkeletonPainter oldDelegate) =>
      color != oldDelegate.color || dots != oldDelegate.dots;
}

/// A tile with nothing to draw. Every widget type reads the same (mock widget-states).
final class WidgetEmpty extends StatelessWidget {
  const WidgetEmpty({super.key});

  @override
  Widget build(BuildContext context) => Center(
    child: Text(
      context.l10n.widgetNoRecordsMatch,
      textAlign: TextAlign.center,
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  );
}

/// A typed per-widget failure. It never propagates: sibling widgets and the record list keep
/// working. Rust's technical wording stays out of the tile; the editor shows it.
final class WidgetFailureCard extends StatelessWidget {
  const WidgetFailureCard({
    super.key,
    required this.title,
    required this.kind,
    required this.message,
    this.onEdit,
  });

  final String title;
  final WidgetErrorKindDto kind;
  final String message;

  /// Opens the widget editor. Null hides the Edit widget button.
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return WidgetTile(
      title: title,
      // Long explanations scroll inside the tile rather than overflowing it.
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(_icon, size: 18, color: theme.colorScheme.error),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    message,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
            if (onEdit case final onEdit?) ...[
              const SizedBox(height: 8),
              OutlinedButton(
                key: const Key('widget-failure-edit'),
                onPressed: onEdit,
                child: Text(context.l10n.widgetEdit),
              ),
            ],
          ],
        ),
      ),
    );
  }

  IconData get _icon => switch (kind) {
    WidgetErrorKindDto.unsupportedType => FiIcons.widget,
    WidgetErrorKindDto.overflow => FiIcons.number,
    WidgetErrorKindDto.shapeMismatch => FiIcons.rule,
    _ => FiIcons.error,
  };
}

final class WidgetFailure extends StatelessWidget {
  const WidgetFailure({
    super.key,
    required this.render,
    required this.evaluation,
  });

  final WidgetRenderContext render;
  final WidgetEvaluationDto evaluation;

  factory WidgetFailure.from(
    WidgetRenderContext render,
    WidgetEvaluationDto evaluation,
  ) => WidgetFailure(render: render, evaluation: evaluation);

  @override
  Widget build(BuildContext context) => WidgetFailureCard(
    title: render.definition.title,
    kind: evaluation.errorKind ?? WidgetErrorKindDto.queryFailed,
    message: switch (evaluation.errorKind) {
      final kind? => widgetErrorText(context.l10n, kind),
      null => evaluation.message ?? context.l10n.widgetNotEvaluated,
    },
    onEdit: render.onEdit,
  );
}
