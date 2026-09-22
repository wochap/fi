import 'dart:async';

import 'package:fi/bridge/collection_bridge.dart';
import 'package:fi/src/rust/api/models.dart';

final class FakeCollectionBridge implements CollectionBridge {
  BootstrapDto bootstrap = const BootstrapDto(
    kind: BootstrapKindDto.needsDecision,
  );
  ProjectionDto projection = const ProjectionDto(
    kind: ProjectionKindDto.unavailable,
  );
  final List<CollectionDto> collections = [];
  final Map<String, CollectionSchemaDto> schemas = {};
  final Map<String, List<RecordDto>> records = {};
  final Map<String, List<ComputedFieldDefinitionDto>> computedFields = {};
  final Map<String, List<QueryDefinitionDto>> queryDefinitions = {};
  QueryResultDto? nextQueryResult;
  final Map<String, List<WidgetDefinitionDto>> widgetDefinitions = {};
  final Map<String, List<DiagnosticDto>> diagnostics = {};
  final List<String> evaluatedCollections = [];
  int evaluationsRequested = 0;

  /// The renderer registry this fake advertises. Tests drop an entry to simulate a build that
  /// cannot render a synchronized widget type.
  List<WidgetDescriptorDto> descriptors = const [
    WidgetDescriptorDto(
      widgetType: 'core.aggregate-number',
      label: 'Aggregate number',
      acceptedShapes: [QueryResultShapeDto.scalar],
      configurationVersion: 1,
      supported: true,
    ),
    WidgetDescriptorDto(
      widgetType: 'core.line-chart',
      label: 'Line chart',
      acceptedShapes: [
        QueryResultShapeDto.series,
        QueryResultShapeDto.categorySeries,
      ],
      configurationVersion: 1,
      supported: true,
    ),
    WidgetDescriptorDto(
      widgetType: 'core.bar-chart',
      label: 'Bar chart',
      acceptedShapes: [
        QueryResultShapeDto.categorySeries,
        QueryResultShapeDto.series,
      ],
      configurationVersion: 1,
      supported: true,
    ),
    WidgetDescriptorDto(
      widgetType: 'core.scatter-plot',
      label: 'Scatter plot',
      acceptedShapes: [QueryResultShapeDto.series],
      configurationVersion: 1,
      supported: true,
    ),
  ];
  final List<TrustedDeviceDto> devices = [];
  final List<String> confirmedSessions = [];
  final List<String> rejectedSessions = [];
  final List<String> revokedDevices = [];
  PairingStateDto pairing = const PairingStateDto(
    kind: PairingKindDto.idle,
    localConfirmed: false,
    remoteConfirmed: false,
  );
  SyncStatusDto status = SyncStatusDto.offline;
  Object? nextError;
  int _next = 1;
  final bootstrapController = StreamController<BootstrapDto>.broadcast();
  final projectionController = StreamController<ProjectionDto>.broadcast();
  final dataController = StreamController<DataChangedDto>.broadcast();
  final errorController = StreamController<BridgeErrorEventDto>.broadcast();
  final pairingController = StreamController<PairingStateDto>.broadcast();
  final candidateController =
      StreamController<List<PairingCandidateDto>>.broadcast();
  final devicesController =
      StreamController<List<TrustedDeviceDto>>.broadcast();
  final statusController = StreamController<SyncStatusDto>.broadcast();
  void _fail() {
    final error = nextError;
    nextError = null;
    if (error != null) throw error;
  }

  void changed([String? id]) => dataController.add(
    DataChangedDto(
      kinds: const [
        DomainKindDto.collections,
        DomainKindDto.schemas,
        DomainKindDto.records,
      ],
      collectionIds: id == null ? const [] : [id],
      checkpoint: 'fake',
    ),
  );

  /// Widget commands emit only the Widgets domain kind, matching the authoritative event scope.
  void changedWidgets([String? id]) => dataController.add(
    DataChangedDto(
      kinds: const [DomainKindDto.widgets],
      collectionIds: id == null ? const [] : [id],
      checkpoint: 'fake',
    ),
  );
  @override
  Future<BootstrapDto> initialize(String dataDir) async {
    _fail();
    return bootstrap;
  }

