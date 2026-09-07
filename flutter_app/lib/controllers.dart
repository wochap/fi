import 'dart:async';

import 'package:fi/bridge/finance_bridge.dart';
import 'package:fi/src/rust/api/models.dart';
import 'package:flutter/foundation.dart';

final class BootstrapController extends ChangeNotifier {
  BootstrapController({
    required this.bridge,
    required this.initializeRust,
    required this.dataDirProvider,
  });

  final FinanceBridge bridge;
  final Future<void> Function() initializeRust;
  final Future<String> Function() dataDirProvider;
  BootstrapDto? state;
  String? fatalError;
  bool loading = true;
  bool creating = false;
  StreamSubscription<BootstrapDto>? _subscription;

  Future<void> start() async {
    loading = true;
    fatalError = null;
    notifyListeners();
    try {
      await initializeRust();
      state = await bridge.initialize(await dataDirProvider());
      await _subscription?.cancel();
      _subscription = bridge.bootstrapEvents().listen(
        (value) {
          state = value;
          notifyListeners();
        },
        onError: (Object error) {
          fatalError = bridgeMessage(error);
          notifyListeners();
        },
      );
    } catch (error) {
      fatalError = bridgeMessage(error);
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> createNewDataset() async {
    creating = true;
    notifyListeners();
    try {
      state = await bridge.createNewDataset();
    } catch (error) {
      fatalError = bridgeMessage(error);
    } finally {
      creating = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }
}

final class FinanceController extends ChangeNotifier {
  FinanceController(this.bridge);

  final FinanceBridge bridge;
  List<CategoryDto> categories = const [];
  List<TransactionDto> transactions = const [];
  AggregateDto aggregate = const AggregateDto(
    balanceMinor: 0,
    incomeMinor: 0,
    expenseMinor: 0,
    transactionCount: 0,
  );
  TransactionFilterDto filter = const TransactionFilterDto();
  ProjectionDto projection = const ProjectionDto(
    kind: ProjectionKindDto.unavailable,
  );
  String? errorMessage;
  bool loading = true;
  bool _disposed = false;
  StreamSubscription<DataChangedDto>? _dataSubscription;
  StreamSubscription<ProjectionDto>? _projectionSubscription;
  StreamSubscription<BridgeErrorEventDto>? _errorSubscription;

  Future<void> start() async {
    projection = await bridge.projectionState();
    _listenForInvalidations();
    _listenForProjection();
    _errorSubscription = bridge.errorEvents().listen((event) {
      errorMessage = event.message;
      notifyListeners();
    });
    await refresh();
  }

  void _listenForInvalidations() {
    _dataSubscription = bridge.dataChangedEvents().listen(
      (_) => unawaited(refresh()),
      onError: (_) {
        if (!_disposed) {
          unawaited(_dataSubscription?.cancel());
          _listenForInvalidations();
          unawaited(refresh());
        }
      },
      onDone: () {
        if (!_disposed) {
          _listenForInvalidations();
          unawaited(refresh());
        }
      },
    );
  }

  void _listenForProjection() {
    _projectionSubscription = bridge.projectionEvents().listen(
      (value) {
        projection = value;
        notifyListeners();
      },
      onError: (_) {
        if (!_disposed) {
          unawaited(_projectionSubscription?.cancel());
          _listenForProjection();
        }
      },
    );
  }

  Future<void> refresh() async {
    loading = true;
    notifyListeners();
    try {
      final results = await Future.wait<Object>([
        bridge.listCategories(),
        bridge.listTransactions(filter),
        bridge.aggregates(),
      ]);
      categories = results[0] as List<CategoryDto>;
      transactions = results[1] as List<TransactionDto>;
      aggregate = results[2] as AggregateDto;
      errorMessage = null;
    } catch (error) {
      errorMessage = bridgeMessage(error);
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> setFilter(TransactionFilterDto value) async {
    filter = value;
    await refresh();
  }

  Future<void> createCategory(String name) async {
    await bridge.createCategory(name);
    await refresh();
  }

  Future<void> renameCategory(String id, String name) async {
    await bridge.updateCategory(id, name);
    await refresh();
  }

  Future<void> saveTransaction({
    String? id,
    required int occurredAtMs,
    required String categoryId,
    required int amountMinor,
    required String description,
  }) async {
    if (id == null) {
      await bridge.createTransaction(
        occurredAtMs: occurredAtMs,
        categoryId: categoryId,
        amountMinor: amountMinor,
        description: description,
      );
    } else {
      await bridge.updateTransaction(
        id: id,
        occurredAtMs: occurredAtMs,
        categoryId: categoryId,
        amountMinor: amountMinor,
        description: description,
      );
    }
    await refresh();
  }

  Future<void> deleteTransaction(String id) async {
    await bridge.deleteTransaction(id);
    await refresh();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_dataSubscription?.cancel());
    unawaited(_projectionSubscription?.cancel());
    unawaited(_errorSubscription?.cancel());
    super.dispose();
  }
}

final class DevicesController extends ChangeNotifier {
  DevicesController(this.bridge);

  final FinanceBridge bridge;
  PairingStateDto pairing = const PairingStateDto(
    kind: PairingKindDto.idle,
    localConfirmed: false,
    remoteConfirmed: false,
  );
  List<PairingCandidateDto> candidates = const [];
  List<TrustedDeviceDto> devices = const [];
  SyncStatusDto syncStatus = SyncStatusDto.offline;
  String? errorMessage;
  bool busy = false;
  bool _disposed = false;
  Timer? _clock;
  final List<StreamSubscription<Object?>> _subscriptions = [];

  Future<void> start() async {
    _subscriptions
      ..add(bridge.pairingStateEvents().listen(_setPairing, onError: _setError))
      ..add(
        bridge.pairingCandidateEvents().listen((value) {
          candidates = value;
          notifyListeners();
        }, onError: _setError),
      )
      ..add(
        bridge.connectionStateEvents().listen((value) {
          devices = value;
          notifyListeners();
        }, onError: _setError),
      )
      ..add(
        bridge.syncStatusEvents().listen((value) {
          syncStatus = value;
          notifyListeners();
        }, onError: _setError),
      );
    await refreshDevices();
    syncStatus = await bridge.syncStatus();
    notifyListeners();
  }

  int get remainingSeconds {
    final deadline = pairing.deadlineMs;
    if (deadline == null) return 0;
    final remaining = deadline - DateTime.now().millisecondsSinceEpoch;
    return remaining <= 0 ? 0 : (remaining / 1000).ceil();
  }

  Future<void> beginPairing({int durationMs = 120000}) =>
      _run(() => bridge.startPairing(durationMs));
  Future<void> stopPairing() => _run(bridge.stopPairing);
  Future<void> selectCandidate(PairingCandidateDto candidate) =>
      _run(() => bridge.connectPairingCandidate(candidate));
  Future<void> confirm() => _run(() async {
    final session = pairing.sessionId;
    if (session == null) return;
    await bridge.confirmPairing(session);
  });
  Future<void> reject() => _run(() => bridge.rejectPairing(pairing.sessionId));

  Future<void> rename(TrustedDeviceDto device, String name) async {
    await _run(() => bridge.renameTrustedDevice(device.deviceId, name));
    await refreshDevices();
  }

  Future<void> revoke(TrustedDeviceDto device) async {
    await _run(
      () => bridge.revokeTrustedDevice(
        device.deviceId,
        DateTime.now().millisecondsSinceEpoch,
      ),
    );
    await refreshDevices();
  }

  Future<void> refreshDevices() async {
    try {
      devices = await bridge.trustedDevices();
      errorMessage = null;
    } catch (error) {
      _setError(error);
    }
    notifyListeners();
  }

  Future<void> _run(Future<void> Function() operation) async {
    busy = true;
    errorMessage = null;
    notifyListeners();
    try {
      await operation();
    } catch (error) {
      _setError(error);
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  void _setPairing(PairingStateDto value) {
    pairing = value;
    _clock?.cancel();
    if (value.deadlineMs != null) {
      _clock = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (remainingSeconds == 0) timer.cancel();
        if (!_disposed) notifyListeners();
      });
    }
    if (value.kind == PairingKindDto.trusted) {
      unawaited(refreshDevices());
    }
    notifyListeners();
  }

  void _setError(Object error) {
    errorMessage = bridgeMessage(error);
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _clock?.cancel();
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    super.dispose();
  }
}

String bridgeMessage(Object error) => switch (error) {
  BridgeError(:final message) => message,
  _ => 'The local finance service encountered an unexpected error.',
};
