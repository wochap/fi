import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:fi/src/rust/api/voice_models.dart' as rust;
import 'package:fi/src/rust/api/voice_models.dart'
    show ModelStatusDto, ModelStatusKindDto, ModelErrorDto;
import 'package:fi/ui_prefs.dart';
import 'package:fi/src/rust/api/voice.dart' as rust_voice;
import 'package:fi/voice/engine.dart';
import 'package:fi/voice/rust_engine.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:permission_handler/permission_handler.dart';

export 'package:fi/src/rust/api/voice_models.dart'
    show ModelStatusDto, ModelStatusKindDto, ModelErrorDto, ModelErrorKindDto;

/// The microphone permission as voice fill needs to know it.
enum MicPermission {
  granted,

  /// Not granted, and Android will still ask.
  notGranted,

  /// Denied for good: only the app's settings page can grant it.
  permanentlyDenied,
}

abstract interface class MicrophonePermission {
  Future<MicPermission> status();

  /// Shows the Android permission request.
  Future<MicPermission> request();

  /// Opens this app's Android settings page.
  Future<void> openSettings();
}

final class PlatformMicrophonePermission implements MicrophonePermission {
  const PlatformMicrophonePermission();

  static MicPermission _map(PermissionStatus status) => switch (status) {
    PermissionStatus.granted ||
    PermissionStatus.limited => MicPermission.granted,
    PermissionStatus.permanentlyDenied ||
    PermissionStatus.restricted => MicPermission.permanentlyDenied,
    _ => MicPermission.notGranted,
  };

  @override
  Future<MicPermission> status() async =>
      _map(await Permission.microphone.status);

  @override
  Future<MicPermission> request() async =>
      _map(await Permission.microphone.request());

  @override
  Future<void> openSettings() async => openAppSettings();
}

/// The network the phone is on, for the download offer.
enum NetworkKind { wifi, mobile, none, other }

abstract interface class NetworkInfo {
  Future<NetworkKind> current();
}

final class PlatformNetworkInfo implements NetworkInfo {
  const PlatformNetworkInfo();

  @override
  Future<NetworkKind> current() async {
    try {
      final results = await Connectivity().checkConnectivity();
      if (results.contains(ConnectivityResult.wifi) ||
          results.contains(ConnectivityResult.ethernet)) {
        return NetworkKind.wifi;
      }
      if (results.contains(ConnectivityResult.mobile)) {
        return NetworkKind.mobile;
      }
      if (results.contains(ConnectivityResult.none)) return NetworkKind.none;
      return NetworkKind.other;
    } catch (_) {
      return NetworkKind.other;
    }
  }
}

/// The phone's built-in text-to-speech.
abstract interface class SpeechOutput {
  /// Speaks [text]; completes when speech ends or is stopped.
  Future<void> speak(String text);
  Future<void> stop();
}

final class PlatformSpeechOutput implements SpeechOutput {
  PlatformSpeechOutput();

  final _tts = FlutterTts();
  var _ready = false;

  Future<void> _prepare() async {
    if (_ready) return;
    _ready = true;
    await _tts.setLanguage('en-US');
    await _tts.awaitSpeakCompletion(true);
  }

  @override
  Future<void> speak(String text) async {
    try {
      await _prepare();
      await _tts.speak(text);
    } catch (_) {
      // Spoken feedback is a courtesy; the panel shows the same line.
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _tts.stop();
    } catch (_) {}
  }
}

/// The on-device model set: status, download and deletion.
abstract class VoiceModels extends ChangeNotifier {
  ModelStatusDto get status;

  bool get ready => status.kind == ModelStatusKindDto.ready;

  /// Downloading or paused with bytes stored.
  bool get inProgress =>
      status.kind == ModelStatusKindDto.downloading ||
      status.kind == ModelStatusKindDto.paused;

  /// Starts or resumes; throws a [ModelErrorDto] when it can't start.
  Future<void> start();
  Future<void> pause();
  Future<void> cancel();

  /// Returns the bytes freed.
  Future<int> delete();
  Future<void> redownload();

  /// Free bytes where the models are stored, when known.
  Future<int?> freeStorageBytes();

  /// Set while a turn runs so delete and re-download refuse.
  void setVoiceTurnActive(bool active);
}

/// Models provisioned by Rust under `<data dir>/models`.
final class RustVoiceModels extends VoiceModels {
  RustVoiceModels(this.modelsDir) {
    _status = rust.modelStatus(modelsDir: modelsDir);
    _subscription = rust.modelStatusEvents(modelsDir: modelsDir).listen((
      status,
    ) {
      _status = status;
      notifyListeners();
    });
  }

  final String modelsDir;
  late ModelStatusDto _status;
  StreamSubscription<ModelStatusDto>? _subscription;

  @override
  ModelStatusDto get status => _status;

  @override
  Future<void> start() => rust.startModelDownload(modelsDir: modelsDir);

