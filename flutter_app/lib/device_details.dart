import 'dart:async';

import 'package:clock/clock.dart';
import 'package:fi/controllers.dart';
import 'package:fi/src/rust/api/models.dart';
import 'package:fi/status_time.dart';
import 'package:fi/theme/fi_icons.dart';
import 'package:fi/theme/nocturne.dart';
import 'package:fi/theme/nocturne_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

/// A DeviceId shortened to its first and last eight characters.
String shortDeviceId(String id) => id.length <= 16
    ? id
    : '${id.substring(0, 8)}…${id.substring(id.length - 8)}';

/// A DeviceId in groups of eight characters, the middle groups elided: `01234567 89abcdef …
/// 01234567 89abcdef`.
String groupedDeviceId(String id) {
  final groups = [
    for (var start = 0; start < id.length; start += 8)
      id.substring(start, start + 8 > id.length ? id.length : start + 8),
  ];
  if (groups.length <= 4) return groups.join(' ');
  return [...groups.take(2), '…', ...groups.skip(groups.length - 2)].join(' ');
}

String connectionLabel(PeerConnectionKindDto state) => switch (state) {
  PeerConnectionKindDto.offline => 'Offline',
  PeerConnectionKindDto.searching => 'Searching',
  PeerConnectionKindDto.connected => 'Connected',
  PeerConnectionKindDto.syncing => 'Syncing',
  PeerConnectionKindDto.synced => 'Synced',
  PeerConnectionKindDto.error => 'Error',
  PeerConnectionKindDto.paused => 'Paused',
};

/// A trusted row's state: accent with a dot while connected, syncing or synced; neutral
/// otherwise.
class DeviceStateTag extends StatelessWidget {
  const DeviceStateTag({required this.device, super.key});

  final TrustedDeviceDto device;

  @override
  Widget build(BuildContext context) =>
      switch ((device.revoked, device.connection)) {
        (true, _) => const Tag.neutral('Revoked'),
        (
          _,
          PeerConnectionKindDto.connected ||
              PeerConnectionKindDto.syncing ||
              PeerConnectionKindDto.synced,
        ) =>
          Tag(connectionLabel(device.connection), leading: FiIcons.dot),
        _ => Tag.neutral(connectionLabel(device.connection)),
      };
}

/// "Seen <time> · Synced <time>", with "Never seen" / "Never synced" for absent values.
String seenSyncedLine(TrustedDeviceDto device, DateTime now) => [
  device.lastSeenMs == null
      ? 'Never seen'
      : 'Seen ${formatStatusTime(device.lastSeenMs, now: now)}',
  device.lastSyncMs == null
      ? 'Never synced'
      : 'Synced ${formatStatusTime(device.lastSyncMs, now: now)}',
].join(' · ');

/// Which connection log lines Details shows.
enum LogFilter { all, pairing, peer }

/// Copies [text] and confirms with [message].
Future<void> copyWithConfirmation(
  BuildContext context,
  String text,
  String message,
) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  await Clipboard.setData(ClipboardData(text: text));
  messenger?.showSnackBar(SnackBar(content: Text(message)));
}

/// A trusted device's Details (mocks 5e, 5f): the state grid, the failure, the full DeviceId
/// with copy, the categorized connection log, and Reconnect / Copy log.
///
/// Inline under the row at 720px and wider ([compact] false); the body of
/// [DeviceDetailsScreen] on a phone.
class DeviceDetails extends StatefulWidget {
  const DeviceDetails({
    required this.device,
    required this.controller,
    required this.now,
    required this.onCopyLog,
    this.compact = false,
    super.key,
  });

  final TrustedDeviceDto device;
  final DevicesController controller;
  final DateTime now;
  final VoidCallback onCopyLog;
  final bool compact;

  @override
  State<DeviceDetails> createState() => _DeviceDetailsState();
}

class _DeviceDetailsState extends State<DeviceDetails> {
  var _filter = LogFilter.all;

  TrustedDeviceDto get device => widget.device;
  DevicesController get controller => widget.controller;

  bool _shown(LogEventDto event) => switch (_filter) {
    LogFilter.all => true,
    LogFilter.pairing => logCategory(event) == LogCategory.pairing,
    LogFilter.peer => switch (logCategory(event)) {
      LogCategory.peer || LogCategory.address => true,
      _ => false,
    },
  };

