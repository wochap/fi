import 'dart:math' as math;

import 'package:fi/src/rust/api/models.dart';

const int minLatitudeMicrodeg = -90000000;
const int maxLatitudeMicrodeg = 90000000;
const int minLongitudeMicrodeg = -180000000;
const int maxLongitudeMicrodeg = 180000000;

/// Converts a floating-point degree value to rounded integer microdegrees.
int degreesToMicrodeg(double degrees) => (degrees * 1000000.0).round();

/// Converts microdegrees to floating-point degrees for map projection and external URLs.
double microdegToDegrees(int microdeg) => microdeg / 1000000.0;

/// Rounds microdegrees to 4 decimal places (100-microdegree steps) for approximate fixes.
int roundMicrodegTo4dp(int microdeg) {
  if (microdeg >= 0) {
    return ((microdeg + 50) ~/ 100) * 100;
  }
  return ((microdeg - 50) ~/ 100) * 100;
}

/// Exact integer formatting of microdegrees to [decimals] places (0..6).
String formatMicrodeg(int microdeg, int decimals) {
  final clamped = decimals.clamp(0, 6);
  var divisor = 1;
  for (var i = 0; i < 6 - clamped; i++) {
    divisor *= 10;
  }
  final int roundedUnits;
  if (divisor == 1) {
    roundedUnits = microdeg;
  } else {
    final half = divisor ~/ 2;
    roundedUnits = microdeg >= 0
        ? (microdeg + half) ~/ divisor
        : (microdeg - half) ~/ divisor;
  }
  final negative = roundedUnits < 0;
  final absUnits = roundedUnits.abs();
  final sign = negative ? '-' : '';
  if (clamped == 0) {
    return '$sign$absUnits';
  }
  var scale = 1;
  for (var i = 0; i < clamped; i++) {
    scale *= 10;
  }
  final whole = absUnits ~/ scale;
  final frac = (absUnits % scale).toString().padLeft(clamped, '0');
  return '$sign$whole.$frac';
}

/// Formats a location to 6 decimal places: `38.710841, -9.137265`.
String formatLocation6dp(LocationValueDto location) =>
    '${formatMicrodeg(location.latitudeMicrodeg, 6)}, '
    '${formatMicrodeg(location.longitudeMicrodeg, 6)}';

/// Formats a location to 4 decimal places: `38.7108, -9.1373`.
String formatLocation4dp(LocationValueDto location) =>
    '${formatMicrodeg(location.latitudeMicrodeg, 4)}, '
    '${formatMicrodeg(location.longitudeMicrodeg, 4)}';

/// Formats a location using 4 decimals if approximate, otherwise 6 decimals.
String formatLocationCanonical(LocationValueDto location) =>
    location.approximate
        ? formatLocation4dp(location)
        : formatLocation6dp(location);

/// Formats horizontal accuracy in meters (`12 m` or `1.9 km`).
String formatAccuracy(int meters) {
  if (meters >= 1000) {
    final km = meters / 1000.0;
    return '${km.toStringAsFixed(1)} km';
  }
  return '$meters m';
}

/// Formats a distance in meters (`140 m` or `1.4 km`).
String formatDistance(double meters) {
  if (meters < 1000) {
    return '${meters.round()} m';
  }
  final km = meters / 1000.0;
  if (km < 100) {
    return '${km.toStringAsFixed(1)} km';
  }
  return '${km.round()} km';
}

/// Great-circle Haversine distance in meters between two WGS 84 coordinates.
double haversineDistanceMeters(
  double lat1,
  double lng1,
  double lat2,
  double lng2,
) {
  const earthRadiusMeters = 6371000.0;
  final dLat = _degToRad(lat2 - lat1);
  final dLng = _degToRad(lng2 - lng1);
  final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(_degToRad(lat1)) *
          math.cos(_degToRad(lat2)) *
          math.sin(dLng / 2) *
          math.sin(dLng / 2);
  final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  return earthRadiusMeters * c;
}

double _degToRad(double deg) => deg * (math.pi / 180.0);

