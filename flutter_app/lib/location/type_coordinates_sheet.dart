import 'dart:async';

import 'package:fi/l10n/l10n.dart';
import 'package:fi/location/format.dart';
import 'package:fi/location/services.dart';
import 'package:fi/src/rust/api/models.dart';
import 'package:fi/theme/nocturne.dart';
import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

/// Opens the `Type coordinates` sheet (bottom sheet on phone, modal dialog on desktop).
/// Returns the parsed [LocationValueDto] when the user taps `Show on map`, or null if cancelled.
Future<LocationValueDto?> showTypeCoordinatesSheet(
  BuildContext context, {
  LocationValueDto? initialValue,
}) {
  final services = LocationScope.of(context);
  final phone = Nocturne.isPhone(context);
  if (phone) {
    return showModalBottomSheet<LocationValueDto>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetContext) => LocationScope(
        services: services,
        child: Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
          ),
          child: _TypeCoordinatesBody(initialValue: initialValue),
        ),
      ),
    );
  }
  return showDialog<LocationValueDto>(
    context: context,
    builder: (dialogContext) => LocationScope(
      services: services,
      child: Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: _TypeCoordinatesBody(initialValue: initialValue),
        ),
      ),
    ),
  );
}

class _TypeCoordinatesBody extends StatefulWidget {
  const _TypeCoordinatesBody({this.initialValue});

  final LocationValueDto? initialValue;

  @override
  State<_TypeCoordinatesBody> createState() => _TypeCoordinatesBodyState();
}

class _TypeCoordinatesBodyState extends State<_TypeCoordinatesBody> {
  late final TextEditingController _pasteController;
  late final TextEditingController _latController;
  late final TextEditingController _lngController;

