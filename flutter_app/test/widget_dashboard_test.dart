import 'package:fi/collections_page.dart';
import 'package:fi/controllers.dart';
import 'package:fi/src/rust/api/models.dart';
import 'package:fi/theme/fi_icons.dart';
import 'package:fi/widgets/widget_renderers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_bridge.dart';

final class Seeded {
  Seeded(this.bridge, this.controller, this.collectionId, this.queryId);

  final FakeCollectionBridge bridge;
  final CollectionsController controller;
  final String collectionId;
  final String queryId;

  void dispose() => controller.dispose();
}

FieldDefinitionDto _field(
  String name,
  FieldTypeKindDto kind, {
  int order = 0,
  int? scale,
}) => FieldDefinitionDto(
  id: '',
  name: name,
  fieldType: FieldTypeDto(kind: kind, scale: scale),
  required_: true,
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

WidgetDefinitionDto _widget({
  required String collectionId,
  required String queryId,
  required String title,
  String type = 'core.aggregate-number',
  WidgetSizeDto size = WidgetSizeDto.medium,
  int order = 0,
}) => WidgetDefinitionDto(
  id: '',
  collectionId: collectionId,
  widgetType: type,
  queryId: queryId,
  title: title,
  configuration: WidgetConfigurationDto(version: 1, body: _map(const {})),
  layout: WidgetLayoutDto(version: 1, size: size, hints: _map(const {})),
  order: order,
  deleted: false,
);

/// A Headache collection with two records, one saved scalar query, and the page pumped at [size].
Future<Seeded> seed(
  WidgetTester tester, {
  Size size = const Size(1200, 1000),
  void Function(FakeCollectionBridge)? configure,
}) async {
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;

  final bridge = FakeCollectionBridge()
    ..bootstrap = const BootstrapDto(
      kind: BootstrapKindDto.ready,
      rootId: 'root',
    )
    // Widgets evaluate to a real scalar so tiles show a value rather than the empty state.
    ..nextQueryResult = QueryResultDto(
      kind: QueryResultKindDto.scalar,
      value: TypedValueDto(
        valueType: const ValueTypeDto(kind: ValueTypeKindDto.integer),
        integerValue: 1,
      ),
      valueType: const ValueTypeDto(kind: ValueTypeKindDto.integer),
      points: const [],
      categoryPoints: const [],
      records: const [],
    );
  configure?.call(bridge);
  final controller = CollectionsController(bridge);
  addTearDown(controller.dispose);
  await controller.start();
  final collectionId = await controller.createCollection('Headaches');
  await controller.selectCollection(collectionId);
  await controller.addField(
    _field('Intensity', FieldTypeKindDto.integer, order: 0),
  );
  await controller.addField(
    _field('Started at', FieldTypeKindDto.dateTime, order: 1),
  );
  final intensityId = controller.schema!.fields.first.id;
  await controller.createRecord([
    RecordValueDto(
      fieldId: intensityId,
      value: const FieldValueDto(
        kind: FieldValueKindDto.integer,
        integerValue: 7,
      ),
    ),
  ]);
  final queryId = await controller.createQueryDefinition(
    QueryDefinitionDto(
      id: '',
      collectionId: collectionId,
      name: 'Record count',
      queryVersion: 1,
      query: CollectionQueryDto(
        collectionId: collectionId,
        shape: const QueryShapeDto(
          kind: QueryShapeKindDto.scalar,
          aggregation: AggregationDto(kind: AggregationKindDto.count),
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
    ),
  );
  return Seeded(bridge, controller, collectionId, queryId);
}

Future<void> pumpPage(
  WidgetTester tester,
  CollectionsController controller,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ListenableBuilder(
          listenable: controller,
          builder: (context, _) => CollectionsPage(controller: controller),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> pumpUntilFound(WidgetTester tester, Finder finder) async {
  for (var attempt = 0; attempt < 40; attempt++) {
    await tester.pump(const Duration(milliseconds: 50));
    if (finder.evaluate().isNotEmpty) return;
  }
  fail('Timed out waiting for $finder.');
}

/// Tiles flow left-to-right then top-to-bottom, so order is compared in reading order rather than
/// by vertical position alone.
void expectReadingOrder(WidgetTester tester, Finder before, Finder after) {
  final first = tester.getTopLeft(before);
  final second = tester.getTopLeft(after);
  expect(
    first.dy < second.dy || (first.dy == second.dy && first.dx < second.dx),
    isTrue,
    reason: '$first should precede $second in reading order',
  );
}

void main() {
  testWidgets(
    'the dashboard renders widgets in order without displacing records',
    (tester) async {
      final seeded = await seed(tester);
      await seeded.controller.createWidget(
        _widget(
          collectionId: seeded.collectionId,
          queryId: seeded.queryId,
          title: 'First',
          order: 0,
        ),
      );
      await seeded.controller.createWidget(
        _widget(
          collectionId: seeded.collectionId,
          queryId: seeded.queryId,
          title: 'Second',
          order: 1,
        ),
      );
      await pumpPage(tester, seeded.controller);

      expect(find.text('DASHBOARD'), findsOneWidget);
      expect(find.text('First'), findsOneWidget);
      expect(find.text('Second'), findsOneWidget);
      // Deterministic order: the first widget precedes the second.
      expectReadingOrder(tester, find.text('First'), find.text('Second'));
      // Record CRUD is still present alongside the dashboard.
      expect(find.text('New record'), findsOneWidget);
      expect(find.text('Schema'), findsOneWidget);
      expect(find.text('Queries'), findsOneWidget);
      expect(find.text('7'), findsWidgets);
      expect(find.byTooltip('Record actions'), findsOneWidget);
    },
  );

  testWidgets('an empty dashboard still offers the add action', (tester) async {
    final seeded = await seed(tester);
    await pumpPage(tester, seeded.controller);
    expect(
      find.text('No widgets yet. Add one to summarize this collection.'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('add-widget')), findsOneWidget);
    expect(find.text('New record'), findsOneWidget);
  });

  testWidgets('the same dashboard reflows between narrow and wide screens', (
    tester,
  ) async {
    Future<(double, double, double)> layoutTwoMediumTiles(Size size) async {
      final seeded = await seed(tester, size: size);
      for (var i = 0; i < 2; i++) {
        await seeded.controller.createWidget(
          _widget(
            collectionId: seeded.collectionId,
            queryId: seeded.queryId,
            title: 'Tile $i',
            size: WidgetSizeDto.medium,
            order: i,
          ),
        );
      }
      await pumpPage(tester, seeded.controller);
      final ids = seeded.controller.widgetDefinitions
          .map((item) => ValueKey('widget-${item.id}'))
          .toList();
      final first = tester.getRect(find.byKey(ids[0]));
      final second = tester.getRect(find.byKey(ids[1]));
      return (first.width, first.top, second.top);
    }

    // Narrow Android: a medium tile fills the row and the two tiles stack vertically.
    final (narrowWidth, narrowFirstTop, narrowSecondTop) =
        await layoutTwoMediumTiles(const Size(420, 1200));
    expect(narrowWidth, closeTo(388, 1));
    expect(narrowSecondTop, greaterThan(narrowFirstTop));

    // Wide Linux Wayland window: the same hint spans two of four columns, side by side.
    final (wideWidth, wideFirstTop, wideSecondTop) = await layoutTwoMediumTiles(
      const Size(1400, 1200),
    );
    expect(wideWidth, closeTo((1400 - 64 - 36) / 2 + 12, 1));
    expect(wideFirstTop, wideSecondTop);
    expect(wideWidth, greaterThan(narrowWidth));

    // Records stay reachable on the narrow screen, where the header collapses to icons.
    final narrow = await seed(tester, size: const Size(420, 1200));
    await pumpPage(tester, narrow.controller);
    expect(find.byTooltip('New record'), findsOneWidget);
    expect(find.byTooltip('Schema'), findsOneWidget);
    expect(find.text('New record'), findsNothing);
    // Queries moves into the phone header's ⋮ menu.
    await tester.tap(find.byKey(const Key('collection-more')));
    await tester.pumpAndSettle();
    expect(find.text('Queries'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the guided flow creates a typed query and widget separately', (
    tester,
  ) async {
    final seeded = await seed(tester);
    await pumpPage(tester, seeded.controller);
    final queriesBefore =
        seeded.bridge.queryDefinitions[seeded.collectionId]!.length;

    await tester.tap(find.byKey(const Key('add-widget')));
    await pumpUntilFound(tester, find.byKey(const Key('widget-type')));
    // Save stays enabled; nothing shows until it is pressed, then the blocker sits under the
    // input it belongs to and clears as soon as it is fixed.
    expect(find.text('Give the widget a title.'), findsNothing);
    await tester.tap(find.byKey(const Key('save-widget')));
    await tester.pumpAndSettle();
    expect(find.text('Give the widget a title.'), findsOneWidget);
    expect(find.byKey(const Key('widget-editor-error')), findsNothing);
    expect(
      seeded.bridge.widgetDefinitions[seeded.collectionId] ?? const [],
      isEmpty,
    );
    await tester.enterText(
      find.byKey(const Key('widget-title')),
      'Headache count',
    );
    await tester.pumpAndSettle();
    expect(find.text('Give the widget a title.'), findsNothing);

    // A count aggregation needs no operand field, so the form is already complete.
    expect(find.byKey(const Key('aggregation')), findsOneWidget);
    await tester.tap(find.byKey(const Key('save-widget')));
    await pumpUntilFound(tester, find.text('Headache count'));
    await tester.pumpAndSettle();

    final definitions = seeded.bridge.widgetDefinitions[seeded.collectionId]!;
    expect(definitions, hasLength(1));
    expect(definitions.single.widgetType, 'core.aggregate-number');
    expect(definitions.single.title, 'Headache count');
    // The query is its own synchronized definition, separate from the presentation config.
    final queries = seeded.bridge.queryDefinitions[seeded.collectionId]!;
    expect(queries, hasLength(queriesBefore + 1));
    expect(definitions.single.queryId, queries.last.id);
    expect(queries.last.query!.shape.kind, QueryShapeKindDto.scalar);
    expect(
      definitions.single.configuration.body.kind,
      StructuredValueKindDto.map,
    );
  });

  testWidgets(
    'the guided flow builds a bucketed chart query with an exact policy',
    (tester) async {
      final seeded = await seed(tester);
      await pumpPage(tester, seeded.controller);

      await tester.tap(find.byKey(const Key('add-widget')));
      await pumpUntilFound(tester, find.byKey(const Key('widget-type')));
      await tester.tap(find.byKey(const Key('widget-type')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Line chart').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('widget-title')),
        'Monthly intensity',
      );

      await tester.tap(find.byKey(const Key('bucket-period')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Month').last);
      await tester.pumpAndSettle();

      // The period field dropdown now only offers Date/DateTime fields.
      await tester.tap(
        find.byKey(const ValueKey('category-field-BucketPeriodDto.month')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Started at').last);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('aggregation')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Average').last);
      await tester.pumpAndSettle();
      // Average exposes the explicit numeric policy instead of inventing a rounding rule.
      expect(find.byKey(const Key('output-scale')), findsOneWidget);
      expect(find.byKey(const Key('rounding')), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('operand-field-AggregationKindDto.average')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Intensity').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('config-axis-label')),
        'Intensity',
      );

      await tester.tap(find.byKey(const Key('save-widget')));
      await pumpUntilFound(tester, find.text('Monthly intensity'));
      await tester.pumpAndSettle();

      final query = seeded.bridge.queryDefinitions[seeded.collectionId]!.last;
      expect(query.query!.shape.kind, QueryShapeKindDto.categorySeries);
      expect(query.query!.grouping?.period, BucketPeriodDto.month);
      expect(query.query!.shape.aggregation?.kind, AggregationKindDto.average);
      expect(query.query!.shape.aggregation?.outputScale, 2);
      expect(
        query.query!.shape.aggregation?.rounding,
        RoundingPolicyDto.halfEven,
      );
      final definition =
          seeded.bridge.widgetDefinitions[seeded.collectionId]!.single;
      expect(definition.queryId, query.id);
      // Presentation is stored separately from the query.
      final entries = {
        for (final entry in definition.configuration.body.entries)
          entry.key: entry.value,
      };
      expect(entries['y_axis_label']?.textValue, 'Intensity');
      expect(entries['show_points']?.booleanValue, isFalse);
    },
  );

  testWidgets('Rust validation errors surface inside the widget dialog', (
    tester,
  ) async {
    final seeded = await seed(tester);
    await pumpPage(tester, seeded.controller);
    await tester.tap(find.byKey(const Key('add-widget')));
    await pumpUntilFound(tester, find.byKey(const Key('widget-title')));
    await tester.enterText(find.byKey(const Key('widget-title')), 'Rejected');
    // Reuse the seeded query so the rejected write is the widget command itself.
    await tester.tap(find.byKey(const Key('query-source-saved')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('saved-query')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Record count').last);
    await tester.pumpAndSettle();
    seeded.bridge.nextError = const BridgeError(
      kind: BridgeErrorKind.validation,
      issues: [
        BridgeIssueDto(
          fields: ['query_id'],
          code: 'invalid',
          message:
              'returns a record set result but core.aggregate-number accepts scalar',
        ),
      ],
      message:
          'returns a record set result but core.aggregate-number accepts scalar',
      resetResolvable: false,
    );
    await tester.tap(find.byKey(const Key('save-widget')));
    final message = find.textContaining('core.aggregate-number accepts scalar');
    await pumpUntilFound(tester, message);
    expect(message, findsOneWidget);
    // The issue names the query, so it sits under the saved-query selector, not the form slot.
    expect(
      find.descendant(
        of: find.byKey(const Key('saved-query')),
        matching: message,
      ),
      findsOneWidget,
    );
    expect(find.byKey(const Key('widget-editor-error')), findsNothing);
    // The dialog stays open and nothing was written.
    expect(find.byKey(const Key('widget-title')), findsOneWidget);
    expect(
      seeded.bridge.widgetDefinitions[seeded.collectionId] ?? const [],
      isEmpty,
    );
  });

  testWidgets('a Widgets domain event refreshes definitions and evaluations', (
    tester,
  ) async {
    final seeded = await seed(tester);
    await seeded.controller.createWidget(
      _widget(
        collectionId: seeded.collectionId,
        queryId: seeded.queryId,
        title: 'Before',
      ),
    );
    await pumpPage(tester, seeded.controller);
    expect(find.text('Before'), findsOneWidget);

    // Another device renames the widget and synchronization advances the local projection.
    final id = seeded.controller.widgetDefinitions.single.id;
    final items = seeded.bridge.widgetDefinitions[seeded.collectionId]!;
    items[0] = WidgetDefinitionDto(
      id: id,
      collectionId: seeded.collectionId,
      widgetType: items[0].widgetType,
      queryId: items[0].queryId,
      title: 'After',
      configuration: items[0].configuration,
      layout: items[0].layout,
      order: 0,
      deleted: false,
    );
    final evaluationsBefore = seeded.bridge.evaluationsRequested;
    seeded.bridge.changedWidgets(seeded.collectionId);
    await pumpUntilFound(tester, find.text('After'));
    expect(find.text('Before'), findsNothing);
    // One invalidation triggered exactly one evaluation cycle, not one per widget.
    expect(seeded.bridge.evaluationsRequested, evaluationsBefore + 1);
    expect(seeded.bridge.evaluatedCollections.last, seeded.collectionId);
  });

  testWidgets('one refresh cycle evaluates the dashboard once', (tester) async {
    final seeded = await seed(tester);
    for (var i = 0; i < 3; i++) {
      await seeded.controller.createWidget(
        _widget(
          collectionId: seeded.collectionId,
          queryId: seeded.queryId,
          title: 'Widget $i',
          order: i,
        ),
      );
    }
    await pumpPage(tester, seeded.controller);
    final before = seeded.bridge.evaluationsRequested;
    await seeded.controller.refresh();
    await tester.pumpAndSettle();
    // Three widgets referencing the same query still cost one bridge round trip; duplicate query
    // evaluation is deduplicated by query ID inside that call.
    expect(seeded.bridge.evaluationsRequested, before + 1);
    expect(seeded.controller.widgetEvaluations, hasLength(3));
  });

  testWidgets('an unsupported widget shows a placeholder and only safe edits', (
    tester,
  ) async {
    final seeded = await seed(
      tester,
      // Simulate a build whose renderer registry lacks this type.
      configure: (bridge) => bridge.descriptors = bridge.descriptors
          .where(
            (descriptor) => descriptor.widgetType != 'core.aggregate-number',
          )
          .toList(),
    );
    await seeded.controller.createWidget(
      WidgetDefinitionDto(
        id: '',
        collectionId: seeded.collectionId,
        widgetType: 'com.example.calendar-heatmap',
        queryId: seeded.queryId,
        title: 'Heatmap',
        configuration: WidgetConfigurationDto(
          version: 9,
          body: _map({'palette': _text('heat')}),
        ),
        layout: WidgetLayoutDto(
          version: 1,
          size: WidgetSizeDto.medium,
          hints: _map(const {}),
        ),
        order: 0,
        deleted: false,
      ),
    );
    await pumpPage(tester, seeded.controller);

    expect(find.byType(UnsupportedWidgetPlaceholder), findsOneWidget);
    expect(find.text('com.example.calendar-heatmap'), findsOneWidget);
    // The evaluation is a typed per-widget error, and the tile still shows it in place.
    expect(
      seeded.controller
          .evaluationFor(seeded.controller.widgetDefinitions.single.id)
          ?.errorKind,
      WidgetErrorKindDto.unsupportedType,
    );

    // Editing offers title and size but no type choice and no presentation fields.
    await tester.tap(find.text('Heatmap'));
    await pumpUntilFound(tester, find.byKey(const Key('widget-title')));
    expect(find.byKey(const Key('widget-type')), findsNothing);
    expect(find.byKey(const Key('config-suffix')), findsNothing);
    expect(find.textContaining('preserved untouched'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('widget-title')),
      'Renamed heatmap',
    );
    await tester.tap(find.byKey(const Key('save-widget')));
    await pumpUntilFound(tester, find.text('Renamed heatmap'));
    await tester.pumpAndSettle();

    final preserved =
        seeded.bridge.widgetDefinitions[seeded.collectionId]!.single;
    expect(preserved.title, 'Renamed heatmap');
    // The opaque configuration survived a metadata-only edit.
    expect(preserved.configuration.version, 9);
    expect(preserved.configuration.body.entries.single.key, 'palette');
    expect(preserved.configuration.body.entries.single.value.textValue, 'heat');
    expect(preserved.widgetType, 'com.example.calendar-heatmap');
  });

  testWidgets('sizes span one to four columns wide and stack on a phone', (
    tester,
  ) async {
    Future<List<Rect>> layout(Size size) async {
      final seeded = await seed(tester, size: size);
      for (final (index, widgetSize) in [
        WidgetSizeDto.small,
        WidgetSizeDto.medium,
        WidgetSizeDto.large,
      ].indexed) {
        await seeded.controller.createWidget(
          _widget(
            collectionId: seeded.collectionId,
            queryId: seeded.queryId,
            title: 'Tile $index',
            size: widgetSize,
            order: index,
          ),
        );
      }
      await pumpPage(tester, seeded.controller);
      return [
        for (final item in seeded.controller.widgetDefinitions)
          tester.getRect(find.byKey(ValueKey('widget-${item.id}'))),
      ];
    }

    // A 1064px window holds a 1000px dashboard: four 241px columns.
    final wide = await layout(const Size(1064, 1000));
    const column = (1000 - 36) / 4;
    expect(wide[0].width, closeTo(column, 1));
    expect(wide[1].width, closeTo(2 * column + 12, 1));
    expect(wide[2].width, closeTo(3 * column + 24, 1));
    // Small and Medium share the first row; Large wraps to the next.
    expect(wide[0].top, wide[1].top);
    expect(wide[2].top, greaterThan(wide[0].bottom));

    // Phone: one full-width tile per row, same order.
    final phone = await layout(const Size(390, 1600));
    for (final rect in phone) {
      expect(rect.width, closeTo(phone.first.width, .5));
    }
    expect(phone[1].top, greaterThan(phone[0].bottom));
    expect(phone[2].top, greaterThan(phone[1].bottom));
  });

  testWidgets(
    'the tile menu offers edit, reorder and remove on a wide screen',
    (tester) async {
      final seeded = await seed(tester);
      await seeded.controller.createWidget(
        _widget(
          collectionId: seeded.collectionId,
          queryId: seeded.queryId,
          title: 'Alpha',
        ),
      );
      await pumpPage(tester, seeded.controller);

      await tester.tap(find.byKey(const Key('widget-menu')));
      await tester.pumpAndSettle();
      expect(find.text('Edit widget'), findsOneWidget);
      expect(find.text('Remove…'), findsOneWidget);
      // One widget: nothing to reorder.
      expect(
        tester
            .widget<PopupMenuItem<Object?>>(
              find.byKey(const Key('widget-menu-reorder')),
            )
            .enabled,
        isFalse,
      );

      await tester.tap(find.text('Edit widget'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('widget-title')), findsOneWidget);
    },
  );

  testWidgets(
    'on a phone the tile menu is an action sheet headed by the title',
    (tester) async {
      final seeded = await seed(tester, size: const Size(390, 1200));
      for (final (index, title) in ['Level over time', 'Avg level'].indexed) {
        await seeded.controller.createWidget(
          _widget(
            collectionId: seeded.collectionId,
            queryId: seeded.queryId,
            title: title,
            order: index,
          ),
        );
      }
      await pumpPage(tester, seeded.controller);

      await tester.tap(find.byKey(const Key('widget-menu')).first);
      await tester.pumpAndSettle();
      final sheet = find.byType(BottomSheet);
      expect(sheet, findsOneWidget);
      for (final label in [
        'Level over time',
        'Edit widget',
        'Reorder',
        'Remove…',
      ]) {
        expect(
          find.descendant(of: sheet, matching: find.text(label)),
          findsOneWidget,
          reason: label,
        );
      }

      await tester.tap(
        find.descendant(of: sheet, matching: find.text('Reorder')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('reorder-done')), findsOneWidget);
      // Phone reorder controls are full touch targets.
      expect(
        tester.getSize(find.byKey(const Key('widget-move-down')).first),
        const Size(44, 44),
      );
    },
  );

  testWidgets('Remove… asks first and only Remove removes the widget', (
    tester,
  ) async {
    final seeded = await seed(tester);
    await seeded.controller.createWidget(
      _widget(
        collectionId: seeded.collectionId,
        queryId: seeded.queryId,
        title: 'Alpha',
      ),
    );
    await pumpPage(tester, seeded.controller);

    Future<void> chooseRemove() async {
      await tester.tap(find.byKey(const Key('widget-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove…'));
      await tester.pumpAndSettle();
      expect(find.text('Remove widget “Alpha”?'), findsOneWidget);
      expect(
        find.text('Its saved query and the records stay.'),
        findsOneWidget,
      );
    }

    await chooseRemove();
    // Remove sits left of the primary Keep widget.
    expect(
      tester.getCenter(find.byKey(const Key('confirm-remove-widget'))).dx,
      lessThan(tester.getCenter(find.byKey(const Key('keep-widget'))).dx),
    );
    await tester.tap(find.byKey(const Key('keep-widget')));
    await tester.pumpAndSettle();
    expect(seeded.controller.widgetDefinitions, hasLength(1));

    await chooseRemove();
    await tester.tap(find.byKey(const Key('confirm-remove-widget')));
    await tester.pumpAndSettle();
    expect(seeded.controller.widgetDefinitions, isEmpty);
    expect(find.text('Alpha'), findsNothing);
    // The saved query stays.
    expect(
      seeded.controller.queryDefinitions.map((item) => item.id),
      contains(seeded.queryId),
    );
  });

  testWidgets('reorder mode moves widgets in place with disabled edges', (
    tester,
  ) async {
    final seeded = await seed(tester);
    for (final (index, title) in [
      'Avg level',
      'Level over time',
      'Episodes by type',
    ].indexed) {
      await seeded.controller.createWidget(
        _widget(
          collectionId: seeded.collectionId,
          queryId: seeded.queryId,
          title: title,
          order: index,
        ),
      );
    }
    await pumpPage(tester, seeded.controller);
    List<String> titles() =>
        seeded.controller.widgetDefinitions.map((item) => item.title).toList();
    Finder controls(String title, String key) {
      final id = seeded.controller.widgetDefinitions
          .firstWhere((item) => item.title == title)
          .id;
      return find.descendant(
        of: find.byKey(Key('reorder-controls-$id')),
        matching: find.byKey(Key(key)),
      );
    }

    bool enabled(Finder finder) =>
        tester
            .widget<IconButton>(
              find.descendant(of: finder, matching: find.byType(IconButton)),
            )
            .onPressed !=
        null;

    await tester.tap(find.byKey(const Key('reorder-widgets')));
    await tester.pumpAndSettle();
    // No dialog: Done replaces Reorder and Add widget in the header.
    expect(find.byType(Dialog), findsNothing);
    expect(find.byKey(const Key('reorder-done')), findsOneWidget);
    expect(find.byKey(const Key('reorder-widgets')), findsNothing);
    expect(find.byKey(const Key('add-widget')), findsNothing);
    expect(find.byKey(const Key('widget-drag-handle')), findsNWidgets(3));

    // Edges are disabled.
    expect(enabled(controls('Avg level', 'widget-move-up')), isFalse);
    expect(enabled(controls('Avg level', 'widget-move-down')), isTrue);
    expect(enabled(controls('Episodes by type', 'widget-move-down')), isFalse);

    // Tile taps are inert.
    await tester.tap(find.text('Level over time'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('widget-title')), findsNothing);

    await tester.tap(controls('Avg level', 'widget-move-down'));
    await tester.pumpAndSettle();
    expect(titles(), ['Level over time', 'Avg level', 'Episodes by type']);

    await tester.tap(find.byKey(const Key('reorder-done')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('reorder-done')), findsNothing);
    expect(titles(), ['Level over time', 'Avg level', 'Episodes by type']);
    expectReadingOrder(
      tester,
      find.text('Level over time'),
      find.text('Avg level'),
    );
  });

  testWidgets('dragging a handle in reorder mode moves the widget', (
    tester,
  ) async {
    final seeded = await seed(tester);
    for (final (index, title) in ['Alpha', 'Beta'].indexed) {
      await seeded.controller.createWidget(
        _widget(
          collectionId: seeded.collectionId,
          queryId: seeded.queryId,
          title: title,
          order: index,
        ),
      );
    }
    await pumpPage(tester, seeded.controller);
    await tester.tap(find.byKey(const Key('reorder-widgets')));
    await tester.pumpAndSettle();

    final betaId = seeded.controller.widgetDefinitions.last.id;
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('widget-drag-handle')).first),
    );
    await gesture.moveTo(
      tester.getCenter(find.byKey(ValueKey('widget-$betaId'))),
    );
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(
      seeded.controller.widgetDefinitions.map((item) => item.title).toList(),
      ['Beta', 'Alpha'],
    );
  });

  testWidgets('the editor remove action asks the same confirmation', (
    tester,
  ) async {
    final seeded = await seed(tester);
    await seeded.controller.createWidget(
      _widget(
        collectionId: seeded.collectionId,
        queryId: seeded.queryId,
        title: 'Beta',
      ),
    );
    await pumpPage(tester, seeded.controller);

    await tester.tap(find.text('Beta'));
    await pumpUntilFound(tester, find.byKey(const Key('remove-widget')));
    await tester.tap(find.byKey(const Key('remove-widget')));
    await tester.pumpAndSettle();
    expect(find.text('Remove widget “Beta”?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('keep-widget')));
    await tester.pumpAndSettle();
    expect(seeded.controller.widgetDefinitions, hasLength(1));
    // Keep leaves the editor open.
    expect(find.byKey(const Key('widget-title')), findsOneWidget);

    await tester.tap(find.byKey(const Key('remove-widget')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-remove-widget')));
    await tester.pumpAndSettle();
    expect(seeded.controller.widgetDefinitions, isEmpty);
    expect(find.byKey(const Key('widget-title')), findsNothing);
    expect(find.text('Beta'), findsNothing);
  });

  testWidgets(
    'editing a saved query in place keeps the widget referencing it',
    (tester) async {
      final seeded = await seed(tester);
      await seeded.controller.createWidget(
        _widget(
          collectionId: seeded.collectionId,
          queryId: seeded.queryId,
          title: 'Count',
        ),
      );
      await pumpPage(tester, seeded.controller);
      final widgetId = seeded.controller.widgetDefinitions.single.id;
      final queriesBefore =
          seeded.bridge.queryDefinitions[seeded.collectionId]!.length;

      await tester.tap(find.text('Count'));
      await pumpUntilFound(tester, find.byKey(const Key('edit-saved-query')));
      // The propagation is disclosed where the decision is made.
      expect(find.text('Used by 1 widget'), findsOneWidget);

      await tester.tap(find.byKey(const Key('edit-saved-query')));
      await pumpUntilFound(tester, find.byKey(const Key('query-editor')));
      expect(find.byKey(const Key('query-editor-usage')), findsOneWidget);
      await tester.tap(find.byKey(const Key('aggregation')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sum').last);
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('operand-field-AggregationKindDto.sum')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Intensity').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('save-query')));
      await tester.pumpAndSettle();

      final queries = seeded.bridge.queryDefinitions[seeded.collectionId]!;
      // An edit is an update, not a new definition.
      expect(queries, hasLength(queriesBefore));
      final edited = queries.firstWhere((item) => item.id == seeded.queryId);
      expect(edited.query!.shape.aggregation?.kind, AggregationKindDto.sum);
      expect(
        seeded.bridge.widgetDefinitions[seeded.collectionId]!
            .firstWhere((item) => item.id == widgetId)
            .queryId,
        seeded.queryId,
      );
    },
  );

  testWidgets('save as new leaves the original query alone', (tester) async {
    final seeded = await seed(tester);
    await seeded.controller.createWidget(
      _widget(
        collectionId: seeded.collectionId,
        queryId: seeded.queryId,
        title: 'Count',
      ),
    );
    await pumpPage(tester, seeded.controller);
    final queriesBefore =
        seeded.bridge.queryDefinitions[seeded.collectionId]!.length;

    await tester.tap(find.text('Count'));
    await pumpUntilFound(tester, find.byKey(const Key('save-query-as-new')));
    await tester.tap(find.byKey(const Key('save-query-as-new')));
    await pumpUntilFound(tester, find.byKey(const Key('query-editor')));
    await tester.tap(find.byKey(const Key('aggregation')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sum').last);
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('operand-field-AggregationKindDto.sum')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Intensity').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save-query')));
    await tester.pumpAndSettle();

    final queries = seeded.bridge.queryDefinitions[seeded.collectionId]!;
    expect(queries, hasLength(queriesBefore + 1));
    final original = queries.firstWhere((item) => item.id == seeded.queryId);
    expect(original.query!.shape.aggregation?.kind, AggregationKindDto.count);

    // Saving the widget now points it at the copy.
    await tester.tap(find.byKey(const Key('save-widget')));
    await tester.pumpAndSettle();
    expect(
      seeded.bridge.widgetDefinitions[seeded.collectionId]!.single.queryId,
      queries.last.id,
    );
  });

  testWidgets('a query the builder cannot read stays read-only and deletable', (
    tester,
  ) async {
    final seeded = await seed(tester);
    await seeded.bridge.createQueryDefinition(
      QueryDefinitionDto(
        id: '',
        collectionId: seeded.collectionId,
        name: 'Made elsewhere',
        queryVersion: 1,
        query: CollectionQueryDto(
          collectionId: seeded.collectionId,
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
        order: 1,
        deleted: false,
      ),
    );
    await seeded.controller.refresh();
    await pumpPage(tester, seeded.controller);

    await tester.tap(find.text('Queries'));
    await pumpUntilFound(tester, find.text('Made elsewhere'));
    // The sheet slides in; wait for it to rest before tapping inside it.
    await tester.pumpAndSettle();
    final unreadable = seeded.controller.queryDefinitions
        .firstWhere((item) => item.name == 'Made elsewhere')
        .id;
    // Delete stays available even for a query this build cannot edit.
    expect(find.byTooltip('Remove query'), findsNWidgets(2));

    await tester.tap(find.byKey(ValueKey('edit-query-$unreadable')));
    await pumpUntilFound(tester, find.byKey(const Key('query-editor')));
    expect(find.byKey(const Key('query-editor-readonly')), findsOneWidget);
    expect(find.byKey(const Key('save-query')), findsNothing);
  });

  testWidgets('the Daily total preset makes a line chart submittable', (
    tester,
  ) async {
    final seeded = await seed(tester);
    await pumpPage(tester, seeded.controller);

    await tester.tap(find.byKey(const Key('add-widget')));
    await pumpUntilFound(tester, find.byKey(const Key('widget-type')));
    await tester.tap(find.byKey(const Key('widget-type')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Line chart').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('widget-title')), 'Daily');

    // Group by and the aggregation controls are on screen before any period is chosen.
    expect(find.byKey(const Key('bucket-period')), findsOneWidget);
    expect(find.byKey(const Key('aggregation')), findsOneWidget);
    expect(find.text('Choose a Group by period to aggregate'), findsOneWidget);

    await tester.tap(find.byKey(const Key('preset-dailyTotal')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('save-widget')));
    await pumpUntilFound(tester, find.text('Daily'));
    await tester.pumpAndSettle();

    final query = seeded.bridge.queryDefinitions[seeded.collectionId]!.last;
    expect(query.query!.shape.kind, QueryShapeKindDto.categorySeries);
    expect(query.query!.grouping?.period, BucketPeriodDto.day);
    expect(query.query!.shape.aggregation?.kind, AggregationKindDto.sum);
  });

  testWidgets('on a phone the widget editor is a bottom sheet with a preview', (
    tester,
  ) async {
    final seeded = await seed(tester, size: const Size(390, 844));
    await pumpPage(tester, seeded.controller);

    await tester.tap(find.byKey(const Key('add-widget')));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.byType(Dialog), findsNothing);
    // The preview sits in the form flow after Size, not pinned above the buttons.
    expect(find.text('PREVIEW'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('PREVIEW')).dy,
      greaterThan(tester.getTopLeft(find.byKey(const Key('widget-size'))).dy),
    );
    // The footer holds only Cancel and Add widget.
    final footerButtons = find.descendant(
      of: find.byType(BottomSheet),
      matching: find.byWidgetPredicate(
        (widget) => widget is OutlinedButton || widget is FilledButton,
      ),
    );
    expect(footerButtons, findsNWidgets(2));
    expect(
      find.descendant(
        of: find.byKey(const Key('save-widget')),
        matching: find.text('Add widget'),
      ),
      findsOneWidget,
    );
    await tester.enterText(find.byKey(const Key('widget-title')), 'Pain');
    await tester.pump();
    expect(find.text('Pain'), findsWidgets);
    // Cancel (1 part) beside the primary (2 parts), both 48px tall.
    final cancel = tester.getSize(
      find.widgetWithText(OutlinedButton, 'Cancel'),
    );
    final save = tester.getSize(find.byKey(const Key('save-widget')));
    expect(cancel.height, 48);
    expect(save.height, 48);
    expect(save.width, closeTo(cancel.width * 2 + 10, 12));
    expect(tester.takeException(), isNull);
  });

  testWidgets('on a phone Remove is an icon button in the sheet title row', (
    tester,
  ) async {
    final seeded = await seed(tester, size: const Size(390, 844));
    await seeded.controller.createWidget(
      _widget(
        collectionId: seeded.collectionId,
        queryId: seeded.queryId,
        title: 'Alpha',
      ),
    );
    await pumpPage(tester, seeded.controller);

    await tester.tap(find.text('Alpha'));
    await tester.pumpAndSettle();
    final remove = find.byKey(const Key('remove-widget'));
    expect(remove, findsOneWidget);
    expect(tester.widget(remove), isA<IconButton>());
    expect(find.byTooltip('Remove widget'), findsOneWidget);
    // Same row as the title, above the body.
    expect(
      tester.getCenter(remove).dy,
      closeTo(tester.getCenter(find.text('Edit widget')).dy, 12),
    );
    expect(find.widgetWithText(TextButton, 'Remove'), findsNothing);

    await tester.tap(remove);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-remove-widget')));
    await tester.pumpAndSettle();
    expect(seeded.controller.widgetDefinitions, isEmpty);
  });

  testWidgets('on a wide screen the widget editor is two panes', (
    tester,
  ) async {
    final seeded = await seed(tester, size: const Size(1280, 800));
    await seeded.controller.createWidget(
      _widget(
        collectionId: seeded.collectionId,
        queryId: seeded.queryId,
        title: 'Alpha',
      ),
    );
    await pumpPage(tester, seeded.controller);

    await tester.tap(find.text('Alpha'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);
    // The preview pane sits beside the form, not below it.
    final preview = tester.getRect(find.text('PREVIEW'));
    final title = tester.getRect(find.byKey(const Key('widget-title')));
    expect(preview.left, greaterThan(title.right));
    // The size hint under the preview states the four-column span.
    expect(find.text('Medium spans 2 of 4 columns.'), findsOneWidget);
    expect(
      tester.widget(find.byKey(const Key('remove-widget'))),
      isA<TextButton>(),
    );
    expect(
      tester.getTopLeft(find.byKey(const Key('remove-widget'))).dx,
      lessThan(tester.getTopLeft(find.widgetWithText(TextButton, 'Cancel')).dx),
    );
  });

  testWidgets('the widget editor picks a type from icon tiles', (tester) async {
    final seeded = await seed(tester);
    await pumpPage(tester, seeded.controller);
    await tester.tap(find.byKey(const Key('add-widget')));
    await pumpUntilFound(tester, find.byKey(const Key('widget-type')));

    for (final type in [
      'core.aggregate-number',
      'core.line-chart',
      'core.bar-chart',
      'core.scatter-plot',
    ]) {
      expect(find.byKey(Key('widget-type-$type')), findsOneWidget);
    }
    // Four tiles share one row on a wide screen.
    expect(
      tester
          .getTopLeft(find.byKey(const Key('widget-type-core.scatter-plot')))
          .dy,
      tester
          .getTopLeft(
            find.byKey(const Key('widget-type-core.aggregate-number')),
          )
          .dy,
    );
    // The number type has no Group by; a bar chart does.
    expect(find.byKey(const Key('bucket-period')), findsNothing);
    await tester.tap(find.byKey(const Key('widget-type-core.bar-chart')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('bucket-period')), findsOneWidget);
    expect(
      tester
          .widget<Semantics>(
            find
                .ancestor(
                  of: find.byKey(const Key('widget-type-core.bar-chart')),
                  matching: find.byType(Semantics),
                )
                .first,
          )
          .properties
          .selected,
      isTrue,
    );
  });

  testWidgets('saved-query controls appear only under Use a saved query', (
    tester,
  ) async {
    final seeded = await seed(tester);
    await pumpPage(tester, seeded.controller);
    await tester.tap(find.byKey(const Key('add-widget')));
    await pumpUntilFound(tester, find.byKey(const Key('query-source')));

    // Define here is the default for a new widget.
    expect(find.byKey(const Key('saved-query')), findsNothing);
    expect(find.byKey(const Key('aggregation')), findsOneWidget);

    await tester.tap(find.byKey(const Key('query-source-saved')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('saved-query')), findsOneWidget);
    expect(find.byKey(const Key('aggregation')), findsNothing);
    await tester.tap(find.byKey(const Key('saved-query')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Record count').last);
    await tester.pumpAndSettle();
    expect(find.text('Edit this query'), findsOneWidget);
    expect(find.text('Save as new'), findsOneWidget);

    await tester.tap(find.byKey(const Key('query-source-define')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('saved-query')), findsNothing);
    expect(find.text('Edit this query'), findsNothing);
    expect(find.text('Save as new'), findsNothing);
  });

  testWidgets('the widget form is grouped under Data and Presentation', (
    tester,
  ) async {
    final seeded = await seed(tester);
    await pumpPage(tester, seeded.controller);
    await tester.tap(find.byKey(const Key('add-widget')));
    await pumpUntilFound(tester, find.byKey(const Key('widget-type')));

    expect(find.text('DATA'), findsOneWidget);
    expect(find.text('PRESENTATION'), findsOneWidget);
    expect(
      find.descendant(of: find.byType(Dialog), matching: find.byType(Divider)),
      findsNothing,
    );
    double top(Finder finder) => tester.getTopLeft(finder).dy;
    expect(
      top(find.text('DATA')),
      lessThan(top(find.byKey(const Key('query-source')))),
    );
    expect(
      top(find.byKey(const Key('aggregation'))),
      lessThan(top(find.text('PRESENTATION'))),
    );
    // Size sits in Presentation.
    expect(
      top(find.text('PRESENTATION')),
      lessThan(top(find.byKey(const Key('widget-size')))),
    );
  });

  testWidgets('the widget form shows the filter as a removable chip', (
    tester,
  ) async {
    final seeded = await seed(tester);
    await pumpPage(tester, seeded.controller);
    await tester.tap(find.byKey(const Key('add-widget')));
    await pumpUntilFound(tester, find.byKey(const Key('add-filter')));

    expect(find.byKey(const Key('filter-field')), findsNothing);
    await tester.tap(find.byKey(const Key('add-filter')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('add-filter')), findsNothing);
    await tester.tap(find.byKey(const Key('filter-field')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Intensity').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('filter-value')), '7');
    await tester.pump();
    await tester.tap(find.byKey(const Key('apply-filter')));
    await tester.pumpAndSettle();

    expect(find.text('Intensity is 7'), findsOneWidget);
    expect(find.byKey(const Key('filter-field')), findsNothing);
    // One condition at most: Add filter hides while it exists.
    expect(find.byKey(const Key('add-filter')), findsNothing);

    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('filter-chip')),
        matching: find.byIcon(FiIcons.clear),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Intensity is 7'), findsNothing);
    expect(find.byKey(const Key('add-filter')), findsOneWidget);
  });
}
