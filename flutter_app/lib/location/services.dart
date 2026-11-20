import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fi/location/format.dart';
import 'package:fi/location/tile_cache.dart';
import 'package:fi/src/rust/api/collections.dart' as rust_collections;
import 'package:fi/src/rust/api/models.dart';
import 'package:fi/voice/services.dart' show NetworkInfo, NetworkKind, PlatformNetworkInfo;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

enum LocationPermissionState {
  grantedPrecise,
  grantedApproximate,
  denied,
  permanentlyDenied,
}

class DeviceLocationStatus {
  const DeviceLocationStatus({
    required this.permission,
    required this.servicesEnabled,
    required this.isAndroid,
  });

  final LocationPermissionState permission;
  final bool servicesEnabled;
  final bool isAndroid;

  bool get isGranted =>
      permission == LocationPermissionState.grantedPrecise ||
      permission == LocationPermissionState.grantedApproximate;

  bool get isApproximateOnly =>
      permission == LocationPermissionState.grantedApproximate;
}

class LocationFix {
  const LocationFix({
    required this.latitude,
    required this.longitude,
    this.accuracyMeters,
    this.approximate = false,
  });

  final double latitude;
  final double longitude;
  final int? accuracyMeters;
  final bool approximate;

  LocationValueDto toDto() {
    var latMicro = degreesToMicrodeg(latitude);
    var lngMicro = degreesToMicrodeg(longitude);
    if (approximate) {
      latMicro = roundMicrodegTo4dp(latMicro);
      lngMicro = roundMicrodegTo4dp(lngMicro);
    }
    return LocationValueDto(
      latitudeMicrodeg: latMicro.clamp(minLatitudeMicrodeg, maxLatitudeMicrodeg),
      longitudeMicrodeg:
          lngMicro.clamp(minLongitudeMicrodeg, maxLongitudeMicrodeg),
      accuracyMeters: accuracyMeters,
      approximate: approximate,
    );
  }
}

class PlaceSearchResult {
  const PlaceSearchResult({
    required this.name,
    required this.subtitle,
    required this.latitude,
    required this.longitude,
    required this.distanceMeters,
  });

  final String name;
  final String subtitle;
  final double latitude;
  final double longitude;
  final double distanceMeters;
}

class ShortLinkResolutionResult {
  const ShortLinkResolutionResult({
    this.resolvedUrl,
    this.offline = false,
  });

  final String? resolvedUrl;
  final bool offline;
}

class PlaceSearchResponse {
  const PlaceSearchResponse({
    required this.results,
    this.offline = false,
  });

  final List<PlaceSearchResult> results;
  final bool offline;
}

abstract interface class LocationServices {
  MapTileCache get tileCache;
  NetworkInfo get networkInfo;

  bool get isAndroid;
  bool get primerShown;
  void markPrimerShown();

  LocationValueDto? get lastSessionLocation;
  set lastSessionLocation(LocationValueDto? value);

  Future<DeviceLocationStatus> locationStatus();
  Future<DeviceLocationStatus> requestLocationPermission();
  Future<void> openLocationSettings();
  Future<void> openAppSettings();

  /// Streams device location fixes until cancelled.
  /// On Android, streams live GPS/network fixes; on Linux desktop, performs a GeoIP lookup.
  Stream<LocationFix> watchLocationFixes();

  Future<void> openExternalUrl(String url, {bool chooser = false});

  /// Parses coordinates or map links via Rust `parse_location_text` (or fallback in tests).
  ParsedLocationDto parseLocationText(String input);

  /// Resolves `https://maps.app.goo.gl/...` or `https://goo.gl/maps/...` up to 3 redirect hops.
  Future<ShortLinkResolutionResult> resolveShortMapLink(String url);

  /// Searches OpenStreetMap places via Photon, sorted nearest-first from [biasLat]/[biasLng].
  Future<PlaceSearchResponse> searchPlaces(
    String query, {
    required double biasLat,
    required double biasLng,
  });

  /// Reverse-geocodes a coordinate via Photon into a short street/place hint, or null if offline/unavailable.
  Future<String?> reverseGeocode(double lat, double lng);
}

typedef HttpClientFactory = HttpClient Function();

final class PlatformLocationServices implements LocationServices {
  PlatformLocationServices({
    MethodChannel? channel,
    NetworkInfo? networkInfo,
    MapTileCache? tileCache,
    HttpClientFactory? httpClientFactory,
    bool? isAndroidOverride,
    Future<void> Function(String url)? linuxOpener,
  })  : _channel = channel ?? const MethodChannel('fi/platform'),
        networkInfo = networkInfo ?? const PlatformNetworkInfo(),
        _httpClientFactory = httpClientFactory ?? HttpClient.new,
        _isAndroid = isAndroidOverride ?? Platform.isAndroid,
        _linuxOpener = linuxOpener {
    this.tileCache = tileCache ?? MapTileCache(networkInfo: this.networkInfo);
    _channel.setMethodCallHandler(_handleIncomingCall);
  }

