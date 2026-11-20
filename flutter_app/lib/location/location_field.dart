import 'dart:async';

import 'package:fi/l10n/l10n.dart';
import 'package:fi/location/format.dart';
import 'package:fi/location/map_canvas.dart';
import 'package:fi/location/map_picker.dart';
import 'package:fi/location/services.dart';
import 'package:fi/src/rust/api/models.dart';
import 'package:fi/theme/form_errors.dart';
import 'package:fi/theme/nocturne.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

enum _AlertKind { none, permissionOff, deviceLocationOff, couldNotLocate }

/// Record form control for [FieldTypeKindDto.location], implementing all 9 states and the
/// one-time inline Android permission primer.
class LocationFieldInput extends StatefulWidget {
  const LocationFieldInput({
    super.key,
    required this.field,
    required this.value,
    required this.onChanged,
    this.errors = const [],
  });

  final FieldDefinitionDto field;
  final FieldValueDto? value;
  final ValueChanged<FieldValueDto?> onChanged;
  final List<String> errors;

  @override
  State<LocationFieldInput> createState() => _LocationFieldInputState();
}

class _LocationFieldInputState extends State<LocationFieldInput> {
  static const int _targetAccuracyMeters = 25;
  static const Duration _locateTimeout = Duration(seconds: 10);

  bool _locating = false;
  bool _showPrimer = false;
  _AlertKind _alert = _AlertKind.none;
  int? _liveAccuracyMeters;
  LocationFix? _bestFix;
  StreamSubscription<LocationFix>? _fixSub;
  Timer? _timeoutTimer;
  LocationValueDto? _lastKnownUserLocation;

  LocationValueDto? get _location =>
      widget.value?.kind == FieldValueKindDto.location
          ? widget.value!.locationValue
          : null;

  @override
  void dispose() {
    _cancelLocating(notify: false);
    super.dispose();
  }

  void _cancelLocating({bool notify = true}) {
    _timeoutTimer?.cancel();
    _timeoutTimer = null;
    final sub = _fixSub;
    _fixSub = null;
    if (sub != null) {
      unawaited(sub.cancel());
    }
    if (notify && mounted) {
      setState(() {
        _locating = false;
        _liveAccuracyMeters = null;
        _bestFix = null;
      });
    }
  }

  Future<void> _onTapCurrentLocation({bool bypassPrimer = false}) async {
    final services = LocationScope.of(context);
    setState(() {
      _alert = _AlertKind.none;
    });

    final status = await services.locationStatus();
    if (!mounted) return;

    if (status.isAndroid) {
      if (!status.isGranted) {
        if (!bypassPrimer && !services.primerShown) {
          setState(() {
            _showPrimer = true;
          });
          return;
        }
        final requested = await services.requestLocationPermission();
        if (!mounted) return;
        if (!requested.isGranted) {
          setState(() {
            _showPrimer = false;
            _alert = _AlertKind.permissionOff;
          });
          return;
        }
        if (!requested.servicesEnabled) {
          setState(() {
            _showPrimer = false;
            _alert = _AlertKind.deviceLocationOff;
          });
          return;
        }
      } else if (!status.servicesEnabled) {
        setState(() {
          _alert = _AlertKind.deviceLocationOff;
        });
        return;
      }
    }

    _startLocating();
  }

  void _startLocating() {
    _cancelLocating(notify: false);
    final services = LocationScope.of(context);
    setState(() {
      _showPrimer = false;
      _locating = true;
      _alert = _AlertKind.none;
      _liveAccuracyMeters = null;
      _bestFix = null;
    });

    _timeoutTimer = Timer(_locateTimeout, _finishWithBestFix);
    _fixSub = services.watchLocationFixes().listen(
      (fix) {
        if (!mounted) return;
        final isBetter = _bestFix == null ||
            (fix.accuracyMeters != null &&
                (_bestFix!.accuracyMeters == null ||
                    fix.accuracyMeters! < _bestFix!.accuracyMeters!));
        if (isBetter) {
          _bestFix = fix;
        }
        setState(() {
          _liveAccuracyMeters = _bestFix?.accuracyMeters ?? fix.accuracyMeters;
        });
        final acc = fix.accuracyMeters;
        if (fix.approximate || (acc != null && acc <= _targetAccuracyMeters)) {
          _finishWithBestFix();
        }
      },
      onError: (_) {
        if (!mounted) return;
        _finishWithBestFix();
      },
      onDone: () {
        if (!mounted) return;
        if (_locating) {
          _finishWithBestFix();
        }
      },
    );
  }

