import 'package:fi/src/rust/api/models.dart';
import 'package:fi/widgets/query_builder.dart';
import 'package:flutter_test/flutter_test.dart';

FieldDefinitionDto _field(
  String id,
  String name,
  FieldTypeKindDto kind, {
  int order = 0,
  int? scale,
}) => FieldDefinitionDto(
  id: id,
  name: name,
  fieldType: FieldTypeDto(kind: kind, scale: scale),
  required_: false,
  validation: const ValidationMetadataDto(),
  display: const DisplayMetadataDto(multiline: false, slider: false),
  order: order,
  deleted: false,
  enumOptions: const [],
);

final schema = CollectionSchemaDto(
  id: 'collection',
  description: '',
  name: 'Headaches',
  fields: [
    _field('amount', 'Amount', FieldTypeKindDto.fixedDecimal, scale: 2),
    _field('started', 'Started at', FieldTypeKindDto.date, order: 1),
    _field('note', 'Note', FieldTypeKindDto.text, order: 2),
  ],
);

/// A second numeric and a second date field, so presets have more than one candidate.
final ambiguousSchema = CollectionSchemaDto(
  id: 'collection',
  description: '',
  name: 'Headaches',
  fields: [
    ...schema.fields,
    _field('duration', 'Duration', FieldTypeKindDto.duration, order: 3),
    _field('ended', 'Ended at', FieldTypeKindDto.date, order: 4),
  ],
);

/// DTO equality compares lists by identity, so round-trip fidelity is checked structurally.
void expectSameQuery(QueryDefinitionDto actual, QueryDefinitionDto expected) {
  expect(actual.id, expected.id);
  expect(actual.collectionId, expected.collectionId);
  expect(actual.name, expected.name);
  expect(actual.order, expected.order);
  expect(actual.deleted, expected.deleted);
  final left = actual.query!;
  final right = expected.query!;
  expect(left.collectionId, right.collectionId);
  expect(left.limit, right.limit);
  expect(left.calendar, right.calendar);
  expectSameExpression(left.filter, right.filter);
  expect(left.grouping?.period, right.grouping?.period);
  expectSameExpression(left.grouping?.expression, right.grouping?.expression);
  expect(left.shape.kind, right.shape.kind);
  expectSameExpression(left.shape.x, right.shape.x);
  expectSameExpression(left.shape.y, right.shape.y);
  expectSameExpression(left.shape.category, right.shape.category);
  expect(left.shape.fields, right.shape.fields);
  expect(left.shape.aggregation?.kind, right.shape.aggregation?.kind);
  expect(
    left.shape.aggregation?.outputScale,
    right.shape.aggregation?.outputScale,
  );
  expect(left.shape.aggregation?.rounding, right.shape.aggregation?.rounding);
  expectSameExpression(
    left.shape.aggregation?.expression,
    right.shape.aggregation?.expression,
  );
  expect(left.sorting.length, right.sorting.length);
  for (var i = 0; i < left.sorting.length; i++) {
    expect(left.sorting[i].direction, right.sorting[i].direction);
    expect(left.sorting[i].nullOrder, right.sorting[i].nullOrder);
    expectSameExpression(
      left.sorting[i].expression,
      right.sorting[i].expression,
    );
  }
}

void expectSameExpression(ExpressionDto? actual, ExpressionDto? expected) {
  if (expected == null) {
    expect(actual, isNull);
    return;
  }
  expect(actual, isNotNull);
  expect(actual!.root, expected.root);
  expect(actual.nodes.length, expected.nodes.length);
  for (var i = 0; i < actual.nodes.length; i++) {
    expect(actual.nodes[i], expected.nodes[i]);
  }
}

QueryDefinitionDto _definition(QueryBuilderState state) =>
    state.toDefinition(schema, 'Saved', 3, id: 'query-1');

/// The filter every "with a filter" case reuses: Amount at least 10.00.
QueryBuilderState _withFilter(QueryBuilderState state) => state.copyWith(
  filterFieldId: 'amount',
  filterOperator: ComparisonOperatorDto.greaterThanOrEqual,
  filterValue: '10.00',
);

