import 'package:fi/theme/fi_icons.dart';
import 'package:fi/theme/nocturne.dart';
import 'package:fi/theme/nocturne_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> pumpAt(WidgetTester tester, double width, Widget child) async {
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: nocturneTheme(NocturneColors.mocha),
      home: Scaffold(body: Center(child: child)),
    ),
  );
}

BoxDecoration decorationOf(WidgetTester tester, Finder finder) =>
    switch (tester.widget(finder)) {
          final Container box => box.decoration!,
          final AnimatedContainer box => box.decoration!,
          _ => throw ArgumentError('no decoration'),
        }
        as BoxDecoration;

void main() {
  group('ClearMark', () {
    testWidgets('draws 22px, hits 44px on a phone and clears', (tester) async {
      var taps = 0;
      await pumpAt(tester, 390, ClearMark(onPressed: () => taps++));
      final circle = find.byKey(const Key('clear-mark-circle'));
      expect(tester.getSize(circle), const Size.square(22));
      expect(
        decorationOf(tester, circle).color,
        NocturneColors.mocha.neutralEdge,
      );
      expect(tester.widget<Icon>(find.byIcon(FiIcons.clear)).size, 11);
      expect(tester.getSize(find.byType(ClearMark)), const Size.square(44));
      expect(find.bySemanticsLabel('Clear'), findsOneWidget);
      // The corner of the hit area, outside the drawn circle, still clears.
      final rect = tester.getRect(find.byType(ClearMark));
      await tester.tapAt(rect.topLeft + const Offset(2, 2));
      expect(taps, 1);
    });

    testWidgets('hit area matches the circle on desktop', (tester) async {
      await pumpAt(tester, 1240, ClearMark(onPressed: () {}));
      expect(tester.getSize(find.byType(ClearMark)), const Size.square(22));
    });
  });

  group('Tag', () {
    testWidgets('outline tag with an icon', (tester) async {
      await pumpAt(
        tester,
        1240,
        const Tag.outline('Incomplete', leading: FiIcons.needed),
      );
      final box = decorationOf(
        tester,
        find.descendant(of: find.byType(Tag), matching: find.byType(Container)),
      );
      expect(box.color, Colors.transparent);
      expect(box.borderRadius, BorderRadius.circular(6));
      final border = box.border! as Border;
      expect(border.top.color, NocturneColors.mocha.accent);
      expect(border.top.width, 1);
      final text = tester.widget<Text>(find.text('Incomplete'));
      expect(text.style!.color, NocturneColors.mocha.accent);
      expect(text.style!.fontSize, 11);
      expect(
        tester.widget<Icon>(find.byIcon(FiIcons.needed)).color,
        NocturneColors.mocha.accent,
      );
    });

    testWidgets('danger tag colors', (tester) async {
      await pumpAt(
        tester,
        1240,
        const Tag.danger('Revoked', leading: FiIcons.blocked),
      );
      final box = decorationOf(
        tester,
        find.descendant(of: find.byType(Tag), matching: find.byType(Container)),
      );
      expect(box.color, Colors.transparent);
      expect((box.border! as Border).top.color, NocturneColors.mocha.danger);
      expect(
        tester.widget<Text>(find.text('Revoked')).style!.color,
        NocturneColors.mocha.text,
      );
      expect(
        tester.widget<Icon>(find.byIcon(FiIcons.blocked)).color,
        NocturneColors.mocha.danger,
      );
    });

    testWidgets('success tag colors', (tester) async {
      await pumpAt(
        tester,
        1240,
        const Tag.success('Synced', leading: FiIcons.synced),
      );
      final box = decorationOf(
        tester,
        find.descendant(of: find.byType(Tag), matching: find.byType(Container)),
      );
      expect(box.color, NocturneColors.mocha.success.withValues(alpha: .22));
      expect(box.border, isNull);
      expect(
        tester.widget<Text>(find.text('Synced')).style!.color,
        NocturneColors.mocha.text,
      );
      expect(
        tester.widget<Icon>(find.byIcon(FiIcons.synced)).color,
        NocturneColors.mocha.success,
      );
    });

    testWidgets('accent tag colors', (tester) async {
      await pumpAt(tester, 1240, const Tag('Required'));
      final box = decorationOf(
        tester,
        find.descendant(of: find.byType(Tag), matching: find.byType(Container)),
      );
      expect(box.color, NocturneColors.mocha.accentFill);
      expect(box.border, isNull);
      expect(
        tester.widget<Text>(find.text('Required')).style!.color,
        NocturneColors.mocha.accentInkStrong,
      );
    });
  });

  group('status markers', () {
    testWidgets('Voice chip is a labelled button', (tester) async {
      await pumpAt(tester, 390, VoiceChip(fieldLabel: 'amount', onTap: () {}));
      expect(find.byIcon(FiIcons.voice), findsOneWidget);
      expect(find.text('Voice'), findsOneWidget);
      expect(
        tester.getSize(find.byType(VoiceChip)).height,
        greaterThanOrEqualTo(28),
      );
      final label = tester
          .getSemantics(find.byType(VoiceChip))
          .getSemanticsData()
          .label;
      expect(label, contains('amount'));
      expect(label, contains('filled by voice'));
    });

    testWidgets('Default and Needed have their own glyph and word', (
      tester,
    ) async {
      await pumpAt(
        tester,
        390,
        const Column(children: [DefaultMarker(), NeededMarker()]),
      );
      expect(find.byIcon(FiIcons.defaultValue), findsOneWidget);
      expect(find.text('Default'), findsOneWidget);
      expect(find.byIcon(FiIcons.needed), findsOneWidget);
      expect(find.text('Needed'), findsOneWidget);
      expect(FiIcons.defaultValue, isNot(FiIcons.needed));
    });
  });

  group('FiSwitch', () {
    final track = find.byKey(const Key('fi-switch-track'));
    final knob = find.byKey(const Key('fi-switch-knob'));

    testWidgets('on switch on desktop', (tester) async {
      await pumpAt(tester, 1240, FiSwitch(value: true, onChanged: (_) {}));
      expect(tester.getSize(track), const Size(38, 22));
      expect(tester.getSize(knob), const Size.square(12));
      expect(
        tester.getRect(knob).right,
        closeTo(tester.getRect(track).right - 5, .01),
      );
      final box = decorationOf(tester, track);
      expect(box.color, NocturneColors.mocha.accentFill);
      expect((box.border! as Border).top.color, NocturneColors.mocha.accent);
      expect(decorationOf(tester, knob).color, NocturneColors.mocha.accent);
    });

    testWidgets('off switch on a phone', (tester) async {
      bool? changed;
      await pumpAt(
        tester,
        390,
        FiSwitch(value: false, onChanged: (value) => changed = value),
      );
      expect(tester.getSize(track), const Size(44, 26));
      expect(tester.getSize(knob), const Size.square(14));
      expect(
        tester.getRect(knob).left,
        closeTo(tester.getRect(track).left + 6, .01),
      );
      final box = decorationOf(tester, track);
      expect(box.color, Colors.transparent);
      expect((box.border! as Border).top.color, NocturneColors.mocha.divider);
      expect(decorationOf(tester, knob).color, NocturneColors.mocha.muted(.55));
      await tester.tap(track);
      expect(changed, isTrue);
    });
  });

  group('phone sizes', () {
    Widget button() =>
        FiIconButton(icon: FiIcons.more, tooltip: 'More', onPressed: () {});
    Widget row() => const CardListRow(child: Text('Groceries'));

    testWidgets('on a phone', (tester) async {
      await pumpAt(tester, 390, Column(children: [button(), row()]));
      final size = tester.getSize(find.byType(IconButton));
      expect(size.width, greaterThanOrEqualTo(44));
      expect(size.height, greaterThanOrEqualTo(44));
      expect(
        tester.getSize(find.byType(CardListRow)).height,
        greaterThanOrEqualTo(64),
      );
      expect(find.byTooltip('More'), findsOneWidget);
    });

    testWidgets('on desktop', (tester) async {
      await pumpAt(tester, 1240, Column(children: [button(), row()]));
      expect(tester.getSize(find.byType(IconButton)), const Size.square(36));
      expect(tester.getSize(find.byType(CardListRow)).height, lessThan(64));
    });
  });
}
