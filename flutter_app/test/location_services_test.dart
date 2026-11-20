import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fi/location/format.dart';
import 'package:fi/location/services.dart';
import 'package:fi/location/tile_cache.dart';
import 'package:fi/src/rust/api/models.dart';
import 'package:fi/voice/services.dart' show NetworkInfo, NetworkKind;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeNetworkInfo implements NetworkInfo {
  _FakeNetworkInfo(this.kind);
  NetworkKind kind;

  @override
  Future<NetworkKind> current() async => kind;
}

/// Minimal valid 1×1 transparent PNG.
final Uint8List _samplePng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Android platform channel & Linux desktop LocationServices', () {
    const channel = MethodChannel('fi/platform');
    final recordedCalls = <MethodCall>[];

    setUp(() {
      recordedCalls.clear();
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('Android location status, permission request, fix stream, and external URL intents',
        () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        recordedCalls.add(call);
        switch (call.method) {
          case 'locationStatus':
            return <String, Object>{
              'fine': false,
              'coarse': true,
              'servicesEnabled': true,
              'shouldShowRationale': false,
            };
          case 'requestLocationPermission':
            return <String, Object>{
              'fine': true,
              'coarse': true,
              'servicesEnabled': true,
              'shouldShowRationale': false,
            };
          case 'startLocationFix':
            // Simulate Android pushing a GPS fix back over the channel.
            scheduleMicrotask(() async {
              final codec = const StandardMethodCodec();
              final data = codec.encodeMethodCall(
                const MethodCall('onLocationFix', <String, Object>{
                  'lat': 38.710841,
                  'lng': -9.137265,
                  'accuracy': 12.0,
                  'approximate': false,
                }),
              );
              await TestDefaultBinaryMessengerBinding
                  .instance.defaultBinaryMessenger
                  .handlePlatformMessage(channel.name, data, (_) {});
            });
            return null;
          default:
            return null;
        }
      });

      final services = PlatformLocationServices(
        channel: channel,
        networkInfo: _FakeNetworkInfo(NetworkKind.wifi),
        isAndroidOverride: true,
      );

      final initial = await services.locationStatus();
      expect(initial.permission, LocationPermissionState.grantedApproximate);
      expect(initial.isApproximateOnly, isTrue);
      expect(initial.servicesEnabled, isTrue);

      final upgraded = await services.requestLocationPermission();
      expect(upgraded.permission, LocationPermissionState.grantedPrecise);

      final fix = await services.watchLocationFixes().first;
      expect(fix.latitude, closeTo(38.710841, 1e-6));
      expect(fix.longitude, closeTo(-9.137265, 1e-6));
      expect(fix.accuracyMeters, 12);
      expect(fix.approximate, isFalse);

      await services.openExternalUrl('geo:38.710841,-9.137265', chooser: true);
      expect(
        recordedCalls.any(
          (c) =>
              c.method == 'openExternalUrl' &&
              (c.arguments as Map)['chooser'] == true,
        ),
        isTrue,
      );
      expect(recordedCalls.any((c) => c.method == 'stopLocationFix'), isTrue);
    });

    test('Linux desktop openExternalUrl uses opener callback', () async {
      final opened = <String>[];
      final services = PlatformLocationServices(
        channel: channel,
        networkInfo: _FakeNetworkInfo(NetworkKind.wifi),
        isAndroidOverride: false,
        linuxOpener: (url) async => opened.add(url),
      );

      await services.openExternalUrl('https://waze.com/ul?ll=38.71,-9.13');
      expect(opened, ['https://waze.com/ul?ll=38.71,-9.13']);
    });
  });

  group('Short-link redirect resolution & coordinate formatting', () {
    test('resolveShortMapLink follows redirect header to full Google Maps URL',
        () async {
      final previousOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      addTearDown(() => HttpOverrides.global = previousOverrides);

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      server.listen((req) async {
        req.response.statusCode = HttpStatus.found;
        req.response.headers.set(
          HttpHeaders.locationHeader,
          'https://www.google.com/maps/place/Lisbon/@38.7139,-9.1334,16z',
        );
        await req.response.close();
      });

      final services = PlatformLocationServices(
        networkInfo: _FakeNetworkInfo(NetworkKind.wifi),
        isAndroidOverride: false,
      );
      final res = await services.resolveShortMapLink(
        'http://127.0.0.1:${server.port}/short',
      );
      expect(res.offline, isFalse);
      expect(
        res.resolvedUrl,
        'https://www.google.com/maps/place/Lisbon/@38.7139,-9.1334,16z',
      );

      final parsed = services.parseLocationText(res.resolvedUrl!);
      expect(parsed.status, LocationParseStatusDto.ok);
      expect(parsed.value!.latitudeMicrodeg, 38713900);
      expect(parsed.value!.longitudeMicrodeg, -9133400);
    });

    test('resolveShortMapLink reports offline when network is none', () async {
      final services = PlatformLocationServices(
        networkInfo: _FakeNetworkInfo(NetworkKind.none),
        isAndroidOverride: false,
      );
      final res = await services
          .resolveShortMapLink('https://maps.app.goo.gl/Hxixt5WMth3JkB8J7f');
      expect(res.offline, isTrue);
      expect(res.resolvedUrl, isNull);
    });

    test('searchPlaces returns offline immediately when network is none',
        () async {
      final services = PlatformLocationServices(
        networkInfo: _FakeNetworkInfo(NetworkKind.none),
        isAndroidOverride: false,
      );
      final res = await services.searchPlaces(
        'time out',
        biasLat: 38.7139,
        biasLng: -9.1334,
      );
      expect(res.offline, isTrue);
      expect(res.results, isEmpty);
    });

    test('format helpers produce exact 6dp, 4dp, accuracy, and external URLs',
        () {
      const loc = LocationValueDto(
        latitudeMicrodeg: 38710841,
        longitudeMicrodeg: -9137265,
        accuracyMeters: 12,
        approximate: false,
      );
      expect(formatLocation6dp(loc), '38.710841, -9.137265');
      expect(formatLocation4dp(loc), '38.7108, -9.1373');
      expect(formatAccuracy(12), '12 m');
      expect(formatAccuracy(1900), '1.9 km');
      expect(
        googleMapsUrl(loc),
        'https://www.google.com/maps/search/?api=1&query=38.710841,-9.137265',
      );
      expect(
        wazeUrl(loc),
        'https://waze.com/ul?ll=38.710841,-9.137265&navigate=yes',
      );
      expect(geoUri(loc), 'geo:38.710841,-9.137265?q=38.710841,-9.137265');
    });
  });

  group('MapTileCache persistence, LRU eviction, and mobile-data safeguard', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('fi_tile_cache_test_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('cached tile persists to disk and serves offline with 0 downloads',
        () async {
      final net = _FakeNetworkInfo(NetworkKind.wifi);
      var downloads = 0;
      final cache1 = MapTileCache(
        networkInfo: net,
        cacheDirectoryProvider: () async => tempDir,
        downloader: (_) async {
          downloads++;
          return _samplePng;
        },
      );

      const coord = TileCoord(15, 15548, 12543);
      final first = await cache1.getTile(coord, allowMeteredNetwork: false);
      expect(first.kind, TileFetchOutcomeKind.fetched);
      expect(first.hasBytes, isTrue);
      expect(downloads, 1);

      // New cache instance simulating app restart while offline.
      net.kind = NetworkKind.none;
      final cache2 = MapTileCache(
        networkInfo: net,
        cacheDirectoryProvider: () async => tempDir,
        downloader: (_) async {
          downloads++;
          return _samplePng;
        },
      );
      final fromDisk = await cache2.getTile(coord, allowMeteredNetwork: false);
      expect(fromDisk.kind, TileFetchOutcomeKind.hitDisk);
      expect(fromDisk.bytes, _samplePng);
      expect(downloads, 1);
    });

    test('mobile data blocks uncached card thumbnails but allows form/picker fetches',
        () async {
      final net = _FakeNetworkInfo(NetworkKind.mobile);
      var downloads = 0;
      final cache = MapTileCache(
        networkInfo: net,
        cacheDirectoryProvider: () async => tempDir,
        downloader: (_) async {
          downloads++;
          return _samplePng;
        },
      );

      const coord = TileCoord(15, 15549, 12543);
      final blocked = await cache.getTile(coord, allowMeteredNetwork: false);
      expect(blocked.kind, TileFetchOutcomeKind.blockedMetered);
      expect(blocked.hasBytes, isFalse);
      expect(downloads, 0);

      // Active form/picker flow IS allowed on mobile data.
      final allowed = await cache.getTile(coord, allowMeteredNetwork: true);
      expect(allowed.kind, TileFetchOutcomeKind.fetched);
      expect(allowed.hasBytes, isTrue);
      expect(downloads, 1);

      // Once cached, even passive card thumbnails render immediately on mobile data.
      final cachedOnMobile =
          await cache.getTile(coord, allowMeteredNetwork: false);
      expect(cachedOnMobile.kind, TileFetchOutcomeKind.hitMemory);
      expect(downloads, 1);
    });

    test('LRU eviction trims disk cache when exceeding maxDiskBytes', () async {
      final net = _FakeNetworkInfo(NetworkKind.wifi);
      final payload = Uint8List(60);
      final cache = MapTileCache(
        networkInfo: net,
        cacheDirectoryProvider: () async => tempDir,
        downloader: (_) async => payload,
        maxDiskBytes: 100,
      );

      await cache.getTile(const TileCoord(15, 1, 1), allowMeteredNetwork: true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await cache.getTile(const TileCoord(15, 2, 2), allowMeteredNetwork: true);

      final files = await tempDir
          .list()
          .where((e) => e is File && e.path.endsWith('.png'))
          .toList();
      expect(files.length, 1);
      expect(files.single.path, endsWith('15_2_2.png'));
    });
  });
}
