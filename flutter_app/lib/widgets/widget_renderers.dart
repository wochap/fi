import 'package:fi/l10n/error_text.dart';
import 'package:fi/l10n/l10n.dart';
import 'package:fi/theme/fi_icons.dart';
import 'package:fi/exact_format.dart';
import 'package:fi/src/rust/api/models.dart';
import 'package:fi/theme/nocturne.dart';
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
  });

  final WidgetDefinitionDto definition;

  /// Null while the widget is still evaluating.
  final WidgetEvaluationDto? evaluation;

  /// Enum option id to label, so category axes stay readable while values stay exact.
  final Map<String, String> enumLabels;

  /// The query in words, shown under a headline number. Null when the query is not known here.
  final String? summary;

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
      child: const WidgetEmpty(reason: WidgetEmptyReason.noValue),
    );
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
    final unknownKeys =
        definition.configuration.body.kind == StructuredValueKindDto.map
        ? definition.configuration.body.entries
              .map((entry) => entry.key)
              .toList()
        : const <String>[];
    final l = context.l10n;
    return WidgetTile(
      title: definition.title.isEmpty
          ? l.widgetUntitledWidget
          : definition.title,
      // Long explanations scroll inside the tile rather than overflowing it.
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
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
            // The exact synchronized type stays visible so the user can tell what is missing.
            SelectableText(
              definition.widgetType,
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: Nocturne.monoFamily,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            Text(
              l.widgetVersionLine(
                '${definition.configuration.version}',
                l.widgetConfigKeys(unknownKeys.length),
              ),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            Text(
              l.widgetUnsupportedExplanation,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
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
              Icon(FiIcons.moreHorizontal, size: 16, color: Nocturne.muted(.6)),
            ],
          ),
          const SizedBox(height: 4),
          Expanded(child: child),
        ],
      ),
    );
  }
}

final class WidgetLoading extends StatelessWidget {
  const WidgetLoading({super.key});

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
        Text(
          context.l10n.commonLoading,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    ),
  );
}

/// Why a tile has nothing to draw.
enum WidgetEmptyReason { noData, noValue, noObservations, nothingToChart }

final class WidgetEmpty extends StatelessWidget {
  const WidgetEmpty({super.key, this.reason = WidgetEmptyReason.noData});

  final WidgetEmptyReason reason;

  @override
  Widget build(BuildContext context) => Center(
    child: Text(
      switch (reason) {
        WidgetEmptyReason.noData => context.l10n.widgetNoData,
        WidgetEmptyReason.noValue => context.l10n.widgetNoValue,
        WidgetEmptyReason.noObservations => context.l10n.widgetNoObservations,
        WidgetEmptyReason.nothingToChart => context.l10n.widgetNothingToChart,
      },
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
    this.detail,
  });

  final String title;
  final WidgetErrorKindDto kind;
  final String message;

  /// Rust's technical wording, shown small under [message].
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return WidgetTile(
      title: title,
      // Long explanations scroll inside the tile rather than overflowing it.
      child: SingleChildScrollView(
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
                    _headline(context.l10n),
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
            if (detail case final detail? when detail != message) ...[
              const SizedBox(height: 4),
              Text(
                detail,
                style: TextStyle(fontSize: 12, color: Nocturne.muted(.55)),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _headline(AppLocalizations l) => switch (kind) {
    WidgetErrorKindDto.unsupportedType => l.widgetUnsupported,
    WidgetErrorKindDto.unsupportedConfigurationVersion =>
      l.widgetHeadlineNewerConfig,
    WidgetErrorKindDto.invalidConfiguration => l.widgetHeadlineInvalidConfig,
    WidgetErrorKindDto.unknownQuery ||
    WidgetErrorKindDto.invalidQuery => l.widgetHeadlineQueryUnavailable,
    WidgetErrorKindDto.shapeMismatch => l.widgetHeadlineShapeMismatch,
    WidgetErrorKindDto.overflow => l.widgetHeadlineOverflow,
    WidgetErrorKindDto.queryFailed => l.widgetHeadlineQueryFailed,
    WidgetErrorKindDto.removed => l.widgetHeadlineRemoved,
  };

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
    detail: evaluation.errorKind == null ? null : evaluation.message,
  );
}