  @override
  Future<BootstrapDto> createNewDataset() async {
    pairingCalls.add('createNewDataset');
    bootstrap = const BootstrapDto(
      kind: BootstrapKindDto.ready,
      rootId: 'root',
    );
    bootstrapController.add(bootstrap);
    return bootstrap;
  }

  @override
  Future<BootstrapDto> resetDataset() async {
    pairingCalls.add('resetDataset');
    _fail();
    bootstrap = const BootstrapDto(kind: BootstrapKindDto.needsDecision);
    devices.clear();
    pairing = const PairingStateDto(
      kind: PairingKindDto.idle,
      localConfirmed: false,
      remoteConfirmed: false,
    );
    bootstrapController.add(bootstrap);
    return bootstrap;
  }

  @override
  Future<ProjectionDto> projectionState() async => projection;
  @override
  Stream<BootstrapDto> bootstrapEvents() => bootstrapController.stream;
  @override
  Stream<ProjectionDto> projectionEvents() => projectionController.stream;
  @override
  Stream<DataChangedDto> dataChangedEvents() => dataController.stream;
  @override
  Stream<BridgeErrorEventDto> errorEvents() => errorController.stream;
  @override
  Future<void> shutdown() async {}
  @override
  Future<void> setForeground(bool foreground) async {}
  @override
  Future<List<CollectionDto>> listCollections() async {
    _fail();
    return List.of(collections);
  }

  @override
  Future<CollectionSchemaDto?> getCollectionSchema(String id) async =>
      schemas[id];
  @override
  Future<String> createCollection(String name, String description) async {
    _fail();
    final id = 'collection-${_next++}';
    collections.add(
      CollectionDto(id: id, name: name, description: description),
    );
    schemas[id] = CollectionSchemaDto(
      id: id,
      description: description,
      name: name,
      fields: const [],
    );
    records[id] = [];
    changed(id);
    return id;
  }

  @override
  Future<void> renameCollection(String id, String name) async {
    final index = collections.indexWhere((item) => item.id == id);
    final old = collections[index];
    collections[index] = CollectionDto(
      id: id,
      name: name,
      description: old.description,
    );
    final schema = schemas[id]!;
    schemas[id] = CollectionSchemaDto(
      id: id,
      description: schema.description,
      name: name,
      fields: schema.fields,
    );
    changed(id);
  }

  @override
  Future<void> deleteCollection(String id) async {
    collections.removeWhere((item) => item.id == id);
    schemas.remove(id);
    records.remove(id);
    changed(id);
  }

  @override
  Future<String> addField(String collectionId, FieldDefinitionDto field) async {
    final id = field.id.isEmpty ? 'field-${_next++}' : field.id;
    final normalized = _copyField(field, id: id);
    final schema = schemas[collectionId]!;
    schemas[collectionId] = CollectionSchemaDto(
      id: schema.id,
      description: schema.description,
      name: schema.name,
      fields: [...schema.fields, normalized],
    );
    changed(collectionId);
    return id;
  }

  @override
  Future<void> updateField(
    String collectionId,
    FieldDefinitionDto field,
  ) async {
    final schema = schemas[collectionId]!;
    schemas[collectionId] = CollectionSchemaDto(
      id: schema.id,
      description: schema.description,
      name: schema.name,
      fields: [
        for (final item in schema.fields)
          if (item.id == field.id) field else item,
      ],
    );
    changed(collectionId);
  }

  @override
  Future<void> removeField(String collectionId, String fieldId) async {
    final schema = schemas[collectionId]!;
    schemas[collectionId] = CollectionSchemaDto(
      id: schema.id,
      description: schema.description,
      name: schema.name,
      fields: schema.fields.where((item) => item.id != fieldId).toList(),
    );
    changed(collectionId);
  }

  @override
  Future<void> reorderFields(String collectionId, List<String> fieldIds) async {
    final schema = schemas[collectionId]!;
    final byId = {for (final field in schema.fields) field.id: field};
    schemas[collectionId] = CollectionSchemaDto(
      id: schema.id,
      description: schema.description,
      name: schema.name,
      fields: [
        for (var i = 0; i < fieldIds.length; i++)
          _copyField(byId[fieldIds[i]]!, order: i),
      ],
    );
    changed(collectionId);
  }

