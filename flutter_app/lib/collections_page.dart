import 'dart:async';

import 'package:fi/controllers.dart';
import 'package:fi/field_registry.dart';
import 'package:fi/src/rust/api/models.dart';
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
          child: LayoutBuilder(
            builder: (context, constraints) {
              // Narrow Android widths cannot fit three labelled buttons next to the title, so the
              // same actions collapse to icons and stay reachable.
              final wide = constraints.maxWidth >= 620;
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
                    return ListTile(
                      key: ValueKey(record.id),
                      leading: Icon(
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
                      onTap: () => _recordEditor(context, schema, record),
                      trailing: IconButton(
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
                    subtitle: Text(
                      field.fieldType.kind == FieldTypeKindDto.enum_ &&
                              field.enumOptions.isNotEmpty
                          ? '${field.fieldType.kind.name} · ${field.enumOptions.where((option) => !option.deleted).map((option) => option.label).join(', ')}'
                          : field.fieldType.kind.name,
                    ),
                    onTap: () => _fieldEditor(dialog, field),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (field.fieldType.kind == FieldTypeKindDto.enum_)
                          IconButton(
                            tooltip: 'Edit enum options',
                            icon: const Icon(Icons.list_alt),
                            onPressed: () =>
                                _enumOptionsEditor(dialog, field.id),
                          ),
                        IconButton(
                          tooltip: 'Remove field',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () =>
                              unawaited(controller.removeField(field.id)),
                        ),
                      ],
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

  Future<void> _queryEditor(
    BuildContext context,
    CollectionSchemaDto schema,
  ) async {
    final numericFields = schema.fields
        .where(
          (field) =>
              !field.deleted &&
              (field.fieldType.kind == FieldTypeKindDto.integer ||
                  field.fieldType.kind == FieldTypeKindDto.fixedDecimal ||
                  field.fieldType.kind == FieldTypeKindDto.duration),
        )
        .toList();
    String? selected = numericFields.isEmpty ? null : numericFields.first.id;
    final name = TextEditingController();
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
                  Text(
                    'Computed fields',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  for (final item in controller.computedFields)
                    ListTile(
                      title: Text(item.name),
                      subtitle: Text(item.declaredType.kind.name),
                      trailing: IconButton(
                        tooltip: 'Remove computed field',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () =>
                            unawaited(controller.removeComputedField(item.id)),
                      ),
                    ),
                  TextField(
                    controller: name,
                    decoration: const InputDecoration(
                      labelText: 'Computed field name',
                    ),
                  ),
                  DropdownButtonFormField<String>(
                    initialValue: selected,
                    decoration: const InputDecoration(
                      labelText: 'Source numeric field',
                    ),
                    items: [
                      for (final field in numericFields)
                        DropdownMenuItem(
                          value: field.id,
                          child: Text(field.name),
                        ),
                    ],
                    onChanged: (value) => setState(() => selected = value),
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FilledButton.tonalIcon(
                      onPressed: selected == null || name.text.trim().isEmpty
                          ? null
                          : () async {
                              final field = numericFields.firstWhere(
                                (item) => item.id == selected,
                              );
                              final source = ExpressionNodeDto(
                                kind: ExpressionKindDto.field,
                                field: FieldReferenceDto(
                                  kind: FieldReferenceKindDto.source,
                                  id: field.id,
                                ),
                              );
                              final absolute = ExpressionNodeDto(
                                kind: ExpressionKindDto.abs,
                                expression: 0,
                              );
                              await controller.createComputedField(
                                ComputedFieldDefinitionDto(
                                  id: '',
                                  collectionId: schema.id,
                                  name: name.text.trim(),
                                  declaredType: _queryValueType(
                                    field.fieldType,
                                  ),
                                  nullable: !field.required_,
                                  expressionVersion: 1,
                                  expression: ExpressionDto(
                                    root: 1,
                                    nodes: [source, absolute],
                                  ),
                                  order: controller.computedFields.length,
                                  deleted: false,
                                ),
                              );
                              name.clear();
                              setState(() {});
                            },
                      icon: const Icon(Icons.add),
                      label: const Text('Add absolute-value field'),
                    ),
                  ),
                  const Divider(height: 32),
                  Text(
                    'Saved queries',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  for (final item in controller.queryDefinitions)
                    ListTile(
                      title: Text(item.name),
                      subtitle: const Text('Typed collection query'),
                      trailing: IconButton(
                        tooltip: 'Remove query',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => unawaited(
                          controller.removeQueryDefinition(item.id),
                        ),
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

  Future<void> _fieldEditor(
    BuildContext context, [
    FieldDefinitionDto? existing,
  ]) async {
    final name = TextEditingController(text: existing?.name);
    var kind = existing?.fieldType.kind ?? FieldTypeKindDto.text;
    var required = existing?.required_ ?? false;
    var multiline = existing?.display.multiline ?? false;
    var scale = existing?.fieldType.scale ?? 2;
    final minimum = TextEditingController(
      text: existing?.validation.minInteger?.toString() ?? '',
    );
    final maximum = TextEditingController(
      text: existing?.validation.maxInteger?.toString() ?? '',
    );
    final minLength = TextEditingController(
      text: existing?.validation.minLength?.toString() ?? '',
    );
    final maxLength = TextEditingController(
      text: existing?.validation.maxLength?.toString() ?? '',
    );
    final defaultValue = TextEditingController(
      text: _defaultText(existing?.defaultValue, kind, scale),
    );
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
                            child: Text(value.name),
                          ),
                        )
                        .toList(),
                    onChanged: existing == null
                        ? (value) => setState(() {
                            kind = value!;
                            defaultValue.clear();
                          })
                        : null,
                  ),
                  if (kind == FieldTypeKindDto.fixedDecimal)
                    TextFormField(
                      initialValue: '$scale',
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Decimal scale',
                      ),
                      onChanged: (value) => scale = int.tryParse(value) ?? 255,
                    ),
                  SwitchListTile(
                    title: const Text('Required'),
                    value: required,
                    onChanged: (value) => setState(() => required = value),
                  ),
                  if (kind == FieldTypeKindDto.text) ...[
                    SwitchListTile(
                      title: const Text('Multiline'),
                      value: multiline,
                      onChanged: (value) => setState(() => multiline = value),
                    ),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: minLength,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: 'Minimum length',
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: TextField(
                            controller: maxLength,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: 'Maximum length',
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
                      children: [
                        Expanded(
                          child: TextField(
                            controller: minimum,
                            keyboardType: const TextInputType.numberWithOptions(
                              signed: true,
                            ),
                            decoration: const InputDecoration(
                              labelText: 'Minimum',
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: TextField(
                            controller: maximum,
                            keyboardType: const TextInputType.numberWithOptions(
                              signed: true,
                            ),
                            decoration: const InputDecoration(
                              labelText: 'Maximum',
                            ),
                          ),
                        ),
                      ],
                    ),
                  TextField(
                    controller: defaultValue,
                    decoration: InputDecoration(
                      labelText: 'Default (optional)',
                      helperText: kind == FieldTypeKindDto.enum_
                          ? 'Enum option UUID'
                          : kind == FieldTypeKindDto.boolean
                          ? 'true or false'
                          : null,
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
                final fields = controller.schema?.fields ?? const [];
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
                    defaultValue: _parseDefault(defaultValue.text, kind, scale),
                    validation: ValidationMetadataDto(
                      minInteger: int.tryParse(minimum.text),
                      maxInteger: int.tryParse(maximum.text),
                      minLength: int.tryParse(minLength.text),
                      maxLength: int.tryParse(maxLength.text),
                    ),
                    display: DisplayMetadataDto(multiline: multiline),
                    order: existing?.order ?? fields.length,
                    deleted: false,
                    enumOptions: existing?.enumOptions ?? const [],
                  );
                  if (existing == null) {
                    await controller.addField(dto);
                  } else {
                    await controller.updateField(dto);
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

  Future<void> _enumOptionsEditor(BuildContext context, String fieldId) async {
    await showDialog<void>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Enum options'),
        content: SizedBox(
          width: 420,
          height: 320,
          child: ListenableBuilder(
            listenable: controller,
            builder: (context, child) {
              final field = controller.schema?.fields
                  .where((item) => item.id == fieldId)
                  .firstOrNull;
              final options =
                  [...?field?.enumOptions.where((item) => !item.deleted)]
                    ..sort((left, right) {
                      final order = left.order.compareTo(right.order);
                      return order == 0 ? left.id.compareTo(right.id) : order;
                    });
              return options.isEmpty
                  ? const Center(
                      child: Text(
                        'Add at least one option before creating enum values.',
                      ),
                    )
                  : ListView(
                      children: [
                        for (final option in options)
                          ListTile(
                            key: ValueKey(option.id),
                            title: Text(option.label),
                            onTap: () =>
                                _editEnumOption(dialog, fieldId, option),
                            trailing: IconButton(
                              tooltip: 'Remove option',
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () => unawaited(
                                controller.removeEnumOption(fieldId, option.id),
                              ),
                            ),
                          ),
                      ],
                    );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => _editEnumOption(dialog, fieldId),
            child: const Text('Add option'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }

  Future<void> _editEnumOption(
    BuildContext context,
    String fieldId, [
    EnumOptionDto? existing,
  ]) async {
    final label = TextEditingController(text: existing?.label);
    String? error;
    await showDialog<void>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(
            existing == null ? 'Add enum option' : 'Edit enum option',
          ),
          content: TextField(
            controller: label,
            autofocus: true,
            decoration: InputDecoration(labelText: 'Label', errorText: error),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () async {
                try {
                  final field = controller.schema!.fields.firstWhere(
                    (item) => item.id == fieldId,
                  );
                  await controller.upsertEnumOption(
                    fieldId,
                    EnumOptionDto(
                      id: existing?.id ?? '',
                      label: label.text,
                      order: existing?.order ?? field.enumOptions.length,
                      deleted: false,
                    ),
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

ValueTypeDto _queryValueType(FieldTypeDto type) => switch (type.kind) {
  FieldTypeKindDto.text => const ValueTypeDto(kind: ValueTypeKindDto.text),
  FieldTypeKindDto.integer => const ValueTypeDto(
    kind: ValueTypeKindDto.integer,
  ),
  FieldTypeKindDto.fixedDecimal => ValueTypeDto(
    kind: ValueTypeKindDto.fixedDecimal,
    scale: type.scale,
  ),
  FieldTypeKindDto.boolean => const ValueTypeDto(
    kind: ValueTypeKindDto.boolean,
  ),
  FieldTypeKindDto.date => const ValueTypeDto(kind: ValueTypeKindDto.date),
  FieldTypeKindDto.dateTime => const ValueTypeDto(
    kind: ValueTypeKindDto.dateTime,
  ),
  FieldTypeKindDto.duration => const ValueTypeDto(
    kind: ValueTypeKindDto.duration,
  ),
  FieldTypeKindDto.enum_ => const ValueTypeDto(kind: ValueTypeKindDto.enum_),
};

String _defaultText(FieldValueDto? value, FieldTypeKindDto kind, int scale) {
  if (value == null || value.kind == FieldValueKindDto.null_) return '';
  if (kind == FieldTypeKindDto.fixedDecimal) {
    return formatScaled(value.integerValue ?? 0, scale);
  }
  if (kind == FieldTypeKindDto.text || kind == FieldTypeKindDto.enum_) {
    return value.textValue ?? '';
  }
  if (kind == FieldTypeKindDto.boolean) return '${value.booleanValue ?? false}';
  return '${value.integerValue ?? 0}';
}

FieldValueDto? _parseDefault(String raw, FieldTypeKindDto kind, int scale) {
  if (raw.trim().isEmpty) return null;
  final value = switch (kind) {
    FieldTypeKindDto.text => FieldValueDto(
      kind: FieldValueKindDto.text,
      textValue: raw,
    ),
    FieldTypeKindDto.integer => FieldValueDto(
      kind: FieldValueKindDto.integer,
      integerValue: int.tryParse(raw),
    ),
    FieldTypeKindDto.fixedDecimal => FieldValueDto(
      kind: FieldValueKindDto.fixedDecimal,
      integerValue: parseScaled(raw, scale),
    ),
    FieldTypeKindDto.boolean => FieldValueDto(
      kind: FieldValueKindDto.boolean,
      booleanValue: switch (raw.trim().toLowerCase()) {
        'true' => true,
        'false' => false,
        _ => null,
      },
    ),
    FieldTypeKindDto.date => FieldValueDto(
      kind: FieldValueKindDto.date,
      integerValue: int.tryParse(raw),
    ),
    FieldTypeKindDto.dateTime => FieldValueDto(
      kind: FieldValueKindDto.dateTime,
      integerValue: int.tryParse(raw),
    ),
    FieldTypeKindDto.duration => FieldValueDto(
      kind: FieldValueKindDto.duration,
      integerValue: int.tryParse(raw),
    ),
    FieldTypeKindDto.enum_ => FieldValueDto(
      kind: FieldValueKindDto.enum_,
      textValue: raw.trim(),
    ),
  };
  if ((kind == FieldTypeKindDto.boolean && value.booleanValue == null) ||
      (kind != FieldTypeKindDto.text &&
          kind != FieldTypeKindDto.enum_ &&
          kind != FieldTypeKindDto.boolean &&
          value.integerValue == null)) {
    throw const FormatException(
      'Default value is invalid for this field type.',
    );
  }
  return value;
}
