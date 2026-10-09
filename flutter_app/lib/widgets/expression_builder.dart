import 'dart:async';

import 'package:fi/l10n/error_text.dart';
import 'package:fi/l10n/l10n.dart';
import 'package:fi/theme/fi_icons.dart';
import 'package:fi/exact_format.dart';
import 'package:fi/help_button.dart';
import 'package:fi/help_copy.dart';
import 'package:fi/src/rust/api/models.dart';
import 'package:fi/theme/inputs.dart';
import 'package:fi/theme/nocturne.dart';
import 'package:fi/theme/nocturne_widgets.dart';
import 'package:fi/widgets/query_builder.dart';
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

/// The leaves that keep a tree from being submitted yet, keyed by node path. Empty when the tree
/// is complete. [incompleteText] words each one.
Map<String, ExprNode> incompleteNodes(ExprNode node, [String path = r'$']) =>
    switch (node) {
      FieldLeaf(fieldId: null) => {path: node},
      FieldLeaf() => const {},
      ConstantLeaf(:final text, :final scale) =>
        _parseConstant(text, scale) == null ? {path: node} : const {},
      BinaryNode(:final left, :final right) => {
        ...incompleteNodes(left, '$path.left'),
        ...incompleteNodes(right, '$path.right'),
      },
      AbsNode(:final child) => incompleteNodes(child, '$path.expression'),
    };

