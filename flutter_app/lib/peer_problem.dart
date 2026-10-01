import 'package:fi/l10n/l10n.dart';
import 'package:fi/src/rust/api/models.dart';
import 'package:fi/theme/nocturne.dart';
import 'package:flutter/material.dart';

/// Why a trusted device cannot be reached, in the terms the row shows (mock 8g).
enum PeerProblem { notFound, noAnswer, notVerified }

/// The problem a non-revoked row whose last attempt failed presents; null
/// for revoked rows, rows without a failure, and a paused failure.
PeerProblem? peerProblemOf(TrustedDeviceDto d) {
  if (d.revoked || d.connection != PeerConnectionKindDto.error) return null;
  return switch (d.failureKind) {
    ConnectionFailureKindDto.noRoute => PeerProblem.notFound,
    ConnectionFailureKindDto.trust ||
    ConnectionFailureKindDto.tls => PeerProblem.notVerified,
    ConnectionFailureKindDto.paused => null,
    _ => PeerProblem.noAnswer,
  };
}

/// Stable failure code shown under Details.
String failureCode(ConnectionFailureKindDto k) => switch (k) {
  ConnectionFailureKindDto.noRoute => 'NO_ELIGIBLE_ENDPOINT',
  ConnectionFailureKindDto.route => 'ROUTE_FAILED',
  ConnectionFailureKindDto.tls => 'TLS_FAILED',
  ConnectionFailureKindDto.trust => 'TRUST_FAILED',
  ConnectionFailureKindDto.stream => 'STREAM_FAILED',
  ConnectionFailureKindDto.transport => 'TRANSPORT_FAILED',
  ConnectionFailureKindDto.paused => 'SYNC_PAUSED',
};

String peerProblemTag(AppLocalizations l, PeerProblem p) => switch (p) {
  PeerProblem.notFound || PeerProblem.noAnswer => l.peerNotReachable,
  PeerProblem.notVerified => l.peerCantVerify,
};

String peerProblemLine(AppLocalizations l, PeerProblem p) => switch (p) {
  PeerProblem.notFound => l.peerNotFound,
  PeerProblem.noAnswer => l.peerNoAnswer,
  PeerProblem.notVerified => l.peerNotRecognized,
};

String peerProblemGuidance(AppLocalizations l, PeerProblem p) => switch (p) {
  PeerProblem.notFound || PeerProblem.noAnswer => l.peerGuidanceReach,
  PeerProblem.notVerified => l.peerGuidanceVerify,
};

/// The guidance and actions under an unreachable device's row. A null
/// [onTryAgain] shows Try again disabled; a null [onConnectByAddress] hides
/// Connect by address.
class PeerGuidanceBox extends StatelessWidget {
  const PeerGuidanceBox({
    required this.deviceId,
    required this.problem,
    required this.onTryAgain,
    required this.onPairAgain,
    this.onConnectByAddress,
    super.key,
  });

  final String deviceId;
  final PeerProblem problem;
  final VoidCallback? onTryAgain;
  final VoidCallback onPairAgain;
  final VoidCallback? onConnectByAddress;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: Nocturne.muted(.2)),
        borderRadius: BorderRadius.circular(Nocturne.radius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 10,
        children: [
          Text(
            peerProblemGuidance(l, problem),
            style: const TextStyle(fontSize: 13),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton(
                key: Key('device-try-again-$deviceId'),
                onPressed: onTryAgain,
                child: Text(l.peerTryAgain),
              ),
              OutlinedButton(
                key: Key('device-pair-again-$deviceId'),
                onPressed: onPairAgain,
                child: Text(l.peerPairAgain),
              ),
              if (onConnectByAddress case final onPressed?)
                OutlinedButton(
                  key: Key('device-connect-address-$deviceId'),
                  onPressed: onPressed,
                  child: Text(l.peerConnectByAddress),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