/// External Google Maps search URL (6-decimal precision).
String googleMapsUrl(LocationValueDto location) {
  final lat = formatMicrodeg(location.latitudeMicrodeg, 6);
  final lng = formatMicrodeg(location.longitudeMicrodeg, 6);
  return 'https://www.google.com/maps/search/?api=1&query=$lat,$lng';
}

/// External Waze navigation URL (6-decimal precision).
String wazeUrl(LocationValueDto location) {
  final lat = formatMicrodeg(location.latitudeMicrodeg, 6);
  final lng = formatMicrodeg(location.longitudeMicrodeg, 6);
  return 'https://waze.com/ul?ll=$lat,$lng&navigate=yes';
}

/// Android `geo:` URI (6-decimal precision).
String geoUri(LocationValueDto location) {
  final lat = formatMicrodeg(location.latitudeMicrodeg, 6);
  final lng = formatMicrodeg(location.longitudeMicrodeg, 6);
  return 'geo:$lat,$lng?q=$lat,$lng';
}

/// Pure-Dart fallback parser mirroring `crates/app_core/src/location.rs`, used when the native
/// Rust library is not loaded (such as in headless Flutter widget tests).
ParsedLocationDto parseLocationFallback(String input) {
  final trimmed = input.trim();
  if (trimmed.isEmpty) {
    return const ParsedLocationDto(
      status: LocationParseStatusDto.invalidSyntax,
      errorMessage: 'Not a coordinate. Try 38.7139, -9.1334',
    );
  }

  // Short Google Maps links
  final shortMatch = RegExp(
    r'(?:https?://)?(?:maps\.app\.goo\.gl/\S+|goo\.gl/maps/\S+)',
    caseSensitive: false,
  ).firstMatch(trimmed);
  if (shortMatch != null) {
    var url = shortMatch.group(0)!.replaceAll(RegExp(r'[)\].;,]+$'), '');
    if (!url.toLowerCase().startsWith('http://') &&
        !url.toLowerCase().startsWith('https://')) {
      url = 'https://$url';
    }
    return ParsedLocationDto(
      status: LocationParseStatusDto.shortLinkNeedsResolution,
      shortLinkUrl: url,
      errorMessage: 'Resolving a short map link requires internet',
    );
  }

  // geo: URI
  if (trimmed.toLowerCase().startsWith('geo:')) {
    final rest = trimmed.substring(4);
    final qIdx = rest.indexOf('?');
    final beforeQ = qIdx >= 0 ? rest.substring(0, qIdx) : rest;
    final query = qIdx >= 0 ? rest.substring(qIdx + 1) : null;
    final coordsPart = beforeQ.split(';').first;
    final base = _parseDecimalPair(coordsPart);
    if (query != null) {
      final params = Uri.splitQueryString(query);
      final q = params['q'];
      if (q != null) {
        final stripped = q.split('(').first.trim();
        final qParsed = _parseDecimalPair(stripped);
        if (qParsed.status == LocationParseStatusDto.ok) {
          if (base.status != LocationParseStatusDto.ok ||
              (base.value!.latitudeMicrodeg == 0 &&
                  base.value!.longitudeMicrodeg == 0)) {
            return qParsed;
          }
        }
      }
    }
    return base;
  }

  // Full URLs
  final lower = trimmed.toLowerCase();
  if (lower.contains('://') ||
      lower.startsWith('maps.google.') ||
      lower.startsWith('www.google.') ||
      lower.startsWith('google.') ||
      lower.startsWith('waze.com') ||
      lower.startsWith('www.waze.com') ||
      lower.startsWith('ul.waze.com') ||
      lower.startsWith('openstreetmap.org') ||
      lower.startsWith('www.openstreetmap.org') ||
      lower.startsWith('osm.org')) {
    return _parseMapUrl(trimmed);
  }

  // DMS
  if (trimmed.contains('°') || trimmed.contains("'") || trimmed.contains('′')) {
    final dms = _tryParseDmsPair(trimmed);
    if (dms != null) return dms;
  }

  return _parseDecimalPair(trimmed);
}

