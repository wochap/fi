import 'package:fi/exact_format.dart';
import 'package:fi/help_button.dart';
import 'package:fi/help_copy.dart';
import 'package:fi/l10n/l10n.dart';
import 'package:fi/src/rust/api/models.dart';
import 'package:fi/theme/fi_icons.dart';
import 'package:fi/theme/inputs.dart';
import 'package:fi/theme/nocturne.dart';
import 'package:flutter/material.dart';

/// Sentinel so `copyWith` can distinguish "leave this alone" from "set this to null".
const Object _keep = Object();

/// The presets offered above the chart builder.
enum ChartPreset { dailyTotal, monthlyTotal, countPerDay, latestValues }

String presetLabel(AppLocalizations l, ChartPreset preset) => switch (preset) {
  ChartPreset.dailyTotal => l.queryPresetDailyTotal,
  ChartPreset.monthlyTotal => l.queryPresetMonthlyTotal,
  ChartPreset.countPerDay => l.queryPresetCountPerDay,
  ChartPreset.latestValues => l.queryPresetLatestValues,
};

/// Everything the guided query builder can express, as plain data.
///
/// It holds `widgetType` because the widget type is what selects the result shape: a number is a
/// scalar, a bar chart is a category series, a line chart is a category series when grouped by a
/// period and a plain series when it is not. Keeping it here lets [toDefinition] be a pure
/// function of the state and lets a preset switch the chart kind along with the rest.
final class QueryBuilderState {
  const QueryBuilderState({
    this.widgetType = 'core.aggregate-number',
    this.aggregation = AggregationKindDto.count,
    this.operandFieldId,
    this.categoryFieldId,
    this.seriesXFieldId,
    this.seriesYFieldId,
    this.bucket,
    this.outputScale = 2,
    this.rounding = RoundingPolicyDto.halfEven,
    this.filterFieldId,
    this.filterOperator = ComparisonOperatorDto.equal,
    this.filterValue = '',
    this.descending = false,
    this.limit,
  });

  final String widgetType;
  final AggregationKindDto aggregation;
  final String? operandFieldId;
  final String? categoryFieldId;
  final String? seriesXFieldId;
  final String? seriesYFieldId;
  final BucketPeriodDto? bucket;
  final int outputScale;
  final RoundingPolicyDto rounding;
  final String? filterFieldId;
  final ComparisonOperatorDto filterOperator;
  final String filterValue;

  /// Series ordering. Descending plus a [limit] is how "Latest values" reads the newest records.
  final bool descending;
  final int? limit;

  QueryBuilderState copyWith({
    String? widgetType,
    AggregationKindDto? aggregation,
    Object? operandFieldId = _keep,
    Object? categoryFieldId = _keep,
    Object? seriesXFieldId = _keep,
    Object? seriesYFieldId = _keep,
    Object? bucket = _keep,
    int? outputScale,
    RoundingPolicyDto? rounding,
    Object? filterFieldId = _keep,
    ComparisonOperatorDto? filterOperator,
    String? filterValue,
    bool? descending,
    Object? limit = _keep,
  }) => QueryBuilderState(
    widgetType: widgetType ?? this.widgetType,
    aggregation: aggregation ?? this.aggregation,
    operandFieldId: identical(operandFieldId, _keep)
        ? this.operandFieldId
        : operandFieldId as String?,
    categoryFieldId: identical(categoryFieldId, _keep)
        ? this.categoryFieldId
        : categoryFieldId as String?,
    seriesXFieldId: identical(seriesXFieldId, _keep)
        ? this.seriesXFieldId
        : seriesXFieldId as String?,
    seriesYFieldId: identical(seriesYFieldId, _keep)
        ? this.seriesYFieldId
        : seriesYFieldId as String?,
    bucket: identical(bucket, _keep) ? this.bucket : bucket as BucketPeriodDto?,
    outputScale: outputScale ?? this.outputScale,
    rounding: rounding ?? this.rounding,
    filterFieldId: identical(filterFieldId, _keep)
        ? this.filterFieldId
        : filterFieldId as String?,
    filterOperator: filterOperator ?? this.filterOperator,
    filterValue: filterValue ?? this.filterValue,
    descending: descending ?? this.descending,
    limit: identical(limit, _keep) ? this.limit : limit as int?,
  );

  bool get isChart => widgetType != 'core.aggregate-number';
  bool get isScatter => widgetType == 'core.scatter-plot';

  /// Whether the emitted query actually aggregates. An ungrouped line chart plots records as they
  /// are, so it does not, even though the controls stay on screen.
  bool get needsAggregation =>
      widgetType == 'core.aggregate-number' ||
      widgetType == 'core.bar-chart' ||
      (widgetType == 'core.line-chart' && bucket != null);

  /// Whether the aggregation controls are shown at all. A line chart always shows them so the
  /// "sum per day" path is discoverable before a period has been chosen.
  bool get showsAggregation =>
      needsAggregation || widgetType == 'core.line-chart';

  bool get needsSeries =>
      isScatter || (widgetType == 'core.line-chart' && bucket == null);

  /// Shown on the disabled aggregation controls of an ungrouped line chart.
  bool get aggregationDisabled => showsAggregation && !needsAggregation;