  @override
  Future<String> upsertEnumOption(
    String collectionId,
    String fieldId,
    EnumOptionDto option,
  ) async {
    final id = option.id.isEmpty ? 'option-${_next++}' : option.id;
    final schema = schemas[collectionId]!;
    final fields = [
      for (final field in schema.fields)
        if (field.id == fieldId)
          _copyField(
            field,
            enumOptions: [
              ...field.enumOptions.where((item) => item.id != id),
              EnumOptionDto(
                id: id,
                label: option.label,
                order: option.order,
                deleted: false,
              ),
            ],
          )
        else
          field,
    ];
    schemas[collectionId] = CollectionSchemaDto(
      id: schema.id,
      description: schema.description,
      name: schema.name,
      fields: fields,
    );
    changed(collectionId);
    return id;
  }

  @override
  Future<void> removeEnumOption(
    String collectionId,
    String fieldId,
    String optionId,
  ) async {
    final schema = schemas[collectionId]!;
    final fields = [
      for (final field in schema.fields)
        if (field.id == fieldId)
          _copyField(
            field,
            enumOptions: field.enumOptions
                .where((item) => item.id != optionId)
                .toList(),
          )
        else
          field,
    ];
    schemas[collectionId] = CollectionSchemaDto(
      id: schema.id,
      description: schema.description,
      name: schema.name,
      fields: fields,
    );
    changed(collectionId);
  }

  @override
  Future<String> createRecord(
    String collectionId,
    List<RecordValueDto> values,
  ) async {
    _fail();
    final id = 'record-${_next++}';
    records
        .putIfAbsent(collectionId, () => [])
        .add(
          RecordDto(
            id: id,
            collectionId: collectionId,
            values: values,
            valid: true,
            diagnostics: const [],
          ),
        );
    changed(collectionId);
    return id;
  }

  @override
  Future<void> updateRecordField(
    String recordId,
    String collectionId,
    String fieldId,
    FieldValueDto value,
  ) async {
    final items = records[collectionId]!;
    final index = items.indexWhere((item) => item.id == recordId);
    final old = items[index];
    items[index] = RecordDto(
      id: old.id,
      collectionId: old.collectionId,
      values: [
        ...old.values.where((item) => item.fieldId != fieldId),
        RecordValueDto(fieldId: fieldId, value: value),
      ],
      valid: true,
      diagnostics: const [],
    );
    changed(collectionId);
  }

  @override
  Future<void> deleteRecord(String recordId, String collectionId) async {
    records[collectionId]?.removeWhere((item) => item.id == recordId);
    changed(collectionId);
  }

  @override
  Future<List<RecordDto>> listRecords(String collectionId) async {
    _fail();
    return List.of(records[collectionId] ?? const []);
  }

  @override
  Future<RecordDto?> getRecord(String id) async {
    for (final list in records.values) {
      for (final item in list) {
        if (item.id == id) return item;
      }
    }
    return null;
  }

  @override
  Future<String> createComputedField(
    ComputedFieldDefinitionDto definition,
  ) async {
    final id = definition.id.isEmpty ? 'computed-${_next++}' : definition.id;
    computedFields
        .putIfAbsent(definition.collectionId, () => [])
        .add(
          ComputedFieldDefinitionDto(
            id: id,
            collectionId: definition.collectionId,
            name: definition.name,
            declaredType: definition.declaredType,
            nullable: definition.nullable,
            expressionVersion: definition.expressionVersion,
            expression: definition.expression,
            unsupportedBodyJson: definition.unsupportedBodyJson,
            order: definition.order,
            deleted: false,
          ),
        );
    changed(definition.collectionId);
    return id;
  }

  @override
  Future<void> updateComputedField(
    ComputedFieldDefinitionDto definition,
  ) async {
    final items = computedFields[definition.collectionId]!;
    items[items.indexWhere((item) => item.id == definition.id)] = definition;
    changed(definition.collectionId);
  }

  @override
  Future<void> removeComputedField(String collectionId, String id) async {
    computedFields[collectionId]?.removeWhere((item) => item.id == id);
    changed(collectionId);
  }

