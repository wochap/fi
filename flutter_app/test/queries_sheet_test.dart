import 'package:fi/collections_page.dart';
import 'package:fi/controllers.dart';
import 'package:fi/src/rust/api/models.dart';
import 'package:fi/theme/nocturne.dart';
import 'package:fi/widgets/expression_builder.dart';
import 'package:fi/widgets/query_builder.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_bridge.dart';

FieldDefinitionDto _field(
  String name,
  FieldTypeKindDto kind, {
  bool required = true,
  int order = 0,
  int? scale,
}) => FieldDefinitionDto(
  id: '',
  name: name,
  fieldType: FieldTypeDto(kind: kind, scale: scale),
  required_: required,
  validation: const ValidationMetadataDto(),
  display: const DisplayMetadataDto(
    multiline: false,
    slider: false,
    sliderStep: null,
  ),
  order: order,
  deleted: false,
  enumOptions: const [],
);

StructuredValueDto _emptyMap() => const StructuredValueDto(
  kind: StructuredValueKindDto.map,
  items: [],
  entries: [],
);

ExpressionDto _single(FieldReferenceKindDto kind, String id) => ExpressionDto(
  root: 0,
  nodes: [
    ExpressionNodeDto(
      kind: ExpressionKindDto.field,
      field: FieldReferenceDto(kind: kind, id: id),
    ),
  ],
);

QueryDefinitionDto _query(
  String collectionId,
  String name,
  AggregationDto aggregation, {
  int order = 0,
}) => QueryDefinitionDto(
  id: '',
  collectionId: collectionId,
  name: name,
  queryVersion: 1,
  query: CollectionQueryDto(
    collectionId: collectionId,
    shape: QueryShapeDto(
      kind: QueryShapeKindDto.scalar,
      aggregation: aggregation,
      fields: const [],
    ),
    sorting: const [],
    calendar: const CalendarPolicyDto(
      timezone: 'UTC',
      weekStart: WeekStartDto.monday,
    ),
  ),
  order: order,
  deleted: false,
);

final class Headaches {
  Headaches(this.bridge, this.controller, this.collectionId);
  final FakeCollectionBridge bridge;
  final CollectionsController controller;
  final String collectionId;

  String id(String name) =>
      controller.queryDefinitions.firstWhere((item) => item.name == name).id;

  List<String> get queryNames =>
      controller.queryDefinitions.map((item) => item.name).toList();
}

