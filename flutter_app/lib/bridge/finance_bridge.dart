import 'package:fi/src/rust/api/finance.dart' as finance;
import 'package:fi/src/rust/api/lifecycle.dart' as lifecycle;
import 'package:fi/src/rust/api/models.dart';
import 'package:fi/src/rust/api/pairing.dart' as pairing;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

abstract interface class FinanceBridge {
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

  Future<List<CategoryDto>> listCategories();
  Future<String> createCategory(String name);
  Future<void> updateCategory(String id, String name);
  Future<void> deleteCategory(String id);
  Future<List<TransactionDto>> listTransactions(TransactionFilterDto filter);
  Future<String> createTransaction({
    required int occurredAtMs,
    required String categoryId,
    required int amountMinor,
    required String description,
  });
  Future<void> updateTransaction({
    required String id,
    int? occurredAtMs,
    String? categoryId,
    int? amountMinor,
    String? description,
  });
  Future<void> deleteTransaction(String id);
  Future<AggregateDto> aggregates();
}

final class RustFinanceBridge implements FinanceBridge {
  static const _platform = MethodChannel('fi/platform');

  @override
  Future<BootstrapDto> initialize(String dataDir) async {
    if (defaultTargetPlatform == TargetPlatform.android) {
      final seed = await _platform.invokeMethod<Uint8List>(
        'secureLoadOrCreateDeviceKey',
      );
      final discovery = await _platform.invokeMethod<Uint8List>(
        'secureLoadDiscoverySecret',
      );
      if (seed == null) {
        throw StateError('Android secure identity is unavailable.');
      }
      return lifecycle.initializeAndroidNetworked(
        dataDir: dataDir,
        deviceSeed: seed,
        discoverySecret: discovery,
      );
    }
    if (defaultTargetPlatform == TargetPlatform.linux) {
      return lifecycle.initializeDesktopNetworked(dataDir: dataDir);
    }
    return lifecycle.initialize(dataDir: dataDir);
  }

  @override
  Future<BootstrapDto> createNewDataset() => finance.createNewDataset();

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
  Future<void> startPairing(int durationMs) async {
    await pairing.startPairing(durationMs: durationMs);
  }

  @override
  Future<void> stopPairing() => pairing.stopPairing();

  @override
  Future<void> connectPairingCandidate(PairingCandidateDto candidate) async {
    await pairing.connectPairingCandidate(
      instanceId: candidate.instanceId,
      endpoint: candidate.endpoint,
      expiresAtMs: candidate.expiresAtMs,
      timeoutMs: 120000,
    );
  }

  @override
  Future<void> confirmPairing(String sessionId) =>
      _confirmAndPersist(sessionId);

  Future<void> _confirmAndPersist(String sessionId) async {
    await pairing.confirmPairing(sessionId: sessionId);
    await _persistAndroidDiscoverySecret();
  }

  @override
  Future<void> rejectPairing(String? sessionId) =>
      pairing.rejectPairing(sessionId: sessionId);

  @override
  Future<List<TrustedDeviceDto>> trustedDevices() => pairing.trustedDevices();

  @override
  Future<void> renameTrustedDevice(String deviceId, String name) async {
    await pairing.renameTrustedDevice(deviceId: deviceId, name: name);
  }

  @override
  Future<void> revokeTrustedDevice(String deviceId, int nowMs) async {
    await pairing.revokeTrustedDevice(deviceId: deviceId, nowMs: nowMs);
    await _persistAndroidDiscoverySecret();
  }

  Future<void> _persistAndroidDiscoverySecret() async {
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
  Future<List<CategoryDto>> listCategories() => finance.listCategories();

  @override
  Future<String> createCategory(String name) =>
      finance.createCategory(name: name);

  @override
  Future<void> updateCategory(String id, String name) =>
      finance.updateCategory(id: id, name: name);

  @override
  Future<void> deleteCategory(String id) => finance.deleteCategory(id: id);

  @override
  Future<List<TransactionDto>> listTransactions(TransactionFilterDto filter) =>
      finance.listTransactions(filter: filter);

  @override
  Future<String> createTransaction({
    required int occurredAtMs,
    required String categoryId,
    required int amountMinor,
    required String description,
  }) => finance.createTransaction(
    occurredAtMs: occurredAtMs,
    categoryId: categoryId,
    amountMinor: amountMinor,
    description: description,
  );

  @override
  Future<void> updateTransaction({
    required String id,
    int? occurredAtMs,
    String? categoryId,
    int? amountMinor,
    String? description,
  }) => finance.updateTransaction(
    id: id,
    occurredAtMs: occurredAtMs,
    categoryId: categoryId,
    amountMinor: amountMinor,
    description: description,
  );

  @override
  Future<void> deleteTransaction(String id) =>
      finance.deleteTransaction(id: id);

  @override
  Future<AggregateDto> aggregates() => finance.aggregates();
}
