import 'package:fi/src/rust/api/models.dart';
import 'package:fi/widgets/computed_field_editor.dart';
import 'package:fi/widgets/expression_builder.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

FieldDefinitionDto _field(
  String id,
  FieldTypeKindDto kind, {
  int? scale,
  bool required = true,
}) => FieldDefinitionDto(
  id: id,
  name: id,
  fieldType: FieldTypeDto(kind: kind, scale: scale),
  required_: required,
  validation: const ValidationMetadataDto(),
  display: const DisplayMetadataDto(multiline: false, slider: false),
  order: 0,
  deleted: false,
  enumOptions: const [],
);

final schema = CollectionSchemaDto(
  id: 'collection',
  description: '',
  name: 'Ledger',
  fields: [
    _field('a', FieldTypeKindDto.fixedDecimal, scale: 2),
    _field('b', FieldTypeKindDto.fixedDecimal, scale: 2),
    _field('c', FieldTypeKindDto.integer),
    _field('date_a', FieldTypeKindDto.date),
    _field('date_b', FieldTypeKindDto.date),
  ],
);

/// A structural rendering of a tree, so trees compare by shape rather than identity.
String describe(ExprNode node) => switch (node) {
  FieldLeaf(:final fieldId) => '$fieldId',
  ConstantLeaf(:final text, :final scale) => '#$text@${scale ?? 'int'}',
  AbsNode(:final child) => 'abs(${describe(child)})',
  BinaryNode(
    :final operator,
    :final left,
    :final right,
    :final outputScale,
    :final rounding,
  ) =>
    operator == ExprOperator.divide
        ? '(${describe(left)} / ${describe(right)} @$outputScale ${rounding.name})'
        : '(${describe(left)} ${operator.name} ${describe(right)})',
};

ExprNode chain(int depth) => depth == 0
    ? const FieldLeaf('a')
    : BinaryNode(
        operator: ExprOperator.add,
        left: chain(depth - 1),
        right: const FieldLeaf('b'),
      );

