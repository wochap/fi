import 'package:fi/src/rust/api/models.dart';
import 'package:fi/theme/fi_icons.dart';
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
  display: const DisplayMetadataDto(
    multiline: false,
    slider: false,
    sliderStep: null,
  ),
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
    _field('End at', FieldTypeKindDto.dateTime),
    _field('Note', FieldTypeKindDto.text),
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

  test('a left-deep + − × chain flattens into terms and rebuilds', () {
    const tree = BinaryNode(
      operator: ExprOperator.add,
      left: BinaryNode(
        operator: ExprOperator.subtract,
        left: FieldLeaf('a'),
        right: AbsNode(FieldLeaf('b')),
      ),
      right: BinaryNode(
        operator: ExprOperator.subtract,
        left: FieldLeaf('c'),
        right: FieldLeaf('a'),
      ),
    );
    final chain = flattenChain(tree);
    expect(chain.terms.map(describe), ['a', 'abs(b)', '(c subtract a)']);
    expect(chain.operators, [ExprOperator.subtract, ExprOperator.add]);
    expect(describe(buildChain(chain.terms, chain.operators)), describe(tree));
    expect(termPath(0, 3), r'$.left.left');
    expect(termPath(1, 3), r'$.left.right');
    expect(termPath(2, 3), r'$.right');
  });

  test('reordering three terms keeps the operators in their slots', () {
    const tree = BinaryNode(
      operator: ExprOperator.multiply,
      left: BinaryNode(
        operator: ExprOperator.subtract,
        left: FieldLeaf('a'),
        right: FieldLeaf('b'),
      ),
      right: FieldLeaf('c'),
    );
    expect(describe(reorderTerms(tree, 2, 0)), '((c subtract a) multiply b)');
    expect(describe(reorderTerms(tree, 0, 2)), '((b subtract c) multiply a)');
  });

  test('formulaText reads field names and operator symbols', () {
    expect(
      formulaText(
        const BinaryNode(
          operator: ExprOperator.subtract,
          left: FieldLeaf('date_a'),
          right: FieldLeaf('date_b'),
        ),
        schema,
      ),
      'date_a − date_b',
    );
  });

  testWidgets('End at − Start at shows as two term cards and round-trips', (
    tester,
  ) async {
    const tree = BinaryNode(
      operator: ExprOperator.subtract,
      left: FieldLeaf('date_a'),
      right: FieldLeaf('date_b'),
    );
    ExpressionDto? submitted;
    await pumpBuilder(
      tester,
      tree,
      infer: (expression) async {
        submitted = expression;
        return const InferredTypeDto(
          valueType: ValueTypeDto(kind: ValueTypeKindDto.duration),
          nullable: false,
        );
      },
    );
    expect(find.byKey(const Key('expr-term-0')), findsOneWidget);
    expect(find.byKey(const Key('expr-term-1')), findsOneWidget);
    expect(find.byKey(const Key('term-operator-0')), findsNothing);
    expect(find.byKey(const Key('term-operator-1')), findsOneWidget);
    expect(describe(expressionFromDto(submitted!)!), describe(tree));
  });

  testWidgets('Add term is disabled at the depth cap', (tester) async {
    await pumpBuilder(tester, chain(maxOperatorDepth - 1));
    TextButton addTerm() =>
        tester.widget<TextButton>(find.byKey(const Key('add-term')));
    expect(addTerm().onPressed, isNotNull);
    await tester.ensureVisible(find.byKey(const Key('add-term')));
    await tester.tap(find.byKey(const Key('add-term')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(Key('expr-term-$maxOperatorDepth'), skipOffstage: false),
      findsOneWidget,
    );
    expect(addTerm().onPressed, isNull);
  });

  testWidgets('Function wraps a term in abs and Divide carries its policy', (
    tester,
  ) async {
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
    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('term-kind-0')),
        matching: find.text('Function'),
      ),
    );
    await tester.pumpAndSettle();
    expect(describe(expressionFromDto(submitted!)!), 'abs(a)');

    await tester.tap(find.byKey(const Key('term-function-0')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Divide').last);
    await tester.pumpAndSettle();
    // The new right leaf starts empty; D3: the output scale follows the left operand.
    expect(find.byKey(const Key(r'expr-error-$.right')), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const Key(r'scale-$'))).data, '2');

    await tester.tap(find.byKey(const Key(r'field-$.right')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('c').last);
    await tester.pumpAndSettle();
    expect(describe(expressionFromDto(submitted!)!), '(a / c @2 halfEven)');

    await tester.tap(find.text('Reject inexact'));
    await tester.pumpAndSettle();
    expect(
      describe(expressionFromDto(submitted!)!),
      '(a / c @2 rejectInexact)',
    );
    expect(find.byKey(const Key('computed-result-ok')), findsOneWidget);
  });

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

    // The failing `a + c` node maps to its right-hand term, c.
    expect(
      tester.widget<Text>(find.byKey(const Key('expr-error-term-1'))).data,
      "Can't add a Integer to a Decimal, scale 2.",
    );
    expect(find.byKey(const Key('expr-error-term-2')), findsNothing);
    expect(find.byKey(const Key('computed-result')), findsNothing);
    final save = tester.widget<FilledButton>(
      find.byKey(const Key('save-computed')),
    );
    expect(save.onPressed, isNull);
  });

  testWidgets('End at − Note marks Note with a localized sentence', (
    tester,
  ) async {
    await pumpBuilder(
      tester,
      const BinaryNode(
        operator: ExprOperator.subtract,
        left: FieldLeaf('End at'),
        right: FieldLeaf('Note'),
      ),
      infer: (_) async => throw const BridgeError(
        kind: BridgeErrorKind.validation,
        issues: [
          BridgeIssueDto(
            fields: [r'$'],
            code: 'invalid',
            message: 'arithmetic operands are incompatible',
          ),
        ],
        message: 'arithmetic operands are incompatible',
        resetResolvable: false,
      ),
    );
    expect(
      tester.widget<Text>(find.byKey(const Key('expr-error-term-1'))).data,
      "Can't subtract a Text from a Date & time.",
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('expr-term-1')),
        matching: find.byIcon(FiIcons.warning),
      ),
      findsOneWidget,
    );
    expect(find.byKey(const Key('computed-result')), findsNothing);
  });
}