ParsedLocationDto _parseMapUrl(String input) {
  // 1. !3d<lat>!4d<lng>
  final matches3d = RegExp(r'!3d(-?\d+(?:\.\d+)?)!4d(-?\d+(?:\.\d+)?)')
      .allMatches(input)
      .toList();
  if (matches3d.isNotEmpty) {
    final m = matches3d.last;
    return _fromDecimalStrings(m.group(1)!, m.group(2)!);
  }

  // 2. Query parameters
  final qIdx = input.indexOf('?');
  if (qIdx >= 0) {
    final afterQ = input.substring(qIdx + 1);
    final hashIdx = afterQ.indexOf('#');
    final query = hashIdx >= 0 ? afterQ.substring(0, hashIdx) : afterQ;
    try {
      final params = Uri.splitQueryString(query);
      if (params.containsKey('mlat') && params.containsKey('mlon')) {
        return _fromDecimalStrings(params['mlat']!, params['mlon']!);
      }
      for (final key in ['q', 'query', 'll', 'center', 'destination', 'daddr']) {
        final val = params[key];
        if (val != null) {
          final candidate = val.trim().replaceFirst(RegExp(r'^loc:'), '');
          final parsed = _parseDecimalPair(candidate);
          if (parsed.status != LocationParseStatusDto.invalidSyntax) {
            return parsed;
          }
        }
      }
    } catch (_) {}
  }

  // 3. OSM #map=<zoom>/<lat>/<lng>
  final osmHash = RegExp(r'map=\d+(?:\.\d+)?/(-?\d+(?:\.\d+)?)/(-?\d+(?:\.\d+)?)')
      .firstMatch(input);
  if (osmHash != null) {
    return _fromDecimalStrings(osmHash.group(1)!, osmHash.group(2)!);
  }

  // 4. /search/<lat>,<lng> or /place/<lat>,<lng>
  final pathMatch = RegExp(r'/(?:search|place)/([^/?#]+)').firstMatch(input);
  if (pathMatch != null) {
    final decoded = Uri.decodeComponent(pathMatch.group(1)!);
    final parsed = _parseDecimalPair(decoded);
    if (parsed.status == LocationParseStatusDto.ok) return parsed;
  }

  // 5. @<lat>,<lng>
  final atMatch = RegExp(r'@(-?\d+(?:\.\d+)?),(-?\d+(?:\.\d+)?)').firstMatch(input);
  if (atMatch != null) {
    return _fromDecimalStrings(atMatch.group(1)!, atMatch.group(2)!);
  }

  return const ParsedLocationDto(
    status: LocationParseStatusDto.invalidSyntax,
    errorMessage: 'Not a coordinate. Try 38.7139, -9.1334',
  );
}

ParsedLocationDto _parseDecimalPair(String input) {
  final trimmed = input.trim();
  String latStr;
  String lngStr;
  if (trimmed.contains(',')) {
    final parts = trimmed.split(',');
    if (parts.length != 2) {
      return const ParsedLocationDto(
        status: LocationParseStatusDto.invalidSyntax,
        errorMessage: 'Not a coordinate. Try 38.7139, -9.1334',
      );
    }
    latStr = parts[0].trim();
    lngStr = parts[1].trim();
  } else {
    final parts = trimmed.split(RegExp(r'\s+'));
    if (parts.length != 2) {
      return const ParsedLocationDto(
        status: LocationParseStatusDto.invalidSyntax,
        errorMessage: 'Not a coordinate. Try 38.7139, -9.1334',
      );
    }
    latStr = parts[0];
    lngStr = parts[1];
  }
  return _fromDecimalStrings(latStr, lngStr);
}