  final MethodChannel _channel;
  @override
  final NetworkInfo networkInfo;
  @override
  late final MapTileCache tileCache;
  final HttpClientFactory _httpClientFactory;
  final bool _isAndroid;
  final Future<void> Function(String url)? _linuxOpener;

  bool _primerShown = false;
  @override
  LocationValueDto? lastSessionLocation;

  final StreamController<LocationFix> _androidFixes =
      StreamController<LocationFix>.broadcast();

  @override
  bool get isAndroid => _isAndroid;

  @override
  bool get primerShown => _primerShown;

  @override
  void markPrimerShown() {
    _primerShown = true;
  }

  Future<dynamic> _handleIncomingCall(MethodCall call) async {
    if (call.method == 'onLocationFix' && call.arguments is Map) {
      final map = Map<Object?, Object?>.from(call.arguments as Map);
      final lat = (map['lat'] as num?)?.toDouble();
      final lng = (map['lng'] as num?)?.toDouble();
      final acc = (map['accuracy'] as num?)?.round();
      final approx = map['approximate'] == true;
      if (lat != null && lng != null) {
        _androidFixes.add(
          LocationFix(
            latitude: lat,
            longitude: lng,
            accuracyMeters: acc,
            approximate: approx,
          ),
        );
      }
    }
  }