  void _finishWithBestFix() {
    final best = _bestFix;
    _cancelLocating(notify: false);
    if (!mounted) return;
    if (best != null) {
      final dto = best.toDto();
      _lastKnownUserLocation = dto;
      LocationScope.of(context).lastSessionLocation = dto;
      setState(() {
        _locating = false;
        _liveAccuracyMeters = null;
        _bestFix = null;
        _alert = _AlertKind.none;
      });
      widget.onChanged(
        FieldValueDto(
          kind: FieldValueKindDto.location,
          locationValue: dto,
        ),
      );
    } else {
      setState(() {
        _locating = false;
        _liveAccuracyMeters = null;
        _bestFix = null;
        _alert = _AlertKind.couldNotLocate;
      });
    }
  }

  Future<void> _onAllowPrecise() async {
    final services = LocationScope.of(context);
    final status = await services.requestLocationPermission();
    if (!mounted) return;
    if (status.permission == LocationPermissionState.grantedPrecise) {
      if (status.servicesEnabled) {
        _startLocating();
      } else {
        setState(() => _alert = _AlertKind.deviceLocationOff);
      }
    } else if (!status.isGranted) {
      setState(() => _alert = _AlertKind.permissionOff);
    }
  }

  Future<void> _onTurnOnLocation() async {
    final services = LocationScope.of(context);
    await services.openLocationSettings();
    if (!mounted) return;
    final status = await services.locationStatus();
    if (!mounted) return;
    if (status.servicesEnabled && status.isGranted) {
      _startLocating();
    }
  }

  Future<void> _openMapPicker() async {
    final picked = await showLocationMapPicker(
      context,
      fieldName: widget.field.name,
      initialValue: _location,
      userLocation: _lastKnownUserLocation,
    );
    if (!mounted || picked == null) return;
    setState(() {
      _alert = _AlertKind.none;
      _showPrimer = false;
    });
    widget.onChanged(
      FieldValueDto(
        kind: FieldValueKindDto.location,
        locationValue: picked,
      ),
    );
  }

  void _clear() {
    widget.onChanged(null);
  }

