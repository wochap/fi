import 'dart:convert';

import 'package:fi/src/rust/api/models.dart';
import 'package:fi/src/rust/api/views.dart';

/// JSON for a view body, used for the per-device draft in `ui_prefs.json` and for structural
/// equality. Every clause's null order is written as `last`, matching what Rust stores, so two
/// bodies that differ only there compare equal.
Map<String, Object?> viewBodyToJson(ViewBodyDto body) => {
  if (body.filter case final filter?) 'filter': _expressionToJson(filter),
  'sorting': [
    for (final clause in body.sorting)
      {
        'expression': _expressionToJson(clause.expression),
        'direction': clause.direction.name,
      },
  ],
  if (body.grouping case final grouping?)
    'grouping': {
      'field': grouping.fieldId,
      if (grouping.period case final period?) 'period': period.name,
    },
};

/// Reads what [viewBodyToJson] wrote; null when [json] cannot be read.
ViewBodyDto? viewBodyFromJson(Object? json) {
  try {
    if (json is! Map) return null;
    final filter = json['filter'];
    final grouping = json['grouping'] as Map?;
    return ViewBodyDto(
      filter: filter == null ? null : _expressionFromJson(filter),
      sorting: [
        for (final clause in json['sorting'] as List)
          SortClauseDto(
            expression: _expressionFromJson((clause as Map)['expression']),
            direction: SortDirectionDto.values.byName(
              clause['direction'] as String,
            ),
            nullOrder: NullOrderDto.last,
          ),
      ],
      grouping: grouping == null
          ? null
          : ViewGroupingDto(
              fieldId: grouping['field'] as String,
              period: _enum(GroupPeriodDto.values, grouping['period']),
            ),
    );
  } catch (_) {
    return null;
  }
}

/// Structural equality of two view bodies after normalising.
bool sameViewBody(ViewBodyDto? a, ViewBodyDto? b) {
  if (a == null || b == null) return a == b;
  return jsonEncode(viewBodyToJson(a)) == jsonEncode(viewBodyToJson(b));
}

Map<String, Object?> _expressionToJson(ExpressionDto expression) => {
  'root': expression.root,
  'nodes': [for (final node in expression.nodes) _nodeToJson(node)],
};

ExpressionDto _expressionFromJson(Object? json) {
  final map = json as Map;
  return ExpressionDto(
    root: map['root'] as int,
    nodes: [for (final node in map['nodes'] as List) _nodeFromJson(node)],
  );
}

Map<String, Object?> _nodeToJson(ExpressionNodeDto node) => {
  'kind': node.kind.name,
  if (node.value case final value?) 'value': _valueToJson(value),
  if (node.field case final field?)
    'field': {'kind': field.kind.name, 'id': field.id},
  if (node.arithmeticOperator case final op?) 'arithmetic': op.name,
  if (node.comparisonOperator case final op?) 'comparison': op.name,
  if (node.setOperator case final op?) 'set': op.name,
  if (node.booleanOperator case final op?) 'boolean': op.name,
  'left': ?node.left,
  'right': ?node.right,
  'expression': ?node.expression,
  'output_scale': ?node.outputScale,
  if (node.rounding case final v?) 'rounding': v.name,
  if (node.boundary case final v?) 'boundary': v.name,
};

T? _enum<T extends Enum>(List<T> values, Object? name) =>
    name == null ? null : values.byName(name as String);

ExpressionNodeDto _nodeFromJson(Object? json) {
  final map = json as Map;
  final field = map['field'] as Map?;
  return ExpressionNodeDto(
    kind: ExpressionKindDto.values.byName(map['kind'] as String),
    value: map['value'] == null ? null : _valueFromJson(map['value']),
    field: field == null
        ? null
        : FieldReferenceDto(
            kind: FieldReferenceKindDto.values.byName(field['kind'] as String),
            id: field['id'] as String,
          ),
    arithmeticOperator: _enum(ArithmeticOperatorDto.values, map['arithmetic']),
    comparisonOperator: _enum(ComparisonOperatorDto.values, map['comparison']),
    setOperator: _enum(SetOperatorDto.values, map['set']),
    booleanOperator: _enum(BooleanOperatorDto.values, map['boolean']),
    left: map['left'] as int?,
    right: map['right'] as int?,
    expression: map['expression'] as int?,
    outputScale: map['output_scale'] as int?,
    rounding: _enum(RoundingPolicyDto.values, map['rounding']),
    boundary: _enum(CurrentBoundaryDto.values, map['boundary']),
  );
}

Map<String, Object?> _valueToJson(TypedValueDto value) => {
  'type': value.valueType.kind.name,
  'scale': ?value.valueType.scale,
  'integer': ?value.integerValue,
  'text': ?value.textValue,
  'boolean': ?value.booleanValue,
  if (value.listValue.isNotEmpty) 'list': value.listValue,
  'field_id': ?value.fieldId,
};

TypedValueDto _valueFromJson(Object? json) {
  final map = json as Map;
  return TypedValueDto(
    valueType: ValueTypeDto(
      kind: ValueTypeKindDto.values.byName(map['type'] as String),
      scale: map['scale'] as int?,
    ),
    integerValue: map['integer'] as int?,
    textValue: map['text'] as String?,
    booleanValue: map['boolean'] as bool?,
    listValue: [for (final item in (map['list'] as List?) ?? const []) '$item'],
    fieldId: map['field_id'] as String?,
  );
}