  /// What still has to be chosen before this query can be submitted.
  String? blocker(AppLocalizations l) {
    if (needsAggregation) {
      if (aggregation != AggregationKindDto.count && operandFieldId == null) {
        return l.queryBlockerOperand;
      }
      if (widgetType != 'core.aggregate-number' && categoryFieldId == null) {
        return l.queryBlockerCategoryOrPeriod;
      }
    }
    if (needsSeries && (seriesXFieldId == null || seriesYFieldId == null)) {
      return l.queryBlockerAxes;
    }
    if (widgetType == 'core.bar-chart' &&
        bucket == null &&
        categoryFieldId == null) {
      return l.queryBlockerCategory;
    }
    if (filterFieldId != null && filterValue.trim().isEmpty) {
      return l.queryBlockerFilterValue;
    }
    return null;
  }

  QueryDefinitionDto toDefinition(
    CollectionSchemaDto schema,
    String name,
    int order, {
    String id = '',
    bool deleted = false,
    int queryVersion = 1,
    String decimalSeparator = '.',
  }) => QueryDefinitionDto(
    id: id,
    collectionId: schema.id,
    name: name,
    queryVersion: queryVersion,
    query: CollectionQueryDto(
      collectionId: schema.id,
      filter: _filterExpression(schema, decimalSeparator),
      grouping: bucket == null || categoryFieldId == null
          ? null
          : GroupingDto(
              expression: fieldExpression(categoryFieldId!),
              period: bucket!,
            ),
      shape: _shape(),
      sorting: _sorting(),
      limit: limit,
      calendar: const CalendarPolicyDto(
        timezone: 'UTC',
        weekStart: WeekStartDto.monday,
      ),
    ),
    order: order,
    deleted: deleted,
  );

  QueryShapeDto _shape() => switch (widgetType) {
    'core.scatter-plot' => QueryShapeDto(
      kind: QueryShapeKindDto.series,
      x: fieldExpression(seriesXFieldId!),
      y: fieldExpression(seriesYFieldId!),
      fields: const [],
    ),
    'core.line-chart' =>
      bucket != null
          ? QueryShapeDto(
              kind: QueryShapeKindDto.categorySeries,
              category: fieldExpression(categoryFieldId!),
              aggregation: _aggregation(),
              fields: const [],
            )
          : QueryShapeDto(
              kind: QueryShapeKindDto.series,
              x: fieldExpression(seriesXFieldId!),
              y: fieldExpression(seriesYFieldId!),
              fields: const [],
            ),
    'core.bar-chart' => QueryShapeDto(
      kind: QueryShapeKindDto.categorySeries,
      category: fieldExpression(categoryFieldId!),
      aggregation: _aggregation(),
      fields: const [],
    ),
    _ => QueryShapeDto(
      kind: QueryShapeKindDto.scalar,
      aggregation: _aggregation(),
      fields: const [],
    ),
  };

  List<SortClauseDto> _sorting() {
    // A Series is plotted exactly in the order the query returns, so chronological charts need
    // an explicit sort on the X expression.
    final x = switch (widgetType) {
      'core.scatter-plot' => seriesXFieldId,
      'core.line-chart' => bucket == null ? seriesXFieldId : null,
      _ => null,
    };
    if (x == null) return const [];
    return [
      SortClauseDto(
        expression: fieldExpression(x),
        direction: descending
            ? SortDirectionDto.descending
            : SortDirectionDto.ascending,
        nullOrder: NullOrderDto.last,
      ),
    ];
  }

  AggregationDto _aggregation() => switch (aggregation) {
    AggregationKindDto.count => const AggregationDto(
      kind: AggregationKindDto.count,
    ),
    AggregationKindDto.sum => AggregationDto(
      kind: AggregationKindDto.sum,
      expression: fieldExpression(operandFieldId!),
    ),
    AggregationKindDto.min => AggregationDto(
      kind: AggregationKindDto.min,
      expression: fieldExpression(operandFieldId!),
    ),
    AggregationKindDto.max => AggregationDto(
      kind: AggregationKindDto.max,
      expression: fieldExpression(operandFieldId!),
    ),
    AggregationKindDto.average => AggregationDto(
      kind: AggregationKindDto.average,
      expression: fieldExpression(operandFieldId!),
      outputScale: outputScale,
      rounding: rounding,
    ),
  };

  ExpressionDto? _filterExpression(
    CollectionSchemaDto schema,
    String decimalSeparator,
  ) {
    final fieldId = filterFieldId;
    if (fieldId == null) return null;
    final field = schema.fields.where((item) => item.id == fieldId).firstOrNull;
    if (field == null) return null;
    final constant = _constant(field, decimalSeparator);
    if (constant == null) return null;
    return ExpressionDto(
      root: 2,
      nodes: [
        ExpressionNodeDto(
          kind: ExpressionKindDto.field,
          field: FieldReferenceDto(
            kind: FieldReferenceKindDto.source,
            id: fieldId,
          ),
        ),
        ExpressionNodeDto(kind: ExpressionKindDto.constant, value: constant),
        ExpressionNodeDto(
          kind: ExpressionKindDto.compare,
          comparisonOperator: filterOperator,
          left: 0,
          right: 1,
        ),
      ],
    );
  }

