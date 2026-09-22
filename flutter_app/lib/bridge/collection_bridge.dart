import 'package:fi/src/rust/api/collections.dart' as collections;
import 'package:fi/src/rust/api/lifecycle.dart' as lifecycle;
import 'package:fi/src/rust/api/models.dart';
import 'package:fi/src/rust/api/pairing.dart' as pairing;
import 'package:fi/src/rust/api/queries.dart' as queries;
import 'package:fi/src/rust/api/widgets.dart' as widgets;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

abstract interface class CollectionBridge {
  Future<BootstrapDto> initialize(String dataDir);
  Future<BootstrapDto> createNewDataset();

  /// Deliberate local dataset reset; see `lifecycle.resetDataset`. Returns the
  /// post-reset bootstrap state, normally `needsDecision`.
  Future<BootstrapDto> resetDataset();
  Future<BootstrapDto> bootstrapState();
  Future<ProjectionDto> projectionState();
  Stream<BootstrapDto> bootstrapEvents();
  Stream<ProjectionDto> projectionEvents();
  Stream<DataChangedDto> dataChangedEvents();
  Stream<BridgeErrorEventDto> errorEvents();
  Future<void> shutdown();
  Future<void> setForeground(bool foreground);

  /// Why peer networking is not running, when a networked open met a locked or
  /// unavailable secure store. Null when networking is not deferred.
  Future<NetworkingDeferredDto?> networkingDeferred();

  /// Retries the deferred networking startup and reports whether peer
  /// networking is now active. Idempotent.
  Future<bool> retryNetworking();
  Future<void> startPairing(int durationMs);
  Future<void> stopPairing();
  Future<void> connectPairingCandidate(PairingCandidateDto candidate);
  Future<void> confirmPairing(String sessionId);
  Future<void> rejectPairing(String? sessionId);
  Future<List<TrustedDeviceDto>> trustedDevices();
  Future<void> renameTrustedDevice(String deviceId, String name);
  Future<RevocationOutcomeDto> revokeTrustedDevice(String deviceId, int nowMs);
  Future<int> rotateDiscoverySecret(int nowMs);
  Future<SyncStatusDto> syncStatus();
  Stream<PairingStateDto> pairingStateEvents();
  Stream<List<PairingCandidateDto>> pairingCandidateEvents();
  Stream<List<TrustedDeviceDto>> connectionStateEvents();
  Stream<SyncStatusDto> syncStatusEvents();

  Future<List<CollectionDto>> listCollections();
  Future<CollectionSchemaDto?> getCollectionSchema(String id);
  Future<String> createCollection(String name, String description);
  Future<void> renameCollection(String id, String name);
  Future<void> deleteCollection(String id);
  Future<String> addField(String collectionId, FieldDefinitionDto field);
  Future<void> updateField(String collectionId, FieldDefinitionDto field);
  Future<void> removeField(String collectionId, String fieldId);
  Future<void> reorderFields(String collectionId, List<String> fieldIds);
  Future<String> upsertEnumOption(
    String collectionId,
    String fieldId,
    EnumOptionDto option,
  );
  Future<void> removeEnumOption(
    String collectionId,
    String fieldId,
    String optionId,
  );
  Future<String> createRecord(String collectionId, List<RecordValueDto> values);
  Future<void> updateRecordField(
    String recordId,
    String collectionId,
    String fieldId,
    FieldValueDto value,
  );
  Future<void> deleteRecord(String recordId, String collectionId);

  /// Deletes every record in one atomic batch. Rust rejects the whole batch if
  /// any member is invalid, so the list is all-or-nothing.
  Future<void> deleteRecords(List<String> recordIds, String collectionId);

