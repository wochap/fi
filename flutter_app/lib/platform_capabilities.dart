import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// What the running platform can do; decides which Settings sections appear.
final class PlatformCapabilities {
  const PlatformCapabilities({
    required this.android,
    required this.onDeviceVoice,
  });

  static const androidPhone = PlatformCapabilities(
    android: true,
    onDeviceVoice: true,
  );
  static const desktop = PlatformCapabilities(
    android: false,
    onDeviceVoice: false,
  );

  factory PlatformCapabilities.current() =>
      defaultTargetPlatform == TargetPlatform.android ? androidPhone : desktop;

  /// Android wording, the Android settings page and the microphone permission.
  final bool android;

  /// The platform can run voice fill at all.
  final bool onDeviceVoice;

  @override
  bool operator ==(Object other) =>
      other is PlatformCapabilities &&
      other.android == android &&
      other.onDeviceVoice == onDeviceVoice;

  @override
  int get hashCode => Object.hash(android, onDeviceVoice);
}

/// Provides [PlatformCapabilities] to every route.
class PlatformScope extends InheritedWidget {
  const PlatformScope({
    required this.capabilities,
    required super.child,
    super.key,
  });

  final PlatformCapabilities capabilities;

  /// The scoped capabilities, or [PlatformCapabilities.current] with no scope above.
  static PlatformCapabilities of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<PlatformScope>()
          ?.capabilities ??
      PlatformCapabilities.current();

  @override
  bool updateShouldNotify(PlatformScope oldWidget) =>
      capabilities != oldWidget.capabilities;
}