  @override
  Future<void> reorderComputedFields(
    String collectionId,
    List<String> ids,
  ) async {
    final items = computedFields[collectionId] ?? [];
    final byId = {for (final item in items) item.id: item};
    computedFields[collectionId] = [
      for (var i = 0; i < ids.length; i++)
        ComputedFieldDefinitionDto(
          id: byId[ids[i]]!.id,
          collectionId: collectionId,
          name: byId[ids[i]]!.name,
          declaredType: byId[ids[i]]!.declaredType,
          nullable: byId[ids[i]]!.nullable,
          expressionVersion: byId[ids[i]]!.expressionVersion,
          expression: byId[ids[i]]!.expression,
          unsupportedBodyJson: byId[ids[i]]!.unsupportedBodyJson,
          order: i,
          deleted: byId[ids[i]]!.deleted,
        ),
    ];
    changed(collectionId);
  }

  @override
  Future<List<ComputedFieldDefinitionDto>> listComputedFields(
    String collectionId,
  ) async => List.of(computedFields[collectionId] ?? const []);
  @override
  Future<String> createQueryDefinition(QueryDefinitionDto definition) async {
    final id = definition.id.isEmpty ? 'query-${_next++}' : definition.id;
    queryDefinitions
        .putIfAbsent(definition.collectionId, () => [])
        .add(
          QueryDefinitionDto(
            id: id,
            collectionId: definition.collectionId,
            name: definition.name,
            queryVersion: definition.queryVersion,
            query: definition.query,
            unsupportedBodyJson: definition.unsupportedBodyJson,
            order: definition.order,
            deleted: false,
          ),
        );
    changed(definition.collectionId);
    return id;
  }

  @override
  Future<void> updateQueryDefinition(QueryDefinitionDto definition) async {
    final items = queryDefinitions[definition.collectionId]!;
    items[items.indexWhere((item) => item.id == definition.id)] = definition;
    changed(definition.collectionId);
  }

  @override
  Future<void> removeQueryDefinition(String collectionId, String id) async {
    queryDefinitions[collectionId]?.removeWhere((item) => item.id == id);
    changed(collectionId);
  }

  @override
  Future<void> reorderQueryDefinitions(
    String collectionId,
    List<String> ids,
  ) async {
    final items = queryDefinitions[collectionId] ?? [];
    final byId = {for (final item in items) item.id: item};
    queryDefinitions[collectionId] = [
      for (var i = 0; i < ids.length; i++)
        QueryDefinitionDto(
          id: byId[ids[i]]!.id,
          collectionId: collectionId,
          name: byId[ids[i]]!.name,
          queryVersion: byId[ids[i]]!.queryVersion,
          query: byId[ids[i]]!.query,
          unsupportedBodyJson: byId[ids[i]]!.unsupportedBodyJson,
          order: i,
          deleted: byId[ids[i]]!.deleted,
        ),
    ];
    changed(collectionId);
  }

  @override
  Future<List<QueryDefinitionDto>> listQueryDefinitions(
    String collectionId,
  ) async => List.of(queryDefinitions[collectionId] ?? const []);
  @override
  Future<void> validateCollectionQuery(CollectionQueryDto query) async {
    _fail();
  }

  @override
  Future<QueryResultDto> executeCollectionQuery(
    CollectionQueryDto query,
    int nowUtcMs,
  ) async {
    _fail();
    return nextQueryResult ??
        const QueryResultDto(
          kind: QueryResultKindDto.recordSet,
          points: [],
          categoryPoints: [],
          records: [],
        );
  }

  @override
  Future<List<WidgetDefinitionDto>> listWidgets(String collectionId) async {
    _fail();
    return List.of(widgetDefinitions[collectionId] ?? const []);
  }

  @override
  Future<WidgetDefinitionDto?> getWidget(String collectionId, String id) async {
    for (final item in widgetDefinitions[collectionId] ?? const []) {
      if (item.id == id) return item;
    }
    return null;
  }

