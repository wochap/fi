import 'dart:async';

import 'package:fi/bridge/collection_bridge.dart';
import 'package:fi/controllers.dart';
import 'package:fi/src/rust/api/models.dart';
import 'package:fi/collections_page.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class CollectionApp extends StatefulWidget {
  const CollectionApp({
    required this.bridge,
    required this.initializeRust,
    required this.dataDirProvider,
    this.setPlatformForeground,
    super.key,
  });

  final CollectionBridge bridge;
  final Future<void> Function() initializeRust;
  final Future<String> Function() dataDirProvider;
  final Future<void> Function(bool foreground)? setPlatformForeground;

  @override
  State<CollectionApp> createState() => _CollectionAppState();
}

class _CollectionAppState extends State<CollectionApp>
    with WidgetsBindingObserver {
  late final BootstrapController controller;
  static const _platform = MethodChannel('fi/platform');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    controller = BootstrapController(
      bridge: widget.bridge,
      initializeRust: widget.initializeRust,
      dataDirProvider: widget.dataDirProvider,
    );
    unawaited(_start());
  }

  Future<void> _start() async {
    await _setPlatformForeground(true);
    await controller.start();
    await _setForeground(true);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    unawaited(_setForeground(state == AppLifecycleState.resumed));
  }

  Future<void> _setForeground(bool foreground) async {
    try {
      await widget.bridge.setForeground(foreground);
    } catch (_) {
      // Rust exposes lifecycle failures through its typed error stream.
    }
    await _setPlatformForeground(foreground);
  }

  Future<void> _setPlatformForeground(bool foreground) async {
    if (widget.setPlatformForeground case final callback?) {
      await callback(foreground);
    } else if (defaultTargetPlatform == TargetPlatform.android) {
      try {
        await _platform.invokeMethod<void>('setForeground', foreground);
      } on PlatformException {
        // Initialization below maps the unavailable capability to app state.
      }
    }
  }

  @override
  void dispose() {
    controller.dispose();
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_setForeground(false));
    unawaited(widget.bridge.shutdown());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Fi',
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
      useMaterial3: true,
    ),
    home: ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        if (controller.loading) {
          return const _CenteredSurface(
            key: Key('bootstrap-loading'),
            child: CircularProgressIndicator(),
          );
        }
        if (controller.fatalError case final message?) {
          return _CenteredSurface(
            key: const Key('bootstrap-error'),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline, size: 48),
                const SizedBox(height: 12),
                Text(message, textAlign: TextAlign.center),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: controller.start,
                  child: const Text('Retry'),
                ),
              ],
            ),
          );
        }
        return switch (controller.state?.kind) {
          BootstrapKindDto.ready => CollectionShell(bridge: widget.bridge),
          BootstrapKindDto.needsDecision => OnboardingPage(
            controller: controller,
          ),
          BootstrapKindDto.joining => const _CenteredSurface(
            child: Text('Waiting for this local dataset to become available.'),
          ),
          BootstrapKindDto.creating => const _CenteredSurface(
            child: CircularProgressIndicator(),
          ),
          _ => const _CenteredSurface(
            child: Text('The local collection service is unavailable.'),
          ),
        };
      },
    ),
  );
}

class _CenteredSurface extends StatelessWidget {
  const _CenteredSurface({required this.child, super.key});
  final Widget child;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: Padding(padding: const EdgeInsets.all(24), child: child),
    ),
  );
}

