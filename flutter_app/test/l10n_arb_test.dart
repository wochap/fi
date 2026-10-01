import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

final _placeholder = RegExp(r'\{(\w+)[,}]');

Set<String> _placeholders(Object? message) =>
    _placeholder.allMatches('$message').map((m) => m.group(1)!).toSet();

/// Problems between an English template and its Spanish translation.
List<String> arbProblems(Map en, Map es) {
  bool message(Object? k) => k is String && !k.startsWith('@');
  final enKeys = en.keys.where(message).cast<String>().toSet();
  final esKeys = es.keys.where(message).cast<String>().toSet();
  final problems = <String>[];
  final missing = enKeys.difference(esKeys).toList()..sort();
  final extra = esKeys.difference(enKeys).toList()..sort();
  if (missing.isNotEmpty) problems.add('missing in app_es.arb: $missing');
  if (extra.isNotEmpty) problems.add('missing in app_en.arb: $extra');
  for (final key in enKeys.intersection(esKeys)) {
    if ('${es[key]}'.trim().isEmpty) problems.add('empty Spanish value: $key');
    final a = _placeholders(en[key]);
    final b = _placeholders(es[key]);
    if (a.length != b.length || !a.containsAll(b)) {
      problems.add('placeholders differ for $key: $a vs $b');
    }
  }
  return problems;
}

Map _read(String path) => jsonDecode(File(path).readAsStringSync()) as Map;

void main() {
  test('app_es.arb matches app_en.arb', () {
    final en = _read('lib/l10n/app_en.arb');
    final es = _read('lib/l10n/app_es.arb');
    expect(en['@@locale'], 'en');
    expect(es['@@locale'], 'es');
    expect(arbProblems(en, es), isEmpty);
  });

  test('arbProblems reports missing keys and placeholder mismatches', () {
    expect(arbProblems({'a': 'x'}, {}).join(), contains('a'));
    expect(
      arbProblems({'b': 'Size {size}'}, {'b': 'Tamaño {tamano}'}).join(),
      contains('b'),
    );
  });
}
