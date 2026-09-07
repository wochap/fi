import 'dart:async';

import 'package:fi/amounts.dart';
import 'package:fi/controllers.dart';
import 'package:fi/src/rust/api/models.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

class TransactionsPage extends StatefulWidget {
  const TransactionsPage({required this.controller, super.key});
  final FinanceController controller;

  @override
  State<TransactionsPage> createState() => _TransactionsPageState();
}

class _TransactionsPageState extends State<TransactionsPage> {
  final search = TextEditingController();

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final locale = Localizations.localeOf(context).toString();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Transactions',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              ),
              FilledButton.icon(
                onPressed: controller.categories.isEmpty
                    ? null
                    : () => _editTransaction(context),
                icon: const Icon(Icons.add),
                label: const Text('New transaction'),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 260,
                child: TextField(
                  key: const Key('transaction-search'),
                  controller: search,
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    labelText: 'Search',
                  ),
                  onChanged: (value) => unawaited(
                    _replaceFilter(
                      text: value.isEmpty ? null : value,
                      replaceText: true,
                    ),
                  ),
                ),
              ),
              DropdownButton<String?>(
                key: const Key('category-filter'),
                value: controller.filter.categoryId,
                hint: const Text('All categories'),
                items: [
                  const DropdownMenuItem<String?>(
                    child: Text('All categories'),
                  ),
                  ...controller.categories.map(
                    (item) => DropdownMenuItem<String?>(
                      value: item.id,
                      child: Text(item.name),
                    ),
                  ),
                ],
                onChanged: (value) => unawaited(
                  _replaceFilter(categoryId: value, replaceCategory: true),
                ),
              ),
              OutlinedButton.icon(
                onPressed: _pickDates,
                icon: const Icon(Icons.date_range),
                label: Text(
                  controller.filter.fromMs == null
                      ? 'Any date'
                      : 'Date range set',
                ),
              ),
              if (controller.filter.fromMs != null)
                TextButton(
                  onPressed: () => unawaited(_clearDates()),
                  child: const Text('Clear dates'),
                ),
            ],
          ),
        ),
        if (controller.errorMessage case final error?)
          MaterialBanner(
            content: Text(error),
            actions: const [SizedBox.shrink()],
          ),
        Card(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: ListTile(
            title: const Text('Balance'),
            trailing: Text(
              formatMinorUnits(controller.aggregate.balanceMinor, locale),
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
        ),
        Expanded(
          child: controller.loading && controller.transactions.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : controller.transactions.isEmpty
              ? const Center(
                  child: Text('No transactions match these filters.'),
                )
              : ListView.builder(
                  itemCount: controller.transactions.length,
                  itemBuilder: (context, index) {
                    final transaction = controller.transactions[index];
                    final date = DateTime.fromMillisecondsSinceEpoch(
                      transaction.occurredAtMs,
                      isUtc: true,
                    ).toLocal();
                    final category = transaction.categoryAvailable
                        ? transaction.categoryName
                        : 'Unavailable category';
                    return ListTile(
                      title: Text(
                        transaction.description.isEmpty
                            ? 'Transaction'
                            : transaction.description,
                      ),
                      subtitle: Text(
                        '${DateFormat.yMMMd(locale).format(date)} · $category',
                      ),
                      leading: Icon(
                        transaction.amountMinor >= 0
                            ? Icons.arrow_downward
                            : Icons.arrow_upward,
                      ),
                      trailing: Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            formatMinorUnits(transaction.amountMinor, locale),
                          ),
                          IconButton(
                            tooltip: 'Edit',
                            icon: const Icon(Icons.edit_outlined),
                            onPressed: () =>
                                _editTransaction(context, transaction),
                          ),
                          IconButton(
                            tooltip: 'Delete',
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () => _delete(context, transaction),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Future<void> _replaceFilter({
    String? text,
    String? categoryId,
    bool replaceText = false,
    bool replaceCategory = false,
  }) => widget.controller.setFilter(
    TransactionFilterDto(
      text: replaceText ? text : widget.controller.filter.text,
      categoryId: replaceCategory
          ? categoryId
          : widget.controller.filter.categoryId,
      fromMs: widget.controller.filter.fromMs,
      throughMs: widget.controller.filter.throughMs,
    ),
  );

  Future<void> _pickDates() async {
    final result = await showDateRangePicker(
      context: context,
      firstDate: DateTime(1970),
      lastDate: DateTime(2200),
    );
    if (result == null) return;
    final from = DateTime.utc(
      result.start.year,
      result.start.month,
      result.start.day,
    );
    final through = DateTime.utc(
      result.end.year,
      result.end.month,
      result.end.day,
      23,
      59,
      59,
      999,
    );
    await widget.controller.setFilter(
      TransactionFilterDto(
        text: widget.controller.filter.text,
        categoryId: widget.controller.filter.categoryId,
        fromMs: from.millisecondsSinceEpoch,
        throughMs: through.millisecondsSinceEpoch,
      ),
    );
  }

  Future<void> _clearDates() => widget.controller.setFilter(
    TransactionFilterDto(
      text: widget.controller.filter.text,
      categoryId: widget.controller.filter.categoryId,
    ),
  );

  Future<void> _delete(BuildContext context, TransactionDto transaction) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete transaction?'),
        content: const Text(
          'This removes the transaction from active finance views.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await widget.controller.deleteTransaction(transaction.id);
    } catch (error) {
      if (context.mounted) _showError(context, bridgeMessage(error));
    }
  }

  Future<void> _editTransaction(
    BuildContext context, [
    TransactionDto? transaction,
  ]) async {
    final locale = Localizations.localeOf(context).toString();
    final description = TextEditingController(text: transaction?.description);
    final amount = TextEditingController(
      text: transaction == null
          ? ''
          : formatMinorUnits(transaction.amountMinor, locale),
    );
    var categoryId = transaction?.categoryAvailable == true
        ? transaction!.categoryId
        : widget.controller.categories.first.id;
    var occurred = transaction == null
        ? DateTime.now()
        : DateTime.fromMillisecondsSinceEpoch(
            transaction.occurredAtMs,
            isUtc: true,
          ).toLocal();
    String? error;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(
            transaction == null ? 'New transaction' : 'Edit transaction',
          ),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: categoryId,
                  decoration: const InputDecoration(labelText: 'Category'),
                  items: widget.controller.categories
                      .map(
                        (item) => DropdownMenuItem(
                          value: item.id,
                          child: Text(item.name),
                        ),
                      )
                      .toList(),
                  onChanged: (value) => setState(() => categoryId = value!),
                ),
                TextField(
                  key: const Key('transaction-amount'),
                  controller: amount,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                    signed: true,
                  ),
                  decoration: const InputDecoration(labelText: 'Signed amount'),
                ),
                TextField(
                  key: const Key('transaction-description'),
                  controller: description,
                  decoration: const InputDecoration(labelText: 'Description'),
                ),
                const SizedBox(height: 12),
                Text(DateFormat.yMMMd(locale).add_jm().format(occurred)),
                Wrap(
                  children: [
                    TextButton(
                      onPressed: () async {
                        final date = await showDatePicker(
                          context: context,
                          initialDate: occurred,
                          firstDate: DateTime(1970),
                          lastDate: DateTime(2200),
                        );
                        if (date != null) {
                          setState(
                            () => occurred = DateTime(
                              date.year,
                              date.month,
                              date.day,
                              occurred.hour,
                              occurred.minute,
                            ),
                          );
                        }
                      },
                      child: const Text('Change date'),
                    ),
                    TextButton(
                      onPressed: () async {
                        final time = await showTimePicker(
                          context: context,
                          initialTime: TimeOfDay.fromDateTime(occurred),
                        );
                        if (time != null) {
                          setState(
                            () => occurred = DateTime(
                              occurred.year,
                              occurred.month,
                              occurred.day,
                              time.hour,
                              time.minute,
                            ),
                          );
                        }
                      },
                      child: const Text('Change time'),
                    ),
                  ],
                ),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () async {
                try {
                  final minor = parseMinorUnits(amount.text, locale);
                  await widget.controller.saveTransaction(
                    id: transaction?.id,
                    occurredAtMs: occurred.toUtc().millisecondsSinceEpoch,
                    categoryId: categoryId,
                    amountMinor: minor,
                    description: description.text,
                  );
                  if (context.mounted) Navigator.pop(context);
                } catch (failure) {
                  setState(() {
                    error = failure is FormatException
                        ? failure.message
                        : bridgeMessage(failure);
                  });
                }
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    description.dispose();
    amount.dispose();
  }
}

void _showError(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}