class OnboardingPage extends StatelessWidget {
  const OnboardingPage({required this.controller, super.key});
  final BootstrapController controller;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Your private collection space',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 12),
              const Text(
                'Create a new local dataset to begin. Nothing is sent to a server.',
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                key: const Key('create-dataset'),
                onPressed: controller.creating
                    ? null
                    : controller.createNewDataset,
                icon: const Icon(Icons.add_circle_outline),
                label: Text(
                  controller.creating ? 'Creating…' : 'Create new dataset',
                ),
              ),
              const SizedBox(height: 12),
              const OutlinedButton(
                onPressed: null,
                child: Text('Join an existing dataset'),
              ),
              const SizedBox(height: 8),
              const Text(
                'Joining will be available after secure device pairing is implemented.',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class CollectionShell extends StatefulWidget {
  const CollectionShell({required this.bridge, super.key});
  final CollectionBridge bridge;

  @override
  State<CollectionShell> createState() => _CollectionShellState();
}

class _CollectionShellState extends State<CollectionShell> {
  late final CollectionsController controller;
  late final DevicesController devices;
  int selected = 0;

  @override
  void initState() {
    super.initState();
    controller = CollectionsController(widget.bridge);
    devices = DevicesController(widget.bridge);
    unawaited(controller.start());
    unawaited(devices.start());
  }

  @override
  void dispose() {
    controller.dispose();
    devices.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([controller, devices]),
    builder: (context, _) => Scaffold(
      appBar: AppBar(
        title: const Text('Fi'),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Center(child: Text(_statusText(devices.syncStatus))),
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final page = IndexedStack(
            index: selected,
            children: [
              CollectionsPage(controller: controller),
              DevicesPage(controller: devices),
            ],
          );
          if (constraints.maxWidth >= 720) {
            return Row(
              children: [
                NavigationRail(
                  selectedIndex: selected,
                  onDestinationSelected: (value) {
                    setState(() => selected = value);
                  },
                  labelType: NavigationRailLabelType.all,
                  destinations: const [
                    NavigationRailDestination(
                      icon: Icon(Icons.dataset_outlined),
                      label: Text('Collections'),
                    ),
                    NavigationRailDestination(
                      icon: Icon(Icons.devices),
                      label: Text('Devices'),
                    ),
                  ],
                ),
                const VerticalDivider(width: 1),
                Expanded(child: page),
              ],
            );
          }
          return page;
        },
      ),
      bottomNavigationBar: MediaQuery.sizeOf(context).width < 720
          ? NavigationBar(
              selectedIndex: selected,
              onDestinationSelected: (value) {
                setState(() => selected = value);
              },
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.dataset_outlined),
                  label: 'Collections',
                ),
                NavigationDestination(
                  icon: Icon(Icons.devices),
                  label: 'Devices',
                ),
              ],
            )
          : null,
    ),
  );
}

String _statusText(SyncStatusDto status) => switch (status) {
  SyncStatusDto.offline => 'Offline',
  SyncStatusDto.searching => 'Searching',
  SyncStatusDto.connected => 'Connected',
  SyncStatusDto.syncing => 'Syncing',
  SyncStatusDto.synced => 'Synced',
  SyncStatusDto.error => 'Error',
};

class DevicesPage extends StatelessWidget {
  const DevicesPage({required this.controller, super.key});
  final DevicesController controller;

  @override
  Widget build(BuildContext context) => ListView(
    key: const Key('devices-page'),
    padding: const EdgeInsets.all(16),
    children: [
      Row(
        children: [
          Expanded(
            child: Text(
              'Devices',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
          ),
          _SyncChip(status: controller.syncStatus),
        ],
      ),
      const SizedBox(height: 16),
      if (controller.errorMessage case final error?) _ErrorBanner(error),
      _PairingCard(controller: controller),
      const SizedBox(height: 24),
      Text('Trusted devices', style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 8),
      if (controller.devices.isEmpty)
        const Text('No devices have been paired yet.')
      else
        ...controller.devices.map(
          (device) => Card(
            key: Key('device-${device.deviceId}'),
            child: ListTile(
              leading: Icon(device.revoked ? Icons.block : Icons.devices_other),
              title: Text(device.friendlyName),
              subtitle: Text(
                '${_shortDeviceId(device.deviceId)} · '
                '${device.revoked ? 'Revoked' : _connectionText(device.connection)}\n'
                'Last seen ${_timestamp(device.lastSeenMs)} · '
                'Last sync ${_timestamp(device.lastSyncMs)}',
              ),
              isThreeLine: true,
              trailing: PopupMenuButton<String>(
                onSelected: (action) {
                  if (action == 'rename') _renameDevice(context, device);
                  if (action == 'revoke') _revokeDevice(context, device);
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'rename', child: Text('Rename')),
                  if (!device.revoked)
                    const PopupMenuItem(
                      value: 'revoke',
                      child: Text('Revoke / unpair'),
                    ),
                ],
              ),
            ),
          ),
        ),
    ],
  );

  Future<void> _renameDevice(
    BuildContext context,
    TrustedDeviceDto device,
  ) async {
    var name = device.friendlyName;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Rename device'),
        content: TextFormField(
          key: const Key('device-name'),
          initialValue: name,
          onChanged: (value) => name = value,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Friendly name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              await controller.rename(device, name);
              if (dialogContext.mounted) Navigator.pop(dialogContext);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<void> _revokeDevice(
    BuildContext context,
    TrustedDeviceDto device,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Revoke ${device.friendlyName}?'),
        content: const Text(
          'This device will be disconnected and will no longer be trusted. '
          'Its record is retained as revoked.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Revoke'),
          ),
        ],
      ),
    );
    if (confirmed == true) await controller.revoke(device);
  }
}

