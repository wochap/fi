import 'package:fi/controllers.dart';
import 'package:fi/src/rust/api/models.dart';
import 'package:fi/widgets/query_builder.dart';
import 'package:flutter/material.dart';

/// How many active widgets evaluate [queryId]. Widgets reference a query by id, so an in-place
/// edit reaches all of them; the number is stated wherever that edit is offered.
int widgetsUsingQuery(CollectionsController controller, String queryId) =>
    controller.widgetDefinitions
        .where((item) => !item.deleted && item.queryId == queryId)
        .length;

/// Creates or edits one saved query with the same builder the widget form uses.
///
/// [onSave] receives the assembled definition and decides whether it becomes an update (keeping
/// the id) or a new query; the dialog itself never chooses.
final class QueryEditorDialog extends StatefulWidget {
  const QueryEditorDialog({
    required this.schema,
    required this.heading,
    required this.initialName,
    required this.initialState,
    required this.onSave,
    this.existing,
    this.referencingWidgets = 0,
    this.order = 0,
    super.key,
  });

  final CollectionSchemaDto schema;
  final String heading;
  final String initialName;

  /// `null` when the saved definition says something the builder cannot say; the dialog then
  /// shows it read-only rather than silently rewriting it on save.
  final QueryBuilderState? initialState;

  final QueryDefinitionDto? existing;
  final int referencingWidgets;
  final int order;
  final Future<void> Function(QueryDefinitionDto) onSave;

  @override
  State<QueryEditorDialog> createState() => _QueryEditorDialogState();
}

class _QueryEditorDialogState extends State<QueryEditorDialog> {
  final name = TextEditingController();
  late QueryBuilderState? query = widget.initialState;
  String? error;
  bool saving = false;

  @override
  void initState() {
    super.initState();
    name.text = widget.initialName;
  }

  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  String get _usage => switch (widget.referencingWidgets) {
    0 => 'Used by no widgets',
    1 => 'Used by 1 widget',
    final count => 'Used by $count widgets',
  };

  String? get _blocker {
    if (name.text.trim().isEmpty) return 'Give the query a name.';
    return query?.blocker;
  }

  @override
  Widget build(BuildContext context) {
    final state = query;
    return AlertDialog(
      key: const Key('query-editor'),
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(widget.heading),
          Text(
            _usage,
            key: const Key('query-editor-usage'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                key: const Key('query-name'),
                controller: name,
                decoration: const InputDecoration(labelText: 'Query name'),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 12),
              if (state == null)
                Text(
                  'This query was made elsewhere and cannot be edited here.\n\n'
                  '${widget.existing == null ? '' : describeQuery(widget.existing!, widget.schema)}',
                  key: const Key('query-editor-readonly'),
                )
              else
                QueryBuilder(
                  schema: widget.schema,
                  state: state,
                  onChanged: (next) => setState(() => query = next),
                ),
              if (error case final message?)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    message,
                    key: const Key('query-editor-error'),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(state == null ? 'Close' : 'Cancel'),
        ),
        if (state != null)
          FilledButton(
            key: const Key('save-query'),
            onPressed: _blocker != null || saving ? null : _save,
            child: const Text('Save'),
          ),
      ],
    );
  }

  Future<void> _save() async {
    final state = query;
    if (state == null) return;
    setState(() {
      saving = true;
      error = null;
    });
    final existing = widget.existing;
    final definition = state.toDefinition(
      widget.schema,
      name.text.trim(),
      existing?.order ?? widget.order,
      id: existing?.id ?? '',
      queryVersion: existing?.queryVersion ?? 1,
    );
    try {
      await widget.onSave(definition);
      if (mounted) Navigator.pop(context, true);
    } catch (failure) {
      if (mounted) {
        setState(() {
          saving = false;
          error = bridgeMessage(failure);
        });
      }
    }
  }
}

/// Opens [QueryEditorDialog] for an existing saved query, pre-filled when the builder can read it.
Future<bool?> showSavedQueryEditor(
  BuildContext context, {
  required CollectionsController controller,
  required CollectionSchemaDto schema,
  required QueryDefinitionDto definition,
  required Future<void> Function(QueryDefinitionDto) onSave,
  String heading = 'Edit query',
}) => showDialog<bool>(
  context: context,
  builder: (dialog) => QueryEditorDialog(
    schema: schema,
    heading: heading,
    initialName: definition.name,
    initialState: QueryBuilderState.fromDefinition(definition, schema),
    existing: definition,
    referencingWidgets: widgetsUsingQuery(controller, definition.id),
    onSave: onSave,
  ),
);
