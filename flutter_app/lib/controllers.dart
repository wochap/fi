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

String bridgeMessage(Object error) => switch (error) {
  BridgeError(:final message) => message,
  _ => 'The local finance service encountered an unexpected error.',
};
