import 'dart:async';

import 'package:fi/controllers.dart';
import 'package:fi/field_registry.dart';
import 'package:fi/help_button.dart';
import 'package:fi/help_copy.dart';
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
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Below this content width the collection screen drops the table for a card list and the
/// header actions collapse to icons.
const double _wideContent = 760;

/// Below this screen width the app is laid out for a phone.
const double _phoneScreen = 720;

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
                      'Collections',
                      style: phone
                          ? theme.textTheme.headlineSmall
                          : theme.textTheme.headlineMedium,
                    ),
                  ),
                  FilledButton.icon(
                    style: phone
                        ? FilledButton.styleFrom(minimumSize: const Size(0, 44))
                        : null,
                    onPressed: () => _editCollection(context),
                    icon: const Icon(Icons.add),
                    label: Text(phone ? 'New' : 'New collection'),
                  ),
                ],
              ),
            ),
            if (controller.errorMessage case final error?)
              MaterialBanner(
                content: Text(error),
                actions: const [SizedBox.shrink()],
              ),
            Expanded(
              child: controller.loading && controller.collections.isEmpty
                  ? const Center(child: CircularProgressIndicator())
                  : controller.collections.isEmpty
                  ? Center(
                      child: Text(
                        'Create a collection to start shaping your data.',
                        style: TextStyle(color: Nocturne.muted(.6)),
                      ),
                    )
                  : ListView.separated(
                      padding: padding.copyWith(top: 0),
                      itemCount: controller.collections.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final item = controller.collections[index];
                        return Align(
                          alignment: Alignment.topLeft,
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 720),
                            child: _collectionCard(context, item),
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

  Widget _collectionCard(BuildContext context, CollectionDto item) =>
      NocturneCard(
        key: ValueKey(item.id),
        padding: const EdgeInsets.fromLTRB(14, 12, 4, 12),
        onTap: () => unawaited(controller.selectCollection(item.id)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 36),
          child: Row(
            children: [
              const IconTile(Icons.grid_view_outlined),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (item.description.isNotEmpty)
                      Text(
                        item.description,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: Nocturne.muted(.55),
                        ),
                      ),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                icon: Icon(Icons.more_vert, color: Nocturne.muted(.7)),
                onSelected: (action) {
                  if (action == 'rename') {
                    _editCollection(context, item);
                  } else {
                    unawaited(_confirmDeleteCollection(context, item));
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'rename', child: Text('Rename')),
                  PopupMenuItem(value: 'delete', child: Text('Delete')),
                ],
              ),
            ],
          ),
        ),
      );

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
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text('Delete "${item.name}"?'),
        content: FutureBuilder<CollectionContents>(
          future: contents,
          builder: (context, snapshot) => Text(
            snapshot.hasData
                ? collectionContentsSentence(snapshot.requireData)
                : 'Its records, widgets and saved queries are deleted with it.',
            style: const TextStyle(fontFeatures: Nocturne.tabular),
          ),
        ),
        actions: [
          TextButton(
            key: const Key('dismiss-delete-collection'),
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('confirm-delete-collection'),
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('Delete'),
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
    return LayoutBuilder(
      builder: (context, constraints) {
        // Narrow widths cannot fit four labelled buttons next to the title or a column per
        // field, so the same actions collapse to icons and records become a card list.
        final wide = constraints.maxWidth >= _wideContent;
        final selecting = controller.selecting;
        final horizontal = wide ? 32.0 : 16.0;
        final records = controller.records;
        final list = CustomScrollView(
          slivers: [
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                horizontal,
                wide ? 22 : 8,
                horizontal,
                0,
              ),
              sliver: SliverList.list(
                children: [
                  if (selecting)
                    _selectionBar(context, schema, wide: wide)
                  else if (wide)
                    _wideHeader(context, schema, fields)
                  else
                    _narrowHeader(context, schema, phone: phone),
                  if (controller.errorMessage case final error?)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: MaterialBanner(
                        content: Text(error),
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
                  const SectionLabel('Records'),
                  const SizedBox(height: 6),
                  if (wide && records.isNotEmpty)
                    _TableHeader(fields: fields, selecting: selecting),
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
                      'No records yet.',
                      style: TextStyle(color: Nocturne.muted(.55)),
                    ),
                  ),
                ),
              )
            else if (wide)
              SliverPadding(
                padding: EdgeInsets.symmetric(horizontal: horizontal),
                sliver: SliverList.builder(
                  itemCount: records.length,
                  itemBuilder: (context, index) =>
                      _recordRow(context, schema, fields, records[index]),
                ),
              )
            else
              SliverPadding(
                padding: EdgeInsets.symmetric(horizontal: horizontal),
                sliver: DecoratedSliver(
                  decoration: BoxDecoration(
                    color: Nocturne.surface,
                    borderRadius: BorderRadius.circular(Nocturne.radius),
                    border: Border.all(color: Nocturne.neutral800),
                  ),
                  sliver: SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    sliver: SliverList.builder(
                      itemCount: records.length,
                      itemBuilder: (context, index) => _recordCard(
                        context,
                        schema,
                        fields,
                        records[index],
                        last: index == records.length - 1,
                      ),
                    ),
                  ),
                ),
              ),
            SliverToBoxAdapter(child: SizedBox(height: wide ? 32 : 96)),
          ],
        );
        if (wide || selecting) return list;
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
                    tooltip: 'New record',
                    onPressed: () => _recordEditor(context, schema),
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('Record'),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  String _countLine(
    CollectionSchemaDto schema,
    List<FieldDefinitionDto> fields,
  ) {
    final records = controller.records.length;
    return '$records ${records == 1 ? 'record' : 'records'} · '
        '${fields.length} ${fields.length == 1 ? 'field' : 'fields'}';
  }

  /// Sends an inline title rename. The input is already closed, so a rejection keeps the
  /// previous name and is reported in a snackbar rather than under a field.
  Future<void> _renameInline(
    BuildContext context,
    String id,
    String name,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await controller.renameCollection(id, name);
    } catch (failure) {
      messenger.showSnackBar(SnackBar(content: Text(bridgeMessage(failure))));
    }
  }

  /// Breadcrumb over the title, and the collection's actions as labelled buttons (mock 1a).
  Widget _wideHeader(
    BuildContext context,
    CollectionSchemaDto schema,
    List<FieldDefinitionDto> fields,
  ) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Tooltip(
                message: 'Back to collections',
                child: InkWell(
                  borderRadius: BorderRadius.circular(Nocturne.radiusSm),
                  onTap: () => unawaited(controller.selectCollection(null)),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.arrow_back,
                          size: 13,
                          color: Nocturne.muted(.55),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          'Collections  /',
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
                    _countLine(schema, fields),
                    style: TextStyle(fontSize: 13, color: Nocturne.muted(.55)),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(width: 16),
        OutlinedButton.icon(
          onPressed: () => _schemaEditor(context, schema),
          icon: const Icon(Icons.tune),
          label: const Text('Schema'),
        ),
        const SizedBox(width: 8),
        OutlinedButton.icon(
          onPressed: () => _queryEditor(context, schema),
          icon: const Icon(Icons.query_stats),
          label: const Text('Queries'),
        ),
        const SizedBox(width: 8),
        OutlinedButton.icon(
          key: const Key('select-records'),
          onPressed: controller.records.isEmpty
              ? null
              : controller.startSelection,
          icon: const Icon(Icons.check_box_outlined),
          label: const Text('Select'),
        ),
        const SizedBox(width: 8),
        FilledButton.icon(
          onPressed: () => _recordEditor(context, schema),
          icon: const Icon(Icons.add),
          label: const Text('New record'),
        ),
      ],
    );
  }

  /// Back, title with the record count, and the actions as icons (mock 2g). New record is the
  /// floating button below.
  Widget _narrowHeader(
    BuildContext context,
    CollectionSchemaDto schema, {
    required bool phone,
  }) {
    final records = controller.records.length;
    final large = phone ? 44.0 : 36.0;
    final button = IconButton.styleFrom(
      minimumSize: Size(large, large),
      foregroundColor: Nocturne.text,
    );
    return Row(
      children: [
        IconButton(
          style: button,
          tooltip: 'Back to collections',
          onPressed: () => unawaited(controller.selectCollection(null)),
          icon: const Icon(Icons.arrow_back, size: 20),
        ),
        const SizedBox(width: 2),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _EditableTitle(
                name: schema.name,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w500,
                  height: 1.2,
                ),
                onRename: (name) =>
                    unawaited(_renameInline(context, schema.id, name)),
              ),
              Text(
                '$records ${records == 1 ? 'record' : 'records'}',
                style: TextStyle(fontSize: 11, color: Nocturne.muted(.55)),
              ),
            ],
          ),
        ),
        IconButton(
          style: button,
          tooltip: 'Schema',
          onPressed: () => _schemaEditor(context, schema),
          icon: const Icon(Icons.tune, size: 20),
        ),
        IconButton(
          style: button,
          tooltip: 'Queries',
          onPressed: () => _queryEditor(context, schema),
          icon: const Icon(Icons.query_stats, size: 20),
        ),
        IconButton(
          style: button,
          key: const Key('select-records'),
          tooltip: 'Select',
          onPressed: controller.records.isEmpty
              ? null
              : controller.startSelection,
          icon: const Icon(Icons.check_box_outlined, size: 20),
        ),
      ],
    );
  }

  /// One table row (mock 1a). Long press is the way into selection mode; once in it, a tap
  /// toggles instead of opening the editor.
  Widget _recordRow(
    BuildContext context,
    CollectionSchemaDto schema,
    List<FieldDefinitionDto> fields,
    RecordDto record,
  ) {
    final selecting = controller.selecting;
    final selected =
        selecting && controller.selectedRecordIds.contains(record.id);
    const registry = FieldRendererRegistry();
    return Column(
      key: ValueKey(record.id),
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: selected ? Nocturne.accent900 : Colors.transparent,
          child: InkWell(
            onLongPress: () => controller.toggleSelected(record.id),
            onTap: selecting
                ? () => controller.toggleSelected(record.id)
                : () => _recordEditor(context, schema, record),
            child: Container(
              constraints: const BoxConstraints(minHeight: 44),
              decoration: selected
                  ? const BoxDecoration(
                      border: Border(
                        left: BorderSide(color: Nocturne.accent, width: 2),
                      ),
                    )
                  : null,
              padding: EdgeInsets.only(left: selected ? 4 : 6, right: 4),
              child: Row(
                children: [
                  if (selecting)
                    SizedBox(
                      width: 40,
                      child: Checkbox(
                        value: selected,
                        onChanged: (_) => controller.toggleSelected(record.id),
                      ),
                    ),
                  if (!record.valid)
                    const Padding(
                      padding: EdgeInsets.only(right: 6),
                      child: Icon(
                        Icons.warning_amber,
                        size: 16,
                        color: Nocturne.error,
                      ),
                    ),
                  if (fields.isEmpty)
                    Expanded(child: Text(record.id))
                  else
                    for (final field in fields)
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          child: _cell(
                            registry.displayText(
                              field,
                              _recordValue(record, field.id),
                              human: true,
                            ),
                            selected: selected,
                          ),
                        ),
                      ),
                  if (!selecting)
                    SizedBox(
                      width: 48,
                      child: IconButton(
                        tooltip: 'Delete record',
                        style: IconButton.styleFrom(
                          foregroundColor: Nocturne.muted(.5),
                        ),
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () =>
                            unawaited(controller.deleteRecord(record.id)),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        FadedRule(color: Nocturne.muted(.08)),
      ],
    );
  }

  Widget _cell(String? text, {bool selected = false}) => Text(
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

  /// One row of the phone record list (mock 2g): first field large, second small on the right.
  Widget _recordCard(
    BuildContext context,
    CollectionSchemaDto schema,
    List<FieldDefinitionDto> fields,
    RecordDto record, {
    required bool last,
  }) {
    final selecting = controller.selecting;
    final selected =
        selecting && controller.selectedRecordIds.contains(record.id);
    const registry = FieldRendererRegistry();
    final primary = fields.isEmpty ? null : fields.first;
    final secondary = fields.length < 2 ? null : fields[1];
    final primaryText = primary == null
        ? record.id
        : registry.displayText(
            primary,
            _recordValue(record, primary.id),
            human: true,
          );
    final secondaryText = secondary == null
        ? null
        : registry.displayText(
            secondary,
            _recordValue(record, secondary.id),
            human: true,
            short: true,
          );
    return InkWell(
      key: ValueKey(record.id),
      onLongPress: () => controller.toggleSelected(record.id),
      onTap: selecting
          ? () => controller.toggleSelected(record.id)
          : () => _recordEditor(context, schema, record),
      child: Container(
        constraints: const BoxConstraints(minHeight: 56),
        decoration: last
            ? null
            : BoxDecoration(
                border: Border(bottom: BorderSide(color: Nocturne.muted(.08))),
              ),
        child: Row(
          children: [
            if (selecting)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Checkbox(
                  value: selected,
                  onChanged: (_) => controller.toggleSelected(record.id),
                ),
              ),
            if (!record.valid)
              const Padding(
                padding: EdgeInsets.only(right: 8),
                child: Icon(
                  Icons.warning_amber,
                  size: 16,
                  color: Nocturne.error,
                ),
              ),
            Expanded(
              child: Text(
                primaryText ?? '—',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 15,
                  fontFeatures: Nocturne.tabular,
                  color: primaryText == null
                      ? Nocturne.muted(.4)
                      : selected
                      ? Nocturne.accent100
                      : Nocturne.text,
                ),
              ),
            ),
            if (secondaryText != null) ...[
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  secondaryText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontFeatures: Nocturne.tabular,
                    color: Nocturne.muted(.55),
                  ),
                ),
              ),
            ],
            // The two delete affordances never coexist: single delete is immediate, the batch
            // one is confirmed.
            if (!selecting)
              IconButton(
                tooltip: 'Delete record',
                style: IconButton.styleFrom(
                  foregroundColor: Nocturne.muted(.45),
                ),
                icon: const Icon(Icons.delete_outline, size: 18),
                onPressed: () => unawaited(controller.deleteRecord(record.id)),
              ),
          ],
        ),
      ),
    );
  }

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
          title: collection == null ? 'New collection' : 'Rename collection',
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
                label: 'Name',
                required: true,
                errors: issues.of('name'),
                // The shown issue is about the old text, so it goes as soon as the name changes.
                onChanged: (_) {
                  if (issues.of('name').isEmpty) return;
                  setState(() => issues = issues.without('name'));
                },
              ),
              if (collection == null)
                FiTextInput(controller: description, label: 'Description'),
            ],
          ),
          errors: issues.form,
          primaryLabel: 'Save',
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

  /// The schema as a side sheet (mock 1c): reorderable field rows, and a new field added inline
  /// below them rather than in a second, stacked dialog.
  Future<void> _schemaEditor(
    BuildContext context,
    CollectionSchemaDto schema,
  ) async {
    var adding = false;
    await showSideSheet(
      context,
      kicker: schema.name,
      title: 'Collection schema',
      footerNote: 'Drag to reorder fields',
      body: (sheet) => StatefulBuilder(
        builder: (sheet, setState) => ListenableBuilder(
          listenable: controller,
          builder: (sheet, _) {
            final fields = [
              ...?controller.schema?.fields.where((field) => !field.deleted),
            ]..sort(_fieldOrder);
            return ListView(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              children: [
                ReorderableListView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  buildDefaultDragHandles: false,
                  itemCount: fields.length,
                  onReorder: (oldIndex, newIndex) {
                    if (newIndex > oldIndex) newIndex--;
                    final moved = fields.removeAt(oldIndex);
                    fields.insert(newIndex, moved);
                    unawaited(
                      controller.reorderFields(
                        fields.map((field) => field.id).toList(),
                      ),
                    );
                  },
                  itemBuilder: (context, index) => Padding(
                    key: ValueKey(fields[index].id),
                    padding: const EdgeInsets.only(bottom: 6),
                    child: _schemaRow(sheet, fields[index], index),
                  ),
                ),
                const SizedBox(height: 4),
                if (adding)
                  _FieldEditorForm(
                    controller: controller,
                    inline: true,
                    onClosed: () => setState(() => adding = false),
                  )
                else
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () => setState(() => adding = true),
                      icon: const Icon(Icons.add),
                      label: const Text('Add field'),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _schemaRow(BuildContext sheet, FieldDefinitionDto field, int index) =>
      Material(
        color: Nocturne.bg,
        borderRadius: BorderRadius.circular(Nocturne.radius),
        child: InkWell(
          borderRadius: BorderRadius.circular(Nocturne.radius),
          onTap: () => _fieldEditor(sheet, field),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
            child: Row(
              children: [
                ReorderableDragStartListener(
                  index: index,
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Icon(
                      Icons.drag_indicator,
                      size: 18,
                      color: Nocturne.muted(.45),
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    field.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 14),
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(child: Tag(_fieldSubtitle(field))),
                IconButton(
                  tooltip: 'Remove field',
                  style: IconButton.styleFrom(
                    foregroundColor: Nocturne.muted(.5),
                  ),
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => unawaited(controller.removeField(field.id)),
                ),
              ],
            ),
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
      icon: Icons.functions,
      title: item.name,
      subtitle: editable
          ? null
          : item.unsupportedBodyJson != null
          ? 'Made by a newer version (expression v${item.expressionVersion}); not editable here'
          : 'Uses operations this editor does not offer; not editable here',
      tag: editable
          ? '${describeValueType(item.declaredType)}'
                '${item.nullable ? ' · may be empty' : ''}'
          : null,
      onTap: editable ? open : null,
      actions: [
        if (editable)
          IconButton(
            tooltip: 'Edit computed field',
            icon: const Icon(Icons.edit_outlined),
            onPressed: open,
          ),
        IconButton(
          tooltip: 'Remove computed field',
          icon: const Icon(Icons.delete_outline),
          onPressed: () => unawaited(controller.removeComputedField(item.id)),
        ),
      ],
    );
  }

  /// Computed fields and saved queries as a side sheet, the same pattern as the schema (mock 2a).
  Future<void> _queryEditor(
    BuildContext context,
    CollectionSchemaDto schema,
  ) async {
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
      title: 'Computed fields & queries',
      body: (sheet) => ListenableBuilder(
        listenable: controller,
        builder: (sheet, _) => ListView(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          children: [
            heading(
              'Computed fields',
              HelpId.computedFields,
              'Calculated per record from other fields.',
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
                icon: const Icon(Icons.add),
                label: const Text('Add computed field'),
              ),
            ),
            const SizedBox(height: 22),
            heading(
              'Saved queries',
              HelpId.querySavedQueries,
              'Aggregates across records. Widgets can reuse them.',
            ),
            for (final item in controller.queryDefinitions)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: _SheetRow(
                  key: ValueKey('saved-query-${item.id}'),
                  icon: _queryIcon(item),
                  title: item.name,
                  subtitle:
                      '${describeQuery(item, schema)} · '
                      '${_usage(widgetsUsingQuery(controller, item.id))}',
                  actions: [
                    IconButton(
                      key: ValueKey('edit-query-${item.id}'),
                      tooltip: 'Edit query',
                      icon: const Icon(Icons.edit_outlined),
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
                      tooltip: 'Remove query',
                      icon: const Icon(Icons.delete_outline),
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
                    name: 'Record count',
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
                icon: const Icon(Icons.add),
                label: const Text('Add record-count query'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _fieldEditor(
    BuildContext context, [
    FieldDefinitionDto? existing,
  ]) => showDialog<void>(
    context: context,
    builder: (dialog) => Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(22),
          child: _FieldEditorForm(
            controller: controller,
            existing: existing,
            onClosed: () => Navigator.pop(dialog),
          ),
        ),
      ),
    ),
  );

  /// Replaces the collection header while records are being selected (mock 2e).
  Widget _selectionBar(
    BuildContext context,
    CollectionSchemaDto schema, {
    required bool wide,
  }) {
    final count = controller.selectedRecordIds.length;
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
            tooltip: 'Cancel',
            style: onAccent,
            onPressed: controller.clearSelection,
            icon: const Icon(Icons.close),
          ),
          const SizedBox(width: 8),
          Text(
            '$count selected',
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w500,
              color: Nocturne.accent100,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'in ${schema.name}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, color: Nocturne.accent200),
            ),
          ),
          if (wide) ...[
            TextButton.icon(
              style: TextButton.styleFrom(foregroundColor: Nocturne.accent100),
              onPressed: unselected.isEmpty ? null : selectAll,
              icon: const Icon(Icons.done_all),
              label: const Text('Select all'),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              key: const Key('batch-edit'),
              style: outlined,
              onPressed: count == 0 ? null : edit,
              icon: const Icon(Icons.edit_outlined),
              label: const Text('Edit'),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              key: const Key('batch-delete'),
              style: outlined,
              onPressed: count == 0 ? null : delete,
              icon: const Icon(Icons.delete_outline),
              label: const Text('Delete'),
            ),
          ] else ...[
            IconButton(
              tooltip: 'Select all',
              style: onAccent,
              onPressed: unselected.isEmpty ? null : selectAll,
              icon: const Icon(Icons.done_all),
            ),
            IconButton(
              key: const Key('batch-edit'),
              tooltip: 'Edit field',
              style: onAccent,
              onPressed: count == 0 ? null : edit,
              icon: const Icon(Icons.edit_outlined),
            ),
            IconButton(
              key: const Key('batch-delete'),
              tooltip: 'Delete',
              style: onAccent,
              onPressed: count == 0 ? null : delete,
              icon: const Icon(Icons.delete_outline),
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
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text('Delete $count records?'),
        content: const Text('Every selected record is deleted in one step.'),
        actions: [
          TextButton(
            key: const Key('dismiss-batch-delete'),
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('confirm-batch-delete'),
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final affected = await controller.deleteSelected();
      messenger.showSnackBar(
        SnackBar(content: Text('$affected records deleted')),
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
    var field = fields.first;
    FieldValueDto? value;
    var issues = FormIssues.none;
    var attempted = false;

    /// A required field left empty would fail every member; say so before confirming.
    String? blocker() =>
        FieldRendererRegistry.marksRequired(field) &&
            (value?.kind ?? FieldValueKindDto.null_) == FieldValueKindDto.null_
        ? 'Required'
        : null;

    Future<void> apply(BuildContext route, StateSetter setState) async {
      setState(() => attempted = true);
      if (blocker() != null) return;
      final confirmed = await showDialog<bool>(
        context: route,
        builder: (dialog) => AlertDialog(
          title: Text('Set ${field.name} on $count records?'),
          content: const Text('Every selected record is updated in one step.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              key: const Key('confirm-batch-edit'),
              onPressed: () => Navigator.pop(dialog, true),
              child: const Text('Set'),
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
          SnackBar(content: Text('$affected records updated')),
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
          title: 'Edit field on $count records',
          showRequiredLegend: FieldRendererRegistry.marksRequired(field),
          body: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 14,
            children: [
              FiSelect<String>(
                key: const Key('batch-field'),
                value: field.id,
                label: 'Field',
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
                errors: [...issues.of(field.id), if (attempted) ?blocker()],
                quickFill: true,
              ),
            ],
          ),
          errors: issues.form,
          primaryKey: const Key('batch-edit-continue'),
          primaryLabel: 'Continue',
          onPrimary: () => apply(route, setState),
        ),
      ),
    );
  }

  /// A dialog on a wide screen; on a phone, a bottom sheet with large inputs (mock 2h).
  Future<void> _recordEditor(
    BuildContext context,
    CollectionSchemaDto schema, [
    RecordDto? existing,
  ]) => showFormSurface<void>(
    context,
    builder: (route) => _RecordEditorForm(
      controller: controller,
      schema: schema,
      existing: existing,
    ),
  );
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
        child: Text(
          widget.name,
          key: const Key('collection-title'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: widget.style,
        ),
      );
    }
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): _cancel},
      child: FiTextInput(
        key: const Key('collection-title-input'),
        controller: _text,
        focusNode: _focus,
        style: widget.style,
        textInputAction: TextInputAction.done,
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
  });

  final CollectionsController controller;
  final CollectionSchemaDto schema;
  final RecordDto? existing;

  @override
  State<_RecordEditorForm> createState() => _RecordEditorFormState();
}

class _RecordEditorFormState extends State<_RecordEditorForm> {
  late final values = <String, FieldValueDto>{
    for (final item in widget.existing?.values ?? const <RecordValueDto>[])
      item.fieldId: item.value,
  };
  late final fields =
      widget.schema.fields.where((field) => !field.deleted).toList()
        ..sort(_fieldOrder);
  late final _fieldIds = {for (final field in fields) field.id};

  /// A record opened because the list marks it invalid shows its problems straight away.
  late var attempted = widget.existing?.valid == false;
  late var issues = attempted
      ? _diagnosticIssues(widget.existing!).restrictTo(_fieldIds)
      : FormIssues.none;
  Timer? _debounce;

  /// Bumped per validation or save, so a slower, older answer never replaces a newer one.
  var _request = 0;

  List<RecordValueDto> get _submitted => [
    for (final MapEntry(:key, :value) in values.entries)
      RecordValueDto(fieldId: key, value: value),
  ];

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _changed(String fieldId, FieldValueDto value) {
    values[fieldId] = value;
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
      return;
    }
    try {
      final existing = widget.existing;
      if (existing == null) {
        await widget.controller.createRecord(_submitted);
      } else {
        await widget.controller.updateRecord(existing.id, _submitted);
      }
      if (mounted) Navigator.pop(context);
    } catch (failure) {
      // Save is authoritative: its issues replace whatever the dry run said.
      if (mounted && request == _request) {
        setState(() => issues = FormIssues.from(failure).restrictTo(_fieldIds));
      }
    }
  }

  @override
  Widget build(BuildContext context) => FormSurface(
    title: widget.existing == null ? 'New record' : 'Edit record',
    contextLabel: 'in ${widget.schema.name}',
    showRequiredLegend: fields.any(FieldRendererRegistry.marksRequired),
    body: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 14,
      children: [
        for (final field in fields)
          const FieldRendererRegistry().editor(
            field,
            values[field.id],
            (value) => _changed(field.id, value),
            errors: issues.of(field.id),
            quickFill: true,
          ),
      ],
    ),
    errors: issues.form,
    primaryLabel: FormSurfaceScope.modeOf(context) == FormSurfaceMode.sheet
        ? 'Save record'
        : 'Save',
    onPrimary: _save,
  );
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

class _TableHeader extends StatelessWidget {
  const _TableHeader({required this.fields, required this.selecting});

  final List<FieldDefinitionDto> fields;
  final bool selecting;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(6, 6, 4, 6),
        child: Row(
          children: [
            if (selecting) const SizedBox(width: 40),
            for (final field in fields)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(text: '${field.name.toUpperCase()} '),
                        TextSpan(
                          text: fieldKindLabel(field.fieldType.kind),
                          style: TextStyle(
                            letterSpacing: 0,
                            color: Nocturne.muted(.36),
                          ),
                        ),
                      ],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      letterSpacing: .88,
                      color: Nocturne.muted(.6),
                    ),
                  ),
                ),
              ),
            if (!selecting) const SizedBox(width: 48),
          ],
        ),
      ),
      const FadedRule(),
    ],
  );
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

/// Creates or edits one field. Inline in the schema sheet for a new field (mock 1c), inside a
/// dialog when editing an existing one.
class _FieldEditorForm extends StatefulWidget {
  const _FieldEditorForm({
    required this.controller,
    required this.onClosed,
    this.existing,
    this.inline = false,
  });

  final CollectionsController controller;
  final FieldDefinitionDto? existing;
  final VoidCallback onClosed;
  final bool inline;

  @override
  State<_FieldEditorForm> createState() => _FieldEditorFormState();
}

class _FieldEditorFormState extends State<_FieldEditorForm> {
  CollectionsController get controller => widget.controller;
  FieldDefinitionDto? get existing => widget.existing;

  late final name = TextEditingController(text: existing?.name);
  late var kind = existing?.fieldType.kind ?? FieldTypeKindDto.text;
  late var required = existing?.required_ ?? false;
  late var multiline = existing?.display.multiline ?? false;
  late var slider = existing?.display.slider ?? false;
  late var scale = existing?.fieldType.scale ?? 2;
  // Range bounds are compared against the stored integer, which is epoch days for a Date, epoch
  // milliseconds for a DateTime, and the scaled representation for a FixedDecimal. Holding them
  // as integers lets the same typed control that edits a record edit the bound.
  late int? minimum = existing?.validation.minInteger;
  late int? maximum = existing?.validation.maxInteger;
  late final minLength = TextEditingController(
    text: existing?.validation.minLength?.toString() ?? '',
  );
  late final maxLength = TextEditingController(
    text: existing?.validation.maxLength?.toString() ?? '',
  );
  late FieldValueDto? defaultValue =
      existing?.defaultValue?.kind == FieldValueKindDto.null_
      ? null
      : existing?.defaultValue;
  // Choice options are held here until Save, so a new field can get options and a default in
  // the same step and Cancel leaves the stored options untouched.
  late final options = [
    for (final option in [
      ...?existing?.enumOptions.where((option) => !option.deleted),
    ]..sort(_optionOrder))
      _DraftOption(option.id, option.label),
  ];
  var addedOptions = 0;
  late final order = existing?.order ?? controller.schema?.fields.length ?? 0;
  // Survives a failed save, so retrying updates what the first attempt already created.
  final session = FieldSaveSession();
  var issues = FormIssues.none;

  /// Rust's keys for field-definition problems, by the input that shows them. Anything else
  /// lands in the slot above the buttons.
  static const _issueInputs = {
    'name': 'name',
    'field_name': 'name',
    'default': 'default',
    'scale': 'scale',
    'numeric_range': 'maximum',
    'length_range': 'max-length',
  };

  /// A slider needs a whole-number track, so only an Integer with both bounds can offer one.
  bool get _sliderAvailable =>
      kind == FieldTypeKindDto.integer && minimum != null && maximum != null;

  /// Turns the slider off once it can no longer apply, so a later bound does not revive it.
  void _dropUnavailableSlider() {
    if (!_sliderAvailable) slider = false;
  }

  /// Drops the shown issues for [input] once it changes, since they describe the old value.
  void _edited(String input) {
    if (issues.of(input).isNotEmpty) issues = issues.without(input);
  }

  List<EnumOptionDto> draftOptions() => [
    for (final (index, option) in options.indexed)
      EnumOptionDto(
        id: option.id,
        label: option.label.text,
        order: index,
        deleted: false,
      ),
  ];

  @override
  void dispose() {
    name.dispose();
    minLength.dispose();
    maxLength.dispose();
    super.dispose();
  }

  /// How many active records would be marked invalid by this field as it currently stands.
  ///
  /// The projected record list is already loaded in full for the collection, so this is a read of
  /// what is on screen rather than another trip through the bridge. It is a disclosure, not a
  /// guard: Rust accepts the command either way.
  int _missingRequiredCount() {
    if (!required || defaultValue != null) return 0;
    // A brand new field has an id no record can hold a value for yet.
    final existing = this.existing;
    if (existing == null) return controller.records.length;
    return controller.records
        .where((record) => _recordValue(record, existing.id) == null)
        .length;
  }

  Future<bool> _confirmInvalidating(int missing) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        key: const Key('required-confirmation'),
        title: const Text('Make this field required?'),
        content: Text(
          '$missing ${missing == 1 ? 'record has' : 'records have'} no value for this field. '
          '${missing == 1 ? 'It' : 'They'} will be marked invalid until you fill the field in. '
          'Nothing is deleted.',
        ),
        actions: [
          TextButton(
            key: const Key('required-cancel'),
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('required-confirm'),
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('Make required'),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  Future<void> _save() async {
    final missing = _missingRequiredCount();
    // Rust no longer refuses this, so the disclosure has to happen here, before the
    // command is sent and with the count the user is about to invalidate.
    if (missing > 0 && !await _confirmInvalidating(missing)) return;
    try {
      final dto = FieldDefinitionDto(
        id: existing?.id ?? '',
        name: name.text,
        fieldType: FieldTypeDto(
          kind: kind,
          scale: kind == FieldTypeKindDto.fixedDecimal ? scale : null,
        ),
        required_: required,
        defaultValue: defaultValue,
        validation: ValidationMetadataDto(
          minInteger: minimum,
          maxInteger: maximum,
          minLength: int.tryParse(minLength.text),
          maxLength: int.tryParse(maxLength.text),
        ),
        display: DisplayMetadataDto(
          multiline: multiline,
          slider: slider && _sliderAvailable,
        ),
        order: order,
        deleted: false,
        // Options travel separately; the controller keeps the stored ones here.
        enumOptions: const [],
      );
      await controller.saveFieldWithOptions(
        dto,
        draftOptions(),
        session: session,
      );
      if (mounted) widget.onClosed();
    } catch (failure) {
      if (mounted) {
        setState(() => issues = FormIssues.from(failure).keyed(_issueInputs));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    const gap = SizedBox(height: 14);
    final nameField = FiTextInput(
      key: const Key('field-name'),
      controller: name,
      autofocus: widget.inline,
      label: 'Name',
      required: true,
      hint: 'e.g. note',
      errors: issues.of('name'),
      onChanged: (_) => setState(() => _edited('name')),
    );
    final typeField = FiSelect<FieldTypeKindDto>(
      value: kind,
      label: 'Type',
      items: FieldTypeKindDto.values
          .map(
            (value) => DropdownMenuItem(
              value: value,
              child: Text(fieldKindLabel(value)),
            ),
          )
          .toList(),
      onChanged: existing == null
          ? (value) => setState(() {
              kind = value!;
              // Default and bounds are typed by the kind, so they cannot survive it.
              defaultValue = null;
              if (kind != FieldTypeKindDto.enum_) options.clear();
              minimum = null;
              maximum = null;
              slider = false;
            })
          : null,
    );
    final missing = _missingRequiredCount();
    final form = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.inline)
          const Padding(
            padding: EdgeInsets.only(bottom: 14),
            child: Row(
              children: [
                Icon(
                  Icons.add_circle_outline,
                  size: 18,
                  color: Nocturne.accent,
                ),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'New field',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: Nocturne.accent200,
                    ),
                  ),
                ),
                RequiredLegend(key: Key('required-legend')),
              ],
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.only(bottom: 18),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Expanded(
                  child: Text(
                    existing == null ? 'Add field' : 'Edit field',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                const RequiredLegend(key: Key('required-legend')),
              ],
            ),
          ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: nameField),
            const SizedBox(width: 10),
            SizedBox(width: 150, child: typeField),
          ],
        ),
        if (kind == FieldTypeKindDto.fixedDecimal) ...[
          gap,
          FiTextInput(
            initialValue: '$scale',
            keyboardType: TextInputType.number,
            label: 'Decimal scale',
            suffixIcon: const HelpButton(HelpId.fieldDecimalScale),
            errors: issues.of('scale'),
            // The scale decides what the stored integer means, so a change to it
            // cannot leave a default or a bound behind reading as something else.
            onChanged: (value) => setState(() {
              _edited('scale');
              scale = int.tryParse(value) ?? 255;
              defaultValue = null;
              minimum = null;
              maximum = null;
            }),
          ),
        ],
        const SizedBox(height: 6),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Required'),
          subtitle: const Text("Records can't be saved without a value"),
          secondary: const HelpButton(HelpId.fieldRequired),
          value: required,
          onChanged: (value) => setState(() => required = value),
        ),
        if (kind == FieldTypeKindDto.text) ...[
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Multiline'),
            subtitle: const Text('Show a text area instead of a single line'),
            secondary: const HelpButton(HelpId.fieldMultiline),
            value: multiline,
            onChanged: (value) => setState(() => multiline = value),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: FiTextInput(
                  controller: minLength,
                  keyboardType: TextInputType.number,
                  label: 'Minimum length',
                  suffixIcon: const HelpButton(HelpId.fieldMinMaxLength),
                  onChanged: (_) => setState(() => _edited('max-length')),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FiTextInput(
                  controller: maxLength,
                  keyboardType: TextInputType.number,
                  label: 'Maximum length',
                  suffixIcon: const HelpButton(HelpId.fieldMinMaxLength),
                  errors: issues.of('max-length'),
                  onChanged: (_) => setState(() => _edited('max-length')),
                ),
              ),
            ],
          ),
        ],
        if (kind != FieldTypeKindDto.text &&
            kind != FieldTypeKindDto.boolean &&
            kind != FieldTypeKindDto.enum_) ...[
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _metadataInput(
                  slot: 'field-minimum',
                  label: 'Minimum',
                  help: HelpId.fieldMinMax,
                  kind: kind,
                  scale: scale,
                  enumOptions: existing?.enumOptions ?? const [],
                  value: _boundValue(minimum, kind, scale),
                  onChanged: (value) => setState(() {
                    _edited('maximum');
                    minimum = value?.integerValue;
                    _dropUnavailableSlider();
                  }),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _metadataInput(
                  slot: 'field-maximum',
                  label: 'Maximum',
                  help: HelpId.fieldMinMax,
                  kind: kind,
                  scale: scale,
                  enumOptions: existing?.enumOptions ?? const [],
                  value: _boundValue(maximum, kind, scale),
                  errors: issues.of('maximum'),
                  onChanged: (value) => setState(() {
                    _edited('maximum');
                    maximum = value?.integerValue;
                    _dropUnavailableSlider();
                  }),
                ),
              ),
            ],
          ),
        ],
        if (kind == FieldTypeKindDto.integer)
          SwitchListTile(
            key: const Key('field-slider'),
            contentPadding: EdgeInsets.zero,
            title: const Text('Show as slider'),
            subtitle: Text(
              _sliderAvailable
                  ? 'Pick the value by dragging between the bounds'
                  : 'Set a minimum and a maximum first',
            ),
            secondary: const HelpButton(HelpId.fieldSlider),
            value: slider && _sliderAvailable,
            onChanged: _sliderAvailable
                ? (value) => setState(() => slider = value)
                : null,
          ),
        if (kind == FieldTypeKindDto.enum_) ..._optionsEditor(),
        gap,
        _metadataInput(
          slot: 'field-default',
          label: 'Default (optional)',
          help: HelpId.fieldDefault,
          kind: kind,
          scale: scale,
          enumOptions: draftOptions(),
          value: defaultValue,
          errors: issues.of('default'),
          onChanged: (value) => setState(() {
            _edited('default');
            defaultValue = value;
          }),
          revision: [
            for (final option in options) '${option.id}=${option.label.text}',
          ].join('|'),
        ),
        if (missing > 0)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Row(
              key: const Key('required-warning'),
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.warning_amber,
                  size: 16,
                  color: Nocturne.accent300,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '$missing ${missing == 1 ? 'record has' : 'records have'} no value for '
                    'this field and will be marked invalid until you fill them in. '
                    'Add a default to avoid this.',
                    style: const TextStyle(
                      fontSize: 12,
                      color: Nocturne.accent300,
                    ),
                  ),
                ),
              ],
            ),
          ),
        if (issues.form.isNotEmpty)
          Padding(
            key: const Key('field-editor-errors'),
            padding: const EdgeInsets.only(top: 14),
            child: FormErrorLines(issues.form),
          ),
        const SizedBox(height: 18),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(onPressed: widget.onClosed, child: const Text('Cancel')),
            const SizedBox(width: 8),
            FilledButton(onPressed: _save, child: const Text('Save')),
          ],
        ),
      ],
    );
    if (!widget.inline) return form;
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Nocturne.radius),
        border: Border.all(color: Nocturne.accent700),
      ),
      child: form,
    );
  }

  /// The Options section of the field editor for a Choice field: one row per option in the order
  /// it will be saved, each with a drag handle, its label, and a remove button.
  List<Widget> _optionsEditor() => [
    const Padding(
      padding: EdgeInsets.only(top: 14, bottom: 4),
      child: SectionLabel('Options'),
    ),
    ReorderableListView(
      key: const Key('field-options'),
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      buildDefaultDragHandles: false,
      onReorder: (from, to) => setState(() {
        options.insert(to > from ? to - 1 : to, options.removeAt(from));
      }),
      children: [
        for (final (index, option) in options.indexed)
          Padding(
            key: ValueKey(option.id),
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              children: [
                ReorderableDragStartListener(
                  index: index,
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Icon(Icons.drag_handle, color: Nocturne.muted(.45)),
                  ),
                ),
                Expanded(
                  child: FiTextInput(
                    key: ValueKey('option-label-${option.id}'),
                    controller: option.label,
                    // A freshly added row is where the user is about to type.
                    autofocus:
                        isTempOptionId(option.id) && option.label.text.isEmpty,
                    hint: 'Option label',
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                IconButton(
                  key: ValueKey('remove-option-${option.id}'),
                  tooltip: 'Remove option',
                  icon: const Icon(Icons.close),
                  onPressed: () => setState(() {
                    options.remove(option);
                    if (defaultValue?.textValue == option.id) {
                      defaultValue = null;
                    }
                  }),
                ),
              ],
            ),
          ),
      ],
    ),
    Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        key: const Key('add-option'),
        onPressed: () => setState(
          () => options.add(_DraftOption(tempOptionId(++addedOptions), '')),
        ),
        icon: const Icon(Icons.add),
        label: const Text('Add option'),
      ),
    ),
  ];
}