  TypedValueDto? _constant(FieldDefinitionDto field, String decimalSeparator) {
    final raw = filterValue.trim();
    final kind = valueKindFor(field.fieldType.kind);
    final valueType = ValueTypeDto(kind: kind, scale: field.fieldType.scale);
    return switch (kind) {
      ValueTypeKindDto.text || ValueTypeKindDto.enum_ => TypedValueDto(
        valueType: valueType,
        textValue: raw,
      ),
      ValueTypeKindDto.boolean => TypedValueDto(
        valueType: valueType,
        booleanValue: switch (raw.toLowerCase()) {
          'true' => true,
          'false' => false,
          _ => null,
        },
      ),
      ValueTypeKindDto.fixedDecimal => TypedValueDto(
        valueType: valueType,
        integerValue: parseScaled(
          raw,
          field.fieldType.scale ?? 0,
          decimalSeparator: decimalSeparator,
        ),
      ),
      _ => TypedValueDto(valueType: valueType, integerValue: int.tryParse(raw)),
    };
  }

  /// Loads a saved definition back into builder state, or returns `null` when the definition says
  /// something this builder cannot say. Guessing would silently rewrite a query on save, so
  /// anything unrecognized is refused and the caller falls back to a read-only view.
  static QueryBuilderState? fromDefinition(
    QueryDefinitionDto definition,
    CollectionSchemaDto schema, {
    String decimalSeparator = '.',
  }) {
    final query = definition.query;
    if (query == null) return null;
    if (query.calendar.timezone != 'UTC' ||
        query.calendar.weekStart != WeekStartDto.monday) {
      return null;
    }
    final shape = query.shape;
    if (shape.fields.isNotEmpty) return null;

    var state = const QueryBuilderState();

    // Filter: only the one comparison shape the builder emits is representable.
    if (query.filter case final filter?) {
      final parsed = _parseFilter(filter, schema, decimalSeparator);
      if (parsed == null) return null;
      state = state.copyWith(
        filterFieldId: parsed.fieldId,
        filterOperator: parsed.operator,
        filterValue: parsed.value,
      );
    }

    final groupingFieldId = query.grouping == null
        ? null
        : _fieldIdOf(query.grouping!.expression);
    if (query.grouping != null && groupingFieldId == null) return null;

    switch (shape.kind) {
      case QueryShapeKindDto.scalar:
        if (query.grouping != null) return null;
        if (query.sorting.isNotEmpty || query.limit != null) return null;
        final aggregation = _parseAggregation(shape.aggregation);
        if (aggregation == null) return null;
        return aggregation(state.copyWith(widgetType: 'core.aggregate-number'));
      case QueryShapeKindDto.categorySeries:
        if (query.sorting.isNotEmpty || query.limit != null) return null;
        final categoryFieldId = shape.category == null
            ? null
            : _fieldIdOf(shape.category!);
        if (categoryFieldId == null) return null;
        // The builder always groups on the very field it plots as the category.
        if (query.grouping != null && groupingFieldId != categoryFieldId) {
          return null;
        }
        final aggregation = _parseAggregation(shape.aggregation);
        if (aggregation == null) return null;
        return aggregation(
          state.copyWith(
            // A grouped category series is emitted identically by a line chart and a bar chart,
            // so either is a faithful reading; the bar chart is the canonical one.
            widgetType: 'core.bar-chart',
            categoryFieldId: categoryFieldId,
            bucket: query.grouping?.period,
          ),
        );
      case QueryShapeKindDto.series:
        if (query.grouping != null) return null;
        if (shape.aggregation != null) return null;
        final x = shape.x == null ? null : _fieldIdOf(shape.x!);
        final y = shape.y == null ? null : _fieldIdOf(shape.y!);
        if (x == null || y == null) return null;
        if (query.sorting.length != 1) return null;
        final sort = query.sorting.single;
        if (_fieldIdOf(sort.expression) != x ||
            sort.nullOrder != NullOrderDto.last) {
          return null;
        }
        return state.copyWith(
          widgetType: 'core.line-chart',
          seriesXFieldId: x,
          seriesYFieldId: y,
          descending: sort.direction == SortDirectionDto.descending,
          limit: query.limit,
        );
      case QueryShapeKindDto.recordSet:
        return null;
    }
  }
}

