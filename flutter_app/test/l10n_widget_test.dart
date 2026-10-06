import 'package:fi/platform_capabilities.dart';
import 'package:fi/src/rust/api/models.dart';
import 'package:fi/theme/nocturne_widgets.dart';
import 'package:fi/ui_prefs.dart';
import 'package:fi/voice/fakes.dart';
import 'package:fi/voice/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';

import 'fake_bridge.dart';
import 'widget_test.dart' show app, pumpUntilFound;

const _phone = Size(360, 780);
const _desktop = Size(1240, 900);
const _collection = 'headaches';
const _deviceId =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

FieldDefinitionDto _field(String id, FieldTypeKindDto kind, int order) =>
    FieldDefinitionDto(
      id: id,
      name: id,
      fieldType: FieldTypeDto(kind: kind),
      required_: order == 0,
      validation: const ValidationMetadataDto(),
      display: const DisplayMetadataDto(
        multiline: false,
        slider: false,
        sliderStep: null,
      ),
      order: order,
      deleted: false,
      enumOptions: const [],
    );

/// One collection with six records and one trusted device.
FakeCollectionBridge _bridge() {
  final bridge = FakeCollectionBridge()
    ..bootstrap = const BootstrapDto(
      kind: BootstrapKindDto.ready,
      rootId: 'root',
    );
  bridge.collections.add(
    const CollectionDto(
      id: _collection,
      name: 'Headaches',
      description: '',
      recordCount: 6,
      fieldCount: 2,
      incompleteCount: 1,
    ),
  );
  bridge.schemas[_collection] = CollectionSchemaDto(
    id: _collection,
    name: 'Headaches',
    description: '',
    fields: [
      _field('Title', FieldTypeKindDto.text, 0),
      _field('Intensity', FieldTypeKindDto.integer, 1),
    ],
  );
  bridge.records[_collection] = [
    for (var i = 0; i < 6; i++)
      RecordDto(
        id: 'record-$i',
        collectionId: _collection,
        values: [
          RecordValueDto(
            fieldId: 'Title',
            value: FieldValueDto(
              kind: FieldValueKindDto.text,
              textValue: 'Entry $i',
            ),
          ),
        ],
        valid: true,
        diagnostics: const [],
        createdAtMs: DateTime(2026, 9, 20 + i).millisecondsSinceEpoch,
      ),
  ];
  bridge.devices.add(
    const TrustedDeviceDto(
      deviceId: _deviceId,
      friendlyName: 'Laptop',
      pairedAtMs: 1,
      revoked: false,
      connection: PeerConnectionKindDto.synced,
    ),
  );
  return bridge;
}

Future<void> _pump(
  WidgetTester tester,
  Size size, {
  FakeCollectionBridge? bridge,
  PlatformCapabilities? capabilities,
  VoiceServices? voice,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    app(
      bridge ?? _bridge(),
      uiPrefs: MemoryUiPrefsStore(
        const UiPrefs(appLanguage: AppLanguage.spanish),
      ),
      capabilities: capabilities,
      voice: voice,
    ),
  );
  await pumpUntilFound(tester, find.text('Colecciones'));
  await tester.pumpAndSettle();
}

Future<void> _open(WidgetTester tester, Size size, String destination) async {
  final label = switch (destination) {
    'devices' => 'Dispositivos',
    'settings' => 'Ajustes',
    _ => 'Colecciones',
  };
  await tester.tap(
    find.descendant(
      of: size.width >= 720
          ? find.byKey(const Key('sidebar'))
          : find.byType(NavigationBar),
      matching: find.text(label),
    ),
  );
  await tester.pumpAndSettle();
}

/// No overflow was reported, and no button, tag, navigation label or sidebar row
/// text was cut short.
void _expectFits(WidgetTester tester) {
  expect(tester.takeException(), isNull);
  final containers = [
    find.byWidgetPredicate((widget) => widget is ButtonStyleButton),
    find.byType(Tag),
    find.byType(NavigationDestination),
    find.byKey(const Key('sidebar')),
  ];
  for (final container in containers) {
    final paragraphs = find.descendant(
      of: container,
      matching: find.byType(RichText),
    );
    for (final element in paragraphs.evaluate()) {
      final paragraph = element.renderObject! as RenderParagraph;
      expect(
        paragraph.didExceedMaxLines,
        isFalse,
        reason: 'cut short: "${paragraph.text.toPlainText()}"',
      );
    }
  }
}