  /// Sets one field to one value on every record in one atomic batch.
  Future<void> setRecordsField(
    List<String> recordIds,
    String collectionId,
    String fieldId,
    FieldValueDto value,
  );
  Future<List<RecordDto>> listRecords(String collectionId);
  Future<RecordDto?> getRecord(String id);
  Future<String> createComputedField(ComputedFieldDefinitionDto definition);
  Future<void> updateComputedField(ComputedFieldDefinitionDto definition);
  Future<void> removeComputedField(String collectionId, String id);
  Future<void> reorderComputedFields(String collectionId, List<String> ids);
  Future<List<ComputedFieldDefinitionDto>> listComputedFields(
    String collectionId,
  );
  Future<String> createQueryDefinition(QueryDefinitionDto definition);
  Future<void> updateQueryDefinition(QueryDefinitionDto definition);
  Future<void> removeQueryDefinition(String collectionId, String id);
  Future<void> reorderQueryDefinitions(String collectionId, List<String> ids);
  Future<List<QueryDefinitionDto>> listQueryDefinitions(String collectionId);
  Future<void> validateCollectionQuery(CollectionQueryDto query);
  Future<QueryResultDto> executeCollectionQuery(
    CollectionQueryDto query,
    int nowUtcMs,
  );
  Future<List<WidgetDefinitionDto>> listWidgets(String collectionId);
  Future<WidgetDefinitionDto?> getWidget(String collectionId, String id);
  Future<String> createWidget(WidgetDefinitionDto definition);
  Future<void> updateWidget(WidgetUpdateDto update);
  Future<void> removeWidget(String collectionId, String id);
  Future<void> reorderWidgets(String collectionId, List<String> ids);
  Future<List<WidgetDescriptorDto>> listWidgetDescriptors();
  Future<WidgetDescriptorDto> widgetDescriptor(String widgetType);
  Future<WidgetEvaluationDto> evaluateWidget(
    String collectionId,
    String id,
    int nowUtcMs,
  );
  Future<List<WidgetEvaluationDto>> evaluateWidgets(
    String collectionId,
    int nowUtcMs,
  );
  Future<List<DiagnosticDto>> widgetDiagnostics(String id);
}

final class RustCollectionBridge implements CollectionBridge {
  static const _platform = MethodChannel('fi/platform');
  @override
  Future<BootstrapDto> initialize(String dataDir) async {
    if (defaultTargetPlatform == TargetPlatform.android) {
      final seed = await _platform.invokeMethod<Uint8List>(
        'secureLoadOrCreateDeviceKey',
      );
      final secret = await _platform.invokeMethod<Uint8List>(
        'secureLoadDiscoverySecret',
      );
      if (seed == null) {
        throw StateError('Android secure identity is unavailable.');
      }
      return lifecycle.initializeAndroidNetworked(
        dataDir: dataDir,
        deviceSeed: seed,
        discoverySecret: secret,
      );
    }
    if (defaultTargetPlatform == TargetPlatform.linux) {
      return lifecycle.initializeDesktopNetworked(dataDir: dataDir);
    }
    return lifecycle.initialize(dataDir: dataDir);
  }

  @override
  Future<BootstrapDto> createNewDataset() => collections.createNewDataset();
  @override
  Future<BootstrapDto> resetDataset() async {
    final state = await lifecycle.resetDataset();
    // Rust cleared its (in-memory, on Android) key store; the platform copy
    // that seeds it on the next launch must go too, or the abandoned group's
    // secret would be re-injected.
    if (defaultTargetPlatform == TargetPlatform.android) {
      await _platform.invokeMethod<void>('secureRemoveDiscoverySecret');
    }
    return state;
  }

  @override
  Future<BootstrapDto> bootstrapState() => lifecycle.bootstrapState();
  @override
  Future<ProjectionDto> projectionState() => lifecycle.projectionState();
  @override
  Stream<BootstrapDto> bootstrapEvents() => lifecycle.bootstrapStream();
  @override
  Stream<ProjectionDto> projectionEvents() => lifecycle.projectionStream();
  @override
  Stream<DataChangedDto> dataChangedEvents() => lifecycle.dataChangedStream();
  @override
  Stream<BridgeErrorEventDto> errorEvents() => lifecycle.errorStream();
  @override
  Future<void> shutdown() => lifecycle.shutdown();
  @override
  Future<void> setForeground(bool foreground) =>
      lifecycle.setForeground(foreground: foreground);
  @override
  Future<NetworkingDeferredDto?> networkingDeferred() =>
      lifecycle.networkingDeferred();
  @override
  Future<bool> retryNetworking() => lifecycle.retryNetworking();
  @override
  Future<void> startPairing(int durationMs) async =>
      pairing.startPairing(durationMs: durationMs);
  @override
  Future<void> stopPairing() => pairing.stopPairing();
  @override
  Future<void> connectPairingCandidate(PairingCandidateDto candidate) =>
      pairing.connectPairingCandidate(
        instanceId: candidate.instanceId,
        endpoint: candidate.endpoint,
        expiresAtMs: candidate.expiresAtMs,
        timeoutMs: 120000,
      );
  @override
  Future<void> confirmPairing(String sessionId) async {
    await pairing.confirmPairing(sessionId: sessionId);
    await _persistAndroidSecret();
  }