/// Headaches with Start at, End at (optional) and Note, a Duration computed field
/// `End at − Start at`, the saved queries "Headache hours" (sum of Duration, used by one widget)
/// and "Record count" (unused), and the queries sheet open.
Future<Headaches> openSheet(WidgetTester tester) async {
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1200, 1000);
  final bridge = FakeCollectionBridge()
    ..bootstrap = const BootstrapDto(
      kind: BootstrapKindDto.ready,
      rootId: 'root',
    );
  final controller = CollectionsController(bridge);
  addTearDown(controller.dispose);
  await controller.start();
  final collectionId = await controller.createCollection('Headaches');
  await controller.selectCollection(collectionId);
  await controller.addField(_field('Start at', FieldTypeKindDto.dateTime));
  await controller.addField(
    _field('End at', FieldTypeKindDto.dateTime, required: false, order: 1),
  );
  await controller.addField(_field('Note', FieldTypeKindDto.text, order: 2));
  String fieldId(String name) =>
      controller.schema!.fields.firstWhere((field) => field.name == name).id;
  final durationId = await bridge.createComputedField(
    ComputedFieldDefinitionDto(
      id: '',
      collectionId: collectionId,
      name: 'Duration',
      declaredType: const ValueTypeDto(kind: ValueTypeKindDto.duration),
      nullable: true,
      expressionVersion: 1,
      expression: ExpressionDto(
        root: 2,
        nodes: [
          ExpressionNodeDto(
            kind: ExpressionKindDto.field,
            field: FieldReferenceDto(
              kind: FieldReferenceKindDto.source,
              id: fieldId('End at'),
            ),
          ),
          ExpressionNodeDto(
            kind: ExpressionKindDto.field,
            field: FieldReferenceDto(
              kind: FieldReferenceKindDto.source,
              id: fieldId('Start at'),
            ),
          ),
          const ExpressionNodeDto(
            kind: ExpressionKindDto.arithmetic,
            arithmeticOperator: ArithmeticOperatorDto.subtract,
            left: 0,
            right: 1,
          ),
        ],
      ),
      order: 0,
      deleted: false,
    ),
  );
  await controller.refresh();
  final hoursId = await controller.createQueryDefinition(
    _query(
      collectionId,
      'Headache hours',
      AggregationDto(
        kind: AggregationKindDto.sum,
        expression: _single(FieldReferenceKindDto.computed, durationId),
      ),
    ),
  );
  await controller.createQueryDefinition(
    _query(
      collectionId,
      'Record count',
      const AggregationDto(kind: AggregationKindDto.count),
      order: 1,
    ),
  );
  await controller.createWidget(
    WidgetDefinitionDto(
      id: '',
      collectionId: collectionId,
      widgetType: 'core.aggregate-number',
      queryId: hoursId,
      title: 'Hours',
      configuration: WidgetConfigurationDto(version: 1, body: _emptyMap()),
      layout: WidgetLayoutDto(
        version: 1,
        size: WidgetSizeDto.medium,
        hints: _emptyMap(),
      ),
      order: 0,
      deleted: false,
    ),
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: nocturneTheme(),
      home: Scaffold(
        body: ListenableBuilder(
          listenable: controller,
          builder: (context, _) => CollectionsPage(controller: controller),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('Queries'));
  await tester.pumpAndSettle();
  return Headaches(bridge, controller, collectionId);
}

void main() {
  group('queryResultType', () {
    final schema = CollectionSchemaDto(
      id: 'c',
      name: 'Ledger',
      description: '',
      fields: [
        _field(
          'Amount',
          FieldTypeKindDto.fixedDecimal,
          scale: 2,
        ).copyWithId('amount'),
      ],
    );
    QueryDefinitionDto query(AggregationDto aggregation) =>
        _query('c', 'q', aggregation);

    test('Count is an Integer', () {
      expect(
        queryResultType(
          query(const AggregationDto(kind: AggregationKindDto.count)),
          schema,
        ),
        const ValueTypeDto(kind: ValueTypeKindDto.integer),
      );
    });

    test('Sum, Min and Max take the operand type', () {
      for (final kind in [
        AggregationKindDto.sum,
        AggregationKindDto.min,
        AggregationKindDto.max,
      ]) {
        expect(
          queryResultType(
            query(
              AggregationDto(
                kind: kind,
                expression: _single(FieldReferenceKindDto.source, 'amount'),
              ),
            ),
            schema,
          ),
          const ValueTypeDto(kind: ValueTypeKindDto.fixedDecimal, scale: 2),
          reason: kind.name,
        );
      }
    });

    test('Average is a decimal at the output scale', () {
      expect(
        queryResultType(
          query(
            AggregationDto(
              kind: AggregationKindDto.average,
              expression: _single(FieldReferenceKindDto.source, 'amount'),
              outputScale: 4,
              rounding: RoundingPolicyDto.halfEven,
            ),
          ),
          schema,
        ),
        const ValueTypeDto(kind: ValueTypeKindDto.fixedDecimal, scale: 4),
      );
    });

    test('a computed operand takes its declared type', () {
      expect(
        queryResultType(
          query(
            AggregationDto(
              kind: AggregationKindDto.sum,
              expression: _single(FieldReferenceKindDto.computed, 'span'),
            ),
          ),
          schema,
          [
            const ComputedFieldDefinitionDto(
              id: 'span',
              collectionId: 'c',
              name: 'Span',
              declaredType: ValueTypeDto(kind: ValueTypeKindDto.duration),
              nullable: false,
              expressionVersion: 1,
              order: 0,
              deleted: false,
            ),
          ],
        ),
        const ValueTypeDto(kind: ValueTypeKindDto.duration),
      );
    });
  });

  group('formulaText', () {
    final schema = CollectionSchemaDto(
      id: 'c',
      name: 'Headaches',
      description: '',
      fields: [
        _field('Start at', FieldTypeKindDto.dateTime).copyWithId('start'),
        _field('End at', FieldTypeKindDto.dateTime).copyWithId('end'),
      ],
    );

    test('a subtraction reads with field names and the operator symbol', () {
      expect(
        formulaText(
          const BinaryNode(
            operator: ExprOperator.subtract,
            left: FieldLeaf('end'),
            right: FieldLeaf('start'),
          ),
          schema,
        ),
        'End at − Start at',
      );
    });

    test(
      'a left chain stays flat and a nested right side is parenthesized',
      () {
        expect(
          formulaText(
            const BinaryNode(
              operator: ExprOperator.add,
              left: BinaryNode(
                operator: ExprOperator.subtract,
                left: FieldLeaf('end'),
                right: FieldLeaf('start'),
              ),
              right: AbsNode(
                BinaryNode(
                  operator: ExprOperator.multiply,
                  left: ConstantLeaf(text: '2'),
                  right: FieldLeaf('start'),
                ),
              ),
            ),
            schema,
          ),
          'End at − Start at + abs(2 × Start at)',
        );
      },
    );
  });

  testWidgets('rows show the result type tag and the formula', (tester) async {
    final sheet = await openSheet(tester);
    Finder row(String name) =>
        find.byKey(ValueKey('saved-query-${sheet.id(name)}'));
    expect(
      find.descendant(
        of: row('Headache hours'),
        matching: find.text('Duration'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: row('Record count'), matching: find.text('Integer')),
      findsOneWidget,
    );
    expect(find.text('End at − Start at'), findsOneWidget);
  });

  testWidgets('Add query opens the editor and creates nothing on cancel', (
    tester,
  ) async {
    final sheet = await openSheet(tester);
    expect(find.text('Add record-count query'), findsNothing);
    await tester.tap(find.byKey(const Key('add-query')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('query-editor')), findsOneWidget);
    expect(find.text('New query'), findsOneWidget);
    expect(
      tester
          .widget<EditableText>(
            find.descendant(
              of: find.byKey(const Key('query-name')),
              matching: find.byType(EditableText),
            ),
          )
          .controller
          .text,
      isEmpty,
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(sheet.queryNames, ['Headache hours', 'Record count']);

    // Saving creates it.
    await tester.tap(find.byKey(const Key('add-query')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('query-name')), 'Episodes');
    await tester.pump();
    await tester.tap(find.byKey(const Key('save-query')));
    await tester.pumpAndSettle();
    expect(sheet.queryNames, contains('Episodes'));
  });

  testWidgets('deleting a referenced query asks first', (tester) async {
    final sheet = await openSheet(tester);
    final hours = sheet.id('Headache hours');
    await tester.tap(find.byKey(ValueKey('delete-query-$hours')));
    await tester.pumpAndSettle();
    expect(find.text('Delete query “Headache hours”?'), findsOneWidget);
    expect(
      find.text('1 widget uses it and will show an error until you edit it.'),
      findsOneWidget,
    );
    expect(
      tester.getCenter(find.byKey(const Key('confirm-delete-query'))).dx,
      lessThan(tester.getCenter(find.byKey(const Key('keep-query'))).dx),
    );
    await tester.tap(find.byKey(const Key('keep-query')));
    await tester.pumpAndSettle();
    expect(sheet.queryNames, contains('Headache hours'));
    expect(sheet.controller.widgetDefinitions.single.queryId, hours);

    await tester.tap(find.byKey(ValueKey('delete-query-$hours')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-delete-query')));
    await tester.pumpAndSettle();
    expect(sheet.queryNames, ['Record count']);
  });

  testWidgets('an unreferenced query is deleted without asking', (
    tester,
  ) async {
    final sheet = await openSheet(tester);
    await tester.tap(
      find.byKey(ValueKey('delete-query-${sheet.id('Record count')}')),
    );
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(sheet.queryNames, ['Headache hours']);
  });

  testWidgets('the query editor shows usage, the filter row and Result now', (
    tester,
  ) async {
    final sheet = await openSheet(tester);
    sheet.bridge.nextQueryResult = QueryResultDto(
      kind: QueryResultKindDto.scalar,
      value: TypedValueDto(
        valueType: const ValueTypeDto(kind: ValueTypeKindDto.duration),
        integerValue: const Duration(hours: 5, minutes: 30).inMilliseconds,
      ),
      points: const [],
      categoryPoints: const [],
      records: const [],
    );
    final count = sheet.id('Record count');
    await tester.tap(find.byKey(ValueKey('edit-query-$count')));
    await tester.pumpAndSettle();
    final editor = find.byKey(const Key('query-editor'));
    expect(
      find.descendant(of: editor, matching: find.text('Used by no widgets')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: editor, matching: find.text('Only records where')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: editor, matching: find.byType(Divider)),
      findsNothing,
    );
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(const Key('query-result-now')),
        matching: find.text('5h 30m'),
      ),
      findsOneWidget,
    );
    expect(find.text('Result now'), findsOneWidget);

    // An incomplete builder hides the line.
    await tester.tap(find.byKey(const Key('aggregation')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sum').last);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('query-result-now')), findsNothing);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    // A query that cannot run hides the line.
    sheet.bridge.nextError = const BridgeError(
      kind: BridgeErrorKind.validation,
      issues: [],
      message: 'query failed',
      resetResolvable: false,
    );
    await tester.tap(find.byKey(ValueKey('edit-query-$count')));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('query-result-now')), findsNothing);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(ValueKey('edit-query-${sheet.id('Headache hours')}')),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('Used by 1 widget · changes apply there too'),
      findsOneWidget,
    );
  });
}

extension on FieldDefinitionDto {
  FieldDefinitionDto copyWithId(String id) => FieldDefinitionDto(
    id: id,
    name: name,
    fieldType: fieldType,
    required_: required_,
    validation: validation,
    display: display,
    order: order,
    deleted: deleted,
    enumOptions: enumOptions,
  );
}
