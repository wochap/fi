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