/// Why [leaf] (an entry of [incompleteNodes]) is incomplete.
String incompleteText(AppLocalizations l, ExprNode leaf) => switch (leaf) {
  ConstantLeaf(scale: null) => l.exprWholeNumberIssue,
  ConstantLeaf(:final scale?) => l.exprDecimalsIssue(scale),
  _ => l.exprPickFieldIssue,
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

/// The expression as one line of text with field names, numbers and operator symbols, e.g.
/// `End at − Start at`. Nested operations are parenthesized except a left-hand chain of the same
/// precedence (`a − b + c`); an unknown field reads `?`.
String formulaText(ExprNode node, CollectionSchemaDto schema) {
  bool additive(ExprOperator operator) =>
      operator == ExprOperator.add || operator == ExprOperator.subtract;
  bool chains(ExprOperator parent, ExprNode left) =>
      left is BinaryNode &&
      (additive(parent) && additive(left.operator) ||
          parent == ExprOperator.multiply &&
              left.operator == ExprOperator.multiply);
  String text(ExprNode node, {required bool nested}) => switch (node) {
    FieldLeaf(:final fieldId) =>
      schema.fields.where((field) => field.id == fieldId).firstOrNull?.name ??
          '?',
    ConstantLeaf(text: final value) =>
      value.trim().isEmpty ? '?' : value.trim(),
    BinaryNode(:final operator, :final left, :final right) => () {
      final inner =
          '${text(left, nested: !chains(operator, left))} ${operator.symbol} '
          '${text(right, nested: true)}';
      return nested ? '($inner)' : inner;
    }(),
    AbsNode(:final child) => 'abs(${text(child, nested: false)})',
  };
  return text(node, nested: false);
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

/// The top-level `+ − ×` chain of an expression: [terms] joined left to right by [operators]
/// (one fewer). The tree is left-deep, so `a − b + c` is `(a − b) + c`. Anything else (a
/// division, an absolute value, a right-nested operation) is one term.
final class TermChain {
  const TermChain(this.terms, this.operators);
  final List<ExprNode> terms;
  final List<ExprOperator> operators;
}

TermChain flattenChain(ExprNode root) {
  final terms = <ExprNode>[];
  final operators = <ExprOperator>[];
  var node = root;
  while (node is BinaryNode && node.operator != ExprOperator.divide) {
    terms.add(node.right);
    operators.add(node.operator);
    node = node.left;
  }
  terms.add(node);
  return TermChain(terms.reversed.toList(), operators.reversed.toList());
}

/// The left-deep tree of [terms] joined by [operators]; the inverse of [flattenChain].
ExprNode buildChain(List<ExprNode> terms, List<ExprOperator> operators) {
  var node = terms.first;
  for (var i = 1; i < terms.length; i++) {
    node = BinaryNode(operator: operators[i - 1], left: node, right: terms[i]);
  }
  return node;
}

/// The node path of term [index] in a chain of [count] terms.
String termPath(int index, int count) => index == 0
    ? r'$' + '.left' * (count - 1)
    : '${_chainNodePath(index, count)}.right';

/// The path of the operator node that joins term [index] (1 or more) to the terms before it.
String _chainNodePath(int index, int count) =>
    r'$' + '.left' * (count - 1 - index);

/// Moves term [from] to position [to]; the operators keep their slots.
ExprNode reorderTerms(ExprNode root, int from, int to) {
  final chain = flattenChain(root);
  final terms = [...chain.terms];
  terms.insert(to, terms.removeAt(from));
  return buildChain(terms, chain.operators);
}

/// A human label for an inferred type, e.g. `Decimal, scale 2`, in the words of `fieldKindLabel`.
String describeValueType(AppLocalizations l, ValueTypeDto type) =>
    switch (type.kind) {
      ValueTypeKindDto.integer => l.exprTypeInteger,
      ValueTypeKindDto.fixedDecimal => l.exprTypeDecimal(type.scale ?? 0),
      ValueTypeKindDto.duration => l.exprTypeDuration,
      ValueTypeKindDto.date => l.exprTypeDate,
      ValueTypeKindDto.dateTime => l.exprTypeDateTime,
      ValueTypeKindDto.boolean => l.exprTypeBoolean,
      ValueTypeKindDto.text => l.exprTypeText,
      ValueTypeKindDto.enum_ => l.exprTypeChoice,
      ValueTypeKindDto.enumSet => l.fieldTypeChoices,
      ValueTypeKindDto.null_ => l.exprTypeEmpty,
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

enum _TermKind { field, number, function }

/// Term cards for a computed-field expression, typed live by Rust inference.
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

  /// Every active field: inference, not the picker, decides what combines.
  List<FieldDefinitionDto> get _fields =>
      widget.schema.fields.where((field) => !field.deleted).toList();

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
          issues: [BridgeIssueDto(fields: [final path], :final message)],
        ) when path.startsWith(r'$') && nodeAt(root, path) != null) {
          _errorPath = path;
          _errorMessage = message;
        } else if (failure != null) {
          _resultError = bridgeMessage(context.l10n, failure);
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
  Widget build(BuildContext context) {
    final chain = flattenChain(root);
    final count = chain.terms.length;
    final canAdd =
        operatorDepth(
          buildChain(
            [...chain.terms, const FieldLeaf()],
            [...chain.operators, ExprOperator.add],
          ),
        ) <=
        maxOperatorDepth;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _formulaStrip(),
        const SizedBox(height: 12),
        ReorderableListView(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          buildDefaultDragHandles: false,
          onReorder: (from, to) {
            if (to > from) to--;
            if (from == to) return;
            _update(reorderTerms(root, from, to), structural: true);
          },
          children: [
            for (var i = 0; i < count; i++)
              Padding(
                key: ValueKey('term-$i'),
                padding: const EdgeInsets.only(bottom: 8),
                child: _term(context, chain, i),
              ),
          ],
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const Key('add-term'),
            onPressed: canAdd
                ? () => _update(
                    buildChain(
                      [...chain.terms, const FieldLeaf()],
                      [...chain.operators, ExprOperator.add],
                    ),
                    structural: true,
                  )
                : null,
            icon: const Icon(FiIcons.add, size: 16),
            label: Text(context.l10n.exprAddTerm),
          ),
        ),
        const SizedBox(height: 8),
        // A positional error sits on its term; the result line steps aside until it is fixed.
        if (_errorPath == null) _resultLine(context),
      ],
    );
  }

  /// The term that carries the positional error: the right-hand term of a failing chain
  /// operator, or the term whose subtree holds the failing node.
  int? _errorTerm(int count) {
    final path = _errorPath;
    if (path == null) return null;
    for (var i = 1; i < count; i++) {
      if (path == _chainNodePath(i, count)) return i;
    }
    for (var i = 0; i < count; i++) {
      final term = termPath(i, count);
      if (path == term || path.startsWith('$term.')) return i;
    }
    return null;
  }

  /// The error message for term [index] when it is the error's own place (not a node nested
  /// inside it, whose card shows the message): a localized sentence when both operand types are
  /// known here, Rust's message otherwise.
  String? _termErrorText(AppLocalizations l, TermChain chain, int index) {
    final count = chain.terms.length;
    final path = _errorPath;
    final message = _errorMessage;
    if (path == null || message == null) return null;
    final (ExprOperator, ExprNode, ExprNode)? operation;
    if (index > 0 && path == _chainNodePath(index, count)) {
      // Only a two-term prefix has a left operand whose type is known without Rust.
      final left = buildChain(
        chain.terms.sublist(0, index),
        chain.operators.sublist(0, index - 1),
      );
      operation = (chain.operators[index - 1], left, chain.terms[index]);
    } else if (path == termPath(index, count)) {
      operation = switch (chain.terms[index]) {
        BinaryNode(:final operator, :final left, :final right) => (
          operator,
          left,
          right,
        ),
        _ => null,
      };
    } else {
      return null;
    }
    if (operation case (final operator, final left, final right)) {
      final leftType = _valueTypeOf(left);
      final rightType = _valueTypeOf(right);
      if (leftType != null && rightType != null) {
        final a = describeValueType(l, leftType);
        final b = describeValueType(l, rightType);
        return switch (operator) {
          ExprOperator.add => l.exprCannotAdd(b, a),
          ExprOperator.subtract => l.exprCannotSubtract(b, a),
          ExprOperator.multiply => l.exprCannotMultiply(a, b),
          ExprOperator.divide => l.exprCannotDivide(a, b),
        };
      }
    }
    return message;
  }

  /// The value type of a leaf from the schema; null for anything Rust has to type.
  ValueTypeDto? _valueTypeOf(ExprNode node) => switch (_leafType(node)) {
    (:final kind, :final scale) => ValueTypeDto(
      kind: valueKindFor(kind),
      scale: scale,
    ),
    null => null,
  };

  /// One term card: its operator (none on the first), a drag handle, the Field / Number /
  /// Function choice and ✕, then the inputs of that choice (mock computed-field-editor).
  Widget _term(BuildContext context, TermChain chain, int index) {
    final l = context.l10n;
    final count = chain.terms.length;
    final path = termPath(index, count);
    final node = chain.terms[index];
    final errorTerm = _errorTerm(count);
    final errorText = errorTerm == index
        ? _termErrorText(l, chain, index)
        : null;
    final kind = switch (node) {
      FieldLeaf() => _TermKind.field,
      ConstantLeaf() => _TermKind.number,
      AbsNode() => _TermKind.function,
      BinaryNode(operator: ExprOperator.divide) => _TermKind.function,
      BinaryNode() => null,
    };
    void replace(ExprNode next) {
      final terms = [...chain.terms]..[index] = next;
      _update(buildChain(terms, chain.operators), structural: true);
    }

    final card = Container(
      key: Key('expr-term-$index'),
      padding: const EdgeInsets.fromLTRB(8, 6, 4, 10),
      decoration: errorTerm == index
          ? null
          : BoxDecoration(
              borderRadius: BorderRadius.circular(Nocturne.radius),
              border: Border.all(color: context.nocturne.muted(.12)),
            ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        spacing: 8,
        children: [
          Row(
            children: [
              ReorderableDragStartListener(
                index: index,
                child: Tooltip(
                  message: l.exprDragTerm,
                  child: SizedBox(
                    key: Key('term-handle-$index'),
                    width: Nocturne.isPhone(context)
                        ? Nocturne.touchTarget
                        : 28,
                    height: Nocturne.isPhone(context)
                        ? Nocturne.touchTarget
                        : 36,
                    child: Icon(
                      FiIcons.dragHandle,
                      size: 18,
                      color: context.nocturne.muted(.5),
                    ),
                  ),
                ),
              ),
              if (index > 0) ...[
                SizedBox(
                  width: 72,
                  child: FiSelect<ExprOperator>.compact(
                    key: Key('term-operator-$index'),
                    value: chain.operators[index - 1],
                    items: [
                      for (final operator in const [
                        ExprOperator.add,
                        ExprOperator.subtract,
                        ExprOperator.multiply,
                      ])
                        DropdownMenuItem(
                          value: operator,
                          child: Text(operator.symbol),
                        ),
                    ],
                    onChanged: (operator) {
                      if (operator == null) return;
                      final operators = [...chain.operators]
                        ..[index - 1] = operator;
                      _update(buildChain(chain.terms, operators));
                    },
                  ),
                ),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: kind == null
                    // A nested operation keeps its own cards below.
                    ? Text(
                        formulaText(node, widget.schema),
                        style: TextStyle(
                          fontFamily: Nocturne.monoFamily,
                          fontSize: 13,
                          color: context.nocturne.muted(.7),
                        ),
                      )
                    : Align(
                        alignment: Alignment.centerLeft,
                        child: SegmentedButton<_TermKind>(
                          key: Key('term-kind-$index'),
                          showSelectedIcon: false,
                          segments: [
                            ButtonSegment(
                              value: _TermKind.field,
                              label: Text(l.exprField),
                            ),
                            ButtonSegment(
                              value: _TermKind.number,
                              label: Text(l.exprNumber),
                            ),
                            ButtonSegment(
                              value: _TermKind.function,
                              label: Text(l.exprFunction),
                            ),
                          ],
                          selected: {kind},
                          onSelectionChanged: (selection) =>
                              replace(switch (selection.single) {
                                _TermKind.field => const FieldLeaf(),
                                _TermKind.number => _constantFor(path),
                                _TermKind.function => AbsNode(node),
                              }),
                        ),
                      ),
              ),
              FiIconButton(
                key: Key('remove-term-$index'),
                icon: FiIcons.close,
                tooltip: l.exprRemoveTerm,
                onPressed: count < 2
                    ? null
                    : () {
                        final terms = [...chain.terms]..removeAt(index);
                        final operators = [...chain.operators]
                          ..removeAt(index == 0 ? 0 : index - 1);
                        _update(buildChain(terms, operators), structural: true);
                      },
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: 8),
            child: switch (node) {
              FieldLeaf() || ConstantLeaf() => Align(
                alignment: Alignment.centerLeft,
                child: _leafInputs(context, node, path),
              ),
              AbsNode() || BinaryNode(operator: ExprOperator.divide) =>
                _function(context, node, path, index, replace),
              _ => _card(context, node, path, parentIsAbs: false),
            },
          ),
          if (switch (node) {
                FieldLeaf() ||
                ConstantLeaf() => incompleteNodes(node, path)[path],
                _ => null,
              }
              case final leaf? when errorText == null)
            Text(
              incompleteText(l, leaf),
              key: Key('expr-error-$path'),
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          if (errorText != null)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(FiIcons.warning, size: 16, color: context.nocturne.danger),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    errorText,
                    key: Key('expr-error-term-$index'),
                    style: TextStyle(
                      fontSize: 12,
                      color: context.nocturne.text,
                    ),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
    return errorTerm == index
        ? DashedOutline(color: context.nocturne.danger, child: card)
        : card;
  }

  /// A Function term: Absolute value of its inner term, or a division with its output scale and
  /// rounding. Switching between the two keeps the inner (left-hand) term.
  Widget _function(
    BuildContext context,
    ExprNode node,
    String path,
    int index,
    void Function(ExprNode) replace,
  ) {
    final l = context.l10n;
    final isAbs = node is AbsNode;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      spacing: 6,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: SizedBox(
            width: 200,
            child: FiSelect<bool>.compact(
              key: Key('term-function-$index'),
              value: isAbs,
              items: [
                DropdownMenuItem(value: true, child: Text(l.exprAbsoluteValue)),
                DropdownMenuItem(value: false, child: Text(l.exprDivide)),
              ],
              onChanged: (abs) {
                if (abs == null || abs == isAbs) return;
                if (node case AbsNode(:final child)) {
                  final leftType = _leafType(child);
                  replace(
                    BinaryNode(
                      operator: ExprOperator.divide,
                      left: child,
                      right: const FieldLeaf(),
                      // Design D3: keep the left operand's scale when it has one.
                      outputScale:
                          leftType?.kind == FieldTypeKindDto.fixedDecimal
                          ? leftType!.scale ?? 2
                          : 2,
                    ),
                  );
                } else if (node case BinaryNode(:final left)) {
                  replace(AbsNode(left));
                }
              },
            ),
          ),
        ),
        switch (node) {
          AbsNode(:final child) => _card(
            context,
            child,
            '$path.expression',
            parentIsAbs: true,
          ),
          final BinaryNode divide => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              _card(context, divide.left, '$path.left', parentIsAbs: false),
              Text(
                ExprOperator.divide.symbol,
                style: const TextStyle(fontSize: 16),
              ),
              _card(context, divide.right, '$path.right', parentIsAbs: false),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: _divideControls(context, divide, path),
              ),
            ],
          ),
          _ => const SizedBox.shrink(),
        },
      ],
    );
  }

  /// The whole expression as one line of formula, so the tree of cards below reads as an edit of
  /// something visible (mock computed-field-editor). Unfinished leaves show as dashed slots.
  Widget _formulaStrip() {
    final paren = TextStyle(color: context.nocturne.accentText);
    Widget symbol(String text, [TextStyle? style]) => Text(text, style: style);
    Widget slot(String text) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 1),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Nocturne.radiusSm),
        border: Border.all(color: context.nocturne.accent),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontFamily: Nocturne.fontFamily,
          fontSize: 12,
          color: context.nocturne.accentText,
        ),
      ),
    );
    List<Widget> pieces(ExprNode node, {required bool nested}) =>
        switch (node) {
          FieldLeaf(:final fieldId) => [
            switch (_field(fieldId)) {
              final field? => Tag(field.name),
              null => slot(context.l10n.exprSlotField),
            },
          ],
          ConstantLeaf(:final text) =>
            text.trim().isEmpty
                ? [slot(context.l10n.exprSlotNumber)]
                : [symbol(text.trim())],
          BinaryNode(:final operator, :final left, :final right) => [
            if (nested) symbol('(', paren),
            ...pieces(left, nested: true),
            symbol(operator.symbol),
            ...pieces(right, nested: true),
            if (nested) symbol(')', paren),
          ],
          AbsNode(:final child) => [
            symbol('abs(', paren),
            ...pieces(child, nested: false),
            symbol(')', paren),
          ],
        };
    return Container(
      key: const Key('computed-formula'),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: context.nocturne.bg,
        borderRadius: BorderRadius.circular(Nocturne.radius),
      ),
      child: DefaultTextStyle.merge(
        style: TextStyle(
          fontFamily: Nocturne.monoFamily,
          fontSize: 14,
          color: context.nocturne.text,
        ),
        child: Wrap(
          spacing: 6,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: pieces(root, nested: false),
        ),
      ),
    );
  }

  Widget _resultLine(BuildContext context) {
    final theme = Theme.of(context);
    final (text, isError) = _resultText(context.l10n);
    final missing = incompleteNodes(root).length;
    return Row(
      children: [
        if (missing > 0) ...[
          Icon(FiIcons.error, size: 16, color: context.nocturne.warning),
          const SizedBox(width: 6),
        ] else if (_inferred != null && !isError) ...[
          Icon(
            FiIcons.check,
            key: const Key('computed-result-ok'),
            size: 16,
            color: context.nocturne.success,
          ),
          const SizedBox(width: 6),
        ],
        Expanded(
          child: Text(
            text,
            key: const Key('computed-result'),
            style: theme.textTheme.bodyMedium?.copyWith(
              fontSize: missing > 0 ? 12 : 13,
              color: isError
                  ? theme.colorScheme.error
                  : missing > 0
                  ? context.nocturne.text
                  : context.nocturne.muted(.7),
            ),
          ),
        ),
        const HelpButton(HelpId.computedFieldResult),
      ],
    );
  }

  (String, bool) _resultText(AppLocalizations l) {
    final missing = incompleteNodes(root).length;
    if (missing > 0) return (l.exprTermsMissing(missing), false);
    if (_resultError case final error?) return (error, true);
    if (_errorMessage != null) {
      return (l.exprResultInvalid, true);
    }
    if (_pending) return (l.exprResultChecking, false);
    if (_inferred case final inferred?) {
      return (
        inferred.nullable
            ? l.exprResultTypeMaybeEmpty(
                describeValueType(l, inferred.valueType),
              )
            : l.exprResultType(describeValueType(l, inferred.valueType)),
        false,
      );
    }
    return (l.exprResultUnknown, false);
  }

  Widget _card(
    BuildContext context,
    ExprNode node,
    String path, {
    required bool parentIsAbs,
  }) {
    final theme = Theme.of(context);
    final localIssue = switch (node) {
      FieldLeaf() || ConstantLeaf() => switch (incompleteNodes(
        node,
        path,
      )[path]) {
        final leaf? => incompleteText(context.l10n, leaf),
        null => null,
      },
      _ => null,
    };
    final error = path == _errorPath ? _errorMessage : null;
    final highlighted = error != null;
    final body = switch (node) {
      FieldLeaf() || ConstantLeaf() => _leaf(context, node, path),
      BinaryNode() => _binary(context, node, path),
      AbsNode() => _abs(context, node, path),
    };
    // A term hangs off a single accent line rather than sitting in a box, so nesting reads as
    // indentation (mock computed-field-editor); an error thickens the line in the error color.
    return Container(
      key: Key('expr-node-$path'),
      margin: const EdgeInsets.symmetric(vertical: 3),
      padding: const EdgeInsets.fromLTRB(12, 4, 0, 4),
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(
            color: highlighted
                ? theme.colorScheme.error
                : context.nocturne.accentEdge,
            width: highlighted ? 2 : 1,
          ),
        ),
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
                  tooltip: context.l10n.exprAbsoluteValue,
                  icon: const Icon(FiIcons.unfold),
                  onPressed: () => _update(
                    replaceAt(root, path, AbsNode(node)),
                    structural: true,
                  ),
                ),
              if (_canWrapInOperator(path))
                PopupMenuButton<ExprOperator>(
                  key: Key('add-operator-$path'),
                  tooltip: context.l10n.exprAddOperator,
                  icon: const Icon(FiIcons.addCircle),
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

  /// A leaf inside a Function or nested operation: Field / Number, then its inputs.
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
          segments: [
            ButtonSegment(value: false, label: Text(context.l10n.exprField)),
            ButtonSegment(value: true, label: Text(context.l10n.exprNumber)),
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
        _leafInputs(context, node, path),
      ],
    );
  }

  /// The field select, or the number and its scale.
  Widget _leafInputs(BuildContext context, ExprNode node, String path) => Wrap(
    spacing: 8,
    runSpacing: 8,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      if (node case FieldLeaf(:final fieldId))
        SizedBox(
          width: 220,
          child: FiSelect<String>.compact(
            key: Key('field-$path'),
            value: _field(fieldId)?.id,
            hint: context.l10n.exprPickField,
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
          child: FiTextInput.compact(
            key: Key('constant-$path'),
            controller: _constantText.putIfAbsent(
              path,
              () => TextEditingController(text: text),
            ),
            keyboardType: const TextInputType.numberWithOptions(
              signed: true,
              decimal: true,
            ),
            label: context.l10n.exprNumber,
            onChanged: (value) => _update(
              replaceAt(root, path, ConstantLeaf(text: value, scale: scale)),
            ),
          ),
        ),
        SizedBox(
          width: 190,
          child: FiSelect<int?>.compact(
            key: Key('constant-scale-$path'),
            value: scale,
            items: [
              DropdownMenuItem<int?>(
                value: null,
                child: Text(context.l10n.exprWhole),
              ),
              for (var i = 0; i <= 18; i++)
                DropdownMenuItem<int?>(
                  value: i,
                  child: Text(context.l10n.exprTypeDecimal(i)),
                ),
            ],
            onChanged: (next) => _update(
              replaceAt(root, path, ConstantLeaf(text: text, scale: next)),
            ),
          ),
        ),
      ],
    ],
  );

  Widget _binary(BuildContext context, BinaryNode node, String path) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      _card(context, node.left, '$path.left', parentIsAbs: false),
      Wrap(
        spacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SizedBox(
            width: 72,
            child: FiSelect<ExprOperator>.compact(
              key: Key('operator-$path'),
              value: node.operator,
              items: [
                for (final operator in ExprOperator.values)
                  DropdownMenuItem(
                    value: operator,
                    child: Text(operator.symbol),
                  ),
              ],
              onChanged: (operator) {
                if (operator == null) return;
                _update(
                  replaceAt(root, path, node.copyWith(operator: operator)),
                );
              },
            ),
          ),
          if (node.operator == ExprOperator.divide)
            ..._divideControls(context, node, path),
          IconButton(
            key: Key('remove-$path'),
            tooltip: context.l10n.exprRemoveOperator,
            icon: const Icon(FiIcons.close),
            onPressed: () =>
                _update(replaceAt(root, path, node.left), structural: true),
          ),
        ],
      ),
      _card(context, node.right, '$path.right', parentIsAbs: false),
    ],
  );

  List<Widget> _divideControls(
    BuildContext context,
    BinaryNode node,
    String path,
  ) => [
    Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(context.l10n.exprScale),
        IconButton(
          key: Key('scale-down-$path'),
          tooltip: context.l10n.exprFewerDecimals,
          icon: const Icon(FiIcons.remove),
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
          tooltip: context.l10n.exprMoreDecimals,
          icon: const Icon(FiIcons.add),
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
    SegmentedButton<RoundingPolicyDto>(
      key: Key('rounding-$path'),
      showSelectedIcon: false,
      segments: [
        ButtonSegment(
          value: RoundingPolicyDto.halfEven,
          label: Text(context.l10n.queryRoundingHalfEven),
        ),
        ButtonSegment(
          value: RoundingPolicyDto.rejectInexact,
          label: Text(context.l10n.queryRoundingRejectInexact),
        ),
      ],
      selected: {node.rounding},
      onSelectionChanged: (selection) => _update(
        replaceAt(root, path, node.copyWith(rounding: selection.single)),
      ),
    ),
  ];

  Widget _abs(BuildContext context, AbsNode node, String path) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: context.nocturne.accent),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(FiIcons.formula, size: 12, color: context.nocturne.accent),
                const SizedBox(width: 4),
                Text(
                  context.l10n.exprAbsoluteValue,
                  style: TextStyle(
                    fontSize: 11,
                    color: context.nocturne.accent,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              context.l10n.exprOf,
              style: TextStyle(
                fontSize: 13,
                color: context.nocturne.muted(.55),
              ),
            ),
          ),
          IconButton(
            key: Key('unabs-$path'),
            tooltip: context.l10n.exprRemoveAbsolute,
            icon: const Icon(FiIcons.close),
            onPressed: () =>
                _update(replaceAt(root, path, node.child), structural: true),
          ),
        ],
      ),
      _card(context, node.child, '$path.expression', parentIsAbs: true),
    ],
  );
}
