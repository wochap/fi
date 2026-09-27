import 'package:fi/theme/inputs.dart';
import 'package:fi/theme/nocturne.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pump(
  WidgetTester tester,
  double width,
  Widget child, {
  double childWidth = 340,
}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: nocturneTheme(),
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [SizedBox(width: childWidth, child: child)],
          ),
        ),
      ),
    ),
  );
}

/// The height of the outlined box of the input found by [finder]: the decorator without the
/// error or helper lines below it.
double _box(WidgetTester tester, Finder finder) {
  final decorator = find
      .descendant(of: finder, matching: find.byType(InputDecorator))
      .first;
  final height = tester.getSize(decorator).height;
  final decoration = tester.widget<InputDecorator>(decorator).decoration;
  final subtext = decoration.errorText ?? decoration.helperText;
  if (subtext == null) return height;
  // The subtext sits 4px (Material 3's gap) below the box.
  return height -
      tester
          .getSize(
            find.descendant(of: decorator, matching: find.text(subtext)).last,
          )
          .height -
      4;
}

/// The slider's value label, apart from the same number in its label row.
String? _value(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const Key('slider-value'))).data;

double _top(WidgetTester tester, Finder finder) => tester
    .getTopLeft(
      find.descendant(of: finder, matching: find.byType(InputDecorator)).first,
    )
    .dy;

final _kinds = <String, Widget Function(InputSize size)>{
  'text': (size) =>
      FiTextInput(key: const Key('input'), label: 'Name', size: size),
  'text without label': (size) =>
      FiTextInput(key: const Key('input'), hint: 'Option label', size: size),
  'integer': (size) => FiTextInput(
    key: const Key('input'),
    label: 'Count',
    initialValue: '12',
    keyboardType: TextInputType.number,
    size: size,
  ),
  'search': (size) => FiTextInput(
    key: const Key('input'),
    hint: 'Search',
    prefixIcon: const Icon(Icons.search),
    size: size,
  ),
  'text with icon button': (size) => FiTextInput(
    key: const Key('input'),
    label: 'Scale',
    suffixIcon: IconButton(
      tooltip: 'Help',
      icon: const Icon(Icons.help_outline),
      onPressed: () {},
    ),
    size: size,
  ),
  'required select': (size) => FiSelect<int>(
    key: const Key('input'),
    label: 'Type',
    required: true,
    value: 1,
    items: const [DropdownMenuItem(value: 1, child: Text('Text'))],
    onChanged: (_) {},
    size: size,
  ),
  'select with help': (size) => FiSelect<int>(
    key: const Key('input'),
    label: 'Group by',
    value: 1,
    suffixIcon: IconButton(
      tooltip: 'Help',
      icon: const Icon(Icons.help_outline),
      onPressed: () {},
    ),
    items: const [DropdownMenuItem(value: 1, child: Text('Day'))],
    onChanged: (_) {},
    size: size,
  ),
  'picker with actions': (size) => FiPickerInput(
    key: const Key('input'),
    controller: TextEditingController(text: '2026-09-24'),
    label: 'Date',
    icon: Icons.calendar_today,
    actions: [TextButton(onPressed: () {}, child: const Text('Today'))],
    replaceIcon: IconButton(
      tooltip: 'Clear',
      icon: const Icon(Icons.clear),
      onPressed: () {},
    ),
    onTap: () {},
    size: size,
  ),
};

/// Sliders are exempt from the equal-height rule: they grow by their label row.
final _sliders = <String, Widget Function(InputSize size)>{
  'slider with value': (size) => FiSlider(
    key: const Key('input'),
    label: 'Pain',
    min: 1,
    max: 5,
    value: 3,
    onChanged: (_) {},
    size: size,
  ),
  'unset slider': (size) => FiSlider(
    key: const Key('input'),
    label: 'Pain',
    required: true,
    min: 1,
    max: 5,
    onChanged: (_) {},
    size: size,
  ),
};

/// The slider's label row at text scale 1.
const double _labelRow = 16;

/// Hosts a [FiSlider] whose value lives in the test, so the widget sees each change.
class _SliderHost extends StatefulWidget {
  const _SliderHost({
    required this.reported,
    super.key,
    this.initial,
    this.required = false,
    this.errors = const [],
    this.min = 1,
    this.max = 5,
    this.step = 1,
  });

  final int min;
  final int max;
  final int step;
  final List<int?> reported;
  final int? initial;
  final bool required;
  final List<String> errors;

  @override
  State<_SliderHost> createState() => _SliderHostState();
}

