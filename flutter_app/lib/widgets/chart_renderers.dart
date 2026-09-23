import 'package:fi/exact_format.dart';
import 'package:fi/src/rust/api/models.dart';
import 'package:fi/theme/nocturne.dart';
import 'package:fi/widgets/widget_renderers.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

/// Every `fl_chart` mapping in the application lives in this file. Nothing above it sees a chart
/// package type, and nothing below the exact-value layer performs aggregation.
///
/// Axis labels are rendered here rather than by the chart package: the package picks "nice number"
/// ticks that need not coincide with any observation, and labelling those from a double would put
/// an inexact value on screen. Taking labels from real data points keeps them exact and unique.
const int _maxAxisLabels = 4;

/// Grid lines are the divider token, never a series color.
FlLine _gridLine(double _) =>
    const FlLine(color: Nocturne.divider, strokeWidth: 1, dashArray: [3, 4]);

final class _ChartPoint {
  const _ChartPoint({required this.x, required this.y});

  final ExactValue x;
  final ExactValue y;
}

/// Plotted geometry: coordinates for drawing plus the exact labels those coordinates came from.
final class _Plot {
  _Plot({required this.points, required this.indexedX});

  /// Data coordinates. When the x value is not numeric (text, enum, boolean) the coordinate is
  /// the row index and the exact label still comes from the source value.
  final List<_ChartPoint> points;
  final bool indexedX;

  List<FlSpot> get spots => [
    for (var i = 0; i < points.length; i++)
      FlSpot(xAt(i), points[i].y.coordinate),
  ];

  double xAt(int index) =>
      indexedX ? index.toDouble() : points[index].x.coordinate;

  List<double> get xCoordinates => [
    for (var i = 0; i < points.length; i++) xAt(i),
  ];

  List<String> get xLabels => [for (final point in points) point.x.label];

  List<double> get yCoordinates => [
    for (final point in points) point.y.coordinate,
  ];

  List<String> get yLabels => [for (final point in points) point.y.label];

  ({double min, double max}) get xRange => _range(xCoordinates);

  ({double min, double max}) get yRange => _range(yCoordinates);
}

({double min, double max}) _range(List<double> values) {
  if (values.isEmpty) return (min: 0, max: 1);
  var min = values.first;
  var max = values.first;
  for (final value in values) {
    if (value < min) min = value;
    if (value > max) max = value;
  }
  // A flat series still needs a non-degenerate axis.
  if (min == max) return (min: min - 0.5, max: max + 0.5);
  return (min: min, max: max);
}

/// Evenly spaced indices into a datum list, so labels are always real observations and never
/// repeat.
List<int> _labelIndices(int count, int limit) {
  if (count <= 0) return const [];
  if (count <= limit) return [for (var i = 0; i < count; i++) i];
  final step = (count - 1) / (limit - 1);
  final indices = <int>[];
  for (var k = 0; k < limit; k++) {
    final index = (k * step).round();
    if (indices.isEmpty || indices.last != index) indices.add(index);
  }
  return indices;
}

/// The exact labels drawn around a chart.
final class _AxisLabels {
  const _AxisLabels({required this.y, required this.x});

  /// Highest value first, lowest last, matching the vertical layout.
  final List<String> y;
  final List<String> x;
}

_AxisLabels _axisLabelsFor(_Plot plot) {
  final x = [
    for (final index in _labelIndices(plot.points.length, _maxAxisLabels))
      plot.xLabels[index],
  ];
  if (plot.points.isEmpty) return _AxisLabels(y: const [], x: x);
  var minIndex = 0;
  var maxIndex = 0;
  final values = plot.yCoordinates;
  for (var i = 1; i < values.length; i++) {
    if (values[i] < values[minIndex]) minIndex = i;
    if (values[i] > values[maxIndex]) maxIndex = i;
  }
  return _AxisLabels(
    y: minIndex == maxIndex
        ? [plot.yLabels[maxIndex]]
        : [plot.yLabels[maxIndex], plot.yLabels[minIndex]],
    x: x,
  );
}

/// Lays a chart out between exact axis labels. The chart package draws only the geometry.
final class _ChartFrame extends StatelessWidget {
  const _ChartFrame({required this.labels, required this.chart, this.yName});

