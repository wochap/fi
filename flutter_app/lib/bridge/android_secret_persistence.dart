import 'package:fi/src/rust/api/models.dart';
import 'package:flutter/services.dart';

/// Android secure storage for the discovery-group secrets the Rust key store
/// writes through. Every failure is reported as `false`/`null`, never thrown,
/// so the Rust side sees a refused write instead of a Dart exception.
final class AndroidSecretPersistence {
  AndroidSecretPersistence([
    this._channel = const MethodChannel('fi/platform'),
  ]);

  final MethodChannel _channel;

  Future<bool> persist(PlatformSecretWriteDto write) async {
    try {
      final secret = write.secret;
      switch (write.slot) {
        case PlatformSecretSlotDto.current:
          if (secret == null) {
            await _channel.invokeMethod<void>('secureRemoveDiscoverySecret');
          } else {
            await _channel.invokeMethod<void>(
              'secureStoreDiscoverySecret',
              secret,
            );
          }
        case PlatformSecretSlotDto.previous:
          if (secret == null) {
            await _channel.invokeMethod<void>(
              'secureRemovePreviousDiscoverySecret',
            );
          } else {
            await _channel.invokeMethod<void>(
              'secureStorePreviousDiscoverySecret',
              {'epoch': write.epoch, 'secret': secret},
            );
          }
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// The retained previous-epoch secret, or null when absent or unreadable
  /// (a failed decrypt only costs rotation retention).
  Future<PreviousDiscoverySecretDto?> loadPrevious() async {
    try {
      final stored = await _channel.invokeMapMethod<String, Object?>(
        'secureLoadPreviousDiscoverySecret',
      );
      final epoch = stored?['epoch'];
      final secret = stored?['secret'];
      if (epoch is! int || secret is! Uint8List) return null;
      return PreviousDiscoverySecretDto(epoch: epoch, secret: secret);
    } catch (_) {
      return null;
    }
  }
}