ParsedLocationDto _fromDecimalStrings(String latStr, String lngStr) {
  final lat = double.tryParse(latStr.trim());
  final lng = double.tryParse(lngStr.trim());
  if (lat == null || lng == null || !lat.isFinite || !lng.isFinite) {
    return const ParsedLocationDto(
      status: LocationParseStatusDto.invalidSyntax,
      errorMessage: 'Not a coordinate. Try 38.7139, -9.1334',
    );
  }
  final latMicro = degreesToMicrodeg(lat);
  final lngMicro = degreesToMicrodeg(lng);
  if (latMicro < minLatitudeMicrodeg || latMicro > maxLatitudeMicrodeg) {
    return const ParsedLocationDto(
      status: LocationParseStatusDto.latitudeOutOfRange,
      errorMessage: 'Latitude goes from -90 to 90',
    );
  }
  if (lngMicro < minLongitudeMicrodeg || lngMicro > maxLongitudeMicrodeg) {
    return const ParsedLocationDto(
      status: LocationParseStatusDto.longitudeOutOfRange,
      errorMessage: 'Longitude goes from -180 to 180',
    );
  }
  return ParsedLocationDto(
    status: LocationParseStatusDto.ok,
    value: LocationValueDto(
      latitudeMicrodeg: latMicro,
      longitudeMicrodeg: lngMicro,
      approximate: false,
    ),
  );
}

ParsedLocationDto? _tryParseDmsPair(String input) {
  final re = RegExp(
    r'''([NSEW])?\s*(-?\d+(?:\.\d+)?)\s*°\s*(?:(\d+(?:\.\d+)?)\s*['′]\s*(?:(\d+(?:\.\d+)?)\s*["″]?)?)?\s*([NSEW])?''',
    caseSensitive: false,
  );
  final matches = re.allMatches(input).toList();
  if (matches.length != 2) return null;

  (double, String?)? parseOne(RegExpMatch m) {
    final h = (m.group(5) ?? m.group(1))?.toUpperCase();
    final deg = double.tryParse(m.group(2)!);
    final min = m.group(3) != null ? double.tryParse(m.group(3)!) : 0.0;
    final sec = m.group(4) != null ? double.tryParse(m.group(4)!) : 0.0;
    if (deg == null || min == null || sec == null) return null;
    if (min < 0 || min >= 60 || sec < 0 || sec >= 60) return null;
    final mag = deg.abs() + min / 60.0 + sec / 3600.0;
    final val = (deg < 0 && h == null) ? -mag : mag;
    return (val, h);
  }

  final p1 = parseOne(matches[0]);
  final p2 = parseOne(matches[1]);
  if (p1 == null || p2 == null) return null;

  double lat;
  double lng;
  switch ((p1.$2, p2.$2)) {
    case ('N', 'E'):
      lat = p1.$1;
      lng = p2.$1;
    case ('N', 'W'):
      lat = p1.$1;
      lng = -p2.$1;
    case ('S', 'E'):
      lat = -p1.$1;
      lng = p2.$1;
    case ('S', 'W'):
      lat = -p1.$1;
      lng = -p2.$1;
    case ('E', 'N'):
      lat = p2.$1;
      lng = p1.$1;
    case ('W', 'N'):
      lat = p2.$1;
      lng = -p1.$1;
    case ('E', 'S'):
      lat = -p2.$1;
      lng = p1.$1;
    case ('W', 'S'):
      lat = -p2.$1;
      lng = -p1.$1;
    case (null, null):
      lat = p1.$1;
      lng = p2.$1;
    default:
      return const ParsedLocationDto(
        status: LocationParseStatusDto.invalidSyntax,
        errorMessage: 'Not a coordinate. Try 38.7139, -9.1334',
      );
  }

  final latMicro = degreesToMicrodeg(lat);
  final lngMicro = degreesToMicrodeg(lng);
  if (latMicro < minLatitudeMicrodeg || latMicro > maxLatitudeMicrodeg) {
    return const ParsedLocationDto(
      status: LocationParseStatusDto.latitudeOutOfRange,
      errorMessage: 'Latitude goes from -90 to 90',
    );
  }
  if (lngMicro < minLongitudeMicrodeg || lngMicro > maxLongitudeMicrodeg) {
    return const ParsedLocationDto(
      status: LocationParseStatusDto.longitudeOutOfRange,
      errorMessage: 'Longitude goes from -180 to 180',
    );
  }
  return ParsedLocationDto(
    status: LocationParseStatusDto.ok,
    value: LocationValueDto(
      latitudeMicrodeg: latMicro,
      longitudeMicrodeg: lngMicro,
      approximate: false,
    ),
  );
}
