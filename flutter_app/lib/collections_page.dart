import 'dart:async';
import 'dart:math' as math;

import 'package:clock/clock.dart';
import 'package:fi/l10n/error_text.dart';
import 'package:fi/l10n/l10n.dart';
import 'package:fi/status_time.dart';
import 'package:fi/theme/action_sheet.dart';
import 'package:fi/theme/fi_icons.dart';
import 'package:fi/ui_prefs.dart';
import 'package:fi/controllers.dart';
import 'package:fi/field_editor.dart';
import 'package:fi/field_registry.dart';
import 'package:fi/help_button.dart';
import 'package:fi/help_copy.dart';
import 'package:fi/record_form.dart';
import 'package:fi/src/rust/api/models.dart';
import 'package:fi/theme/form_errors.dart';
import 'package:fi/theme/form_surface.dart';
import 'package:fi/theme/inputs.dart';
import 'package:fi/theme/nocturne.dart';
import 'package:fi/theme/nocturne_widgets.dart';
import 'package:fi/theme/side_sheet.dart';
import 'package:fi/widgets/computed_field_editor.dart';
import 'package:fi/widgets/expression_builder.dart';
import 'package:fi/widgets/query_builder.dart';
import 'package:fi/widgets/query_editor_dialog.dart';
import 'package:fi/widgets/widget_dashboard.dart';
import 'package:fi/voice/controller.dart';
import 'package:fi/voice/engine.dart';
import 'package:fi/voice/mic_button.dart';
import 'package:fi/voice/panel.dart';
import 'package:fi/voice/patch.dart';
import 'package:fi/voice/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:two_dimensional_scrollables/two_dimensional_scrollables.dart';

/// Below this content width the collection screen drops the table for a card list and the
/// header actions collapse to icons.
const double _wideContent = 760;

/// Below this screen width the app is laid out for a phone.
const double _phoneScreen = 720;

/// `6 records · 3 fields`.
String _counts(AppLocalizations l, int records, int fields) =>
    '${l.collectionsRecordCount(records)} · ${l.collectionsFieldCount(fields)}';

/// What a collection row's menu can do.
enum _CollectionAction {
  rename(FiIcons.edit),
  duplicate(FiIcons.copy),
  importCsv(FiIcons.importFile),
  exportCsv(FiIcons.exportFile),
  exportJson(FiIcons.exportFile),
  delete(FiIcons.delete);

  const _CollectionAction(this.icon);

  final IconData icon;

  String label(AppLocalizations l) => switch (this) {
    rename => l.commonRename,
    duplicate => l.collectionsDuplicate,
    importCsv => l.collectionsImportCsv,
    exportCsv => l.collectionsExportCsv,
    exportJson => l.collectionsExportJson,
    delete => l.collectionsDeleteEllipsis,
  };

  /// The "Data" group.
  static const data = [importCsv, exportCsv, exportJson];

  ActionSheetItem<_CollectionAction> sheetItem(AppLocalizations l) =>
      ActionSheetItem(value: this, label: label(l), icon: icon);
}

/// The collections list order control: the current order, and a menu of both.
class _SortButton extends StatelessWidget {
  const _SortButton({
    required this.sort,
    required this.compact,
    required this.onSelected,
  });

  final CollectionSort sort;
  final bool compact;
  final ValueChanged<CollectionSort> onSelected;

  static String label(AppLocalizations l, CollectionSort sort) =>
      switch (sort) {
        CollectionSort.lastEdited => l.collectionsSortLastEdited,
        CollectionSort.name => l.collectionsSortName,
      };

  @override
  Widget build(BuildContext context) => PopupMenuButton<CollectionSort>(
    key: const Key('collections-sort'),
    tooltip: context.l10n.collectionsSort,
    initialValue: sort,
    onSelected: onSelected,
    itemBuilder: (_) => [
      for (final value in CollectionSort.values)
        PopupMenuItem(
          value: value,
          child: Row(
            children: [
              SizedBox(
                width: 24,
                child: value == sort
                    ? const Icon(
                        FiIcons.check,
                        size: 16,
                        color: Nocturne.accent,
                      )
                    : null,
              ),
              Text(label(context.l10n, value)),
            ],
          ),
        ),
    ],
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(FiIcons.sort, size: 16, color: Nocturne.muted(.7)),
          if (!compact) ...[
            const SizedBox(width: 6),
            Text(
              label(context.l10n, sort),
              key: const Key('collections-sort-label'),
              style: TextStyle(fontSize: 13, color: Nocturne.muted(.7)),
            ),
          ],
        ],
      ),
    ),
  );
}

class CollectionsPage extends StatelessWidget {
  const CollectionsPage({super.key, required this.controller});
  final CollectionsController controller;

  @override
  Widget build(BuildContext context) => controller.selectedCollectionId == null
      ? _collectionList(context)
      : _collection(context);

