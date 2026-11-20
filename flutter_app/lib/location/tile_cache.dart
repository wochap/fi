import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:fi/voice/services.dart' show NetworkInfo, NetworkKind, PlatformNetworkInfo;
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

const String fiMapUserAgent = 'Fi/0.1.0 (https://github.com/wochap/fi)';

/// Key identifying one Web Mercator raster tile.
/// When [useCarto] is `true`, fetches 512×512 (`@2x` retina) CARTO tiles (Voyager for light mode,
/// Dark Matter for dark mode); otherwise fetches standard 256×256 OpenStreetMap tiles.
class TileCoord {
  const TileCoord(
    this.z,
    this.x,
    this.y, {
    this.useCarto = false,
    this.dark = false,
  });

  final int z;
  final int x;
  final int y;
  final bool useCarto;
  final bool dark;

  String get cacheKey {
    if (!useCarto) return 'osm_${z}_${x}_$y';
    final style = dark ? 'carto_dark_2x' : 'carto_voyager_2x';
    return '${style}_${z}_${x}_$y';
  }

  Uri get osmUri => uriFor();

  Uri uriFor({String? cartoApiKey}) {
    final key = MapTileCache.normalizeCartoKey(cartoApiKey);
    if (useCarto && key != null) {
      final path = dark
          ? '/dark_all/$z/$x/$y@2x.png'
          : '/rastertiles/voyager/$z/$x/$y@2x.png';
      return Uri.https('basemaps.cartocdn.com', path, {'key': key});
    }
    return Uri.parse('https://tile.openstreetmap.org/$z/$x/$y.png');
  }

  @override
  bool operator ==(Object other) =>
      other is TileCoord &&
      z == other.z &&
      x == other.x &&
      y == other.y &&
      useCarto == other.useCarto &&
      dark == other.dark;

  @override
  int get hashCode => Object.hash(z, x, y, useCarto, dark);
}

enum TileFetchOutcomeKind {
  hitMemory,
  hitDisk,
  fetched,
  blockedMetered,
  offline,
  failed,
}

class TileFetchResult {
  const TileFetchResult({
    required this.kind,
    this.bytes,
  });

  final TileFetchOutcomeKind kind;
  final Uint8List? bytes;

  bool get hasBytes => bytes != null && bytes!.isNotEmpty;
}

typedef TileDownloader = Future<Uint8List?> Function(Uri uri);

/// Persistent on-disk + in-memory LRU cache for OpenStreetMap raster tiles with mobile-data
/// gating and a concurrency cap of 4 in-flight downloads.
class MapTileCache {
  MapTileCache({
    NetworkInfo? networkInfo,
    Future<Directory?> Function()? cacheDirectoryProvider,
    TileDownloader? downloader,
    String? cartoApiKey,
    this.maxDiskBytes = 50 * 1024 * 1024, // 50 MB
    this.maxMemoryEntries = 128,
    this.maxConcurrentDownloads = 4,
  })  : _networkInfo = networkInfo ?? const PlatformNetworkInfo(),
        _cacheDirectoryProvider = cacheDirectoryProvider ?? _defaultCacheDir,
        _downloader = downloader ?? _defaultDownload,
        _cartoApiKeyOverride = normalizeCartoKey(cartoApiKey);

  /// Device-wide CARTO Basemaps API key loaded from `UiPrefs`. When non-null, map canvases
  /// fetch `@2x` CARTO tiles; when null, they fall back to standard OpenStreetMap tiles.
  static final ValueNotifier<String?> configuredCartoApiKey =
      ValueNotifier<String?>(null);

  static String? normalizeCartoKey(String? raw) {
    if (raw == null) return null;
    var trimmed = raw.trim();
    if (trimmed.toLowerCase().startsWith('?key=')) {
      trimmed = trimmed.substring(5).trim();
    } else if (trimmed.toLowerCase().startsWith('key=')) {
      trimmed = trimmed.substring(4).trim();
    }
    return trimmed.isEmpty ? null : trimmed;
  }

  static void setCartoApiKey(String? raw) {
    configuredCartoApiKey.value = normalizeCartoKey(raw);
  }

  final NetworkInfo _networkInfo;
  final Future<Directory?> Function() _cacheDirectoryProvider;
  final TileDownloader _downloader;
  final String? _cartoApiKeyOverride;
  final int maxDiskBytes;
  final int maxMemoryEntries;
  final int maxConcurrentDownloads;

  String? get cartoApiKey =>
      _cartoApiKeyOverride ?? configuredCartoApiKey.value;

  bool get hasCartoApiKey => cartoApiKey != null;

  final LinkedHashMap<String, Uint8List> _memory = LinkedHashMap();
  final Map<String, Future<TileFetchResult>> _inflight = {};
  final Queue<Completer<void>> _waiters = Queue();
  int _activeDownloads = 0;
  Directory? _resolvedDir;

