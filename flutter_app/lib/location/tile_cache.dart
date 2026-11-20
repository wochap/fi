import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:fi/voice/services.dart' show NetworkInfo, NetworkKind, PlatformNetworkInfo;
import 'package:path_provider/path_provider.dart';

const String fiMapUserAgent = 'Fi/0.1.0 (https://github.com/wochap/fi)';

/// Key identifying one 512×512 (`@2x` retina) Web Mercator raster tile.
class TileCoord {
  const TileCoord(this.z, this.x, this.y, {this.dark = false});

  final int z;
  final int x;
  final int y;
  final bool dark;

  String get _styleSlug => dark ? 'dark_2x' : 'voyager_2x';

  String get cacheKey => '${_styleSlug}_${z}_${x}_$y';

  Uri get osmUri => dark
      ? Uri.parse('https://basemaps.cartocdn.com/dark_all/$z/$x/$y@2x.png')
      : Uri.parse(
          'https://basemaps.cartocdn.com/rastertiles/voyager/$z/$x/$y@2x.png',
        );

  @override
  bool operator ==(Object other) =>
      other is TileCoord &&
      z == other.z &&
      x == other.x &&
      y == other.y &&
      dark == other.dark;

  @override
  int get hashCode => Object.hash(z, x, y, dark);
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
    this.maxDiskBytes = 50 * 1024 * 1024, // 50 MB
    this.maxMemoryEntries = 128,
    this.maxConcurrentDownloads = 4,
  })  : _networkInfo = networkInfo ?? const PlatformNetworkInfo(),
        _cacheDirectoryProvider = cacheDirectoryProvider ?? _defaultCacheDir,
        _downloader = downloader ?? _defaultDownload;

  final NetworkInfo _networkInfo;
  final Future<Directory?> Function() _cacheDirectoryProvider;
  final TileDownloader _downloader;
  final int maxDiskBytes;
  final int maxMemoryEntries;
  final int maxConcurrentDownloads;

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
      final bytes = await _downloader(coord.osmUri);
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
