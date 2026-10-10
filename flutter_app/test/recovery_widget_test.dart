import 'package:fi/app.dart';
import 'package:fi/src/rust/api/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_bridge.dart';

Widget testApp(FakeCollectionBridge bridge) => CollectionApp(
  bridge: bridge,
  initializeRust: () async {},
  dataDirProvider: () async => '/test',
  setPlatformForeground: (_) async {},
);

Future<void> pumpUntilFound(WidgetTester tester, Finder finder) async {
  for (var attempt = 0; attempt < 30; attempt++) {
    await tester.pump(const Duration(milliseconds: 50));
    if (finder.evaluate().isNotEmpty) return;
  }
  fail('Timed out waiting for $finder.');
}

const root = '0b6f4b3e-9f5c-4a7e-8f0e-5a1c2d3e4f50';

RecoveryDto recovery(
  RecoveryOutcomeDto outcome, {
  RecoveryReasonDto reason = RecoveryReasonDto.rootSnapshotMissing,
}) => RecoveryDto(
  reason: reason,
  outcome: outcome,
  rootId: root,
  documentIds: const [root],
  quarantinePaths: const [],
);

BootstrapDto joining(RecoveryDto? recovery) => BootstrapDto(
  kind: BootstrapKindDto.joining,
  rootId: root,
  recovery: recovery,
);