  @override
  Future<void> pause() => rust.pauseModelDownload(modelsDir: modelsDir);

  @override
  Future<void> cancel() => rust.cancelModelDownload(modelsDir: modelsDir);

  @override
  Future<int> delete() => rust.deleteModels(modelsDir: modelsDir);

  @override
  Future<void> redownload() => rust.redownloadModels(modelsDir: modelsDir);

  @override
  Future<int?> freeStorageBytes() async =>
      rust.modelFreeStorageBytes(modelsDir: modelsDir);

  @override
  void setVoiceTurnActive(bool active) =>
      rust.setVoiceTurnActive(modelsDir: modelsDir, active: active);

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }
}

/// Voice preferences kept in `ui_prefs.json`.
final class VoicePrefs extends ChangeNotifier {
  VoicePrefs(this.store) {
    unawaited(_load());
  }

  final UiPrefsStore store;
  var _prefs = const UiPrefs();

  var _changes = 0;

  Future<void> _load() async {
    final changes = _changes;
    final loaded = await store.load();
    if (changes != _changes) return;
    _prefs = loaded;
    notifyListeners();
  }

  bool get tipDismissed => _prefs.voiceTipDismissed;
  bool get handsFree => _prefs.handsFree;

  Future<void> _update(UiPrefs Function(UiPrefs prefs) change) async {
    _changes++;
    _prefs = change(_prefs);
    notifyListeners();
    await store.update(change);
  }

  Future<void> dismissTip() =>
      _update((prefs) => prefs.copyWith(voiceTipDismissed: true));

  Future<void> setHandsFree(bool on) =>
      _update((prefs) => prefs.copyWith(handsFree: on));
}

/// Everything voice fill needs, injected once per app.
final class VoiceServices {
  VoiceServices({
    required this.engine,
    required this.models,
    required this.permission,
    required this.network,
    required this.speech,
    required this.prefs,
  });

  /// The real plugins, Rust models under [dataDir], and the engine for this build.
  factory VoiceServices.platform({
    required String dataDir,
    required UiPrefsStore prefs,
  }) {
    final modelsDir = '$dataDir${Platform.pathSeparator}models';
    final engine = selectVoiceEngine(
      nativeAvailable: rust_voice.voiceNativeAvailable(),
      native: () => RustVoiceEngine(modelsDir: modelsDir),
    );
    VoiceEngineLifecycle(engine).attach();
    return VoiceServices(
      engine: engine,
      models: RustVoiceModels(modelsDir),
      permission: const PlatformMicrophonePermission(),
      network: const PlatformNetworkInfo(),
      speech: PlatformSpeechOutput(),
      prefs: VoicePrefs(prefs),
    );
  }

  final VoiceEngine engine;
  final VoiceModels models;
  final MicrophonePermission permission;
  final NetworkInfo network;
  final SpeechOutput speech;
  final VoicePrefs prefs;

  bool get available => engine.available;
}

/// Publishes [VoiceServices] and how to reach the Settings tab.
class VoiceScope extends InheritedWidget {
  const VoiceScope({
    required this.services,
    required super.child,
    this.openSettings,
    super.key,
  });

  final VoiceServices? services;

  /// Switches the shell to the Settings tab.
  final VoidCallback? openSettings;

  static VoiceScope? _of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<VoiceScope>();

  /// The enclosing scope itself, to carry into a new route.
  static VoiceScope? scopeOf(BuildContext context) => _of(context);

  /// The services when voice fill is available to this build, else null.
  static VoiceServices? of(BuildContext context) {
    final services = _of(context)?.services;
    return services != null && services.available ? services : null;
  }

  static VoidCallback? openSettingsOf(BuildContext context) =>
      _of(context)?.openSettings;

  @override
  bool updateShouldNotify(VoiceScope oldWidget) =>
      services != oldWidget.services || openSettings != oldWidget.openSettings;
}

/// Formats a byte count the way the voice UI shows sizes: "494 MB", "1.3 GB".
String formatBytes(int bytes) {
  const mb = 1000 * 1000;
  const gb = 1000 * mb;
  if (bytes >= gb) {
    return '${(bytes / gb).toStringAsFixed(1)} GB';
  }
  return '${(bytes / mb).round()} MB';
}

/// "3 min left", "45 s left".
String formatTimeLeft(int seconds) =>
    seconds >= 90 ? '${(seconds / 60).round()} min left' : '$seconds s left';

/// A status built from parts, for fakes and tests.
ModelStatusDto modelStatusOf(
  ModelStatusKindDto kind, {
  int done = 0,
  int total = 1300000000,
  int? remaining,
  int? secondsLeft,
  ModelErrorDto? error,
}) => ModelStatusDto(
  kind: kind,
  doneBytes: done,
  totalBytes: total,
  remainingBytes:
      remaining ?? (kind == ModelStatusKindDto.ready ? 0 : total - done),
  secondsLeft: secondsLeft,
  error: error,
);
