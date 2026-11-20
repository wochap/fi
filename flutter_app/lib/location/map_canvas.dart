import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fi/l10n/app_localizations.dart';
import 'package:fi/location/services.dart';
import 'package:fi/location/tile_cache.dart';
import 'package:fi/theme/nocturne.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

const double _tileSize = 256.0;
const double _maxMercatorLat = 85.05112878;

/// Converts WGS 84 `(lat, lng)` to Web Mercator world pixel coordinates at [zoom].
Offset latLngToWorldPixel(double lat, double lng, double zoom) {
  final clampedLat = lat.clamp(-_maxMercatorLat, _maxMercatorLat);
  final scale = _tileSize * math.pow(2.0, zoom);
  final x = (lng + 180.0) / 360.0 * scale;
  final sinLat = math.sin(clampedLat * math.pi / 180.0);
  final y =
      (0.5 - math.log((1.0 + sinLat) / (1.0 - sinLat)) / (4.0 * math.pi)) *
          scale;
  return Offset(x, y);
}

/// Converts Web Mercator world pixel coordinates at [zoom] back to WGS 84 `(lat, lng)`.
(double lat, double lng) worldPixelToLatLng(Offset px, double zoom) {
  final scale = _tileSize * math.pow(2.0, zoom);
  final lng = (px.dx / scale) * 360.0 - 180.0;
  final n = math.pi - 2.0 * math.pi * (px.dy / scale);
  final lat = (180.0 / math.pi) *
      math.atan(0.5 * (math.exp(n) - math.exp(-n)));
  return (
    lat.clamp(-_maxMercatorLat, _maxMercatorLat),
    ((lng + 180.0) % 360.0 + 360.0) % 360.0 - 180.0,
  );
}

/// Pure-Dart OpenStreetMap slippy map and static preview widget backed by [MapTileCache].
class OsmMapCanvas extends StatefulWidget {
  const OsmMapCanvas({
    super.key,
    required this.latitude,
    required this.longitude,
    this.zoom = 15.0,
    this.minZoom = 3.0,
    this.maxZoom = 18.0,
    this.interactive = false,
    this.allowMeteredNetwork = true,
    this.showAttribution = true,
    this.showCenterPin = true,
    this.compactPin = false,
    this.userLatitude,
    this.userLongitude,
    this.tileCache,
    this.onCenterChanged,
    this.onMoveEnd,
    this.offlinePlaceholder,
  });

  final double latitude;
  final double longitude;
  final double zoom;
  final double minZoom;
  final double maxZoom;
  final bool interactive;
  final bool allowMeteredNetwork;
  final bool showAttribution;
  final bool showCenterPin;
  final bool compactPin;
  final double? userLatitude;
  final double? userLongitude;
  final MapTileCache? tileCache;
  final void Function(double lat, double lng)? onCenterChanged;
  final void Function(double lat, double lng)? onMoveEnd;
  final Widget? offlinePlaceholder;

  @override
  State<OsmMapCanvas> createState() => _OsmMapCanvasState();
}

class _OsmMapCanvasState extends State<OsmMapCanvas> {
  late double _lat;
  late double _lng;
  late double _zoom;

  final Map<TileCoord, Uint8List> _loadedTiles = {};
  final Set<TileCoord> _requestedTiles = {};
  bool _anyOfflineOrBlocked = false;
  bool _anyTileLoaded = false;

  // Gesture tracking for interactive pan & pinch zoom.
  Offset? _lastFocalPoint;
  double? _startZoom;

  @override
  void initState() {
    super.initState();
    _lat = widget.latitude;
    _lng = widget.longitude;
    _zoom = widget.zoom;
  }