void main() {
  testWidgets('recovering renders progress copy instead of a bare spinner', (
    tester,
  ) async {
    final bridge = FakeCollectionBridge()
      ..bootstrap = joining(recovery(RecoveryOutcomeDto.recovering));
    await tester.pumpWidget(testApp(bridge));
    await pumpUntilFound(tester, find.byKey(const Key('recovery-recovering')));
    expect(find.text("Recovering this device's data"), findsOneWidget);
    expect(
      find.text(
        'Fi is getting the dataset back from your other devices. Keep them '
        'open.',
      ),
      findsOneWidget,
    );
    expect(find.byKey(const Key('setup-ring')), findsOneWidget);
    // The root id is not printed.
    expect(find.textContaining('0b6f4b3e'), findsNothing);
    expect(find.byKey(const Key('joining-surface')), findsNothing);
    expect(find.byKey(const Key('bootstrap-error')), findsNothing);
    expect(find.byKey(const Key('create-dataset')), findsNothing);
  });

  testWidgets('a corrupt snapshot shows the same recovering copy', (
    tester,
  ) async {
    final bridge = FakeCollectionBridge()
      ..bootstrap = joining(
        recovery(
          RecoveryOutcomeDto.recovering,
          reason: RecoveryReasonDto.rootSnapshotCorrupt,
        ),
      );
    await tester.pumpWidget(testApp(bridge));
    await pumpUntilFound(tester, find.byKey(const Key('recovery-recovering')));
    expect(find.text("Recovering this device's data"), findsOneWidget);
  });

  testWidgets('Retry dials every trusted device and offers no create', (
    tester,
  ) async {
    TrustedDeviceDto device(String n, {bool revoked = false}) =>
        TrustedDeviceDto(
          deviceId: n * 64,
          friendlyName: 'Peer $n',
          announcedName: 'Peer $n',
          pairedAtMs: 1,
          revoked: revoked,
          connection: PeerConnectionKindDto.offline,
        );
    final bridge = FakeCollectionBridge()
      ..bootstrap = joining(recovery(RecoveryOutcomeDto.noPeerAvailable))
      ..devices.addAll([device('1'), device('2'), device('3', revoked: true)]);
    await tester.pumpWidget(testApp(bridge));
    await pumpUntilFound(tester, find.byKey(const Key('recovery-no-peer')));
    await tester.pump();
    expect(find.byKey(const Key('create-dataset')), findsNothing);
    expect(find.textContaining('Create'), findsNothing);

    await tester.tap(find.byKey(const Key('recovery-retry')));
    await tester.pump();
    expect(bridge.reconnects, ['1' * 64, '2' * 64]);
    expect(find.byKey(const Key('recovery-no-peer')), findsOneWidget);
  });

  testWidgets(
    'no peer available states plainly that another device is required and '
    'never creates a dataset automatically',
    (tester) async {
      final bridge = FakeCollectionBridge()
        ..bootstrap = joining(recovery(RecoveryOutcomeDto.recovering));
      await tester.pumpWidget(testApp(bridge));
      await pumpUntilFound(
        tester,
        find.byKey(const Key('recovery-recovering')),
      );
      bridge.bootstrapController.add(
        joining(recovery(RecoveryOutcomeDto.noPeerAvailable)),
      );
      await pumpUntilFound(tester, find.byKey(const Key('recovery-no-peer')));
      expect(find.text('Recovery needs another device'), findsOneWidget);
      expect(
        find.textContaining("This device's copy of the dataset is damaged."),
        findsOneWidget,
      );
      expect(find.text("Reset this device's data…"), findsOneWidget);
      expect(find.byKey(const Key('recovery-retry')), findsOneWidget);
      expect(find.byKey(const Key('create-dataset')), findsNothing);
      expect(find.byKey(const Key('retry-bootstrap')), findsNothing);
      expect(bridge.pairingCalls, isNot(contains('createNewDataset')));

      // A reset is offered only behind an explicit confirmation.
      await tester.tap(find.byKey(const Key('recovery-reset-dataset')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('reset-dataset-dialog')), findsOneWidget);
      expect(bridge.pairingCalls, isNot(contains('resetDataset')));
      await tester.tap(find.text('Keep data'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('recovery-no-peer')), findsOneWidget);

      // The peer appears later: recovery completes into the shell.
      bridge.bootstrapController.add(
        joining(recovery(RecoveryOutcomeDto.recovering)),
      );
      await pumpUntilFound(
        tester,
        find.byKey(const Key('recovery-recovering')),
      );
      bridge.bootstrapController.add(
        BootstrapDto(
          kind: BootstrapKindDto.ready,
          rootId: root,
          recovery: recovery(RecoveryOutcomeDto.recovered),
        ),
      );
      await pumpUntilFound(tester, find.text('Collections'));
    },
  );

  testWidgets('a plain join without recovery keeps the joining surface', (
    tester,
  ) async {
    final bridge = FakeCollectionBridge()..bootstrap = joining(null);
    await tester.pumpWidget(testApp(bridge));
    await pumpUntilFound(tester, find.byKey(const Key('joining-surface')));
    expect(find.byKey(const Key('recovery-recovering')), findsNothing);
  });

  testWidgets('genuinely fatal open keeps the fatal surface and retry', (
    tester,
  ) async {
    final bridge = FakeCollectionBridge()
      ..nextError = const BridgeError(
        kind: BridgeErrorKind.persistence,
        issues: [],
        message: 'Local data could not be saved or loaded.',
        resetResolvable: false,
      );
    await tester.pumpWidget(testApp(bridge));
    await pumpUntilFound(tester, find.byKey(const Key('bootstrap-error')));
    expect(find.byKey(const Key('retry-bootstrap')), findsOneWidget);
    expect(find.byKey(const Key('reset-dataset')), findsNothing);
    expect(find.byKey(const Key('recovery-recovering')), findsNothing);
    expect(find.byKey(const Key('recovery-no-peer')), findsNothing);
  });

  testWidgets('exhausted recovery is fatal and reset-resolvable', (
    tester,
  ) async {
    final bridge = FakeCollectionBridge()
      ..nextError = const BridgeError(
        kind: BridgeErrorKind.bootstrap,
        issues: [],
        message:
            "Recovering this device's dataset from your other devices failed "
            'repeatedly, so it will not be retried.',
        resetResolvable: true,
      );
    await tester.pumpWidget(testApp(bridge));
    await pumpUntilFound(tester, find.byKey(const Key('bootstrap-error')));
    expect(find.text("Fi couldn't start"), findsOneWidget);
    expect(find.textContaining('Retrying won\'t fix it.'), findsOneWidget);
    expect(find.textContaining('failed repeatedly'), findsNothing);
    expect(find.byKey(const Key('copy-error-details')), findsOneWidget);
    expect(find.byKey(const Key('reset-dataset')), findsOneWidget);
    expect(find.byKey(const Key('retry-bootstrap')), findsNothing);
  });

  testWidgets('quarantined orphans are explained on onboarding', (
    tester,
  ) async {
    final bridge = FakeCollectionBridge()
      ..bootstrap = BootstrapDto(
        kind: BootstrapKindDto.needsDecision,
        recovery: recovery(
          RecoveryOutcomeDto.quarantined,
          reason: RecoveryReasonDto.orphanedDocuments,
        ),
      );
    await tester.pumpWidget(testApp(bridge));
    await pumpUntilFound(tester, find.byKey(const Key('create-dataset')));
    expect(find.byKey(const Key('recovery-quarantined')), findsOneWidget);
  });

  testWidgets('Copy details puts Rust\'s message on the clipboard', (
    tester,
  ) async {
    const message =
        "Recovering this device's dataset from your other devices failed "
        'repeatedly, so it will not be retried.';
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final bridge = FakeCollectionBridge()
      ..nextError = const BridgeError(
        kind: BridgeErrorKind.bootstrap,
        issues: [],
        message: message,
        resetResolvable: true,
      );
    await tester.pumpWidget(testApp(bridge));
    await pumpUntilFound(tester, find.byKey(const Key('copy-error-details')));
    await tester.tap(find.byKey(const Key('copy-error-details')));
    await tester.pump();
    await tester.pump();
    expect(copied, message);
    expect(find.text('Details copied'), findsOneWidget);
  });

  testWidgets('a fatal error without its own message offers no Copy details', (
    tester,
  ) async {
    final bridge = FakeCollectionBridge()..nextError = StateError('boom');
    await tester.pumpWidget(testApp(bridge));
    await pumpUntilFound(tester, find.byKey(const Key('bootstrap-error')));
    expect(find.byKey(const Key('copy-error-details')), findsNothing);
    expect(find.byKey(const Key('retry-bootstrap')), findsOneWidget);
  });
}
