import 'package:fi/theme/inputs.dart';

/// A Dart copy of the core's duration grammar (`app_core::duration`) for widget tests, which run
/// without the native bridge.
final class TestDurationGrammar implements DurationGrammar {
  const TestDurationGrammar();

  static const _units = {
    'h': 3600000,
    'm': 60000,
    'min': 60000,
    's': 1000,
    'sec': 1000,
    'ms': 1,
  };

  @override
  int? parse(String text) {
    var rest = text.trim();
    var negative = false;
    if (rest.startsWith('-') || rest.startsWith('−')) {
      negative = true;
      rest = rest.substring(1);
    } else if (rest.startsWith('+')) {
      rest = rest.substring(1);
    }
    final part = RegExp(r'^\s*(\d+)\s*([a-zA-Z]+)');
    final seen = <int>{};
    var total = 0;
    var parts = 0;
    while (rest.trim().isNotEmpty) {
      final match = part.firstMatch(rest);
      if (match == null) return null;
      final size = _units[match.group(2)!.toLowerCase()];
      if (size == null || !seen.add(size)) return null;
      total += int.parse(match.group(1)!) * size;
      parts++;
      rest = rest.substring(match.end);
    }
    if (parts == 0) return null;
    return negative ? -total : total;
  }

  @override
  String format(int milliseconds) {
    if (milliseconds == 0) return '0s';
    var remaining = milliseconds.abs();
    final parts = <String>[];
    for (final (size, unit) in const [
      (3600000, 'h'),
      (60000, 'm'),
      (1000, 's'),
      (1, 'ms'),
    ]) {
      final count = remaining ~/ size;
      remaining %= size;
      if (count > 0) parts.add('$count$unit');
    }
    return '${milliseconds < 0 ? '-' : ''}${parts.join(' ')}';
  }
}
