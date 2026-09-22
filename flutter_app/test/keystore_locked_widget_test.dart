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
    expect(find.textContaining('keyring'), findsOneWidget);

    // A retry that is still locked keeps the explanation and reports why.
    bridge.nextRetryNetworkingError = const BridgeError(
      kind: BridgeErrorKind.secureStoreLocked,
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
  });

  testWidgets('a fatal locked keystore offers retry, not a dataset reset', (
    tester,
  ) async {
    final bridge = FakeCollectionBridge()
      ..nextError = const BridgeError(
        kind: BridgeErrorKind.secureStoreLocked,
        message:
            'Your login keyring is locked, so secure device networking '
            'cannot start. Unlock the keyring and retry.',
        resetResolvable: false,
      );
    await tester.pumpWidget(testApp(bridge));
    await pumpUntilFound(tester, find.byKey(const Key('bootstrap-error')));
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
}
