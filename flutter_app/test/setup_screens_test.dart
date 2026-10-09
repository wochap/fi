import 'package:fi/l10n/app_localizations.dart';
import 'package:fi/setup_screens.dart';
import 'package:fi/src/rust/api/models.dart';
import 'package:fi/theme/fi_icons.dart';
import 'package:fi/theme/nocturne.dart';
import 'package:fi/ui_prefs.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_bridge.dart';
import 'widget_test.dart' show app, pumpUntilFound;

const _desktop = Size(1240, 820);
const _phone = Size(390, 844);

void _size(WidgetTester tester, Size size) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
}

Widget _host(Widget child, {Locale locale = const Locale('en')}) => MaterialApp(
  theme: nocturneTheme(NocturneColors.mocha),
  locale: locale,
  supportedLocales: AppLocalizations.supportedLocales,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  home: child,
);

void main() {
  for (final size in [_desktop, _phone]) {
    testWidgets('SetupScaffold and ChoiceCard fit at ${size.width}', (
      tester,
    ) async {
      _size(tester, size);
      var tapped = 0;
      await tester.pumpWidget(
        _host(
          SetupScaffold(
            title: 'Set up this device',
            lead: 'Your data stays on your devices. Pick how this one starts.',
            children: [
              ChoiceCard(
                key: const Key('normal'),
                icon: FiIcons.addCircle,
                title: 'Create a new dataset',
                body: 'Start fresh. You can pair other devices later.',
                onTap: () => tapped++,
              ),
              const ChoiceCard(
                key: Key('selected'),
                icon: FiIcons.link,
                title: 'Join an existing dataset',
                body: 'Copy the dataset from one of your other devices.',
                bullets: [
                  'The other device must already have a dataset.',
                  'Start the connection from only one of the two devices.',
                ],
                selected: true,
              ),
              ChoiceCard(
                key: const Key('locked'),
                icon: FiIcons.addCircle,
                title: 'Create a new dataset',
                body: 'unused',
                lockedReason: 'Not available while pairing is open.',
                onTap: () => tapped++,
              ),
            ],
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Fi'), findsOneWidget);
      expect(
        tester.getSize(find.byKey(const Key('normal'))).width,
        lessThanOrEqualTo(560),
      );
      if (size == _phone) {
        expect(tester.getTopLeft(find.byKey(const Key('normal'))).dx, 16);
      }
      expect(find.byIcon(FiIcons.locked), findsOneWidget);
      expect(find.text('unused'), findsNothing);
      await tester.tap(find.byKey(const Key('normal')));
      await tester.tap(find.byKey(const Key('locked')));
      expect(tapped, 1);
    });

    for (final name in ['Fi f755167e', null]) {
      testWidgets(
        'DatasetMismatchScreen ${name == null ? 'unnamed' : 'named'} at '
        '${size.width}',
        (tester) async {
          _size(tester, size);
          final calls = <String>[];
          await tester.pumpWidget(
            _host(
              DatasetMismatchScreen(
                peerName: name,
                onBack: () => calls.add('back'),
                onPairDifferent: () => calls.add('different'),
                onReset: () => calls.add('reset'),
              ),
            ),
          );
          expect(tester.takeException(), isNull);
          expect(
            find.text('This device has a different dataset'),
            findsOneWidget,
          );
          expect(
            find.text(
              name == null
                  ? 'The other device uses another dataset than this device. '
                        'Devices can only sync when they share the same one.'
                  : '“$name” uses another dataset than this device. Devices '
                        'can only sync when they share the same one.',
            ),
            findsOneWidget,
          );
          expect(
            find.textContaining("To join it, reset this device's data first."),
            findsOneWidget,
          );
          final reset = find.byKey(const Key('reset-dataset'));
          final back = find.byKey(const Key('dataset-mismatch-back'));
          expect(tester.widget(back), isA<FilledButton>());
          if (size == _phone) {
            // Stacked, primary at the bottom.
            expect(
              tester.getTopLeft(back).dy,
              greaterThan(
                tester
                    .getTopLeft(find.byKey(const Key('pair-different-device')))
                    .dy,
              ),
            );
            expect(tester.getSize(back).width, tester.getSize(reset).width);
          }
          await tester.tap(reset);
          await tester.tap(find.byKey(const Key('pair-different-device')));
          await tester.tap(back);
          expect(calls, ['reset', 'different', 'back']);
        },
      );
    }
  }

  group('Spanish at 390px', () {
    testWidgets('onboarding, Join view and different dataset fit', (
      tester,
    ) async {
      _size(tester, _phone);
      final bridge = FakeCollectionBridge();
      await tester.pumpWidget(
        app(
          bridge,
          uiPrefs: MemoryUiPrefsStore(
            const UiPrefs(appLanguage: AppLanguage.spanish),
          ),
        ),
      );
      await pumpUntilFound(tester, find.text('Configura este dispositivo'));
      expect(tester.takeException(), isNull);

      await tester.tap(find.byKey(const Key('join-dataset')));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('join-view')), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.byKey(const Key('join-back')));
      await tester.pump();
      expect(find.byKey(const Key('pairing-status-row')), findsOneWidget);
      expect(tester.takeException(), isNull);

      bridge.pairingController.add(
        const PairingStateDto(
          kind: PairingKindDto.failed,
          localConfirmed: false,
          remoteConfirmed: false,
          failure: PairingFailureKindDto.rootMismatch,
          alreadyPaired: false,
        ),
      );
      await tester.pump();
      expect(
        find.text('Este dispositivo tiene otro conjunto de datos'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    for (final kind in NetworkingDeferredKindDto.values) {
      testWidgets('the ${kind.name} banner fits', (tester) async {
        _size(tester, _phone);
        final bridge = FakeCollectionBridge()
          ..bootstrap = const BootstrapDto(
            kind: BootstrapKindDto.ready,
            rootId: 'root',
          )
          ..deferredNetworking = NetworkingDeferredDto(kind: kind, message: '');
        await tester.pumpWidget(
          app(
            bridge,
            uiPrefs: MemoryUiPrefsStore(
              const UiPrefs(appLanguage: AppLanguage.spanish),
            ),
          ),
        );
        await pumpUntilFound(
          tester,
          find.byKey(const Key('networking-deferred-banner')),
        );
        await tester.pump();
        expect(
          find.textContaining('Sincronización desactivada'),
          findsOneWidget,
        );
        expect(find.text('Reintentar'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  });
}