class _SliderHostState extends State<_SliderHost> {
  late int? value = widget.initial;

  @override
  Widget build(BuildContext context) => FiSlider(
    key: const Key('input'),
    label: 'Pain',
    min: widget.min,
    max: widget.max,
    step: widget.step,
    value: value,
    required: widget.required,
    errors: widget.errors,
    onChanged: (next) => setState(() {
      widget.reported.add(next);
      value = next;
    }),
  );
}

void main() {
  final expected = {
    (1280.0, InputSize.small): 32.0,
    (1280.0, InputSize.normal): 40.0,
    (390.0, InputSize.small): 40.0,
    (390.0, InputSize.normal): 48.0,
  };

  for (final MapEntry(key: (width, size), value: height) in expected.entries) {
    for (final MapEntry(key: kind, value: build) in _kinds.entries) {
      testWidgets(
        '$kind, ${size.name}, ${width.toInt()}px wide: ${height.toInt()}px box',
        (tester) async {
          await _pump(tester, width, build(size));
          expect(_box(tester, find.byKey(const Key('input'))), height);
        },
      );
    }
  }

  for (final MapEntry(key: (width, size), value: height) in expected.entries) {
    for (final MapEntry(key: kind, value: build) in _sliders.entries) {
      testWidgets(
        '$kind, ${size.name}, ${width.toInt()}px wide: box grows by the label row',
        (tester) async {
          await _pump(tester, width, build(size));
          expect(
            _box(tester, find.byKey(const Key('input'))),
            height + _labelRow,
          );
        },
      );
    }
  }

  for (final width in [1280.0, 390.0]) {
    testWidgets(
      'a two-line error keeps the box and the row aligned at ${width.toInt()}px',
      (tester) async {
        await _pump(
          tester,
          width,
          const Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: FiTextInput(
                  key: Key('name'),
                  label: 'Name',
                  required: true,
                  errors: ['Name is required.', 'Name is too short.'],
                ),
              ),
              SizedBox(width: 10),
              SizedBox(
                width: 150,
                child: FiSelect<int>(
                  key: Key('type'),
                  label: 'Type',
                  value: 1,
                  items: [DropdownMenuItem(value: 1, child: Text('Text'))],
                  onChanged: null,
                ),
              ),
            ],
          ),
        );
        final height = width < 720 ? 48.0 : 40.0;
        expect(_box(tester, find.byKey(const Key('name'))), height);
        expect(_box(tester, find.byKey(const Key('type'))), height);
        expect(
          _top(tester, find.byKey(const Key('name'))),
          _top(tester, find.byKey(const Key('type'))),
        );
        // Both issues show under the text input, in order.
        final first = tester.getTopLeft(
          find.text('Name is required.\nName is too short.'),
        );
        expect(
          first.dy,
          greaterThan(_top(tester, find.byKey(const Key('name'))) + height),
        );
      },
    );
  }

  testWidgets('a multiline input starts at the box height and grows by lines', (
    tester,
  ) async {
    final controller = TextEditingController();
    await _pump(
      tester,
      1280,
      FiTextInput(
        key: const Key('input'),
        label: 'Notes',
        controller: controller,
        maxLines: 6,
      ),
    );
    expect(_box(tester, find.byKey(const Key('input'))), 40);
    controller.text = 'one\ntwo\nthree';
    await tester.pump();
    expect(_box(tester, find.byKey(const Key('input'))), 80);
  });

  for (final width in [1280.0, 390.0]) {
    testWidgets('a slider aligns with a text input at ${width.toInt()}px', (
      tester,
    ) async {
      await _pump(
        tester,
        width,
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Expanded(
              child: FiTextInput(key: Key('name'), label: 'Name'),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FiSlider(
                key: const Key('slider'),
                label: 'Pain',
                min: 1,
                max: 5,
                value: 2,
                onChanged: (_) {},
              ),
            ),
          ],
        ),
      );
      final height = width < 720 ? 48.0 : 40.0;
      expect(_box(tester, find.byKey(const Key('name'))), height);
      // The slider is taller by its label row; only the tops align.
      expect(
        _box(tester, find.byKey(const Key('slider'))),
        greaterThan(height),
      );
      expect(
        _top(tester, find.byKey(const Key('name'))),
        _top(tester, find.byKey(const Key('slider'))),
      );
      // The track row sits where the text input's line does.
      final text = find.descendant(
        of: find.byKey(const Key('name')),
        matching: find.byType(EditableText),
      );
      expect(
        tester.getCenter(find.byType(Slider)).dy,
        closeTo(tester.getCenter(text).dy, 1),
      );
    });
  }

  /// The x centres of the division ticks, as the Slider's rounded track places them.
  List<double> ticks(WidgetTester tester, int divisions) {
    final rect = tester.getRect(find.byType(Slider));
    // Thumb 7 and overlay 14 radius: the track is inset by 14; ticks sit a track height (4)
    // inside its rounded ends.
    const inset = 14.0;
    final usable = rect.width - 2 * inset - 4;
    return [
      for (var i = 0; i <= divisions; i++)
        rect.left + inset + 2 + usable * i / divisions,
    ];
  }

  List<String> tickLabels(WidgetTester tester) => [
    for (final element
        in find
            .byWidgetPredicate(
              (w) =>
                  w.key is ValueKey<String> &&
                  (w.key! as ValueKey<String>).value.startsWith('slider-tick-'),
            )
            .evaluate())
      (element.widget.key! as ValueKey<String>).value.substring(12),
  ];

  testWidgets('a slider that fits every step labels each one under its tick', (
    tester,
  ) async {
    await _pump(
      tester,
      1280,
      _SliderHost(reported: [], initial: 30, min: 0, max: 100, step: 10),
      // The test font draws every glyph a font size wide, wider than real digits.
      childWidth: 700,
    );
    final labels = tickLabels(tester);
    expect(labels, [for (var v = 0; v <= 100; v += 10) '$v']);
    final xs = ticks(tester, 10);
    for (var i = 0; i <= 10; i++) {
      expect(
        tester.getCenter(find.byKey(Key('slider-tick-${i * 10}'))).dx,
        closeTo(xs[i], 1),
      );
    }
  });

  testWidgets('a slider whose steps would overlap shows only its bounds', (
    tester,
  ) async {
    await _pump(
      tester,
      1280,
      _SliderHost(reported: [], initial: 30, min: 0, max: 100),
      childWidth: 600,
    );
    expect(tickLabels(tester), ['0', '100']);
    expect(find.text('0'), findsOneWidget);
    expect(find.text('100'), findsOneWidget);
    final track = tester.getRect(find.byType(Slider));
    final first = tester.getRect(find.text('0'));
    final last = tester.getRect(find.text('100'));
    // Clamped inside the track ends.
    expect(first.left, greaterThanOrEqualTo(track.left));
    expect(last.right, lessThanOrEqualTo(track.right));
    expect(first.top, greaterThan(tester.getCenter(find.byType(Slider)).dy));
  });

  testWidgets('an unset slider shows its bounds under the track', (
    tester,
  ) async {
    await _pump(tester, 1280, _SliderHost(reported: []));
    final labels = tickLabels(tester);
    expect(labels.first, '1');
    expect(labels.last, '5');
    expect(labels.toSet().length, labels.length);
    expect(find.text('1'), findsOneWidget);
    expect(find.text('5'), findsOneWidget);
  });

  testWidgets('bounds fall back to the ends under a large text scale', (
    tester,
  ) async {
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await _pump(
      tester,
      1280,
      _SliderHost(reported: [], initial: 30, min: 0, max: 100, step: 10),
      childWidth: 300,
    );
    expect(tickLabels(tester), ['0', '100']);
  });

  testWidgets('an error renders below the label row and keeps the track', (
    tester,
  ) async {
    await _pump(tester, 1280, _SliderHost(key: const Key('a'), reported: []));
    final before = tester.getRect(find.byType(Slider)).top;
    await _pump(
      tester,
      1280,
      _SliderHost(
        key: const Key('b'),
        reported: [],
        errors: const ['Required'],
      ),
    );
    expect(tester.getRect(find.byType(Slider)).top, before);
    expect(
      tester.getRect(find.text('Required')).top,
      greaterThan(
        tester.getRect(find.byKey(const Key('slider-tick-5'))).bottom,
      ),
    );
  });

  testWidgets('a slider snaps drags to whole numbers inside the bounds', (
    tester,
  ) async {
    final reported = <int?>[];
    await _pump(tester, 1280, _SliderHost(reported: reported, initial: 1));
    final track = find.byType(Slider);
    final left = tester.getTopLeft(track);
    final width = tester.getSize(track).width;
    // Between 3 and 4 on the 1..5 track, a little past the halfway mark between them.
    await tester.tapAt(
      Offset(left.dx + width * 0.6, tester.getCenter(track).dy),
    );
    await tester.pump();
    expect(reported, isNotEmpty);
    expect(reported.last, anyOf(3, 4));
    expect(
      reported.every((value) => value is int && value >= 1 && value <= 5),
      isTrue,
    );
    expect(_value(tester), '${reported.last}');
    await tester.drag(track, const Offset(2000, 0));
    await tester.pump();
    expect(reported.last, 5);
    expect(_value(tester), '5');
  });

  testWidgets('a stepped slider reports only multiples of its step', (
    tester,
  ) async {
    final reported = <int?>[];
    await _pump(
      tester,
      1280,
      _SliderHost(reported: reported, initial: 0, min: 0, max: 100, step: 10),
    );
    final track = find.byType(Slider);
    final left = tester.getTopLeft(track);
    final width = tester.getSize(track).width;
    await tester.tapAt(
      Offset(left.dx + width * 0.37, tester.getCenter(track).dy),
    );
    await tester.pump();
    expect(reported.last, anyOf(30, 40));
    final gesture = await tester.startGesture(tester.getCenter(track));
    for (var i = 0; i < 12; i++) {
      await gesture.moveBy(const Offset(13, 0));
      await tester.pump();
    }
    await gesture.up();
    await tester.pump();
    expect(reported.length, greaterThan(1));
    expect(reported.every((value) => value! % 10 == 0), isTrue);
    expect(reported.every((value) => value! >= 0 && value <= 100), isTrue);
  });

  testWidgets('an unset slider shows the track and reports nothing until '
      'touched', (tester) async {
    final reported = <int?>[];
    await _pump(tester, 1280, _SliderHost(reported: reported));
    expect(find.byKey(const Key('slider-unset')), findsOneWidget);
    expect(find.byType(Slider), findsOneWidget);
    expect(find.byKey(const Key('slider-set')), findsNothing);
    expect(find.byKey(const Key('slider-value')), findsNothing);
    expect(find.byKey(const Key('slider-placeholder')), findsOneWidget);
    expect(reported, isEmpty);
    await tester.tap(find.byType(Slider));
    await tester.pump();
    expect(reported, [3]);
    expect(find.byKey(const Key('slider-value')), findsOneWidget);
    expect(_value(tester), '3');
  });

  testWidgets('the unset track spans the same width as the set track', (
    tester,
  ) async {
    await _pump(tester, 1280, _SliderHost(key: const Key('a'), reported: []));
    final unset = tester.getRect(find.byType(Slider));
    final reported = <int?>[];
    await _pump(
      tester,
      1280,
      _SliderHost(key: const Key('b'), reported: reported, initial: 2),
    );
    final set = tester.getRect(find.byType(Slider));
    expect(unset.left, set.left);
    // The set state gives up the clear icon's width at the trailing edge.
    expect(unset.width, greaterThanOrEqualTo(set.width));
    await _pump(
      tester,
      1280,
      _SliderHost(key: const Key('c'), reported: reported),
    );
    await tester.tapAt(unset.centerLeft + const Offset(1, 0));
    await tester.pump();
    expect(reported.last, 1);
  });

  testWidgets(
    'an optional slider clears back to unset; a required one cannot',
    (tester) async {
      final reported = <int?>[];
      await _pump(tester, 1280, _SliderHost(reported: reported, initial: 4));
      expect(_value(tester), '4');
      await tester.tap(find.byKey(const Key('slider-clear')));
      await tester.pump();
      expect(reported, [null]);
      expect(find.byKey(const Key('slider-unset')), findsOneWidget);

      await _pump(
        tester,
        1280,
        _SliderHost(reported: reported, initial: 4, required: true),
      );
      expect(find.byKey(const Key('slider-clear')), findsNothing);
    },
  );

  testWidgets('a slider shows its error lines and required marker', (
    tester,
  ) async {
    await _pump(
      tester,
      1280,
      _SliderHost(
        reported: [],
        required: true,
        errors: const ['Required', 'Must be between 1 and 5'],
      ),
    );
    expect(find.text('Required\nMust be between 1 and 5'), findsOneWidget);
    expect(find.bySemanticsLabel('Pain, required'), findsOneWidget);
    expect(_box(tester, find.byKey(const Key('input'))), 40 + _labelRow);
  });

  testWidgets('a required select reads "<label>, required"', (tester) async {
    await _pump(
      tester,
      1280,
      FiSelect<int>(
        label: 'Type',
        required: true,
        items: const [DropdownMenuItem(value: 1, child: Text('Text'))],
        onChanged: (_) {},
      ),
    );
    expect(find.bySemanticsLabel('Type, required'), findsOneWidget);
    expect(find.text(' *'), findsOneWidget);
  });
}