  @override
  Future<String> createWidget(WidgetDefinitionDto definition) async {
    _fail();
    final id = definition.id.isEmpty ? 'widget-${_next++}' : definition.id;
    widgetDefinitions
        .putIfAbsent(definition.collectionId, () => [])
        .add(
          WidgetDefinitionDto(
            id: id,
            collectionId: definition.collectionId,
            widgetType: definition.widgetType,
            queryId: definition.queryId,
            title: definition.title,
            configuration: definition.configuration,
            layout: definition.layout,
            order: definition.order,
            deleted: false,
          ),
        );
    changedWidgets(definition.collectionId);
    return id;
  }

  @override
  Future<void> updateWidget(WidgetUpdateDto update) async {
    _fail();
    final items = widgetDefinitions[update.collectionId]!;
    final index = items.indexWhere((item) => item.id == update.id);
    final old = items[index];
    // Omitted fields stay untouched, mirroring the authoritative register granularity.
    items[index] = WidgetDefinitionDto(
      id: old.id,
      collectionId: old.collectionId,
      widgetType: old.widgetType,
      queryId: update.queryId ?? old.queryId,
      title: update.title ?? old.title,
      configuration: update.configuration ?? old.configuration,
      layout: update.layout ?? old.layout,
      order: update.order ?? old.order,
      deleted: old.deleted,
    );
    changedWidgets(update.collectionId);
  }

  @override
  Future<void> removeWidget(String collectionId, String id) async {
    widgetDefinitions[collectionId]?.removeWhere((item) => item.id == id);
    changedWidgets(collectionId);
  }

  @override
  Future<void> reorderWidgets(String collectionId, List<String> ids) async {
    final items = widgetDefinitions[collectionId] ?? [];
    final byId = {for (final item in items) item.id: item};
    widgetDefinitions[collectionId] = [
      for (var i = 0; i < ids.length; i++)
        WidgetDefinitionDto(
          id: byId[ids[i]]!.id,
          collectionId: collectionId,
          widgetType: byId[ids[i]]!.widgetType,
          queryId: byId[ids[i]]!.queryId,
          title: byId[ids[i]]!.title,
          configuration: byId[ids[i]]!.configuration,
          layout: byId[ids[i]]!.layout,
          order: i,
          deleted: byId[ids[i]]!.deleted,
        ),
    ];
    changedWidgets(collectionId);
  }

  @override
  Future<List<WidgetDescriptorDto>> listWidgetDescriptors() async =>
      List.of(descriptors.where((descriptor) => descriptor.supported));

  @override
  Future<WidgetDescriptorDto> widgetDescriptor(String widgetType) async =>
      descriptors.firstWhere(
        (descriptor) => descriptor.widgetType == widgetType,
        orElse: () => WidgetDescriptorDto(
          widgetType: widgetType,
          label: '',
          acceptedShapes: const [],
          configurationVersion: 0,
          supported: false,
        ),
      );

  @override
  Future<WidgetEvaluationDto> evaluateWidget(
    String collectionId,
    String id,
    int nowUtcMs,
  ) async {
    _fail();
    final definition = await getWidget(collectionId, id);
    if (definition == null) {
      throw BridgeError(
        kind: BridgeErrorKind.validation,
        message: 'The selected widget no longer exists.',
        resetResolvable: false,
      );
    }
    return _evaluate(definition);
  }

  @override
  Future<List<WidgetEvaluationDto>> evaluateWidgets(
    String collectionId,
    int nowUtcMs,
  ) async {
    _fail();
    evaluationsRequested++;
    evaluatedCollections.add(collectionId);
    return widgetDefinitions[collectionId]?.map(_evaluate).toList() ?? const [];
  }

  @override
  Future<List<DiagnosticDto>> widgetDiagnostics(String id) async =>
      List.of(diagnostics[id] ?? const []);

  WidgetEvaluationDto _evaluate(WidgetDefinitionDto definition) {
    final supported = descriptors.any(
      (descriptor) =>
          descriptor.supported &&
          descriptor.widgetType == definition.widgetType,
    );
    if (!supported) {
      return WidgetEvaluationDto(
        widgetId: definition.id,
        widgetType: definition.widgetType,
        ready: false,
        errorKind: WidgetErrorKindDto.unsupportedType,
        message:
            'widget type ${definition.widgetType} has no local implementation',
      );
    }
    return WidgetEvaluationDto(
      widgetId: definition.id,
      widgetType: definition.widgetType,
      ready: true,
      result:
          nextQueryResult ??
          const QueryResultDto(
            kind: QueryResultKindDto.scalar,
            points: [],
            categoryPoints: [],
            records: [],
          ),
    );
  }

