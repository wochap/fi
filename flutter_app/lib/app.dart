import 'dart:async';

import 'package:fi/bridge/finance_bridge.dart';
import 'package:fi/controllers.dart';
import 'package:fi/src/rust/api/models.dart';
import 'package:fi/transactions_page.dart';
import 'package:flutter/material.dart';

class FinanceApp extends StatefulWidget {
  const FinanceApp({
    required this.bridge,
    required this.initializeRust,
    required this.dataDirProvider,
    super.key,
  });

  final FinanceBridge bridge;
  final Future<void> Function() initializeRust;
  final Future<String> Function() dataDirProvider;

  @override
  State<FinanceApp> createState() => _FinanceAppState();
}

class _FinanceAppState extends State<FinanceApp> {
  late final BootstrapController controller;

  @override
  void initState() {
    super.initState();
    controller = BootstrapController(
      bridge: widget.bridge,
      initializeRust: widget.initializeRust,
      dataDirProvider: widget.dataDirProvider,
    );
    unawaited(controller.start());
  }

  @override
  void dispose() {
    controller.dispose();
    unawaited(widget.bridge.shutdown());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Fi',
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
      useMaterial3: true,
    ),
    home: ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        if (controller.loading) {
          return const _CenteredSurface(
            key: Key('bootstrap-loading'),
            child: CircularProgressIndicator(),
          );
        }
        if (controller.fatalError case final message?) {
          return _CenteredSurface(
            key: const Key('bootstrap-error'),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline, size: 48),
                const SizedBox(height: 12),
                Text(message, textAlign: TextAlign.center),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: controller.start,
                  child: const Text('Retry'),
                ),
              ],
            ),
          );
        }
        return switch (controller.state?.kind) {
          BootstrapKindDto.ready => FinanceShell(bridge: widget.bridge),
          BootstrapKindDto.needsDecision => OnboardingPage(
            controller: controller,
          ),
          BootstrapKindDto.joining => const _CenteredSurface(
            child: Text('Waiting for this local dataset to become available.'),
          ),
          BootstrapKindDto.creating => const _CenteredSurface(
            child: CircularProgressIndicator(),
          ),
          _ => const _CenteredSurface(
            child: Text('The local finance service is unavailable.'),
          ),
        };
      },
    ),
  );
}

class _CenteredSurface extends StatelessWidget {
  const _CenteredSurface({required this.child, super.key});
  final Widget child;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: Padding(padding: const EdgeInsets.all(24), child: child),
    ),
  );
}

class OnboardingPage extends StatelessWidget {
  const OnboardingPage({required this.controller, super.key});
  final BootstrapController controller;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Your private finance dataset',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 12),
              const Text(
                'Create a new local dataset to begin. Nothing is sent to a server.',
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                key: const Key('create-dataset'),
                onPressed: controller.creating
                    ? null
                    : controller.createNewDataset,
                icon: const Icon(Icons.add_circle_outline),
                label: Text(
                  controller.creating ? 'Creating…' : 'Create new dataset',
                ),
              ),
              const SizedBox(height: 12),
              const OutlinedButton(
                onPressed: null,
                child: Text('Join an existing dataset'),
              ),
              const SizedBox(height: 8),
              const Text(
                'Joining will be available after secure device pairing is implemented.',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class FinanceShell extends StatefulWidget {
  const FinanceShell({required this.bridge, super.key});
  final FinanceBridge bridge;

  @override
  State<FinanceShell> createState() => _FinanceShellState();
}

class _FinanceShellState extends State<FinanceShell> {
  late final FinanceController controller;
  int selected = 0;

  @override
  void initState() {
    super.initState();
    controller = FinanceController(widget.bridge);
    unawaited(controller.start());
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => Scaffold(
      appBar: AppBar(
        title: const Text('Fi'),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Center(child: Text(_statusText(controller.projection))),
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final page = IndexedStack(
            index: selected,
            children: [
              TransactionsPage(controller: controller),
              CategoriesPage(controller: controller),
            ],
          );
          if (constraints.maxWidth >= 720) {
            return Row(
              children: [
                NavigationRail(
                  selectedIndex: selected,
                  onDestinationSelected: (value) {
                    setState(() => selected = value);
                  },
                  labelType: NavigationRailLabelType.all,
                  destinations: const [
                    NavigationRailDestination(
                      icon: Icon(Icons.receipt_long),
                      label: Text('Transactions'),
                    ),
                    NavigationRailDestination(
                      icon: Icon(Icons.category),
                      label: Text('Categories'),
                    ),
                  ],
                ),
                const VerticalDivider(width: 1),
                Expanded(child: page),
              ],
            );
          }
          return page;
        },
      ),
      bottomNavigationBar: MediaQuery.sizeOf(context).width < 720
          ? NavigationBar(
              selectedIndex: selected,
              onDestinationSelected: (value) {
                setState(() => selected = value);
              },
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.receipt_long),
                  label: 'Transactions',
                ),
                NavigationDestination(
                  icon: Icon(Icons.category),
                  label: 'Categories',
                ),
              ],
            )
          : null,
    ),
  );
}

