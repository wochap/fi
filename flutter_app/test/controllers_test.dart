import 'package:fi/controllers.dart';
import 'package:fi/src/rust/api/models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_bridge.dart';

void main() {
  test('commands and filters always refresh from bridge queries', () async {
    final bridge = FakeFinanceBridge()
      ..categories.add(const CategoryDto(id: 'food', name: 'Food'));
    final controller = FinanceController(bridge);
    await controller.start();
    await controller.createCategory('Travel');
    expect(controller.categories.map((item) => item.name), contains('Travel'));
    const filter = TransactionFilterDto(
      text: 'lunch',
      categoryId: 'food',
      fromMs: 100,
      throughMs: 200,
    );
    await controller.setFilter(filter);
    expect(bridge.requestedFilters.last, filter);
    await controller.saveTransaction(
      occurredAtMs: 150,
      categoryId: 'food',
      amountMinor: -725,
      description: 'Lunch',
    );
    expect(controller.transactions.single.description, 'Lunch');
    await controller.deleteTransaction(controller.transactions.single.id);
    expect(bridge.deletedTransactions, ['transaction-1']);
    expect(controller.transactions, isEmpty);
    controller.dispose();
  });

  test(
    'invalidation refreshes queries and a closed stream is recreated',
    () async {
      final bridge = FakeFinanceBridge();
      final controller = FinanceController(bridge);
      await controller.start();
      final calls = bridge.listTransactionCalls;
      bridge.emitDataChanged();
      await Future<void>.delayed(Duration.zero);
      expect(bridge.listTransactionCalls, greaterThan(calls));
      await bridge.closeDataStream();
      await Future<void>.delayed(Duration.zero);
      expect(bridge.dataSubscriptions, greaterThanOrEqualTo(2));
      controller.dispose();
    },
  );
}