  @override
  Future<void> startPairing(int durationMs) async {
    pairing = PairingStateDto(
      kind: PairingKindDto.discoverable,
      deadlineMs: DateTime.now().millisecondsSinceEpoch + durationMs,
      localConfirmed: false,
      remoteConfirmed: false,
    );
    pairingController.add(pairing);
  }

  /// Order of pairing-relevant calls, for asserting create/pair sequencing.
  final List<String> pairingCalls = [];

  /// Runs while `confirmPairing` is awaiting, so a test can move bootstrap
  /// state mid-call.
  Future<void> Function()? confirmDelay;

  @override
  Future<void> stopPairing() async {
    pairingCalls.add('stopPairing');
    pairing = const PairingStateDto(
      kind: PairingKindDto.idle,
      localConfirmed: false,
      remoteConfirmed: false,
    );
    pairingController.add(pairing);
  }

  @override
  Future<void> connectPairingCandidate(PairingCandidateDto candidate) async {}
  @override
  Future<void> confirmPairing(String sessionId) async {
    confirmedSessions.add(sessionId);
    if (confirmDelay case final delay?) await delay();
  }

  @override
  Future<void> rejectPairing(String? sessionId) async {
    if (sessionId != null) rejectedSessions.add(sessionId);
  }

  @override
  Future<List<TrustedDeviceDto>> trustedDevices() async => List.of(devices);
  @override
  Future<void> renameTrustedDevice(String deviceId, String name) async {
    final index = devices.indexWhere((item) => item.deviceId == deviceId);
    final old = devices[index];
    devices[index] = TrustedDeviceDto(
      deviceId: old.deviceId,
      friendlyName: name,
      pairedAtMs: old.pairedAtMs,
      lastSeenMs: old.lastSeenMs,
      lastSyncMs: old.lastSyncMs,
      revoked: old.revoked,
      connection: old.connection,
    );
    devicesController.add(List.of(devices));
  }

  /// Rotation failure the next revocation reports after committing.
  String? nextRotationError;
  int rotationRetries = 0;

  @override
  Future<RevocationOutcomeDto> revokeTrustedDevice(
    String deviceId,
    int nowMs,
  ) async {
    revokedDevices.add(deviceId);
    final index = devices.indexWhere((item) => item.deviceId == deviceId);
    final old = devices[index];
    devices[index] = TrustedDeviceDto(
      deviceId: old.deviceId,
      friendlyName: old.friendlyName,
      pairedAtMs: old.pairedAtMs,
      lastSeenMs: old.lastSeenMs,
      lastSyncMs: old.lastSyncMs,
      revoked: true,
      connection: PeerConnectionKindDto.offline,
    );
    devicesController.add(List.of(devices));
    return RevocationOutcomeDto(
      revoked: true,
      rotationError: nextRotationError,
    );
  }

  @override
  Future<int> rotateDiscoverySecret(int nowMs) async {
    rotationRetries += 1;
    return rotationRetries;
  }

  @override
  Future<SyncStatusDto> syncStatus() async => status;
  @override
  Stream<PairingStateDto> pairingStateEvents() => pairingController.stream;
  @override
  Stream<List<PairingCandidateDto>> pairingCandidateEvents() =>
      candidateController.stream;
  @override
  Stream<List<TrustedDeviceDto>> connectionStateEvents() =>
      devicesController.stream;
  @override
  Stream<SyncStatusDto> syncStatusEvents() => statusController.stream;
}

FieldDefinitionDto _copyField(
  FieldDefinitionDto field, {
  String? id,
  int? order,
  List<EnumOptionDto>? enumOptions,
}) => FieldDefinitionDto(
  id: id ?? field.id,
  name: field.name,
  fieldType: field.fieldType,
  required_: field.required_,
  defaultValue: field.defaultValue,
  validation: field.validation,
  display: field.display,
  order: order ?? field.order,
  deleted: field.deleted,
  enumOptions: enumOptions ?? field.enumOptions,
);
