import 'dart:async';

import 'package:fi/controllers.dart';
import 'package:fi/field_registry.dart';
import 'package:fi/help_button.dart';
import 'package:fi/help_copy.dart';
import 'package:fi/src/rust/api/models.dart';
import 'package:fi/widgets/computed_field_editor.dart';
import 'package:fi/widgets/expression_builder.dart';
import 'package:fi/widgets/query_builder.dart';
import 'package:fi/widgets/query_editor_dialog.dart';
import 'package:fi/widgets/widget_dashboard.dart';
import 'package:flutter/material.dart';

class CollectionsPage extends StatelessWidget {
  const CollectionsPage({super.key, required this.controller});
  final CollectionsController controller;

  @override
  Widget build(BuildContext context) => controller.selectedCollectionId == null
      ? _collectionList(context)
      : _collection(context);

  Widget _collectionList(BuildContext context) => Column(
    children: [
      _header(
        context,
        'Collections',
        'New collection',
        () => _editCollection(context),
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
            ? const Center(
                child: Text('Create a collection to start shaping your data.'),
              )
            : ListView.builder(
                itemCount: controller.collections.length,
                itemBuilder: (context, index) {
                  final item = controller.collections[index];
                  return ListTile(
                    key: ValueKey(item.id),
                    leading: const Icon(Icons.dataset_outlined),
                    title: Text(item.name),
                    subtitle: item.description.isEmpty
                        ? null
                        : Text(item.description),
                    onTap: () =>
                        unawaited(controller.selectCollection(item.id)),
                    trailing: PopupMenuButton<String>(
                      onSelected: (action) {
                        if (action == 'rename') {
                          _editCollection(context, item);
                        } else {
                          unawaited(controller.deleteCollection(item.id));
                        }
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'rename', child: Text('Rename')),
                        PopupMenuItem(value: 'delete', child: Text('Delete')),
                      ],
                    ),
                  );
                },
              ),
      ),
    ],
  );

  Widget _collection(BuildContext context) {
    final schema = controller.schema;
    if (schema == null) return const Center(child: CircularProgressIndicator());
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: controller.selecting
              ? _selectionHeader(context, schema)
              : LayoutBuilder(
                  builder: (context, constraints) {
                    // Narrow widths cannot fit four labelled buttons next to
                    // the title, so the same actions collapse to icons and
                    // stay reachable.
                    final wide = constraints.maxWidth >= 760;
                    return Row(
                      children: [
                        IconButton(
                          tooltip: 'Back to collections',
                          onPressed: () =>
                              unawaited(controller.selectCollection(null)),
                          icon: const Icon(Icons.arrow_back),
                        ),
                        Expanded(
                          child: Text(
                            schema.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.headlineSmall,
                          ),
                        ),
                        if (wide) ...[
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
                            icon: const Icon(Icons.checklist),
                            label: const Text('Select'),
                          ),
                          const SizedBox(width: 8),
                          FilledButton.icon(
                            onPressed: () => _recordEditor(context, schema),
                            icon: const Icon(Icons.add),
                            label: const Text('New record'),
                          ),
                        ] else ...[
                          IconButton(
                            tooltip: 'Schema',
                            onPressed: () => _schemaEditor(context, schema),
                            icon: const Icon(Icons.tune),
                          ),
                          IconButton(
                            tooltip: 'Queries',
                            onPressed: () => _queryEditor(context, schema),
                            icon: const Icon(Icons.query_stats),
                          ),
                          IconButton(
                            key: const Key('select-records'),
                            tooltip: 'Select',
                            onPressed: controller.records.isEmpty
                                ? null
                                : controller.startSelection,
                            icon: const Icon(Icons.checklist),
                          ),
                          IconButton(
                            tooltip: 'New record',
                            onPressed: () => _recordEditor(context, schema),
                            icon: const Icon(Icons.add),
                          ),
                        ],
                      ],
                    );
                  },
                ),
        ),
        if (controller.errorMessage case final error?)
          MaterialBanner(
            content: Text(error),
            actions: const [SizedBox.shrink()],
          ),
        Expanded(
          child: CustomScrollView(
            slivers: [
              // The dashboard sits above the record list and never replaces record CRUD.
              SliverToBoxAdapter(
                child: CollectionDashboard(controller: controller),
              ),
              if (controller.records.isEmpty)
                const SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(child: Text('No records yet.')),
                )
              else
                SliverList.builder(
                  itemCount: controller.records.length,
                  itemBuilder: (context, index) {
                    final record = controller.records[index];
                    final fields =
                        schema.fields.where((field) => !field.deleted).toList()
                          ..sort(_fieldOrder);
                    final primary = fields.isEmpty ? null : fields.first;
                    final secondary = fields.length < 2 ? null : fields[1];
                    final selecting = controller.selecting;
                    final selected = controller.selectedRecordIds.contains(
                      record.id,
                    );
                    return ListTile(
                      key: ValueKey(record.id),
                      selected: selecting && selected,
                      leading: selecting
                          ? Checkbox(
                              value: selected,
                              onChanged: (_) =>
                                  controller.toggleSelected(record.id),
                            )
                          : Icon(
                              record.valid
                                  ? Icons.description_outlined
                                  : Icons.warning_amber,
                            ),
                      title: primary == null
                          ? Text(record.id)
                          : FieldRendererRegistry().display(
                              primary,
                              _recordValue(record, primary.id),
                            ),
                      subtitle: secondary == null
                          ? (record.valid
                                ? null
                                : Text(
                                    record.diagnostics
                                        .map((item) => item.message)
                                        .join('\n'),
                                  ))
                          : FieldRendererRegistry().display(
                              secondary,
                              _recordValue(record, secondary.id),
                            ),
                      // Long press is the way into selection mode; once in it,
                      // a tap toggles instead of opening the editor.
                      onLongPress: () => controller.toggleSelected(record.id),
                      onTap: selecting
                          ? () => controller.toggleSelected(record.id)
                          : () => _recordEditor(context, schema, record),
                      // The two delete affordances never coexist: single delete
                      // is immediate, the batch one is confirmed.
                      trailing: selecting
                          ? null
                          : IconButton(
                              tooltip: 'Delete record',
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () =>
                                  unawaited(controller.deleteRecord(record.id)),
                            ),
                    );
                  },
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _header(
    BuildContext context,
    String title,
    String action,
    VoidCallback onPressed,
  ) => Padding(
    padding: const EdgeInsets.all(16),
    child: Row(
      children: [
        Expanded(
          child: Text(title, style: Theme.of(context).textTheme.headlineSmall),
        ),
        FilledButton.icon(
          onPressed: onPressed,
          icon: const Icon(Icons.add),
          label: Text(action),
        ),
      ],
    ),
  );

  Future<void> _editCollection(
    BuildContext context, [
    CollectionDto? collection,
  ]) async {
    final name = TextEditingController(text: collection?.name);
    final description = TextEditingController(text: collection?.description);
    String? error;
    await showDialog<void>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(
            collection == null ? 'New collection' : 'Rename collection',
          ),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  key: const Key('collection-name'),
                  controller: name,
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: 'Name',
                    errorText: error,
                  ),
                ),
                if (collection == null)
                  TextField(
                    controller: description,
                    decoration: const InputDecoration(labelText: 'Description'),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () async {
                try {
                  if (collection == null) {
                    await controller.createCollection(
                      name.text,
                      description.text,
                    );
                  } else {
                    await controller.renameCollection(collection.id, name.text);
                  }
                  if (dialog.mounted) Navigator.pop(dialog);
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
  }

  Future<void> _schemaEditor(
    BuildContext context,
    CollectionSchemaDto schema,
  ) async {
    await showDialog<void>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Collection schema'),
        content: SizedBox(
          width: 600,
          height: 420,
          child: ListenableBuilder(
            listenable: controller,
            builder: (context, child) {
              final fields = [
                ...?controller.schema?.fields.where((field) => !field.deleted),
              ]..sort(_fieldOrder);
              return ReorderableListView.builder(
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
                itemBuilder: (context, index) {
                  final field = fields[index];
                  return ListTile(
                    key: ValueKey(field.id),
                    title: Text(field.name),
                    subtitle: Text(_fieldSubtitle(field)),
                    onTap: () => _fieldEditor(dialog, field),
                    trailing: IconButton(
                      tooltip: 'Remove field',
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () =>
                          unawaited(controller.removeField(field.id)),
                    ),
                  );
                },
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => _fieldEditor(dialog),
            child: const Text('Add field'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }

  /// One computed field in the dialog list. Tapping opens the editor pre-filled; a definition the
  /// builder cannot represent stays visible with its diagnostic but does not open.
  Widget _computedFieldTile(
    BuildContext context,
    CollectionSchemaDto schema,
    ComputedFieldDefinitionDto item,
  ) {
    final editable = isEditableComputedField(item);
    return ListTile(
      key: ValueKey('computed-${item.id}'),
      title: Text(item.name),
      subtitle: Text(
        editable
            ? '${describeValueType(item.declaredType)}'
                  '${item.nullable ? ' · may be empty' : ''}'
            : item.unsupportedBodyJson != null
            ? 'Made by a newer version (expression v${item.expressionVersion}); not editable here'
            : 'Uses operations this editor does not offer; not editable here',
      ),
      onTap: editable
          ? () => unawaited(
              showComputedFieldEditor(
                context,
                controller: controller,
                schema: schema,
                existing: item,
              ),
            )
          : null,
      trailing: IconButton(
        tooltip: 'Remove computed field',
        icon: const Icon(Icons.delete_outline),
        onPressed: () => unawaited(controller.removeComputedField(item.id)),
      ),
    );
  }

  Future<void> _queryEditor(
    BuildContext context,
    CollectionSchemaDto schema,
  ) async {
    await showDialog<void>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Computed fields and queries'),
          content: SizedBox(
            width: 600,
            height: 430,
            child: ListenableBuilder(
              listenable: controller,
              builder: (context, _) => ListView(
                children: [
                  Row(
                    children: [
                      Text(
                        'Computed fields',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const HelpButton(HelpId.computedFields),
                    ],
                  ),
                  for (final item in controller.computedFields)
                    _computedFieldTile(context, schema, item),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FilledButton.tonalIcon(
                      key: const Key('add-computed-field'),
                      onPressed: () => unawaited(
                        showComputedFieldEditor(
                          context,
                          controller: controller,
                          schema: schema,
                        ),
                      ),
                      icon: const Icon(Icons.add),
                      label: const Text('Add computed field'),
                    ),
                  ),
                  const Divider(height: 32),
                  Row(
                    children: [
                      Text(
                        'Saved queries',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const HelpButton(HelpId.querySavedQueries),
                    ],
                  ),
                  for (final item in controller.queryDefinitions)
                    ListTile(
                      key: ValueKey('saved-query-${item.id}'),
                      title: Text(item.name),
                      subtitle: Text(describeQuery(item, schema)),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            key: ValueKey('edit-query-${item.id}'),
                            tooltip: 'Edit query',
                            icon: const Icon(Icons.edit_outlined),
                            onPressed: () => unawaited(
                              showSavedQueryEditor(
                                context,
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
                            onPressed: () => unawaited(
                              controller.removeQueryDefinition(item.id),
                            ),
                          ),
                        ],
                      ),
                    ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FilledButton.tonalIcon(
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
                      icon: const Icon(Icons.add_chart),
                      label: const Text('Add record-count query'),
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog),
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );
  }

  /// How many active records would be marked invalid by this field as it currently stands.
  ///
  /// The projected record list is already loaded in full for the collection, so this is a read of
  /// what is on screen rather than another trip through the bridge. It is a disclosure, not a
  /// guard: Rust accepts the command either way.
  int _missingRequiredCount({
    required bool required,
    required bool hasDefault,
    required FieldDefinitionDto? existing,
  }) {
    if (!required || hasDefault) return 0;
    // A brand new field has an id no record can hold a value for yet.
    if (existing == null) return controller.records.length;
    return controller.records
        .where((record) => _recordValue(record, existing.id) == null)
        .length;
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
              display: const DisplayMetadataDto(multiline: false),
              order: 0,
              deleted: false,
              enumOptions: enumOptions,
            ),
            value,
            (typed) =>
                onChanged(typed.kind == FieldValueKindDto.null_ ? null : typed),
            label: label,
            allowClear: true,
          ),
        ),
      ),
      Padding(padding: const EdgeInsets.only(top: 8), child: HelpButton(help)),
    ],
  );

  Future<bool> _confirmInvalidating(BuildContext context, int missing) async {
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

  Future<void> _fieldEditor(
    BuildContext context, [
    FieldDefinitionDto? existing,
  ]) async {
    final name = TextEditingController(text: existing?.name);
    var kind = existing?.fieldType.kind ?? FieldTypeKindDto.text;
    var required = existing?.required_ ?? false;
    var multiline = existing?.display.multiline ?? false;
    var scale = existing?.fieldType.scale ?? 2;
    // Range bounds are compared against the stored integer, which is epoch days for a Date, epoch
    // milliseconds for a DateTime, and the scaled representation for a FixedDecimal. Holding them
    // as integers lets the same typed control that edits a record edit the bound.
    var minimum = existing?.validation.minInteger;
    var maximum = existing?.validation.maxInteger;
    final minLength = TextEditingController(
      text: existing?.validation.minLength?.toString() ?? '',
    );
    final maxLength = TextEditingController(
      text: existing?.validation.maxLength?.toString() ?? '',
    );
    var defaultValue = existing?.defaultValue?.kind == FieldValueKindDto.null_
        ? null
        : existing?.defaultValue;
    // Choice options are held here until Save, so a new field can get options and a default in
    // the same step and Cancel leaves the stored options untouched.
    final options = [
      for (final option in [
        ...?existing?.enumOptions.where((option) => !option.deleted),
      ]..sort(_optionOrder))
        _DraftOption(option.id, option.label),
    ];
    var addedOptions = 0;
    List<EnumOptionDto> draftOptions() => [
      for (final (index, option) in options.indexed)
        EnumOptionDto(
          id: option.id,
          label: option.label.text,
          order: index,
          deleted: false,
        ),
    ];
    final order = existing?.order ?? controller.schema?.fields.length ?? 0;
    // Survives a failed save, so retrying updates what the first attempt already created.
    final session = FieldSaveSession();
    String? error;
    await showDialog<void>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(existing == null ? 'Add field' : 'Edit field'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    key: const Key('field-name'),
                    controller: name,
                    decoration: InputDecoration(
                      labelText: 'Name',
                      errorText: error,
                    ),
                  ),
                  DropdownButtonFormField<FieldTypeKindDto>(
                    initialValue: kind,
                    decoration: const InputDecoration(labelText: 'Type'),
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
                          })
                        : null,
                  ),
                  if (kind == FieldTypeKindDto.fixedDecimal)
                    TextFormField(
                      initialValue: '$scale',
                      keyboardType: TextInputType.number,
                      decoration: labelWithHelp(
                        'Decimal scale',
                        HelpId.fieldDecimalScale,
                      ),
                      // The scale decides what the stored integer means, so a change to it
                      // cannot leave a default or a bound behind reading as something else.
                      onChanged: (value) => setState(() {
                        scale = int.tryParse(value) ?? 255;
                        defaultValue = null;
                        minimum = null;
                        maximum = null;
                      }),
                    ),
                  SwitchListTile(
                    title: const Text('Required'),
                    secondary: const HelpButton(HelpId.fieldRequired),
                    value: required,
                    onChanged: (value) => setState(() => required = value),
                  ),
                  if (kind == FieldTypeKindDto.text) ...[
                    SwitchListTile(
                      title: const Text('Multiline'),
                      secondary: const HelpButton(HelpId.fieldMultiline),
                      value: multiline,
                      onChanged: (value) => setState(() => multiline = value),
                    ),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: minLength,
                            keyboardType: TextInputType.number,
                            decoration: labelWithHelp(
                              'Minimum length',
                              HelpId.fieldMinMaxLength,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: TextField(
                            controller: maxLength,
                            keyboardType: TextInputType.number,
                            decoration: labelWithHelp(
                              'Maximum length',
                              HelpId.fieldMinMaxLength,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                  if (kind != FieldTypeKindDto.text &&
                      kind != FieldTypeKindDto.boolean &&
                      kind != FieldTypeKindDto.enum_)
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
                            onChanged: (value) =>
                                setState(() => minimum = value?.integerValue),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _metadataInput(
                            slot: 'field-maximum',
                            label: 'Maximum',
                            help: HelpId.fieldMinMax,
                            kind: kind,
                            scale: scale,
                            enumOptions: existing?.enumOptions ?? const [],
                            value: _boundValue(maximum, kind, scale),
                            onChanged: (value) =>
                                setState(() => maximum = value?.integerValue),
                          ),
                        ),
                      ],
                    ),
                  if (kind == FieldTypeKindDto.enum_)
                    ..._optionsEditor(
                      options,
                      onReorder: (from, to) => setState(() {
                        options.insert(
                          to > from ? to - 1 : to,
                          options.removeAt(from),
                        );
                      }),
                      onRenamed: () => setState(() {}),
                      onRemove: (option) => setState(() {
                        options.remove(option);
                        if (defaultValue?.textValue == option.id) {
                          defaultValue = null;
                        }
                      }),
                      onAdd: () => setState(
                        () => options.add(
                          _DraftOption(tempOptionId(++addedOptions), ''),
                        ),
                      ),
                    ),
                  _metadataInput(
                    slot: 'field-default',
                    label: 'Default (optional)',
                    help: HelpId.fieldDefault,
                    kind: kind,
                    scale: scale,
                    enumOptions: draftOptions(),
                    value: defaultValue,
                    onChanged: (value) => setState(() => defaultValue = value),
                    revision: [
                      for (final option in options)
                        '${option.id}=${option.label.text}',
                    ].join('|'),
                  ),
                  if (_missingRequiredCount(
                        required: required,
                        hasDefault: defaultValue != null,
                        existing: existing,
                      )
                      case final missing when missing > 0)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: ListTile(
                        key: const Key('required-warning'),
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.warning_amber),
                        title: Text(
                          '$missing ${missing == 1 ? 'record has' : 'records have'} no value for '
                          'this field and will be marked invalid until you fill them in. '
                          'Add a default to avoid this.',
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () async {
                final missing = _missingRequiredCount(
                  required: required,
                  hasDefault: defaultValue != null,
                  existing: existing,
                );
                // Rust no longer refuses this, so the disclosure has to happen here, before the
                // command is sent and with the count the user is about to invalidate.
                if (missing > 0 &&
                    !await _confirmInvalidating(context, missing)) {
                  return;
                }
                try {
                  final dto = FieldDefinitionDto(
                    id: existing?.id ?? '',
                    name: name.text,
                    fieldType: FieldTypeDto(
                      kind: kind,
                      scale: kind == FieldTypeKindDto.fixedDecimal
                          ? scale
                          : null,
                    ),
                    required_: required,
                    defaultValue: defaultValue,
                    validation: ValidationMetadataDto(
                      minInteger: minimum,
                      maxInteger: maximum,
                      minLength: int.tryParse(minLength.text),
                      maxLength: int.tryParse(maxLength.text),
                    ),
                    display: DisplayMetadataDto(multiline: multiline),
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
                  if (dialog.mounted) Navigator.pop(dialog);
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
  }

  /// The Options section of the field editor for a Choice field: one row per option in the order
  /// it will be saved, each with a drag handle, its label, and a remove button.
  List<Widget> _optionsEditor(
    List<_DraftOption> options, {
    required ReorderCallback onReorder,
    required VoidCallback onRenamed,
    required ValueChanged<_DraftOption> onRemove,
    required VoidCallback onAdd,
  }) => [
    const Padding(
      padding: EdgeInsets.only(top: 12),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text('Options', style: TextStyle(fontWeight: FontWeight.w600)),
      ),
    ),
    ReorderableListView(
      key: const Key('field-options'),
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      buildDefaultDragHandles: false,
      onReorder: onReorder,
      children: [
        for (final (index, option) in options.indexed)
          Row(
            key: ValueKey(option.id),
            children: [
              ReorderableDragStartListener(
                index: index,
                child: const Padding(
                  padding: EdgeInsets.all(8),
                  child: Icon(Icons.drag_handle),
                ),
              ),
              Expanded(
                child: TextField(
                  key: ValueKey('option-label-${option.id}'),
                  controller: option.label,
                  // A freshly added row is where the user is about to type.
                  autofocus:
                      isTempOptionId(option.id) && option.label.text.isEmpty,
                  decoration: const InputDecoration(hintText: 'Option label'),
                  onChanged: (_) => onRenamed(),
                ),
              ),
              IconButton(
                key: ValueKey('remove-option-${option.id}'),
                tooltip: 'Remove option',
                icon: const Icon(Icons.close),
                onPressed: () => onRemove(option),
              ),
            ],
          ),
      ],
    ),
    Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        key: const Key('add-option'),
        onPressed: onAdd,
        icon: const Icon(Icons.add),
        label: const Text('Add option'),
      ),
    ),
  ];

  /// Replaces the collection header while records are being selected.
  Widget _selectionHeader(BuildContext context, CollectionSchemaDto schema) {
    final count = controller.selectedRecordIds.length;
    return Row(
      children: [
        Expanded(
          child: Text(
            '$count selected',
            style: Theme.of(context).textTheme.titleLarge,
          ),
        ),
        IconButton(
          key: const Key('batch-edit'),
          tooltip: 'Edit field',
          onPressed: count == 0
              ? null
              : () => unawaited(_batchEdit(context, schema)),
          icon: const Icon(Icons.edit_outlined),
        ),
        IconButton(
          key: const Key('batch-delete'),
          tooltip: 'Delete',
          onPressed: count == 0 ? null : () => unawaited(_batchDelete(context)),
          icon: const Icon(Icons.delete_outline),
        ),
        TextButton(
          key: const Key('cancel-selection'),
          onPressed: controller.clearSelection,
          child: const Text('Cancel'),
        ),
      ],
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
    final chosen = await showDialog<bool>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text('Edit field on $count records'),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropdownButtonFormField<String>(
                    key: const Key('batch-field'),
                    initialValue: field.id,
                    decoration: const InputDecoration(labelText: 'Field'),
                    items: [
                      for (final item in fields)
                        DropdownMenuItem(
                          value: item.id,
                          child: Text(item.name),
                        ),
                    ],
                    onChanged: (id) => setState(() {
                      field = fields.firstWhere((item) => item.id == id);
                      value = null;
                    }),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: const FieldRendererRegistry().editor(
                      field,
                      value,
                      (updated) => value = updated,
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              key: const Key('batch-edit-continue'),
              onPressed: () => Navigator.pop(dialog, true),
              child: const Text('Continue'),
            ),
          ],
        ),
      ),
    );
    if (chosen != true || !context.mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
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
      messenger.showSnackBar(
        SnackBar(content: Text('$affected records updated')),
      );
    } catch (_) {
      // Left on the banner, as in _batchDelete.
    }
  }

  Future<void> _recordEditor(
    BuildContext context,
    CollectionSchemaDto schema, [
    RecordDto? existing,
  ]) async {
    final values = <String, FieldValueDto>{
      for (final item in existing?.values ?? const <RecordValueDto>[])
        item.fieldId: item.value,
    };
    String? error;
    final fields = schema.fields.where((field) => !field.deleted).toList()
      ..sort(_fieldOrder);
    await showDialog<void>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(existing == null ? 'New record' : 'Edit record'),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final field in fields)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: const FieldRendererRegistry().editor(
                        field,
                        values[field.id],
                        (value) => values[field.id] = value,
                        // A record opened from the list because it is invalid should say which
                        // field is at fault, not leave the user hunting for it.
                        errorText: _diagnosticFor(existing, field.id),
                      ),
                    ),
                  if (error != null)
                    Text(
                      error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () async {
                try {
                  final submitted = values.entries
                      .map(
                        (entry) => RecordValueDto(
                          fieldId: entry.key,
                          value: entry.value,
                        ),
                      )
                      .toList();
                  if (existing == null) {
                    await controller.createRecord(submitted);
                  } else {
                    await controller.updateRecord(existing.id, submitted);
                  }
                  if (dialog.mounted) Navigator.pop(dialog);
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
  }
}

/// The projected diagnostic naming [fieldId], if this record carries one.
String? _diagnosticFor(RecordDto? record, String fieldId) => record?.diagnostics
    .where((item) => item.fieldId == fieldId)
    .map((item) => item.message)
    .firstOrNull;

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
