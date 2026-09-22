import 'dart:async';

import 'package:fi/controllers.dart';
import 'package:fi/exact_format.dart';
import 'package:fi/help_button.dart';
import 'package:fi/help_copy.dart';
import 'package:fi/src/rust/api/models.dart';
import 'package:flutter/material.dart';

/// The deepest nesting of operator nodes the builder offers. Core has no limit; this only keeps
/// the card layout legible on a phone.
const int maxOperatorDepth = 6;

/// Field kinds a computed-field expression can start from.
const Set<FieldTypeKindDto> computedSourceKinds = {
  FieldTypeKindDto.integer,
  FieldTypeKindDto.fixedDecimal,
  FieldTypeKindDto.duration,
  FieldTypeKindDto.date,
  FieldTypeKindDto.dateTime,
};

/// The operators the builder exposes; `/` is the core `Divide` node, the rest are `Arithmetic`.
enum ExprOperator {
  add('+'),
  subtract('−'),
  multiply('×'),
  divide('÷');

  const ExprOperator(this.symbol);
  final String symbol;
}

/// One node of the in-memory expression tree. The tree maps one-to-one onto [ExpressionDto]
/// nodes, and a node's path (`$`, `$.left`, `$.expression`) is the same string core puts on a
/// validation error, which is how errors find their card.
sealed class ExprNode {
  const ExprNode();
}

/// A source-field reference. [fieldId] is null until the user picks one.
final class FieldLeaf extends ExprNode {
  const FieldLeaf([this.fieldId]);
  final String? fieldId;
}

/// A numeric constant held as the text the user typed, so it is only ever parsed exactly.
/// [scale] is null for an Integer constant and the decimal scale for a FixedDecimal one.
final class ConstantLeaf extends ExprNode {
  const ConstantLeaf({this.text = '', this.scale});
  final String text;
  final int? scale;
}

final class BinaryNode extends ExprNode {
  const BinaryNode({
    required this.operator,
    required this.left,
    required this.right,
    this.outputScale = 2,
    this.rounding = RoundingPolicyDto.halfEven,
  });
  final ExprOperator operator;
  final ExprNode left;
  final ExprNode right;

  /// Only meaningful for [ExprOperator.divide].
  final int outputScale;
  final RoundingPolicyDto rounding;

  BinaryNode copyWith({
    ExprOperator? operator,
    ExprNode? left,
    ExprNode? right,
    int? outputScale,
    RoundingPolicyDto? rounding,
  }) => BinaryNode(
    operator: operator ?? this.operator,
    left: left ?? this.left,
    right: right ?? this.right,
    outputScale: outputScale ?? this.outputScale,
    rounding: rounding ?? this.rounding,
  );
}

final class AbsNode extends ExprNode {
  const AbsNode(this.child);
  final ExprNode child;
}

/// Why a tree cannot be submitted yet, keyed by node path. Empty when the tree is complete.
Map<String, String> incompleteNodes(ExprNode node, [String path = r'$']) =>
    switch (node) {
      FieldLeaf(fieldId: null) => {path: 'Pick a field.'},
      FieldLeaf() => const {},
      ConstantLeaf(:final text, :final scale) =>
        _parseConstant(text, scale) == null
            ? {
                path: scale == null
                    ? 'Enter a whole number.'
                    : 'Enter a number with at most $scale decimals.',
              }
            : const {},
      BinaryNode(:final left, :final right) => {
        ...incompleteNodes(left, '$path.left'),
        ...incompleteNodes(right, '$path.right'),
      },
      AbsNode(:final child) => incompleteNodes(child, '$path.expression'),
    };

int? _parseConstant(String text, int? scale) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return null;
  return parseScaled(trimmed, scale ?? 0);
}