class _PairingCard extends StatelessWidget {
  const _PairingCard({required this.controller});
  final DevicesController controller;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Pair a device', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          ..._content(context),
        ],
      ),
    ),
  );

  List<Widget> _content(
    BuildContext context,
  ) => switch (controller.pairing.kind) {
    PairingKindDto.idle => [
      const Text('Pairing is off. Start it only when both devices are nearby.'),
      const SizedBox(height: 12),
      FilledButton.icon(
        key: const Key('start-pairing'),
        onPressed: controller.busy ? null : controller.beginPairing,
        icon: const Icon(Icons.link),
        label: const Text('Start pairing'),
      ),
    ],
    PairingKindDto.discoverable => [
      Text(
        'Searching for nearby devices · ${controller.remainingSeconds}s remaining',
      ),
      const LinearProgressIndicator(),
      const SizedBox(height: 8),
      if (controller.candidates.isEmpty)
        const Text('No nearby pairing candidates yet.')
      else
        ...controller.candidates.map(
          (candidate) => ListTile(
            key: Key('candidate-${candidate.instanceId}'),
            leading: const Icon(Icons.phone_android),
            title: Text(candidate.endpoint),
            subtitle: const Text('Nearby device'),
            onTap: controller.busy
                ? null
                : () => controller.selectCandidate(candidate),
          ),
        ),
      OutlinedButton(
        onPressed: controller.busy ? null : controller.stopPairing,
        child: const Text('Stop pairing'),
      ),
    ],
    PairingKindDto.connecting => const [
      LinearProgressIndicator(),
      SizedBox(height: 8),
      Text('Connecting securely…'),
    ],
    PairingKindDto.awaitingConfirmation => [
      const Text('Confirm that this code matches on both devices:'),
      const SizedBox(height: 8),
      SelectableText(
        controller.pairing.sas?.padLeft(6, '0') ?? '------',
        key: const Key('pairing-sas'),
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.displaySmall,
      ),
      const SizedBox(height: 12),
      FilledButton(
        onPressed: controller.busy ? null : controller.confirm,
        child: const Text('Codes match'),
      ),
      TextButton(
        onPressed: controller.busy ? null : controller.reject,
        child: const Text('Codes do not match'),
      ),
    ],
    PairingKindDto.committing => const [
      LinearProgressIndicator(),
      SizedBox(height: 8),
      Text('Saving trust and synchronizing the dataset…'),
    ],
    PairingKindDto.trusted => [
      const Icon(Icons.verified, color: Colors.green, size: 40),
      const Text('Device paired successfully.', textAlign: TextAlign.center),
      TextButton(
        onPressed: controller.beginPairing,
        child: const Text('Pair another device'),
      ),
    ],
    PairingKindDto.failed => [
      const Icon(Icons.error_outline, color: Colors.red, size: 40),
      Text(
        controller.pairing.message ?? 'Pairing did not complete.',
        textAlign: TextAlign.center,
      ),
      TextButton(
        onPressed: controller.beginPairing,
        child: const Text('Try again'),
      ),
    ],
  };
}

class _SyncChip extends StatelessWidget {
  const _SyncChip({required this.status});
  final SyncStatusDto status;
  @override
  Widget build(BuildContext context) => Chip(
    key: const Key('sync-status'),
    avatar: Icon(
      status == SyncStatusDto.error ? Icons.error_outline : Icons.sync,
      size: 18,
    ),
    label: Text(_statusText(status)),
  );
}

String _shortDeviceId(String id) => id.length <= 16
    ? id
    : '${id.substring(0, 8)}…${id.substring(id.length - 8)}';
String _connectionText(PeerConnectionKindDto state) => switch (state) {
  PeerConnectionKindDto.offline => 'Offline',
  PeerConnectionKindDto.searching => 'Searching',
  PeerConnectionKindDto.connected => 'Connected',
  PeerConnectionKindDto.syncing => 'Syncing',
  PeerConnectionKindDto.synced => 'Synced',
  PeerConnectionKindDto.error => 'Error',
};
String _timestamp(int? milliseconds) => milliseconds == null
    ? 'never'
    : DateTime.fromMillisecondsSinceEpoch(milliseconds).toLocal().toString();

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner(this.message);
  final String message;

  @override
  Widget build(BuildContext context) => MaterialBanner(
    content: Text(message),
    actions: const [SizedBox.shrink()],
  );
}
