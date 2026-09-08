import 'package:fi/src/rust/api/collections.dart' as collections;
import 'package:fi/src/rust/api/lifecycle.dart' as lifecycle;
import 'package:fi/src/rust/api/models.dart';
import 'package:fi/src/rust/api/pairing.dart' as pairing;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

abstract interface class CollectionBridge {
  Future<BootstrapDto> initialize(String dataDir);
  Future<BootstrapDto> createNewDataset();
  Future<ProjectionDto> projectionState();
  Stream<BootstrapDto> bootstrapEvents();
  Stream<ProjectionDto> projectionEvents();
  Stream<DataChangedDto> dataChangedEvents();
  Stream<BridgeErrorEventDto> errorEvents();
  Future<void> shutdown();
  Future<void> setForeground(bool foreground);
  Future<void> startPairing(int durationMs);
  Future<void> stopPairing();
  Future<void> connectPairingCandidate(PairingCandidateDto candidate);
  Future<void> confirmPairing(String sessionId);
  Future<void> rejectPairing(String? sessionId);
  Future<List<TrustedDeviceDto>> trustedDevices();
  Future<void> renameTrustedDevice(String deviceId, String name);
  Future<void> revokeTrustedDevice(String deviceId, int nowMs);
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
  Future<List<RecordDto>> listRecords(String collectionId);
  Future<RecordDto?> getRecord(String id);
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
  Future<void> revokeTrustedDevice(String deviceId, int nowMs) async {
    await pairing.revokeTrustedDevice(deviceId: deviceId, nowMs: nowMs);
    await _persistAndroidSecret();
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
  Future<List<RecordDto>> listRecords(String collectionId) =>
      collections.listRecords(collectionId: collectionId);
  @override
  Future<RecordDto?> getRecord(String id) => collections.getRecord(id: id);
}