/// Encodes a complete tree as the flat, index-referenced wire shape (children before parents).
/// Returns null while any leaf is incomplete.
ExpressionDto? expressionToDto(ExprNode root) {
  if (incompleteNodes(root).isNotEmpty) return null;
  final nodes = <ExpressionNodeDto>[];
  int encode(ExprNode node) {
    switch (node) {
      case FieldLeaf(:final fieldId):
        nodes.add(
          ExpressionNodeDto(
            kind: ExpressionKindDto.field,
            field: FieldReferenceDto(
              kind: FieldReferenceKindDto.source,
              id: fieldId!,
            ),
          ),
        );
      case ConstantLeaf(:final text, :final scale):
        nodes.add(
          ExpressionNodeDto(
            kind: ExpressionKindDto.constant,
            value: TypedValueDto(
              valueType: scale == null
                  ? const ValueTypeDto(kind: ValueTypeKindDto.integer)
                  : ValueTypeDto(
                      kind: ValueTypeKindDto.fixedDecimal,
                      scale: scale,
                    ),
              integerValue: _parseConstant(text, scale),
            ),
          ),
        );
      case BinaryNode(
        :final operator,
        :final left,
        :final right,
        :final outputScale,
        :final rounding,
      ):
        final l = encode(left);
        final r = encode(right);
        nodes.add(
          operator == ExprOperator.divide
              ? ExpressionNodeDto(
                  kind: ExpressionKindDto.divide,
                  left: l,
                  right: r,
                  outputScale: outputScale,
                  rounding: rounding,
                )
              : ExpressionNodeDto(
                  kind: ExpressionKindDto.arithmetic,
                  arithmeticOperator: switch (operator) {
                    ExprOperator.add => ArithmeticOperatorDto.add,
                    ExprOperator.subtract => ArithmeticOperatorDto.subtract,
                    _ => ArithmeticOperatorDto.multiply,
                  },
                  left: l,
                  right: r,
                ),
        );
      case AbsNode(:final child):
        final inner = encode(child);
        nodes.add(
          ExpressionNodeDto(kind: ExpressionKindDto.abs, expression: inner),
        );
    }
    return nodes.length - 1;
  }

  final rootIndex = encode(root);
  return ExpressionDto(root: rootIndex, nodes: nodes);
}

/// Rebuilds the tree from a stored expression by walking from `root`. Returns null when the
/// expression uses anything the builder cannot show (comparisons, computed references, ...), so
/// the caller can present it read-only instead of silently rewriting it.
ExprNode? expressionFromDto(ExpressionDto dto) {
  final visiting = <int>{};
  ExprNode? decode(int? index) {
    if (index == null || index < 0 || index >= dto.nodes.length) return null;
    if (!visiting.add(index)) return null;
    final node = dto.nodes[index];
    try {
      switch (node.kind) {
        case ExpressionKindDto.field:
          final field = node.field;
          if (field == null || field.kind != FieldReferenceKindDto.source) {
            return null;
          }
          return FieldLeaf(field.id);
        case ExpressionKindDto.constant:
          final value = node.value;
          final representation = value?.integerValue;
          if (value == null || representation == null) return null;
          return switch (value.valueType.kind) {
            ValueTypeKindDto.integer => ConstantLeaf(
              text: representation.toString(),
            ),
            ValueTypeKindDto.fixedDecimal => ConstantLeaf(
              text: formatScaled(representation, value.valueType.scale ?? 0),
              scale: value.valueType.scale ?? 0,
            ),
            _ => null,
          };
        case ExpressionKindDto.arithmetic:
          final left = decode(node.left);
          final right = decode(node.right);
          final operator = switch (node.arithmeticOperator) {
            ArithmeticOperatorDto.add => ExprOperator.add,
            ArithmeticOperatorDto.subtract => ExprOperator.subtract,
            ArithmeticOperatorDto.multiply => ExprOperator.multiply,
            null => null,
          };
          if (left == null || right == null || operator == null) return null;
          return BinaryNode(operator: operator, left: left, right: right);
        case ExpressionKindDto.divide:
          final left = decode(node.left);
          final right = decode(node.right);
          if (left == null || right == null) return null;
          return BinaryNode(
            operator: ExprOperator.divide,
            left: left,
            right: right,
            outputScale: node.outputScale ?? 2,
            rounding: node.rounding ?? RoundingPolicyDto.halfEven,
          );
        case ExpressionKindDto.abs:
          final child = decode(node.expression);
          return child == null ? null : AbsNode(child);
        default:
          return null;
      }
    } finally {
      visiting.remove(index);
    }
  }

  return decode(dto.root);
}