  @override
  Future<DeviceLocationStatus> locationStatus() async {
    if (!_isAndroid) {
      return const DeviceLocationStatus(
        permission: LocationPermissionState.grantedPrecise,
        servicesEnabled: true,
        isAndroid: false,
      );
    }
    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>('locationStatus');
      return _parseAndroidStatus(raw);
    } catch (_) {
      return const DeviceLocationStatus(
        permission: LocationPermissionState.denied,
        servicesEnabled: false,
        isAndroid: true,
      );
    }
  }

  @override
  Future<DeviceLocationStatus> requestLocationPermission() async {
    if (!_isAndroid) {
      return const DeviceLocationStatus(
        permission: LocationPermissionState.grantedPrecise,
        servicesEnabled: true,
        isAndroid: false,
      );
    }
    try {
      final raw = await _channel
          .invokeMapMethod<String, dynamic>('requestLocationPermission');
      return _parseAndroidStatus(raw);
    } catch (_) {
      return const DeviceLocationStatus(
        permission: LocationPermissionState.denied,
        servicesEnabled: false,
        isAndroid: true,
      );
    }
  }

  DeviceLocationStatus _parseAndroidStatus(Map<String, dynamic>? raw) {
    final fine = raw?['fine'] == true;
    final coarse = raw?['coarse'] == true;
    final servicesEnabled = raw?['servicesEnabled'] == true;
    final shouldShowRationale = raw?['shouldShowRationale'] == true;
    final LocationPermissionState perm;
    if (fine) {
      perm = LocationPermissionState.grantedPrecise;
    } else if (coarse) {
      perm = LocationPermissionState.grantedApproximate;
    } else if (shouldShowRationale) {
      perm = LocationPermissionState.denied;
    } else {
      perm = _primerShown
          ? LocationPermissionState.permanentlyDenied
          : LocationPermissionState.denied;
    }
    return DeviceLocationStatus(
      permission: perm,
      servicesEnabled: servicesEnabled,
      isAndroid: true,
    );
  }

  @override
  Future<void> openLocationSettings() async {
    if (_isAndroid) {
      try {
        await _channel.invokeMethod<void>('openLocationSettings');
      } catch (_) {}
    }
  }

  @override
  Future<void> openAppSettings() async {
    if (_isAndroid) {
      try {
        await _channel.invokeMethod<void>('openAppSettings');
      } catch (_) {}
    }
  }

  @override
  Stream<LocationFix> watchLocationFixes() {
    if (_isAndroid) {
      late StreamController<LocationFix> controller;
      StreamSubscription<LocationFix>? sub;
      controller = StreamController<LocationFix>(
        onListen: () async {
          sub = _androidFixes.stream.listen(
            controller.add,
            onError: controller.addError,
          );
          try {
            await _channel.invokeMethod<void>('startLocationFix');
          } catch (e, st) {
            if (!controller.isClosed) {
              controller.addError(e, st);
            }
          }
        },
        onCancel: () async {
          await sub?.cancel();
          try {
            await _channel.invokeMethod<void>('stopLocationFix');
          } catch (_) {}
        },
      );
      return controller.stream;
    }

    // Linux desktop: approximate location via keyless HTTPS GeoIP lookup (5s timeout).
    return Stream<LocationFix?>.fromFuture(_lookupDesktopGeoIp())
        .where((fix) => fix != null)
        .cast<LocationFix>();
  }

  Future<LocationFix?> _lookupDesktopGeoIp() async {
    final client = _httpClientFactory()
      ..connectionTimeout = const Duration(seconds: 5);
    try {
      final request = await client
          .getUrl(Uri.parse('https://get.geojs.io/v1/ip/geo.json'))
          .timeout(const Duration(seconds: 5));
      request.headers.set(HttpHeaders.userAgentHeader, fiMapUserAgent);
      final response = await request.close().timeout(const Duration(seconds: 5));
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        return null;
      }
      final body = await utf8.decodeStream(response);
      final data = jsonDecode(body);
      if (data is! Map) return null;
      final lat = double.tryParse('${data['latitude'] ?? ''}');
      final lng = double.tryParse('${data['longitude'] ?? ''}');
      if (lat == null || lng == null) return null;
      final accKm = double.tryParse('${data['accuracy'] ?? ''}');
      return LocationFix(
        latitude: lat,
        longitude: lng,
        accuracyMeters: accKm != null ? (accKm * 1000).round() : 5000,
        approximate: true,
      );
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<void> openExternalUrl(String url, {bool chooser = false}) async {
    if (_isAndroid) {
      await _channel.invokeMethod<void>('openExternalUrl', <String, Object>{
        'url': url,
        'chooser': chooser,
      });
      return;
    }
    if (_linuxOpener != null) {
      await _linuxOpener(url);
      return;
    }
    try {
      await Process.start('xdg-open', [url], mode: ProcessStartMode.detached);
    } catch (_) {}
  }

  @override
  ParsedLocationDto parseLocationText(String input) {
    try {
      return rust_collections.parseLocationText(input: input);
    } catch (_) {
      return parseLocationFallback(input);
    }
  }

  @override
  Future<ShortLinkResolutionResult> resolveShortMapLink(String url) async {
    final net = await networkInfo.current();
    if (net == NetworkKind.none) {
      return const ShortLinkResolutionResult(offline: true);
    }

    final client = _httpClientFactory()
      ..connectionTimeout = const Duration(seconds: 4);
    try {
      var current = Uri.parse(url);
      for (var hop = 0; hop < 3; hop++) {
        final request = await client
            .openUrl('HEAD', current)
            .timeout(const Duration(seconds: 4));
        request.followRedirects = false;
        request.headers.set(HttpHeaders.userAgentHeader, fiMapUserAgent);
        final response =
            await request.close().timeout(const Duration(seconds: 4));
        await response.drain<void>();
        final location = response.headers.value(HttpHeaders.locationHeader);
        if (location == null || location.isEmpty) {
          // Some shorteners reject HEAD; retry once with GET without following redirects.
          if (hop == 0 && response.statusCode >= 400) {
            final getReq = await client
                .getUrl(current)
                .timeout(const Duration(seconds: 4));
            getReq.followRedirects = false;
            getReq.headers.set(HttpHeaders.userAgentHeader, fiMapUserAgent);
            final getResp =
                await getReq.close().timeout(const Duration(seconds: 4));
            await getResp.drain<void>();
            final getLoc = getResp.headers.value(HttpHeaders.locationHeader);
            if (getLoc != null && getLoc.isNotEmpty) {
              current = current.resolve(getLoc);
              final parsed = parseLocationText(current.toString());
              if (parsed.status == LocationParseStatusDto.ok) {
                return ShortLinkResolutionResult(
                  resolvedUrl: current.toString(),
                );
              }
              continue;
            }
          }
          return ShortLinkResolutionResult(resolvedUrl: current.toString());
        }
        current = current.resolve(location);
        final parsed = parseLocationText(current.toString());
        if (parsed.status == LocationParseStatusDto.ok) {
          return ShortLinkResolutionResult(resolvedUrl: current.toString());
        }
      }
      return ShortLinkResolutionResult(resolvedUrl: current.toString());
    } on SocketException {
      return const ShortLinkResolutionResult(offline: true);
    } on TimeoutException {
      return const ShortLinkResolutionResult(offline: true);
    } catch (_) {
      return const ShortLinkResolutionResult();
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<PlaceSearchResponse> searchPlaces(
    String query, {
    required double biasLat,
    required double biasLng,
  }) async {
    final trimmed = query.trim();
    if (trimmed.length < 3) {
      return const PlaceSearchResponse(results: []);
    }
    final net = await networkInfo.current();
    if (net == NetworkKind.none) {
      return const PlaceSearchResponse(results: [], offline: true);
    }

    final uri = Uri.https('photon.komoot.io', '/api/', {
      'q': trimmed,
      'lat': biasLat.toStringAsFixed(6),
      'lon': biasLng.toStringAsFixed(6),
      'limit': '8',
    });

    final client = _httpClientFactory()
      ..connectionTimeout = const Duration(seconds: 5);
    try {
      final request =
          await client.getUrl(uri).timeout(const Duration(seconds: 5));
      request.headers.set(HttpHeaders.userAgentHeader, fiMapUserAgent);
      final response =
          await request.close().timeout(const Duration(seconds: 5));
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        return const PlaceSearchResponse(results: []);
      }
      final body = await utf8.decodeStream(response);
      final json = jsonDecode(body);
      final results = _parsePhotonFeatures(json, biasLat, biasLng);
      results.sort((a, b) => a.distanceMeters.compareTo(b.distanceMeters));
      return PlaceSearchResponse(results: results);
    } on SocketException {
      return const PlaceSearchResponse(results: [], offline: true);
    } on TimeoutException {
      return const PlaceSearchResponse(results: [], offline: true);
    } catch (_) {
      return const PlaceSearchResponse(results: []);
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<String?> reverseGeocode(double lat, double lng) async {
    final net = await networkInfo.current();
    if (net == NetworkKind.none) return null;

    final uri = Uri.https('photon.komoot.io', '/reverse', {
      'lat': lat.toStringAsFixed(6),
      'lon': lng.toStringAsFixed(6),
    });

    final client = _httpClientFactory()
      ..connectionTimeout = const Duration(seconds: 4);
    try {
      final request =
          await client.getUrl(uri).timeout(const Duration(seconds: 4));
      request.headers.set(HttpHeaders.userAgentHeader, fiMapUserAgent);
      final response =
          await request.close().timeout(const Duration(seconds: 4));
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        return null;
      }
      final body = await utf8.decodeStream(response);
      final json = jsonDecode(body);
      if (json is! Map) return null;
      final features = json['features'];
      if (features is! List || features.isEmpty) return null;
      final first = features.first;
      if (first is! Map) return null;
      final props = first['properties'];
      if (props is! Map) return null;
      final street = props['street'] as String?;
      final name = props['name'] as String?;
      final city = props['city'] as String? ?? props['town'] as String?;
      if (street != null && street.isNotEmpty) {
        return city != null && city.isNotEmpty ? '$street, $city' : street;
      }
      if (name != null && name.isNotEmpty) {
        return city != null && city.isNotEmpty ? '$name, $city' : name;
      }
      return city;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  List<PlaceSearchResult> _parsePhotonFeatures(
    Object? json,
    double biasLat,
    double biasLng,
  ) {
    if (json is! Map) return [];
    final features = json['features'];
    if (features is! List) return [];
    final out = <PlaceSearchResult>[];
    for (final raw in features) {
      if (raw is! Map) continue;
      final geom = raw['geometry'];
      final props = raw['properties'];
      if (geom is! Map || props is! Map) continue;
      final coords = geom['coordinates'];
      if (coords is! List || coords.length < 2) continue;
      final lng = (coords[0] as num?)?.toDouble();
      final lat = (coords[1] as num?)?.toDouble();
      if (lat == null || lng == null) continue;
      final name = (props['name'] as String?) ??
          (props['street'] as String?) ??
          (props['city'] as String?) ??
          '';
      if (name.isEmpty) continue;
      final subtitleParts = <String>[
        if (props['street'] is String &&
            (props['street'] as String).isNotEmpty &&
            props['street'] != name)
          props['street'] as String,
        if (props['city'] is String &&
            (props['city'] as String).isNotEmpty &&
            props['city'] != name)
          props['city'] as String,
        if (props['country'] is String && (props['country'] as String).isNotEmpty)
          props['country'] as String,
      ];
      out.add(
        PlaceSearchResult(
          name: name,
          subtitle: subtitleParts.join(', '),
          latitude: lat,
          longitude: lng,
          distanceMeters: haversineDistanceMeters(biasLat, biasLng, lat, lng),
        ),
      );
    }
    return out;
  }
}

/// Provides [LocationServices] down the widget tree (following [VoiceScope]).
class LocationScope extends InheritedWidget {
  const LocationScope({
    super.key,
    required this.services,
    required super.child,
  });

  final LocationServices services;

  static LocationServices? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<LocationScope>()?.services;

  static final LocationServices _defaultServices = PlatformLocationServices();

  static LocationServices of(BuildContext context) =>
      maybeOf(context) ?? _defaultServices;

  @override
  bool updateShouldNotify(LocationScope oldWidget) =>
      oldWidget.services != services;
}