/// Applies a preset, filling a field only when exactly one candidate exists so the user is never
/// handed a choice that was made for them by position.
QueryBuilderState applyPreset(
  ChartPreset preset,
  QueryBuilderState state,
  CollectionSchemaDto schema,
) {
  final dateField = _soleOrNull(timeFieldsOf(schema));
  final numericField = _soleOrNull(numericFieldsOf(schema));
  return switch (preset) {
    ChartPreset.dailyTotal => state.copyWith(
      widgetType: state.widgetType == 'core.bar-chart'
          ? 'core.bar-chart'
          : 'core.line-chart',
      bucket: BucketPeriodDto.day,
      aggregation: AggregationKindDto.sum,
      categoryFieldId: dateField?.id ?? state.categoryFieldId,
      operandFieldId: numericField?.id,
      descending: false,
      limit: null,
    ),
    ChartPreset.monthlyTotal => state.copyWith(
      widgetType: state.widgetType == 'core.bar-chart'
          ? 'core.bar-chart'
          : 'core.line-chart',
      bucket: BucketPeriodDto.month,
      aggregation: AggregationKindDto.sum,
      categoryFieldId: dateField?.id ?? state.categoryFieldId,
      operandFieldId: numericField?.id,
      descending: false,
      limit: null,
    ),
    ChartPreset.countPerDay => state.copyWith(
      widgetType: state.widgetType == 'core.bar-chart'
          ? 'core.bar-chart'
          : 'core.line-chart',
      bucket: BucketPeriodDto.day,
      aggregation: AggregationKindDto.count,
      categoryFieldId: dateField?.id ?? state.categoryFieldId,
      operandFieldId: null,
      descending: false,
      limit: null,
    ),
    // Latest values plots records as they are, which only the ungrouped series shape does.
    ChartPreset.latestValues => state.copyWith(
      widgetType: 'core.line-chart',
      bucket: null,
      seriesXFieldId: dateField?.id ?? state.seriesXFieldId,
      seriesYFieldId: numericField?.id ?? state.seriesYFieldId,
      descending: true,
      limit: 30,
    ),
  };
}

T? _soleOrNull<T>(List<T> items) => items.length == 1 ? items.single : null;

/// A one-line description of a saved query, for the places that offer to edit it.
String describeQuery(
  AppLocalizations l,
  QueryDefinitionDto definition,
  CollectionSchemaDto schema,
) {
  final query = definition.query;
  if (query == null) return l.queryMadeElsewhere;
  String fieldName(ExpressionDto expression) {
    final id = _fieldIdOf(expression);
    return schema.fields.where((item) => item.id == id).firstOrNull?.name ??
        id ??
        l.queryAnExpression;
  }

  final parts = <String>[];
  final aggregation = query.shape.aggregation;
  if (aggregation != null) {
    parts.add(
      aggregation.kind == AggregationKindDto.count
          ? l.queryAggCount
          : l.queryDescAggregationOf(
              _aggregationLabel(l, aggregation.kind),
              aggregation.expression == null
                  ? '?'
                  : fieldName(aggregation.expression!),
            ),
    );
  }
  switch (query.shape.kind) {
    case QueryShapeKindDto.series:
      parts.add(
        l.queryDescSeries(
          query.shape.x == null ? '?' : fieldName(query.shape.x!),
          query.shape.y == null ? '?' : fieldName(query.shape.y!),
        ),
      );
    case QueryShapeKindDto.categorySeries:
      parts.add(
        l.queryDescBy(
          query.shape.category == null ? '?' : fieldName(query.shape.category!),
        ),
      );
    case QueryShapeKindDto.scalar:
    case QueryShapeKindDto.recordSet:
      break;
  }
  if (query.grouping case final grouping?) {
    parts.add(switch (grouping.period) {
      BucketPeriodDto.day => l.queryDescPerDay,
      BucketPeriodDto.week => l.queryDescPerWeek,
      BucketPeriodDto.month => l.queryDescPerMonth,
      BucketPeriodDto.year => l.queryDescPerYear,
    });
  }
  if (query.filter != null) parts.add(l.queryDescFiltered);
  if (query.limit case final limit?) parts.add(l.queryDescLimit(limit));
  return parts.isEmpty ? l.queryDescEveryRecord : parts.join(', ');
}

String _aggregationLabel(AppLocalizations l, AggregationKindDto kind) =>
    switch (kind) {
      AggregationKindDto.count => l.queryAggCount,
      AggregationKindDto.sum => l.queryAggSum,
      AggregationKindDto.average => l.queryAggAverage,
      AggregationKindDto.min => l.queryAggMin,
      AggregationKindDto.max => l.queryAggMax,
    };

/// The type of the value [definition]'s aggregation produces, for the tag on its row: Integer
/// for Count, the operand's type for Sum, Min and Max, and a decimal at the declared output scale
/// for Average. Null when the query does not aggregate or its operand is unknown here.
ValueTypeDto? queryResultType(
  QueryDefinitionDto definition,
  CollectionSchemaDto schema, [
  List<ComputedFieldDefinitionDto> computedFields = const [],
]) {
  final aggregation = definition.query?.shape.aggregation;
  if (aggregation == null) return null;
  switch (aggregation.kind) {
    case AggregationKindDto.count:
      return const ValueTypeDto(kind: ValueTypeKindDto.integer);
    case AggregationKindDto.average:
      return ValueTypeDto(
        kind: ValueTypeKindDto.fixedDecimal,
        scale: aggregation.outputScale ?? 0,
      );
    case AggregationKindDto.sum ||
        AggregationKindDto.min ||
        AggregationKindDto.max:
      final expression = aggregation.expression;
      if (expression == null ||
          expression.nodes.length != 1 ||
          expression.root != 0) {
        return null;
      }
      final reference = expression.nodes.single.field;
      if (reference == null) return null;
      if (reference.kind == FieldReferenceKindDto.computed) {
        return computedFields
            .where((item) => item.id == reference.id)
            .firstOrNull
            ?.declaredType;
      }
      final field = schema.fields
          .where((item) => item.id == reference.id)
          .firstOrNull;
      if (field == null) return null;
      return ValueTypeDto(
        kind: valueKindFor(field.fieldType.kind),
        scale: field.fieldType.scale,
      );
  }
}