/// Deepest chain of operator nodes in [node].
int operatorDepth(ExprNode node) => switch (node) {
  BinaryNode(:final left, :final right) =>
    1 +
        (operatorDepth(left) > operatorDepth(right)
            ? operatorDepth(left)
            : operatorDepth(right)),
  AbsNode(:final child) => operatorDepth(child),
  _ => 0,
};

ExprNode? nodeAt(ExprNode root, String path) {
  if (path == r'$') return root;
  var node = root;
  for (final step in path.substring(2).split('.')) {
    final next = switch ((node, step)) {
      (BinaryNode(:final left), 'left') => left,
      (BinaryNode(:final right), 'right') => right,
      (AbsNode(:final child), 'expression') => child,
      _ => null,
    };
    if (next == null) return null;
    node = next;
  }
  return node;
}

/// Returns a copy of [root] with the node at [path] replaced.
ExprNode replaceAt(ExprNode root, String path, ExprNode replacement) {
  if (path == r'$') return replacement;
  final steps = path.substring(2).split('.');
  ExprNode rebuild(ExprNode node, int i) {
    if (i == steps.length) return replacement;
    return switch ((node, steps[i])) {
      (final BinaryNode binary, 'left') => binary.copyWith(
        left: rebuild(binary.left, i + 1),
      ),
      (final BinaryNode binary, 'right') => binary.copyWith(
        right: rebuild(binary.right, i + 1),
      ),
      (AbsNode(:final child), 'expression') => AbsNode(rebuild(child, i + 1)),
      _ => node,
    };
  }

  return rebuild(root, 0);
}

String _parentPath(String path) => path.substring(0, path.lastIndexOf('.'));

/// A human label for an inferred type, e.g. `Decimal, scale 2`, in the words of `fieldKindLabel`.
String describeValueType(ValueTypeDto type) => switch (type.kind) {
  ValueTypeKindDto.integer => 'Integer',
  ValueTypeKindDto.fixedDecimal => 'Decimal, scale ${type.scale ?? 0}',
  ValueTypeKindDto.duration => 'Duration',
  ValueTypeKindDto.date => 'Date',
  ValueTypeKindDto.dateTime => 'Date & time',
  ValueTypeKindDto.boolean => 'Boolean',
  ValueTypeKindDto.text => 'Text',
  ValueTypeKindDto.enum_ => 'Choice',
  ValueTypeKindDto.null_ => 'Empty',
};

/// What the builder currently holds, reported on every change and every inference answer.
///
/// [inferred] is non-null only when Rust accepted exactly [expression]; callers enable saving on
/// that alone and never derive a type themselves.
final class ExpressionBuilderValue {
  const ExpressionBuilderValue({this.expression, this.inferred});
  final ExpressionDto? expression;
  final InferredTypeDto? inferred;
}

/// A tree of node cards for a computed-field expression, typed live by Rust inference.
final class ExpressionBuilder extends StatefulWidget {
  const ExpressionBuilder({
    required this.schema,
    required this.initial,
    required this.infer,
    required this.onChanged,
    this.debounce = const Duration(milliseconds: 150),
    super.key,
  });

  final CollectionSchemaDto schema;
  final ExprNode initial;
  final Future<InferredTypeDto> Function(ExpressionDto expression) infer;
  final ValueChanged<ExpressionBuilderValue> onChanged;
  final Duration debounce;

  @override
  State<ExpressionBuilder> createState() => _ExpressionBuilderState();
}

class _ExpressionBuilderState extends State<ExpressionBuilder> {
  late ExprNode root = widget.initial;
  int _revision = 0;
  Timer? _debounce;
  bool _pending = false;
  InferredTypeDto? _inferred;

  /// A positional error from Rust, shown on the card at [_errorPath].
  String? _errorPath;
  String? _errorMessage;

  /// An error with no node to sit on, shown on the result line.
  String? _resultError;

  /// Constant text controllers, keyed by node path so a card keeps its cursor across rebuilds.
  final Map<String, TextEditingController> _constantText = {};

