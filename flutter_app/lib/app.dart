import 'dart:async';

import 'package:fi/bridge/collection_bridge.dart';
import 'package:fi/controllers.dart';
import 'package:fi/src/rust/api/models.dart';
import 'package:fi/collections_page.dart';
import 'package:fi/pairing_card.dart';
import 'package:fi/reset_dialog.dart';
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

  /// Owned here, above the bootstrap switch, so an in-flight pairing
  /// confirmation survives the needs-decision → joining → ready transition.
  late final DevicesController devices;
  bool _devicesStarted = false;
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
    devices = DevicesController(widget.bridge);
    unawaited(_start());
  }

  Future<void> _start() async {
    await _setPlatformForeground(true);
    await controller.start();
    await _setForeground(true);
    // Only after the core exists (bridge.initialize) and foreground is set, so
    // every call in DevicesController.start() succeeds and the aggregate
    // status reads Searching rather than Offline on a rootless device.
    if (controller.fatalError == null && !_devicesStarted) {
      _devicesStarted = true;
      await devices.start();
    }
  }

  /// Runs a confirmed dataset reset. The devices controller is restarted
  /// afterwards so its streams observe the reopened core rather than the one
  /// the bridge shut down.
  Future<void> _resetDataset() async {
    await controller.resetDataset();
    if (controller.fatalError != null) return;
    await _setForeground(true);
    _devicesStarted = true;
    await devices.restart();
  }

  Future<void> _confirmResetFromError(BuildContext context) async {
    final confirmed = await ResetDatasetDialog.show(
      context,
      lead:
          "This device's local data cannot be opened by this version of the "
          'app. Resetting it lets you create a new dataset or join one from '
          'another device.',
    );
    if (confirmed) await _resetDataset();
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
    devices.dispose();
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
                if (controller.fatalResetResolvable)
                  FilledButton(
                    key: const Key('reset-dataset'),
                    onPressed: () => unawaited(_confirmResetFromError(context)),
                    child: const Text("Reset this device's data"),
                  )
                else
                  FilledButton(
                    key: const Key('retry-bootstrap'),
                    onPressed: () => unawaited(_start()),
                    child: const Text('Retry'),
                  ),
              ],
            ),
          );
        }
        return switch (controller.state?.kind) {
          BootstrapKindDto.ready => CollectionShell(
            bridge: widget.bridge,
            devices: devices,
            onResetDataset: _resetDataset,
          ),
          BootstrapKindDto.needsDecision => OnboardingPage(
            controller: controller,
            devices: devices,
            onResetDataset: _resetDataset,
          ),
          BootstrapKindDto.joining => JoiningSurface(devices: devices),
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

/// Shown while a received root is being joined. Names the provisioning device
/// when the pairing session that started the join is still known.
class JoiningSurface extends StatelessWidget {
  const JoiningSurface({required this.devices, super.key});
  final DevicesController devices;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: devices,
    builder: (context, _) => _CenteredSurface(
      key: const Key('joining-surface'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(switch (devices.peerName) {
            final name? => 'Joining dataset from $name…',
            null => 'Waiting for this local dataset to become available.',
          }, textAlign: TextAlign.center),
        ],
      ),
    ),
  );
}

