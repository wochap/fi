import 'package:fi/theme/fi_icons.dart';
import 'package:fi/src/rust/api/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'device_widget_test.dart' show pumpUntilFound, testApp;
import 'fake_bridge.dart';

void main() {
  testWidgets('a deferred networking start explains the keyring and retries', (
    tester,
  ) async {
    final bridge = FakeCollectionBridge()
      ..bootstrap = const BootstrapDto(
        kind: BootstrapKindDto.ready,
        rootId: 'root',
      )
      ..deferredNetworking = const NetworkingDeferredDto(
        kind: NetworkingDeferredKindDto.secureStoreLocked,
        message: 'Your login keyring is locked.',
      );
    await tester.pumpWidget(testApp(bridge));
    await pumpUntilFound(
      tester,
      find.byKey(const Key('networking-deferred-banner')),
    );
    // Local data stays usable behind the banner.
    expect(find.text('Collections'), findsWidgets);
    expect(
      find.text('Sync is off: the desktop keyring is locked'),
      findsOneWidget,
    );
    expect(
      find.text(
        "Fi keeps this device's keys in the desktop keyring. Unlock it, then "
        'retry. Your data here still works.',
      ),
      findsOneWidget,
    );
    expect(find.text('keyring locked'), findsOneWidget);

    // A retry that is still locked keeps the explanation and reports why.
    bridge.nextRetryNetworkingError = const BridgeError(
      kind: BridgeErrorKind.secureStoreLocked,
      issues: [],
      message:
          'Your login keyring is locked, so secure device networking '
          'cannot start. Unlock the keyring and retry.',
      resetResolvable: false,
    );
    await tester.tap(find.byKey(const Key('retry-networking')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('networking-deferred-banner')), findsOneWidget);
    expect(find.byKey(const Key('networking-retry-error')), findsOneWidget);

    // After the user unlocks, the retry clears the banner in place.
    await tester.tap(find.byKey(const Key('retry-networking')));
    await tester.pumpAndSettle();
    expect(bridge.retryNetworkingCalls, 2);
    expect(find.byKey(const Key('networking-deferred-banner')), findsNothing);
    expect(find.text('Collections'), findsWidgets);
    // The live status replaces the cause line.
    expect(find.text('keyring locked'), findsNothing);
  });

  testWidgets('exhausted ports name the UDP range and retry', (tester) async {
    final bridge = FakeCollectionBridge()
      ..bootstrap = const BootstrapDto(
        kind: BootstrapKindDto.ready,
        rootId: 'root',
      )
      ..deferredNetworking = const NetworkingDeferredDto(
        kind: NetworkingDeferredKindDto.portsExhausted,
        message:
            'Every network port fi uses (UDP 47380-47389) is already in use, '
            'so this device cannot reach your other devices. Close the other '
            'program or instance holding them, then retry.',
      );
    await tester.pumpWidget(testApp(bridge));
    await pumpUntilFound(
      tester,
      find.byKey(const Key('networking-deferred-banner')),
    );
    expect(
      find.text('Sync is off: UDP 47380–47389 are in use'),
      findsOneWidget,
    );
    expect(find.textContaining('keyring'), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const Key('app-bar-sync-status')),
        matching: find.text('Offline'),
      ),
      findsOneWidget,
    );
    expect(find.text('ports in use'), findsOneWidget);
    expect(find.byIcon(FiIcons.network), findsOneWidget);
    expect(find.text('Collections'), findsWidgets);

    await tester.tap(find.byKey(const Key('retry-networking')));
    await tester.pumpAndSettle();
    expect(bridge.retryNetworkingCalls, 1);
    expect(find.byKey(const Key('networking-deferred-banner')), findsNothing);
  });

  testWidgets('a fatal locked keystore offers retry, not a dataset reset', (
    tester,
  ) async {
    final bridge = FakeCollectionBridge()
      ..nextError = const BridgeError(
        kind: BridgeErrorKind.secureStoreLocked,
        issues: [],
        message:
            'Your login keyring is locked, so secure device networking '
            'cannot start. Unlock the keyring and retry.',
        resetResolvable: false,
      );
    await tester.pumpWidget(testApp(bridge));
    await pumpUntilFound(tester, find.byKey(const Key('bootstrap-error')));
    expect(find.text("Fi couldn't start"), findsOneWidget);
    expect(find.textContaining('keyring'), findsOneWidget);
    expect(find.byKey(const Key('retry-after-unlock')), findsOneWidget);
    // Never the destructive affordance: a locked keyring is not a dataset
    // problem.
    expect(find.byKey(const Key('reset-dataset')), findsNothing);

    bridge.bootstrap = const BootstrapDto(
      kind: BootstrapKindDto.ready,
      rootId: 'root',
    );
    await tester.tap(find.byKey(const Key('retry-after-unlock')));
    await tester.pumpAndSettle();
    expect(bridge.retryNetworkingCalls, 1);
    expect(find.byKey(const Key('bootstrap-error')), findsNothing);
  });

  testWidgets('no keyring titles the banner and reads no keyring', (
    tester,
  ) async {
    final bridge = FakeCollectionBridge()
      ..bootstrap = const BootstrapDto(
        kind: BootstrapKindDto.ready,
        rootId: 'root',
      )
      ..deferredNetworking = const NetworkingDeferredDto(
        kind: NetworkingDeferredKindDto.secureStoreUnavailable,
        message: '',
      );
    await tester.pumpWidget(testApp(bridge));
    await pumpUntilFound(
      tester,
      find.byKey(const Key('networking-deferred-banner')),
    );
    expect(find.text('Sync is off: no keyring is available'), findsOneWidget);
    expect(find.text('no keyring'), findsOneWidget);
    expect(find.byKey(const Key('retry-networking')), findsOneWidget);
  });

  testWidgets('a phone shows Offline with the cause in the top row', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    for (final (kind, cause) in [
      (NetworkingDeferredKindDto.secureStoreLocked, 'keyring locked'),
      (NetworkingDeferredKindDto.secureStoreUnavailable, 'no keyring'),
      (NetworkingDeferredKindDto.portsExhausted, 'ports in use'),
    ]) {
      final bridge = FakeCollectionBridge()
        ..bootstrap = const BootstrapDto(
          kind: BootstrapKindDto.ready,
          rootId: 'root',
        )
        ..deferredNetworking = NetworkingDeferredDto(kind: kind, message: '');
      await tester.pumpWidget(testApp(bridge));
      await pumpUntilFound(tester, find.text('Offline · $cause'));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    }
  });
}
