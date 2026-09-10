import 'package:fi/src/rust/api/models.dart';
import 'package:fi/widgets/widget_renderers.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _registry = WidgetRendererRegistry();

Widget _throwingRenderer(WidgetRenderContext context) =>
    throw StateError('renderer exploded');

const _failingRegistry = WidgetRendererRegistry(
  renderers: {'core.line-chart': _throwingRenderer},
);

StructuredValueDto _map(Map<String, StructuredValueDto> entries) =>
    StructuredValueDto(
      kind: StructuredValueKindDto.map,
      items: const [],
      entries: [
        for (final entry in entries.entries)
          StructuredEntryDto(key: entry.key, value: entry.value),
      ],
    );

StructuredValueDto _text(String value) => StructuredValueDto(
  kind: StructuredValueKindDto.text,
  textValue: value,
  items: const [],
  entries: const [],
);

StructuredValueDto _integer(int value) => StructuredValueDto(
  kind: StructuredValueKindDto.integer,
  integerValue: value,
  items: const [],
  entries: const [],
);

StructuredValueDto _boolean(bool value) => StructuredValueDto(
  kind: StructuredValueKindDto.boolean,
  booleanValue: value,
  items: const [],
  entries: const [],
);

WidgetDefinitionDto definition({
  String id = 'widget-1',
  String type = 'core.aggregate-number',
  String title = 'Balance',
  StructuredValueDto? configuration,
  int version = 1,
  WidgetSizeDto size = WidgetSizeDto.medium,
}) => WidgetDefinitionDto(
  id: id,
  collectionId: 'collection-1',
  widgetType: type,
  queryId: 'query-1',
  title: title,
  configuration: WidgetConfigurationDto(
    version: version,
    body: configuration ?? _map(const {}),
  ),
  layout: WidgetLayoutDto(version: 1, size: size, hints: _map(const {})),
  order: 0,
  deleted: false,
);

TypedValueDto decimal(int representation, int scale) => TypedValueDto(
  valueType: ValueTypeDto(kind: ValueTypeKindDto.fixedDecimal, scale: scale),
  integerValue: representation,
);

TypedValueDto integer(int value) => TypedValueDto(
  valueType: const ValueTypeDto(kind: ValueTypeKindDto.integer),
  integerValue: value,
);

TypedValueDto dateTime(int epochMs) => TypedValueDto(
  valueType: const ValueTypeDto(kind: ValueTypeKindDto.dateTime),
  integerValue: epochMs,
);

TypedValueDto enumValue(String optionId) => TypedValueDto(
  valueType: const ValueTypeDto(kind: ValueTypeKindDto.enum_),
  textValue: optionId,
);

QueryResultDto scalar(TypedValueDto value) => QueryResultDto(
  kind: QueryResultKindDto.scalar,
  value: value,
  valueType: value.valueType,
  points: const [],
  categoryPoints: const [],
  records: const [],
);

QueryResultDto series(List<(TypedValueDto, TypedValueDto)> points) =>
    QueryResultDto(
      kind: QueryResultKindDto.series,
      points: [
        for (final point in points) SeriesPointDto(x: point.$1, y: point.$2),
      ],
      categoryPoints: const [],
      xType: points.isEmpty ? null : points.first.$1.valueType,
      yType: points.isEmpty ? null : points.first.$2.valueType,
      records: const [],
    );

QueryResultDto categories(List<(TypedValueDto, TypedValueDto)> points) =>
    QueryResultDto(
      kind: QueryResultKindDto.categorySeries,
      points: const [],
      categoryPoints: [
        for (final point in points)
          CategoryPointDto(category: point.$1, value: point.$2),
      ],
      categoryType: points.isEmpty ? null : points.first.$1.valueType,
      valueType: points.isEmpty ? null : points.first.$2.valueType,
      records: const [],
    );

WidgetEvaluationDto ready(WidgetDefinitionDto widget, QueryResultDto result) =>
    WidgetEvaluationDto(
      widgetId: widget.id,
      widgetType: widget.widgetType,
      ready: true,
      result: result,
    );

