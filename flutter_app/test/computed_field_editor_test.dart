import 'package:fi/collections_page.dart';
import 'package:fi/controllers.dart';
import 'package:fi/help_copy.dart';
import 'package:fi/src/rust/api/models.dart';
import 'package:fi/theme/nocturne.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_bridge.dart';

FieldDefinitionDto _field(
  String name,
  FieldTypeKindDto kind, {
  int? scale,
  bool required = true,
  int order = 0,
}) => FieldDefinitionDto(
  id: '',
  name: name,
  fieldType: FieldTypeDto(kind: kind, scale: scale),
  required_: required,
  validation: const ValidationMetadataDto(),
  display: const DisplayMetadataDto(multiline: false),
  order: order,
  deleted: false,
  enumOptions: const [],
);

final class Ledger {
  Ledger(this.bridge, this.controller, this.collectionId);
  final FakeCollectionBridge bridge;
  final CollectionsController controller;
  final String collectionId;

  String fieldId(String name) =>
      controller.schema!.fields.firstWhere((field) => field.name == name).id;

  List<ComputedFieldDefinitionDto> get computed =>
      bridge.computedFields[collectionId] ?? const [];
}

/// A ledger with a required scale-2 `Amount` and an optional scale-3 `Rate`, with the page shown
/// and the "Computed fields & queries" sheet open.
Future<Ledger> openDialog(
  WidgetTester tester, {
  Future<void> Function(Ledger)? seed,
  Size size = const Size(1200, 1000),
}) async {
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  final bridge = FakeCollectionBridge()
    ..bootstrap = const BootstrapDto(
      kind: BootstrapKindDto.ready,
      rootId: 'root',
    );
  final controller = CollectionsController(bridge);
  addTearDown(controller.dispose);
  await controller.start();
  final collectionId = await controller.createCollection('Ledger');
  await controller.selectCollection(collectionId);
  await controller.addField(
    _field('Amount', FieldTypeKindDto.fixedDecimal, scale: 2),
  );
  await controller.addField(
    _field(
      'Rate',
      FieldTypeKindDto.fixedDecimal,
      scale: 3,
      required: false,
      order: 1,
    ),
  );
  final ledger = Ledger(bridge, controller, collectionId);
  await seed?.call(ledger);
  await controller.refresh();
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
  await tester.pump();
  // Wide layouts label the button; narrow ones show an icon with the same tooltip.
  final queries = find.text('Queries');
  await tester.tap(
    queries.evaluate().isEmpty ? find.byTooltip('Queries') : queries,
  );
  await settle(tester);
  return ledger;
}

/// The outlined box height of the input keyed [key].
double boxHeight(WidgetTester tester, Key key) => tester
    .getSize(
      find
          .descendant(
            of: find.byKey(key),
            matching: find.byType(InputDecorator),
          )
          .first,
    )
    .height;

/// Lets the inference debounce fire and the fake answer land.
Future<void> settle(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 200));
  await tester.pumpAndSettle();
}

Future<String> seedMagnitude(Ledger ledger) =>
    ledger.bridge.createComputedField(
      ComputedFieldDefinitionDto(
        id: '',
        collectionId: ledger.collectionId,
        name: 'Magnitude',
        declaredType: const ValueTypeDto(
          kind: ValueTypeKindDto.fixedDecimal,
          scale: 2,
        ),
        nullable: false,
        expressionVersion: 1,
        expression: ExpressionDto(
          root: 1,
          nodes: [
            ExpressionNodeDto(
              kind: ExpressionKindDto.field,
              field: FieldReferenceDto(
                kind: FieldReferenceKindDto.source,
                id: ledger.fieldId('Amount'),
              ),
            ),
            const ExpressionNodeDto(kind: ExpressionKindDto.abs, expression: 0),
          ],
        ),
        order: 0,
        deleted: false,
      ),
    );

