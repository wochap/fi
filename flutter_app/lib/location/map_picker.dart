import 'dart:async';

import 'package:fi/l10n/l10n.dart';
import 'package:fi/location/format.dart';
import 'package:fi/location/map_canvas.dart';
import 'package:fi/location/services.dart';
import 'package:fi/location/type_coordinates_sheet.dart';
import 'package:fi/src/rust/api/models.dart';
import 'package:fi/theme/nocturne.dart';
import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

/// Opens the interactive Map Picker (full-screen on phone `< 720px`, modal dialog on desktop
/// `>= 720px`). Returns the chosen [LocationValueDto] when the user taps `Use this spot`,
/// or null if cancelled.
Future<LocationValueDto?> showLocationMapPicker(
  BuildContext context, {
  required String fieldName,
  LocationValueDto? initialValue,
  LocationValueDto? userLocation,
}) {
  final services = LocationScope.of(context);
  final phone = Nocturne.isPhone(context);
  if (phone) {
    return Navigator.of(context).push<LocationValueDto>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => LocationScope(
          services: services,
          child: _MapPickerView(
            fieldName: fieldName,
            initialValue: initialValue,
            userLocation: userLocation,
            fullScreen: true,
          ),
        ),
      ),
    );
  }
  return showDialog<LocationValueDto>(
    context: context,
    builder: (_) => LocationScope(
      services: services,
      child: Dialog(
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          width: 680,
          height: 580,
          child: _MapPickerView(
            fieldName: fieldName,
            initialValue: initialValue,
            userLocation: userLocation,
            fullScreen: false,
          ),
        ),
      ),
    ),
  );
}

class _MapPickerView extends StatefulWidget {
  const _MapPickerView({
    required this.fieldName,
    required this.fullScreen,
    this.initialValue,
    this.userLocation,
  });

  final String fieldName;
  final bool fullScreen;
  final LocationValueDto? initialValue;
  final LocationValueDto? userLocation;

  @override
  State<_MapPickerView> createState() => _MapPickerViewState();
}

class _MapPickerViewState extends State<_MapPickerView> {
  // Default fallback center (Lisbon) when no saved, user, or session location exists.
  static const _fallbackLat = 38.7139;
  static const _fallbackLng = -9.1334;

  late double _lat;
  late double _lng;
  final double _zoom = 16.0;
  bool _initialized = false;

  String? _reverseHint;
  Timer? _reverseTimer;
  int _reverseToken = 0;

