import 'dart:async';
import 'dart:convert';

import 'package:fi/collections_page.dart';
import 'package:fi/controllers.dart';
import 'package:fi/l10n/l10n.dart';
import 'package:fi/location/format.dart';
import 'package:fi/location/location_field.dart';
import 'package:fi/location/map_picker.dart';
import 'package:fi/location/services.dart';
import 'package:fi/location/tile_cache.dart';
import 'package:fi/location/type_coordinates_sheet.dart';
import 'package:fi/src/rust/api/models.dart';
import 'package:fi/voice/services.dart' show NetworkInfo, NetworkKind;
import 'package:fi/widgets/query_builder.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_bridge.dart';

final Uint8List _samplePng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
);

class _FakeNetworkInfo implements NetworkInfo {
  _FakeNetworkInfo(this.kind);
  NetworkKind kind;

  @override
  Future<NetworkKind> current() async => kind;
}

class _FakeLocationServices implements LocationServices {
  _FakeLocationServices({
    NetworkKind network = NetworkKind.wifi,
    this.isAndroid = true,
    this.status = const DeviceLocationStatus(
      permission: LocationPermissionState.grantedPrecise,
      servicesEnabled: true,
      isAndroid: true,
    ),
    DeviceLocationStatus? statusAfterRequest,
    bool tilesAvailable = true,
  })  : _network = _FakeNetworkInfo(network),
        _statusAfterRequest = statusAfterRequest {
    tileCache = MapTileCache(
      networkInfo: _network,
      cacheDirectoryProvider: () async => null,
      downloader: (_) async => tilesAvailable ? _samplePng : null,
    );
  }

  final _FakeNetworkInfo _network;
  @override
  late final MapTileCache tileCache;
  @override
  NetworkInfo get networkInfo => _network;

  @override
  bool isAndroid;

  bool _primerShown = false;
  @override
  bool get primerShown => _primerShown;
  @override
  void markPrimerShown() => _primerShown = true;

  @override
  LocationValueDto? lastSessionLocation;

  DeviceLocationStatus status;
  final DeviceLocationStatus? _statusAfterRequest;
  int requestPermissionCalls = 0;
  int openLocationSettingsCalls = 0;
  int openAppSettingsCalls = 0;
  final List<(String url, bool chooser)> openedUrls = [];

  StreamController<LocationFix>? fixController;
  List<PlaceSearchResult> searchResults = const [];
  bool searchOffline = false;
  String? reverseHint;
  String? resolvedShortUrl;
  bool shortLinkOffline = false;

  @override
  Future<DeviceLocationStatus> locationStatus() async => status;

  @override
  Future<DeviceLocationStatus> requestLocationPermission() async {
    requestPermissionCalls++;
    if (_statusAfterRequest != null) {
      status = _statusAfterRequest;
    }
    return status;
  }

  @override
  Future<void> openLocationSettings() async {
    openLocationSettingsCalls++;
  }

  @override
  Future<void> openAppSettings() async {
    openAppSettingsCalls++;
  }

  @override
  Stream<LocationFix> watchLocationFixes() {
    fixController ??= StreamController<LocationFix>.broadcast();
    return fixController!.stream;
  }

  @override
  Future<void> openExternalUrl(String url, {bool chooser = false}) async {
    openedUrls.add((url, chooser));
  }

  @override
  ParsedLocationDto parseLocationText(String input) =>
      parseLocationFallback(input);

  @override
  Future<ShortLinkResolutionResult> resolveShortMapLink(String url) async =>
      ShortLinkResolutionResult(
        resolvedUrl: resolvedShortUrl,
        offline: shortLinkOffline,
      );

  @override
  Future<PlaceSearchResponse> searchPlaces(
    String query, {
    required double biasLat,
    required double biasLng,
  }) async =>
      PlaceSearchResponse(results: searchResults, offline: searchOffline);

  @override
  Future<String?> reverseGeocode(double lat, double lng) async => reverseHint;
}

FieldDefinitionDto _locationField({
  String id = 'loc-1',
  String name = 'Place',
  bool required = false,
  bool showMapPreview = true,
}) =>
    FieldDefinitionDto(
      id: id,
      name: name,
      fieldType: const FieldTypeDto(kind: FieldTypeKindDto.location),
      required_: required,
      validation: const ValidationMetadataDto(),
      display: DisplayMetadataDto(
        multiline: false,
        slider: false,
        showMapPreview: showMapPreview,
      ),
      order: 0,
      deleted: false,
      enumOptions: const [],
    );