  @override
  Widget build(BuildContext context) {
    final id = device.deviceId;
    final compact = widget.compact;
    final logs = controller.details[id];
    final events = logs == null
        ? const <LogEventDto>[]
        : ([...logs.peer, ...logs.local]
            ..sort((a, b) => a.atMs.compareTo(b.atMs)));
    final shown = compact ? events : events.where(_shown).toList();
    final facts = [
      (
        'State',
        device.revoked ? 'Revoked' : connectionLabel(device.connection),
      ),
      ('Endpoint', device.attemptEndpoint ?? '—'),
      (
        'Last attempt',
        device.lastAttemptMs == null
            ? '—'
            : formatStatusTime(device.lastAttemptMs, now: widget.now),
      ),
      ('Sync port', '${controller.syncPort ?? 'not bound'}'),
    ];
    final label = TextStyle(
      fontSize: 11,
      letterSpacing: .88,
      color: Nocturne.muted(.5),
    );
    const value = TextStyle(fontSize: 13, fontFeatures: Nocturne.tabular);
    const mono = TextStyle(fontFamily: Nocturne.monoFamily, fontSize: 12);
    final onReconnect = controller.reconnecting.contains(id)
        ? null
        : () => unawaited(controller.reconnect(device));
    final Widget? reconnect = device.revoked
        ? null
        : compact
        ? SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              key: Key('device-reconnect-$id'),
              onPressed: onReconnect,
              icon: const Icon(FiIcons.refresh, size: 18),
              label: const Text('Reconnect'),
            ),
          )
        : OutlinedButton.icon(
            key: Key('device-reconnect-$id'),
            onPressed: onReconnect,
            icon: const Icon(FiIcons.refresh, size: 18),
            label: const Text('Reconnect'),
          );
    final copyLog = compact
        ? TextButton.icon(
            key: Key('device-copy-$id'),
            onPressed: widget.onCopyLog,
            icon: const Icon(FiIcons.copy, size: 16),
            label: const Text('Copy'),
          )
        : OutlinedButton.icon(
            key: Key('device-copy-$id'),
            onPressed: widget.onCopyLog,
            icon: const Icon(FiIcons.copy, size: 18),
            label: const Text('Copy log'),
          );
    return Column(
      key: Key('device-details-panel-$id'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (compact)
          for (final (name, text) in facts)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  SizedBox(width: 110, child: Text(name, style: label)),
                  Expanded(
                    child: Text(
                      text,
                      key: Key('device-fact-$name'),
                      textAlign: TextAlign.right,
                      style: value,
                    ),
                  ),
                ],
              ),
            )
        else
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final (name, text) in facts)
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name.toUpperCase(), style: label),
                      const SizedBox(height: 4),
                      Text(
                        text,
                        key: Key('device-fact-$name'),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: value,
                      ),
                    ],
                  ),
                ),
            ],
          ),
        if (device.failure case final failure?) ...[
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(FiIcons.error, size: 15, color: Nocturne.error),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  failure,
                  key: Key('device-failure-$id'),
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: 12),
        Row(
          children: [
            SizedBox(
              width: compact ? 110 : 90,
              child: Text('ID', style: label),
            ),
            Expanded(
              child: SelectableText(
                compact ? shortDeviceId(id) : id,
                key: Key('device-id-$id'),
                maxLines: 1,
                style: mono,
              ),
            ),
            FiIconButton(
              key: Key('device-copy-id-$id'),
              icon: FiIcons.copy,
              tooltip: 'Copy ID',
              onPressed: () =>
                  unawaited(copyWithConfirmation(context, id, 'ID copied')),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: Text(
                'Connection log · ${events.length} '
                '${events.length == 1 ? 'event' : 'events'}',
                key: Key('device-log-heading-$id'),
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            if (compact)
              copyLog
            else
              SegmentedButton<LogFilter>(
                key: Key('device-log-filter-$id'),
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: LogFilter.all, label: Text('All')),
                  ButtonSegment(
                    value: LogFilter.pairing,
                    label: Text('Pairing'),
                  ),
                  ButtonSegment(value: LogFilter.peer, label: Text('Peer')),
                ],
                selected: {_filter},
                onSelectionChanged: (value) =>
                    setState(() => _filter = value.single),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Container(
          key: Key('device-log-$id'),
          constraints: const BoxConstraints(maxHeight: 240),
          decoration: BoxDecoration(
            color: Nocturne.bg,
            borderRadius: BorderRadius.circular(Nocturne.radius),
            border: Border.all(color: Nocturne.divider),
          ),
          child: logs == null
              ? const Padding(
                  padding: EdgeInsets.all(10),
                  child: Text('Loading…', style: mono),
                )
              : shown.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(10),
                  child: Text(
                    'No events.',
                    style: mono.copyWith(color: Nocturne.muted(.5)),
                  ),
                )
              : SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  child: SelectionArea(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      spacing: 4,
                      children: [for (final event in shown) LogLineRow(event)],
                    ),
                  ),
                ),
        ),
        const SizedBox(height: 12),
        if (compact) ...[
          ?reconnect,
        ] else
          Wrap(spacing: 8, children: [?reconnect, copyLog]),
      ],
    );
  }
}