/// A schema-metadata slot edited with the very control that edits a record of that type.
///
/// A default and a range bound are values of the field's own type, so typing an epoch day or a
/// scaled integer by hand was never the right ask. The draft field carries only what the
/// renderer needs; [slot] keys the control so switching type or scale rebuilds it empty rather
/// than leaving digits that now mean something else. [revision] does the same when the Choice
/// options held in the editor change, so the dropdown never keeps an option that is gone.
Widget _metadataInput({
  required String slot,
  required String label,
  required HelpId help,
  required FieldTypeKindDto kind,
  required int scale,
  required List<EnumOptionDto> enumOptions,
  required FieldValueDto? value,
  required ValueChanged<FieldValueDto?> onChanged,
  List<String> errors = const [],
  String revision = '',
}) => Row(
  crossAxisAlignment: CrossAxisAlignment.start,
  children: [
    Expanded(
      child: KeyedSubtree(
        key: ValueKey('$slot-$kind-$scale-$revision'),
        child: const FieldRendererRegistry().editor(
          FieldDefinitionDto(
            id: slot,
            name: label,
            fieldType: FieldTypeDto(
              kind: kind,
              scale: kind == FieldTypeKindDto.fixedDecimal ? scale : null,
            ),
            // Never required: the slot itself is optional whatever the field demands of records.
            required_: false,
            validation: const ValidationMetadataDto(),
            display: const DisplayMetadataDto(multiline: false, slider: false),
            order: 0,
            deleted: false,
            enumOptions: enumOptions,
          ),
          value,
          (typed) =>
              onChanged(typed.kind == FieldValueKindDto.null_ ? null : typed),
          label: label,
          allowClear: true,
          errors: errors,
        ),
      ),
    ),
    Padding(padding: const EdgeInsets.only(top: 4), child: HelpButton(help)),
  ],
);