  final _AxisLabels labels;
  final Widget chart;
  final String? yName;

  static const double _gutter = 64;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget axis(String text) => Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.labelSmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
    return Column(
      children: [
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: _gutter,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [for (final label in labels.y) axis(label)],
                ),
              ),
              const SizedBox(width: 6),
              Expanded(child: chart),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Padding(
          padding: const EdgeInsets.only(left: _gutter + 6),
          child: Row(
            children: [
              // Each label gets an equal bounded share and ellipsizes, so long date labels never
              // overflow a narrow Android tile.
              for (var i = 0; i < labels.x.length; i++)
                Expanded(
                  child: Align(
                    alignment: switch (labels.x.length) {
                      1 => Alignment.center,
                      _ when i == 0 => Alignment.centerLeft,
                      _ when i == labels.x.length - 1 => Alignment.centerRight,
                      _ => Alignment.center,
                    },
                    child: axis(labels.x[i]),
                  ),
                ),
            ],
          ),
        ),
        if (yName != null && yName!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              yName!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }
}

_Plot _plotFromSeries(QueryResultDto result, Map<String, String> enumLabels) {
  final points = [
    for (final point in result.points)
      _ChartPoint(
        x: exactFromTypedValue(point.x, enumLabels: enumLabels),
        y: exactFromTypedValue(point.y, enumLabels: enumLabels),
      ),
  ];
  final indexedX = points.isNotEmpty && !points.first.x.isNumeric;
  return _Plot(points: points, indexedX: indexedX);
}

_Plot _plotFromCategories(
  QueryResultDto result,
  Map<String, String> enumLabels,
) {
  final points = [
    for (final point in result.categoryPoints)
      _ChartPoint(
        x: exactFromTypedValue(point.category, enumLabels: enumLabels),
        y: exactFromTypedValue(point.value, enumLabels: enumLabels),
      ),
  ];
  return _Plot(points: points, indexedX: true);
}

/// The plot for a line or bar result, which may arrive grouped or as an ordered series.
_Plot _plotFromGroupedOrSeries(
  QueryResultDto result,
  Map<String, String> enumLabels,
) => result.categoryPoints.isEmpty
    ? _plotFromSeries(result, enumLabels)
    : _plotFromCategories(result, enumLabels);

/// Ordered time or numeric observations joined as a line, or grouped buckets drawn in the order
/// the query returned them. Nothing here reorders, resamples, or aggregates.
Widget renderLineChart(WidgetRenderContext context) {
  final evaluation = context.evaluation;
  final title = context.definition.title;
  if (evaluation == null) {
    return WidgetTile(title: title, child: const WidgetLoading());
  }
  if (!evaluation.ready) return WidgetFailure.from(context, evaluation);
  final result = evaluation.result;
  if (result == null ||
      (result.points.isEmpty && result.categoryPoints.isEmpty)) {
    return WidgetTile(
      title: title,
      child: const WidgetEmpty(message: 'No observations yet.'),
    );
  }
  final config = WidgetConfig(context.configuration);
  final plot = _plotFromGroupedOrSeries(result, context.enumLabels);
  final xRange = plot.xRange;
  final yRange = plot.yRange;
  return WidgetTile(
    title: context.definition.title,
    child: _ChartFrame(
      labels: _axisLabelsFor(plot),
      yName: config.textAt('y_axis_label'),
      chart: LineChart(
        LineChartData(
          minX: xRange.min,
          maxX: xRange.max,
          minY: yRange.min,
          maxY: yRange.max,
          lineBarsData: [
            LineChartBarData(
              spots: plot.spots,
              isCurved: false,
              barWidth: 2,
              color: Nocturne.accent,
              belowBarData: BarAreaData(
                show: true,
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Nocturne.accent.withValues(alpha: .18),
                    Nocturne.accent.withValues(alpha: 0),
                  ],
                ),
              ),
              dotData: FlDotData(
                show: config.booleanAt('show_points'),
                getDotPainter: (spot, percent, bar, index) =>
                    FlDotCirclePainter(
                      radius: 3,
                      color: Nocturne.accent,
                      strokeWidth: 2,
                      strokeColor: Nocturne.surface,
                    ),
              ),
            ),
          ],
          titlesData: const FlTitlesData(),
          gridData: const FlGridData(
            drawVerticalLine: false,
            getDrawingHorizontalLine: _gridLine,
          ),
          borderData: FlBorderData(show: false),
          lineTouchData: LineTouchData(enabled: false),
        ),
      ),
    ),
  );
}

