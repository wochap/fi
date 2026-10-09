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

  test(
    'colors come from the theme: no ramp step or color literal outside it',
    () {
      final offenders = <String>[];
      final files = Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('.dart'))
          .where((file) => !file.path.startsWith('lib/src/'))
          .where((file) => file.path != 'lib/theme/nocturne.dart');
      final step = RegExp(r'\b(accent|neutral)[1-9]00\b');
      final literal = RegExp(r'\bColor\(0x');
      final named = RegExp(r'\bColors\.(?!transparent\b)\w+');
      for (final file in files) {
        final lines = file.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          final line = lines[i];
          if (step.hasMatch(line) ||
              literal.hasMatch(line) ||
              named.hasMatch(line)) {
            offenders.add('${file.path}:${i + 1}: ${line.trim()}');
          }
        }
      }
      expect(
        offenders,
        isEmpty,
        reason: 'Use roles and tokens from context.nocturne (DESIGN.md)',
      );
    },
  );
}