/// The single-node field expression the builder emits everywhere it names a field.
ExpressionDto fieldExpression(String fieldId) => ExpressionDto(
  root: 0,
  nodes: [
    ExpressionNodeDto(
      kind: ExpressionKindDto.field,
      field: FieldReferenceDto(kind: FieldReferenceKindDto.source, id: fieldId),
    ),
  ],
);

String? _fieldIdOf(ExpressionDto expression) {
  if (expression.nodes.length != 1 || expression.root != 0) return null;
  final node = expression.nodes.single;
  if (node.kind != ExpressionKindDto.field) return null;
  final field = node.field;
  if (field == null || field.kind != FieldReferenceKindDto.source) return null;
  return field.id;
}

/// A parsed aggregation, applied to the state under construction so the operand, scale, and
/// rounding land together with the kind.
typedef _AggregationApply = QueryBuilderState Function(QueryBuilderState);

_AggregationApply? _parseAggregation(AggregationDto? aggregation) {
  if (aggregation == null) return null;
  if (aggregation.kind == AggregationKindDto.count) {
    if (aggregation.expression != null) return null;
    return (state) => state.copyWith(
      aggregation: AggregationKindDto.count,
      operandFieldId: null,
    );
  }
  final expression = aggregation.expression;
  if (expression == null) return null;
  final operand = _fieldIdOf(expression);
  if (operand == null) return null;
  if (aggregation.kind == AggregationKindDto.average) {
    final scale = aggregation.outputScale;
    final rounding = aggregation.rounding;
    if (scale == null || rounding == null) return null;
    return (state) => state.copyWith(
      aggregation: AggregationKindDto.average,
      operandFieldId: operand,
      outputScale: scale,
      rounding: rounding,
    );
  }
  if (aggregation.outputScale != null || aggregation.rounding != null) {
    return null;
  }
  return (state) =>
      state.copyWith(aggregation: aggregation.kind, operandFieldId: operand);
}

final class _ParsedFilter {
  const _ParsedFilter(this.fieldId, this.operator, this.value);
  final String fieldId;
  final ComparisonOperatorDto operator;
  final String value;
}

_ParsedFilter? _parseFilter(
  ExpressionDto filter,
  CollectionSchemaDto schema,
  String decimalSeparator,
) {
  if (filter.nodes.length != 3 || filter.root != 2) return null;
  final left = filter.nodes[0];
  final constant = filter.nodes[1];
  final compare = filter.nodes[2];
  if (left.kind != ExpressionKindDto.field ||
      constant.kind != ExpressionKindDto.constant ||
      compare.kind != ExpressionKindDto.compare) {
    return null;
  }
  if (compare.left != 0 || compare.right != 1) return null;
  final reference = left.field;
  if (reference == null || reference.kind != FieldReferenceKindDto.source) {
    return null;
  }
  final field = schema.fields
      .where((item) => item.id == reference.id)
      .firstOrNull;
  if (field == null) return null;
  final operator = compare.comparisonOperator;
  final value = constant.value;
  if (operator == null || value == null) return null;
  if (value.valueType.kind != valueKindFor(field.fieldType.kind)) return null;
  final text = _constantText(value, decimalSeparator);
  if (text == null) return null;
  return _ParsedFilter(reference.id, operator, text);
}

/// The inverse of the constant the builder emits, so a saved filter reloads into its text box.
String? _constantText(TypedValueDto value, String decimalSeparator) =>
    switch (value.valueType.kind) {
      ValueTypeKindDto.text || ValueTypeKindDto.enum_ => value.textValue,
      ValueTypeKindDto.boolean => value.booleanValue?.toString(),
      ValueTypeKindDto.fixedDecimal =>
        value.integerValue == null
            ? null
            : formatScaled(
                value.integerValue!,
                value.valueType.scale ?? 0,
                decimalSeparator: decimalSeparator,
              ),
      _ => value.integerValue?.toString(),
    };

ValueTypeKindDto valueKindFor(FieldTypeKindDto kind) => switch (kind) {
  FieldTypeKindDto.text => ValueTypeKindDto.text,
  FieldTypeKindDto.integer => ValueTypeKindDto.integer,
  FieldTypeKindDto.fixedDecimal => ValueTypeKindDto.fixedDecimal,
  FieldTypeKindDto.boolean => ValueTypeKindDto.boolean,
  FieldTypeKindDto.date => ValueTypeKindDto.date,
  FieldTypeKindDto.dateTime => ValueTypeKindDto.dateTime,
  FieldTypeKindDto.duration => ValueTypeKindDto.duration,
  FieldTypeKindDto.enum_ => ValueTypeKindDto.enum_,
};

List<FieldDefinitionDto> activeFieldsOf(CollectionSchemaDto schema) =>
    schema.fields.where((field) => !field.deleted).toList();