/// One connection log line: time (HH:mm:ss), category, and the event's technical text.
class LogLineRow extends StatelessWidget {
  const LogLineRow(this.event, {super.key});

  final LogEventDto event;

  static final _time = DateFormat('HH:mm:ss');
  static const _mono = TextStyle(fontFamily: Nocturne.monoFamily, fontSize: 12);

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SizedBox(
        width: 70,
        child: Text(
          _time.format(DateTime.fromMillisecondsSinceEpoch(event.atMs)),
          style: _mono.copyWith(color: Nocturne.muted(.5)),
        ),
      ),
      SizedBox(
        width: 64,
        child: Text(
          logCategory(event).name,
          style: _mono.copyWith(color: Nocturne.accent300),
        ),
      ),
      Expanded(child: Text(logMessage(event), style: _mono)),
    ],
  );
}

/// Details as a pushed screen on a phone (mock 5f): titled with the friendly name, with back
/// and the row's ⋮ menu. It follows the device as Rust updates it and closes when it is gone.
class DeviceDetailsScreen extends StatefulWidget {
  const DeviceDetailsScreen({
    required this.deviceId,
    required this.controller,
    required this.menu,
    required this.onCopyLog,
    super.key,
  });

  final String deviceId;
  final DevicesController controller;

  /// The row's ⋮ menu for the current record.
  final Widget Function(BuildContext context, TrustedDeviceDto device) menu;
  final void Function(BuildContext context, TrustedDeviceDto device) onCopyLog;

  @override
  State<DeviceDetailsScreen> createState() => _DeviceDetailsScreenState();
}

class _DeviceDetailsScreenState extends State<DeviceDetailsScreen> {
  late final Timer _ticker;

  @override
  void initState() {
    super.initState();
    // Relative times go stale without device events.
    _ticker = Timer.periodic(
      const Duration(minutes: 1),
      (_) => setState(() {}),
    );
  }

  @override
  void dispose() {
    _ticker.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final device = widget.controller.devices
          .where((item) => item.deviceId == widget.deviceId)
          .firstOrNull;
      return Scaffold(
        key: const Key('device-details-screen'),
        body: SafeArea(
          child: device == null
              ? const SizedBox.shrink()
              : ListView(
                  padding: const EdgeInsets.fromLTRB(8, 8, 16, 24),
                  children: [
                    Row(
                      children: [
                        FiIconButton(
                          icon: FiIcons.back,
                          tooltip: 'Back',
                          size: 20,
                          onPressed: () => Navigator.maybePop(context),
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            device.friendlyName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                        widget.menu(context, device),
                      ],
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 10, 0, 0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Align(
                            alignment: Alignment.centerLeft,
                            child: DeviceStateTag(device: device),
                          ),
                          const SizedBox(height: 12),
                          DeviceDetails(
                            device: device,
                            controller: widget.controller,
                            now: clock.now(),
                            compact: true,
                            onCopyLog: () => widget.onCopyLog(context, device),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
        ),
      );
    },
  );
}
