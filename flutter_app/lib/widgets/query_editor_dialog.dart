import 'dart:async';

import 'package:fi/exact_format.dart';
import 'package:fi/l10n/l10n.dart';
import 'package:fi/controllers.dart';
import 'package:fi/src/rust/api/models.dart';
import 'package:fi/theme/confirm_dialog.dart';
import 'package:fi/theme/form_errors.dart';
import 'package:fi/theme/inputs.dart';
import 'package:fi/theme/nocturne.dart';
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
    this.run,
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

  /// Runs a candidate query for the "Result now" line. Null hides the line.
  final Future<QueryResultDto> Function(CollectionQueryDto query)? run;

  @override
  State<QueryEditorDialog> createState() => _QueryEditorDialogState();
}

class _QueryEditorDialogState extends State<QueryEditorDialog> {
  final name = TextEditingController();
  late QueryBuilderState? query = widget.initialState;

  /// What the last save was refused for: a `name` issue under the name, the rest above the
  /// actions.
  FormIssues issues = FormIssues.none;
  bool saving = false;

  /// The query's current result, or null while the builder is incomplete or the query fails.
  QueryResultDto? resultNow;
  Timer? _resultTimer;
  int _resultRevision = 0;

  @override
  void initState() {
    super.initState();
    name.text = widget.initialName;
  }

  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The first evaluation needs the locale's decimal separator, so it waits for dependencies.
    if (!_started) {
      _started = true;
      _scheduleResult();
    }
  }

  @override
  void dispose() {
    _resultTimer?.cancel();
    name.dispose();
    super.dispose();
  }

  /// Reevaluates "Result now" 300 ms after the builder settles. A newer change supersedes an
  /// answer still in flight.
  void _scheduleResult() {
    _resultTimer?.cancel();
    final revision = ++_resultRevision;
    final state = query;
    final run = widget.run;
    resultNow = null;
    if (state == null || run == null || state.blocker(context.l10n) != null) {
      return;
    }
    final candidate = state.toDefinition(
      widget.schema,
      '',
      0,
      decimalSeparator: decimalSeparatorOf(context),
    );
    _resultTimer = Timer(const Duration(milliseconds: 300), () async {
      QueryResultDto? result;
      try {
        result = await run(candidate.query!);
      } catch (_) {
        result = null;
      }
      if (mounted && revision == _resultRevision) {
        setState(() => resultNow = result);
      }
    });
  }

  /// The result in words: an exact scalar, or the number of points of a series.
  String? _resultText(AppLocalizations l, QueryResultDto result) =>
      switch (result.kind) {
        QueryResultKindDto.scalar =>
          result.value == null
              ? l.widgetNoRecordsMatch
              : exactFromTypedValue(
                  result.value,
                ).label(l, decimalSeparator: decimalSeparatorOf(context)),
        QueryResultKindDto.series => l.queryResultPoints(result.points.length),
        QueryResultKindDto.categorySeries => l.queryResultPoints(
          result.categoryPoints.length,
        ),
        QueryResultKindDto.recordSet => null,
      };

  String? _blocker(AppLocalizations l) {
    if (name.text.trim().isEmpty) return l.queryNameRequired;
    return query?.blocker(l);
  }

  @override
  Widget build(BuildContext context) {
    final state = query;
    final l = context.l10n;
    return AlertDialog(
      key: const Key('query-editor'),
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(widget.heading),
          if (widget.existing != null || widget.referencingWidgets > 0) ...[
            const SizedBox(height: 2),
            Text(
              widget.referencingWidgets > 0
                  ? l.queryUsedByApplies(widget.referencingWidgets)
                  : l.queryUsedBy(0),
              key: const Key('query-editor-usage'),
              style: TextStyle(fontSize: 12, color: Nocturne.muted(.55)),
            ),
          ],
        ],
      ),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              FiTextInput(
                key: const Key('query-name'),
                controller: name,
                label: l.queryName,
                required: true,
                errors: issues.fieldLines(context.l10n, 'name'),
                onChanged: (_) =>
                    setState(() => issues = issues.without('name')),
              ),
              const SizedBox(height: 12),
              if (state == null)
                Text(
                  '${l.queryNotEditable}\n\n'
                  '${widget.existing == null ? '' : describeQuery(l, widget.existing!, widget.schema)}',
                  key: const Key('query-editor-readonly'),
                )
              else
                QueryBuilder(
                  schema: widget.schema,
                  state: state,
                  onChanged: (next) => setState(() {
                    query = next;
                    _scheduleResult();
                  }),
                ),
              if (resultNow case final result?)
                if (_resultText(l, result) case final text?)
                  Padding(
                    padding: const EdgeInsets.only(top: 14),
                    child: Row(
                      key: const Key('query-result-now'),
                      children: [
                        Text(
                          l.queryResultNow,
                          style: TextStyle(
                            fontSize: 12,
                            color: Nocturne.muted(.55),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            text,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              fontFeatures: Nocturne.tabular,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              if (issues.form.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: FormErrorLines(
                    issues.formLines(context.l10n),
                    key: const Key('query-editor-error'),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(state == null ? l.commonClose : l.commonCancel),
        ),
        if (state != null)
          FilledButton(
            key: const Key('save-query'),
            onPressed: _blocker(l) != null || saving ? null : _save,
            child: Text(l.commonSave),
          ),
      ],
    );
  }

  Future<void> _save() async {
    final state = query;
    if (state == null) return;
    setState(() {
      saving = true;
      issues = FormIssues.none;
    });
    final existing = widget.existing;
    final definition = state.toDefinition(
      widget.schema,
      name.text.trim(),
      existing?.order ?? widget.order,
      id: existing?.id ?? '',
      queryVersion: existing?.queryVersion ?? 1,
      decimalSeparator: decimalSeparatorOf(context),
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

/// Opens [QueryEditorDialog] for an existing saved query, pre-filled when the builder can read it.
Future<bool?> showSavedQueryEditor(
  BuildContext context, {
  required CollectionsController controller,
  required CollectionSchemaDto schema,
  required QueryDefinitionDto definition,
  required Future<void> Function(QueryDefinitionDto) onSave,
  String? heading,
}) => showDialog<bool>(
  context: context,
  builder: (dialog) => QueryEditorDialog(
    schema: schema,
    heading: heading ?? context.l10n.queryEditTitle,
    initialName: definition.name,
    initialState: QueryBuilderState.fromDefinition(
      definition,
      schema,
      decimalSeparator: decimalSeparatorOf(context),
    ),
    existing: definition,
    referencingWidgets: widgetsUsingQuery(controller, definition.id),
    run: controller.runQuery,
    onSave: onSave,
  ),
);

/// Opens [QueryEditorDialog] for a new Count query. Nothing is created until Save.
Future<bool?> showNewQueryEditor(
  BuildContext context, {
  required CollectionsController controller,
  required CollectionSchemaDto schema,
}) => showDialog<bool>(
  context: context,
  builder: (dialog) => QueryEditorDialog(
    schema: schema,
    heading: context.l10n.queryNewTitle,
    initialName: '',
    initialState: const QueryBuilderState(),
    order: controller.queryDefinitions.length,
    run: controller.runQuery,
    onSave: (definition) async {
      await controller.createQueryDefinition(definition);
    },
  ),
);

/// Deletes [definition], asking first when widgets use it: they show an error until edited.
/// An unreferenced query is deleted directly.
Future<void> confirmDeleteQuery(
  BuildContext context,
  CollectionsController controller,
  QueryDefinitionDto definition,
) async {
  final used = widgetsUsingQuery(controller, definition.id);
  if (used > 0) {
    final l = context.l10n;
    final confirmed = await showConfirmDialog(
      context,
      title: l.queryDeleteConfirmTitle(definition.name),
      body: l.queryDeleteConfirmBody(used),
      destructive: l.queryDelete,
      safe: l.queryKeep,
      destructiveKey: const Key('confirm-delete-query'),
      safeKey: const Key('keep-query'),
    );
    if (!confirmed) return;
  }
  await controller.removeQueryDefinition(definition.id);
}