Future<void> pumpBuilder(
  WidgetTester tester,
  ExprNode initial, {
  Future<InferredTypeDto> Function(ExpressionDto)? infer,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ExpressionBuilder(
            key: ObjectKey(initial),
            schema: schema,
            initial: initial,
            debounce: Duration.zero,
            infer:
                infer ??
                (_) async => const InferredTypeDto(
                  valueType: ValueTypeDto(
                    kind: ValueTypeKindDto.fixedDecimal,
                    scale: 2,
                  ),
                  nullable: false,
                ),
            onChanged: (_) {},
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  test('trees round-trip through the flat ExpressionDto shape', () {
    final cases = <ExprNode>[
      const AbsNode(FieldLeaf('a')),
      const BinaryNode(
        operator: ExprOperator.multiply,
        left: FieldLeaf('a'),
        right: FieldLeaf('b'),
      ),
      const BinaryNode(
        operator: ExprOperator.divide,
        left: BinaryNode(
          operator: ExprOperator.add,
          left: FieldLeaf('a'),
          right: FieldLeaf('b'),
        ),
        right: FieldLeaf('c'),
        outputScale: 4,
        rounding: RoundingPolicyDto.rejectInexact,
      ),
      const BinaryNode(
        operator: ExprOperator.subtract,
        left: FieldLeaf('date_a'),
        right: FieldLeaf('date_b'),
      ),
      const BinaryNode(
        operator: ExprOperator.multiply,
        left: FieldLeaf('a'),
        right: ConstantLeaf(text: '-1.50', scale: 2),
      ),
    ];
    for (final tree in cases) {
      final dto = expressionToDto(tree)!;
      expect(describe(expressionFromDto(dto)!), describe(tree));
    }

    final divide = expressionToDto(cases[2])!;
    final root = divide.nodes[divide.root];
    expect(root.kind, ExpressionKindDto.divide);
    expect(root.outputScale, 4);
    expect(root.rounding, RoundingPolicyDto.rejectInexact);
    final sum = divide.nodes[root.left!];
    expect(sum.kind, ExpressionKindDto.arithmetic);
    expect(sum.arithmeticOperator, ArithmeticOperatorDto.add);

    final constant = expressionToDto(cases[4])!;
    final value = constant.nodes[constant.nodes[constant.root].right!].value!;
    // Parsed exactly into a scaled integer, never through a double.
    expect(value.integerValue, -150);
    expect(value.valueType.scale, 2);
  });

  test('a stored expression rebuilds the same tree from any node order', () {
    // abs(a) * 2, with the root first and children after it.
    const dto = ExpressionDto(
      root: 0,
      nodes: [
        ExpressionNodeDto(
          kind: ExpressionKindDto.arithmetic,
          arithmeticOperator: ArithmeticOperatorDto.multiply,
          left: 2,
          right: 1,
        ),
        ExpressionNodeDto(
          kind: ExpressionKindDto.constant,
          value: TypedValueDto(
            valueType: ValueTypeDto(kind: ValueTypeKindDto.integer),
            integerValue: 2,
          ),
        ),
        ExpressionNodeDto(kind: ExpressionKindDto.abs, expression: 3),
        ExpressionNodeDto(
          kind: ExpressionKindDto.field,
          field: FieldReferenceDto(kind: FieldReferenceKindDto.source, id: 'a'),
        ),
      ],
    );
    expect(describe(expressionFromDto(dto)!), '(abs(a) multiply #2@int)');

    // Anything the builder does not offer is refused rather than rewritten.
    const compare = ExpressionDto(
      root: 0,
      nodes: [ExpressionNodeDto(kind: ExpressionKindDto.isNull, expression: 0)],
    );
    expect(expressionFromDto(compare), isNull);
  });

  testWidgets('the add-operator affordance disappears at the depth cap', (
    tester,
  ) async {
    await pumpBuilder(tester, chain(maxOperatorDepth - 1));
    final deepest = r'$' + '.left' * (maxOperatorDepth - 1);
    expect(find.byKey(Key('add-operator-$deepest')), findsOneWidget);

    await pumpBuilder(tester, chain(maxOperatorDepth));
    final deepestAtCap = r'$' + '.left' * maxOperatorDepth;
    expect(find.byKey(Key('expr-node-$deepestAtCap')), findsOneWidget);
    expect(find.byKey(Key('add-operator-$deepestAtCap')), findsNothing);
    expect(find.byKey(const Key(r'add-operator-$')), findsNothing);
  });

  testWidgets(
    'choosing an operator wraps a leaf and division carries its policy',
    (tester) async {
      ExpressionDto? submitted;
      await pumpBuilder(
        tester,
        const FieldLeaf('a'),
        infer: (expression) async {
          submitted = expression;
          return const InferredTypeDto(
            valueType: ValueTypeDto(
              kind: ValueTypeKindDto.fixedDecimal,
              scale: 2,
            ),
            nullable: false,
          );
        },
      );
      await tester.tap(find.byKey(const Key(r'add-operator-$')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('operator-divide')));
      await tester.pumpAndSettle();
      // The new right leaf starts empty, so nothing is submitted until it is picked.
      expect(find.byKey(const Key(r'expr-error-$.right')), findsOneWidget);
      expect(find.byKey(const Key(r'scale-$')), findsOneWidget);
      // D3: the default output scale follows a FixedDecimal left operand.
      expect(tester.widget<Text>(find.byKey(const Key(r'scale-$'))).data, '2');

      await tester.tap(find.byKey(const Key(r'field-$.right')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('c').last);
      await tester.pumpAndSettle();
      final root = submitted!.nodes[submitted!.root];
      expect(root.kind, ExpressionKindDto.divide);
      expect(root.outputScale, 2);
      expect(root.rounding, RoundingPolicyDto.halfEven);
      expect(find.text('Result: Decimal, scale 2'), findsOneWidget);

      await tester.tap(find.byKey(const Key(r'remove-$')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key(r'expr-node-$.right')), findsNothing);
      expect(submitted!.nodes[submitted!.root].kind, ExpressionKindDto.field);
    },
  );

  testWidgets('a positional inference error marks its card and blocks Save', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ComputedFieldEditor(
            schema: schema,
            inferenceDebounce: Duration.zero,
            existing: ComputedFieldDefinitionDto(
              id: 'computed-1',
              collectionId: schema.id,
              name: 'Broken',
              declaredType: const ValueTypeDto(kind: ValueTypeKindDto.integer),
              nullable: false,
              expressionVersion: 1,
              expression: expressionToDto(
                const BinaryNode(
                  operator: ExprOperator.add,
                  left: BinaryNode(
                    operator: ExprOperator.add,
                    left: FieldLeaf('a'),
                    right: FieldLeaf('c'),
                  ),
                  right: FieldLeaf('b'),
                ),
              ),
              order: 0,
              deleted: false,
            ),
            infer: (_) async => throw const BridgeError(
              kind: BridgeErrorKind.validation,
              issues: [
                BridgeIssueDto(
                  fields: [r'$.left'],
                  code: 'invalid',
                  message: 'arithmetic operands are incompatible',
                ),
              ],
              message: 'arithmetic operands are incompatible',
              resetResolvable: false,
            ),
            onSave: (_) async => fail('must not save'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester.widget<Text>(find.byKey(const Key(r'expr-error-$.left'))).data,
      'arithmetic operands are incompatible',
    );
    expect(find.byKey(const Key(r'expr-error-$')), findsNothing);
    final save = tester.widget<FilledButton>(
      find.byKey(const Key('save-computed')),
    );
    expect(save.onPressed, isNull);
  });
}
