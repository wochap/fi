import 'package:fi/theme/nocturne_widgets.dart';
import 'package:fi/help_button.dart';
import 'package:fi/help_copy.dart';
import 'package:fi/l10n/l10n.dart';
import 'package:flutter/material.dart';
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
}