String _usage(int count) => switch (count) {
  0 => 'used by no widgets',
  1 => 'used by 1 widget',
  _ => 'used by $count widgets',
};

IconData _queryIcon(QueryDefinitionDto query) => switch (query.query?.shape) {
  QueryShapeDto(kind: QueryShapeKindDto.scalar, :final aggregation?) =>
    aggregation.kind == AggregationKindDto.count ? Icons.tag : Icons.functions,
  QueryShapeDto(kind: QueryShapeKindDto.series) => Icons.show_chart,
  QueryShapeDto(kind: QueryShapeKindDto.categorySeries) => Icons.bar_chart,
  _ => Icons.query_stats,
};

/// A stored range bound as a typed value of the field's own kind, so the bound is edited with a
/// date picker or a decimal box rather than as the raw integer it is compared as.
FieldValueDto? _boundValue(int? bound, FieldTypeKindDto kind, int scale) {
  if (bound == null) return null;
  return FieldValueDto(
    kind: switch (kind) {
      FieldTypeKindDto.integer => FieldValueKindDto.integer,
      FieldTypeKindDto.fixedDecimal => FieldValueKindDto.fixedDecimal,
      FieldTypeKindDto.date => FieldValueKindDto.date,
      FieldTypeKindDto.dateTime => FieldValueKindDto.dateTime,
      FieldTypeKindDto.duration => FieldValueKindDto.duration,
      // Text, boolean, and enum carry no numeric range; the control is not rendered for them.
      _ => FieldValueKindDto.null_,
    },
    integerValue: bound,
  );
}