Widget _wrapApp(Widget child, {required LocationServices services}) =>
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: LocationScope(
        services: services,
        child: Scaffold(body: child),
      ),
    );

void main() {
  group('Task 4.1 — Schema editor Location field', () {
    testWidgets('creates and edits a Location field with Show map preview chip',
        (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1200, 1400);

      final bridge = FakeCollectionBridge()
        ..bootstrap = const BootstrapDto(
          kind: BootstrapKindDto.ready,
          rootId: 'root',
        );
      final controller = CollectionsController(bridge);
      addTearDown(controller.dispose);
      await controller.start();
      final collectionId = await controller.createCollection('Places');
      await controller.selectCollection(collectionId);

      await tester.pumpWidget(
        _wrapApp(
          ListenableBuilder(
            listenable: controller,
            builder: (context, _) => CollectionsPage(controller: controller),
          ),
          services: _FakeLocationServices(),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Schema'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add field'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const Key('field-name')), 'Spot');
      await tester.tap(find.byKey(const Key('type-location')));
      await tester.pumpAndSettle();

      // Required and Show map preview chips present; Default value absent; helper shown.
      expect(find.byKey(const Key('chip-required')), findsOneWidget);
      expect(find.byKey(const Key('chip-show-map-preview')), findsOneWidget);
      expect(find.byKey(const Key('chip-default')), findsNothing);
      expect(
        find.byKey(const Key('location-map-preview-help')),
        findsOneWidget,
      );

      // Toggle Show map preview off and save.
      await tester.tap(find.byKey(const Key('chip-show-map-preview')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('field-save')));
      await tester.pumpAndSettle();

      final saved =
          controller.schema!.fields.firstWhere((f) => f.name == 'Spot');
      expect(saved.fieldType.kind, FieldTypeKindDto.location);
      expect(saved.display.showMapPreview, isFalse);
    });
  });

  group('Task 4.2 — Location record form states & permission primer', () {
    testWidgets('empty -> locating -> populated with preview, copy, and clear',
        (tester) async {
      final services = _FakeLocationServices();
      FieldValueDto? current;
      late StateSetter outerSetState;

      await tester.pumpWidget(
        _wrapApp(
          StatefulBuilder(
            builder: (context, setState) {
              outerSetState = setState;
              return Padding(
                padding: const EdgeInsets.all(16),
                child: LocationFieldInput(
                  field: _locationField(),
                  value: current,
                  onChanged: (v) => setState(() => current = v),
                ),
              );
            },
          ),
          services: services,
        ),
      );
      await tester.pumpAndSettle();

      // State 1: Empty.
      expect(find.text('Current location'), findsOneWidget);
      expect(find.text('Pick on map'), findsOneWidget);

      // Tap Current location -> State 2: Locating.
      await tester.tap(find.byKey(const Key('location-current-loc-1')));
      await tester.pump();
      expect(find.byKey(const Key('location-locating-loc-1')), findsOneWidget);
      expect(find.text('Finding you…'), findsOneWidget);

      // Emit coarse accuracy (> 25m) -> stays locating with countdown.
      services.fixController!.add(
        const LocationFix(latitude: 38.7108, longitude: -9.1372, accuracyMeters: 42),
      );
      await tester.pump();
      expect(find.text('Finding you… ±42 m'), findsOneWidget);

      // Emit precise fix (<= 25m) -> transitions to State 3: Populated with preview.
      services.fixController!.add(
        const LocationFix(
          latitude: 38.710841,
          longitude: -9.137265,
          accuracyMeters: 12,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('38.710841, -9.137265'), findsOneWidget);
      expect(find.text('±12 m'), findsOneWidget);
      expect(find.byKey(const Key('location-clear-loc-1')), findsOneWidget);
      expect(find.text('Move pin'), findsOneWidget);

      // Clear returns to Empty.
      await tester.tap(find.byKey(const Key('location-clear-loc-1')));
      await tester.pumpAndSettle();
      expect(current, isNull);
      expect(find.text('Pick on map'), findsOneWidget);

      // Keep outerSetState referenced.
      outerSetState(() {});
    });

    testWidgets('preview off renders compact single row without 132px map',
        (tester) async {
      final services = _FakeLocationServices();
      const val = FieldValueDto(
        kind: FieldValueKindDto.location,
        locationValue: LocationValueDto(
          latitudeMicrodeg: 38710841,
          longitudeMicrodeg: -9137265,
          approximate: false,
        ),
      );
      await tester.pumpWidget(
        _wrapApp(
          LocationFieldInput(
            field: _locationField(showMapPreview: false),
            value: val,
            onChanged: (_) {},
          ),
          services: services,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('location-compact-row-loc-1')), findsOneWidget);
      expect(find.byKey(const Key('location-preview-map-loc-1')), findsNothing);
      expect(find.text('38.710841, -9.137265'), findsOneWidget);
      expect(find.byKey(const Key('location-clear-loc-1')), findsOneWidget);
    });

    testWidgets('offline renders Map needs internet placeholder', (tester) async {
      final services = _FakeLocationServices(
        network: NetworkKind.none,
        tilesAvailable: false,
      );
      const val = FieldValueDto(
        kind: FieldValueKindDto.location,
        locationValue: LocationValueDto(
          latitudeMicrodeg: 38710841,
          longitudeMicrodeg: -9137265,
          approximate: false,
        ),
      );
      await tester.pumpWidget(
        _wrapApp(
          LocationFieldInput(
            field: _locationField(showMapPreview: true),
            value: val,
            onChanged: (_) {},
          ),
          services: services,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Map needs internet'), findsOneWidget);
      expect(find.text('38.710841, -9.137265'), findsOneWidget);
    });

    testWidgets('inline Android permission primer, permission off, device off, approximate, and required',
        (tester) async {
      // Primer shown on first tap when Android permission not granted.
      final primerServices = _FakeLocationServices(
        isAndroid: true,
        status: const DeviceLocationStatus(
          permission: LocationPermissionState.denied,
          servicesEnabled: true,
          isAndroid: true,
        ),
        statusAfterRequest: const DeviceLocationStatus(
          permission: LocationPermissionState.denied,
          servicesEnabled: true,
          isAndroid: true,
        ),
      );

      await tester.pumpWidget(
        _wrapApp(
          LocationFieldInput(
            field: _locationField(),
            value: null,
            onChanged: (_) {},
          ),
          services: primerServices,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('location-current-loc-1')));
      await tester.pumpAndSettle();
      expect(find.text('Save where you are'), findsOneWidget);
      expect(primerServices.requestPermissionCalls, 0);

      // Not now dismisses without requesting OS permission.
      await tester.tap(find.byKey(const Key('location-primer-not-now')));
      await tester.pumpAndSettle();
      expect(find.text('Save where you are'), findsNothing);
      expect(primerServices.requestPermissionCalls, 0);

      // Tap again -> Continue triggers request -> denied -> Permission off alert.
      await tester.tap(find.byKey(const Key('location-current-loc-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('location-primer-continue')));
      await tester.pumpAndSettle();
      expect(primerServices.requestPermissionCalls, 1);
      expect(find.text('Location access is off for Fi'), findsOneWidget);
      expect(find.text('Settings'), findsOneWidget);

      // State 7: Device location off.
      final deviceOffServices = _FakeLocationServices(
        isAndroid: true,
        status: const DeviceLocationStatus(
          permission: LocationPermissionState.grantedPrecise,
          servicesEnabled: false,
          isAndroid: true,
        ),
      );
      await tester.pumpWidget(
        _wrapApp(
          LocationFieldInput(
            field: _locationField(),
            value: null,
            onChanged: (_) {},
          ),
          services: deviceOffServices,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('location-current-loc-1')));
      await tester.pumpAndSettle();
      expect(find.text('Location is off on this phone'), findsOneWidget);
      expect(find.text('Turn on'), findsOneWidget);

      // State 8 & 9: Approximate warning + Required hides clear button & shows Required error.
      const approxVal = FieldValueDto(
        kind: FieldValueKindDto.location,
        locationValue: LocationValueDto(
          latitudeMicrodeg: 38710200,
          longitudeMicrodeg: -9138000,
          accuracyMeters: 1900,
          approximate: true,
        ),
      );
      await tester.pumpWidget(
        _wrapApp(
          LocationFieldInput(
            field: _locationField(required: true),
            value: approxVal,
            onChanged: (_) {},
            errors: const ['Required'],
          ),
          services: _FakeLocationServices(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('38.7102, -9.1380'), findsOneWidget);
      expect(find.text('±1.9 km'), findsOneWidget);
      expect(
        find.text('Approximate location. The pin may be off by streets.'),
        findsOneWidget,
      );
      expect(find.text('Allow precise'), findsOneWidget);
      expect(find.byKey(const Key('location-clear-loc-1')), findsNothing);
      expect(find.text('Required'), findsOneWidget);
    });
  });

  group('Task 4.3 — Map picker, Place search, and Type coordinates', () {
    testWidgets('Map picker search, reverse hint, and Use this spot',
        (tester) async {
      final services = _FakeLocationServices()
        ..reverseHint = 'Rua Augusta, Lisboa'
        ..searchResults = const [
          PlaceSearchResult(
            name: 'Time Out Market Lisboa',
            subtitle: 'Av. 24 de Julho, Lisboa',
            latitude: 38.7071,
            longitude: -9.1460,
            distanceMeters: 850,
          ),
        ];

      LocationValueDto? picked;
      await tester.pumpWidget(
        _wrapApp(
          Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                picked = await showLocationMapPicker(
                  context,
                  fieldName: 'Place',
                  userLocation: const LocationValueDto(
                    latitudeMicrodeg: 38713900,
                    longitudeMicrodeg: -9133400,
                    approximate: false,
                  ),
                );
              },
              child: const Text('Open picker'),
            ),
          ),
          services: services,
        ),
      );
      await tester.tap(find.text('Open picker'));
      await tester.pumpAndSettle(const Duration(milliseconds: 500));

      expect(find.text('Drag the map; the pin stays put'), findsOneWidget);
      expect(find.byKey(const Key('map-picker-recenter')), findsOneWidget);
      expect(find.textContaining('Rua Augusta, Lisboa'), findsOneWidget);

      // Open Place Search and pick a result.
      await tester.tap(find.byKey(const Key('map-picker-search-pill')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('place-search-input')),
        'time o',
      );
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('place-search-result-0')));
      await tester.pumpAndSettle(const Duration(milliseconds: 500));

      expect(find.text('38.707100, -9.146000'), findsOneWidget);

      // Confirm with Use this spot.
      await tester.tap(find.byKey(const Key('map-picker-confirm')));
      await tester.pumpAndSettle();
      expect(picked, isNotNull);
      expect(picked!.latitudeMicrodeg, 38707100);
      expect(picked!.longitudeMicrodeg, -9146000);
      expect(picked!.accuracyMeters, isNull);
    });

    testWidgets('Type coordinates sheet parses link, DMS, short link, and validates range',
        (tester) async {
      final services = _FakeLocationServices()
        ..resolvedShortUrl =
            'https://www.google.com/maps/place/Lisbon/@38.7139,-9.1334,16z';

      LocationValueDto? result;
      await tester.pumpWidget(
        _wrapApp(
          Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                result = await showTypeCoordinatesSheet(context);
              },
              child: const Text('Open type'),
            ),
          ),
          services: services,
        ),
      );

      await tester.tap(find.text('Open type'));
      await tester.pumpAndSettle();

      // Out-of-range latitude shows error and disables Show on map.
      await tester.enterText(
        find.byKey(const Key('location-paste-input')),
        '95.0, -9.1334',
      );
      await tester.pump();
      expect(find.text('Latitude goes from -90 to 90'), findsOneWidget);
      final disabledBtn = tester.widget<FilledButton>(
        find.byKey(const Key('location-show-on-map')),
      );
      expect(disabledBtn.onPressed, isNull);

      // Paste full Google Maps link -> shows Found and populates Lat/Lng.
      await tester.enterText(
        find.byKey(const Key('location-paste-input')),
        'maps.google.com/?q=38.7139,-9.1334',
      );
      await tester.pump();
      expect(find.text('Found 38.713900, -9.133400'), findsOneWidget);

      // Paste DMS -> converts accurately.
      await tester.enterText(
        find.byKey(const Key('location-paste-input')),
        '38°42\'50"N 9°08\'00"W',
      );
      await tester.pump();
      expect(find.text('Found 38.713889, -9.133333'), findsOneWidget);

      // Paste short link -> resolves via service.
      await tester.enterText(
        find.byKey(const Key('location-paste-input')),
        'https://maps.app.goo.gl/Hxixt5WMth3JkB8J7f',
      );
      await tester.pumpAndSettle();
      expect(find.text('Found 38.713900, -9.133400'), findsOneWidget);

      await tester.tap(find.byKey(const Key('location-show-on-map')));
      await tester.pumpAndSettle();
      expect(result, isNotNull);
      expect(result!.latitudeMicrodeg, 38713900);
      expect(result!.longitudeMicrodeg, -9133400);
    });

    testWidgets('Type coordinates bottom sheet clears Android navigation bar on phone',
        (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPadding);
      addTearDown(tester.view.resetViewPadding);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      tester.view.padding = const FakeViewPadding(bottom: 48);
      tester.view.viewPadding = const FakeViewPadding(bottom: 48);

      final services = _FakeLocationServices();
      await tester.pumpWidget(
        _wrapApp(
          Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => showTypeCoordinatesSheet(context),
              child: const Text('Open type'),
            ),
          ),
          services: services,
        ),
      );

      await tester.tap(find.text('Open type'));
      await tester.pumpAndSettle();

      final buttonRect =
          tester.getRect(find.byKey(const Key('location-show-on-map')));
      expect(buttonRect.bottom, lessThanOrEqualTo(844 - 48));
    });
  });

  group('Task 4.4 — View mode (desktop table & mobile card) and presence filters',
      () {
    testWidgets('Desktop table cell displays 4dp, hover buttons, and Open in menu with 6dp copy',
        (tester) async {
      final services = _FakeLocationServices(isAndroid: false);
      String? copiedText;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copiedText = (call.arguments as Map)['text'] as String?;
        }
        return null;
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
      });

      const loc = LocationValueDto(
        latitudeMicrodeg: 38710841,
        longitudeMicrodeg: -9137265,
        approximate: false,
      );
      await tester.pumpWidget(
        _wrapApp(
          const SizedBox(
            width: 260,
            child: LocationTableCell(location: loc),
          ),
          services: services,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('38.7108, -9.1373'), findsOneWidget);

      // Hover reveals Google Maps and Waze quick buttons.
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await gesture.moveTo(tester.getCenter(find.byType(LocationTableCell)));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('location-table-google-maps')), findsOneWidget);
      expect(find.byKey(const Key('location-table-waze')), findsOneWidget);

      // Click coordinates opens Open in menu -> Copy coordinates copies 6dp.
      await tester.tap(find.byKey(const Key('location-table-coords')));
      await tester.pumpAndSettle();
      expect(find.text('Open in Google Maps'), findsOneWidget);
      expect(find.text('Navigate with Waze'), findsOneWidget);
      expect(find.text('Copy coordinates'), findsOneWidget);

      await tester.tap(find.text('Copy coordinates'));
      await tester.pumpAndSettle();
      expect(copiedText, '38.710841, -9.137265');
    });

    testWidgets('Mobile record card shows 64×64 thumbnail, 4dp coords, and Google Maps / Waze buttons',
        (tester) async {
      final services = _FakeLocationServices(isAndroid: true);
      const loc = LocationValueDto(
        latitudeMicrodeg: 38713900,
        longitudeMicrodeg: -9133400,
        approximate: false,
      );

      await tester.pumpWidget(
        _wrapApp(
          const Padding(
            padding: EdgeInsets.all(16),
            child: LocationCardView(
              fieldName: 'Place',
              location: loc,
              showMapPreview: true,
            ),
          ),
          services: services,
        ),
      );
      await tester.pumpAndSettle();

      final thumb = tester.getSize(find.byKey(const Key('location-card-thumbnail')));
      expect(thumb, const Size(64, 64));
      expect(find.text('38.7139, -9.1334'), findsOneWidget);
      expect(find.text('Google Maps'), findsOneWidget);
      expect(find.text('Waze'), findsOneWidget);

      await tester.tap(find.byKey(const Key('location-card-waze')));
      await tester.pump();
      expect(
        services.openedUrls.single.$1,
        'https://waze.com/ul?ll=38.713900,-9.133400&navigate=yes',
      );
    });

    test('Query builder offers only isEmpty / isNotEmpty for Location fields', () {
      expect(
        ChoicesFilterOperator.offeredFor(FieldTypeKindDto.location),
        const [ChoicesFilterOperator.isEmpty, ChoicesFilterOperator.isNotEmpty],
      );
      expect(isChoicesFilterKind(FieldTypeKindDto.location), isTrue);

      final schema = CollectionSchemaDto(
        id: 'col-1',
        name: 'Places',
        description: '',
        fields: [_locationField()],
      );
      final state = QueryBuilderState(
        filterFieldId: 'loc-1',
        filterChoices: true,
        choicesOperator: ChoicesFilterOperator.isNotEmpty,
      );
      final expr = state.filterExpression(schema, '.');
      expect(expr, isNotNull);
      expect(expr!.nodes.last.kind, ExpressionKindDto.isNotNull);
    });
  });
}