/// Category totals or a bucketed ordered series, drawn as bars with exact formatted labels.
Widget renderBarChart(WidgetRenderContext context) {
  final evaluation = context.evaluation;
  final title = context.definition.title;
  if (evaluation == null) {
    return WidgetTile(title: title, child: const WidgetLoading());
  }
  if (!evaluation.ready) return WidgetFailure.from(context, evaluation);
  final result = evaluation.result;
  if (result == null ||
      (result.points.isEmpty && result.categoryPoints.isEmpty)) {
    return WidgetTile(
      title: title,
      child: const WidgetEmpty(message: 'Nothing to chart yet.'),
    );
  }
  final plot = _plotFromGroupedOrSeries(result, context.enumLabels);
  final config = WidgetConfig(context.configuration);
  final width = config.integerAt('bar_width');
  final yRange = plot.yRange;
  return WidgetTile(
    title: context.definition.title,
    child: _ChartFrame(
      labels: _axisLabelsFor(plot),
      yName: config.textAt('y_axis_label'),
      chart: BarChart(
        BarChartData(
          alignment: BarChartAlignment.spaceBetween,
          minY: yRange.min < 0 ? yRange.min : 0,
          maxY: yRange.max,
          barGroups: [
            for (var i = 0; i < plot.points.length; i++)
              BarChartGroupData(
                x: i,
                barRods: [
                  BarChartRodData(
                    toY: plot.points[i].y.coordinate,
                    width: width == null ? 8 : width.toDouble(),
                    color: Nocturne.accent,
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(Nocturne.radiusSm / 2),
                    ),
                  ),
                ],
              ),
          ],
          titlesData: const FlTitlesData(),
          gridData: const FlGridData(
            drawVerticalLine: false,
            getDrawingHorizontalLine: _gridLine,
          ),
          borderData: FlBorderData(show: false),
          barTouchData: BarTouchData(enabled: false),
        ),
      ),
    ),
  );
}

/// Individual ordered observations, one spot each. No implicit aggregation happens here: a
/// scatter plot over grouped data would misrepresent it, so the query decides the granularity.
Widget renderScatterPlot(WidgetRenderContext context) {
  final evaluation = context.evaluation;
  final title = context.definition.title;
  if (evaluation == null) {
    return WidgetTile(title: title, child: const WidgetLoading());
  }
  if (!evaluation.ready) return WidgetFailure.from(context, evaluation);
  final result = evaluation.result;
  if (result == null || result.points.isEmpty) {
    return WidgetTile(
      title: title,
      child: const WidgetEmpty(message: 'No observations yet.'),
    );
  }
  final plot = _plotFromSeries(result, context.enumLabels);
  final config = WidgetConfig(context.configuration);
  final radius = config.integerAt('point_radius');
  final xRange = plot.xRange;
  final yRange = plot.yRange;
  return WidgetTile(
    title: context.definition.title,
    child: _ChartFrame(
      labels: _axisLabelsFor(plot),
      yName: config.textAt('y_axis_label'),
      chart: ScatterChart(
        ScatterChartData(
          minX: xRange.min,
          maxX: xRange.max,
          minY: yRange.min,
          maxY: yRange.max,
          scatterSpots: [
            for (final spot in plot.spots)
              ScatterSpot(
                spot.x,
                spot.y,
                dotPainter: FlDotCirclePainter(
                  radius: radius == null ? 5 : radius.toDouble(),
                  color: Nocturne.accent.withValues(alpha: .85),
                  strokeWidth: 0,
                ),
              ),
          ],
          titlesData: const FlTitlesData(),
          gridData: const FlGridData(
            getDrawingHorizontalLine: _gridLine,
            getDrawingVerticalLine: _gridLine,
          ),
          borderData: FlBorderData(show: false),
          scatterTouchData: ScatterTouchData(enabled: false),
        ),
      ),
    ),
  );
}