  Widget _collectionList(BuildContext context) {
    final phone = MediaQuery.sizeOf(context).width < _phoneScreen;
    final theme = Theme.of(context);
    // `clock` rather than `DateTime.now()` so widget tests can pin the time.
    final now = clock.now();
    final collections = controller.sortedCollections;
    final l = context.l10n;
    return LayoutBuilder(
      builder: (context, constraints) {
        final padding = phone
            ? const EdgeInsets.fromLTRB(18, 12, 18, 16)
            : const EdgeInsets.fromLTRB(32, 22, 32, 22);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: padding.copyWith(bottom: 16),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      l.collectionsTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: phone
                          ? theme.textTheme.headlineSmall
                          : theme.textTheme.headlineMedium,
                    ),
                  ),
                  _SortButton(
                    sort: controller.collectionSort,
                    compact: phone,
                    onSelected: controller.setCollectionSort,
                  ),
                  const SizedBox(width: 4),
                  PopupMenuButton<String>(
                    key: const Key('collections-transfer-menu'),
                    tooltip: l.collectionsImportExport,
                    icon: Icon(
                      FiIcons.importExport,
                      size: 18,
                      color: Nocturne.muted(.7),
                    ),
                    onSelected: (action) => unawaited(switch (action) {
                      'import-json' => _importJson(context),
                      'export-all' => _exportAll(context),
                      _ => _exportSelected(context),
                    }),
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        value: 'import-json',
                        child: Text(l.collectionsImportJson),
                      ),
                      PopupMenuItem(
                        value: 'export-all',
                        enabled: controller.collections.isNotEmpty,
                        child: Text(l.collectionsExportAll),
                      ),
                      PopupMenuItem(
                        value: 'export-selected',
                        enabled: controller.collections.isNotEmpty,
                        child: Text(l.collectionsExportSelected),
                      ),
                    ],
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    style: phone
                        ? FilledButton.styleFrom(minimumSize: const Size(0, 44))
                        : null,
                    onPressed: () => _editCollection(context),
                    icon: const Icon(FiIcons.add),
                    label: Text(
                      phone ? l.commonNew : l.collectionsNewCollection,
                    ),
                  ),
                ],
              ),
            ),
            if (controller.failure case final failure?)
              MaterialBanner(
                content: Text(bridgeMessage(context.l10n, failure)),
                actions: const [SizedBox.shrink()],
              ),
            Expanded(
              child: controller.loading && controller.collections.isEmpty
                  ? const Center(child: CircularProgressIndicator())
                  : controller.collections.isEmpty
                  ? Center(
                      child: Text(
                        l.collectionsEmpty,
                        style: TextStyle(color: Nocturne.muted(.6)),
                      ),
                    )
                  : ListView.separated(
                      padding: padding.copyWith(top: 0),
                      itemCount: collections.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final item = collections[index];
                        return Align(
                          alignment: Alignment.topLeft,
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 816),
                            child: _collectionCard(
                              context,
                              item,
                              now,
                              phone: phone,
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }

  /// One collection (mock collections): icon tile, name with an incomplete tag, its size,
  /// when it was last edited, and its menu. F2 on a focused row renames it.
  Widget _collectionCard(
    BuildContext context,
    CollectionDto item,
    DateTime now, {
    required bool phone,
  }) {
    final muted = TextStyle(
      fontSize: 12,
      fontFeatures: Nocturne.tabular,
      color: Nocturne.muted(.55),
    );
    final l = context.l10n;
    final edited = item.lastEditedMs == null
        ? null
        : formatStatusTime(l, item.lastEditedMs, now: now);
    final Widget details;
    if (phone) {
      details = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            item.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 2),
          Text(
            [
              l.collectionsRecordCount(item.recordCount),
              if (item.incompleteCount > 0)
                l.collectionsIncomplete(item.incompleteCount)
              else if (edited != null)
                l.collectionsEditedLower(edited),
            ].join(' · '),
            key: Key('collection-subtitle-${item.id}'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: muted,
          ),
        ],
      );
    } else {
      details = Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        item.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    if (item.incompleteCount > 0) ...[
                      const SizedBox(width: 8),
                      Tag.outline(
                        l.collectionsIncomplete(item.incompleteCount),
                        key: Key('collection-incomplete-${item.id}'),
                        leading: FiIcons.warning,
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  _counts(l, item.recordCount, item.fieldCount),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: muted,
                ),
              ],
            ),
          ),
          if (edited != null) ...[
            const SizedBox(width: 12),
            Text(
              l.collectionsEdited(edited),
              key: Key('collection-edited-${item.id}'),
              style: muted,
            ),
          ],
        ],
      );
    }
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.f2): () =>
            unawaited(_editCollection(context, item)),
      },
      child: CardListRow(
        key: ValueKey(item.id),
        child: NocturneCard(
          padding: const EdgeInsets.fromLTRB(14, 12, 4, 12),
          onTap: () => unawaited(controller.selectCollection(item.id)),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: phone ? 40 : 36),
            child: Row(
              children: [
                const IconTile(FiIcons.collection),
                const SizedBox(width: 12),
                Expanded(child: details),
                if (phone)
                  FiIconButton(
                    icon: FiIcons.more,
                    tooltip: l.collectionsActions,
                    color: Nocturne.muted(.7),
                    onPressed: () =>
                        unawaited(_collectionActionSheet(context, item)),
                  )
                else
                  PopupMenuButton<_CollectionAction>(
                    tooltip: l.collectionsActions,
                    icon: Icon(FiIcons.more, color: Nocturne.muted(.7)),
                    onSelected: (action) =>
                        _runCollectionAction(context, item, action),
                    itemBuilder: (_) => _collectionMenuItems(l),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The row menu on wide screens: Rename (F2), Duplicate, the "Data" group, then Delete….
  List<PopupMenuEntry<_CollectionAction>> _collectionMenuItems(
    AppLocalizations l,
  ) => [
    PopupMenuItem(
      value: _CollectionAction.rename,
      child: Row(
        children: [
          Expanded(child: Text(l.commonRename)),
          const SizedBox(width: 24),
          Text(
            'F2',
            style: TextStyle(
              fontSize: 12,
              fontFamily: Nocturne.monoFamily,
              color: Nocturne.muted(.45),
            ),
          ),
        ],
      ),
    ),
    PopupMenuItem(
      value: _CollectionAction.duplicate,
      child: Text(l.collectionsDuplicate),
    ),
    const PopupMenuDivider(),
    PopupMenuItem(
      enabled: false,
      height: 28,
      child: SectionLabel(l.collectionsData),
    ),
    for (final action in _CollectionAction.data)
      PopupMenuItem(value: action, child: Text(action.label(l))),
    const PopupMenuDivider(),
    PopupMenuItem(
      value: _CollectionAction.delete,
      child: Text(_CollectionAction.delete.label(l)),
    ),
  ];

  void _runCollectionAction(
    BuildContext context,
    CollectionDto item,
    _CollectionAction action,
  ) {
    switch (action) {
      case _CollectionAction.rename:
        unawaited(_editCollection(context, item));
      case _CollectionAction.duplicate:
        unawaited(_duplicateCollection(context, item));
      case _CollectionAction.importCsv:
        unawaited(_importCsv(context, item));
      case _CollectionAction.exportCsv:
        unawaited(_export(context, () => controller.exportCsv(item)));
      case _CollectionAction.exportJson:
        unawaited(_export(context, () => controller.exportJson([item])));
      case _CollectionAction.delete:
        unawaited(_confirmDeleteCollection(context, item));
    }
  }

  /// The row menu on a phone (mock collections): an action sheet headed by the collection, with the same
  /// actions in the same groups as the wide popup.
  Future<void> _collectionActionSheet(
    BuildContext context,
    CollectionDto item,
  ) async {
    final l = context.l10n;
    final chosen = await showActionSheet<_CollectionAction>(
      context,
      icon: FiIcons.collection,
      title: item.name,
      subtitle: _counts(l, item.recordCount, item.fieldCount),
      groups: [
        ActionSheetGroup([
          for (final action in [
            _CollectionAction.rename,
            _CollectionAction.duplicate,
          ])
            action.sheetItem(l),
        ]),
        ActionSheetGroup([
          for (final action in _CollectionAction.data) action.sheetItem(l),
        ], label: l.collectionsData),
        ActionSheetGroup([_CollectionAction.delete.sheetItem(l)]),
      ],
    );
    if (chosen == null || !context.mounted) return;
    _runCollectionAction(context, item, chosen);
  }

  /// Runs one export and reports the written file. A dismissed save dialog reports nothing; a
  /// failed export (for example two columns sharing a name) reports Rust's reason.
  Future<void> _export(
    BuildContext context,
    Future<String?> Function() export,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final l = context.l10n;
    try {
      final name = await export();
      if (name != null) {
        messenger.showSnackBar(
          SnackBar(content: Text(l.collectionsExportedTo(name))),
        );
      }
    } catch (failure) {
      messenger.showSnackBar(
        SnackBar(content: Text(bridgeMessage(l, failure))),
      );
    }
  }

  Future<void> _exportAll(BuildContext context) =>
      _export(context, controller.exportAll);

  /// Picks several collections, then exports them as one JSON document. Dismissing the picker
  /// or choosing none exports nothing.
  Future<void> _exportSelected(BuildContext context) async {
    final chosen = <String>{};
    final l = context.l10n;
    final picked = await showDialog<List<CollectionDto>>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(l.collectionsExportTitle),
          content: SizedBox(
            width: 360,
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final item in controller.collections)
                  CheckboxListTile(
                    key: Key('export-pick-${item.id}'),
                    value: chosen.contains(item.id),
                    title: Text(item.name),
                    onChanged: (value) => setState(
                      () => value == true
                          ? chosen.add(item.id)
                          : chosen.remove(item.id),
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog),
              child: Text(l.commonCancel),
            ),
            FilledButton(
              key: const Key('confirm-export-selected'),
              onPressed: chosen.isEmpty
                  ? null
                  : () => Navigator.pop(dialog, [
                      for (final item in controller.collections)
                        if (chosen.contains(item.id)) item,
                    ]),
              child: Text(l.collectionsExport),
            ),
          ],
        ),
      ),
    );
    if (picked == null || picked.isEmpty || !context.mounted) return;
    await _export(context, () => controller.exportJson(picked));
  }

  /// Imports a CSV file into [item] and reports the count, or the row, column and reason that
  /// stopped it. A dismissed open dialog reports nothing.
  Future<void> _importCsv(BuildContext context, CollectionDto item) =>
      _import(context, () => controller.importCsv(item.id), csv: true);

  Future<void> _importJson(BuildContext context) =>
      _import(context, controller.importJson, csv: false);

  Future<void> _import(
    BuildContext context,
    Future<ImportOutcomeDto?> Function() run, {
    required bool csv,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    final l = context.l10n;
    try {
      final outcome = await run();
      if (outcome == null) return;
      messenger.showSnackBar(
        SnackBar(content: Text(importOutcomeMessage(l, outcome, csv: csv))),
      );
    } catch (failure) {
      messenger.showSnackBar(
        SnackBar(content: Text(bridgeMessage(l, failure))),
      );
    }
  }

  /// Confirms before deleting a collection, stating what goes with it. Counts
  /// load while the dialog is open; until then, or if loading fails, a generic
  /// sentence stands in and Delete stays usable. Dismissing sends no command.
  Future<void> _confirmDeleteCollection(
    BuildContext context,
    CollectionDto item,
  ) async {
    // Ignored here so a failed count never surfaces as an unhandled error;
    // the FutureBuilder still sees it and keeps the generic sentence.
    final contents = controller.contentsOf(item.id)..ignore();
    final l = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(l.collectionsDeleteTitle(item.name)),
        content: FutureBuilder<CollectionContents>(
          future: contents,
          builder: (context, snapshot) => Text(
            snapshot.hasData
                ? collectionContentsSentence(l, snapshot.requireData)
                : l.collectionsDeleteGeneric,
            style: const TextStyle(fontFeatures: Nocturne.tabular),
          ),
        ),
        actions: [
          TextButton(
            key: const Key('dismiss-delete-collection'),
            onPressed: () => Navigator.pop(dialog, false),
            child: Text(l.commonCancel),
          ),
          FilledButton(
            key: const Key('confirm-delete-collection'),
            onPressed: () => Navigator.pop(dialog, true),
            child: Text(l.commonDelete),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await controller.deleteCollection(item.id);
  }

  Widget _collection(BuildContext context) {
    final schema = controller.schema;
    if (schema == null) return const Center(child: CircularProgressIndicator());
    final fields = schema.fields.where((field) => !field.deleted).toList()
      ..sort(_fieldOrder);
    final phone = MediaQuery.sizeOf(context).width < _phoneScreen;
    final l = context.l10n;
    return LayoutBuilder(
      builder: (context, constraints) {
        // Between the phone breakpoint and a content width that fits four labelled buttons, the
        // header's actions collapse to icons; the records stay a table.
        final wide = !phone && constraints.maxWidth >= _wideContent;
        final selecting = controller.selecting;
        final horizontal = phone ? 16.0 : (wide ? 32.0 : 24.0);
        final records = controller.records;
        final incomplete = records.where((record) => !record.valid).length;
        // The table scrolls inside its own viewport so its header row can stay pinned; it is
        // never taller than the screen leaves room for.
        final tableHeight = math.min(
          _RecordTable.headerHeight + records.length * _RecordTable.rowHeight,
          math.max(constraints.maxHeight - 160, 280.0),
        );
        final list = CustomScrollView(
          slivers: [
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                horizontal,
                phone ? 8 : 22,
                horizontal,
                0,
              ),
              sliver: SliverList.list(
                children: [
                  if (selecting)
                    _selectionBar(context, schema, wide: wide)
                  else if (phone)
                    _phoneHeader(context, schema, fields)
                  else if (wide)
                    _wideHeader(context, schema, fields)
                  else
                    _narrowHeader(context, schema, fields),
                  if (controller.failure case final failure?)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: MaterialBanner(
                        content: Text(bridgeMessage(context.l10n, failure)),
                        actions: const [SizedBox.shrink()],
                      ),
                    ),
                  const SizedBox(height: 22),
                  // The dashboard sits above the records and never replaces record CRUD. While
                  // selecting, it recedes so the action bar reads as the one active surface.
                  AnimatedOpacity(
                    duration: const Duration(milliseconds: 150),
                    opacity: selecting ? .4 : 1,
                    child: IgnorePointer(
                      ignoring: selecting,
                      child: CollectionDashboard(controller: controller),
                    ),
                  ),
                  const SizedBox(height: 22),
                  Row(
                    children: [
                      SectionLabel(l.recordsSection),
                      const Spacer(),
                      if (phone && records.isNotEmpty)
                        Flexible(
                          flex: 3,
                          child: Text(
                            l.recordsNewestFirst,
                            textAlign: TextAlign.right,
                            style: TextStyle(
                              fontSize: 12,
                              color: Nocturne.muted(.5),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (phone && incomplete > 0) ...[
                    _IncompleteLine(count: incomplete, phone: true),
                    const SizedBox(height: 10),
                  ],
                ],
              ),
            ),
            if (records.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 32),
                  child: Center(
                    child: Text(
                      l.recordsEmpty,
                      style: TextStyle(color: Nocturne.muted(.55)),
                    ),
                  ),
                ),
              )
            else if (!phone) ...[
              SliverPadding(
                padding: EdgeInsets.symmetric(horizontal: horizontal),
                sliver: SliverToBoxAdapter(
                  child: _RecordTable(
                    height: tableHeight,
                    fields: fields,
                    records: records,
                    selecting: selecting,
                    selectedIds: controller.selectedRecordIds,
                    onOpen: (record) => _openRecord(context, schema, record),
                    onToggle: controller.toggleSelected,
                    onDelete: (record) =>
                        unawaited(controller.deleteRecord(record.id)),
                  ),
                ),
              ),
              if (incomplete > 0)
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(horizontal, 12, horizontal, 0),
                  sliver: SliverToBoxAdapter(
                    child: _IncompleteLine(count: incomplete, phone: false),
                  ),
                ),
            ] else
              SliverPadding(
                padding: EdgeInsets.symmetric(horizontal: horizontal),
                sliver: SliverList.separated(
                  itemCount: records.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) =>
                      _recordCard(context, schema, fields, records[index]),
                ),
              ),
            SliverToBoxAdapter(child: SizedBox(height: phone ? 96 : 32)),
          ],
        );
        if (!phone || selecting) return list;
        return Stack(
          children: [
            Positioned.fill(child: list),
            Positioned(
              right: 18,
              bottom: 18,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(Nocturne.radius),
                  boxShadow: Nocturne.shadowMd,
                ),
                child: SizedBox(
                  height: 52,
                  child: FloatingActionButton.extended(
                    tooltip: l.recordsNewRecord,
                    onPressed: () => _recordEditor(context, schema),
                    icon: const Icon(FiIcons.add, size: 18),
                    label: Text(l.recordsFab),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// Opens [record] for editing, or toggles it while selecting. An incomplete record opens on
  /// its first missing required field.
  void _openRecord(
    BuildContext context,
    CollectionSchemaDto schema,
    RecordDto record,
  ) {
    if (controller.selecting) {
      controller.toggleSelected(record.id);
      return;
    }
    final fields = schema.fields.where((field) => !field.deleted).toList()
      ..sort(_fieldOrder);
    final missing = missingRequiredFields(record, fields);
    unawaited(_recordEditor(context, schema, record, missing.firstOrNull?.id));
  }

  String _countLine(
    AppLocalizations l,
    CollectionSchemaDto schema,
    List<FieldDefinitionDto> fields,
  ) => _counts(l, controller.records.length, fields.length);

  /// The list row's entry for the open collection, for the actions it shares with the list.
  CollectionDto _openCollectionEntry(
    CollectionSchemaDto schema,
    List<FieldDefinitionDto> fields,
  ) =>
      controller.collections
          .where((item) => item.id == schema.id)
          .firstOrNull ??
      CollectionDto(
        id: schema.id,
        name: schema.name,
        description: schema.description,
        recordCount: controller.records.length,
        fieldCount: fields.length,
        incompleteCount: controller.records
            .where((record) => !record.valid)
            .length,
      );

  /// Sends an inline title rename. The input is already closed, so a rejection keeps the
  /// previous name and is reported in a snackbar rather than under a field.
  Future<void> _renameInline(
    BuildContext context,
    String id,
    String name,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final l = context.l10n;
    try {
      await controller.renameCollection(id, name);
    } catch (failure) {
      messenger.showSnackBar(
        SnackBar(content: Text(bridgeMessage(l, failure))),
      );
    }
  }

  /// Breadcrumb over the title, and the collection's actions as labelled buttons (mock collection-records).
  Widget _wideHeader(
    BuildContext context,
    CollectionSchemaDto schema,
    List<FieldDefinitionDto> fields,
  ) {
    final theme = Theme.of(context);
    final l = context.l10n;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Tooltip(
                message: l.recordsBackToCollections,
                child: InkWell(
                  borderRadius: BorderRadius.circular(Nocturne.radiusSm),
                  onTap: () => unawaited(controller.selectCollection(null)),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          FiIcons.back,
                          size: 13,
                          color: Nocturne.muted(.55),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          l.recordsBreadcrumb,
                          style: TextStyle(
                            fontSize: 12,
                            color: Nocturne.muted(.55),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Flexible(
                    child: _EditableTitle(
                      name: schema.name,
                      style: theme.textTheme.headlineMedium,
                      onRename: (name) =>
                          unawaited(_renameInline(context, schema.id, name)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    _countLine(l, schema, fields),
                    style: TextStyle(
                      fontSize: 13,
                      fontFeatures: Nocturne.tabular,
                      color: Nocturne.muted(.55),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(width: 16),
        OutlinedButton.icon(
          onPressed: () => _schemaEditor(context, schema),
          icon: const Icon(FiIcons.filter),
          label: Text(l.recordsSchema),
        ),
        const SizedBox(width: 8),
        OutlinedButton.icon(
          onPressed: () => _queryEditor(context, schema),
          icon: const Icon(FiIcons.query),
          label: Text(l.recordsQueries),
        ),
        const SizedBox(width: 8),
        OutlinedButton.icon(
          key: const Key('select-records'),
          onPressed: controller.records.isEmpty
              ? null
              : controller.startSelection,
          icon: const Icon(FiIcons.select),
          label: Text(l.recordsSelect),
        ),
        const SizedBox(width: 8),
        FilledButton.icon(
          onPressed: () => _recordEditor(context, schema),
          icon: const Icon(FiIcons.add),
          label: Text(l.recordsNewRecord),
        ),
      ],
    );
  }

  /// Back and title with the counts, and the actions as icons: the wide header when the content
  /// is too narrow for labelled buttons but the screen is not a phone.
  Widget _narrowHeader(
    BuildContext context,
    CollectionSchemaDto schema,
    List<FieldDefinitionDto> fields,
  ) => Row(
    children: [
      FiIconButton(
        icon: FiIcons.back,
        tooltip: context.l10n.recordsBackToCollections,
        size: 20,
        onPressed: () => unawaited(controller.selectCollection(null)),
      ),
      const SizedBox(width: 2),
      Expanded(child: _compactTitle(context, schema, fields)),
      FiIconButton(
        icon: FiIcons.filter,
        tooltip: context.l10n.recordsSchema,
        size: 20,
        onPressed: () => _schemaEditor(context, schema),
      ),
      FiIconButton(
        icon: FiIcons.query,
        tooltip: context.l10n.recordsQueries,
        size: 20,
        onPressed: () => _queryEditor(context, schema),
      ),
      FiIconButton(
        key: const Key('select-records'),
        icon: FiIcons.select,
        tooltip: context.l10n.recordsSelect,
        size: 20,
        onPressed: controller.records.isEmpty
            ? null
            : controller.startSelection,
      ),
      FiIconButton(
        icon: FiIcons.add,
        tooltip: context.l10n.recordsNewRecord,
        size: 20,
        onPressed: () => _recordEditor(context, schema),
      ),
    ],
  );

  /// The phone top bar (mock collection-records): back, title with the counts, Schema, and a ⋮ menu holding
  /// Queries, Select records and Collection actions…. New record is the floating button below.
  Widget _phoneHeader(
    BuildContext context,
    CollectionSchemaDto schema,
    List<FieldDefinitionDto> fields,
  ) => Row(
    key: const Key('collection-phone-header'),
    children: [
      FiIconButton(
        icon: FiIcons.back,
        tooltip: context.l10n.recordsBackToCollections,
        size: 20,
        onPressed: () => unawaited(controller.selectCollection(null)),
      ),
      const SizedBox(width: 2),
      Expanded(child: _compactTitle(context, schema, fields)),
      FiIconButton(
        icon: FiIcons.filter,
        tooltip: context.l10n.recordsSchema,
        size: 20,
        onPressed: () => _schemaEditor(context, schema),
      ),
      PopupMenuButton<String>(
        key: const Key('collection-more'),
        tooltip: context.l10n.recordsMoreActions,
        icon: const Icon(FiIcons.more, size: 20),
        style: IconButton.styleFrom(
          minimumSize: const Size(Nocturne.touchTarget, Nocturne.touchTarget),
          foregroundColor: Nocturne.text,
        ),
        onSelected: (action) {
          switch (action) {
            case 'queries':
              unawaited(_queryEditor(context, schema));
            case 'select':
              controller.startSelection();
            default:
              unawaited(
                _collectionActionSheet(
                  context,
                  _openCollectionEntry(schema, fields),
                ),
              );
          }
        },
        itemBuilder: (_) => [
          PopupMenuItem(
            value: 'queries',
            child: Text(context.l10n.recordsQueries),
          ),
          PopupMenuItem(
            key: const Key('select-records'),
            value: 'select',
            enabled: controller.records.isNotEmpty,
            child: Text(context.l10n.recordsSelectRecords),
          ),
          PopupMenuItem(
            value: 'actions',
            child: Text(context.l10n.recordsCollectionActions),
          ),
        ],
      ),
    ],
  );

  Widget _compactTitle(
    BuildContext context,
    CollectionSchemaDto schema,
    List<FieldDefinitionDto> fields,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _EditableTitle(
        name: schema.name,
        style: const TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w500,
          height: 1.2,
        ),
        onRename: (name) => unawaited(_renameInline(context, schema.id, name)),
      ),
      Text(
        _countLine(context.l10n, schema, fields),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 11,
          fontFeatures: Nocturne.tabular,
          color: Nocturne.muted(.55),
        ),
      ),
    ],
  );

  /// One phone record card (mock collection-records): the first three fields with their type icons, then how
  /// many more there are and when the record was created. Long press starts selection; while
  /// selecting a tap toggles.
  Widget _recordCard(
    BuildContext context,
    CollectionSchemaDto schema,
    List<FieldDefinitionDto> fields,
    RecordDto record,
  ) {
    final selecting = controller.selecting;
    final selected =
        selecting && controller.selectedRecordIds.contains(record.id);
    const registry = FieldRendererRegistry();
    final missing = {
      for (final field in missingRequiredFields(record, fields)) field.id,
    };
    final shown = fields.take(3).toList();
    final more = fields.length - shown.length;
    final l = context.l10n;
    final created = switch (record.createdAtMs) {
      final ms? => DateFormat.yMMMd(
        l.localeName,
      ).format(DateTime.fromMillisecondsSinceEpoch(ms)),
      null => null,
    };
    final footer = [
      if (more > 0) l.recordsMoreFields(more),
      ?created,
    ].join(' · ');
    final muted = TextStyle(fontSize: 12, color: Nocturne.muted(.55));
    return Material(
      key: ValueKey(record.id),
      color: selected ? Nocturne.accent900 : Nocturne.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Nocturne.radius),
        side: BorderSide(
          color: selected ? Nocturne.accent700 : Nocturne.neutral800,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(Nocturne.radius),
        onLongPress: () => controller.toggleSelected(record.id),
        onTap: () => _openRecord(context, schema, record),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 4, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (selecting)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Checkbox(
                    value: selected,
                    onChanged: (_) => controller.toggleSelected(record.id),
                  ),
                ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 6,
                  children: [
                    if (!record.valid)
                      Tag.outline(
                        l.recordsIncomplete,
                        key: Key('record-incomplete-${record.id}'),
                        leading: FiIcons.warning,
                      ),
                    if (fields.isEmpty)
                      Text(
                        record.id,
                        style: const TextStyle(
                          fontSize: 12,
                          fontFamily: Nocturne.monoFamily,
                        ),
                      ),
                    for (final field in shown)
                      Row(
                        children: [
                          Icon(
                            fieldTypeIcon(field.fieldType.kind),
                            size: 14,
                            color: Nocturne.muted(.5),
                          ),
                          const SizedBox(width: 8),
                          SizedBox(
                            width: 96,
                            child: Text(
                              field.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: muted,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: missing.contains(field.id)
                                ? const Align(
                                    alignment: Alignment.centerLeft,
                                    child: NeededMarker(),
                                  )
                                : _cell(
                                    registry.displayText(
                                      field,
                                      _recordValue(record, field.id),
                                      human: true,
                                      short: true,
                                      l: context.l10n,
                                      decimalSeparator: decimalSeparatorOf(
                                        context,
                                      ),
                                    ),
                                    selected: selected,
                                  ),
                          ),
                        ],
                      ),
                    if (footer.isNotEmpty)
                      Text(
                        footer,
                        style: muted.copyWith(fontFeatures: Nocturne.tabular),
                      ),
                  ],
                ),
              ),
              // The two delete affordances never coexist: single delete is immediate, the batch
              // one is confirmed.
              if (!selecting)
                FiIconButton(
                  icon: FiIcons.delete,
                  tooltip: l.recordsDeleteRecord,
                  color: Nocturne.muted(.45),
                  onPressed: () =>
                      unawaited(controller.deleteRecord(record.id)),
                ),
            ],
          ),
        ),
      ),
    );
  }

  static Widget _cell(String? text, {bool selected = false}) => Text(
    text ?? '—',
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: TextStyle(
      fontSize: 14,
      fontFeatures: Nocturne.tabular,
      color: text == null
          ? Nocturne.muted(.4)
          : selected
          ? Nocturne.accent100
          : Nocturne.text,
    ),
  );

  Future<void> _editCollection(
    BuildContext context, [
    CollectionDto? collection,
  ]) async {
    final name = TextEditingController(text: collection?.name);
    final description = TextEditingController(text: collection?.description);
    // Rust names the collection's name `name` or `collection_name`; both belong to Name.
    const nameKeys = {'name', 'collection_name'};
    var issues = FormIssues.none;
    await showFormSurface<void>(
      context,
      builder: (route) => StatefulBuilder(
        builder: (context, setState) => FormSurface(
          title: collection == null
              ? context.l10n.collectionsNewCollection
              : context.l10n.collectionsRenameTitle,
          width: 420,
          showRequiredLegend: true,
          body: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 14,
            children: [
              FiTextInput(
                key: const Key('collection-name'),
                controller: name,
                autofocus: true,
                label: context.l10n.collectionsSortName,
                required: true,
                errors: issues.fieldLines(context.l10n, 'name'),
                // The shown issue is about the old text, so it goes as soon as the name changes.
                onChanged: (_) {
                  if (issues.of('name').isEmpty) return;
                  setState(() => issues = issues.without('name'));
                },
              ),
              if (collection == null)
                FiTextInput(
                  controller: description,
                  label: context.l10n.collectionsDescription,
                ),
            ],
          ),
          errors: issues.formLines(context.l10n),
          primaryLabel: context.l10n.commonSave,
          onPrimary: () async {
            try {
              if (collection == null) {
                await controller.createCollection(name.text, description.text);
              } else {
                await controller.renameCollection(collection.id, name.text);
              }
              if (route.mounted) Navigator.pop(route);
            } catch (failure) {
              setState(
                () => issues = FormIssues.from(
                  failure,
                ).keyed({for (final key in nameKeys) key: 'name'}),
              );
            }
          },
        ),
      ),
    );
  }

  /// Names the copy of [source] (fields, queries and widgets; no records). The list refreshes
  /// on success and the selection stays put; dismissing sends no command.
  Future<void> _duplicateCollection(
    BuildContext context,
    CollectionDto source,
  ) async {
    final name = TextEditingController(
      text: context.l10n.collectionsCopyName(source.name),
    );
    const nameKeys = {'name', 'collection_name'};
    var issues = FormIssues.none;
    await showFormSurface<void>(
      context,
      builder: (route) => StatefulBuilder(
        builder: (context, setState) => FormSurface(
          title: context.l10n.collectionsDuplicateTitle,
          width: 420,
          showRequiredLegend: true,
          body: FiTextInput(
            key: const Key('duplicate-collection-name'),
            controller: name,
            autofocus: true,
            label: context.l10n.collectionsSortName,
            required: true,
            errors: issues.fieldLines(context.l10n, 'name'),
            onChanged: (_) {
              if (issues.of('name').isEmpty) return;
              setState(() => issues = issues.without('name'));
            },
          ),
          errors: issues.formLines(context.l10n),
          primaryLabel: context.l10n.commonSave,
          onPrimary: () async {
            try {
              await controller.cloneCollection(source.id, name.text.trim());
              if (route.mounted) Navigator.pop(route);
            } catch (failure) {
              setState(
                () => issues = FormIssues.from(
                  failure,
                ).keyed({for (final key in nameKeys) key: 'name'}),
              );
            }
          },
        ),
      ),
    );
  }

  /// The schema as a side sheet (mock schema-sheet): reorderable field rows, and a new field added inline
  /// below them rather than in a second, stacked dialog.
  /// The collection schema (mocks schema-sheet, schema-field-editor): a side sheet of field rows on desktop, where a
  /// new field and an edited one open as inline panels; a bottom sheet of rows on a phone, where
  /// each field opens as its own pushed screen.
  Future<void> _schemaEditor(
    BuildContext context,
    CollectionSchemaDto schema,
  ) async {
    final phone = MediaQuery.sizeOf(context).width < _phoneScreen;
    final l = context.l10n;

    /// The field whose inline panel is open: its id, '' for a new field, null for none.
    String? editing;
    await showSideSheet(
      context,
      kicker: schema.name,
      kickerView: ListenableBuilder(
        listenable: controller,
        builder: (_, _) {
          final count =
              controller.schema?.fields
                  .where((field) => !field.deleted)
                  .length ??
              0;
          return Kicker(
            '${controller.schema?.name ?? schema.name} · '
            '${l.collectionsFieldCount(count)}',
          );
        },
      ),
      title: l.recordsSchemaTitle,
      footerNote: phone ? l.recordsReorderPhone : l.recordsReorderDesktop,
      body: (sheet) => StatefulBuilder(
        builder: (sheet, setState) => ListenableBuilder(
          listenable: controller,
          builder: (sheet, _) {
            final fields = [
              ...?controller.schema?.fields.where((field) => !field.deleted),
            ]..sort(_fieldOrder);
            void reorder(int oldIndex, int newIndex) {
              if (newIndex > oldIndex) newIndex--;
              final moved = fields.removeAt(oldIndex);
              fields.insert(newIndex, moved);
              unawaited(
                controller.reorderFields(
                  fields.map((field) => field.id).toList(),
                ),
              );
            }

            if (phone) {
              return ListView(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                children: [
                  ReorderableListView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    buildDefaultDragHandles: false,
                    itemCount: fields.length,
                    onReorder: reorder,
                    itemBuilder: (context, index) =>
                        ReorderableDelayedDragStartListener(
                          key: ValueKey(fields[index].id),
                          index: index,
                          child: Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: _phoneSchemaRow(sheet, fields[index]),
                          ),
                        ),
                  ),
                  const SizedBox(height: 4),
                  SizedBox(
                    height: 52,
                    child: DashedSlot(
                      key: const Key('add-field'),
                      onTap: () => _openFieldScreen(sheet),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(FiIcons.add),
                          const SizedBox(width: 8),
                          Text(l.recordsAddField),
                        ],
                      ),
                    ),
                  ),
                ],
              );
            }
            return ListView(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              children: [
                ReorderableListView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  buildDefaultDragHandles: false,
                  itemCount: fields.length,
                  onReorder: reorder,
                  itemBuilder: (context, index) => Padding(
                    key: ValueKey(fields[index].id),
                    padding: const EdgeInsets.only(bottom: 6),
                    child: editing == fields[index].id
                        ? FieldEditorBody(
                            controller: controller,
                            existing: fields[index],
                            onClosed: () => setState(() => editing = null),
                          )
                        : _schemaRow(
                            context,
                            fields[index],
                            index,
                            () => setState(() => editing = fields[index].id),
                          ),
                  ),
                ),
                const SizedBox(height: 4),
                if (editing == '')
                  FieldEditorBody(
                    controller: controller,
                    onClosed: () => setState(() => editing = null),
                  )
                else
                  SizedBox(
                    height: 40,
                    child: DashedSlot(
                      key: const Key('new-field'),
                      onTap: () => setState(() => editing = ''),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(FiIcons.add),
                          const SizedBox(width: 8),
                          Text(l.recordsAddField),
                        ],
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  /// A desktop schema row: drag handle, type icon, name with the required mark, summary, a
  /// delete icon shown on hover or focus, and a chevron.
  Widget _schemaRow(
    BuildContext context,
    FieldDefinitionDto field,
    int index,
    VoidCallback onTap,
  ) => _DesktopSchemaRow(
    index: index,
    icon: fieldTypeIcon(field.fieldType.kind),
    text: _schemaRowText(field),
    deleteTooltip: context.l10n.fieldEditorDeleteFieldNamed(field.name),
    deleteKey: Key('field-row-delete-${field.id}'),
    onTap: onTap,
    onDelete: () => unawaited(confirmDeleteField(context, controller, field)),
  );

  Widget _schemaRowText(FieldDefinitionDto field) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      DefaultTextStyle.merge(
        style: const TextStyle(fontSize: 14),
        child: field.required_
            ? requiredLabel(field.name)
            : Text(field.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      Builder(
        builder: (context) => Text(
          fieldSummary(context.l10n, field),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 12, color: Nocturne.muted(.55)),
        ),
      ),
    ],
  );

  /// A phone schema row: at least 52px, type icon, name and summary, and a chevron. Tapping it
  /// pushes the field's screen; a long press drags it.
  Widget _phoneSchemaRow(BuildContext sheet, FieldDefinitionDto field) =>
      Material(
        color: Nocturne.bg,
        borderRadius: BorderRadius.circular(Nocturne.radius),
        child: InkWell(
          borderRadius: BorderRadius.circular(Nocturne.radius),
          onTap: () => _openFieldScreen(sheet, field),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 52),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(
                children: [
                  IconTile(fieldTypeIcon(field.fieldType.kind)),
                  const SizedBox(width: 12),
                  Expanded(child: _schemaRowText(field)),
                  Icon(
                    FiIcons.chevronRight,
                    size: 16,
                    color: Nocturne.muted(.45),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

  Future<void> _openFieldScreen(
    BuildContext sheet, [
    FieldDefinitionDto? existing,
  ]) => Navigator.of(sheet).push(
    MaterialPageRoute<void>(
      builder: (_) => FieldEditorScreen(
        controller: controller,
        collectionName: controller.schema?.name ?? '',
        existing: existing,
      ),
    ),
  );

  /// One computed field in the sheet. Tapping opens the editor pre-filled; a definition the
  /// builder cannot represent stays visible with its diagnostic but does not open.
  Widget _computedFieldTile(
    BuildContext context,
    CollectionSchemaDto schema,
    ComputedFieldDefinitionDto item,
  ) {
    final editable = isEditableComputedField(item);
    final l = context.l10n;
    void open() => unawaited(
      showComputedFieldEditor(
        context,
        controller: controller,
        schema: schema,
        existing: item,
      ),
    );
    return _SheetRow(
      key: ValueKey('computed-${item.id}'),
      icon: FiIcons.formula,
      title: item.name,
      subtitle: editable
          ? null
          : item.unsupportedBodyJson != null
          ? l.recordsComputedNewer('${item.expressionVersion}')
          : l.recordsComputedUnsupported,
      tag: editable
          ? '${describeValueType(context.l10n, item.declaredType)}'
                '${item.nullable ? ' · ${l.recordsMayBeEmpty}' : ''}'
          : null,
      onTap: editable ? open : null,
      actions: [
        if (editable)
          IconButton(
            tooltip: l.recordsEditComputed,
            icon: const Icon(FiIcons.edit),
            onPressed: open,
          ),
        IconButton(
          tooltip: l.recordsRemoveComputed,
          icon: const Icon(FiIcons.delete),
          onPressed: () => unawaited(controller.removeComputedField(item.id)),
        ),
      ],
    );
  }

  /// Computed fields and saved queries as a side sheet, the same pattern as the schema (mock queries).
  Future<void> _queryEditor(
    BuildContext context,
    CollectionSchemaDto schema,
  ) async {
    final l = context.l10n;
    Widget heading(String title, HelpId help, String description) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: SectionLabel(title)),
            HelpButton(help),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text(
            description,
            style: TextStyle(fontSize: 12, color: Nocturne.muted(.55)),
          ),
        ),
      ],
    );

    await showSideSheet(
      context,
      kicker: schema.name,
      title: l.recordsComputedSheetTitle,
      body: (sheet) => ListenableBuilder(
        listenable: controller,
        builder: (sheet, _) => ListView(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          children: [
            heading(
              l.recordsComputedFields,
              HelpId.computedFields,
              l.recordsComputedFieldsHint,
            ),
            for (final item in controller.computedFields)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: _computedFieldTile(sheet, schema, item),
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const Key('add-computed-field'),
                onPressed: () => unawaited(
                  showComputedFieldEditor(
                    sheet,
                    controller: controller,
                    schema: schema,
                  ),
                ),
                icon: const Icon(FiIcons.add),
                label: Text(l.recordsAddComputed),
              ),
            ),
            const SizedBox(height: 22),
            heading(
              l.recordsSavedQueries,
              HelpId.querySavedQueries,
              l.recordsSavedQueriesHint,
            ),
            for (final item in controller.queryDefinitions)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: _SheetRow(
                  key: ValueKey('saved-query-${item.id}'),
                  icon: _queryIcon(item),
                  title: item.name,
                  subtitle:
                      '${describeQuery(l, item, schema)} · '
                      '${l.recordsUsedBy(widgetsUsingQuery(controller, item.id))}',
                  actions: [
                    IconButton(
                      key: ValueKey('edit-query-${item.id}'),
                      tooltip: l.recordsEditQuery,
                      icon: const Icon(FiIcons.edit),
                      onPressed: () => unawaited(
                        showSavedQueryEditor(
                          sheet,
                          controller: controller,
                          schema: schema,
                          definition: item,
                          // Editing in place keeps the id, so every widget that references
                          // this query evaluates the edited definition.
                          onSave: controller.updateQueryDefinition,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: l.recordsRemoveQuery,
                      icon: const Icon(FiIcons.delete),
                      onPressed: () =>
                          unawaited(controller.removeQueryDefinition(item.id)),
                    ),
                  ],
                ),
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => controller.createQueryDefinition(
                  QueryDefinitionDto(
                    id: '',
                    collectionId: schema.id,
                    name: l.recordsCountQueryName,
                    queryVersion: 1,
                    query: CollectionQueryDto(
                      collectionId: schema.id,
                      shape: const QueryShapeDto(
                        kind: QueryShapeKindDto.scalar,
                        aggregation: AggregationDto(
                          kind: AggregationKindDto.count,
                        ),
                        fields: [],
                      ),
                      sorting: const [],
                      calendar: const CalendarPolicyDto(
                        timezone: 'UTC',
                        weekStart: WeekStartDto.monday,
                      ),
                    ),
                    order: controller.queryDefinitions.length,
                    deleted: false,
                  ),
                ),
                icon: const Icon(FiIcons.add),
                label: Text(l.recordsAddCountQuery),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Replaces the collection header while records are being selected (mock collection-selection).
  Widget _selectionBar(
    BuildContext context,
    CollectionSchemaDto schema, {
    required bool wide,
  }) {
    final count = controller.selectedRecordIds.length;
    final l = context.l10n;
    final unselected = controller.records
        .where((record) => !controller.selectedRecordIds.contains(record.id))
        .map((record) => record.id)
        .toList();
    final onAccent = IconButton.styleFrom(foregroundColor: Nocturne.accent100);
    final outlined = OutlinedButton.styleFrom(
      foregroundColor: Nocturne.accent100,
      side: const BorderSide(color: Nocturne.accent700),
    );
    void selectAll() {
      for (final id in unselected) {
        controller.toggleSelected(id);
      }
    }

    void edit() => unawaited(_batchEdit(context, schema));
    void delete() => unawaited(_batchDelete(context));
    return Container(
      padding: const EdgeInsets.fromLTRB(4, 6, 12, 6),
      decoration: BoxDecoration(
        color: Nocturne.accent900,
        borderRadius: BorderRadius.circular(Nocturne.radius),
        border: Border.all(color: Nocturne.accent700),
      ),
      child: Row(
        children: [
          IconButton(
            key: const Key('cancel-selection'),
            tooltip: l.commonCancel,
            style: onAccent,
            onPressed: controller.clearSelection,
            icon: const Icon(FiIcons.close),
          ),
          const SizedBox(width: 8),
          Flexible(
            flex: 2,
            child: Text(
              l.recordsSelected(count),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w500,
                color: Nocturne.accent100,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              l.recordsInCollection(schema.name),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, color: Nocturne.accent200),
            ),
          ),
          if (wide) ...[
            TextButton.icon(
              style: TextButton.styleFrom(foregroundColor: Nocturne.accent100),
              onPressed: unselected.isEmpty ? null : selectAll,
              icon: const Icon(FiIcons.selectAll),
              label: Text(l.recordsSelectAll),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              key: const Key('batch-edit'),
              style: outlined,
              onPressed: count == 0 ? null : edit,
              icon: const Icon(FiIcons.edit),
              label: Text(l.commonEdit),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              key: const Key('batch-delete'),
              style: outlined,
              onPressed: count == 0 ? null : delete,
              icon: const Icon(FiIcons.delete),
              label: Text(l.commonDelete),
            ),
          ] else ...[
            IconButton(
              tooltip: l.recordsSelectAll,
              style: onAccent,
              onPressed: unselected.isEmpty ? null : selectAll,
              icon: const Icon(FiIcons.selectAll),
            ),
            IconButton(
              key: const Key('batch-edit'),
              tooltip: l.recordsEditField,
              style: onAccent,
              onPressed: count == 0 ? null : edit,
              icon: const Icon(FiIcons.edit),
            ),
            IconButton(
              key: const Key('batch-delete'),
              tooltip: l.commonDelete,
              style: onAccent,
              onPressed: count == 0 ? null : delete,
              icon: const Icon(FiIcons.delete),
            ),
          ],
        ],
      ),
    );
  }

  /// Confirms, then deletes the whole selection in one batch. Dismissing the
  /// dialog sends no command and leaves the selection intact.
  Future<void> _batchDelete(BuildContext context) async {
    final count = controller.selectedRecordIds.length;
    final messenger = ScaffoldMessenger.of(context);
    final l = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(l.recordsBatchDeleteTitle(count)),
        content: Text(l.recordsBatchDeleteBody),
        actions: [
          TextButton(
            key: const Key('dismiss-batch-delete'),
            onPressed: () => Navigator.pop(dialog, false),
            child: Text(l.commonCancel),
          ),
          FilledButton(
            key: const Key('confirm-batch-delete'),
            onPressed: () => Navigator.pop(dialog, true),
            child: Text(l.commonDelete),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final affected = await controller.deleteSelected();
      messenger.showSnackBar(
        SnackBar(content: Text(l.recordsDeletedSnack(affected))),
      );
    } catch (_) {
      // The typed error is already on the controller's banner and the
      // selection has been pruned, so the user can retry from what is left.
    }
  }

  /// Picks one active field and one value, confirms, then sets it across the
  /// whole selection in one batch.
  Future<void> _batchEdit(
    BuildContext context,
    CollectionSchemaDto schema,
  ) async {
    final fields = schema.fields.where((field) => !field.deleted).toList()
      ..sort(_fieldOrder);
    if (fields.isEmpty) return;
    final count = controller.selectedRecordIds.length;
    final messenger = ScaffoldMessenger.of(context);
    final l = context.l10n;
    var field = fields.first;
    FieldValueDto? value;
    var issues = FormIssues.none;
    var attempted = false;

    /// A required field left empty would fail every member; say so before confirming.
    String? blocker() =>
        FieldRendererRegistry.marksRequired(field) &&
            (value?.kind ?? FieldValueKindDto.null_) == FieldValueKindDto.null_
        ? l.commonRequired
        : null;

    Future<void> apply(BuildContext route, StateSetter setState) async {
      setState(() => attempted = true);
      if (blocker() != null) return;
      final confirmed = await showDialog<bool>(
        context: route,
        builder: (dialog) => AlertDialog(
          title: Text(l.recordsBatchSetTitle(field.name, count)),
          content: Text(l.recordsBatchSetBody),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: Text(l.commonCancel),
            ),
            FilledButton(
              key: const Key('confirm-batch-edit'),
              onPressed: () => Navigator.pop(dialog, true),
              child: Text(l.recordsSet),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
      try {
        final affected = await controller.setFieldOnSelected(
          field.id,
          value ?? const FieldValueDto(kind: FieldValueKindDto.null_),
        );
        if (route.mounted) Navigator.pop(route);
        messenger.showSnackBar(
          SnackBar(content: Text(l.recordsUpdatedSnack(affected))),
        );
      } catch (failure) {
        if (route.mounted) {
          setState(
            () => issues = FormIssues.from(failure).restrictTo({field.id}),
          );
        }
      }
    }

    await showFormSurface<void>(
      context,
      builder: (route) => StatefulBuilder(
        builder: (context, setState) => FormSurface(
          title: l.recordsBatchEditTitle(count),
          showRequiredLegend: FieldRendererRegistry.marksRequired(field),
          body: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 14,
            children: [
              FiSelect<String>(
                key: const Key('batch-field'),
                value: field.id,
                label: l.recordsField,
                items: [
                  for (final item in fields)
                    DropdownMenuItem(value: item.id, child: Text(item.name)),
                ],
                onChanged: (id) => setState(() {
                  field = fields.firstWhere((item) => item.id == id);
                  value = null;
                  issues = FormIssues.none;
                }),
              ),
              const FieldRendererRegistry().editor(
                field,
                value,
                (updated) => setState(() {
                  value = updated;
                  issues = issues.without(field.id);
                }),
                errors: [
                  ...issues.fieldLines(
                    context.l10n,
                    field.id,
                    field: field,
                    decimalSeparator: decimalSeparatorOf(context),
                  ),
                  if (attempted) ?blocker(),
                ],
                quickFill: true,
              ),
            ],
          ),
          errors: issues.formLines(context.l10n),
          primaryKey: const Key('batch-edit-continue'),
          primaryLabel: l.recordsContinue,
          onPrimary: () => apply(route, setState),
        ),
      ),
    );
  }

  /// A dialog on a wide screen; on a phone, a bottom sheet with large inputs (mocks record-form-empty, record-form-errors, record-form-edit).
  /// [prefill] opens a new record holding those values instead of the defaults (Duplicate).
  Future<void> _recordEditor(
    BuildContext context,
    CollectionSchemaDto schema, [
    RecordDto? existing,
    String? focusFieldId,
    Map<String, FieldValueDto>? prefill,
  ]) {
    // The sheet is its own route, so the shell's voice scope is carried into it.
    final voice = VoiceScope.scopeOf(context);
    return showFormSurface<void>(
      context,
      builder: (route) => VoiceScope(
        services: voice?.services,
        openSettings: voice?.openSettings,
        child: _RecordEditorForm(
          controller: controller,
          schema: schema,
          existing: existing,
          focusFieldId: focusFieldId,
          prefill: prefill,
          onDuplicate: (values) {
            if (context.mounted) {
              unawaited(_recordEditor(context, schema, null, null, values));
            }
          },
        ),
      ),
    );
  }
}

/// How long the record editor waits after an edit before asking Rust to re-validate the draft.
const _draftValidationDelay = Duration(milliseconds: 200);

/// Creates or edits one record. Errors stay hidden until the first Save; after it, every edit
/// re-runs Rust's dry-run validation (debounced) so each error clears as soon as it is fixed.
/// The collection title, renamed in place: a double tap swaps the text for an input with the
/// name selected. Enter or losing focus submits; Escape cancels. The trimmed name goes to
/// [onRename] at most once per edit, and only when it is non-empty and differs from [name].
class _EditableTitle extends StatefulWidget {
  const _EditableTitle({
    required this.name,
    required this.style,
    required this.onRename,
  });

  final String name;
  final TextStyle? style;
  final ValueChanged<String> onRename;

  @override
  State<_EditableTitle> createState() => _EditableTitleState();
}

class _EditableTitleState extends State<_EditableTitle> {
  final _text = TextEditingController();
  final _focus = FocusNode();
  var _editing = false;

  /// Set once the edit is submitted or cancelled, so the blur that follows closing the input
  /// neither saves a cancelled edit nor sends a submitted one twice.
  var _closed = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_focusChanged);
  }

  @override
  void dispose() {
    _focus
      ..removeListener(_focusChanged)
      ..dispose();
    _text.dispose();
    super.dispose();
  }

  void _focusChanged() {
    if (!_focus.hasFocus) _submit();
  }

  void _start() {
    _text.value = TextEditingValue(
      text: widget.name,
      selection: TextSelection(baseOffset: 0, extentOffset: widget.name.length),
    );
    setState(() {
      _editing = true;
      _closed = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _editing) _focus.requestFocus();
    });
  }

  /// Closes the input before any rename is awaited, so the shown name always comes from the
  /// projection.
  bool _close() {
    if (!_editing || _closed) return false;
    _closed = true;
    setState(() => _editing = false);
    return true;
  }

  void _submit() {
    final name = _text.text.trim();
    if (!_close()) return;
    // Empty or unchanged is a cancel: nothing is sent and no error is shown.
    if (name.isEmpty || name == widget.name) return;
    widget.onRename(name);
  }

  void _cancel() => _close();

  @override
  Widget build(BuildContext context) {
    if (!_editing) {
      return GestureDetector(
        onDoubleTap: _start,
        // Holds the editor's caret room, so entering edit mode moves nothing beside the title.
        child: Padding(
          padding: const EdgeInsetsDirectional.only(
            end: FiEditableText.caretAllowance,
          ),
          child: Text(
            widget.name,
            key: const Key('collection-title'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: widget.style,
          ),
        ),
      );
    }
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): _cancel},
      child: FiEditableText(
        key: const Key('collection-title-input'),
        controller: _text,
        focusNode: _focus,
        // Resolved the way the title's `Text` resolves it, so both render alike.
        style: DefaultTextStyle.of(context).style.merge(widget.style),
        onSubmitted: (_) => _submit(),
      ),
    );
  }
}

class _RecordEditorForm extends StatefulWidget {
  const _RecordEditorForm({
    required this.controller,
    required this.schema,
    this.existing,
    this.focusFieldId,
    this.prefill,
    this.onDuplicate,
  });

  final CollectionsController controller;
  final CollectionSchemaDto schema;
  final RecordDto? existing;

  /// The field to scroll to and focus on open: an incomplete record's first missing one.
  final String? focusFieldId;

  /// A new record's values in place of the defaults, from Duplicate.
  final Map<String, FieldValueDto>? prefill;

  /// Opens a new-record editor holding these values, after this editor has closed.
  final ValueChanged<Map<String, FieldValueDto>>? onDuplicate;

  @override
  State<_RecordEditorForm> createState() => _RecordEditorFormState();
}

/// Today in the device's local calendar, as a timezone-free epoch day.
int _localEpochDay() {
  final now = clock.now();
  return DateTime.utc(now.year, now.month, now.day).millisecondsSinceEpoch ~/
      Duration.millisecondsPerDay;
}

/// The value a field's declared default seeds a new record with: the fixed default, or for a
/// relative Date default the local [today] plus the declared days. Null without a default.
FieldValueDto? _seededDefault(FieldDefinitionDto field, int today) {
  if (field.defaultValue case final value?
      when value.kind != FieldValueKindDto.null_) {
    return value;
  }
  if (field.defaultRelativeDays case final days?
      when field.fieldType.kind == FieldTypeKindDto.date) {
    return FieldValueDto(
      kind: FieldValueKindDto.date,
      integerValue: today + days,
    );
  }
  return null;
}

/// The values a new record opens with: every declared default (a relative Date default resolved
/// from the local [today]), plus the minimum for a required slider without one, since a slider
/// has no empty position to leave it at. Rust applies the same defaults on create, so saving an
/// untouched form stores what it did before seeding.
Map<String, FieldValueDto> _newRecordSeeds(
  CollectionSchemaDto schema, {
  required int today,
}) => {
  for (final field in schema.fields.where((field) => !field.deleted))
    if (_seededDefault(field, today) case final value?)
      field.id: value
    else if (field.required_ &&
        field.fieldType.kind == FieldTypeKindDto.integer &&
        field.display.slider &&
        field.validation.minInteger != null &&
        field.validation.maxInteger != null)
      field.id: FieldValueDto(
        kind: FieldValueKindDto.integer,
        integerValue: field.validation.minInteger,
      ),
};

class _RecordEditorFormState extends State<_RecordEditorForm> {
  late final _stored = <String, FieldValueDto>{
    for (final item in widget.existing?.values ?? const <RecordValueDto>[])
      item.fieldId: item.value,
  };
  late final _seeds = widget.existing == null && widget.prefill == null
      ? _newRecordSeeds(widget.schema, today: _localEpochDay())
      : const <String, FieldValueDto>{};
  late final values = <String, FieldValueDto>{
    ..._seeds,
    ...?widget.prefill,
    ..._stored,
  };
  late final fields =
      widget.schema.fields.where((field) => !field.deleted).toList()
        ..sort(_fieldOrder);
  late final _fieldIds = {for (final field in fields) field.id};

  /// Fields still holding their seeded default; each shows the Default marker until changed.
  late final _defaulted = {
    for (final field in fields)
      if (_seeds.containsKey(field.id) && _seededDefault(field, 0) != null)
        field.id,
  };

  /// A record opened because the list marks it invalid shows its problems straight away.
  late var attempted = widget.existing?.valid == false;
  late var issues = attempted
      ? _diagnosticIssues(widget.existing!).restrictTo(_fieldIds)
      : FormIssues.none;
  Timer? _debounce;

  /// Bumped per validation or save, so a slower, older answer never replaces a newer one.
  var _request = 0;

  /// The required fields the opened record was missing; each shows Needed until it holds a value.
  late final _needed = {
    if (widget.existing case final record?)
      for (final field in missingRequiredFields(record, fields)) field.id,
  };

  /// Per field: a node wrapping its control, so focus can go to its first focusable descendant,
  /// and a key to scroll it into view.
  late final _focusGroups = {
    for (final field in fields)
      field.id: FocusNode(skipTraversal: true, canRequestFocus: false),
  };
  late final _fieldKeys = {for (final field in fields) field.id: GlobalKey()};

  /// Voice fill: only in a phone New record sheet with an engine; null otherwise.
  VoiceFillController? _voice;
  var _voiceChecked = false;

  /// Bumped when voice writes a field, so its control rebuilds from the new value.
  final _revisions = <String, int>{};

  /// The values the sheet opened with, to tell whether closing loses changes.
  late final _opened = Map<String, FieldValueDto>.of(values);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_voiceChecked) return;
    _voiceChecked = true;
    final services = VoiceScope.of(context);
    if (services == null ||
        widget.existing != null ||
        FormSurfaceScope.modeOf(context) != FormSurfaceMode.sheet) {
      return;
    }
    _voice = VoiceFillController(
      services: services,
      fields: [for (final field in fields) VoiceField.fromDefinition(field)],
      readDraft: () => values,
      writeDraft: _voiceWrote,
      origins: {for (final id in _defaulted) id: FieldOrigin.defaulted},
    );
  }

  /// A voice turn (or "Clear field") replaced the draft.
  void _voiceWrote(Map<String, FieldValueDto> next) {
    setState(() {
      for (final MapEntry(:key, :value) in next.entries) {
        if (values[key] == value) continue;
        values[key] = value;
        _defaulted.remove(key);
        _revisions[key] = (_revisions[key] ?? 0) + 1;
      }
    });
    // The patched draft goes through Rust's validation; issues show once Save was tried.
    _debounce?.cancel();
    _debounce = Timer(_draftValidationDelay, () async {
      final found = await _check(++_request);
      if (found != null && attempted) setState(() => issues = found);
    });
  }

  bool get _changedSinceOpen {
    bool empty(FieldValueDto? value) =>
        value == null || value.kind == FieldValueKindDto.null_;
    return {...values.keys, ..._opened.keys}.any((key) {
      final now = values[key];
      final before = _opened[key];
      return !(empty(now) && empty(before)) && now != before;
    });
  }

  /// Closing while a turn runs or after changes asks first (voice sheets only).
  bool get _confirmClose =>
      _voice != null && (_voice!.busy || _changedSinceOpen);

  Future<void> _close() async {
    if (!_confirmClose) {
      Navigator.pop(context);
      return;
    }
    final l = context.l10n;
    final discard = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        key: const Key('voice-discard-dialog'),
        title: Text(l.recordDiscardTitle),
        content: Text(l.recordDiscardBody),
        actions: [
          OutlinedButton(
            key: const Key('voice-discard'),
            onPressed: () => Navigator.pop(dialog, true),
            child: Text(l.recordDiscard),
          ),
          FilledButton(
            key: const Key('voice-keep-editing'),
            onPressed: () => Navigator.pop(dialog, false),
            child: Text(l.recordKeepEditing),
          ),
        ],
      ),
    );
    if (discard != true || !mounted) return;
    await _voice?.discard();
    if (mounted) Navigator.pop(context);
  }

  bool _stillNeeded(String fieldId) =>
      _needed.contains(fieldId) &&
      (values[fieldId]?.kind ?? FieldValueKindDto.null_) ==
          FieldValueKindDto.null_;

  @override
  void initState() {
    super.initState();
    if (widget.focusFieldId case final id?) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _focusField(id));
    }
  }

  /// Scrolls [fieldId] into view and puts keyboard focus in its control.
  Future<void> _focusField(String fieldId) async {
    final target = _fieldKeys[fieldId]?.currentContext;
    if (!mounted || target == null) return;
    await Scrollable.ensureVisible(
      target,
      alignment: .1,
      duration: const Duration(milliseconds: 200),
    );
    if (!mounted) return;
    _focusGroups[fieldId]?.descendants
        .where((node) => node.canRequestFocus && !node.skipTraversal)
        .firstOrNull
        ?.requestFocus();
  }

  /// What a save sends: every value for a new record; for an existing one only the fields whose
  /// value changed, so an untouched field (for example one holding a removed option) is kept.
  List<RecordValueDto> get _submitted => [
    for (final MapEntry(:key, :value) in values.entries)
      if (widget.existing == null || _stored[key] != value)
        RecordValueDto(fieldId: key, value: value),
  ];

  @override
  void dispose() {
    _debounce?.cancel();
    _voice?.dispose();
    for (final node in _focusGroups.values) {
      node.dispose();
    }
    super.dispose();
  }

  void _changed(String fieldId, FieldValueDto value) {
    _voice?.fieldEdited(fieldId);
    final wasNeeded = _stillNeeded(fieldId);
    values[fieldId] = value;
    final wasDefaulted = _defaulted.remove(fieldId);
    if (wasNeeded != _stillNeeded(fieldId) || wasDefaulted) setState(() {});
    if (!attempted) return;
    _debounce?.cancel();
    _debounce = Timer(_draftValidationDelay, () => unawaited(_validate()));
  }

  /// Asks Rust for the draft's issues; null when superseded or unmounted.
  Future<FormIssues?> _check(int request) async {
    FormIssues found;
    try {
      found = FormIssues.fromIssues(
        await widget.controller.validateRecordDraft(
          _submitted,
          recordId: widget.existing?.id,
        ),
      );
    } catch (failure) {
      found = FormIssues.from(failure);
    }
    if (!mounted || request != _request) return null;
    return found.restrictTo(_fieldIds);
  }

  Future<void> _validate() async {
    final found = await _check(++_request);
    if (found != null) setState(() => issues = found);
  }

  Future<void> _save() async {
    _debounce?.cancel();
    final request = ++_request;
    setState(() => attempted = true);
    final found = await _check(request);
    if (found == null) return;
    if (!found.isEmpty) {
      setState(() => issues = found);
      _jumpToFirstError();
      return;
    }
    try {
      final existing = widget.existing;
      if (existing == null) {
        await widget.controller.createRecord(_submitted);
      } else if (_submitted.isNotEmpty) {
        await widget.controller.updateRecord(existing.id, _submitted);
      }
      if (mounted) Navigator.pop(context);
    } catch (failure) {
      // Save is authoritative: its issues replace whatever the dry run said.
      if (mounted && request == _request) {
        setState(() => issues = FormIssues.from(failure).restrictTo(_fieldIds));
        _jumpToFirstError();
      }
    }
  }

  /// After a failed save, scrolls to and focuses the first field with an error, in form order.
  void _jumpToFirstError() {
    final first = fields
        .where((field) => issues.of(field.id).isNotEmpty)
        .firstOrNull;
    if (first == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => _focusField(first.id));
  }

  /// Asks, then logically deletes the record and closes the editor. Cancelling keeps the editor
  /// open with its edits.
  Future<void> _delete() async {
    final l = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(l.recordDeleteTitle),
        content: Text(l.recordDeleteBody),
        actions: [
          TextButton(
            key: const Key('dismiss-record-delete'),
            onPressed: () => Navigator.pop(dialog, false),
            child: Text(l.commonCancel),
          ),
          FilledButton(
            key: const Key('confirm-record-delete'),
            onPressed: () => Navigator.pop(dialog, true),
            child: Text(l.commonDelete),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await widget.controller.deleteRecord(widget.existing!.id);
      if (mounted) Navigator.pop(context);
    } catch (failure) {
      if (mounted) setState(() => issues = FormIssues.from(failure));
    }
  }

  /// Closes this editor and opens a new record holding the current values, except removed
  /// options, which a new record can't pick.
  void _duplicate() {
    bool removed(FieldDefinitionDto field, FieldValueDto value) =>
        value.kind == FieldValueKindDto.enum_ &&
        field.enumOptions.any(
          (option) => option.id == value.textValue && option.deleted,
        );
    final copy = <String, FieldValueDto>{};
    for (final field in fields) {
      final value = values[field.id];
      if (value == null || value.kind == FieldValueKindDto.null_) continue;
      if (!removed(field, value)) copy[field.id] = value;
    }
    Navigator.pop(context);
    widget.onDuplicate?.call(copy);
  }

  String _contextLabel(AppLocalizations l) {
    final created = switch (widget.existing?.createdAtMs) {
      final ms? => DateFormat.yMMMd(
        l.localeName,
      ).format(DateTime.fromMillisecondsSinceEpoch(ms)),
      null => null,
    };
    return [
      l.recordsInCollection(widget.schema.name),
      if (created != null) l.recordCreated(created),
    ].join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final voice = _voice;
    if (voice == null) return _form(context);
    return ListenableBuilder(
      listenable: Listenable.merge([voice, voice.services.models]),
      builder: (context, _) => PopScope(
        canPop: !_confirmClose,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) unawaited(_close());
        },
        child: _form(context),
      ),
    );
  }

  Widget _mic(VoiceFillController voice) {
    final status = voice.services.models.status;
    return VoiceMicButton(
      state: voice.micState,
      percent: status.totalBytes == 0
          ? 0
          : status.doneBytes * 100 ~/ status.totalBytes,
      onTap: () => unawaited(voice.micTapped()),
      onHoldStart: () => unawaited(voice.holdStarted()),
      onHoldEnd: () => unawaited(voice.holdEnded()),
    );
  }

  Widget? _evidence(VoiceFillController? voice, String fieldId) {
    if (voice == null || voice.evidenceFieldId != fieldId) return null;
    final origin = voice.draftState.of(fieldId);
    final transcript = voice.transcriptOf(fieldId);
    if (!origin.isVoice || transcript == null) return null;
    return VoiceEvidencePopover(
      key: Key('voice-evidence-$fieldId'),
      transcript: transcript,
      evidence: origin.evidence ?? '',
      onClear: () => voice.clearField(fieldId),
      onDone: voice.closeEvidence,
    );
  }

  Widget _form(BuildContext context) {
    final voice = _voice;
    final dialog = FormSurfaceScope.modeOf(context) != FormSurfaceMode.sheet;
    final needed = fields.where((field) => _stillNeeded(field.id)).length;
    final existing = widget.existing;
    final l = context.l10n;
    final title = existing == null ? l.recordsNewRecord : l.recordEditTitle;
    final withErrors = attempted
        ? fields.where((field) => issues.of(field.id).isNotEmpty).toList()
        : const <FieldDefinitionDto>[];
    return FormSurface(
      // Wide screens say how much is left to finish an incomplete record.
      title: dialog && needed > 0 ? l.recordTitleNeeded(title, needed) : title,
      contextLabel: _contextLabel(l),
      showContextInDialog: true,
      closeInHeader: true,
      onCancel: voice == null ? null : () => unawaited(_close()),
      fullWidthPrimaryOnPhone: true,
      phoneFooterLeading: voice == null ? null : _mic(voice),
      top: voice == null ? null : VoicePanel(controller: voice),
      submitOnCtrlEnter: true,
      footerHint: existing == null ? l.recordFooterHint : null,
      leadingFooterAction: existing == null
          ? null
          : FormHeaderAction(
              key: const Key('record-delete'),
              icon: FiIcons.delete,
              label: l.collectionsDeleteEllipsis,
              onPressed: _delete,
            ),
      menuActions: existing == null
          ? const []
          : [
              FormMenuAction(
                key: const Key('record-duplicate'),
                label: l.collectionsDuplicate,
                icon: FiIcons.copy,
                onPressed: _duplicate,
              ),
              FormMenuAction(
                key: const Key('record-delete-menu'),
                label: l.recordDeleteRecordEllipsis,
                icon: FiIcons.delete,
                onPressed: _delete,
              ),
            ],
      summary: withErrors.isEmpty
          ? null
          : FormErrorSummary(
              count: withErrors.length,
              onShow: () => _focusField(withErrors.first.id),
            ),
      body: RecordFormBody(
        rows: [
          for (final field in fields)
            RecordFormRow(
              key: ValueKey('record-field-${field.id}'),
              id: field.id,
              name: field.name,
              required: FieldRendererRegistry.marksRequired(field),
              defaulted: _defaulted.contains(field.id),
              needed: _stillNeeded(field.id),
              voiceFilled: voice?.draftState.of(field.id).isVoice ?? false,
              onVoiceChip: voice == null
                  ? null
                  : () => voice.openEvidence(field.id),
              voiceNeeded: voice?.isNeeded(field.id) ?? false,
              belowLabel: _evidence(voice, field.id),
              control: Focus(
                focusNode: _focusGroups[field.id],
                child: KeyedSubtree(
                  key: _fieldKeys[field.id],
                  child: KeyedSubtree(
                    key: ValueKey(_revisions[field.id] ?? 0),
                    child: const FieldRendererRegistry().editor(
                      field,
                      values[field.id],
                      (value) => _changed(field.id, value),
                      errors: issues.fieldLines(
                        context.l10n,
                        field.id,
                        field: field,
                        decimalSeparator: decimalSeparatorOf(context),
                      ),
                      quickFill: true,
                      showLabel: false,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
      errors: issues.formLines(context.l10n),
      primaryLabel: existing == null ? l.recordSave : l.recordSaveChanges,
      // Voice fill never saves by itself, and Save waits while a turn listens or processes.
      onPrimary: voice?.busy ?? false ? null : _save,
    );
  }
}

/// A record's projected diagnostics as form issues: those naming a field go under it.
FormIssues _diagnosticIssues(RecordDto record) => FormIssues.fromIssues([
  for (final item in record.diagnostics)
    BridgeIssueDto(
      fields: [?item.fieldId],
      code: item.kind,
      message: item.message,
    ),
]);

/// The desktop records table (mock collection-records): a pinned header row and first column, fixed-width
/// columns that scroll sideways, incomplete rows marked by an accent edge, a warning icon and
/// "Required" cells, and a hint while columns are hidden past the trailing edge.
class _RecordTable extends StatefulWidget {
  const _RecordTable({
    required this.height,
    required this.fields,
    required this.records,
    required this.selecting,
    required this.selectedIds,
    required this.onOpen,
    required this.onToggle,
    required this.onDelete,
  });

  static const headerHeight = 40.0;
  static const rowHeight = 44.0;
  static const firstColumnWidth = 170.0;
  static const columnWidth = 150.0;
  static const actionWidth = 48.0;
  static const checkboxWidth = 40.0;

  /// The table viewport's height; the scroll hint goes below it.
  final double height;
  final List<FieldDefinitionDto> fields;
  final List<RecordDto> records;
  final bool selecting;
  final Set<String> selectedIds;
  final ValueChanged<RecordDto> onOpen;
  final ValueChanged<String> onToggle;
  final ValueChanged<RecordDto> onDelete;

  @override
  State<_RecordTable> createState() => _RecordTableState();
}

class _RecordTableState extends State<_RecordTable> {
  final _horizontal = ScrollController();
  var _moreColumns = false;

  @override
  void initState() {
    super.initState();
    _horizontal.addListener(_measure);
  }

  @override
  void dispose() {
    _horizontal
      ..removeListener(_measure)
      ..dispose();
    super.dispose();
  }

  /// Whether columns remain hidden past the trailing edge.
  void _measure() {
    if (!mounted || !_horizontal.hasClients) return;
    final position = _horizontal.position;
    final more = position.hasContentDimensions && position.extentAfter > .5;
    if (more != _moreColumns) setState(() => _moreColumns = more);
  }

  int get _dataColumns => math.max(widget.fields.length, 1);
  bool get _hasActions => !widget.selecting;

  @override
  Widget build(BuildContext context) {
    // Content or width changes can reveal or hide columns without a scroll.
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
    final table = TableView.builder(
      key: const Key('records-table'),
      horizontalDetails: ScrollableDetails.horizontal(controller: _horizontal),
      pinnedRowCount: 1,
      pinnedColumnCount: 1,
      rowCount: widget.records.length + 1,
      columnCount: _dataColumns + (_hasActions ? 1 : 0),
      columnBuilder: (index) => TableSpan(
        extent: FixedTableSpanExtent(
          index == 0
              ? _RecordTable.firstColumnWidth +
                    (widget.selecting ? _RecordTable.checkboxWidth : 0)
              : index >= _dataColumns
              ? _RecordTable.actionWidth
              : _RecordTable.columnWidth,
        ),
      ),
      rowBuilder: (index) => TableSpan(
        extent: FixedTableSpanExtent(
          index == 0 ? _RecordTable.headerHeight : _RecordTable.rowHeight,
        ),
        backgroundDecoration: TableSpanDecoration(
          color: index == 0
              ? Nocturne.bg
              : widget.selectedIds.contains(widget.records[index - 1].id)
              ? Nocturne.accent900
              : null,
        ),
        foregroundDecoration: TableSpanDecoration(
          border: TableSpanBorder(
            trailing: index == 0
                ? const BorderSide(color: Nocturne.divider)
                : BorderSide(color: Nocturne.muted(.08)),
          ),
        ),
      ),
      cellBuilder: (context, vicinity) => TableViewCell(
        child: vicinity.row == 0
            ? _header(vicinity.column)
            : _cell(widget.records[vicinity.row - 1], vicinity.column),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: widget.height,
          child: Stack(
            children: [
              Positioned.fill(child: table),
              if (_moreColumns)
                Positioned(
                  top: 0,
                  bottom: 0,
                  right: 0,
                  width: 64,
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            Nocturne.bg.withValues(alpha: 0),
                            Nocturne.bg,
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        if (_moreColumns)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              context.l10n.recordScrollMore,
              key: const Key('table-scroll-hint'),
              textAlign: TextAlign.right,
              style: TextStyle(fontSize: 12, color: Nocturne.muted(.5)),
            ),
          ),
      ],
    );
  }

  Widget _header(int column) {
    if (column >= _dataColumns || widget.fields.isEmpty) {
      return const SizedBox.shrink();
    }
    final field = widget.fields[column];
    return Container(
      key: Key('column-header-${field.id}'),
      color: Nocturne.bg,
      padding: EdgeInsets.only(
        left: column == 0 && widget.selecting ? 52 : 12,
        right: 8,
      ),
      alignment: Alignment.centerLeft,
      child: Row(
        children: [
          Icon(
            fieldTypeIcon(field.fieldType.kind),
            size: 13,
            color: Nocturne.muted(.5),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              field.name.toUpperCase(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                letterSpacing: .88,
                color: Nocturne.muted(.6),
              ),
            ),
          ),
          if (FieldRendererRegistry.marksRequired(field))
            const Text(
              ' *',
              key: Key('required-mark'),
              style: TextStyle(fontSize: 11, color: Nocturne.accent300),
            ),
        ],
      ),
    );
  }

  Widget _cell(RecordDto record, int column) {
    final selected = widget.selectedIds.contains(record.id);
    Widget content;
    if (column >= _dataColumns) {
      content = Center(
        child: FiIconButton(
          icon: FiIcons.delete,
          tooltip: context.l10n.recordsDeleteRecord,
          color: Nocturne.muted(.5),
          onPressed: () => widget.onDelete(record),
        ),
      );
      return content;
    }
    final missing = !record.valid && widget.fields.isNotEmpty
        ? missingRequiredFields(record, widget.fields).map((f) => f.id).toSet()
        : const <String>{};
    if (widget.fields.isEmpty) {
      content = CollectionsPage._cell(record.id, selected: selected);
    } else {
      final field = widget.fields[column];
      content = missing.contains(field.id)
          ? Align(
              alignment: Alignment.centerLeft,
              child: Tag(
                context.l10n.commonRequired,
                key: const Key('required-cell'),
              ),
            )
          : CollectionsPage._cell(
              const FieldRendererRegistry().displayText(
                field,
                _recordValue(record, field.id),
                human: true,
                l: context.l10n,
                decimalSeparator: decimalSeparatorOf(context),
              ),
              selected: selected,
            );
    }
    final first = column == 0;
    if (first) {
      content = Row(
        children: [
          if (widget.selecting)
            SizedBox(
              width: _RecordTable.checkboxWidth,
              child: Checkbox(
                value: selected,
                onChanged: (_) => widget.onToggle(record.id),
              ),
            ),
          if (!record.valid)
            const Padding(
              padding: EdgeInsets.only(right: 6),
              child: Icon(FiIcons.warning, size: 15, color: Nocturne.accent),
            ),
          Expanded(child: content),
        ],
      );
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => widget.onOpen(record),
      onLongPress: () => widget.onToggle(record.id),
      child: Container(
        // The pinned column is opaque so scrolled cells pass beneath it.
        decoration: first
            ? BoxDecoration(
                color: selected ? Nocturne.accent900 : Nocturne.bg,
                border: !record.valid || selected
                    ? const Border(
                        left: BorderSide(color: Nocturne.accent, width: 2),
                      )
                    : null,
              )
            : null,
        padding: EdgeInsets.only(
          left: first && (!record.valid || selected) ? 10 : 12,
          right: 8,
        ),
        alignment: Alignment.centerLeft,
        child: content,
      ),
    );
  }
}

/// The line under (or, on a phone, above) the records saying how many are incomplete.
class _IncompleteLine extends StatelessWidget {
  const _IncompleteLine({required this.count, required this.phone});

  final int count;
  final bool phone;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final lead = l.recordIncompleteLead(count);
    final action = phone
        ? l.recordTapToFinish(count)
        : l.recordClickToFinish(count);
    const style = TextStyle(fontSize: 13, color: Nocturne.accent300);
    return Row(
      key: const Key('incomplete-status'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(top: 1),
          child: Icon(FiIcons.warning, size: 15, color: Nocturne.accent),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: phone
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(lead, style: style),
                    Text(
                      action,
                      style: TextStyle(
                        fontSize: 12,
                        color: Nocturne.muted(.55),
                      ),
                    ),
                  ],
                )
              : Text('$lead. $action', style: style),
        ),
      ],
    );
  }
}

/// A row in a side sheet: an accent icon, a name with an optional line under it, an optional
/// tag, and trailing actions, on the page ground.
class _SheetRow extends StatelessWidget {
  const _SheetRow({
    required this.icon,
    required this.title,
    this.subtitle,
    this.tag,
    this.onTap,
    this.actions = const [],
    super.key,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final String? tag;
  final VoidCallback? onTap;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => Material(
    color: Nocturne.bg,
    borderRadius: BorderRadius.circular(Nocturne.radius),
    child: InkWell(
      borderRadius: BorderRadius.circular(Nocturne.radius),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
        child: IconButtonTheme(
          data: IconButtonThemeData(
            style: IconButton.styleFrom(foregroundColor: Nocturne.muted(.5)),
          ),
          child: Row(
            children: [
              Icon(icon, size: 18, color: Nocturne.accent),
              const SizedBox(width: 10),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: const TextStyle(fontSize: 14)),
                      if (subtitle case final subtitle?)
                        Text(
                          subtitle,
                          style: TextStyle(
                            fontSize: 12,
                            color: Nocturne.muted(.55),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              if (tag case final tag?) ...[
                const SizedBox(width: 8),
                Flexible(child: Tag.neutral(tag)),
              ],
              ...actions,
            ],
          ),
        ),
      ),
    ),
  );
}

IconData _queryIcon(QueryDefinitionDto query) => switch (query.query?.shape) {
  QueryShapeDto(kind: QueryShapeKindDto.scalar, :final aggregation?) =>
    aggregation.kind == AggregationKindDto.count
        ? FiIcons.number
        : FiIcons.formula,
  QueryShapeDto(kind: QueryShapeKindDto.series) => FiIcons.lineChart,
  QueryShapeDto(kind: QueryShapeKindDto.categorySeries) => FiIcons.barChart,
  _ => FiIcons.query,
};

FieldValueDto? _recordValue(RecordDto record, String fieldId) {
  for (final item in record.values) {
    if (item.fieldId == fieldId) return item.value;
  }
  return null;
}

int _fieldOrder(FieldDefinitionDto left, FieldDefinitionDto right) {
  final order = left.order.compareTo(right.order);
  return order == 0 ? left.id.compareTo(right.id) : order;
}

/// States what deleting a collection takes with it, leaving out zero counts:
/// "142 records, 3 widgets and 2 saved queries are deleted with it."
String collectionContentsSentence(
  AppLocalizations l,
  CollectionContents contents,
) {
  final parts = [
    if (contents.records > 0) l.collectionsContentsRecords(contents.records),
    if (contents.widgets > 0) l.collectionsContentsWidgets(contents.widgets),
    if (contents.savedQueries > 0)
      l.collectionsContentsSavedQueries(contents.savedQueries),
  ];
  if (parts.isEmpty) return l.collectionsContentsEmpty;
  final list = parts.length == 1
      ? parts.single
      : l.collectionsContentsJoin(
          parts.sublist(0, parts.length - 1).join(', '),
          parts.last,
        );
  final total = contents.records + contents.widgets + contents.savedQueries;
  return l.collectionsContentsDeleted(total, list);
}

/// The desktop schema row body. The delete icon stays in the tree so the keyboard reaches it, and
/// shows while the row is hovered or holds focus.
final class _DesktopSchemaRow extends StatefulWidget {
  const _DesktopSchemaRow({
    required this.index,
    required this.icon,
    required this.text,
    required this.deleteTooltip,
    required this.deleteKey,
    required this.onTap,
    required this.onDelete,
  });

  final int index;
  final IconData icon;
  final Widget text;
  final String deleteTooltip;
  final Key deleteKey;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  State<_DesktopSchemaRow> createState() => _DesktopSchemaRowState();
}

final class _DesktopSchemaRowState extends State<_DesktopSchemaRow> {
  bool hovered = false;
  bool focused = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) => setState(() => hovered = true),
    onExit: (_) => setState(() => hovered = false),
    child: Focus(
      skipTraversal: true,
      onFocusChange: (value) => setState(() => focused = value),
      child: Material(
        color: Nocturne.bg,
        borderRadius: BorderRadius.circular(Nocturne.radius),
        child: InkWell(
          borderRadius: BorderRadius.circular(Nocturne.radius),
          onTap: widget.onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 6, 12, 6),
            child: Row(
              children: [
                ReorderableDragStartListener(
                  index: widget.index,
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Icon(
                      FiIcons.dragHandle,
                      size: 18,
                      color: Nocturne.muted(.45),
                    ),
                  ),
                ),
                IconTile(widget.icon),
                const SizedBox(width: 12),
                Expanded(child: widget.text),
                Opacity(
                  opacity: hovered || focused ? 1 : 0,
                  child: FiIconButton(
                    key: widget.deleteKey,
                    icon: FiIcons.delete,
                    tooltip: widget.deleteTooltip,
                    color: Nocturne.muted(.6),
                    onPressed: widget.onDelete,
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  FiIcons.chevronRight,
                  size: 16,
                  color: Nocturne.muted(.45),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
