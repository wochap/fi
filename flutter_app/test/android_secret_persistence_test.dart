import 'package:fi/bridge/android_secret_persistence.dart';
import 'package:fi/src/rust/api/models.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('fi/platform');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final persistence = AndroidSecretPersistence(channel);
  final secret = Uint8List.fromList(List.filled(32, 7));
  late List<MethodCall> calls;

  void handle(Future<Object?> Function(MethodCall call) handler) {
    messenger.setMockMethodCallHandler(channel, (call) {
      calls.add(call);
      return handler(call);
    });
  }

  setUp(() {
    calls = [];
    handle((_) async => null);
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('each write shape invokes the matching platform method', () async {
    expect(
      await persistence.persist(
        PlatformSecretWriteDto(
          slot: PlatformSecretSlotDto.current,
          secret: secret,
        ),
      ),
      isTrue,
    );
    expect(
      await persistence.persist(
        const PlatformSecretWriteDto(slot: PlatformSecretSlotDto.current),
      ),
      isTrue,
    );
    expect(
      await persistence.persist(
        PlatformSecretWriteDto(
          slot: PlatformSecretSlotDto.previous,
          epoch: 3,
          secret: secret,
        ),
      ),
      isTrue,
    );
    expect(
      await persistence.persist(
        const PlatformSecretWriteDto(slot: PlatformSecretSlotDto.previous),
      ),
      isTrue,
    );

    expect(calls.map((call) => call.method), [
      'secureStoreDiscoverySecret',
      'secureRemoveDiscoverySecret',
      'secureStorePreviousDiscoverySecret',
      'secureRemovePreviousDiscoverySecret',
    ]);
    expect(calls[0].arguments, secret);
    expect(calls[1].arguments, isNull);
    expect(calls[2].arguments, {'epoch': 3, 'secret': secret});
    expect(calls[3].arguments, isNull);
  });

  test('a platform failure is reported as false', () async {
    handle((_) async => throw PlatformException(code: 'android_capability'));
    expect(
      await persistence.persist(
        PlatformSecretWriteDto(
          slot: PlatformSecretSlotDto.current,
          secret: secret,
        ),
      ),
      isFalse,
    );
  });

  test('loadPrevious parses the stored epoch and secret', () async {
    handle((_) async => {'epoch': 4, 'secret': secret});
    final previous = await persistence.loadPrevious();
    expect(calls.single.method, 'secureLoadPreviousDiscoverySecret');
    expect(previous?.epoch, 4);
    expect(previous?.secret, secret);
  });

  test('loadPrevious returns null when absent or unreadable', () async {
    expect(await persistence.loadPrevious(), isNull);
    handle((_) async => throw PlatformException(code: 'android_capability'));
    expect(await persistence.loadPrevious(), isNull);
  });
}
