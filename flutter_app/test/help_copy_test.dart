import 'package:fi/help_button.dart';
import 'package:fi/help_copy.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('every help id has reviewable copy', () {
    for (final id in HelpId.values) {
      final entry = helpCopy[id];
      expect(entry, isNotNull, reason: 'no help copy registered for ${id.name}');
      expect(
        entry!.title.trim(),
        isNotEmpty,
        reason: '${id.name} has an empty title',
      );
      expect(
        entry.body.trim(),
        isNotEmpty,
        reason: '${id.name} has an empty body',
      );
    }
  });

  test('the registry holds no id the enum does not name', () {
    expect(helpCopy.keys.toSet(), HelpId.values.toSet());
  });

  testWidgets('tapping help opens the copy and leaves the form untouched', (
    tester,
  ) async {
    var switchValue = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => SwitchListTile(
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

    final entry = helpCopy[HelpId.fieldRequired]!;
    expect(find.byKey(const Key('help-dialog')), findsOneWidget);
    // The control beside the button carries the same label, so the title is expected twice.
    expect(find.text(entry.title), findsNWidgets(2));
    expect(find.text(entry.body), findsOneWidget);

    await tester.tap(find.byKey(const Key('help-close')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('help-dialog')), findsNothing);
    expect(switchValue, isFalse);
    expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value, isFalse);
  });
}
