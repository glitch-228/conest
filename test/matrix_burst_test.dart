import 'dart:async';
import 'dart:typed_data';

import 'package:conest/src/limits/network_budgets.dart';
import 'package:conest/src/limits/network_limiter.dart';
import 'package:conest/src/matrix_carrier.dart';
import 'package:conest/src/matrix_client.dart';
import 'package:conest/src/transport.dart';
import 'package:conest/src/transport_models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/strict_matrix_server.dart';

/// The release gate's burst over Matrix (build 308): 20 rounds, two seconds
/// apart, of a message to each of two contacts and a group message copy to
/// each of two members, and the receipts for what arrives. Everything of one
/// device leaves through one Matrix account, so one limiter.
///
/// On the gate the carrier answered in under half a second and no server
/// refused anything, yet the messages took 54 s (p50) to 117 s (p95) against
/// a deadline of 30 s: they waited for their turn behind the account's own
/// pace (one send a second), the receipts in the same queue.
void main() {
  late StepClock clock;
  late MatrixTransportAdapter adapter;
  late NetworkLimiter limiter;

  const peers = ['bob', 'carol'];

  TransportPeer peer(String user) => TransportPeer(
    deviceId: 'dev-$user',
    transportAddresses: {
      TransportKind.matrix: MatrixAddress(
        userId: '@$user:fake.test',
        deviceId: 'CONEST_$user',
      ).encode(),
    },
  );

  Future<MatrixTransportAdapter> startAdapter(StrictMatrixServer server) async {
    final created = MatrixTransportAdapter(sealer: _Sealer(), channel: server)
      ..attach(
        MatrixSession(
          homeserver: Uri.parse('https://hs.example'),
          userId: '@alice:fake.test',
          deviceId: 'CONEST_alice',
          accessToken: 'unused',
        ),
      );
    limiter = NetworkLimiter(
      NetworkBudgets.matrix,
      now: () => clock.now,
      timer: clock.timer,
    );
    created.limiter = limiter;
    return created;
  }

  /// One send, as the controller makes it. Returns when the server took it
  /// (null if it was refused, with the refusal in [refused]).
  Future<void> send(
    String user,
    String id,
    List<Duration> handoffs,
    List<Object> refused,
  ) async {
    final route = (await adapter.discoverRoutes(peer(user))).single;
    final started = clock.now;
    try {
      await adapter.sendEnvelope(
        peer: peer(user),
        route: route,
        envelope: TransportEnvelope(
          id: id,
          recipientDeviceId: 'dev-$user',
          bytes: Uint8List.fromList(List.filled(600, 7)),
          createdAt: started,
        ),
      );
      handoffs.add(clock.now.difference(started));
    } catch (error) {
      refused.add(error);
    }
  }

  /// The gate's load from one device: [rounds] rounds, two seconds apart.
  Future<void> burst(
    int rounds,
    List<Duration> handoffs,
    List<Object> refused,
  ) async {
    var serial = 0;
    for (var round = 0; round < rounds; round++) {
      for (final user in peers) {
        unawaited(send(user, 'dm-${serial++}', handoffs, refused));
        unawaited(send(user, 'group-${serial++}', handoffs, refused));
      }
      await clock.advance(const Duration(seconds: 1));
      // A receipt for what arrived, to each contact.
      for (final user in peers) {
        unawaited(send(user, 'ack-${serial++}', handoffs, refused));
      }
      await clock.advance(const Duration(seconds: 1));
    }
  }

  Duration percentile(List<Duration> values, double fraction) {
    final sorted = List.of(values)..sort();
    return sorted[((sorted.length - 1) * fraction).round()];
  }

  setUp(() => clock = StepClock());

  test('a burst of messages and receipts is on its way within seconds, '
      'not minutes (no server limit, as Synapse for to-device)', () async {
    final server = StrictMatrixServer(clock);
    adapter = await startAdapter(server);
    final handoffs = <Duration>[];
    final refused = <Object>[];
    await burst(20, handoffs, refused);
    await clock.advance(const Duration(minutes: 3));
    expect(refused, isEmpty);
    expect(server.stored, hasLength(20 * 6));
    expect(handoffs, hasLength(20 * 6));
    // The deadline is 30 s from writing to the receipt; the carrier's own
    // time is under a second, so the rest is for the queue at most.
    expect(percentile(handoffs, 0.5), lessThan(const Duration(seconds: 3)));
    expect(percentile(handoffs, 0.95), lessThan(const Duration(seconds: 10)));
    expect(percentile(handoffs, 1.0), lessThan(const Duration(seconds: 20)));
  });

  test('a server with a rate limit is kept under it: nothing is refused '
      'and nothing is lost', () async {
    // Ten a second with a burst of ten, far stricter than any homeserver
    // checked, still more than the gate's burst needs.
    final server = StrictMatrixServer(clock, perSecond: 10, burst: 10);
    adapter = await startAdapter(server);
    final handoffs = <Duration>[];
    final refused = <Object>[];
    await burst(20, handoffs, refused);
    await clock.advance(const Duration(minutes: 3));
    expect(server.refusals, 0);
    expect(refused, isEmpty);
    expect(server.stored, hasLength(20 * 6));
  });

  test('a server that does slow the account down is obeyed exactly, and '
      'every frame still arrives once', () async {
    final server = StrictMatrixServer(clock, perSecond: 2, burst: 4);
    adapter = await startAdapter(server);
    final handoffs = <Duration>[];
    final refused = <Object>[];
    await burst(20, handoffs, refused);
    // What a refused send does next is the controller's retry; the server
    // must never be asked faster than it said.
    await clock.advance(const Duration(minutes: 3));
    expect(server.refusals, greaterThan(0), reason: 'this server does limit');
    expect(
      server.earlyRetries,
      0,
      reason: 'no send came before the wait the server named was over',
    );
    for (final error in refused) {
      expect(
        error,
        anyOf(isA<LimiterRefused>(), isA<MatrixException>()),
        reason: 'a refusal, never a lost send',
      );
    }
    expect(
      server.stored.length + refused.length,
      20 * 6,
      reason: 'every send was either taken once or refused for a retry',
    );
  });
}

class _Sealer implements MatrixCarrierSealer {
  @override
  bool acceptsSender(String senderUserId) => true;

  @override
  Future<Uint8List> seal(String peerDeviceId, Uint8List envelope) async =>
      envelope;

  @override
  Future<({String peerDeviceId, Uint8List envelope})?> open(
    String senderUserId,
    Uint8List sealed,
  ) async => null;
}
