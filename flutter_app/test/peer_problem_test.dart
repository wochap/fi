import 'package:fi/peer_problem.dart';
import 'package:fi/src/rust/api/models.dart';
import 'package:flutter_test/flutter_test.dart';

TrustedDeviceDto _device({
  PeerConnectionKindDto connection = PeerConnectionKindDto.error,
  ConnectionFailureKindDto? kind,
  bool revoked = false,
}) => TrustedDeviceDto(
  deviceId: 'peer',
  friendlyName: 'Peer',
  pairedAtMs: 1,
  revoked: revoked,
  connection: connection,
  failure: 'failure',
  failureKind: kind,
);

void main() {
  test('every failure kind maps to a problem', () {
    final expected = {
      ConnectionFailureKindDto.noRoute: PeerProblem.notFound,
      ConnectionFailureKindDto.route: PeerProblem.noAnswer,
      ConnectionFailureKindDto.transport: PeerProblem.noAnswer,
      ConnectionFailureKindDto.stream: PeerProblem.noAnswer,
      ConnectionFailureKindDto.trust: PeerProblem.notVerified,
      ConnectionFailureKindDto.tls: PeerProblem.notVerified,
      ConnectionFailureKindDto.paused: null,
    };
    for (final MapEntry(:key, :value) in expected.entries) {
      expect(peerProblemOf(_device(kind: key)), value, reason: '$key');
    }
  });

  test('a failure without a kind did not answer', () {
    expect(peerProblemOf(_device()), PeerProblem.noAnswer);
  });

  test('revoked and non-error rows have no problem', () {
    expect(
      peerProblemOf(
        _device(revoked: true, kind: ConnectionFailureKindDto.noRoute),
      ),
      isNull,
    );
    for (final connection in PeerConnectionKindDto.values) {
      if (connection == PeerConnectionKindDto.error) continue;
      expect(
        peerProblemOf(
          _device(
            connection: connection,
            kind: ConnectionFailureKindDto.noRoute,
          ),
        ),
        isNull,
        reason: '$connection',
      );
    }
  });

  test('failure codes are stable', () {
    expect(
      {for (final kind in ConnectionFailureKindDto.values) failureCode(kind)},
      {
        'NO_ELIGIBLE_ENDPOINT',
        'ROUTE_FAILED',
        'TLS_FAILED',
        'TRUST_FAILED',
        'STREAM_FAILED',
        'TRANSPORT_FAILED',
        'SYNC_PAUSED',
      },
    );
    expect(
      failureCode(ConnectionFailureKindDto.noRoute),
      'NO_ELIGIBLE_ENDPOINT',
    );
    expect(failureCode(ConnectionFailureKindDto.tls), 'TLS_FAILED');
  });
}