void main() {
  testWidgets('building amount × rate saves the type Rust inferred', (
    tester,
  ) async {
    final ledger = await openDialog(tester);
    expect(find.text('Add absolute-value field'), findsNothing);

    await tester.tap(find.byKey(const Key('add-computed-field')));
    await settle(tester);
    expect(find.byKey(const Key('computed-editor')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('computed-name')), 'Cost');
    await tester.tap(find.byKey(const Key(r'add-operator-$')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('operator-multiply')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key(r'field-$.right')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rate').last);
    await settle(tester);

    expect(
      find.text('Result: Decimal, scale 5 · may be empty'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('save-computed')));
    await settle(tester);

    expect(find.byKey(const Key('computed-editor')), findsNothing);
    final saved = ledger.computed.single;
    expect(saved.name, 'Cost');
    expect(
      saved.declaredType,
      const ValueTypeDto(kind: ValueTypeKindDto.fixedDecimal, scale: 5),
    );
    expect(saved.nullable, isTrue);
    final root = saved.expression!.nodes[saved.expression!.root];
    expect(root.kind, ExpressionKindDto.arithmetic);
    expect(root.arithmeticOperator, ArithmeticOperatorDto.multiply);
  });

  testWidgets(
    'mismatched scales keep Save disabled with the Rust error on the node',
    (tester) async {
      await openDialog(tester);
      await tester.tap(find.byKey(const Key('add-computed-field')));
      await settle(tester);
      await tester.enterText(find.byKey(const Key('computed-name')), 'Sum');
      await tester.tap(find.byKey(const Key(r'add-operator-$')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('operator-add')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key(r'field-$.right')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rate').last);
      await settle(tester);

      expect(find.byKey(const Key(r'expr-error-$')), findsOneWidget);
      expect(find.text('arithmetic operands are incompatible'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('save-computed')))
            .onPressed,
        isNull,
      );
    },
  );

  testWidgets('tapping a computed field edits it in place under the same id', (
    tester,
  ) async {
    late String id;
    final ledger = await openDialog(
      tester,
      seed: (ledger) async => id = await seedMagnitude(ledger),
    );

    await tester.tap(find.byKey(ValueKey('computed-$id')));
    await settle(tester);
    expect(find.byKey(const Key('computed-editor')), findsOneWidget);
    expect(find.text('Magnitude'), findsWidgets);
    expect(find.byKey(const Key(r'expr-node-$.expression')), findsOneWidget);

    await tester.enterText(find.byKey(const Key('computed-name')), 'Size');
    // Replace abs(amount) with amount − 1.00.
    await tester.tap(find.byKey(const Key(r'unabs-$')));
    await settle(tester);
    await tester.tap(find.byKey(const Key(r'add-operator-$')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('operator-subtract')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Number').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key(r'constant-$.right')), '1');
    await settle(tester);
    await tester.tap(find.byKey(const Key('save-computed')));
    await settle(tester);

    final saved = ledger.computed.single;
    expect(saved.id, id);
    expect(saved.name, 'Size');
    final root = saved.expression!.nodes[saved.expression!.root];
    expect(root.arithmeticOperator, ArithmeticOperatorDto.subtract);
    // The constant took the sibling's scale (D4), so `1` is 1.00 exactly.
    final constant = saved.expression!.nodes[root.right!].value!;
    expect(constant.valueType.scale, 2);
    expect(constant.integerValue, 100);
  });

  testWidgets('an unsupported definition is listed but does not open', (
    tester,
  ) async {
    late String id;
    await openDialog(
      tester,
      seed: (ledger) async => id = await ledger.bridge.createComputedField(
        ComputedFieldDefinitionDto(
          id: '',
          collectionId: ledger.collectionId,
          name: 'From the future',
          declaredType: const ValueTypeDto(kind: ValueTypeKindDto.integer),
          nullable: false,
          expressionVersion: 9,
          unsupportedBodyJson: '{"future":"node"}',
          order: 0,
          deleted: false,
        ),
      ),
    );

    expect(find.textContaining('not editable here'), findsOneWidget);
    await tester.tap(find.byKey(ValueKey('computed-$id')));
    await settle(tester);
    expect(find.byKey(const Key('computed-editor')), findsNothing);
  });

  testWidgets('the explainer opens from the "?" beside Computed fields', (
    tester,
  ) async {
    await openDialog(tester);
    await tester.tap(find.byKey(Key('help-${HelpId.computedFields.name}')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('help-dialog')), findsOneWidget);
    expect(find.text(helpCopy[HelpId.computedFields]!.body), findsOneWidget);
    await tester.tap(find.byKey(const Key('help-close')));
    await tester.pumpAndSettle();
    expect(find.text('Computed fields & queries'), findsOneWidget);
  });

  testWidgets('on a phone the editor is a form-surface bottom sheet', (
    tester,
  ) async {
    await openDialog(tester, size: const Size(390, 844));
    await tester.tap(find.byKey(const Key('add-computed-field')));
    await settle(tester);

    final editor = find.byKey(const Key('computed-editor'));
    expect(editor, findsOneWidget);
    expect(
      find.ancestor(of: editor, matching: find.byType(BottomSheet)),
      findsOneWidget,
    );
    expect(find.byType(Dialog), findsNothing);
    expect(find.text('New computed field'), findsOneWidget);
    expect(find.text('in Ledger'), findsOneWidget);
    expect(
      find.descendant(
        of: editor,
        matching: find.widgetWithText(OutlinedButton, 'Cancel'),
      ),
      findsOneWidget,
    );
    expect(tester.getSize(find.byKey(const Key('save-computed'))).height, 48);
    // Phone inputs take their height from the tokens: normal 48, small 40.
    expect(boxHeight(tester, const Key('computed-name')), 48);
    expect(boxHeight(tester, const Key(r'field-$')), 40);
  });

  testWidgets('on desktop editing opens a form-surface dialog', (tester) async {
    late String id;
    await openDialog(
      tester,
      size: const Size(1280, 900),
      seed: (ledger) async => id = await seedMagnitude(ledger),
    );
    await tester.tap(find.byKey(ValueKey('computed-$id')));
    await settle(tester);

    final editor = find.byKey(const Key('computed-editor'));
    expect(
      find.descendant(of: editor, matching: find.byType(Dialog)),
      findsOneWidget,
    );
    expect(find.text('Edit computed field'), findsOneWidget);
    final cancel = find.descendant(
      of: editor,
      matching: find.widgetWithText(TextButton, 'Cancel'),
    );
    final save = find.byKey(const Key('save-computed'));
    expect(cancel, findsOneWidget);
    // Cancel then Save, right-aligned.
    expect(
      tester.getTopRight(save).dx,
      greaterThan(tester.getTopRight(cancel).dx),
    );
    expect(
      tester.getTopRight(save).dx,
      // Flush with the inputs' right edge.
      tester.getTopRight(find.byKey(const Key('computed-name'))).dx,
    );
    // Name is a normal input; the node's select is small.
    expect(boxHeight(tester, const Key('computed-name')), 40);
    expect(boxHeight(tester, const Key(r'field-$.expression')), 32);
  });
}
