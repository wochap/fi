import 'package:fi/status_time.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime(2026, 9, 24, 13, 0);
  String ago(Duration delta) =>
      formatStatusTime(now.subtract(delta).millisecondsSinceEpoch, now: now);

  test('absent value reads never', () {
    expect(formatStatusTime(null, now: now), 'never');
  });

  test('under one minute reads just now', () {
    expect(ago(Duration.zero), 'just now');
    expect(ago(const Duration(seconds: 59)), 'just now');
    expect(ago(const Duration(seconds: 60)), '1 min ago');
  });

  test('future values from clock skew read just now', () {
    expect(ago(const Duration(seconds: -1)), 'just now');
    expect(ago(const Duration(hours: -3)), 'just now');
  });

  test('under one hour reads whole minutes', () {
    expect(ago(const Duration(minutes: 5, seconds: 59)), '5 min ago');
    expect(ago(const Duration(minutes: 30)), '30 min ago');
    expect(ago(const Duration(minutes: 59, seconds: 59)), '59 min ago');
    expect(ago(const Duration(minutes: 60)), '1 h ago');
  });

  test('under twenty-four hours reads whole hours', () {
    expect(ago(const Duration(hours: 3)), '3 h ago');
    expect(ago(const Duration(hours: 23, minutes: 59)), '23 h ago');
  });

  test('twenty-four hours or older reads a short local date', () {
    expect(ago(const Duration(hours: 24)), 'Wed 23 Sep 13:00');
    expect(
      formatStatusTime(
        DateTime(2026, 9, 22, 13, 0).millisecondsSinceEpoch,
        now: now,
      ),
      'Tue 22 Sep 13:00',
    );
  });

  test('a previous year includes the year', () {
    expect(
      formatStatusTime(
        DateTime(2025, 12, 31, 23, 5).millisecondsSinceEpoch,
        now: DateTime(2026, 1, 2, 9, 0),
      ),
      'Wed 31 Dec 2025 23:05',
    );
  });
}