  List<FieldDefinitionDto> get _fields => widget.schema.fields
      .where(
        (field) =>
            !field.deleted &&
            computedSourceKinds.contains(field.fieldType.kind),
      )
      .toList();

  FieldDefinitionDto? _field(String? id) =>
      _fields.where((field) => field.id == id).firstOrNull;

  @override
  void initState() {
    super.initState();
    // The parent is mid-build here, so the first report waits for the inference answer.
    _schedule(immediate: true, notify: false);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    for (final controller in _constantText.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _update(ExprNode next, {bool structural = false}) {
    if (structural) {
      // Paths shift when the shape changes; let each constant card seed a fresh controller.
      for (final controller in _constantText.values) {
        controller.dispose();
      }
      _constantText.clear();
    }
    setState(() {
      root = next;
      _schedule();
    });
  }

  /// Starts inference for the current tree. Callers hold `setState` (or are in `initState`).
  void _schedule({bool immediate = false, bool notify = true}) {
    final revision = ++_revision;
    _debounce?.cancel();
    final expression = expressionToDto(root);
    _inferred = null;
    _errorPath = null;
    _errorMessage = null;
    _resultError = null;
    _pending = expression != null;
    if (notify) {
      widget.onChanged(ExpressionBuilderValue(expression: expression));
    }
    if (expression == null) return;
    Future<void> run() async {
      InferredTypeDto? inferred;
      Object? failure;
      try {
        inferred = await widget.infer(expression);
      } catch (error) {
        failure = error;
      }
      // A newer tree superseded this one while Rust was answering.
      if (!mounted || revision != _revision) return;
      setState(() {
        _pending = false;
        _inferred = inferred;
        if (failure case BridgeError(
          field: final path?,
          :final message,
        ) when path.startsWith(r'$') && nodeAt(root, path) != null) {
          _errorPath = path;
          _errorMessage = message;
        } else if (failure != null) {
          _resultError = bridgeMessage(failure);
        }
      });
      widget.onChanged(
        ExpressionBuilderValue(expression: expression, inferred: inferred),
      );
    }

    if (immediate) {
      unawaited(run());
    } else {
      _debounce = Timer(widget.debounce, () => unawaited(run()));
    }
  }

  /// The type a leaf has on its own, used only to pick sensible defaults (constant kind, division
  /// scale). Anything above a leaf is Rust's to type.
  ({FieldTypeKindDto kind, int? scale})? _leafType(ExprNode node) =>
      switch (node) {
        FieldLeaf(:final fieldId) => switch (_field(fieldId)) {
          final field? => (
            kind: field.fieldType.kind,
            scale: field.fieldType.scale,
          ),
          null => null,
        },
        ConstantLeaf(:final scale) =>
          scale == null
              ? (kind: FieldTypeKindDto.integer, scale: null)
              : (kind: FieldTypeKindDto.fixedDecimal, scale: scale),
        _ => null,
      };

  /// A constant typed by its sibling operand (design D4).
  ConstantLeaf _constantFor(String path) {
    if (path != r'$') {
      final parent = nodeAt(root, _parentPath(path));
      if (parent is BinaryNode && parent.operator != ExprOperator.divide) {
        final sibling = path.endsWith('.left') ? parent.right : parent.left;
        final type = _leafType(sibling);
        if (type?.kind == FieldTypeKindDto.fixedDecimal) {
          return ConstantLeaf(scale: type!.scale ?? 0);
        }
      }
    }
    return const ConstantLeaf();
  }

  void _wrapInOperator(String path, ExprOperator operator) {
    final node = nodeAt(root, path)!;
    final leftType = _leafType(node);
    final binary = BinaryNode(
      operator: operator,
      left: node,
      right: const FieldLeaf(),
      // Design D3: keep the left operand's scale when it has one.
      outputScale: leftType?.kind == FieldTypeKindDto.fixedDecimal
          ? leftType!.scale ?? 2
          : 2,
    );
    _update(replaceAt(root, path, binary), structural: true);
  }

  bool _canWrapInOperator(String path) {
    final candidate = replaceAt(
      root,
      path,
      BinaryNode(
        operator: ExprOperator.add,
        left: nodeAt(root, path)!,
        right: const FieldLeaf(),
      ),
    );
    return operatorDepth(candidate) <= maxOperatorDepth;
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      _card(context, root, r'$', parentIsAbs: false),
      const SizedBox(height: 12),
      _resultLine(context),
    ],
  );

  Widget _resultLine(BuildContext context) {
    final theme = Theme.of(context);
    final (text, isError) = _resultText();
    return Row(
      children: [
        Expanded(
          child: Text(
            text,
            key: const Key('computed-result'),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: isError ? theme.colorScheme.error : null,
            ),
          ),
        ),
        const HelpButton(HelpId.computedFieldResult),
      ],
    );
  }