WidgetEvaluationDto failed(
  WidgetDefinitionDto widget,
  WidgetErrorKindDto kind,
  String message,
) => WidgetEvaluationDto(
  widgetId: widget.id,
  widgetType: widget.widgetType,
  ready: false,
  errorKind: kind,
  message: message,
);

WidgetRenderContext renderContext(
  WidgetDefinitionDto widget, {
  WidgetEvaluationDto? evaluation,
  Map<String, String> enumLabels = const {},
}) => WidgetRenderContext(
  definition: widget,
  evaluation: evaluation,
  enumLabels: enumLabels,
);

/// Charts need bounded space and a moment for their implicit animation.
Future<void> pumpChart(
  WidgetTester tester,
  Widget child, {
  Size size = const Size(420, 320),
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(width: size.width, height: size.height, child: child),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 250));
}

void main() {
  group('registry lookup', () {
    test('resolves built-in types by open string and rejects nothing', () {
      for (final type in [
        'core.aggregate-number',
        'core.line-chart',
        'core.bar-chart',
        'core.scatter-plot',
      ]) {
        expect(_registry.isSupported(type), isTrue, reason: type);
        expect(_registry.lookup(type), isNotNull, reason: type);
      }
    });

    test('an unrecognized type is unsupported rather than an error', () {
      expect(_registry.isSupported('com.example.calendar-heatmap'), isFalse);
      expect(_registry.lookup('com.example.calendar-heatmap'), isNull);
    });

    testWidgets('an unsupported type renders the placeholder', (tester) async {
      final widget = definition(
        type: 'com.example.calendar-heatmap',
        title: 'Calendar heatmap',
        configuration: _map({
          'palette': _text('heat'),
          'futureFlag': _boolean(true),
          'futureScale': _integer(3),
        }),
        version: 7,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 400,
              height: 300,
              child: _registry.build(renderContext(widget)),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(UnsupportedWidgetPlaceholder), findsOneWidget);
      // The preserved type and configuration stay visible; nothing offers to rewrite them.
      expect(find.text('com.example.calendar-heatmap'), findsOneWidget);
      expect(find.text('Unsupported widget'), findsWidgets);
      expect(find.textContaining('Version 7'), findsOneWidget);
      expect(find.textContaining('3 configuration keys'), findsOneWidget);
      expect(find.text('Calendar heatmap'), findsOneWidget);
    });

    testWidgets('a throwing renderer is contained inside its own tile', (
      tester,
    ) async {
      final widget = definition(type: 'core.line-chart', title: 'Broken');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 400,
              height: 300,
              child: _failingRegistry.build(renderContext(widget)),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(WidgetFailureCard), findsOneWidget);
      expect(find.textContaining('could not be rendered'), findsOneWidget);
      // The rest of the tree still builds.
      expect(tester.takeException(), isNull);
    });
  });

  group('AggregateNumber exact formatting', () {
    testWidgets('Balance shows 2576.50 from representation 257650 at scale 2', (
      tester,
    ) async {
      final widget = definition(title: 'Balance');
      await pumpChart(
        tester,
        _registry.build(
          renderContext(
            widget,
            evaluation: ready(widget, scalar(decimal(257650, 2))),
          ),
        ),
        size: const Size(300, 160),
      );
      expect(find.text('Balance'), findsOneWidget);
      expect(find.text('2576.50'), findsOneWidget);
      expect(find.text('2576.5'), findsNothing);
    });

    testWidgets('negative scaled values keep their sign and scale', (
      tester,
    ) async {
      final widget = definition(title: 'Overdrawn');
      await pumpChart(
        tester,
        _registry.build(
          renderContext(
            widget,
            evaluation: ready(widget, scalar(decimal(-2350, 2))),
          ),
        ),
        size: const Size(300, 160),
      );
      expect(find.text('-23.50'), findsOneWidget);
    });

    testWidgets('a large count prints every digit exactly', (tester) async {
      // 2^53 + 1 cannot survive a double round trip.
      final widget = definition(title: 'Events');
      await pumpChart(
        tester,
        _registry.build(
          renderContext(
            widget,
            evaluation: ready(widget, scalar(integer(9007199254740993))),
          ),
        ),
        size: const Size(300, 160),
      );
      expect(find.text('9007199254740993'), findsOneWidget);
      expect(find.text('9007199254740992'), findsNothing);
    });

    testWidgets('average intensity renders with an optional unit suffix', (
      tester,
    ) async {
      final widget = definition(
        title: 'Average Intensity',
        configuration: _map({'suffix': _text('pts')}),
      );
      await pumpChart(
        tester,
        _registry.build(
          renderContext(
            widget,
            evaluation: ready(widget, scalar(decimal(733, 2))),
          ),
        ),
        size: const Size(300, 160),
      );
      expect(find.text('Average Intensity'), findsOneWidget);
      expect(find.text('7.33 pts'), findsOneWidget);
    });

    testWidgets('a null aggregate shows the empty state, not zero', (
      tester,
    ) async {
      final widget = definition(title: 'Nothing');
      final result = QueryResultDto(
        kind: QueryResultKindDto.scalar,
        points: const [],
        categoryPoints: const [],
        records: const [],
      );
      await pumpChart(
        tester,
        _registry.build(
          renderContext(widget, evaluation: ready(widget, result)),
        ),
        size: const Size(300, 160),
      );
      expect(find.byType(WidgetEmpty), findsOneWidget);
      expect(find.text('0'), findsNothing);
    });

    testWidgets('an unknown configuration key is ignored, not rejected', (
      tester,
    ) async {
      final widget = definition(
        title: 'Forward compatible',
        configuration: _map({
          'suffix': _text('EUR'),
          'sparkline': _boolean(true),
          'palette': _map({'shader': _text('heat')}),
        }),
      );
      await pumpChart(
        tester,
        _registry.build(
          renderContext(
            widget,
            evaluation: ready(widget, scalar(decimal(257650, 2))),
          ),
        ),
        size: const Size(300, 160),
      );
      expect(find.text('2576.50 EUR'), findsOneWidget);
    });

    testWidgets('a malformed configuration degrades instead of crashing', (
      tester,
    ) async {
      // Wrong types for known keys must not throw: the renderer falls back to defaults and the
      // exact value is still shown.
      final widget = definition(
        title: 'Malformed',
        configuration: _map({
          'suffix': _integer(5),
          'show_points': _text('yes'),
          'bar_width': _text('wide'),
          'point_radius': _map({}),
        }),
      );
      await pumpChart(
        tester,
        _registry.build(
          renderContext(
            widget,
            evaluation: ready(widget, scalar(decimal(257650, 2))),
          ),
        ),
        size: const Size(300, 160),
      );
      expect(find.text('2576.50'), findsOneWidget);
      expect(tester.takeException(), isNull);

      for (final type in ['core.line-chart', 'core.bar-chart']) {
        final chart = definition(
          type: type,
          title: 'Malformed chart',
          configuration: _map({
            'show_points': _text('yes'),
            'bar_width': _text('wide'),
            'y_axis_label': _integer(3),
          }),
        );
        await pumpChart(
          tester,
          _registry.build(
            renderContext(
              chart,
              evaluation: ready(
                chart,
                series([(dateTime(1700000000000), integer(3))]),
              ),
            ),
          ),
        );
        expect(tester.takeException(), isNull, reason: type);
        // Defaults apply rather than a crash: no dots, default bar width, no axis name.
        if (type == 'core.bar-chart') {
          final bar = tester.widget<BarChart>(find.byType(BarChart));
          expect(bar.data.barGroups.single.barRods.single.width, 8);
        } else {
          final line = tester.widget<LineChart>(find.byType(LineChart));
          expect(line.data.lineBarsData.single.dotData.show, isFalse);
        }
      }
    });
  });

  group('chart renderers', () {
    testWidgets('LineChart plots a headache history in the returned order', (
      tester,
    ) async {
      final widget = definition(
        type: 'core.line-chart',
        title: 'Intensity history',
        configuration: _map({'show_points': _boolean(true)}),
      );
      final result = series([
        (dateTime(1700000000000), integer(3)),
        (dateTime(1700086400000), integer(7)),
        (dateTime(1700172800000), integer(-2)),
      ]);
      await pumpChart(
        tester,
        _registry.build(
          renderContext(widget, evaluation: ready(widget, result)),
        ),
      );
      expect(find.text('Intensity history'), findsOneWidget);
      final chart = tester.widget<LineChart>(find.byType(LineChart));
      final spots = chart.data.lineBarsData.single.spots;
      expect(spots, hasLength(3));
      // Order is preserved and negative values are plotted below the baseline.
      expect(spots[0].y, 3);
      expect(spots[1].y, 7);
      expect(spots[2].y, -2);
      expect(spots[0].x, lessThan(spots[1].x));
      expect(chart.data.lineBarsData.single.dotData.show, isTrue);
    });

    testWidgets('LineChart renders grouped monthly buckets with exact labels', (
      tester,
    ) async {
      final widget = definition(type: 'core.line-chart', title: 'Monthly');
      final result = categories([
        (dateTime(1704067200000), decimal(257650, 2)),
        (dateTime(1706745600000), decimal(-2350, 2)),
      ]);
      await pumpChart(
        tester,
        _registry.build(
          renderContext(widget, evaluation: ready(widget, result)),
        ),
      );
      final chart = tester.widget<LineChart>(find.byType(LineChart));
      expect(chart.data.lineBarsData.single.spots, hasLength(2));
      // Axis labels come from the exact values, never from a double round trip.
      expect(find.text('2576.50'), findsOneWidget);
      expect(find.text('-23.50'), findsOneWidget);
    });

    testWidgets('BarChart shows one bar per returned category with labels', (
      tester,
    ) async {
      final widget = definition(
        type: 'core.bar-chart',
        title: 'Headache frequency',
        configuration: _map({'bar_width': _integer(14)}),
      );
      final result = categories([
        (enumValue('option-migraine'), integer(4)),
        (enumValue('option-tension'), integer(9)),
      ]);
      await pumpChart(
        tester,
        _registry.build(
          renderContext(
            widget,
            evaluation: ready(widget, result),
            enumLabels: const {
              'option-migraine': 'Migraine',
              'option-tension': 'Tension',
            },
          ),
        ),
      );
      final chart = tester.widget<BarChart>(find.byType(BarChart));
      expect(chart.data.barGroups, hasLength(2));
      expect(chart.data.barGroups[0].barRods.single.toY, 4);
      expect(chart.data.barGroups[1].barRods.single.toY, 9);
      expect(chart.data.barGroups[0].barRods.single.width, 14);
      // The enum option id is never shown; its label is.
      expect(find.text('Migraine'), findsOneWidget);
      expect(find.text('Tension'), findsOneWidget);
      expect(find.text('option-migraine'), findsNothing);
    });

    testWidgets('BarChart supports negative totals', (tester) async {
      final widget = definition(type: 'core.bar-chart', title: 'Net');
      final result = categories([
        (enumValue('a'), decimal(-2350, 2)),
        (enumValue('b'), decimal(257650, 2)),
      ]);
      await pumpChart(
        tester,
        _registry.build(
          renderContext(widget, evaluation: ready(widget, result)),
        ),
      );
      final chart = tester.widget<BarChart>(find.byType(BarChart));
      expect(chart.data.minY, lessThan(0));
      expect(chart.data.barGroups[0].barRods.single.toY, -23.5);
      expect(chart.data.barGroups[1].barRods.single.toY, 2576.5);
      expect(find.text('-23.50'), findsOneWidget);
      expect(find.text('2576.50'), findsOneWidget);
    });

    testWidgets('ScatterPlot renders one spot per observation', (tester) async {
      final widget = definition(
        type: 'core.scatter-plot',
        title: 'Measurements',
        configuration: _map({'point_radius': _integer(9)}),
      );
      final result = series([
        (dateTime(1700000000000), integer(3)),
        (dateTime(1700086400000), integer(7)),
        (dateTime(1700172800000), integer(7)),
      ]);
      await pumpChart(
        tester,
        _registry.build(
          renderContext(widget, evaluation: ready(widget, result)),
        ),
      );
      final chart = tester.widget<ScatterChart>(find.byType(ScatterChart));
      // Duplicate y values are separate observations; nothing is aggregated away.
      expect(chart.data.scatterSpots, hasLength(3));
      expect(
        chart.data.scatterSpots.first.dotPainter,
        isA<FlDotCirclePainter>().having(
          (painter) => painter.radius,
          'radius',
          9,
        ),
      );
    });

    testWidgets('empty series render the empty state for every chart', (
      tester,
    ) async {
      for (final type in [
        'core.line-chart',
        'core.bar-chart',
        'core.scatter-plot',
      ]) {
        final widget = definition(type: type, title: 'Empty');
        await pumpChart(
          tester,
          _registry.build(
            renderContext(widget, evaluation: ready(widget, series(const []))),
          ),
        );
        expect(
          find.byType(WidgetEmpty),
          findsOneWidget,
          reason: '$type must show an empty state',
        );
        expect(find.byType(LineChart), findsNothing, reason: type);
        expect(find.byType(BarChart), findsNothing, reason: type);
        expect(find.byType(ScatterChart), findsNothing, reason: type);
      }
    });
  });

  group('per-widget states', () {
    testWidgets('a null evaluation shows loading', (tester) async {
      final widget = definition(title: 'Loading');
      await pumpChart(
        tester,
        _registry.build(renderContext(widget)),
        size: const Size(300, 160),
      );
      expect(find.byType(WidgetLoading), findsOneWidget);
    });

    testWidgets('each typed error renders its own headline', (tester) async {
      final cases = <WidgetErrorKindDto, String>{
        WidgetErrorKindDto.shapeMismatch: 'Query result does not fit',
        WidgetErrorKindDto.overflow: 'Value out of range',
        WidgetErrorKindDto.unknownQuery: 'Query unavailable',
        WidgetErrorKindDto.invalidQuery: 'Query unavailable',
        WidgetErrorKindDto.unsupportedType: 'Unsupported widget',
        WidgetErrorKindDto.unsupportedConfigurationVersion:
            'Newer configuration version',
        WidgetErrorKindDto.invalidConfiguration: 'Invalid configuration',
        WidgetErrorKindDto.queryFailed: 'Query failed',
        WidgetErrorKindDto.removed: 'Widget removed',
      };
      for (final entry in cases.entries) {
        final widget = definition(type: 'core.line-chart', title: 'Broken');
        await pumpChart(
          tester,
          _registry.build(
            renderContext(
              widget,
              evaluation: failed(widget, entry.key, 'detail ${entry.key.name}'),
            ),
          ),
          size: const Size(320, 200),
        );
        expect(
          find.text(entry.value),
          findsOneWidget,
          reason: '${entry.key} headline',
        );
        expect(
          find.textContaining('detail ${entry.key.name}'),
          findsOneWidget,
          reason: '${entry.key} message',
        );
        expect(find.byType(LineChart), findsNothing, reason: entry.key.name);
      }
    });

    testWidgets('a failing widget does not stop its siblings', (tester) async {
      final good = definition(id: 'good', title: 'Balance');
      final bad = definition(
        id: 'bad',
        type: 'core.line-chart',
        title: 'Broken',
      );
      await pumpChart(
        tester,
        Column(
          children: [
            Expanded(
              child: _registry.build(
                renderContext(
                  good,
                  evaluation: ready(good, scalar(decimal(257650, 2))),
                ),
              ),
            ),
            Expanded(
              child: _registry.build(
                renderContext(
                  bad,
                  evaluation: failed(
                    bad,
                    WidgetErrorKindDto.shapeMismatch,
                    'scalar does not fit',
                  ),
                ),
              ),
            ),
          ],
        ),
        size: const Size(360, 400),
      );
      expect(find.text('2576.50'), findsOneWidget);
      expect(find.text('Query result does not fit'), findsOneWidget);
    });
  });
}
