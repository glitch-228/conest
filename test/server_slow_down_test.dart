import 'dart:async';
import 'dart:typed_data';

import 'package:conest/src/email/smtp.dart';
import 'package:conest/src/limits/network_limiter.dart';
import 'package:conest/src/matrix_client.dart';
import 'package:conest/src/transport.dart';
import 'package:conest/src/transport_models.dart';
import 'package:flutter_test/flutter_test.dart';

/// A server that says "slow down" (the chatmail relay's "450 4.7.1 Too much
/// mail", a homeserver's 429) says nothing about the route: the account has
/// to wait, the message is sent again later, and the route is not marked as
/// failing (device lab, build 308, email: every refusal put the route into
/// back-off and counted against the message's retries).
void main() {
  const peer = TransportPeer(deviceId: 'peer', transportIdentity: 'peer-id');

  TransportEnvelope envelope() => TransportEnvelope(
    id: 'message-1',
    recipientDeviceId: 'peer',
    bytes: Uint8List.fromList([1, 2, 3]),
    createdAt: DateTime.utc(2026, 11, 4),
  );

  Future<(TransportRegistry, List<Object?>)> registryThatThrows(
    Object error,
  ) async {
    final outcomes = <Object?>[];
    final registry = TransportRegistry([
      _SlowAdapter(TransportKind.deltaChat, error),
    ])..onOutcome = (kind, ok, error, deviceId) => outcomes.add(ok);
    return (registry, outcomes);
  }

  final refusals = <String, Object>{
    'an email server that refuses "Too much mail"': const SmtpException(
      450,
      '4.7.1: Too much mail from <a@example.org>, rate-limited until later',
    ),
    'a homeserver that answers 429': const MatrixException(
      'Too many requests',
      status: 429,
      errcode: 'M_LIMIT_EXCEEDED',
      retryAfter: Duration(seconds: 7),
    ),
  };

  for (final MapEntry(key: name, value: error) in refusals.entries) {
    test('$name is a wait, not a failing route', () async {
      final (registry, outcomes) = await registryThatThrows(error);
      await expectLater(
        registry.deliverEnvelope(
          peer: peer,
          envelope: envelope(),
          policies: const {TransportKind.deltaChat: TransportPolicy.automatic},
        ),
        throwsA(isA<LimiterRefused>()),
      );
      expect(
        outcomes,
        isNot(contains(false)),
        reason: 'the route was marked as failed for a server\'s slow-down',
      );
    });
  }

  test('a recipient\'s full mailbox or a word containing "rate" is not '
      'the account\'s pace', () {
    for (final refusal in const [
      SmtpException(452, '4.2.2 Quota exceeded (mailbox for user is full)'),
      SmtpException(450, '4.1.1 Recipient address temporarily unavailable'),
      SmtpException(451, '4.3.0 Message generated a separate error'),
    ]) {
      expect(refusal.slowDownFor, isNull, reason: refusal.message);
    }
    for (final refusal in const [
      SmtpException(450, '4.7.1: Too much mail from <a@example.org>'),
      SmtpException(421, '4.7.0 Rate limit exceeded, try again later'),
      SmtpException(452, '4.5.3 Sending quota exceeded for this hour'),
    ]) {
      expect(refusal.slowDownFor, Duration.zero, reason: refusal.message);
    }
  });

  test('a refusal that names its wait passes it on', () async {
    final (registry, _) = await registryThatThrows(
      refusals.values.elementAt(1),
    );
    await expectLater(
      registry.deliverEnvelope(
        peer: peer,
        envelope: envelope(),
        policies: const {TransportKind.deltaChat: TransportPolicy.automatic},
      ),
      throwsA(
        isA<LimiterRefused>().having(
          (error) => error.retryIn,
          'retryIn',
          const Duration(seconds: 7),
        ),
      ),
    );
  });

  test('a full mailbox or a bad address is still a failing route', () async {
    final (registry, outcomes) = await registryThatThrows(
      const SmtpException(452, '4.2.2 Mailbox full'),
    );
    await expectLater(
      registry.deliverEnvelope(
        peer: peer,
        envelope: envelope(),
        policies: const {TransportKind.deltaChat: TransportPolicy.automatic},
      ),
      throwsStateError,
    );
    expect(outcomes, contains(false));
  });

  test('a slow-down of one route does not hide a failure of another', () async {
    final outcomes = <Object?>[];
    final registry = TransportRegistry([
      _SlowAdapter(TransportKind.deltaChat, refusals.values.first),
      _SlowAdapter(TransportKind.matrix, StateError('unreachable')),
    ])..onOutcome = (kind, ok, error, deviceId) => outcomes.add(ok);
    await expectLater(
      registry.deliverEnvelope(
        peer: peer,
        envelope: envelope(),
        policies: const {
          TransportKind.deltaChat: TransportPolicy.automatic,
          TransportKind.matrix: TransportPolicy.automatic,
        },
      ),
      throwsStateError,
    );
    expect(outcomes, [false], reason: 'only the broken route failed');
  });
}

class _SlowAdapter implements TransportAdapter {
  _SlowAdapter(this.kind, this.error);

  @override
  final TransportKind kind;
  final Object error;

  late final RouteCandidate _route = RouteCandidate(
    transport: kind,
    path: TransportPathKind.storeForward,
    routeId: '${kind.name}:x',
    label: kind.label,
    trust: TransportTrustState.pinnedTransport,
  );

  @override
  TransportCapabilities get capabilities => const TransportCapabilities(
    requiresPeerOnline: false,
    supportsStoreForward: true,
    duplex: true,
    requiresUserAction: false,
    supportsAttachmentStreaming: false,
    reportsPath: true,
  );

  @override
  Stream<TransportInboundEnvelope> get inboundEnvelopes => const Stream.empty();
  @override
  Stream<RouteCandidate> get pathChanges => const Stream.empty();
  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> cancel(String operationId) async {}
  @override
  Future<List<RouteCandidate>> discoverRoutes(TransportPeer peer) async => [
    _route,
  ];

  @override
  Future<DeliveryReceipt> sendEnvelope({
    required TransportPeer peer,
    required RouteCandidate route,
    required TransportEnvelope envelope,
  }) async => throw error;

  @override
  Future<DeliveryReceipt> sendAttachmentRange({
    required TransportPeer peer,
    required RouteCandidate route,
    required AttachmentRange range,
  }) => throw UnimplementedError();
}