  (String, bool) _resultText() {
    if (incompleteNodes(root).isNotEmpty) {
      return ('Result: finish the marked parts', false);
    }
    if (_resultError case final error?) return (error, true);
    if (_errorMessage != null) {
      return ('Result: not valid, see the highlighted part', true);
    }
    if (_pending) return ('Result: checking…', false);
    if (_inferred case final inferred?) {
      return (
        'Result: ${describeValueType(inferred.valueType)}'
            '${inferred.nullable ? ' · may be empty' : ''}',
        false,
      );
    }
    return ('Result: unknown', false);
  }

  Widget _card(
    BuildContext context,
    ExprNode node,
    String path, {
    required bool parentIsAbs,
  }) {
    final theme = Theme.of(context);
    final localIssue = switch (node) {
      FieldLeaf() || ConstantLeaf() => incompleteNodes(node, path)[path],
      _ => null,
    };
    final error = path == _errorPath ? _errorMessage : null;
    final highlighted = error != null;
    final body = switch (node) {
      FieldLeaf() || ConstantLeaf() => _leaf(context, node, path),
      BinaryNode() => _binary(context, node, path),
      AbsNode() => _abs(context, node, path),
    };
    return Container(
      key: Key('expr-node-$path'),
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        border: Border.all(
          color: highlighted
              ? theme.colorScheme.error
              : theme.colorScheme.outlineVariant,
          width: highlighted ? 2 : 1,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: body),
              if (!parentIsAbs && node is! AbsNode)
                IconButton(
                  key: Key('abs-$path'),
                  tooltip: 'Absolute value',
                  icon: const Icon(Icons.unfold_more),
                  onPressed: () => _update(
                    replaceAt(root, path, AbsNode(node)),
                    structural: true,
                  ),
                ),
              if (_canWrapInOperator(path))
                PopupMenuButton<ExprOperator>(
                  key: Key('add-operator-$path'),
                  tooltip: 'Add operator',
                  icon: const Icon(Icons.add_circle_outline),
                  onSelected: (operator) => _wrapInOperator(path, operator),
                  itemBuilder: (_) => [
                    for (final operator in ExprOperator.values)
                      PopupMenuItem(
                        key: Key('operator-${operator.name}'),
                        value: operator,
                        child: Text(operator.symbol),
                      ),
                  ],
                ),
            ],
          ),
          if (error ?? localIssue case final message?)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                message,
                key: Key('expr-error-$path'),
                style: TextStyle(
                  color: highlighted
                      ? theme.colorScheme.error
                      : theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _leaf(BuildContext context, ExprNode node, String path) {
    final isConstant = node is ConstantLeaf;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        SegmentedButton<bool>(
          key: Key('leaf-kind-$path'),
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: false, label: Text('Field')),
            ButtonSegment(value: true, label: Text('Number')),
          ],
          selected: {isConstant},
          onSelectionChanged: (selection) => _update(
            replaceAt(
              root,
              path,
              selection.single ? _constantFor(path) : const FieldLeaf(),
            ),
            structural: true,
          ),
        ),
        if (node case FieldLeaf(:final fieldId))
          SizedBox(
            width: 220,
            child: DropdownButton<String>(
              key: Key('field-$path'),
              value: _field(fieldId)?.id,
              isExpanded: true,
              hint: const Text('Pick a field'),
              items: [
                for (final field in _fields)
                  DropdownMenuItem(value: field.id, child: Text(field.name)),
              ],
              onChanged: (id) => _update(replaceAt(root, path, FieldLeaf(id))),
            ),
          ),
        if (node case ConstantLeaf(:final text, :final scale)) ...[
          SizedBox(
            width: 140,
            child: TextField(
              key: Key('constant-$path'),
              controller: _constantText.putIfAbsent(
                path,
                () => TextEditingController(text: text),
              ),
              keyboardType: const TextInputType.numberWithOptions(
                signed: true,
                decimal: true,
              ),
              decoration: const InputDecoration(labelText: 'Number'),
              onChanged: (value) => _update(
                replaceAt(root, path, ConstantLeaf(text: value, scale: scale)),
              ),
            ),
          ),
          DropdownButton<int?>(
            key: Key('constant-scale-$path'),
            value: scale,
            items: [
              const DropdownMenuItem<int?>(value: null, child: Text('Whole')),
              for (var i = 0; i <= 18; i++)
                DropdownMenuItem<int?>(
                  value: i,
                  child: Text('Decimal, scale $i'),
                ),
            ],
            onChanged: (next) => _update(
              replaceAt(root, path, ConstantLeaf(text: text, scale: next)),
            ),
          ),
        ],
      ],
    );
  }

  Widget _binary(BuildContext context, BinaryNode node, String path) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      _card(context, node.left, '$path.left', parentIsAbs: false),
      Wrap(
        spacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          DropdownButton<ExprOperator>(
            key: Key('operator-$path'),
            value: node.operator,
            items: [
              for (final operator in ExprOperator.values)
                DropdownMenuItem(value: operator, child: Text(operator.symbol)),
            ],
            onChanged: (operator) {
              if (operator == null) return;
              _update(replaceAt(root, path, node.copyWith(operator: operator)));
            },
          ),
          if (node.operator == ExprOperator.divide)
            ..._divideControls(node, path),
          IconButton(
            key: Key('remove-$path'),
            tooltip: 'Remove operator (keep the left side)',
            icon: const Icon(Icons.close),
            onPressed: () =>
                _update(replaceAt(root, path, node.left), structural: true),
          ),
        ],
      ),
      _card(context, node.right, '$path.right', parentIsAbs: false),
    ],
  );

  List<Widget> _divideControls(BinaryNode node, String path) => [
    Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text('Scale'),
        IconButton(
          key: Key('scale-down-$path'),
          tooltip: 'Fewer decimals',
          icon: const Icon(Icons.remove),
          onPressed: node.outputScale <= 0
              ? null
              : () => _update(
                  replaceAt(
                    root,
                    path,
                    node.copyWith(outputScale: node.outputScale - 1),
                  ),
                ),
        ),
        Text('${node.outputScale}', key: Key('scale-$path')),
        IconButton(
          key: Key('scale-up-$path'),
          tooltip: 'More decimals',
          icon: const Icon(Icons.add),
          onPressed: node.outputScale >= 18
              ? null
              : () => _update(
                  replaceAt(
                    root,
                    path,
                    node.copyWith(outputScale: node.outputScale + 1),
                  ),
                ),
        ),
      ],
    ),
    DropdownButton<RoundingPolicyDto>(
      key: Key('rounding-$path'),
      value: node.rounding,
      items: const [
        DropdownMenuItem(
          value: RoundingPolicyDto.halfEven,
          child: Text('Round half to even'),
        ),
        DropdownMenuItem(
          value: RoundingPolicyDto.rejectInexact,
          child: Text('Reject inexact'),
        ),
      ],
      onChanged: (rounding) {
        if (rounding == null) return;
        _update(replaceAt(root, path, node.copyWith(rounding: rounding)));
      },
    ),
  ];

  Widget _abs(BuildContext context, AbsNode node, String path) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      Row(
        children: [
          const Expanded(child: Text('Absolute value of')),
          IconButton(
            key: Key('unabs-$path'),
            tooltip: 'Remove absolute value',
            icon: const Icon(Icons.close),
            onPressed: () =>
                _update(replaceAt(root, path, node.child), structural: true),
          ),
        ],
      ),
      _card(context, node.child, '$path.expression', parentIsAbs: true),
    ],
  );
}
