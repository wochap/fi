import 'package:fi/platform_capabilities.dart';
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
  PlatformCapabilities capabilities = PlatformCapabilities.androidPhone,
  FakeCollectionBridge? bridge,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    app(bridge ?? _ready(), voice: voice, capabilities: capabilities),
  );
  await pumpUntilFound(tester, find.text('Collections'));
}

/// [settle] false for states with endless animations (indeterminate bars).
Future<void> _openSettings(
  WidgetTester tester, {
  VoiceServices? voice,
  bool settle = true,
  PlatformCapabilities capabilities = PlatformCapabilities.androidPhone,
  Size size = const Size(390, 844),
  FakeCollectionBridge? bridge,
}) async {
  await _open(
    tester,
    voice: voice,
    capabilities: capabilities,
    size: size,
    bridge: bridge,
  );
  await tester.tap(
    size.width >= 720
        ? find.byKey(const Key('nav-settings'))
        : find.text('Settings'),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump(const Duration(seconds: 1));
  }
}

ModelStatusDto _downloading() => modelStatusOf(
  ModelStatusKindDto.downloading,
  done: 612000000,
  secondsLeft: 240,
);

Finder _tag(String text) => find.descendant(
  of: find.byKey(const Key('settings-model-tag')),
  matching: find.text(text),
);