List<FieldDefinitionDto> _fieldsWhere(
  CollectionSchemaDto schema,
  bool Function(FieldTypeKindDto) test,
) => activeFieldsOf(schema).where((f) => test(f.fieldType.kind)).toList();

List<FieldDefinitionDto> numericFieldsOf(CollectionSchemaDto schema) =>
    _fieldsWhere(
      schema,
      (kind) =>
          kind == FieldTypeKindDto.integer ||
          kind == FieldTypeKindDto.fixedDecimal ||
          kind == FieldTypeKindDto.duration,
    );

List<FieldDefinitionDto> timeFieldsOf(CollectionSchemaDto schema) =>
    _fieldsWhere(
      schema,
      (kind) =>
          kind == FieldTypeKindDto.date || kind == FieldTypeKindDto.dateTime,
    );

List<FieldDefinitionDto> categoryFieldsOf(CollectionSchemaDto schema) =>
    _fieldsWhere(
      schema,
      (kind) =>
          kind == FieldTypeKindDto.enum_ ||
          kind == FieldTypeKindDto.text ||
          kind == FieldTypeKindDto.boolean ||
          kind == FieldTypeKindDto.date ||
          kind == FieldTypeKindDto.dateTime,
    );

List<FieldDefinitionDto> plotFieldsOf(CollectionSchemaDto schema) =>
    _fieldsWhere(
      schema,
      (kind) =>
          kind == FieldTypeKindDto.integer ||
          kind == FieldTypeKindDto.fixedDecimal ||
          kind == FieldTypeKindDto.duration ||
          kind == FieldTypeKindDto.date ||
          kind == FieldTypeKindDto.dateTime,
    );

/// How the filter condition is presented: the widget form shows it as a removable chip behind
/// "Add filter"; the saved-query editor shows one "Only records where" row.
enum QueryFilterStyle { chip, row }

/// The guided query controls, shared by the widget form and the saved-query editor.
///
/// It owns no state of its own beyond the filter text controller: every change is reported to the
/// parent, which holds the authoritative [QueryBuilderState].
final class QueryBuilder extends StatefulWidget {
  const QueryBuilder({
    required this.schema,
    required this.state,
    required this.onChanged,
    this.showPresets = true,
    this.filterStyle = QueryFilterStyle.row,
    super.key,
  });

  final CollectionSchemaDto schema;
  final QueryBuilderState state;
  final ValueChanged<QueryBuilderState> onChanged;

  /// The saved-query editor shows presets too; only the unsupported-widget path hides them.
  final bool showPresets;

  final QueryFilterStyle filterStyle;

  @override
  State<QueryBuilder> createState() => _QueryBuilderState();
}

class _QueryBuilderState extends State<QueryBuilder> {
  final filterValue = TextEditingController();

  /// Chip style: the condition row is open, either from "Add filter" or by tapping the chip.
  bool editingFilter = false;

  QueryBuilderState get state => widget.state;
  CollectionSchemaDto get schema => widget.schema;

  @override
  void initState() {
    super.initState();
    filterValue.text = state.filterValue;
  }

  @override
  void didUpdateWidget(QueryBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A preset can rewrite the filter text; anything the user typed is already in the state.
    if (state.filterValue != filterValue.text) {
      filterValue.text = state.filterValue;
    }
  }

  @override
  void dispose() {
    filterValue.dispose();
    super.dispose();
  }

