import 'package:fi/theme/outcome_toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _show(
  WidgetTester tester, {
  required bool success,
  double width = 1240,
}) async {
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () =>
                showOutcomeToast(context, 'Something', success: success),
            child: const Text('go'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('go'));
  await tester.pumpAndSettle();
}

/// The toast's visible surface, inside the SnackBar's full-width layout.
final _surface = find
    .descendant(of: find.byType(SnackBar), matching: find.byType(Material))
    .first;

void main() {
  testWidgets('a success shows a check and hides on its own', (tester) async {
    await _show(tester, success: true);
    expect(find.text('Something'), findsOneWidget);
    expect(find.byKey(const Key('outcome-check')), findsOneWidget);
    expect(find.text('Dismiss'), findsNothing);
    expect(tester.getSize(_surface).width, 440);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.text('Something'), findsNothing);
  });

  testWidgets('an abort shows a warning and stays until Dismiss', (
    tester,
  ) async {
    await _show(tester, success: false);
    expect(find.byKey(const Key('outcome-warning')), findsOneWidget);
    await tester.pump(const Duration(minutes: 5));
    await tester.pumpAndSettle();
    expect(find.text('Something'), findsOneWidget);
    await tester.tap(find.text('Dismiss'));
    await tester.pumpAndSettle();
    expect(find.text('Something'), findsNothing);
  });

  testWidgets('a phone toast spans the screen', (tester) async {
    await _show(tester, success: true, width: 390);
    expect(tester.getSize(_surface).width, greaterThan(340));
  });
}
