import 'dart:async';

import 'package:fi/bridge/collection_bridge.dart';
import 'package:fi/controllers.dart';
import 'package:fi/src/rust/api/models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_bridge.dart';

void main() {
  test('controller refreshes generic projection events and CRUD', () async {
    final bridge = FakeCollectionBridge();
    final controller = CollectionsController(bridge);
    await controller.start();
    final id = await controller.createCollection('Headaches');
    expect(controller.collections.single.name, 'Headaches');
    await controller.selectCollection(id);
    expect(controller.schema?.id, id);
    bridge.changed(id);
    await Future<void>.delayed(Duration.zero);
    expect(controller.selectedCollectionId, id);
    controller.dispose();
  });

  test('Rust errors remain visible', () async {
    final bridge = FakeCollectionBridge();
    final controller = CollectionsController(bridge);
    await controller.start();
    bridge.nextError = const BridgeError(
      kind: BridgeErrorKind.validation,
      field: 'name',
      message: 'Name is required.',
      resetResolvable: false,
    );
    await expectLater(
      controller.createCollection(''),
      throwsA(isA<BridgeError>()),
    );
    controller.dispose();
  });

  test('controller drives schema, enum option, and record CRUD', () async {
    final bridge = FakeCollectionBridge();
    final controller = CollectionsController(bridge);
    await controller.start();
    final collection = await controller.createCollection('Symptoms');
    await controller.selectCollection(collection);
    const enumField = FieldDefinitionDto(
      id: '',
      name: 'Severity',
      fieldType: FieldTypeDto(kind: FieldTypeKindDto.enum_),
      required_: true,
      validation: ValidationMetadataDto(),
      display: DisplayMetadataDto(multiline: false),
      order: 0,
      deleted: false,
      enumOptions: [],
    );
    await controller.addField(enumField);
    final fieldId = controller.schema!.fields.single.id;
    await controller.upsertEnumOption(
      fieldId,
      const EnumOptionDto(id: '', label: 'High', order: 0, deleted: false),
    );
    final optionId = controller.schema!.fields.single.enumOptions.single.id;
    await controller.createRecord([
      RecordValueDto(
        fieldId: fieldId,
        value: FieldValueDto(
          kind: FieldValueKindDto.enum_,
          textValue: optionId,
        ),
      ),
    ]);
    expect(controller.records, hasLength(1));
    await controller.updateRecord(controller.records.single.id, [
      RecordValueDto(
        fieldId: fieldId,
        value: FieldValueDto(
          kind: FieldValueKindDto.enum_,
          textValue: optionId,
        ),
      ),
    ]);
    await controller.deleteRecord(controller.records.single.id);
    expect(controller.records, isEmpty);
    await controller.removeEnumOption(fieldId, optionId);
    expect(controller.schema!.fields.single.enumOptions, isEmpty);
    controller.dispose();
  });

  test('controller drives computed field and query definition CRUD', () async {
    final bridge = FakeCollectionBridge();
    final controller = CollectionsController(bridge);
    await controller.start();
    final collection = await controller.createCollection('Headaches');
    await controller.selectCollection(collection);
    const intensity = FieldDefinitionDto(
      id: '',
      name: 'Intensity',
      fieldType: FieldTypeDto(kind: FieldTypeKindDto.integer),
      required_: true,
      validation: ValidationMetadataDto(),
      display: DisplayMetadataDto(multiline: false),
      order: 0,
      deleted: false,
      enumOptions: [],
    );
    await controller.addField(intensity);
    final fieldId = controller.schema!.fields.single.id;
    expect(controller.computedFields, isEmpty);
    expect(controller.queryDefinitions, isEmpty);

    await controller.createComputedField(
      ComputedFieldDefinitionDto(
        id: '',
        collectionId: collection,
        name: 'Absolute intensity',
        declaredType: const ValueTypeDto(kind: ValueTypeKindDto.integer),
        nullable: false,
        expressionVersion: 1,
        expression: ExpressionDto(
          root: 1,
          nodes: [
            ExpressionNodeDto(
              kind: ExpressionKindDto.field,
              field: FieldReferenceDto(
                kind: FieldReferenceKindDto.source,
                id: fieldId,
              ),
            ),
            const ExpressionNodeDto(kind: ExpressionKindDto.abs, expression: 0),
          ],
        ),
        order: 0,
        deleted: false,
      ),
    );
    expect(controller.computedFields.single.name, 'Absolute intensity');

    await controller.createQueryDefinition(
      QueryDefinitionDto(
        id: '',
        collectionId: collection,
        name: 'Record count',
        queryVersion: 1,
        query: CollectionQueryDto(
          collectionId: collection,
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
    expect(controller.queryDefinitions.single.name, 'Record count');

    await controller.removeComputedField(controller.computedFields.single.id);
    expect(controller.computedFields, isEmpty);
    await controller.removeQueryDefinition(
      controller.queryDefinitions.single.id,
    );
    expect(controller.queryDefinitions, isEmpty);
    controller.dispose();
  });

  test(
    'updateComputedField edits in place and surfaces validation failures',
    () async {
      final bridge = FakeCollectionBridge();
      final controller = CollectionsController(bridge);
      await controller.start();
      final collection = await controller.createCollection('Ledger');
      await controller.selectCollection(collection);
      await controller.addField(
        const FieldDefinitionDto(
          id: '',
          name: 'Amount',
          fieldType: FieldTypeDto(
            kind: FieldTypeKindDto.fixedDecimal,
            scale: 2,
          ),
          required_: true,
          validation: ValidationMetadataDto(),
          display: DisplayMetadataDto(multiline: false),
          order: 0,
          deleted: false,
          enumOptions: [],
        ),
      );
      final fieldId = controller.schema!.fields.single.id;
      final amount = ExpressionNodeDto(
        kind: ExpressionKindDto.field,
        field: FieldReferenceDto(
          kind: FieldReferenceKindDto.source,
          id: fieldId,
        ),
      );
      const decimal = ValueTypeDto(
        kind: ValueTypeKindDto.fixedDecimal,
        scale: 2,
      );
      ComputedFieldDefinitionDto definition(
        String id,
        String name,
        ExpressionDto expression,
      ) => ComputedFieldDefinitionDto(
        id: id,
        collectionId: collection,
        name: name,
        declaredType: decimal,
        nullable: false,
        expressionVersion: 1,
        expression: expression,
        order: 0,
        deleted: false,
      );
      await controller.createComputedField(
        definition(
          '',
          'Magnitude',
          ExpressionDto(
            root: 1,
            nodes: [
              amount,
              const ExpressionNodeDto(
                kind: ExpressionKindDto.abs,
                expression: 0,
              ),
            ],
          ),
        ),
      );
      final id = controller.computedFields.single.id;
      final doubled = ExpressionDto(root: 0, nodes: [amount]);

      await controller.updateComputedField(
        definition(id, 'Amount copy', doubled),
      );
      expect(controller.computedFields.single.id, id);
      expect(controller.computedFields.single.name, 'Amount copy');
      expect(controller.computedFields.single.expression, doubled);

      bridge.nextError = const BridgeError(
        kind: BridgeErrorKind.validation,
        field: 'declared_type',
        message: 'does not match inferred expression type',
        resetResolvable: false,
      );
      await expectLater(
        controller.updateComputedField(definition(id, 'Broken', doubled)),
        throwsA(isA<BridgeError>()),
      );
      expect(controller.computedFields.single.name, 'Amount copy');
      controller.dispose();
    },
  );

  test('controller drives widget lifecycle, evaluation, and unknown types', () async {
    final bridge = FakeCollectionBridge();
    final controller = CollectionsController(bridge);
    await controller.start();
    final collection = await controller.createCollection('Money Movement');
    await controller.selectCollection(collection);
    const amount = FieldDefinitionDto(
      id: '',
      name: 'Amount',
      fieldType: FieldTypeDto(kind: FieldTypeKindDto.fixedDecimal, scale: 2),
      required_: true,
      validation: ValidationMetadataDto(),
      display: DisplayMetadataDto(multiline: false),
      order: 0,
      deleted: false,
      enumOptions: [],
    );
    await controller.addField(amount);
    final queryId = await controller.createQueryDefinition(
      QueryDefinitionDto(
        id: '',
        collectionId: collection,
        name: 'Record count',
        queryVersion: 1,
        query: CollectionQueryDto(
          collectionId: collection,
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
    expect(queryId, isNotEmpty);

    // The descriptor registry is loaded once and drives what the UI offers.
    expect(controller.widgetDescriptors, hasLength(4));
    expect(
      controller.descriptorFor('core.aggregate-number')?.supported,
      isTrue,
    );
    expect(controller.descriptorFor('com.example.future-widget'), isNull);

    final balance = WidgetDefinitionDto(
      id: '',
      collectionId: collection,
      widgetType: 'core.aggregate-number',
      queryId: queryId,
      title: 'Balance',
      configuration: WidgetConfigurationDto(
        version: 1,
        body: _map({'suffix': _text('EUR')}),
      ),
      layout: WidgetLayoutDto(
        version: 1,
        size: WidgetSizeDto.medium,
        hints: _map(const {}),
      ),
      order: 0,
      deleted: false,
    );
    await controller.createWidget(balance);
    expect(controller.widgetDefinitions.single.title, 'Balance');
    expect(
      controller.evaluationFor(controller.widgetDefinitions.single.id)?.ready,
      isTrue,
    );

    // A granular update changes only what it names.
    final id = controller.widgetDefinitions.single.id;
    await controller.updateWidget(
      WidgetUpdateDto(
        id: id,
        collectionId: collection,
        title: 'Renamed balance',
        order: 3,
      ),
    );
    final renamed = controller.widgetDefinitions.single;
    expect(renamed.title, 'Renamed balance');
    expect(renamed.order, 3);
    expect(renamed.configuration, balance.configuration);
    expect(renamed.widgetType, 'core.aggregate-number');

    // An unknown widget type is preserved and evaluates to a typed per-widget error.
    final future = WidgetDefinitionDto(
      id: '',
      collectionId: collection,
      widgetType: 'com.example.future-widget',
      queryId: queryId,
      title: 'Future',
      configuration: WidgetConfigurationDto(
        version: 9,
        body: _map({'opaque': _integer(7)}),
      ),
      layout: WidgetLayoutDto(
        version: 1,
        size: WidgetSizeDto.small,
        hints: _map(const {}),
      ),
      order: 1,
      deleted: false,
    );
    await controller.createWidget(future);
    final futureId = controller.widgetDefinitions
        .firstWhere((item) => item.widgetType == 'com.example.future-widget')
        .id;
    final evaluation = controller.evaluationFor(futureId);
    expect(evaluation?.ready, isFalse);
    expect(evaluation?.errorKind, WidgetErrorKindDto.unsupportedType);
    // The other widget still evaluates; one unsupported definition isolates itself.
    expect(controller.evaluationFor(id)?.ready, isTrue);

    // Renaming an unknown widget omits its configuration, so the opaque value is untouched.
    await controller.updateWidget(
      WidgetUpdateDto(
        id: futureId,
        collectionId: collection,
        title: 'Renamed future',
      ),
    );
    final preserved = controller.widgetDefinitions.firstWhere(
      (item) => item.id == futureId,
    );
    expect(preserved.title, 'Renamed future');
    expect(preserved.configuration.version, 9);
    expect(preserved.configuration, future.configuration);
    expect(preserved.widgetType, 'com.example.future-widget');

    await controller.reorderWidgets([futureId, id]);
    expect(controller.widgetDefinitions.map((item) => item.id).toList(), [
      futureId,
      id,
    ]);

    await controller.removeWidget(futureId);
    expect(controller.widgetDefinitions.map((item) => item.id), [id]);
    controller.dispose();
  });

  test('a failing widget evaluation never blanks the record list', () async {
    final bridge = FakeCollectionBridge();
    final controller = CollectionsController(bridge);
    await controller.start();
    final collection = await controller.createCollection('Headaches');
    await controller.selectCollection(collection);
    await controller.createRecord(const []);
    expect(controller.records, hasLength(1));

    // The widget layer fails while records keep loading.
    bridge.nextError = const BridgeError(
      kind: BridgeErrorKind.projection,
      message: 'projection is not ready',
      resetResolvable: false,
    );
    await controller.refresh();
    expect(controller.errorMessage, 'projection is not ready');
    controller.dispose();
  });

  test('evaluation errors stay isolated from definitions and records', () async {
    final bridge = FakeCollectionBridge();
    final controller = CollectionsController(bridge);
    await controller.start();
    final collection = await controller.createCollection('Headaches');
    await controller.selectCollection(collection);
    await controller.createRecord(const []);
    await controller.createWidget(
      WidgetDefinitionDto(
        id: '',
        collectionId: collection,
        widgetType: 'core.aggregate-number',
        queryId: 'query-1',
        title: 'Balance',
        configuration: WidgetConfigurationDto(version: 1, body: _map(const {})),
        layout: WidgetLayoutDto(
          version: 1,
          size: WidgetSizeDto.medium,
          hints: _map(const {}),
        ),
        order: 0,
        deleted: false,
      ),
    );
    expect(controller.widgetDefinitions, hasLength(1));
    expect(controller.records, hasLength(1));

    // A later refresh where only evaluation fails keeps definitions and records intact.
    bridge.nextError = const BridgeError(
      kind: BridgeErrorKind.projection,
      message: 'evaluation unavailable',
      resetResolvable: false,
    );
    await controller.refreshWidgets();
    expect(controller.widgetErrorMessage, 'evaluation unavailable');
    expect(controller.widgetDefinitions, hasLength(1));
    expect(controller.records, hasLength(1));
    controller.dispose();
  });

  test(
    'devices controller reopens a bridge stream that ends unexpectedly',
    () async {
      final bridge = ClosingDevicesBridge();
      final controller = DevicesController(bridge);
      await controller.start();
      expect(bridge.opens, 1);
      expect(controller.devices, isEmpty);
      // The Rust side ends the stream without the subscriber cancelling it.
      bridge.devices.add(
        const TrustedDeviceDto(
          deviceId: 'peer',
          friendlyName: 'Peer',
          pairedAtMs: 1,
          lastSeenMs: null,
          lastSyncMs: null,
          revoked: false,
          connection: PeerConnectionKindDto.offline,
        ),
      );
      await bridge.closeCurrent();
      await Future<void>.delayed(const Duration(milliseconds: 1300));
      expect(bridge.opens, 2, reason: 'the stream is reopened');
      expect(
        controller.devices.map((device) => device.deviceId),
        ['peer'],
        reason: 'the backing query is refreshed on reopen',
      );
      // A deliberate teardown does not reopen.
      controller.dispose();
      await bridge.closeCurrent();
      await Future<void>.delayed(const Duration(milliseconds: 1300));
      expect(bridge.opens, 2);
    },
  );

  test('a batch is one bridge call and clears the selection', () async {
    final bridge = FakeCollectionBridge();
    final controller = CollectionsController(bridge);
    await controller.start();
    final collection = await controller.createCollection('Inbox');
    await controller.selectCollection(collection);
    for (var index = 0; index < 3; index++) {
      await controller.createRecord(const []);
    }
    final ids = controller.records.map((record) => record.id).toList();
    for (final id in ids) {
      controller.toggleSelected(id);
    }
    expect(controller.selecting, isTrue);
    expect(controller.selectedRecordIds, ids.toSet());

    final affected = await controller.deleteSelected();
    expect(affected, 3);
    expect(bridge.batchDeleteCalls, hasLength(1), reason: 'one batch call');
    expect(bridge.batchDeleteCalls.single.toSet(), ids.toSet());
    expect(controller.records, isEmpty);
    expect(controller.selectedRecordIds, isEmpty);
    expect(controller.selecting, isFalse);
    controller.dispose();
  });

  test('a batch field set is one bridge call', () async {
    final bridge = FakeCollectionBridge();
    final controller = CollectionsController(bridge);
    await controller.start();
    final collection = await controller.createCollection('Inbox');
    await controller.selectCollection(collection);
    const category = FieldDefinitionDto(
      id: '',
      name: 'Category',
      fieldType: FieldTypeDto(kind: FieldTypeKindDto.text),
      required_: false,
      validation: ValidationMetadataDto(),
      display: DisplayMetadataDto(multiline: false),
      order: 0,
      deleted: false,
      enumOptions: [],
    );
    await controller.addField(category);
    final fieldId = controller.schema!.fields.single.id;
    for (var index = 0; index < 2; index++) {
      await controller.createRecord(const []);
    }
    for (final record in controller.records) {
      controller.toggleSelected(record.id);
    }
    final affected = await controller.setFieldOnSelected(
      fieldId,
      const FieldValueDto(kind: FieldValueKindDto.text, textValue: 'triage'),
    );
    expect(affected, 2);
    expect(bridge.batchFieldCalls, hasLength(1), reason: 'one batch call');
    expect(controller.selectedRecordIds, isEmpty);
    for (final record in controller.records) {
      expect(
        record.values.single.value.textValue,
        'triage',
        reason: 'every selected record carries the batch value',
      );
    }
    controller.dispose();
  });

  test('a rejected batch keeps selection mode and prunes it', () async {
    final bridge = FakeCollectionBridge();
    final controller = CollectionsController(bridge);
    await controller.start();
    final collection = await controller.createCollection('Inbox');
    await controller.selectCollection(collection);
    for (var index = 0; index < 2; index++) {
      await controller.createRecord(const []);
    }
    final ids = controller.records.map((record) => record.id).toList();
    for (final id in ids) {
      controller.toggleSelected(id);
    }
    // The record vanishes the way a remote delete drops it from the projection.
    bridge.records[collection]!.removeWhere((record) => record.id == ids.first);
    bridge.nextBatchError = const BridgeError(
      kind: BridgeErrorKind.validation,
      field: 'batch',
      message: 'member 0: record not found',
      resetResolvable: false,
    );
    await expectLater(controller.deleteSelected(), throwsA(isA<BridgeError>()));
    expect(controller.selecting, isTrue, reason: 'selection mode survives');
    expect(
      controller.selectedRecordIds,
      {ids.last},
      reason: 'the missing record is pruned, the rest is kept',
    );
    controller.dispose();
  });

  test('a refresh that drops a record prunes it from the selection', () async {
    final bridge = FakeCollectionBridge();
    final controller = CollectionsController(bridge);
    await controller.start();
    final collection = await controller.createCollection('Inbox');
    await controller.selectCollection(collection);
    for (var index = 0; index < 2; index++) {
      await controller.createRecord(const []);
    }
    final ids = controller.records.map((record) => record.id).toList();
    for (final id in ids) {
      controller.toggleSelected(id);
    }
    bridge.records[collection]!.removeWhere((record) => record.id == ids.first);
    await controller.refresh();
    expect(controller.selectedRecordIds, {ids.last});
    controller.dispose();
  });

  group('saveFieldWithOptions', () {
    FieldDefinitionDto choiceField({String id = '', FieldValueDto? value}) =>
        FieldDefinitionDto(
          id: id,
          name: 'Priority',
          fieldType: const FieldTypeDto(kind: FieldTypeKindDto.enum_),
          required_: false,
          defaultValue: value,
          validation: const ValidationMetadataDto(),
          display: const DisplayMetadataDto(multiline: false),
          order: 0,
          deleted: false,
          enumOptions: const [],
        );
    EnumOptionDto option(String id, String label) =>
        EnumOptionDto(id: id, label: label, order: 0, deleted: false);
    FieldValueDto choice(String id) =>
        FieldValueDto(kind: FieldValueKindDto.enum_, textValue: id);

    Future<(FakeCollectionBridge, CollectionsController)> start() async {
      final bridge = FakeCollectionBridge();
      final controller = CollectionsController(bridge);
      addTearDown(controller.dispose);
      await controller.start();
      await controller.selectCollection(
        await controller.createCollection('Tasks'),
      );
      return (bridge, controller);
    }

    List<String> labels(CollectionsController controller) {
      final options = [
        ...controller.schema!.fields.single.enumOptions.where(
          (item) => !item.deleted,
        ),
      ]..sort((a, b) => a.order.compareTo(b.order));
      return options.map((item) => item.label).toList();
    }

    test('creates the field, its options in order, then the default', () async {
      final (bridge, controller) = await start();
      final id = await controller
          .saveFieldWithOptions(choiceField(value: choice(tempOptionId(2))), [
            option(tempOptionId(1), 'Low'),
            option(tempOptionId(2), 'Medium'),
            option(tempOptionId(3), 'High'),
          ]);
      final field = controller.schema!.fields.single;
      final medium = field.enumOptions.firstWhere(
        (item) => item.label == 'Medium',
      );
      expect(field.id, id);
      expect(bridge.schemaCalls, [
        'addField',
        'upsertEnumOption -|Low|0',
        'upsertEnumOption -|Medium|1',
        'upsertEnumOption -|High|2',
        'updateField default=${medium.id}',
      ]);
      expect(labels(controller), ['Low', 'Medium', 'High']);
      expect(field.defaultValue?.textValue, medium.id);
    });

    test('edits send only the options that changed', () async {
      final (bridge, controller) = await start();
      await controller.saveFieldWithOptions(choiceField(), [
        option(tempOptionId(1), 'Low'),
        option(tempOptionId(2), 'Medium'),
        option(tempOptionId(3), 'High'),
      ]);
      final stored = controller.schema!.fields.single;
      String idOf(String label) =>
          stored.enumOptions.firstWhere((item) => item.label == label).id;
      bridge.schemaCalls.clear();

      // Rename Medium, drag High above Low, remove Low.
      await controller.saveFieldWithOptions(choiceField(id: stored.id), [
        option(idOf('High'), 'High'),
        option(idOf('Medium'), 'Mid'),
      ]);
      expect(bridge.schemaCalls, [
        'updateField default=-',
        'removeEnumOption ${idOf('Low')}',
        'upsertEnumOption ${idOf('High')}|High|0',
        // Medium keeps order 1, so only its label changed.
        'upsertEnumOption ${idOf('Medium')}|Mid|1',
      ]);
      expect(labels(controller), ['High', 'Mid']);
    });

    test('unchanged options are not resubmitted', () async {
      final (bridge, controller) = await start();
      await controller.saveFieldWithOptions(choiceField(), [
        option(tempOptionId(1), 'A'),
        option(tempOptionId(2), 'B'),
      ]);
      final stored = controller.schema!.fields.single;
      bridge.schemaCalls.clear();
      final sorted = [...stored.enumOptions]
        ..sort((a, b) => a.order.compareTo(b.order));
      await controller.saveFieldWithOptions(choiceField(id: stored.id), sorted);
      expect(bridge.schemaCalls, ['updateField default=-']);
      expect(labels(controller), ['A', 'B']);
    });

    test(
      'a failed option write rethrows, keeps the field, and retries cleanly',
      () async {
        final (bridge, controller) = await start();
        final session = FieldSaveSession();
        final draft = [
          option(tempOptionId(1), 'Low'),
          option(tempOptionId(2), 'High'),
        ];
        final field = choiceField(value: choice(tempOptionId(2)));
        bridge.nextOptionError = const BridgeError(
          kind: BridgeErrorKind.validation,
          field: 'enum_option_label',
          message: 'Label is required.',
          resetResolvable: false,
        );
        await expectLater(
          controller.saveFieldWithOptions(field, draft, session: session),
          throwsA(isA<BridgeError>()),
        );
        expect(controller.schema!.fields, hasLength(1));
        expect(controller.schema!.fields.single.enumOptions, isEmpty);
        expect(session.fieldId, controller.schema!.fields.single.id);

        bridge.schemaCalls.clear();
        await controller.saveFieldWithOptions(field, draft, session: session);
        final high = controller.schema!.fields.single.enumOptions.firstWhere(
          (item) => item.label == 'High',
        );
        expect(controller.schema!.fields, hasLength(1));
        expect(bridge.schemaCalls, [
          'updateField default=-',
          'upsertEnumOption -|Low|0',
          'upsertEnumOption -|High|1',
          'updateField default=${high.id}',
        ]);
        expect(labels(controller), ['Low', 'High']);
      },
    );
  });
}

/// A bridge whose connection-state stream can be ended from the Rust side.
final class ClosingDevicesBridge implements CollectionBridge {
  final inner = FakeCollectionBridge();
  int opens = 0;
  StreamController<List<TrustedDeviceDto>>? _current;

  List<TrustedDeviceDto> get devices => inner.devices;

  Future<void> closeCurrent() async => _current?.close();

  @override
  Stream<PairingStateDto> pairingStateEvents() => inner.pairingStateEvents();
  @override
  Stream<List<PairingCandidateDto>> pairingCandidateEvents() =>
      inner.pairingCandidateEvents();
  @override
  Stream<SyncStatusDto> syncStatusEvents() => inner.syncStatusEvents();
  @override
  Future<List<TrustedDeviceDto>> trustedDevices() => inner.trustedDevices();
  @override
  Future<SyncStatusDto> syncStatus() => inner.syncStatus();

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());

  @override
  Stream<List<TrustedDeviceDto>> connectionStateEvents() {
    opens += 1;
    final controller = StreamController<List<TrustedDeviceDto>>();
    _current = controller;
    return controller.stream;
  }
}

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
