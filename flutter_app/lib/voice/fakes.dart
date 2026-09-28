import 'dart:async';

import 'package:fi/ui_prefs.dart';
import 'package:fi/voice/engine.dart';
import 'package:fi/voice/services.dart';

/// Models whose status tests set directly.
final class FakeVoiceModels extends VoiceModels {
  FakeVoiceModels([ModelStatusDto? status])
    : _status = status ?? modelStatusOf(ModelStatusKindDto.ready);

  ModelStatusDto _status;
  int? freeBytes = 24000000000;

  /// Thrown by [start] when set.
  ModelErrorDto? startError;
  var turnActive = false;
  final calls = <String>[];

  @override
  ModelStatusDto get status => _status;

  set status(ModelStatusDto value) {
    _status = value;
    notifyListeners();
  }

  @override
  Future<void> start() async {
    calls.add('start');
    if (startError case final error?) throw error;
    status = modelStatusOf(
      ModelStatusKindDto.downloading,
      done: _status.doneBytes,
      total: _status.totalBytes,
    );
  }

  @override
  Future<void> pause() async {
    calls.add('pause');
    status = modelStatusOf(
      ModelStatusKindDto.paused,
      done: _status.doneBytes,
      total: _status.totalBytes,
    );
  }

  @override
  Future<void> cancel() async {
    calls.add('cancel');
    status = modelStatusOf(
      ModelStatusKindDto.notDownloaded,
      total: _status.totalBytes,
    );
  }

  @override
  Future<int> delete() async {
    calls.add('delete');
    final freed = _status.doneBytes;
    status = modelStatusOf(
      ModelStatusKindDto.notDownloaded,
      total: _status.totalBytes,
    );
    return freed;
  }

  @override
  Future<void> redownload() async {
    calls.add('redownload');
    status = modelStatusOf(
      ModelStatusKindDto.downloading,
      total: _status.totalBytes,
    );
  }

  @override
  Future<int?> freeStorageBytes() async => freeBytes;

  @override
  void setVoiceTurnActive(bool active) => turnActive = active;
}

final class FakeMicrophonePermission implements MicrophonePermission {
  FakeMicrophonePermission([this.state = MicPermission.granted]);

  MicPermission state;

  /// What the Android request answers.
  MicPermission onRequest = MicPermission.granted;
  var requests = 0;
  var settingsOpened = 0;

  @override
  Future<MicPermission> status() async => state;

  @override
  Future<MicPermission> request() async {
    requests++;
    return state = onRequest;
  }

  @override
  Future<void> openSettings() async => settingsOpened++;
}

final class FakeNetworkInfo implements NetworkInfo {
  FakeNetworkInfo([this.kind = NetworkKind.wifi]);

  NetworkKind kind;

  @override
  Future<NetworkKind> current() async => kind;
}

/// Records what was spoken; speech ends when [finish] is called or at once with [instant].
final class FakeSpeechOutput implements SpeechOutput {
  FakeSpeechOutput({this.instant = false});

  final bool instant;
  final spoken = <String>[];
  var stops = 0;
  Completer<void>? _speaking;

  @override
  Future<void> speak(String text) {
    spoken.add(text);
    if (instant) return Future.value();
    return (_speaking = Completer<void>()).future;
  }

  void finish() {
    final speaking = _speaking;
    if (speaking != null && !speaking.isCompleted) speaking.complete();
  }

  @override
  Future<void> stop() async {
    stops++;
    finish();
  }
}

/// Services built from fakes, for tests and previews.
VoiceServices fakeVoiceServices({
  VoiceEngine? engine,
  FakeVoiceModels? models,
  FakeMicrophonePermission? permission,
  FakeNetworkInfo? network,
  FakeSpeechOutput? speech,
  UiPrefsStore? prefs,
}) => VoiceServices(
  engine: engine ?? FakeVoiceEngine(),
  models: models ?? FakeVoiceModels(),
  permission: permission ?? FakeMicrophonePermission(),
  network: network ?? FakeNetworkInfo(),
  speech: speech ?? FakeSpeechOutput(instant: true),
  prefs: VoicePrefs(prefs ?? MemoryUiPrefsStore()),
);