  LocationValueDto? _parsed;
  LocationParseStatusDto? _errorStatus;
  bool _shortLinkOffline = false;
  bool _resolvingLink = false;
  int _resolveToken = 0;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialValue;
    _parsed = initial;
    _pasteController = TextEditingController();
    _latController = TextEditingController(
      text: initial != null ? formatMicrodeg(initial.latitudeMicrodeg, 6) : '',
    );
    _lngController = TextEditingController(
      text: initial != null ? formatMicrodeg(initial.longitudeMicrodeg, 6) : '',
    );
  }

  @override
  void dispose() {
    _pasteController.dispose();
    _latController.dispose();
    _lngController.dispose();
    super.dispose();
  }

  void _onPasteChanged(String text) {
    final trimmed = text.trim();
    _resolveToken++;
    if (trimmed.isEmpty) {
      setState(() {
        _resolvingLink = false;
        _shortLinkOffline = false;
        _errorStatus = null;
      });
      _onLatLngChanged();
      return;
    }

    final services = LocationScope.of(context);
    final result = services.parseLocationText(trimmed);
    switch (result.status) {
      case LocationParseStatusDto.ok:
        final value = result.value!;
        setState(() {
          _parsed = value;
          _errorStatus = null;
          _shortLinkOffline = false;
          _resolvingLink = false;
          _latController.text = formatMicrodeg(value.latitudeMicrodeg, 6);
          _lngController.text = formatMicrodeg(value.longitudeMicrodeg, 6);
        });
      case LocationParseStatusDto.shortLinkNeedsResolution:
        final shortUrl = result.shortLinkUrl ?? trimmed;
        final token = _resolveToken;
        setState(() {
          _parsed = null;
          _errorStatus = null;
          _shortLinkOffline = false;
          _resolvingLink = true;
        });
        unawaited(_resolveShortLink(shortUrl, token));
      case LocationParseStatusDto.latitudeOutOfRange:
      case LocationParseStatusDto.longitudeOutOfRange:
      case LocationParseStatusDto.invalidSyntax:
        setState(() {
          _parsed = null;
          _errorStatus = result.status;
          _shortLinkOffline = false;
          _resolvingLink = false;
        });
    }
  }

  Future<void> _resolveShortLink(String url, int token) async {
    final services = LocationScope.of(context);
    final resolved = await services.resolveShortMapLink(url);
    if (!mounted || token != _resolveToken) return;
    if (resolved.offline) {
      setState(() {
        _resolvingLink = false;
        _shortLinkOffline = true;
        _errorStatus = LocationParseStatusDto.shortLinkNeedsResolution;
        _parsed = null;
      });
      return;
    }
    final target = resolved.resolvedUrl;
    if (target == null || target.isEmpty) {
      setState(() {
        _resolvingLink = false;
        _shortLinkOffline = false;
        _errorStatus = LocationParseStatusDto.invalidSyntax;
        _parsed = null;
      });
      return;
    }
    final parsed = services.parseLocationText(target);
    if (parsed.status == LocationParseStatusDto.ok && parsed.value != null) {
      final value = parsed.value!;
      setState(() {
        _resolvingLink = false;
        _shortLinkOffline = false;
        _errorStatus = null;
        _parsed = value;
        _latController.text = formatMicrodeg(value.latitudeMicrodeg, 6);
        _lngController.text = formatMicrodeg(value.longitudeMicrodeg, 6);
      });
    } else {
      setState(() {
        _resolvingLink = false;
        _shortLinkOffline = false;
        _errorStatus = parsed.status;
        _parsed = null;
      });
    }
  }

  void _onLatLngChanged() {
    final latText = _latController.text.trim();
    final lngText = _lngController.text.trim();
    if (latText.isEmpty && lngText.isEmpty) {
      setState(() {
        _parsed = null;
        _errorStatus = null;
        _shortLinkOffline = false;
      });
      return;
    }
    final services = LocationScope.of(context);
    final result = services.parseLocationText('$latText, $lngText');
    setState(() {
      _resolvingLink = false;
      _shortLinkOffline = false;
      if (result.status == LocationParseStatusDto.ok && result.value != null) {
        _parsed = result.value;
        _errorStatus = null;
      } else {
        _parsed = null;
        _errorStatus = result.status;
      }
    });
  }

  String? _localizedError(AppLocalizations l) {
    if (_shortLinkOffline ||
        _errorStatus == LocationParseStatusDto.shortLinkNeedsResolution) {
      return l.locationShortLinkNeedsInternet;
    }
    return switch (_errorStatus) {
      LocationParseStatusDto.latitudeOutOfRange => l.locationLatitudeOutOfRange,
      LocationParseStatusDto.longitudeOutOfRange => l.locationLongitudeOutOfRange,
      LocationParseStatusDto.invalidSyntax => l.locationInvalidSyntax,
      _ => null,
    };
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final colors = context.nocturne;
    final error = _localizedError(l);

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  l.locationTypeCoordinatesTitle,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: colors.text,
                  ),
                ),
              ),
              IconButton(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(PhosphorIconsRegular.x, size: 18),
                tooltip: l.commonCancel,
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('location-paste-input'),
            controller: _pasteController,
            onChanged: _onPasteChanged,
            decoration: InputDecoration(
              labelText: l.locationCoordinatesOrLink,
              hintText: '38.7139, -9.1334',
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          if (_resolvingLink)
            Row(
              children: [
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 8),
                Text(
                  l.locationResolvingLink,
                  style: TextStyle(fontSize: 12.5, color: colors.muted(.6)),
                ),
              ],
            )
          else if (error != null)
            Row(
              key: const Key('location-type-error'),
              children: [
                Icon(
                  PhosphorIconsRegular.warningCircle,
                  size: 15,
                  color: colors.danger,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    error,
                    style: TextStyle(fontSize: 12.5, color: colors.danger),
                  ),
                ),
              ],
            )
          else if (_parsed != null && _pasteController.text.trim().isNotEmpty)
            Row(
              key: const Key('location-type-found'),
              children: [
                Icon(
                  PhosphorIconsRegular.checkCircle,
                  size: 15,
                  color: colors.success,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    l.locationFoundCoordinates(formatLocation6dp(_parsed!)),
                    style: TextStyle(
                      fontSize: 12.5,
                      color: colors.success,
                      fontFamily: Nocturne.monoFamily,
                    ),
                  ),
                ),
              ],
            ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const Key('location-lat-input'),
                  controller: _latController,
                  keyboardType: const TextInputType.numberWithOptions(
                    signed: true,
                    decimal: true,
                  ),
                  style: const TextStyle(fontFamily: Nocturne.monoFamily),
                  onChanged: (_) => _onLatLngChanged(),
                  decoration: InputDecoration(
                    labelText: l.locationLatitude,
                    border: const OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  key: const Key('location-lng-input'),
                  controller: _lngController,
                  keyboardType: const TextInputType.numberWithOptions(
                    signed: true,
                    decimal: true,
                  ),
                  style: const TextStyle(fontFamily: Nocturne.monoFamily),
                  onChanged: (_) => _onLatLngChanged(),
                  decoration: InputDecoration(
                    labelText: l.locationLongitude,
                    border: const OutlineInputBorder(),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(l.commonCancel),
              ),
              const SizedBox(width: 8),
              FilledButton(
                key: const Key('location-show-on-map'),
                onPressed: _parsed != null && !_resolvingLink
                    ? () => Navigator.of(context).pop(_parsed)
                    : null,
                child: Text(l.locationShowOnMap),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
