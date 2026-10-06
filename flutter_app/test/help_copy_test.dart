import 'package:fi/theme/nocturne_widgets.dart';
import 'package:fi/help_button.dart';
import 'package:fi/help_copy.dart';
import 'package:fi/l10n/l10n.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('every help id has reviewable copy', () {
    for (final locale in const [Locale('en'), Locale('es')]) {
      final l = lookupAppLocalizations(locale);
      for (final id in HelpId.values) {
        final entry = helpEntry(l, id);
        final where = '${id.name} (${locale.languageCode})';
        expect(entry.title.trim(), isNotEmpty, reason: where);
        expect(entry.body.trim(), isNotEmpty, reason: where);
      }
    }
  });

  testWidgets('tapping help opens the copy and leaves the form untouched', (
    tester,
  ) async {
    var switchValue = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => FiSwitchTile(
              title: const Text('Required'),
              secondary: const HelpButton(HelpId.fieldRequired),
              value: switchValue,
              onChanged: (value) => setState(() => switchValue = value),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('help-fieldRequired')));
    await tester.pumpAndSettle();

    final entry = helpEntry(
      lookupAppLocalizations(const Locale('en')),
      HelpId.fieldRequired,
    );
    expect(find.byKey(const Key('help-dialog')), findsOneWidget);
    // The control beside the button carries the same label, so the title is expected twice.
    expect(find.text(entry.title), findsNWidgets(2));
    expect(find.text(entry.body), findsOneWidget);

    await tester.tap(find.byKey(const Key('help-close')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('help-dialog')), findsNothing);
    expect(switchValue, isFalse);
    expect(
      tester.widget<FiSwitchTile>(find.byType(FiSwitchTile)).value,
      isFalse,
    );
  });

  group('presentation by width', () {
    Future<void> pumpAt(
      WidgetTester tester,
      double width,
      ValueNotifier<bool> value,
    ) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 844);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ValueListenableBuilder(
              valueListenable: value,
              builder: (context, on, _) => FiSwitchTile(
                title: const Text('Required'),
                secondary: const HelpButton(HelpId.fieldRequired),
                value: on,
                onChanged: (next) => value.value = next,
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('the button is 28×28 on desktop and 44×44 on a phone', (
      tester,
    ) async {
      final value = ValueNotifier(false);
      addTearDown(value.dispose);
      await pumpAt(tester, 1240, value);
      expect(
        tester.getSize(find.byKey(const Key('help-fieldRequired'))),
        const Size(28, 28),
      );
      await pumpAt(tester, 390, value);
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.byKey(const Key('help-fieldRequired'))),
        const Size(44, 44),
      );
    });

    testWidgets('desktop opens a popover under the button that Esc closes', (
      tester,
    ) async {
      final value = ValueNotifier(true);
      addTearDown(value.dispose);
      await pumpAt(tester, 1240, value);
      final button = find.byKey(const Key('help-fieldRequired'));
      await tester.tap(button);
      await tester.pumpAndSettle();
      final popup = find.byKey(const Key('help-dialog'));
      expect(popup, findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.text('Got it'), findsOneWidget);
      expect(
        tester.getTopLeft(popup).dy,
        greaterThanOrEqualTo(tester.getBottomLeft(button).dy),
      );
      expect(tester.getSize(popup).width, lessThanOrEqualTo(320));

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(popup, findsNothing);
      expect(value.value, isTrue);

      // A click outside closes it without reaching the control underneath.
      await tester.tap(button);
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(600, 700));
      await tester.pumpAndSettle();
      expect(popup, findsNothing);
      expect(value.value, isTrue);
    });

    testWidgets('a phone opens a bottom sheet with a full-width Got it', (
      tester,
    ) async {
      final value = ValueNotifier(false);
      addTearDown(value.dispose);
      await pumpAt(tester, 390, value);
      await tester.tap(find.byKey(const Key('help-fieldRequired')));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsOneWidget);
      final gotIt = find.byKey(const Key('help-close'));
      expect(tester.getSize(gotIt).width, greaterThan(300));
      expect(find.text('Got it'), findsOneWidget);

      await tester.tapAt(const Offset(195, 20));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
      expect(value.value, isFalse);

      await tester.tap(find.byKey(const Key('help-fieldRequired')));
      await tester.pumpAndSettle();
      await tester.tap(gotIt);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('help-dialog')), findsNothing);
      expect(value.value, isFalse);
    });
  });
}