void main() {
  final shapes = <String, QueryBuilderState>{
    'scalar': const QueryBuilderState(
      widgetType: 'core.aggregate-number',
      aggregation: AggregationKindDto.sum,
      operandFieldId: 'amount',
    ),
    'scalar average': const QueryBuilderState(
      widgetType: 'core.aggregate-number',
      aggregation: AggregationKindDto.average,
      operandFieldId: 'amount',
      outputScale: 3,
      rounding: RoundingPolicyDto.rejectInexact,
    ),
    'series': const QueryBuilderState(
      widgetType: 'core.line-chart',
      seriesXFieldId: 'started',
      seriesYFieldId: 'amount',
    ),
    'series descending with a limit': const QueryBuilderState(
      widgetType: 'core.line-chart',
      seriesXFieldId: 'started',
      seriesYFieldId: 'amount',
      descending: true,
      limit: 30,
    ),
    'grouped category series': const QueryBuilderState(
      widgetType: 'core.bar-chart',
      aggregation: AggregationKindDto.sum,
      operandFieldId: 'amount',
      categoryFieldId: 'started',
      bucket: BucketPeriodDto.month,
    ),
    'ungrouped category series': const QueryBuilderState(
      widgetType: 'core.bar-chart',
      aggregation: AggregationKindDto.count,
      categoryFieldId: 'note',
    ),
  };

  for (final entry in shapes.entries) {
    for (final filtered in [false, true]) {
      test('round trip: ${entry.key}${filtered ? ' with a filter' : ''}', () {
        final state = filtered ? _withFilter(entry.value) : entry.value;
        final original = _definition(state);
        final loaded = QueryBuilderState.fromDefinition(original, schema);
        expect(
          loaded,
          isNotNull,
          reason: 'builder could not read its own output',
        );
        expectSameQuery(_definition(loaded!), original);
      });
    }
  }

  test('a record-set shape is refused rather than guessed at', () {
    final definition = QueryDefinitionDto(
      id: 'query-1',
      collectionId: 'collection',
      name: 'Elsewhere',
      queryVersion: 1,
      query: CollectionQueryDto(
        collectionId: 'collection',
        shape: const QueryShapeDto(
          kind: QueryShapeKindDto.recordSet,
          fields: [],
        ),
        sorting: const [],
        calendar: const CalendarPolicyDto(
          timezone: 'UTC',
          weekStart: WeekStartDto.monday,
        ),
      ),
      order: 0,
      deleted: false,
    );
    expect(QueryBuilderState.fromDefinition(definition, schema), isNull);
  });

  test('an unreadable expression is refused rather than guessed at', () {
    final definition = QueryDefinitionDto(
      id: 'query-1',
      collectionId: 'collection',
      name: 'Elsewhere',
      queryVersion: 1,
      query: CollectionQueryDto(
        collectionId: 'collection',
        shape: QueryShapeDto(
          kind: QueryShapeKindDto.scalar,
          aggregation: AggregationDto(
            kind: AggregationKindDto.sum,
            // An arithmetic operand is beyond anything the builder can put on screen.
            expression: ExpressionDto(
              root: 2,
              nodes: [
                fieldExpression('amount').nodes.single,
                fieldExpression('amount').nodes.single,
                const ExpressionNodeDto(
                  kind: ExpressionKindDto.arithmetic,
                  arithmeticOperator: ArithmeticOperatorDto.add,
                  left: 0,
                  right: 1,
                ),
              ],
            ),
          ),
          fields: const [],
        ),
        sorting: const [],
        calendar: const CalendarPolicyDto(
          timezone: 'UTC',
          weekStart: WeekStartDto.monday,
        ),
      ),
      order: 0,
      deleted: false,
    );
    expect(QueryBuilderState.fromDefinition(definition, schema), isNull);
  });

  test('a query with no body is refused', () {
    const definition = QueryDefinitionDto(
      id: 'query-1',
      collectionId: 'collection',
      name: 'Elsewhere',
      queryVersion: 1,
      unsupportedBodyJson: '{}',
      order: 0,
      deleted: false,
    );
    expect(QueryBuilderState.fromDefinition(definition, schema), isNull);
  });

  group('presets', () {
    const line = QueryBuilderState(widgetType: 'core.line-chart');

    test('Daily total fills both fields when each has one candidate', () {
      final state = applyPreset(ChartPreset.dailyTotal, line, schema);
      expect(state.bucket, BucketPeriodDto.day);
      expect(state.aggregation, AggregationKindDto.sum);
      expect(state.categoryFieldId, 'started');
      expect(state.operandFieldId, 'amount');
      expect(state.blocker, isNull);
    });

    test('Monthly total differs from Daily total only in the period', () {
      final state = applyPreset(ChartPreset.monthlyTotal, line, schema);
      expect(state.bucket, BucketPeriodDto.month);
      expect(state.aggregation, AggregationKindDto.sum);
    });

    test('Daily total leaves an ambiguous field for the user to choose', () {
      final state = applyPreset(ChartPreset.dailyTotal, line, ambiguousSchema);
      expect(state.bucket, BucketPeriodDto.day);
      expect(state.operandFieldId, isNull);
      expect(state.categoryFieldId, isNull);
      expect(state.blocker, 'Choose the field to aggregate.');
    });

    test('Count per day needs no operand', () {
      final state = applyPreset(ChartPreset.countPerDay, line, schema);
      expect(state.aggregation, AggregationKindDto.count);
      expect(state.operandFieldId, isNull);
      expect(state.bucket, BucketPeriodDto.day);
      expect(state.blocker, isNull);
    });

    test('Latest values plots records newest first, capped', () {
      final state = applyPreset(ChartPreset.latestValues, line, schema);
      expect(state.bucket, isNull);
      expect(state.seriesXFieldId, 'started');
      expect(state.seriesYFieldId, 'amount');
      expect(state.descending, isTrue);
      expect(state.limit, 30);
      final query = _definition(state).query!;
      expect(query.shape.kind, QueryShapeKindDto.series);
      expect(query.sorting.single.direction, SortDirectionDto.descending);
      expect(query.limit, 30);
    });

    test('a preset applied to a bar chart keeps it a bar chart', () {
      const bar = QueryBuilderState(widgetType: 'core.bar-chart');
      expect(
        applyPreset(ChartPreset.dailyTotal, bar, schema).widgetType,
        'core.bar-chart',
      );
    });
  });

  test('an ungrouped line chart shows the aggregation controls disabled', () {
    const state = QueryBuilderState(
      widgetType: 'core.line-chart',
      seriesXFieldId: 'started',
      seriesYFieldId: 'amount',
    );
    expect(state.showsAggregation, isTrue);
    expect(state.needsAggregation, isFalse);
    expect(state.aggregationDisabled, isTrue);
    // The emitted query is unchanged by the controls being on screen.
    expect(_definition(state).query!.shape.kind, QueryShapeKindDto.series);
    expect(_definition(state).query!.shape.aggregation, isNull);
  });
}
