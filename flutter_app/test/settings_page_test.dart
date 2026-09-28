import 'package:fi/src/rust/api/models.dart';
import 'package:fi/ui_prefs.dart';
import 'package:fi/voice/engine.dart';
import 'package:fi/voice/fakes.dart';
import 'package:fi/voice/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_bridge.dart';
import 'widget_test.dart';

FakeCollectionBridge _ready() => FakeCollectionBridge()
  ..bootstrap = const BootstrapDto(kind: BootstrapKindDto.ready, rootId: 'root')
  ..buildIdentity = const BuildInfoDto(
    version: '0.1.21',
    gitHash: 'a1b2c3d',
    dirty: false,
  );

Future<void> _open(
  WidgetTester tester, {
  VoiceServices? voice,
  Size size = const Size(390, 844),
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(app(_ready(), voice: voice));
  await pumpUntilFound(tester, find.text('Collections'));
}

Future<void> _openSettings(WidgetTester tester, {VoiceServices? voice}) async {
  await _open(tester, voice: voice);
  await tester.tap(find.text('Settings'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the phone bottom bar is Collections · Devices · Settings', (
    tester,
  ) async {
    await _open(tester);
    final bar = tester.widget<NavigationBar>(find.byType(NavigationBar));
    expect(
      [
        for (final destination in bar.destinations)
          (destination as NavigationDestination).label,
      ],
      ['Collections', 'Devices', 'Settings'],
    );
  });

  testWidgets('desktop navigation has no Settings', (tester) async {
    await _open(tester, size: const Size(1240, 900));
    expect(find.byType(NavigationBar), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const Key('sidebar')),
        matching: find.text('Settings'),
      ),
      findsNothing,
    );
  });

  testWidgets('without voice services only About shows', (tester) async {
    await _openSettings(tester);
    expect(find.text('VOICE INPUT'), findsNothing);
    expect(find.byKey(const Key('settings-microphone')), findsNothing);
    await pumpUntilFound(tester, find.byKey(const Key('build-version')));
    expect(find.byKey(const Key('settings-about')), findsOneWidget);
  });

  testWidgets('without an engine Voice input is hidden', (tester) async {
    await _openSettings(
      tester,
      voice: fakeVoiceServices(engine: const UnavailableVoiceEngine()),
    );
    expect(find.byKey(const Key('settings-voice')), findsNothing);
    expect(find.byKey(const Key('settings-microphone')), findsOneWidget);
  });

  testWidgets('not downloaded offers the download and hides hands-free', (
    tester,
  ) async {
    final models = FakeVoiceModels(
      modelStatusOf(ModelStatusKindDto.notDownloaded),
    );
    await _openSettings(tester, voice: fakeVoiceServices(models: models));
    expect(find.text('Voice model'), findsOneWidget);
    expect(find.text('English · 1.3 GB'), findsOneWidget);
    expect(find.text('Not downloaded'), findsOneWidget);
    expect(find.text('Download 1.3 GB'), findsOneWidget);
    expect(find.text('Wi-Fi recommended'), findsOneWidget);
    expect(find.byKey(const Key('settings-hands-free')), findsNothing);
    expect(
      find.text(
        'Audio is processed on this device and never saved. English only for now.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('settings-model-download')));
    await tester.pump();
    expect(models.calls, ['start']);
    expect(find.byKey(const Key('settings-model-progress')), findsOneWidget);
  });

  testWidgets('downloading shows progress and pause', (tester) async {
    final models = FakeVoiceModels(
      modelStatusOf(ModelStatusKindDto.downloading, done: 494000000),
    );
    await _openSettings(tester, voice: fakeVoiceServices(models: models));
    expect(find.text('494 MB of 1.3 GB · 38%'), findsOneWidget);
    await tester.tap(find.byKey(const Key('settings-model-pause')));
    await tester.pump();
    expect(models.calls, ['pause']);
    expect(find.text('494 MB of 1.3 GB · 38% · Paused'), findsOneWidget);
  });

  testWidgets('ready shows the tag, hands-free, re-download and delete', (
    tester,
  ) async {
    final prefs = MemoryUiPrefsStore();
    final models = FakeVoiceModels(
      modelStatusOf(ModelStatusKindDto.ready, done: 1300000000),
    );
    await _openSettings(
      tester,
      voice: fakeVoiceServices(models: models, prefs: prefs),
    );
    expect(find.text('Ready'), findsOneWidget);
    expect(find.text('English · 1.3 GB'), findsOneWidget);
    expect(find.text('Hands-free spoken feedback'), findsOneWidget);
    expect(
      find.text('Speaks the “still need” question and a short confirmation'),
      findsOneWidget,
    );
    expect(find.text('Re-download model'), findsOneWidget);
    expect(find.text('frees 1.3 GB'), findsOneWidget);

    await tester.tap(find.byKey(const Key('settings-hands-free')));
    await tester.pump();
    expect(prefs.prefs.handsFree, isTrue);

    await tester.tap(find.byKey(const Key('settings-redownload')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(models.calls, isEmpty);

    await tester.tap(find.byKey(const Key('settings-delete-model')));
    await tester.pumpAndSettle();
    expect(find.text('Delete voice model?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('confirm-delete-model')));
    await tester.pumpAndSettle();
    expect(models.calls, ['delete']);
    expect(find.text('Not downloaded'), findsOneWidget);
    expect(find.text('Download 1.3 GB'), findsOneWidget);
    expect(find.byKey(const Key('settings-hands-free')), findsNothing);
  });

  testWidgets('re-download asks first, then starts over', (tester) async {
    final models = FakeVoiceModels(
      modelStatusOf(ModelStatusKindDto.ready, done: 1300000000),
    );
    await _openSettings(tester, voice: fakeVoiceServices(models: models));
    await tester.tap(find.byKey(const Key('settings-redownload')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-redownload')));
    await tester.pumpAndSettle();
    expect(models.calls, ['redownload']);
    expect(find.byKey(const Key('settings-model-progress')), findsOneWidget);
  });

  testWidgets('Microphone shows the permission and links to Android settings', (
    tester,
  ) async {
    final permission = FakeMicrophonePermission(
      MicPermission.permanentlyDenied,
    );
    await _openSettings(
      tester,
      voice: fakeVoiceServices(permission: permission),
    );
    expect(find.text('Microphone access'), findsOneWidget);
    expect(find.text('Off'), findsOneWidget);
    await tester.tap(find.byKey(const Key('settings-android-settings')));
    await tester.pump();
    expect(permission.settingsOpened, 1);
  });
}
