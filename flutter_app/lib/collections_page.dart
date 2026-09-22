import 'dart:async';

import 'package:fi/controllers.dart';
import 'package:fi/field_registry.dart';
import 'package:fi/help_button.dart';
import 'package:fi/help_copy.dart';
import 'package:fi/src/rust/api/models.dart';
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
                  Row(
                    children: [
                      Text(
                        'Computed fields',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const HelpButton(HelpId.queryComputedFields),
                    ],
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
  /// than leaving digits that now mean something else.
  Widget _metadataInput({
    required String slot,
    required String label,
    required HelpId help,
    required FieldTypeKindDto kind,
    required int scale,
    required List<EnumOptionDto> enumOptions,
    required FieldValueDto? value,
    required ValueChanged<FieldValueDto?> onChanged,
  }) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(
        child: KeyedSubtree(
          key: ValueKey('$slot-$kind-$scale'),
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
            (typed) => onChanged(
              typed.kind == FieldValueKindDto.null_ ? null : typed,
            ),
            label: label,
            allowClear: true,
          ),
        ),
      ),
      Padding(
        padding: const EdgeInsets.only(top: 8),
        child: HelpButton(help),
      ),
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
                            // Default and bounds are typed by the kind, so they cannot survive it.
                            defaultValue = null;
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
                            onChanged: (value) => setState(
                              () => minimum = value?.integerValue,
                            ),
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
                            onChanged: (value) => setState(
                              () => maximum = value?.integerValue,
                            ),
                          ),
                        ),
                      ],
                    ),
                  _metadataInput(
                    slot: 'field-default',
                    label: 'Default (optional)',
                    help: HelpId.fieldDefault,
                    kind: kind,
                    scale: scale,
                    enumOptions: existing?.enumOptions ?? const [],
                    value: defaultValue,
                    onChanged: (value) => setState(() => defaultValue = value),
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
                final fields = controller.schema?.fields ?? const [];
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

