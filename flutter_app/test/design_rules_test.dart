import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('app code draws no Material icons', () {
    final offenders = <String>[];
    final files = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'))
        .where((file) => !file.path.startsWith('lib/src/'));
    final material = RegExp(r'\bIcons\.');
    for (final file in files) {
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (material.hasMatch(lines[i])) offenders.add('${file.path}:${i + 1}');
      }
    }
    expect(offenders, isEmpty, reason: 'Use FiIcons (lib/theme/fi_icons.dart)');
  });
}