  bool _searchOpen = false;
  final TextEditingController _searchController = TextEditingController();
  Timer? _searchTimer;
  int _searchToken = 0;
  List<PlaceSearchResult> _searchResults = const [];
  bool _searchOffline = false;
  bool _searchLoading = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    final services = LocationScope.of(context);
    final seed =
        widget.initialValue ?? widget.userLocation ?? services.lastSessionLocation;
    if (seed != null) {
      _lat = microdegToDegrees(seed.latitudeMicrodeg);
      _lng = microdegToDegrees(seed.longitudeMicrodeg);
    } else {
      _lat = _fallbackLat;
      _lng = _fallbackLng;
    }
    _scheduleReverseGeocode();
  }

  @override
  void dispose() {
    _reverseTimer?.cancel();
    _searchTimer?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _scheduleReverseGeocode() {
    _reverseTimer?.cancel();
    final token = ++_reverseToken;
    _reverseTimer = Timer(const Duration(milliseconds: 400), () async {
      if (!mounted) return;
      final services = LocationScope.of(context);
      final hint = await services.reverseGeocode(_lat, _lng);
      if (!mounted || token != _reverseToken) return;
      setState(() {
        _reverseHint = hint;
      });
    });
  }

  void _moveCenter(double lat, double lng) {
    setState(() {
      _lat = lat;
      _lng = lng;
    });
    _scheduleReverseGeocode();
  }

  void _recenterOnUser() {
    final user = widget.userLocation;
    if (user == null) return;
    _moveCenter(
      microdegToDegrees(user.latitudeMicrodeg),
      microdegToDegrees(user.longitudeMicrodeg),
    );
  }

  Future<void> _openTypeCoordinates() async {
    final current = LocationValueDto(
      latitudeMicrodeg: degreesToMicrodeg(_lat),
      longitudeMicrodeg: degreesToMicrodeg(_lng),
      approximate: false,
    );
    final picked = await showTypeCoordinatesSheet(
      context,
      initialValue: current,
    );
    if (!mounted || picked == null) return;
    setState(() {
      _searchOpen = false;
    });
    _moveCenter(
      microdegToDegrees(picked.latitudeMicrodeg),
      microdegToDegrees(picked.longitudeMicrodeg),
    );
  }

  void _onSearchQueryChanged(String query) {
    _searchTimer?.cancel();
    final trimmed = query.trim();
    if (trimmed.length < 3) {
      setState(() {
        _searchResults = const [];
        _searchLoading = false;
        _searchOffline = false;
      });
      return;
    }
    final token = ++_searchToken;
    setState(() {
      _searchLoading = true;
      _searchOffline = false;
    });
    _searchTimer = Timer(const Duration(milliseconds: 300), () async {
      if (!mounted) return;
      final services = LocationScope.of(context);
      final response = await services.searchPlaces(
        trimmed,
        biasLat: _lat,
        biasLng: _lng,
      );
      if (!mounted || token != _searchToken) return;
      setState(() {
        _searchLoading = false;
        _searchOffline = response.offline;
        _searchResults = response.results;
      });
    });
  }

  void _openSearch() async {
    setState(() {
      _searchOpen = true;
    });
    final services = LocationScope.of(context);
    final net = await services.networkInfo.current();
    if (!mounted) return;
    if (net.name == 'none') {
      setState(() {
        _searchOffline = true;
      });
    }
  }

  void _confirmSpot() {
    final value = LocationValueDto(
      latitudeMicrodeg:
          degreesToMicrodeg(_lat).clamp(minLatitudeMicrodeg, maxLatitudeMicrodeg),
      longitudeMicrodeg:
          degreesToMicrodeg(_lng).clamp(minLongitudeMicrodeg, maxLongitudeMicrodeg),
      approximate: false,
    );
    LocationScope.of(context).lastSessionLocation = value;
    Navigator.of(context).pop(value);
  }

  String? _buildHintLine(AppLocalizations l) {
    String? distanceText;
    final user = widget.userLocation;
    if (user != null) {
      final meters = haversineDistanceMeters(
        microdegToDegrees(user.latitudeMicrodeg),
        microdegToDegrees(user.longitudeMicrodeg),
        _lat,
        _lng,
      );
      distanceText = formatDistance(meters);
    }
    final place = _reverseHint;
    if (place != null && place.isNotEmpty && distanceText != null) {
      return l.locationNearPlaceDistance(place, distanceText);
    }
    if (place != null && place.isNotEmpty) {
      return l.locationNearPlace(place);
    }
    if (distanceText != null) {
      return l.locationDistanceFromYou(distanceText);
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final colors = context.nocturne;
    final user = widget.userLocation;
    final currentCoords = LocationValueDto(
      latitudeMicrodeg: degreesToMicrodeg(_lat),
      longitudeMicrodeg: degreesToMicrodeg(_lng),
      approximate: false,
    );
    final hintLine = _buildHintLine(l);

    return Scaffold(
      backgroundColor: colors.bg,
      body: SafeArea(
        child: Stack(
          children: [
            Column(
              children: [
                // Map viewport + floating top bar & recenter button.
                Expanded(
                  child: Stack(
                    children: [
                      OsmMapCanvas(
                        key: const Key('map-picker-canvas'),
                        latitude: _lat,
                        longitude: _lng,
                        zoom: _zoom,
                        interactive: true,
                        allowMeteredNetwork: true,
                        showAttribution: true,
                        showCenterPin: true,
                        userLatitude: user != null
                            ? microdegToDegrees(user.latitudeMicrodeg)
                            : null,
                        userLongitude: user != null
                            ? microdegToDegrees(user.longitudeMicrodeg)
                            : null,
                        onCenterChanged: (lat, lng) {
                          setState(() {
                            _lat = lat;
                            _lng = lng;
                          });
                        },
                        onMoveEnd: (lat, lng) {
                          setState(() {
                            _lat = lat;
                            _lng = lng;
                          });
                          _scheduleReverseGeocode();
                        },
                      ),
                      // Top bar: close/back + Search places pill.
                      Positioned(
                        left: 12,
                        right: 12,
                        top: 12,
                        child: Row(
                          children: [
                            Material(
                              color: colors.surface,
                              shape: const CircleBorder(),
                              elevation: 2,
                              child: IconButton(
                                key: const Key('map-picker-close'),
                                onPressed: () => Navigator.of(context).pop(),
                                icon: Icon(
                                  widget.fullScreen
                                      ? PhosphorIconsRegular.arrowLeft
                                      : PhosphorIconsRegular.x,
                                  size: 18,
                                  color: colors.text,
                                ),
                                tooltip: l.commonCancel,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Material(
                                color: colors.surface,
                                elevation: 2,
                                borderRadius: BorderRadius.circular(24),
                                child: InkWell(
                                  key: const Key('map-picker-search-pill'),
                                  borderRadius: BorderRadius.circular(24),
                                  onTap: _openSearch,
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 14,
                                      vertical: 11,
                                    ),
                                    child: Row(
                                      children: [
                                        Icon(
                                          PhosphorIconsRegular.magnifyingGlass,
                                          size: 16,
                                          color: colors.muted(.6),
                                        ),
                                        const SizedBox(width: 8),
                                        Text(
                                          l.locationSearchPlaces,
                                          style: TextStyle(
                                            fontSize: 13.5,
                                            color: colors.muted(.6),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (user != null)
                        Positioned(
                          right: 12,
                          bottom: 12,
                          child: Material(
                            color: colors.surface,
                            shape: const CircleBorder(),
                            elevation: 2,
                            child: IconButton(
                              key: const Key('map-picker-recenter'),
                              onPressed: _recenterOnUser,
                              icon: Icon(
                                PhosphorIconsRegular.gpsFix,
                                size: 20,
                                color: colors.accent,
                              ),
                              tooltip: l.locationGoToMyLocation,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                // Bottom sheet / panel.
                Container(
                  padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
                  decoration: BoxDecoration(
                    color: colors.surface,
                    border: Border(
                      top: BorderSide(color: colors.divider),
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              widget.fieldName,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: colors.text,
                              ),
                            ),
                          ),
                          Text(
                            l.locationDragMapHint,
                            style: TextStyle(
                              fontSize: 12,
                              color: colors.muted(.6),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Icon(
                            PhosphorIconsRegular.mapPin,
                            size: 16,
                            color: colors.accent,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              formatLocation6dp(currentCoords),
                              key: const Key('map-picker-coords'),
                              style: TextStyle(
                                fontFamily: Nocturne.monoFamily,
                                fontSize: 13.5,
                                color: colors.text,
                              ),
                            ),
                          ),
                          OutlinedButton.icon(
                            key: const Key('map-picker-type-button'),
                            onPressed: _openTypeCoordinates,
                            icon: const Icon(
                              PhosphorIconsRegular.pencilSimple,
                              size: 14,
                            ),
                            label: Text(l.locationTypeAction),
                          ),
                        ],
                      ),
                      if (hintLine != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          hintLine,
                          key: const Key('map-picker-reverse-hint'),
                          style: TextStyle(
                            fontSize: 12,
                            color: colors.muted(.6),
                          ),
                        ),
                      ],
                      const SizedBox(height: 12),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton(
                            onPressed: () => Navigator.of(context).pop(),
                            child: Text(l.commonCancel),
                          ),
                          const SizedBox(width: 8),
                          FilledButton(
                            key: const Key('map-picker-confirm'),
                            onPressed: _confirmSpot,
                            child: Text(l.locationUseThisSpot),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (_searchOpen) _buildSearchOverlay(context),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchOverlay(BuildContext context) {
    final l = context.l10n;
    final colors = context.nocturne;
    final query = _searchController.text.trim();

    return Positioned.fill(
      child: Material(
        color: colors.surface,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 10, 12, 8),
              child: Row(
                children: [
                  IconButton(
                    key: const Key('place-search-back'),
                    onPressed: () => setState(() => _searchOpen = false),
                    icon: const Icon(PhosphorIconsRegular.arrowLeft, size: 18),
                  ),
                  Expanded(
                    child: TextField(
                      key: const Key('place-search-input'),
                      controller: _searchController,
                      autofocus: true,
                      onChanged: _onSearchQueryChanged,
                      decoration: InputDecoration(
                        hintText: l.locationSearchPlaces,
                        border: InputBorder.none,
                        isDense: true,
                      ),
                    ),
                  ),
                  if (_searchController.text.isNotEmpty)
                    IconButton(
                      onPressed: () {
                        _searchController.clear();
                        _onSearchQueryChanged('');
                      },
                      icon: const Icon(PhosphorIconsRegular.x, size: 16),
                    ),
                ],
              ),
            ),
            Divider(height: 1, color: colors.divider),
            Expanded(
              child: _searchOffline
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              PhosphorIconsRegular.wifiSlash,
                              size: 28,
                              color: colors.muted(.6),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              l.locationSearchNeedsInternet,
                              key: const Key('place-search-offline'),
                              style: TextStyle(
                                fontSize: 14,
                                color: colors.muted(.6),
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                  : _searchLoading
                      ? const Center(
                          child: SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      : ListView.builder(
                          itemCount: _searchResults.length,
                          itemBuilder: (context, index) {
                            final item = _searchResults[index];
                            return ListTile(
                              key: Key('place-search-result-$index'),
                              leading: Icon(
                                PhosphorIconsRegular.mapPin,
                                size: 18,
                                color: colors.muted(.6),
                              ),
                              title: _HighlightedMatch(
                                text: item.name,
                                query: query,
                                color: colors.text,
                              ),
                              subtitle: item.subtitle.isNotEmpty
                                  ? Text(
                                      item.subtitle,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: colors.muted(.6),
                                      ),
                                    )
                                  : null,
                              trailing: Text(
                                formatDistance(item.distanceMeters),
                                style: TextStyle(
                                  fontFamily: Nocturne.monoFamily,
                                  fontSize: 12,
                                  color: colors.muted(.6),
                                  fontFeatures: const [
                                    FontFeature.tabularFigures(),
                                  ],
                                ),
                              ),
                              onTap: () {
                                setState(() {
                                  _searchOpen = false;
                                });
                                _moveCenter(item.latitude, item.longitude);
                              },
                            );
                          },
                        ),
            ),
            Divider(height: 1, color: colors.divider),
            ListTile(
              key: const Key('place-search-type-instead'),
              leading: Icon(
                PhosphorIconsRegular.hash,
                size: 18,
                color: colors.accent,
              ),
              title: Text(
                l.locationTypeCoordinatesInstead,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w500,
                  color: colors.accent,
                ),
              ),
              onTap: _openTypeCoordinates,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Text(
                l.locationSearchCaption,
                style: TextStyle(fontSize: 11.5, color: colors.muted(.6)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HighlightedMatch extends StatelessWidget {
  const _HighlightedMatch({
    required this.text,
    required this.query,
    required this.color,
  });

  final String text;
  final String query;
  final Color color;

  @override
  Widget build(BuildContext context) {
    if (query.isEmpty) {
      return Text(text, style: TextStyle(color: color, fontSize: 14));
    }
    final lowerText = text.toLowerCase();
    final lowerQuery = query.toLowerCase();
    final idx = lowerText.indexOf(lowerQuery);
    if (idx < 0) {
      return Text(text, style: TextStyle(color: color, fontSize: 14));
    }
    return RichText(
      text: TextSpan(
        style: TextStyle(color: color, fontSize: 14),
        children: [
          if (idx > 0) TextSpan(text: text.substring(0, idx)),
          TextSpan(
            text: text.substring(idx, idx + query.length),
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          if (idx + query.length < text.length)
            TextSpan(text: text.substring(idx + query.length)),
        ],
      ),
    );
  }
}