  Future<void> _copyCoordinates(LocationValueDto location) async {
    final text = formatLocationCanonical(location);
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(context.l10n.locationCoordinatesCopied),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final colors = context.nocturne;
    final location = _location;
    final hasError = widget.errors.isNotEmpty;
    final showPreview = widget.field.display.showMapPreview;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_showPrimer)
          _buildPrimerCard(context)
        else if (_locating)
          _buildLocatingBox(context)
        else if (location != null && showPreview)
          _buildPopulatedWithPreview(context, location)
        else if (location != null && !showPreview)
          _buildPopulatedCompactRow(context, location)
        else
          _buildEmptyButtons(context, hasError: hasError),
        if (location != null && location.approximate)
          _buildApproximateWarning(context),
        if (_alert == _AlertKind.permissionOff)
          _buildInlineAlert(
            context,
            key: const Key('location-permission-off-alert'),
            icon: PhosphorIconsRegular.gpsSlash,
            message: l.locationPermissionOff,
            actionLabel: l.locationOpenSettings,
            actionKey: const Key('location-open-settings'),
            onAction: () => LocationScope.of(context).openAppSettings(),
          ),
        if (_alert == _AlertKind.deviceLocationOff)
          _buildInlineAlert(
            context,
            key: const Key('location-device-off-alert'),
            icon: PhosphorIconsRegular.gpsSlash,
            message: l.locationDeviceOff,
            actionLabel: l.locationTurnOn,
            actionKey: const Key('location-turn-on'),
            onAction: _onTurnOnLocation,
          ),
        if (_alert == _AlertKind.couldNotLocate)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              l.locationCouldNotLocate,
              style: TextStyle(fontSize: 12, color: colors.danger),
            ),
          ),
        if (hasError)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: FormErrorLines(widget.errors),
          ),
      ],
    );
  }

  Widget _buildEmptyButtons(BuildContext context, {required bool hasError}) {
    final l = context.l10n;
    final colors = context.nocturne;
    final borderColor = hasError ? colors.danger : colors.neutralEdge;
    final buttonStyle = OutlinedButton.styleFrom(
      side: BorderSide(color: borderColor),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
    );
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            key: Key('location-current-${widget.field.id}'),
            style: buttonStyle,
            onPressed: _onTapCurrentLocation,
            icon: const Icon(PhosphorIconsRegular.gpsFix, size: 16),
            label: Text(
              l.locationCurrentLocation,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: OutlinedButton.icon(
            key: Key('location-pick-map-${widget.field.id}'),
            style: buttonStyle,
            onPressed: _openMapPicker,
            icon: const Icon(PhosphorIconsRegular.mapTrifold, size: 16),
            label: Text(
              l.locationPickOnMap,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildLocatingBox(BuildContext context) {
    final l = context.l10n;
    final colors = context.nocturne;
    final statusText = _liveAccuracyMeters != null
        ? l.locationFindingYouAccuracy(formatAccuracy(_liveAccuracyMeters!))
        : l.locationFindingYou;

    return Container(
      key: Key('location-locating-${widget.field.id}'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: colors.neutralFill,
        borderRadius: BorderRadius.circular(Nocturne.radius),
        border: Border.all(color: colors.neutralEdge),
      ),
      child: Row(
        children: [
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              statusText,
              style: TextStyle(
                fontFamily: Nocturne.monoFamily,
                fontSize: 13,
                color: colors.text,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          TextButton(
            key: Key('location-cancel-locate-${widget.field.id}'),
            onPressed: () => _cancelLocating(),
            child: Text(l.commonCancel),
          ),
        ],
      ),
    );
  }

  Widget _buildPrimerCard(BuildContext context) {
    final l = context.l10n;
    final colors = context.nocturne;
    final services = LocationScope.of(context);

    return Container(
      key: const Key('location-permission-primer'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.neutralFill,
        borderRadius: BorderRadius.circular(Nocturne.radius),
        border: Border.all(color: colors.neutralEdge),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(PhosphorIconsRegular.mapPin, size: 16, color: colors.accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l.locationPrimerTitle,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: colors.text,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            l.locationPrimerBody,
            style: TextStyle(fontSize: 12.5, color: colors.muted(.6)),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                key: const Key('location-primer-not-now'),
                onPressed: () => setState(() => _showPrimer = false),
                child: Text(l.locationPrimerNotNow),
              ),
              const SizedBox(width: 8),
              FilledButton(
                key: const Key('location-primer-continue'),
                onPressed: () {
                  services.markPrimerShown();
                  _onTapCurrentLocation(bypassPrimer: true);
                },
                child: Text(l.locationPrimerContinue),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPopulatedWithPreview(
    BuildContext context,
    LocationValueDto location,
  ) {
    final l = context.l10n;
    final colors = context.nocturne;
    final coordsText = formatLocationCanonical(location);

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Nocturne.radius),
        border: Border.all(color: colors.neutralEdge),
        color: colors.surface,
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 132,
            child: Stack(
              fit: StackFit.expand,
              children: [
                GestureDetector(
                  key: Key('location-preview-map-${widget.field.id}'),
                  onTap: _openMapPicker,
                  child: OsmMapCanvas(
                    latitude: microdegToDegrees(location.latitudeMicrodeg),
                    longitude: microdegToDegrees(location.longitudeMicrodeg),
                    zoom: 15.0,
                    interactive: false,
                    allowMeteredNetwork: true,
                    showAttribution: true,
                    showCenterPin: true,
                    offlinePlaceholder: MapOfflinePlaceholder(
                      key: Key('location-offline-placeholder-${widget.field.id}'),
                      label: l.locationMapNeedsInternet,
                    ),
                  ),
                ),
                if (!widget.field.required_)
                  Positioned(
                    top: 6,
                    right: 6,
                    child: Material(
                      color: colors.surface.withValues(alpha: 0.9),
                      shape: const CircleBorder(),
                      child: InkWell(
                        key: Key('location-clear-${widget.field.id}'),
                        customBorder: const CircleBorder(),
                        onTap: _clear,
                        child: Padding(
                          padding: const EdgeInsets.all(6),
                          child: Icon(
                            PhosphorIconsRegular.x,
                            size: 14,
                            color: colors.text,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 6, 4),
            child: Row(
              children: [
                Icon(
                  PhosphorIconsRegular.mapPin,
                  size: 15,
                  color: colors.accent,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Wrap(
                    spacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        coordsText,
                        key: Key('location-coords-${widget.field.id}'),
                        style: TextStyle(
                          fontFamily: Nocturne.monoFamily,
                          fontSize: 13,
                          color: colors.text,
                        ),
                      ),
                      if (location.accuracyMeters != null)
                        Text(
                          '±${formatAccuracy(location.accuracyMeters!)}',
                          key: Key('location-accuracy-${widget.field.id}'),
                          style: TextStyle(
                            fontFamily: Nocturne.monoFamily,
                            fontSize: 11.5,
                            color: colors.muted(.6),
                          ),
                        ),
                    ],
                  ),
                ),
                IconButton(
                  key: Key('location-copy-${widget.field.id}'),
                  tooltip: l.locationCopyCoordinates,
                  onPressed: () => _copyCoordinates(location),
                  icon: Icon(
                    PhosphorIconsRegular.copy,
                    size: 16,
                    color: colors.muted(.6),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    key: Key('location-current-${widget.field.id}'),
                    onPressed: _onTapCurrentLocation,
                    icon: const Icon(PhosphorIconsRegular.gpsFix, size: 15),
                    label: Text(
                      l.locationCurrentLocation,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    key: Key('location-move-pin-${widget.field.id}'),
                    onPressed: _openMapPicker,
                    icon: const Icon(PhosphorIconsRegular.mapTrifold, size: 15),
                    label: Text(
                      l.locationMovePin,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPopulatedCompactRow(
    BuildContext context,
    LocationValueDto location,
  ) {
    final l = context.l10n;
    final colors = context.nocturne;
    final coordsText = formatLocationCanonical(location);

    return Container(
      key: Key('location-compact-row-${widget.field.id}'),
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Nocturne.radius),
        border: Border.all(color: colors.neutralEdge),
        color: colors.surface,
      ),
      child: Row(
        children: [
          Icon(
            PhosphorIconsRegular.mapPin,
            size: 16,
            color: colors.accent,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              coordsText,
              key: Key('location-coords-${widget.field.id}'),
              style: TextStyle(
                fontFamily: Nocturne.monoFamily,
                fontSize: 13,
                color: colors.text,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (!widget.field.required_)
            IconButton(
              key: Key('location-clear-${widget.field.id}'),
              tooltip: l.commonClear,
              onPressed: _clear,
              icon: Icon(
                PhosphorIconsRegular.x,
                size: 16,
                color: colors.muted(.6),
              ),
            ),
          IconButton(
            key: Key('location-pick-map-${widget.field.id}'),
            tooltip: l.locationPickOnMap,
            onPressed: _openMapPicker,
            icon: Icon(
              PhosphorIconsRegular.mapTrifold,
              size: 18,
              color: colors.muted(.6),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildApproximateWarning(BuildContext context) {
    final l = context.l10n;
    final colors = context.nocturne;

    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        key: const Key('location-approximate-warning'),
        children: [
          Icon(
            PhosphorIconsRegular.warning,
            size: 15,
            color: colors.warning,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              l.locationApproximateWarning,
              style: TextStyle(fontSize: 12, color: colors.text),
            ),
          ),
          TextButton(
            key: const Key('location-allow-precise'),
            onPressed: _onAllowPrecise,
            child: Text(l.locationAllowPrecise),
          ),
        ],
      ),
    );
  }

  Widget _buildInlineAlert(
    BuildContext context, {
    required Key key,
    required IconData icon,
    required String message,
    required String actionLabel,
    required Key actionKey,
    required VoidCallback onAction,
  }) {
    final colors = context.nocturne;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Container(
        key: key,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: colors.neutralFill,
          borderRadius: BorderRadius.circular(Nocturne.radius),
          border: Border.all(color: colors.neutralEdge),
        ),
        child: Row(
          children: [
            Icon(icon, size: 15, color: colors.warning),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message,
                style: TextStyle(fontSize: 12.5, color: colors.text),
              ),
            ),
            TextButton(
              key: actionKey,
              onPressed: onAction,
              child: Text(actionLabel),
            ),
          ],
        ),
      ),
    );
  }
}

/// Opens the `Open in` menu for a populated [LocationValueDto] in view mode.
Future<void> showLocationOpenInMenu(
  BuildContext context,
  LocationValueDto location, {
  RelativeRect? position,
}) async {
  final l = context.l10n;
  final services = LocationScope.of(context);

  Future<void> handle(String action) async {
    switch (action) {
      case 'google':
        await services.openExternalUrl(googleMapsUrl(location));
      case 'waze':
        await services.openExternalUrl(wazeUrl(location));
      case 'other':
        await services.openExternalUrl(geoUri(location), chooser: true);
      case 'copy':
        await Clipboard.setData(
          ClipboardData(text: formatLocationCanonical(location)),
        );
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(l.locationCoordinatesCopied),
              duration: const Duration(seconds: 2),
            ),
          );
        }
    }
  }

  final items = <PopupMenuEntry<String>>[
    PopupMenuItem(
      value: 'google',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(PhosphorIconsRegular.googleLogo, size: 16),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              l.locationOpenInGoogleMaps,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    ),
    PopupMenuItem(
      value: 'waze',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(PhosphorIconsRegular.navigationArrow, size: 16),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              l.locationNavigateWithWaze,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    ),
    if (services.isAndroid)
      PopupMenuItem(
        value: 'other',
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(PhosphorIconsRegular.arrowSquareOut, size: 16),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                l.locationOpenInAnotherApp,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    const PopupMenuDivider(),
    PopupMenuItem(
      value: 'copy',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(PhosphorIconsRegular.copy, size: 16),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              l.locationCopyCoordinates,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    ),
  ];

  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
  final rect = position ??
      RelativeRect.fromLTRB(
        overlay.size.width / 2,
        overlay.size.height / 2,
        overlay.size.width / 2,
        overlay.size.height / 2,
      );
  final chosen = await showMenu<String>(
    context: context,
    position: rect,
    items: items,
  );
  if (chosen != null) {
    await handle(chosen);
  }
}

/// Desktop table cell for a populated [LocationValueDto]: 4-decimal monospace coordinates,
/// hover quick buttons for Google Maps and Waze, and click to open the `Open in` menu.
class LocationTableCell extends StatefulWidget {
  const LocationTableCell({
    super.key,
    required this.location,
  });

  final LocationValueDto location;

  @override
  State<LocationTableCell> createState() => _LocationTableCellState();
}

class _LocationTableCellState extends State<LocationTableCell> {
  bool _hovered = false;

  void _openMenu() {
    final box = context.findRenderObject() as RenderBox?;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    RelativeRect? rect;
    if (box != null) {
      final offset = box.localToGlobal(Offset.zero, ancestor: overlay);
      rect = RelativeRect.fromRect(
        offset & box.size,
        Offset.zero & overlay.size,
      );
    }
    unawaited(showLocationOpenInMenu(context, widget.location, position: rect));
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final colors = context.nocturne;
    final services = LocationScope.of(context);

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Expanded(
            child: InkWell(
              key: const Key('location-table-coords'),
              borderRadius: BorderRadius.circular(4),
              onTap: _openMenu,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      PhosphorIconsRegular.mapPin,
                      size: 14,
                      color: colors.muted(.6),
                    ),
                    const SizedBox(width: 5),
                    Flexible(
                      child: Text(
                        formatLocation4dp(widget.location),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: Nocturne.monoFamily,
                          fontSize: 12.5,
                          color: colors.text,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (_hovered) ...[
            const SizedBox(width: 4),
            IconButton(
              key: const Key('location-table-google-maps'),
              tooltip: l.locationOpenInGoogleMaps,
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
              icon: Icon(
                PhosphorIconsRegular.googleLogo,
                size: 14,
                color: colors.muted(.6),
              ),
              onPressed: () =>
                  services.openExternalUrl(googleMapsUrl(widget.location)),
            ),
            IconButton(
              key: const Key('location-table-waze'),
              tooltip: l.locationNavigateWithWaze,
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
              icon: Icon(
                PhosphorIconsRegular.navigationArrow,
                size: 14,
                color: colors.muted(.6),
              ),
              onPressed: () =>
                  services.openExternalUrl(wazeUrl(widget.location)),
            ),
          ],
        ],
      ),
    );
  }
}

/// Mobile record card view for a populated [LocationValueDto]: optional 64×64 map thumbnail
/// (respecting `showMapPreview` and mobile-data gating), field label, 4-decimal monospace
/// coordinates, and side-by-side Google Maps and Waze buttons.
class LocationCardView extends StatelessWidget {
  const LocationCardView({
    super.key,
    required this.fieldName,
    required this.location,
    required this.showMapPreview,
  });

  final String fieldName;
  final LocationValueDto location;
  final bool showMapPreview;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final colors = context.nocturne;
    final services = LocationScope.of(context);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showMapPreview) ...[
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              key: const Key('location-card-thumbnail'),
              width: 64,
              height: 64,
              child: OsmMapCanvas(
                latitude: microdegToDegrees(location.latitudeMicrodeg),
                longitude: microdegToDegrees(location.longitudeMicrodeg),
                zoom: 15.0,
                interactive: false,
                // Mobile data safeguard: card list thumbnails never auto-fetch uncached
                // tiles on metered mobile data.
                allowMeteredNetwork: false,
                showAttribution: false,
                showCenterPin: true,
                compactPin: true,
              ),
            ),
          ),
          const SizedBox(width: 10),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                fieldName,
                style: TextStyle(fontSize: 11.5, color: colors.muted(.6)),
              ),
              const SizedBox(height: 2),
              Text(
                formatLocation4dp(location),
                style: TextStyle(
                  fontFamily: Nocturne.monoFamily,
                  fontSize: 12.5,
                  color: colors.text,
                ),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      key: const Key('location-card-google-maps'),
                      style: OutlinedButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 6,
                        ),
                      ),
                      onPressed: () =>
                          services.openExternalUrl(googleMapsUrl(location)),
                      icon: const Icon(PhosphorIconsRegular.googleLogo, size: 13),
                      label: Text(
                        l.locationGoogleMaps,
                        style: const TextStyle(fontSize: 12),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: OutlinedButton.icon(
                      key: const Key('location-card-waze'),
                      style: OutlinedButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 6,
                        ),
                      ),
                      onPressed: () =>
                          services.openExternalUrl(wazeUrl(location)),
                      icon: const Icon(
                        PhosphorIconsRegular.navigationArrow,
                        size: 13,
                      ),
                      label: Text(
                        l.locationWaze,
                        style: const TextStyle(fontSize: 12),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}
