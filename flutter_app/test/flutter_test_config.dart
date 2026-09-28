import 'dart:async';

import 'package:fi/theme/inputs.dart';

import 'duration_grammar.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  FiDurationInput.grammar = const TestDurationGrammar();
  await testMain();
}