  void _emit(QueryBuilderState next) => widget.onChanged(next);

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      // Outlined inputs need air between them; the labels sit on their top edges.
      spacing: 14,
      children: [
        if (widget.showPresets &&
            (state.widgetType == 'core.line-chart' ||
                state.widgetType == 'core.bar-chart'))
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 4),
            child: Wrap(
              spacing: 8,
              children: [
                for (final preset in ChartPreset.values)
                  ActionChip(
                    key: Key('preset-${preset.name}'),
                    label: Text(presetLabel(l, preset)),
                    onPressed: () => _emit(applyPreset(preset, state, schema)),
                  ),
              ],
            ),
          ),
        // Group by comes first: a user thinks "per day, sum of amount", not the other way round.
        if (state.isChart && !state.isScatter) ...[
          FiSelect<BucketPeriodDto?>(
            key: const Key('bucket-period'),
            value: state.bucket,
            label: l.queryGroupBy,
            suffixIcon: const HelpButton(HelpId.widgetGroupBy),
            items: [
              DropdownMenuItem(value: null, child: Text(l.commonNone)),
              DropdownMenuItem(
                value: BucketPeriodDto.day,
                child: Text(l.queryPeriodDay),
              ),
              DropdownMenuItem(
                value: BucketPeriodDto.week,
                child: Text(l.queryPeriodWeek),
              ),
              DropdownMenuItem(
                value: BucketPeriodDto.month,
                child: Text(l.queryPeriodMonth),
              ),
              DropdownMenuItem(
                value: BucketPeriodDto.year,
                child: Text(l.queryPeriodYear),
              ),
            ],
            onChanged: (value) => _emit(
              // Switching the period swaps the allowed field kinds, so the previous choice cannot
              // be carried over.
              state.copyWith(
                bucket: value,
                categoryFieldId: value == null ? state.categoryFieldId : null,
              ),
            ),
          ),
          _fieldDropdown(
            key: ValueKey('category-field-${state.bucket}'),
            label: state.bucket == null
                ? l.queryCategoryField
                : l.queryDateField,
            help: state.bucket == null
                ? HelpId.widgetCategoryField
                : HelpId.widgetDateField,
            fields: state.bucket == null
                ? categoryFieldsOf(schema)
                : timeFieldsOf(schema),
            value: state.categoryFieldId,
            onChanged: (value) => _emit(state.copyWith(categoryFieldId: value)),
          ),
        ],
        if (state.showsAggregation) ...[
          FiSelect<AggregationKindDto>(
            key: const Key('aggregation'),
            value: state.aggregation,
            label: l.queryAggregation,
            suffixIcon: const HelpButton(HelpId.widgetAggregation),
            helperText: state.aggregationDisabled
                ? l.queryAggregationNeedsGroup
                : null,
            items: [
              for (final kind in AggregationKindDto.values)
                DropdownMenuItem(
                  value: kind,
                  child: Text(_aggregationLabel(l, kind)),
                ),
            ],
            onChanged: state.aggregationDisabled
                ? null
                : (value) => _emit(
                    state.copyWith(
                      aggregation: value ?? state.aggregation,
                      operandFieldId: value == AggregationKindDto.count
                          ? null
                          : state.operandFieldId,
                    ),
                  ),
          ),
          if (state.aggregation != AggregationKindDto.count)
            _fieldDropdown(
              // Keyed by the aggregation so switching back to Count clears the displayed operand
              // instead of leaving a stale choice the state no longer holds.
              key: ValueKey('operand-field-${state.aggregation}'),
              label: l.queryOperandField,
              help: HelpId.widgetOperandField,
              fields: numericFieldsOf(schema),
              value: state.operandFieldId,
              enabled: !state.aggregationDisabled,
              onChanged: (value) =>
                  _emit(state.copyWith(operandFieldId: value)),
            ),
          // An exact numeric policy is mandatory for Average so no implicit rounding is invented.
          if (state.aggregation == AggregationKindDto.average) ...[
            FiTextInput(
              key: const Key('output-scale'),
              initialValue: '${state.outputScale}',
              enabled: !state.aggregationDisabled,
              keyboardType: TextInputType.number,
              label: l.queryOutputScale,
              suffixIcon: const HelpButton(HelpId.widgetOutputScale),
              onChanged: (value) => _emit(
                state.copyWith(
                  outputScale: int.tryParse(value) ?? state.outputScale,
                ),
              ),
            ),
            _labelled(
              l.queryRoundingPolicy,
              const HelpButton(HelpId.widgetRounding),
              SegmentedButton<RoundingPolicyDto>(
                key: const Key('rounding'),
                showSelectedIcon: false,
                segments: [
                  ButtonSegment(
                    value: RoundingPolicyDto.halfEven,
                    label: Text(l.queryRoundingHalfEven),
                  ),
                  ButtonSegment(
                    value: RoundingPolicyDto.rejectInexact,
                    label: Text(l.queryRoundingRejectInexact),
                  ),
                ],
                selected: {state.rounding},
                onSelectionChanged: state.aggregationDisabled
                    ? null
                    : (value) => _emit(state.copyWith(rounding: value.single)),
              ),
            ),
          ],
        ],
        if (state.needsSeries) ...[
          _fieldDropdown(
            key: const Key('series-x'),
            label: l.queryXAxis,
            help: HelpId.widgetXAxis,
            fields: plotFieldsOf(schema),
            value: state.seriesXFieldId,
            onChanged: (value) => _emit(state.copyWith(seriesXFieldId: value)),
          ),
          _fieldDropdown(
            key: const Key('series-y'),
            label: l.queryYAxis,
            help: HelpId.widgetYAxis,
            fields: numericFieldsOf(schema),
            value: state.seriesYFieldId,
            onChanged: (value) => _emit(state.copyWith(seriesYFieldId: value)),
          ),
        ],
        ...switch (widget.filterStyle) {
          QueryFilterStyle.row => [
            Text(
              l.queryOnlyRecordsWhere,
              style: TextStyle(fontSize: 12, color: Nocturne.muted(.7)),
            ),
            _conditionRow(l),
          ],
          QueryFilterStyle.chip => _filterChip(l),
        },
      ],
    );
  }

  /// A control under a small label with its help button, for controls without a label of their
  /// own (segmented buttons).
  Widget _labelled(String label, Widget help, Widget control) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Text(
            label,
            style: TextStyle(fontSize: 12, color: Nocturne.muted(.7)),
          ),
          help,
        ],
      ),
      control,
    ],
  );

  /// The condition in words, e.g. `Type is headache`.
  String _conditionText(AppLocalizations l) {
    final field = schema.fields
        .where((item) => item.id == state.filterFieldId)
        .firstOrNull;
    final value = field?.fieldType.kind == FieldTypeKindDto.enum_
        ? field!.enumOptions
                  .where((option) => option.id == state.filterValue.trim())
                  .firstOrNull
                  ?.label ??
              state.filterValue.trim()
        : state.filterValue.trim();
    return l.queryFilterChip(field?.name ?? '?', switch (state.filterOperator) {
      ComparisonOperatorDto.equal => l.queryOpIs,
      ComparisonOperatorDto.notEqual => l.queryOpIsNot,
      ComparisonOperatorDto.greaterThan => l.queryOpGreaterThan,
      ComparisonOperatorDto.greaterThanOrEqual => l.queryOpAtLeast,
      ComparisonOperatorDto.lessThan => l.queryOpLessThan,
      ComparisonOperatorDto.lessThanOrEqual => l.queryOpAtMost,
    }, value);
  }

  void _clearFilter() {
    setState(() => editingFilter = false);
    _emit(state.copyWith(filterFieldId: null, filterValue: ''));
  }

  /// Chip style: the finished condition as a chip (✕ removes it), the open condition row, or the
  /// "Add filter" button. One condition at most, so "Add filter" hides while one exists.
  List<Widget> _filterChip(AppLocalizations l) {
    final complete =
        state.filterFieldId != null && state.filterValue.trim().isNotEmpty;
    if (editingFilter || (state.filterFieldId != null && !complete)) {
      return [
        _conditionRow(l),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              key: const Key('remove-filter'),
              onPressed: _clearFilter,
              child: Text(l.queryRemoveFilter),
            ),
            TextButton(
              key: const Key('apply-filter'),
              onPressed: complete
                  ? () => setState(() => editingFilter = false)
                  : null,
              child: Text(l.commonDone),
            ),
          ],
        ),
      ];
    }
    if (state.filterFieldId != null) {
      return [
        Align(
          alignment: Alignment.centerLeft,
          child: InputChip(
            key: const Key('filter-chip'),
            label: Text(_conditionText(l)),
            onPressed: () => setState(() => editingFilter = true),
            onDeleted: _clearFilter,
            deleteIcon: const Icon(FiIcons.clear, size: 14),
            deleteButtonTooltipMessage: l.queryRemoveFilter,
          ),
        ),
      ];
    }
    return [
      Row(
        children: [
          TextButton.icon(
            key: const Key('add-filter'),
            onPressed: () => setState(() => editingFilter = true),
            icon: const Icon(FiIcons.add, size: 16),
            label: Text(l.queryAddFilter),
          ),
          const HelpButton(HelpId.widgetFilter),
        ],
      ),
    ];
  }

  /// Field, operator and value side by side.
  Widget _conditionRow(AppLocalizations l) {
    final fields = activeFieldsOf(schema);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 8,
      children: [
        Expanded(
          child: FiSelect<String>.compact(
            key: const Key('filter-field'),
            value: fields.any((field) => field.id == state.filterFieldId)
                ? state.filterFieldId
                : null,
            label: l.queryFilterField,
            items: [
              DropdownMenuItem<String>(value: null, child: Text(l.commonNone)),
              for (final field in fields)
                DropdownMenuItem(value: field.id, child: Text(field.name)),
            ],
            onChanged: (value) => _emit(state.copyWith(filterFieldId: value)),
          ),
        ),
        Expanded(
          child: FiSelect<ComparisonOperatorDto>.compact(
            key: const Key('filter-operator'),
            value: state.filterOperator,
            label: l.queryFilterOperator,
            items: [
              DropdownMenuItem(
                value: ComparisonOperatorDto.equal,
                child: Text(l.queryOpEquals),
              ),
              DropdownMenuItem(
                value: ComparisonOperatorDto.notEqual,
                child: Text(l.queryOpIsNot),
              ),
              DropdownMenuItem(
                value: ComparisonOperatorDto.greaterThan,
                child: Text(l.queryOpGreaterThan),
              ),
              DropdownMenuItem(
                value: ComparisonOperatorDto.greaterThanOrEqual,
                child: Text(l.queryOpAtLeast),
              ),
              DropdownMenuItem(
                value: ComparisonOperatorDto.lessThan,
                child: Text(l.queryOpLessThan),
              ),
              DropdownMenuItem(
                value: ComparisonOperatorDto.lessThanOrEqual,
                child: Text(l.queryOpAtMost),
              ),
            ],
            onChanged: state.filterFieldId == null
                ? null
                : (value) => _emit(
                    state.copyWith(
                      filterOperator: value ?? state.filterOperator,
                    ),
                  ),
          ),
        ),
        Expanded(
          child: FiTextInput.compact(
            key: const Key('filter-value'),
            controller: filterValue,
            enabled: state.filterFieldId != null,
            label: l.queryFilterValue,
            onChanged: (value) => _emit(state.copyWith(filterValue: value)),
          ),
        ),
      ],
    );
  }

  Widget _fieldDropdown({
    required Key key,
    required String label,
    required HelpId help,
    required List<FieldDefinitionDto> fields,
    required String? value,
    required ValueChanged<String?> onChanged,
    bool enabled = true,
  }) {
    final current = fields.any((field) => field.id == value) ? value : null;
    return FiSelect<String>(
      key: key,
      value: current,
      label: label,
      suffixIcon: HelpButton(help),
      items: [
        for (final field in fields)
          DropdownMenuItem(value: field.id, child: Text(field.name)),
      ],
      onChanged: enabled ? onChanged : null,
    );
  }
}