void main() {
  tearDown(() => Intl.defaultLocale = null);

  for (final size in [_phone, _desktop]) {
    final width = size.width.toInt();

    testWidgets('Spanish collections list fits at $width', (tester) async {
      await _pump(tester, size);
      expect(find.text('Colecciones'), findsWidgets);
      expect(find.text('Headaches'), findsWidgets);
      _expectFits(tester);
    });

    testWidgets('Spanish devices fit at $width', (tester) async {
      await _pump(tester, size);
      await _open(tester, size, 'devices');
      expect(find.text('Laptop'), findsWidgets);
      _expectFits(tester);
    });

    testWidgets('Spanish pairing card fits at $width', (tester) async {
      final bridge = _bridge();
      await _pump(tester, size, bridge: bridge);
      await _open(tester, size, 'devices');
      bridge.pairingController.add(
        PairingStateDto(
          kind: PairingKindDto.discoverable,
          deadlineMs: DateTime.now().millisecondsSinceEpoch + 120000,
          localConfirmed: false,
          remoteConfirmed: false,
          alreadyPaired: false,
        ),
      );
      bridge.candidateController.add([
        PairingCandidateDto(
          instanceId: List.filled(16, '01').join(),
          endpoint: '192.168.0.165:47380',
          expiresAtMs: DateTime.now().millisecondsSinceEpoch + 10000,
          alreadyPaired: false,
        ),
      ]);
      await tester.pump();
      await tester.pump();
      expect(find.text('El emparejamiento está abierto'), findsOneWidget);
      expect(find.text('192.168.0.165:47380'), findsOneWidget);
      _expectFits(tester);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('Spanish pairing confirmation fits at $width', (tester) async {
      final bridge = _bridge();
      await _pump(tester, size, bridge: bridge);
      await _open(tester, size, 'devices');
      bridge.pairingController.add(
        const PairingStateDto(
          kind: PairingKindDto.awaitingConfirmation,
          sessionId: 'session',
          sas: '42',
          peerDeviceId: _deviceId,
          localConfirmed: false,
          remoteConfirmed: false,
          alreadyPaired: false,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('pairing-sas')), findsOneWidget);
      expect(find.text('Confirmar el código'), findsOneWidget);
      expect(find.text('Rechazar'), findsOneWidget);
      _expectFits(tester);
    });
  }

  testWidgets('Spanish Android settings fit with voice ready', (tester) async {
    await _pump(
      tester,
      const Size(360, 2400),
      capabilities: PlatformCapabilities.androidPhone,
      voice: fakeVoiceServices(),
    );
    await _open(tester, _phone, 'settings');
    expect(find.text('Ajustes'), findsWidgets);
    expect(find.text('IDIOMA'), findsOneWidget);
    expect(find.text('Volver a descargar'), findsOneWidget);
    _expectFits(tester);
  });

  testWidgets('Spanish Android settings fit while downloading', (tester) async {
    await _pump(
      tester,
      const Size(360, 2400),
      capabilities: PlatformCapabilities.androidPhone,
      voice: fakeVoiceServices(
        models: FakeVoiceModels(
          modelStatusOf(
            ModelStatusKindDto.downloading,
            done: 612000000,
            secondsLeft: 240,
          ),
        ),
      ),
    );
    await _open(tester, _phone, 'settings');
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('IDIOMA'), findsOneWidget);
    _expectFits(tester);
  });

  testWidgets('Spanish desktop settings fit', (tester) async {
    await _pump(tester, _desktop, capabilities: PlatformCapabilities.desktop);
    await _open(tester, _desktop, 'settings');
    expect(find.text('Idioma de la app'), findsOneWidget);
    _expectFits(tester);
  });

  testWidgets('Spanish new record sheet with the voice offer fits', (
    tester,
  ) async {
    await _pump(
      tester,
      _phone,
      capabilities: PlatformCapabilities.androidPhone,
      voice: fakeVoiceServices(
        models: FakeVoiceModels(
          modelStatusOf(ModelStatusKindDto.notDownloaded),
        ),
      ),
    );
    await tester.tap(find.text('Headaches').first);
    await tester.pumpAndSettle();
    final tip = find.byTooltip('Nuevo registro');
    await tester.tap(
      tip.evaluate().isNotEmpty ? tip.first : find.text('Nuevo registro').first,
    );
    await tester.pumpAndSettle();
    _expectFits(tester);
    await tester.tap(find.byKey(const Key('voice-mic')));
    await tester.pumpAndSettle();
    expect(find.text('Descargar modelos de voz'), findsOneWidget);
    _expectFits(tester);
  });
}
