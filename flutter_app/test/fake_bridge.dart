import 'dart:async';

import 'package:fi/bridge/finance_bridge.dart';
import 'package:fi/src/rust/api/models.dart';

final class FakeFinanceBridge implements FinanceBridge {
  BootstrapDto bootstrap = const BootstrapDto(
    kind: BootstrapKindDto.needsDecision,
  );
  ProjectionDto projection = const ProjectionDto(
    kind: ProjectionKindDto.ready,
    checkpoint: 'test',
  );
  final List<CategoryDto> categories = [];
  final List<TransactionDto> transactions = [];
  final List<TransactionFilterDto> requestedFilters = [];
  final List<String> deletedTransactions = [];
  final bootstrapController = StreamController<BootstrapDto>.broadcast(
    sync: true,
  );
  final projectionController = StreamController<ProjectionDto>.broadcast(
    sync: true,
  );
  final errorController = StreamController<BridgeErrorEventDto>.broadcast(
    sync: true,
  );
  StreamController<DataChangedDto> dataController =
      StreamController<DataChangedDto>.broadcast(sync: true);
  int listTransactionCalls = 0;
  int dataSubscriptions = 0;
  bool failNextCategory = false;

  @override
  Future<BootstrapDto> initialize(String dataDir) async => bootstrap;
  @override
  Future<BootstrapDto> createNewDataset() async {
    bootstrap = const BootstrapDto(
      kind: BootstrapKindDto.ready,
      rootId: 'root',
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
  Stream<DataChangedDto> dataChangedEvents() {
    dataSubscriptions++;
    if (dataController.isClosed) {
      dataController = StreamController<DataChangedDto>.broadcast(sync: true);
    }
    return dataController.stream;
  }

  @override
  Stream<BridgeErrorEventDto> errorEvents() => errorController.stream;
  @override
  Future<void> shutdown() async {}
  @override
  Future<List<CategoryDto>> listCategories() async => List.of(categories);
  @override
  Future<String> createCategory(String name) async {
    if (failNextCategory) {
      failNextCategory = false;
      throw const BridgeError(
        kind: BridgeErrorKind.validation,
        field: 'name',
        message: 'Name is required.',
      );
    }
    final id = 'category-${categories.length + 1}';
    categories.add(CategoryDto(id: id, name: name));
    return id;
  }

  @override
  Future<void> updateCategory(String id, String name) async {
    final index = categories.indexWhere((item) => item.id == id);
    categories[index] = CategoryDto(id: id, name: name);
  }

  @override
  Future<void> deleteCategory(String id) async {
    categories.removeWhere((item) => item.id == id);
  }

  @override
  Future<List<TransactionDto>> listTransactions(
    TransactionFilterDto filter,
  ) async {
    listTransactionCalls++;
    requestedFilters.add(filter);
    return List.of(transactions);
  }

  @override
  Future<String> createTransaction({
    required int occurredAtMs,
    required String categoryId,
    required int amountMinor,
    required String description,
  }) async {
    final id = 'transaction-${transactions.length + 1}';
    final category = categories.firstWhere((item) => item.id == categoryId);
    transactions.add(
      TransactionDto(
        id: id,
        occurredAtMs: occurredAtMs,
        categoryId: categoryId,
        categoryName: category.name,
        categoryAvailable: true,
        amountMinor: amountMinor,
        description: description,
      ),
    );
    return id;
  }

  @override
  Future<void> updateTransaction({
    required String id,
    int? occurredAtMs,
    String? categoryId,
    int? amountMinor,
    String? description,
  }) async {
    final index = transactions.indexWhere((item) => item.id == id);
    final prior = transactions[index];
    final selected = categoryId == null
        ? null
        : categories.firstWhere((item) => item.id == categoryId);
    transactions[index] = TransactionDto(
      id: id,
      occurredAtMs: occurredAtMs ?? prior.occurredAtMs,
      categoryId: categoryId ?? prior.categoryId,
      categoryName: selected?.name ?? prior.categoryName,
      categoryAvailable: true,
      amountMinor: amountMinor ?? prior.amountMinor,
      description: description ?? prior.description,
    );
  }

  @override
  Future<void> deleteTransaction(String id) async {
    deletedTransactions.add(id);
    transactions.removeWhere((item) => item.id == id);
  }

  @override
  Future<AggregateDto> aggregates() async {
    final amounts = transactions.map((item) => item.amountMinor);
    return AggregateDto(
      balanceMinor: amounts.fold(0, (sum, value) => sum + value),
      incomeMinor: amounts
          .where((value) => value > 0)
          .fold(0, (sum, value) => sum + value),
      expenseMinor: amounts
          .where((value) => value < 0)
          .fold(0, (sum, value) => sum + value),
      transactionCount: transactions.length,
    );
  }

  void emitDataChanged() {
    dataController.add(
      const DataChangedDto(
        kinds: [DomainKindDto.categories, DomainKindDto.transactions],
        checkpoint: 'next',
      ),
    );
  }

  Future<void> closeDataStream() => dataController.close();
}