FieldValueDto? _recordValue(RecordDto record, String fieldId) {
  for (final item in record.values) {
    if (item.fieldId == fieldId) return item.value;
  }
  return null;
}

/// A field's kind in words, and for a Choice field its option labels in order.
String _fieldSubtitle(FieldDefinitionDto field) {
  final label = fieldKindLabel(field.fieldType.kind);
  if (field.fieldType.kind != FieldTypeKindDto.enum_) return label;
  final options = [...field.enumOptions.where((option) => !option.deleted)]
    ..sort(_optionOrder);
  if (options.isEmpty) return label;
  return '$label · ${options.map((option) => option.label).join(', ')}';
}

/// One Choice option as the field editor holds it until Save. [id] is the stored ID, or one made
/// by [tempOptionId] for an option this editor added.
final class _DraftOption {
  _DraftOption(this.id, String label)
    : label = TextEditingController(text: label);
  final String id;
  final TextEditingController label;
}

int _optionOrder(EnumOptionDto left, EnumOptionDto right) {
  final order = left.order.compareTo(right.order);
  return order == 0 ? left.id.compareTo(right.id) : order;
}

int _fieldOrder(FieldDefinitionDto left, FieldDefinitionDto right) {
  final order = left.order.compareTo(right.order);
  return order == 0 ? left.id.compareTo(right.id) : order;
}

/// States what deleting a collection takes with it, leaving out zero counts:
/// "142 records, 3 widgets and 2 saved queries are deleted with it."
String collectionContentsSentence(CollectionContents contents) {
  String count(int n, String one, String many) => '$n ${n == 1 ? one : many}';
  final parts = [
    if (contents.records > 0) count(contents.records, 'record', 'records'),
    if (contents.widgets > 0) count(contents.widgets, 'widget', 'widgets'),
    if (contents.savedQueries > 0)
      count(contents.savedQueries, 'saved query', 'saved queries'),
  ];
  if (parts.isEmpty) return 'This collection is empty.';
  final list = parts.length == 1
      ? parts.single
      : '${parts.sublist(0, parts.length - 1).join(', ')} and ${parts.last}';
  final total = contents.records + contents.widgets + contents.savedQueries;
  return '$list ${total == 1 ? 'is' : 'are'} deleted with it.';
}
