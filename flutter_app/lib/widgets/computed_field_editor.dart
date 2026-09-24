import 'package:fi/controllers.dart';
import 'package:fi/src/rust/api/models.dart';
import 'package:fi/theme/form_errors.dart';
import 'package:fi/theme/form_surface.dart';
import 'package:fi/theme/inputs.dart';
import 'package:fi/widgets/expression_builder.dart';
import 'package:flutter/material.dart';

/// Whether [definition] can be opened in the builder. Definitions from a newer expression
/// version, or using nodes the builder does not offer, stay read-only in the list.
bool isEditableComputedField(ComputedFieldDefinitionDto definition) =>
    definition.unsupportedBodyJson == null &&
    definition.expression != null &&
    expressionFromDto(definition.expression!) != null;

/// Creates or edits one computed field on the shared form surface (a bottom sheet on a phone, a
/// dialog otherwise): a name plus a builder-made expression whose declared type and nullability
/// come only from Rust inference.
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
  Widget build(BuildContext context) => FormSurface(
    key: const Key('computed-editor'),
    title: widget.existing == null
        ? 'New computed field'
        : 'Edit computed field',
    contextLabel: 'in ${widget.schema.name}',
    width: 676,
    showRequiredLegend: true,
    body: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 16,
      children: [
        FiTextInput(
          key: const Key('computed-name'),
          controller: name,
          label: 'Name',
          required: true,
          hint: 'e.g. difference',
          errors: issues.of('name'),
          onChanged: (_) => setState(() => issues = issues.without('name')),
        ),
        ExpressionBuilder(
          schema: widget.schema,
          initial: initial,
          infer: widget.infer,
          debounce: widget.inferenceDebounce,
          onChanged: (next) => setState(() => value = next),
        ),
      ],
    ),
    message: issues.form.isEmpty
        ? null
        : FormErrorLines(issues.form, key: const Key('computed-editor-error')),
    primaryLabel: 'Save',
    primaryKey: const Key('save-computed'),
    onPrimary: _canSave ? _save : null,
  );

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
}) => showFormSurface<bool>(
  context,
  builder: (route) => ComputedFieldEditor(
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
