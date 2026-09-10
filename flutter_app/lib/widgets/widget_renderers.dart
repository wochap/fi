import 'package:fi/exact_format.dart';
import 'package:fi/src/rust/api/models.dart';
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
  });

  final WidgetDefinitionDto definition;

  /// Null while the widget is still evaluating.
  final WidgetEvaluationDto? evaluation;

  /// Enum option id to label, so category axes stay readable while values stay exact.
  final Map<String, String> enumLabels;

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
      return WidgetFailureCard(
        title: widget.definition.title,
        kind: WidgetErrorKindDto.invalidConfiguration,
        message: 'This widget could not be rendered: $error',
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
    return WidgetTile(title: title, child: const WidgetLoading());
  }
  if (!evaluation.ready) return WidgetFailure.from(context, evaluation);
  final result = evaluation.result;
  final value = exactFromTypedValue(
    result?.value,
    enumLabels: context.enumLabels,
  );
  if (result?.value == null) {
    return WidgetTile(
      title: title,
      child: const WidgetEmpty(message: 'No value yet.'),
    );
  }
  final suffix = WidgetConfig(context.configuration).textAt('suffix');
  return WidgetTile(
    title: context.definition.title,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          suffix == null || suffix.isEmpty
              ? value.label
              : '${value.label} $suffix',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.w600,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
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
    final unknownKeys =
        definition.configuration.body.kind == StructuredValueKindDto.map
        ? definition.configuration.body.entries
              .map((entry) => entry.key)
              .toList()
        : const <String>[];
    return WidgetTile(
      title: definition.title.isEmpty ? 'Untitled widget' : definition.title,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(
                Icons.widgets_outlined,
                size: 18,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Unsupported widget',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          // The exact synchronized type stays visible so the user can tell what is missing.
          SelectableText(
            definition.widgetType,
            style: theme.textTheme.bodySmall?.copyWith(
              fontFamily: 'monospace',
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          Text(
            'Version ${definition.configuration.version} · '
            '${unknownKeys.isEmpty ? 'no configuration keys' : '${unknownKeys.length} configuration keys'}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          Text(
            'This widget was created by another device or a newer version. '
            'Its configuration is preserved and can be renamed, reordered, or removed.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
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
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title.isNotEmpty)
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall,
            ),
          const SizedBox(height: 8),
          Expanded(child: child),
        ],
      ),
    );
  }
}

final class WidgetLoading extends StatelessWidget {
  const WidgetLoading({super.key, this.message = 'Loading…'});

  final String message;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        const SizedBox(height: 8),
        Text(message, style: Theme.of(context).textTheme.bodySmall),
      ],
    ),
  );
}

final class WidgetEmpty extends StatelessWidget {
  const WidgetEmpty({super.key, this.message = 'No data yet.'});

  final String message;

  @override
  Widget build(BuildContext context) => Center(
    child: Text(
      message,
      textAlign: TextAlign.center,
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  );
}

/// A typed per-widget failure. It never propagates: sibling widgets and the record list keep
/// working.
final class WidgetFailureCard extends StatelessWidget {
  const WidgetFailureCard({
    super.key,
    required this.title,
    required this.kind,
    required this.message,
  });

  final String title;
  final WidgetErrorKindDto kind;
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return WidgetTile(
      title: title,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(_icon, size: 18, color: theme.colorScheme.error),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _headline,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            message,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  String get _headline => switch (kind) {
    WidgetErrorKindDto.unsupportedType => 'Unsupported widget',
    WidgetErrorKindDto.unsupportedConfigurationVersion =>
      'Newer configuration version',
    WidgetErrorKindDto.invalidConfiguration => 'Invalid configuration',
    WidgetErrorKindDto.unknownQuery ||
    WidgetErrorKindDto.invalidQuery => 'Query unavailable',
    WidgetErrorKindDto.shapeMismatch => 'Query result does not fit',
    WidgetErrorKindDto.overflow => 'Value out of range',
    WidgetErrorKindDto.queryFailed => 'Query failed',
    WidgetErrorKindDto.removed => 'Widget removed',
  };

  IconData get _icon => switch (kind) {
    WidgetErrorKindDto.unsupportedType => Icons.widgets_outlined,
    WidgetErrorKindDto.overflow => Icons.numbers_outlined,
    WidgetErrorKindDto.shapeMismatch => Icons.rule_outlined,
    _ => Icons.error_outline,
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
    message: evaluation.message ?? 'This widget could not be evaluated.',
  );
}