void _expectRow(String name, List<String> texts) {
  for (final text in texts) {
    expect(
      find.descendant(
        of: find.byKey(Key('settings-model-row-$name')),
        matching: find.text(text),
      ),
      findsOneWidget,
      reason: '$name row shows "$text"',
    );
  }
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

  testWidgets('the sidebar lists Collections · Devices · Settings', (
    tester,
  ) async {
    await _open(tester, size: const Size(1240, 900));
    expect(find.byType(NavigationBar), findsNothing);
    final sidebar = find.byKey(const Key('sidebar'));
    final tops = [
      for (final label in ['Collections', 'Devices', 'Settings'])
        tester
            .getTopLeft(
              find.descendant(of: sidebar, matching: find.text(label)),
            )
            .dy,
    ];
    expect(tops[0], lessThan(tops[1]));
    expect(tops[1], lessThan(tops[2]));
    await tester.tap(find.byKey(const Key('nav-settings')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settings-page')), findsOneWidget);
  });

  testWidgets('Settings survives widening', (tester) async {
    await _open(tester, size: const Size(500, 800));
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    tester.view.physicalSize = const Size(1000, 800);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sidebar')), findsOneWidget);
    expect(find.byKey(const Key('settings-page')), findsOneWidget);
  });

  testWidgets('Settings survives narrowing', (tester) async {
    await _open(tester, size: const Size(1000, 800));
    await tester.tap(find.byKey(const Key('nav-settings')));
    await tester.pumpAndSettle();
    tester.view.physicalSize = const Size(500, 800);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settings-page')), findsOneWidget);
    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
      2,
    );
  });

  for (final (name, size) in [
    ('desktop shows only About', const Size(1240, 900)),
    ('desktop capabilities at phone width', const Size(390, 844)),
  ]) {
    testWidgets(name, (tester) async {
      await _openSettings(
        tester,
        voice: fakeVoiceServices(),
        capabilities: PlatformCapabilities.desktop,
        size: size,
      );
      expect(find.byKey(const Key('settings-about')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('settings-subtitle')),
          matching: find.text('Preferences for this computer.'),
          matchRoot: true,
        ),
        findsOneWidget,
      );
      expect(find.byKey(const Key('settings-voice')), findsNothing);
      expect(find.byKey(const Key('settings-microphone')), findsNothing);
      expect(find.byKey(const Key('settings-android-settings')), findsNothing);
      expect(find.textContaining('Android'), findsNothing);
    });
  }

  testWidgets(
    'Android with voice shows Voice input, Microphone, About in order',
    (tester) async {
      // Tall enough that the lazy list builds every section.
      await _openSettings(
        tester,
        voice: fakeVoiceServices(),
        size: const Size(390, 2400),
      );
      final tops = [
        for (final label in ['VOICE INPUT', 'MICROPHONE', 'ABOUT'])
          tester.getTopLeft(find.text(label)).dy,
      ];
      expect(tops[0], lessThan(tops[1]));
      expect(tops[1], lessThan(tops[2]));
      expect(find.byKey(const Key('settings-subtitle')), findsNothing);
    },
  );

  testWidgets('permission is re-read on resume', (tester) async {
    final permission = FakeMicrophonePermission(
      MicPermission.permanentlyDenied,
    );
    await _openSettings(
      tester,
      voice: fakeVoiceServices(permission: permission),
    );
    expect(find.text('Off'), findsOneWidget);
    permission.state = MicPermission.granted;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('Allowed'), findsOneWidget);
  });

  testWidgets('About shows Version and Network', (tester) async {
    await _openSettings(
      tester,
      capabilities: PlatformCapabilities.desktop,
      size: const Size(1240, 900),
    );
    final about = find.byKey(const Key('settings-about'));
    await pumpUntilFound(tester, find.byKey(const Key('build-version')));
    for (final text in [
      'Version',
      'fi 0.1.21 · a1b2c3d',
      'Network',
      'Local network only · UDP 47380–47389 · mDNS 5353',
    ]) {
      expect(
        find.descendant(of: about, matching: find.text(text)),
        findsOneWidget,
        reason: text,
      );
    }
  });

  testWidgets('About without build identity', (tester) async {
    await _openSettings(
      tester,
      capabilities: PlatformCapabilities.desktop,
      size: const Size(1240, 900),
      bridge: _ready()..buildInfoError = StateError('x'),
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byKey(const Key('settings-network')), findsOneWidget);
    expect(find.byKey(const Key('build-version')), findsNothing);
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
    expect(find.byKey(const Key('settings-microphone')), findsNothing);
    expect(find.byKey(const Key('settings-about')), findsOneWidget);
  });

  testWidgets('not downloaded offers the download and hides hands-free', (
    tester,
  ) async {
    final models = FakeVoiceModels(
      modelStatusOf(ModelStatusKindDto.notDownloaded),
    );
    await _openSettings(tester, voice: fakeVoiceServices(models: models));
    expect(find.text('Voice models'), findsOneWidget);
    expect(find.text('English · 1.43 GB total'), findsOneWidget);
    expect(find.text('Not downloaded'), findsOneWidget);
    _expectRow('ggml-base.en.bin', [
      'Speech recognition',
      'Whisper Base (English)',
      '148 MB',
    ]);
    _expectRow('qwen2.5-1.5b-instruct-q5_k_m.gguf', [
      'Understanding',
      'Qwen2.5 1.5B Instruct',
      '1.29 GB',
    ]);
    expect(find.text('Download 1.43 GB'), findsOneWidget);
    expect(find.text('Wi-Fi recommended'), findsOneWidget);
    expect(
      find.text('Needs 1.43 GB · 24 GB free on this phone'),
      findsOneWidget,
    );
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

  testWidgets('downloading shows progress, pause and cancel', (tester) async {
    final models = FakeVoiceModels(_downloading());
    await _openSettings(tester, voice: fakeVoiceServices(models: models));
    expect(find.text('English · 612 MB of 1.43 GB'), findsOneWidget);
    expect(_tag('Downloading'), findsOneWidget);
    expect(find.text('42%'), findsOneWidget);
    expect(find.text('about 4 min left'), findsOneWidget);
    _expectRow('qwen2.5-1.5b-instruct-q5_k_m.gguf', ['464 MB of 1.29 GB']);
    _expectRow('ggml-base.en.bin', ['148 MB']);
    expect(find.byKey(const Key('settings-model-cancel')), findsOneWidget);
    await tester.tap(find.byKey(const Key('settings-model-pause')));
    await tester.pump();
    expect(models.calls, ['pause']);
    expect(_tag('Paused'), findsOneWidget);
    expect(find.text('English · paused at 612 MB of 1.43 GB'), findsOneWidget);
    expect(find.text('resumes from here'), findsOneWidget);
    expect(find.byKey(const Key('settings-model-resume')), findsOneWidget);
  });

  testWidgets('cancel asks first; Keep downloading changes nothing', (
    tester,
  ) async {
    final models = FakeVoiceModels(_downloading());
    await _openSettings(tester, voice: fakeVoiceServices(models: models));
    await tester.tap(find.byKey(const Key('settings-model-cancel')));
    await tester.pumpAndSettle();
    expect(find.text('Cancel download?'), findsOneWidget);
    expect(
      find.text('Downloaded data (612 MB) will be deleted.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Keep downloading'));
    await tester.pumpAndSettle();
    expect(models.calls, isEmpty);
    expect(_tag('Downloading'), findsOneWidget);

    await tester.tap(find.byKey(const Key('settings-model-cancel')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-cancel-download')));
    await tester.pumpAndSettle();
    expect(models.calls, ['cancel']);
    expect(find.text('Not downloaded'), findsOneWidget);
    expect(find.text('Download 1.43 GB'), findsOneWidget);
  });

  testWidgets('reconnecting explains and keeps pause and cancel', (
    tester,
  ) async {
    final models = FakeVoiceModels(
      modelStatusOf(ModelStatusKindDto.reconnecting, done: 612000000),
    );
    await _openSettings(tester, voice: fakeVoiceServices(models: models));
    expect(_tag('Reconnecting'), findsOneWidget);
    expect(find.text('Connection lost — reconnecting…'), findsOneWidget);
    expect(find.text('The download resumes where it stopped.'), findsOneWidget);
    expect(find.byKey(const Key('settings-model-pause')), findsOneWidget);
    expect(find.byKey(const Key('settings-model-cancel')), findsOneWidget);
  });

  testWidgets('verifying shows the check and the checking row', (tester) async {
    final models = FakeVoiceModels(
      modelStatusOf(
        ModelStatusKindDto.verifying,
        done: 612000000,
        checked: 100000000,
        checking: 464035789,
      ),
    );
    await _openSettings(
      tester,
      voice: fakeVoiceServices(models: models),
      settle: false,
    );
    expect(_tag('Verifying'), findsOneWidget);
    expect(find.text('English · 1.43 GB'), findsOneWidget);
    expect(find.text('Checking downloaded data…'), findsOneWidget);
    _expectRow('qwen2.5-1.5b-instruct-q5_k_m.gguf', ['Checking']);
    expect(find.byKey(const Key('settings-model-pause')), findsNothing);
    expect(find.byKey(const Key('settings-model-cancel')), findsOneWidget);
  });

  testWidgets('a network failure offers Retry and Cancel and delete', (
    tester,
  ) async {
    final models = FakeVoiceModels(
      modelStatusOf(
        ModelStatusKindDto.failed,
        done: 612000000,
        error: const ModelErrorDto(
          kind: ModelErrorKindDto.network,
          message: 'network error',
        ),
      ),
    );
    await _openSettings(tester, voice: fakeVoiceServices(models: models));
    expect(_tag('Failed'), findsOneWidget);
    expect(find.text('No connection'), findsOneWidget);
    expect(find.text('English · stopped at 612 MB'), findsOneWidget);
    expect(
      find.byKey(const Key('settings-model-cancel-delete')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('settings-model-retry')));
    await tester.pump();
    expect(models.calls, ['start']);
  });

  testWidgets('a storage failure names the space needed', (tester) async {
    final models = FakeVoiceModels(
      modelStatusOf(
        ModelStatusKindDto.failed,
        done: 612000000,
        error: const ModelErrorDto(
          kind: ModelErrorKindDto.notEnoughStorage,
          message: 'not enough storage',
          neededBytes: 1021000000,
        ),
      ),
    );
    await _openSettings(tester, voice: fakeVoiceServices(models: models));
    expect(find.text('Not enough storage'), findsOneWidget);
    expect(
      find.text('Free up 1.02 GB on this phone, then retry.'),
      findsOneWidget,
    );
  });

  testWidgets('a damaged file names its model', (tester) async {
    const qwen = 'qwen2.5-1.5b-instruct-q5_k_m.gguf';
    final models = FakeVoiceModels(
      modelStatusOf(
        ModelStatusKindDto.failed,
        done: 147964211,
        damagedFile: qwen,
        error: const ModelErrorDto(
          kind: ModelErrorKindDto.checksum,
          message: 'checksum',
          file: qwen,
        ),
      ),
    );
    await _openSettings(tester, voice: fakeVoiceServices(models: models));
    expect(find.text('Downloaded file is damaged'), findsOneWidget);
    expect(
      find.text(
        'The understanding model failed its check. Retry downloads it again (1.29 GB).',
      ),
      findsOneWidget,
    );
    expect(find.text('English · check failed'), findsOneWidget);
    _expectRow(qwen, ['1.29 GB · damaged']);
  });

  testWidgets('ready shows the tag, hands-free, re-download and delete', (
    tester,
  ) async {
    final prefs = MemoryUiPrefsStore();
    final models = FakeVoiceModels(modelStatusOf(ModelStatusKindDto.ready));
    await _openSettings(
      tester,
      voice: fakeVoiceServices(models: models, prefs: prefs),
    );
    expect(_tag('Ready'), findsOneWidget);
    expect(find.text('English · 1.43 GB used on this phone'), findsOneWidget);
    _expectRow('ggml-base.en.bin', ['Whisper Base (English)', '148 MB']);
    _expectRow('qwen2.5-1.5b-instruct-q5_k_m.gguf', [
      'Qwen2.5 1.5B Instruct',
      '1.29 GB',
    ]);
    expect(find.text('Hands-free spoken feedback'), findsOneWidget);
    expect(
      find.text('Speaks the “still need” question and a short confirmation'),
      findsOneWidget,
    );
    expect(find.text('Re-download models'), findsOneWidget);
    expect(find.text('frees 1.43 GB'), findsOneWidget);

    await tester.tap(find.byKey(const Key('settings-hands-free')));
    await tester.pump();
    expect(prefs.prefs.handsFree, isTrue);

    await tester.tap(find.byKey(const Key('settings-redownload')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Keep models'));
    await tester.pumpAndSettle();
    expect(models.calls, isEmpty);

    await tester.tap(find.byKey(const Key('settings-delete-model')));
    await tester.pumpAndSettle();
    expect(find.text('Delete voice models?'), findsOneWidget);
    expect(
      find.text(
        'Frees 1.43 GB. Voice fill won’t work until you download them again.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('confirm-delete-model')));
    await tester.pumpAndSettle();
    expect(models.calls, ['delete']);
    expect(find.text('Not downloaded'), findsOneWidget);
    expect(find.text('Download 1.43 GB'), findsOneWidget);
    expect(find.byKey(const Key('settings-hands-free')), findsNothing);
  });

  testWidgets('re-download asks first, then starts over', (tester) async {
    final models = FakeVoiceModels(modelStatusOf(ModelStatusKindDto.ready));
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
    await tester.dragUntilVisible(
      find.byKey(const Key('settings-android-settings')),
      find.byKey(const Key('settings-page')),
      const Offset(0, -200),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-android-settings')));
    await tester.pump();
    expect(permission.settingsOpened, 1);
  });
}
