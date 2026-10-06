import 'package:fi/controllers.dart';
import 'package:fi/l10n/error_text.dart';
import 'package:fi/l10n/l10n.dart';
import 'package:fi/src/rust/api/models.dart';
import 'package:flutter/material.dart';

/// Opens Connect by address for [device] (mock devices-connect-address): a dialog at 720px and wider, a bottom sheet
/// below.
Future<void> showConnectByAddress(
  BuildContext context,
  DevicesController controller,
  TrustedDeviceDto device,
) {
  final form = ConnectByAddressForm(controller: controller, device: device);
  if (MediaQuery.sizeOf(context).width >= 720) {
    return showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: form,
        ),
      ),
    );
  }
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (sheetContext) => Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
      ),
      child: form,
    ),
  );
}

/// The message for a connect-by-address outcome; empty for `connected`.
String connectOutcomeText(
  AppLocalizations l,
  ManualConnectOutcomeDto o, {
  required String address,
  required String name,
}) => switch (o.kind) {
  ManualConnectKindDto.connected => '',
  ManualConnectKindDto.invalidAddress => l.connectAddressInvalid,
  ManualConnectKindDto.notLocalNetwork => l.connectAddressNotLocal,
  ManualConnectKindDto.failed => switch (o.failureKind) {
    ConnectionFailureKindDto.trust ||
    ConnectionFailureKindDto.tls => l.connectAddressWrongDevice(address, name),
    ConnectionFailureKindDto.paused => l.connectAddressPaused,
    _ => l.connectAddressNoAnswer(address),
  },
};

class ConnectByAddressForm extends StatefulWidget {
  const ConnectByAddressForm({
    required this.controller,
    required this.device,
    super.key,
  });

  final DevicesController controller;
  final TrustedDeviceDto device;

  @override
  State<ConnectByAddressForm> createState() => _ConnectByAddressFormState();
}

class _ConnectByAddressFormState extends State<ConnectByAddressForm> {
  late final TextEditingController _text = TextEditingController(
    text:
        widget.device.lastKnownEndpoint ?? widget.device.attemptEndpoint ?? '',
  );
  var _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _text.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final l = context.l10n;
    final name = widget.device.friendlyName;
    final address = _text.text.trim();
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    String? error;
    try {
      final outcome = await widget.controller.connectByAddress(
        widget.device,
        _text.text,
      );
      if (outcome.kind == ManualConnectKindDto.connected) {
        if (!mounted) return;
        navigator.pop();
        messenger?.showSnackBar(
          SnackBar(content: Text(l.connectAddressConnected(name))),
        );
        return;
      }
      error = connectOutcomeText(l, outcome, address: address, name: name);
    } on BridgeError catch (thrown) {
      error = thrown.kind == BridgeErrorKind.paused
          ? l.connectAddressPaused
          : bridgeMessage(l, thrown);
    } catch (thrown) {
      error = bridgeMessage(l, thrown);
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 12,
        children: [
          Text(l.connectAddressTitle, style: theme.textTheme.titleLarge),
          Text(l.connectAddressLead(widget.device.friendlyName)),
          TextField(
            key: const Key('connect-address-field'),
            controller: _text,
            enabled: !_busy,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: l.connectAddressField,
              hintText: '192.168.0.165:47380',
              helperText: l.connectAddressHelp,
              helperMaxLines: 3,
              error: _error == null
                  ? null
                  : Text(
                      _error!,
                      key: const Key('connect-address-error'),
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
            ),
            onSubmitted: (_) {
              if (!_busy && _text.text.trim().isNotEmpty) _connect();
            },
          ),
          OverflowBar(
            alignment: MainAxisAlignment.end,
            spacing: 8,
            overflowSpacing: 8,
            children: [
              TextButton(
                key: const Key('connect-address-cancel'),
                onPressed: () => Navigator.pop(context),
                child: Text(l.commonCancel),
              ),
              FilledButton(
                key: const Key('connect-address-connect'),
                onPressed: _busy || _text.text.trim().isEmpty ? null : _connect,
                child: _busy
                    ? Text(
                        l.connectAddressConnecting,
                        key: const Key('connect-address-busy'),
                      )
                    : Text(l.connectAddressConnect),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