  @override
  void didUpdateWidget(OsmMapCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.interactive ||
        oldWidget.latitude != widget.latitude ||
        oldWidget.longitude != widget.longitude) {
      _lat = widget.latitude;
      _lng = widget.longitude;
    }
    if (oldWidget.zoom != widget.zoom) {
      _zoom = widget.zoom;
    }
  }

  MapTileCache _cache(BuildContext context) =>
      widget.tileCache ?? LocationScope.of(context).tileCache;

  void _ensureTiles(BuildContext context, List<TileCoord> visible) {
    final cache = _cache(context);
    for (final coord in visible) {
      if (_loadedTiles.containsKey(coord)) continue;
      final mem = cache.peekMemory(coord);
      if (mem != null) {
        _loadedTiles[coord] = mem;
        _anyTileLoaded = true;
        continue;
      }
      if (_requestedTiles.contains(coord)) continue;
      _requestedTiles.add(coord);
      unawaited(
        cache
            .getTile(coord, allowMeteredNetwork: widget.allowMeteredNetwork)
            .then((result) {
          if (!mounted) return;
          if (result.hasBytes) {
            setState(() {
              _loadedTiles[coord] = result.bytes!;
              _anyTileLoaded = true;
              _anyOfflineOrBlocked = false;
            });
          } else if (result.kind == TileFetchOutcomeKind.offline ||
              result.kind == TileFetchOutcomeKind.blockedMetered ||
              result.kind == TileFetchOutcomeKind.failed) {
            setState(() {
              _anyOfflineOrBlocked = true;
            });
          }
        }),
      );
    }
  }

  void _panBy(Offset delta) {
    final centerPx = latLngToWorldPixel(_lat, _lng, _zoom);
    final nextPx = centerPx - delta;
    final (nextLat, nextLng) = worldPixelToLatLng(nextPx, _zoom);
    setState(() {
      _lat = nextLat;
      _lng = nextLng;
    });
    widget.onCenterChanged?.call(_lat, _lng);
  }

  void _zoomBy(double deltaZoom) {
    final next = (_zoom + deltaZoom).clamp(widget.minZoom, widget.maxZoom);
    if (next == _zoom) return;
    setState(() {
      _zoom = next;
    });
    widget.onCenterChanged?.call(_lat, _lng);
    widget.onMoveEnd?.call(_lat, _lng);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.nocturne;
    final l10n = AppLocalizations.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cache = _cache(context);

    return ValueListenableBuilder<String?>(
      valueListenable: MapTileCache.configuredCartoApiKey,
      builder: (context, _, _) {
        final useCarto = cache.hasCartoApiKey;
        return LayoutBuilder(
          builder: (context, constraints) {
            final width =
                constraints.maxWidth.isFinite ? constraints.maxWidth : 300.0;
            final height =
                constraints.maxHeight.isFinite ? constraints.maxHeight : 132.0;
            final intZoom = _zoom.floor().clamp(0, 19);
            final scaleFactor = math.pow(2.0, _zoom - intZoom).toDouble();
            final tileRenderSize = _tileSize * scaleFactor;
            final centerPx = latLngToWorldPixel(_lat, _lng, _zoom);
            final topLeftPx =
                Offset(centerPx.dx - width / 2, centerPx.dy - height / 2);

            final maxTileIndex = (1 << intZoom);
            final minTx = (topLeftPx.dx / tileRenderSize).floor();
            final maxTx = ((topLeftPx.dx + width) / tileRenderSize).floor();
            final minTy = (topLeftPx.dy / tileRenderSize).floor();
            final maxTy = ((topLeftPx.dy + height) / tileRenderSize).floor();

            final visible = <TileCoord>[];
            final tileWidgets = <Widget>[];

            for (var ty = minTy; ty <= maxTy; ty++) {
              if (ty < 0 || ty >= maxTileIndex) continue;
              for (var tx = minTx; tx <= maxTx; tx++) {
                final wrappedTx =
                    ((tx % maxTileIndex) + maxTileIndex) % maxTileIndex;
                final coord = TileCoord(
                  intZoom,
                  wrappedTx,
                  ty,
                  useCarto: useCarto,
                  dark: useCarto && isDark,
                );
                visible.add(coord);
                final left = tx * tileRenderSize - topLeftPx.dx;
                final top = ty * tileRenderSize - topLeftPx.dy;
                final bytes = _loadedTiles[coord] ?? cache.peekMemory(coord);
                if (bytes != null) {
                  _loadedTiles[coord] = bytes;
                  _anyTileLoaded = true;
                  tileWidgets.add(
                    Positioned(
                      left: left,
                      top: top,
                      width: tileRenderSize,
                      height: tileRenderSize,
                      child: Image.memory(
                        bytes,
                        fit: BoxFit.fill,
                        gaplessPlayback: true,
                        filterQuality: FilterQuality.medium,
                      ),
                    ),
                  );
                }
              }
            }

            _ensureTiles(context, visible);

            if (!_anyTileLoaded &&
                _anyOfflineOrBlocked &&
                widget.offlinePlaceholder != null) {
              return widget.offlinePlaceholder!;
            }

            Offset? userDotOffset;
            if (widget.userLatitude != null && widget.userLongitude != null) {
              final userPx = latLngToWorldPixel(
                widget.userLatitude!,
                widget.userLongitude!,
                _zoom,
              );
              final pos = userPx - topLeftPx;
              if (pos.dx >= -16 &&
                  pos.dx <= width + 16 &&
                  pos.dy >= -16 &&
                  pos.dy <= height + 16) {
                userDotOffset = pos;
              }
            }

            final attributionText = useCarto
                ? (l10n?.locationCartoAttribution ??
                    '© OpenStreetMap · © CARTO')
                : (l10n?.locationOsmAttribution ?? '© OpenStreetMap');

            Widget mapStack = ClipRect(
              child: ColoredBox(
                color: colors.neutralFill,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ...tileWidgets,
                    if (userDotOffset != null)
                      Positioned(
                        left: userDotOffset.dx - 10,
                        top: userDotOffset.dy - 10,
                        child: Semantics(
                          label: 'You are here',
                          child: Container(
                            width: 20,
                            height: 20,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: colors.accent.withValues(alpha: 0.24),
                            ),
                            alignment: Alignment.center,
                            child: Container(
                              width: 10,
                              height: 10,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: colors.accent,
                                border: Border.all(
                                  color: Colors.white,
                                  width: 2,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    if (widget.showCenterPin)
                      Center(
                        child: Transform.translate(
                          offset: Offset(0, widget.compactPin ? -7 : -12),
                          child: Icon(
                            PhosphorIconsFill.mapPin,
                            size: widget.compactPin ? 20 : 30,
                            color: colors.accent,
                            shadows: const [
                              Shadow(
                                color: Color(0x55000000),
                                blurRadius: 4,
                                offset: Offset(0, 2),
                              ),
                            ],
                          ),
                        ),
                      ),
                    if (widget.showAttribution)
                      Positioned(
                        left: 6,
                        bottom: 6,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: colors.surface.withValues(alpha: 0.85),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            attributionText,
                            style: TextStyle(
                              fontSize: 10,
                              color: colors.muted(.6),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            );

            if (widget.interactive) {
              mapStack = Listener(
                onPointerSignal: (event) {
                  if (event is PointerScrollEvent) {
                    final step = event.scrollDelta.dy < 0 ? 0.8 : -0.8;
                    _zoomBy(step);
                  }
                },
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onDoubleTap: () => _zoomBy(1.0),
                  onScaleStart: (details) {
                    _lastFocalPoint = details.localFocalPoint;
                    _startZoom = _zoom;
                  },
                  onScaleUpdate: (details) {
                    final prev = _lastFocalPoint;
                    _lastFocalPoint = details.localFocalPoint;
                    if (prev != null) {
                      _panBy(details.localFocalPoint - prev);
                    }
                    if (_startZoom != null && details.scale != 1.0) {
                      final nextZoom =
                          (_startZoom! + math.log(details.scale) / math.ln2)
                              .clamp(widget.minZoom, widget.maxZoom);
                      if ((nextZoom - _zoom).abs() > 0.01) {
                        setState(() {
                          _zoom = nextZoom;
                        });
                      }
                    }
                  },
                  onScaleEnd: (_) {
                    _lastFocalPoint = null;
                    _startZoom = null;
                    widget.onMoveEnd?.call(_lat, _lng);
                  },
                  child: mapStack,
                ),
              );
            }

            return mapStack;
          },
        );
      },
    );
  }
}

/// Striped offline placeholder shown in the 132px mini-map slot when tiles are unavailable.
class MapOfflinePlaceholder extends StatelessWidget {
  const MapOfflinePlaceholder({
    super.key,
    required this.label,
  });

  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = context.nocturne;
    return CustomPaint(
      painter: _DiagonalStripesPainter(
        background: colors.neutralFill,
        stripe: colors.divider,
      ),
      child: Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              PhosphorIconsRegular.wifiSlash,
              size: 16,
              color: colors.muted(.6),
            ),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
                color: colors.muted(.6),
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DiagonalStripesPainter extends CustomPainter {
  const _DiagonalStripesPainter({
    required this.background,
    required this.stripe,
  });

  final Color background;
  final Color stripe;

  @override
  void paint(Canvas canvas, Size size) {
    final bgPaint = Paint()..color = background;
    canvas.drawRect(Offset.zero & size, bgPaint);

    final stripePaint = Paint()
      ..color = stripe.withValues(alpha: 0.45)
      ..strokeWidth = 6;
    const step = 18.0;
    for (var x = -size.height; x < size.width + size.height; x += step) {
      canvas.drawLine(
        Offset(x, 0),
        Offset(x + size.height, size.height),
        stripePaint,
      );
    }
  }

  @override
  bool shouldRepaint(_DiagonalStripesPainter oldDelegate) =>
      oldDelegate.background != background || oldDelegate.stripe != stripe;
}
