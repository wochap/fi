import 'package:fi/src/rust/api/finance.dart' as finance;
import 'package:fi/src/rust/api/lifecycle.dart' as lifecycle;
import 'package:fi/src/rust/api/models.dart';

abstract interface class FinanceBridge {
  Future<BootstrapDto> initialize(String dataDir);
  Future<BootstrapDto> createNewDataset();
  Future<ProjectionDto> projectionState();
  Stream<BootstrapDto> bootstrapEvents();
  Stream<ProjectionDto> projectionEvents();
  Stream<DataChangedDto> dataChangedEvents();
  Stream<BridgeErrorEventDto> errorEvents();
  Future<void> shutdown();

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
  @override
  Future<BootstrapDto> initialize(String dataDir) =>
      lifecycle.initialize(dataDir: dataDir);

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