String _statusText(ProjectionDto projection) => switch (projection.kind) {
  ProjectionKindDto.ready => 'Local data ready · Offline',
  ProjectionKindDto.projecting ||
  ProjectionKindDto.rebuilding => 'Updating local data · Offline',
  ProjectionKindDto.failed => 'Local data needs attention · Offline',
  _ => 'Local only · Offline',
};

class CategoriesPage extends StatelessWidget {
  const CategoriesPage({required this.controller, super.key});
  final FinanceController controller;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      _PageHeader(
        title: 'Categories',
        actionLabel: 'New category',
        onAction: () => _editCategory(context),
      ),
      if (controller.errorMessage case final error?) _ErrorBanner(error),
      Expanded(
        child: controller.loading && controller.categories.isEmpty
            ? const Center(child: CircularProgressIndicator())
            : ListView.builder(
                itemCount: controller.categories.length,
                itemBuilder: (context, index) {
                  final category = controller.categories[index];
                  return ListTile(
                    leading: const Icon(Icons.label_outline),
                    title: Text(category.name),
                    trailing: IconButton(
                      tooltip: 'Rename',
                      icon: const Icon(Icons.edit_outlined),
                      onPressed: () => _editCategory(context, category),
                    ),
                  );
                },
              ),
      ),
    ],
  );

  Future<void> _editCategory(
    BuildContext context, [
    CategoryDto? category,
  ]) async {
    final field = TextEditingController(text: category?.name);
    String? error;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(category == null ? 'New category' : 'Rename category'),
          content: TextField(
            key: const Key('category-name'),
            controller: field,
            autofocus: true,
            decoration: InputDecoration(labelText: 'Name', errorText: error),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () async {
                try {
                  if (category == null) {
                    await controller.createCategory(field.text);
                  } else {
                    await controller.renameCategory(category.id, field.text);
                  }
                  if (context.mounted) Navigator.pop(context);
                } catch (failure) {
                  setState(() => error = bridgeMessage(failure));
                }
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    field.dispose();
  }
}

class _PageHeader extends StatelessWidget {
  const _PageHeader({
    required this.title,
    required this.actionLabel,
    required this.onAction,
  });
  final String title;
  final String actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(16),
    child: Row(
      children: [
        Expanded(
          child: Text(title, style: Theme.of(context).textTheme.headlineSmall),
        ),
        FilledButton.icon(
          onPressed: onAction,
          icon: const Icon(Icons.add),
          label: Text(actionLabel),
        ),
      ],
    ),
  );
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner(this.message);
  final String message;

  @override
  Widget build(BuildContext context) => MaterialBanner(
    content: Text(message),
    actions: const [SizedBox.shrink()],
  );
}

void showFinanceError(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}