  @override
  Future<void> rejectPairing(String? sessionId) =>
      pairing.rejectPairing(sessionId: sessionId);
  @override
  Future<List<TrustedDeviceDto>> trustedDevices() => pairing.trustedDevices();
  @override
  Future<void> renameTrustedDevice(String deviceId, String name) =>
      pairing.renameTrustedDevice(deviceId: deviceId, name: name);
  @override
  Future<RevocationOutcomeDto> revokeTrustedDevice(
    String deviceId,
    int nowMs,
  ) async {
    final outcome = await pairing.revokeTrustedDevice(
      deviceId: deviceId,
      nowMs: nowMs,
    );
    if (outcome.rotationError == null) await _persistAndroidSecret();
    return outcome;
  }

  @override
  Future<int> rotateDiscoverySecret(int nowMs) async {
    final epoch = await pairing.rotateDiscoverySecret(nowMs: nowMs);
    await _persistAndroidSecret();
    return epoch;
  }

  Future<void> _persistAndroidSecret() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    final secret = await pairing.discoverySecretForPlatform();
    if (secret != null) {
      await _platform.invokeMethod<void>('secureStoreDiscoverySecret', secret);
    }
  }

  @override
  Future<SyncStatusDto> syncStatus() => pairing.syncStatus();
  @override
  Stream<PairingStateDto> pairingStateEvents() => pairing.pairingStateStream();
  @override
  Stream<List<PairingCandidateDto>> pairingCandidateEvents() =>
      pairing.pairingCandidatesStream();
  @override
  Stream<List<TrustedDeviceDto>> connectionStateEvents() =>
      pairing.connectionStateStream();
  @override
  Stream<SyncStatusDto> syncStatusEvents() => pairing.syncStatusStream();
  @override
  Future<List<CollectionDto>> listCollections() =>
      collections.listCollections();
  @override
  Future<CollectionSchemaDto?> getCollectionSchema(String id) =>
      collections.getCollectionSchema(id: id);
  @override
  Future<String> createCollection(String name, String description) =>
      collections.createCollection(name: name, description: description);
  @override
  Future<void> renameCollection(String id, String name) =>
      collections.renameCollection(id: id, name: name);
  @override
  Future<void> deleteCollection(String id) =>
      collections.deleteCollection(id: id);
  @override
  Future<String> addField(String collectionId, FieldDefinitionDto field) =>
      collections.addField(collectionId: collectionId, field: field);
  @override
  Future<void> updateField(String collectionId, FieldDefinitionDto field) =>
      collections.updateField(collectionId: collectionId, field: field);
  @override
  Future<void> removeField(String collectionId, String fieldId) =>
      collections.removeField(collectionId: collectionId, fieldId: fieldId);
  @override
  Future<void> reorderFields(String collectionId, List<String> fieldIds) =>
      collections.reorderFields(collectionId: collectionId, fieldIds: fieldIds);
  @override
  Future<String> upsertEnumOption(
    String collectionId,
    String fieldId,
    EnumOptionDto option,
  ) => collections.upsertEnumOption(
    collectionId: collectionId,
    fieldId: fieldId,
    option: option,
  );
  @override
  Future<void> removeEnumOption(
    String collectionId,
    String fieldId,
    String optionId,
  ) => collections.removeEnumOption(
    collectionId: collectionId,
    fieldId: fieldId,
    optionId: optionId,
  );
  @override
  Future<String> createRecord(
    String collectionId,
    List<RecordValueDto> values,
  ) => collections.createRecord(collectionId: collectionId, values: values);
  @override
  Future<void> updateRecordField(
    String recordId,
    String collectionId,
    String fieldId,
    FieldValueDto value,
  ) => collections.updateRecordField(
    recordId: recordId,
    collectionId: collectionId,
    fieldId: fieldId,
    value: value,
  );
  @override
  Future<void> deleteRecord(String recordId, String collectionId) =>
      collections.deleteRecord(recordId: recordId, collectionId: collectionId);
  @override
  Future<void> deleteRecords(List<String> recordIds, String collectionId) =>
      collections.deleteRecords(
        recordIds: recordIds,
        collectionId: collectionId,
      );
  @override
  Future<void> setRecordsField(
    List<String> recordIds,
    String collectionId,
    String fieldId,
    FieldValueDto value,
  ) => collections.setRecordsField(
    recordIds: recordIds,
    collectionId: collectionId,
    fieldId: fieldId,
    value: value,
  );
  @override
  Future<List<RecordDto>> listRecords(String collectionId) =>
      collections.listRecords(collectionId: collectionId);
  @override
  Future<RecordDto?> getRecord(String id) => collections.getRecord(id: id);
  @override
  Future<String> createComputedField(ComputedFieldDefinitionDto definition) =>
      queries.createComputedField(definition: definition);
  @override
  Future<void> updateComputedField(ComputedFieldDefinitionDto definition) =>
      queries.updateComputedField(definition: definition);
  @override
  Future<void> removeComputedField(String collectionId, String id) =>
      queries.removeComputedField(collectionId: collectionId, id: id);
  @override
  Future<void> reorderComputedFields(String collectionId, List<String> ids) =>
      queries.reorderComputedFields(collectionId: collectionId, ids: ids);
  @override
  Future<List<ComputedFieldDefinitionDto>> listComputedFields(
    String collectionId,
  ) => queries.listComputedFields(collectionId: collectionId);
  @override
  Future<String> createQueryDefinition(QueryDefinitionDto definition) =>
      queries.createQueryDefinition(definition: definition);
  @override
  Future<void> updateQueryDefinition(QueryDefinitionDto definition) =>
      queries.updateQueryDefinition(definition: definition);
  @override
  Future<void> removeQueryDefinition(String collectionId, String id) =>
      queries.removeQueryDefinition(collectionId: collectionId, id: id);
  @override
  Future<void> reorderQueryDefinitions(String collectionId, List<String> ids) =>
      queries.reorderQueryDefinitions(collectionId: collectionId, ids: ids);
  @override
  Future<List<QueryDefinitionDto>> listQueryDefinitions(String collectionId) =>
      queries.listQueryDefinitions(collectionId: collectionId);
  @override
  Future<void> validateCollectionQuery(CollectionQueryDto query) =>
      queries.validateCollectionQuery(query: query);
  @override
  Future<QueryResultDto> executeCollectionQuery(
    CollectionQueryDto query,
    int nowUtcMs,
  ) => queries.executeCollectionQuery(query: query, nowUtcMs: nowUtcMs);
  @override
  Future<List<WidgetDefinitionDto>> listWidgets(String collectionId) =>
      widgets.listWidgets(collectionId: collectionId);
  @override
  Future<WidgetDefinitionDto?> getWidget(String collectionId, String id) =>
      widgets.getWidget(collectionId: collectionId, id: id);
  @override
  Future<String> createWidget(WidgetDefinitionDto definition) =>
      widgets.createWidget(definition: definition);
  @override
  Future<void> updateWidget(WidgetUpdateDto update) =>
      widgets.updateWidget(update: update);
  @override
  Future<void> removeWidget(String collectionId, String id) =>
      widgets.removeWidget(collectionId: collectionId, id: id);
  @override
  Future<void> reorderWidgets(String collectionId, List<String> ids) =>
      widgets.reorderWidgets(collectionId: collectionId, ids: ids);
  @override
  Future<List<WidgetDescriptorDto>> listWidgetDescriptors() =>
      widgets.listWidgetDescriptors();
  @override
  Future<WidgetDescriptorDto> widgetDescriptor(String widgetType) =>
      widgets.getWidgetDescriptor(widgetType: widgetType);
  @override
  Future<WidgetEvaluationDto> evaluateWidget(
    String collectionId,
    String id,
    int nowUtcMs,
  ) => widgets.evaluateWidget(
    collectionId: collectionId,
    id: id,
    nowUtcMs: nowUtcMs,
  );
  @override
  Future<List<WidgetEvaluationDto>> evaluateWidgets(
    String collectionId,
    int nowUtcMs,
  ) => widgets.evaluateWidgets(collectionId: collectionId, nowUtcMs: nowUtcMs);
  @override
  Future<List<DiagnosticDto>> widgetDiagnostics(String id) =>
      widgets.widgetDiagnostics(id: id);
}