  static Future<Directory> _defaultCacheDir() async {
    final base = await getTemporaryDirectory();
    final dir = Directory('${base.path}${Platform.pathSeparator}map_tiles');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  static Future<Uint8List?> _defaultDownload(Uri uri) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    try {
      final request = await client.getUrl(uri);
      request.headers.set(HttpHeaders.userAgentHeader, fiMapUserAgent);
      final response = await request.close().timeout(const Duration(seconds: 8));
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        return null;
      }
      final builder = BytesBuilder(copy: false);
      await for (final chunk in response) {
        builder.add(chunk);
      }
      return builder.takeBytes();
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  Future<Directory?> _tileDir() async {
    if (_resolvedDir != null) return _resolvedDir;
    try {
      final dir = await _cacheDirectoryProvider();
      if (dir == null) return null;
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      _resolvedDir = dir;
      return dir;
    } catch (_) {
      return null;
    }
  }

  /// Synchronously returns cached bytes if already in memory.
  Uint8List? peekMemory(TileCoord coord) {
    final key = coord.cacheKey;
    final bytes = _memory.remove(key);
    if (bytes != null) {
      _memory[key] = bytes;
    }
    return bytes;
  }

  void _putMemory(String key, Uint8List bytes) {
    _memory.remove(key);
    _memory[key] = bytes;
    while (_memory.length > maxMemoryEntries) {
      _memory.remove(_memory.keys.first);
    }
  }

  /// Fetches a tile obeying the mobile-data policy:
  /// - Memory or disk cache hits always return immediately regardless of network state.
  /// - If uncached and [allowMeteredNetwork] is `false` (record list card thumbnails),
  ///   fetches ONLY on [NetworkKind.wifi] (which includes Ethernet).
  /// - If uncached and [allowMeteredNetwork] is `true` (record editor form & map picker),
  ///   fetches whenever [NetworkInfo.current()] is not [NetworkKind.none].
  Future<TileFetchResult> getTile(
    TileCoord coord, {
    required bool allowMeteredNetwork,
  }) async {
    final key = coord.cacheKey;

    // 1. In-memory LRU hit.
    final mem = peekMemory(coord);
    if (mem != null) {
      return TileFetchResult(kind: TileFetchOutcomeKind.hitMemory, bytes: mem);
    }

    // 2. On-disk cache hit.
    final dir = await _tileDir();
    if (dir != null) {
      final file = File('${dir.path}${Platform.pathSeparator}$key.png');
      if (await file.exists()) {
        try {
          final bytes = await file.readAsBytes();
          if (bytes.isNotEmpty) {
            _putMemory(key, bytes);
            // Touch mtime for LRU tracking (best effort).
            unawaited(
              file.setLastModified(DateTime.now()).catchError((_) => file),
            );
            return TileFetchResult(kind: TileFetchOutcomeKind.hitDisk, bytes: bytes);
          }
        } catch (_) {
          // Fall through to network if file is unreadable.
        }
      }
    }

    // 3. Deduplicate concurrent fetches for the same tile.
    final existing = _inflight[key];
    if (existing != null) return existing;

    final future = _fetchFromNetwork(
      coord,
      dir: dir,
      allowMeteredNetwork: allowMeteredNetwork,
    );
    _inflight[key] = future;
    try {
      return await future;
    } finally {
      _inflight.remove(key);
    }
  }

  Future<TileFetchResult> _fetchFromNetwork(
    TileCoord coord, {
    required Directory? dir,
    required bool allowMeteredNetwork,
  }) async {
    final network = await _networkInfo.current();
    if (network == NetworkKind.none) {
      return const TileFetchResult(kind: TileFetchOutcomeKind.offline);
    }
    if (!allowMeteredNetwork && network != NetworkKind.wifi) {
      return const TileFetchResult(kind: TileFetchOutcomeKind.blockedMetered);
    }

    await _acquireSlot();
    try {
      final bytes = await _downloader(coord.uriFor(cartoApiKey: cartoApiKey));
      if (bytes == null || bytes.isEmpty) {
        return const TileFetchResult(kind: TileFetchOutcomeKind.failed);
      }
      _putMemory(coord.cacheKey, bytes);
      if (dir != null) {
        await _writeToDiskAndPrune(dir, coord.cacheKey, bytes);
      }
      return TileFetchResult(kind: TileFetchOutcomeKind.fetched, bytes: bytes);
    } finally {
      _releaseSlot();
    }
  }

  Future<void> _acquireSlot() async {
    if (_activeDownloads < maxConcurrentDownloads) {
      _activeDownloads++;
      return;
    }
    final completer = Completer<void>();
    _waiters.add(completer);
    await completer.future;
  }

  void _releaseSlot() {
    if (_waiters.isNotEmpty) {
      _waiters.removeFirst().complete();
    } else if (_activeDownloads > 0) {
      _activeDownloads--;
    }
  }

  Future<void> _writeToDiskAndPrune(
    Directory dir,
    String key,
    Uint8List bytes,
  ) async {
    try {
      final target = File('${dir.path}${Platform.pathSeparator}$key.png');
      final tmp = File('${dir.path}${Platform.pathSeparator}$key.tmp');
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(target.path);
      await _pruneIfNeeded(dir);
    } catch (_) {
      // Disk write errors are non-fatal; tile remains in memory cache.
    }
  }

  Future<void> _pruneIfNeeded(Directory dir) async {
    try {
      final entries = <(File, int, DateTime)>[];
      var totalBytes = 0;
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is File && entity.path.endsWith('.png')) {
          final stat = await entity.stat();
          totalBytes += stat.size;
          entries.add((entity, stat.size, stat.modified));
        }
      }
      if (totalBytes <= maxDiskBytes) return;
      // Oldest modified first (LRU eviction).
      entries.sort((a, b) => a.$3.compareTo(b.$3));
      for (final (file, size, _) in entries) {
        if (totalBytes <= maxDiskBytes) break;
        try {
          await file.delete();
          totalBytes -= size;
        } catch (_) {}
      }
    } catch (_) {}
  }
}