class OnboardingPage extends StatefulWidget {
  const OnboardingPage({
    required this.controller,
    required this.devices,
    this.onResetDataset,
    super.key,
  });
  final BootstrapController controller;
  final DevicesController devices;
  final ResetDatasetAction? onResetDataset;

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage> {
  bool showPairing = false;

  bool get _pairingActive => widget.devices.pairing.kind != PairingKindDto.idle;

  Future<void> _create() async {
    // Unconditional, not gated on the observed pairing state: the stream may
    // not have delivered an open window yet. A window advertises the root state
    // captured when it opened, so it must be closed before a root exists or a
    // peer may provision against a state that no longer holds. Stopping from
    // idle is a no-op in Rust.
    await widget.devices.stopPairing();
    await widget.controller.createNewDataset();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.devices,
    builder: (context, _) {
      final controller = widget.controller;
      final createBlocked = controller.creating || _pairingActive;
      return Scaffold(
        body: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
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
                    'Create a new local dataset, or join the dataset on one of '
                    'your other devices. Nothing is sent to a server.',
                  ),
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    key: const Key('create-dataset'),
                    onPressed: createBlocked ? null : _create,
                    icon: const Icon(Icons.add_circle_outline),
                    label: Text(
                      controller.creating ? 'Creating…' : 'Create new dataset',
                    ),
                  ),
                  if (_pairingActive) ...[
                    const SizedBox(height: 8),
                    const Text(
                      'Creating is unavailable while pairing is active. '
                      'Stop pairing to create a new dataset here.',
                      key: Key('create-blocked-reason'),
                      textAlign: TextAlign.center,
                    ),
                  ],
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    key: const Key('join-dataset'),
                    onPressed: controller.creating
                        ? null
                        : () => setState(() => showPairing = !showPairing),
                    icon: Icon(showPairing ? Icons.expand_less : Icons.link),
                    label: const Text('Join an existing dataset'),
                  ),
                  if (showPairing) ...[
                    const SizedBox(height: 16),
                    const Text(
                      'The other device must already have a dataset. Start '
                      'pairing on both devices, then tap Connect on one device '
                      'only.',
                      key: Key('pairing-preconditions'),
                    ),
                    const SizedBox(height: 12),
                    if (widget.devices.errorMessage case final error?)
                      _ErrorBanner(error),
                    PairingCard(
                      controller: widget.devices,
                      onResetDataset: widget.onResetDataset,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}

class CollectionShell extends StatefulWidget {
  const CollectionShell({
    required this.bridge,
    required this.devices,
    this.onResetDataset,
    super.key,
  });
  final CollectionBridge bridge;
  final DevicesController devices;
  final ResetDatasetAction? onResetDataset;

  @override
  State<CollectionShell> createState() => _CollectionShellState();
}

class _CollectionShellState extends State<CollectionShell> {
  late final CollectionsController controller;
  DevicesController get devices => widget.devices;
  int selected = 0;

  @override
  void initState() {
    super.initState();
    controller = CollectionsController(widget.bridge);
    unawaited(controller.start());
  }

  @override
  void dispose() {
    controller.dispose();
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
              DevicesPage(
                controller: devices,
                onResetDataset: widget.onResetDataset,
              ),
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
  const DevicesPage({required this.controller, this.onResetDataset, super.key});
  final DevicesController controller;
  final ResetDatasetAction? onResetDataset;

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
      if (controller.rotationError case final error?)
        MaterialBanner(
          key: const Key('rotation-error'),
          content: Text(
            'The device was revoked, but the discovery secret could not be '
            'rotated: $error',
          ),
          actions: [
            TextButton(
              key: const Key('retry-rotation'),
              onPressed: controller.busy ? null : controller.retryRotation,
              child: const Text('Retry rotation'),
            ),
          ],
        ),
      PairingCard(controller: controller, onResetDataset: onResetDataset),
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
      if (onResetDataset != null) ...[
        const SizedBox(height: 32),
        Text('This device', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        const Text(
          'Abandon the dataset on this device to create a new one or join '
          "another device's. Your device identity is kept.",
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            key: const Key('reset-dataset'),
            onPressed: controller.busy ? null : () => _resetDataset(context),
            icon: const Icon(Icons.restart_alt),
            label: const Text("Reset this device's data"),
          ),
        ),
      ],
    ],
  );

  Future<void> _resetDataset(BuildContext context) async {
    final action = onResetDataset;
    if (action == null) return;
    final trusted = controller.devices
        .where((device) => !device.revoked)
        .length;
    final confirmed = await ResetDatasetDialog.show(
      context,
      lead:
          'You are about to abandon the dataset on this device and return to '
          'onboarding.',
      trustedDeviceCount: trusted,
    );
    if (confirmed) await action();
  }

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
