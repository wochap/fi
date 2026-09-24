import 'package:fi/controllers.dart';
import 'package:fi/src/rust/api/models.dart';
import 'package:fi/theme/form_errors.dart';
import 'package:fi/widgets/expression_builder.dart';
import 'package:flutter/material.dart';

/// Below this width the editor takes the whole screen; above it, a 720px dialog.
const double _fullscreenBelow = 760;

/// Whether [definition] can be opened in the builder. Definitions from a newer expression
/// version, or using nodes the builder does not offer, stay read-only in the list.
bool isEditableComputedField(ComputedFieldDefinitionDto definition) =>
    definition.unsupportedBodyJson == null &&
    definition.expression != null &&
    expressionFromDto(definition.expression!) != null;

/// Creates or edits one computed field: a name plus a builder-made expression whose declared
/// type and nullability come only from Rust inference.
///
/// [onSave] receives the assembled definition; for an existing field it carries the same id and
/// order, so the caller issues an in-place update.
final class ComputedFieldEditor extends StatefulWidget {
  const ComputedFieldEditor({
    required this.schema,
    required this.infer,
    required this.onSave,
    this.existing,
    this.order = 0,
    this.inferenceDebounce = const Duration(milliseconds: 150),
    super.key,
  });

  final CollectionSchemaDto schema;
  final ComputedFieldDefinitionDto? existing;
  final int order;
  final Future<InferredTypeDto> Function(ExpressionDto expression) infer;
  final Future<void> Function(ComputedFieldDefinitionDto definition) onSave;
  final Duration inferenceDebounce;

  @override
  State<ComputedFieldEditor> createState() => _ComputedFieldEditorState();
}

class _ComputedFieldEditorState extends State<ComputedFieldEditor> {
  final name = TextEditingController();
  late final ExprNode initial = _initialTree();
  ExpressionBuilderValue value = const ExpressionBuilderValue();

  /// What the last save was refused for: a `name` issue under the name, the rest above the
  /// actions.
  FormIssues issues = FormIssues.none;
  bool saving = false;

  ExprNode _initialTree() {
    if (widget.existing?.expression case final expression?) {
      if (expressionFromDto(expression) case final tree?) return tree;
    }
    final first = widget.schema.fields
        .where(
          (field) =>
              !field.deleted &&
              computedSourceKinds.contains(field.fieldType.kind),
        )
        .firstOrNull;
    return FieldLeaf(first?.id);
  }

  @override
  void initState() {
    super.initState();
    name.text = widget.existing?.name ?? '';
  }

  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  bool get _canSave =>
      !saving &&
      name.text.trim().isNotEmpty &&
      value.expression != null &&
      value.inferred != null;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 16, 12, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  widget.existing == null
                      ? 'New computed field'
                      : 'Edit computed field',
                  style: theme.textTheme.titleLarge,
                ),
              ),
              IconButton(
                tooltip: 'Close',
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(22, 8, 22, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  key: const Key('computed-name'),
                  controller: name,
                  decoration: InputDecoration(
                    label: requiredLabel('Name'),
                    hintText: 'e.g. difference',
                    errorText: errorTextOf(issues.of('name')),
                    errorMaxLines: errorLinesOf(issues.of('name')),
                  ),
                  onChanged: (_) =>
                      setState(() => issues = issues.without('name')),
                ),
                const SizedBox(height: 16),
                ExpressionBuilder(
                  schema: widget.schema,
                  initial: initial,
                  infer: widget.infer,
                  debounce: widget.inferenceDebounce,
                  onChanged: (next) => setState(() => value = next),
                ),
              ],
            ),
          ),
        ),
        if (issues.form.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 10, 22, 0),
            child: FormErrorLines(
              issues.form,
              key: const Key('computed-editor-error'),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 12, 22, 20),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                key: const Key('save-computed'),
                onPressed: _canSave ? _save : null,
                child: const Text('Save'),
              ),
            ],
          ),
        ),
      ],
    );
    final fullscreen = MediaQuery.sizeOf(context).width < _fullscreenBelow;
    return fullscreen
        ? Dialog.fullscreen(
            key: const Key('computed-editor'),
            child: SafeArea(child: body),
          )
        : Dialog(
            key: const Key('computed-editor'),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720, maxHeight: 720),
              child: body,
            ),
          );
  }

  Future<void> _save() async {
    final expression = value.expression;
    final inferred = value.inferred;
    if (expression == null || inferred == null) return;
    setState(() {
      saving = true;
      issues = FormIssues.none;
    });
    final existing = widget.existing;
    final definition = ComputedFieldDefinitionDto(
      id: existing?.id ?? '',
      collectionId: widget.schema.id,
      name: name.text.trim(),
      // Copied from Rust's answer for exactly this expression; never chosen here.
      declaredType: inferred.valueType,
      nullable: inferred.nullable,
      expressionVersion: existing?.expressionVersion ?? 1,
      expression: expression,
      order: existing?.order ?? widget.order,
      deleted: false,
    );
    try {
      await widget.onSave(definition);
      if (mounted) Navigator.pop(context, true);
    } catch (failure) {
      if (mounted) {
        setState(() {
          saving = false;
          issues = FormIssues.from(failure).keyed(const {'name': 'name'});
        });
      }
    }
  }
}

/// Opens [ComputedFieldEditor] to create a field (`existing == null`) or edit one in place.
Future<bool?> showComputedFieldEditor(
  BuildContext context, {
  required CollectionsController controller,
  required CollectionSchemaDto schema,
  ComputedFieldDefinitionDto? existing,
}) => showDialog<bool>(
  context: context,
  builder: (dialog) => ComputedFieldEditor(
    schema: schema,
    existing: existing,
    order: controller.computedFields.length,
    infer: (expression) =>
        controller.bridge.inferComputedExpression(schema.id, expression),
    onSave: existing == null
        ? controller.createComputedField
        : controller.updateComputedField,
  ),
);
