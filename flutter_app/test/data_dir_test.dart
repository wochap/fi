import 'package:fi/main.dart' show dataDirOverride, dataDirOverrideVariable;
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('data directory override', () {
    test('distinct overrides keep two instances on separate datasets', () {
      expect(
        dataDirOverride({
          dataDirOverrideVariable: '/tmp/fi-a',
        }, releaseMode: false),
        '/tmp/fi-a',
      );
      expect(
        dataDirOverride({
          dataDirOverrideVariable: '/tmp/fi-b',
        }, releaseMode: false),
        '/tmp/fi-b',
      );
    });

    test('absent override falls back to the platform directory', () {
      // A null result is what makes resolveDataDir use
      // getApplicationSupportDirectory(), exactly as before.
      expect(dataDirOverride(const {}, releaseMode: false), isNull);
      expect(
        dataDirOverride({dataDirOverrideVariable: '   '}, releaseMode: false),
        isNull,
      );
    });

    test('release build ignores the override', () {
      expect(
        dataDirOverride({
          dataDirOverrideVariable: '/tmp/fi-a',
        }, releaseMode: true),
        isNull,
      );
    });
  });
}
