import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:conest/src/matrix_carrier.dart';
import 'package:conest/src/matrix_client.dart';
import 'package:conest/src/transport.dart';
import 'package:conest/src/transport_models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_homeserver.dart';

void main() {
  late FakeHomeserver server;

  setUp(() async {
    server = await FakeHomeserver.start();
    server.register('alice', 'alice-pass');
    server.register('bob', 'bob-pass');
  });
  tearDown(() => server.close());

  Future<MatrixSession> login(String user, String password) =>
      MatrixClient.login(
        homeserver: server.url,
        user: user,
        password: password,
        deviceId: 'CONEST_$user',
      );

  group('MatrixClient', () {
    test('resolves, logs in and identifies the device', () async {
      final homeserver = await MatrixClient.resolveHomeserver(
        server.url.toString(),
      );
      expect(homeserver.port, server.url.port);
      final session = await login('alice', 'alice-pass');
      expect(session.userId, '@alice:fake.test');
      expect(session.deviceId, 'CONEST_alice');
      final client = MatrixClient(session);
      addTearDown(client.close);
      expect(await client.whoami(), '@alice:fake.test');
      expect(
        MatrixSession.tryFromJson(
          jsonDecode(jsonEncode(session.toJson())),
        )?.accessToken,
        session.accessToken,
      );
    });

    test('credentials only go to HTTPS or this machine', () {
      expect(
        () => requireSecureHomeserver(Uri.parse('http://matrix.example')),
        throwsA(isA<MatrixException>()),
      );
      requireSecureHomeserver(Uri.parse('https://matrix.example'));
      requireSecureHomeserver(Uri.parse('http://127.0.0.1:8008'));
      requireSecureHomeserver(Uri.parse('http://localhost:8008'));
    });

    test('a wrong password is a typed error', () async {
      await expectLater(
        login('alice', 'nope'),
        throwsA(
          isA<MatrixException>().having(
            (error) => error.errcode,
            'errcode',
            'M_FORBIDDEN',
          ),
        ),
      );
    });

    test(
      'to-device messages stay until the next sync acknowledges them',
      () async {
        final alice = MatrixClient(await login('alice', 'alice-pass'));
        final bob = MatrixClient(await login('bob', 'bob-pass'));
        addTearDown(alice.close);
        addTearDown(bob.close);
        await alice.sendToDevice('dev.test', {
          '@bob:fake.test': {
            'CONEST_bob': {'n': 1},
          },
        });
        final first = await bob.sync(timeout: Duration.zero);
        expect(first.toDevice.single.content, {'n': 1});
        expect(first.toDevice.single.sender, '@alice:fake.test');
        // Without the token the batch is delivered again...
        final again = await bob.sync(timeout: Duration.zero);
        expect(again.toDevice, hasLength(1));
        // ...and with it, it is gone.
        final acked = await bob.sync(
          since: again.nextBatch,
          timeout: Duration.zero,
        );
        expect(acked.toDevice, isEmpty);
      },
    );

    test('rate limits carry the retry delay', () async {
      final alice = MatrixClient(await login('alice', 'alice-pass'));
      addTearDown(alice.close);
      server.rateLimitSends = 1;
      await expectLater(
        alice.sendToDevice('dev.test', {
          '@bob:fake.test': {
            'X': {'n': 1},
          },
        }),
        throwsA(
          isA<MatrixException>()
              .having((error) => error.isRateLimited, 'rate limited', isTrue)
              .having(
                (error) => error.retryAfter,
                'retryAfter',
                const Duration(seconds: 1),
              ),
        ),
      );
    });
  });

  group('carrier frames', () {
    test('split and reassemble in any order', () {
      final sealed = Uint8List.fromList(
        List<int>.generate(100 * 1024, (index) => index % 251),
      );
      final frames = matrixCarrierFrames('env-1', sealed);
      expect(frames, hasLength(3));
      final reassembler = MatrixCarrierReassembler();
      Uint8List? result;
      for (final frame in frames.reversed) {
        result = reassembler.add(
          '@alice:fake.test',
          jsonDecode(jsonEncode(frame)) as Map<String, dynamic>,
        );
      }
      expect(result, sealed);
    });

    test('reject malformed and oversized frames', () {
      final reassembler = MatrixCarrierReassembler();
      for (final content in <Map<String, dynamic>>[
        {'v': 2, 'id': 'x', 'i': 0, 'n': 1, 'd': 'AA=='},
        {'v': 1, 'id': 'x', 'i': 1, 'n': 1, 'd': 'AA=='},
        {'v': 1, 'id': 'x', 'i': 0, 'n': 100, 'd': 'AA=='},
        {'v': 1, 'id': 'x', 'i': 0, 'n': 1, 'd': '!!'},
        {'v': 1, 'id': '', 'i': 0, 'n': 1, 'd': 'AA=='},
      ]) {
        expect(reassembler.add('@a:b', content), isNull);
      }
      expect(
        () => matrixCarrierFrames(
          'big',
          Uint8List(matrixCarrierMaxSealedBytes + 1),
        ),
        throwsArgumentError,
      );
    });

    test('frames fit the 64 KiB event limit', () {
      final frames = matrixCarrierFrames(
        MatrixClient.newTransactionId(),
        Uint8List(matrixCarrierMaxSealedBytes),
      );
      for (final frame in frames) {
        expect(utf8.encode(jsonEncode(frame)).length, lessThan(60 * 1024));
      }
    });

    test('MatrixAddress round-trips and validates', () {
      final address = MatrixAddress(
        userId: '@bob:fake.test',
        deviceId: 'CONEST_bob',
      );
      expect(MatrixAddress.decode(address.encode()), address);
      expect(MatrixAddress.fromJson(address.toJson()), address);
      expect(MatrixAddress.tryCreate('bob', 'X'), isNull);
      expect(MatrixAddress.tryCreate('@bob:fake.test', 'a|b'), isNull);
      expect(MatrixAddress.decode('nonsense'), isNull);
    });
  });

  group('MatrixTransportAdapter', () {
    Future<MatrixTransportAdapter> adapter(
      String user,
      String password, {
      _PrefixSealer? sealer,
      void Function()? onRevoked,
    }) async {
      final transport = MatrixTransportAdapter(
        sealer: sealer ?? _PrefixSealer(user),
        syncTimeout: const Duration(milliseconds: 200),
        onSessionRevoked: onRevoked,
      )..attach(await login(user, password));
      await transport.start();
      addTearDown(transport.stop);
      return transport;
    }

    TransportPeer peer(String deviceId, String user) => TransportPeer(
      deviceId: deviceId,
      transportAddresses: {
        TransportKind.matrix: MatrixAddress(
          userId: '@$user:fake.test',
          deviceId: 'CONEST_$user',
        ).encode(),
      },
    );

    test('delivers a large sealed envelope to the peer device', () async {
      final alice = await adapter('alice', 'alice-pass');
      final bob = await adapter('bob', 'bob-pass');
      final received = bob.inboundEnvelopes.first;
      final routes = await alice.discoverRoutes(peer('dev-bob', 'bob'));
      expect(routes.single.path, TransportPathKind.storeForward);
      final payload = Uint8List.fromList(
        List<int>.generate(120 * 1024, (index) => index % 13),
      );
      final receipt = await alice.sendEnvelope(
        peer: peer('dev-bob', 'bob'),
        route: routes.single,
        envelope: TransportEnvelope(
          id: 'm1',
          recipientDeviceId: 'dev-bob',
          bytes: payload,
          createdAt: DateTime.now().toUtc(),
        ),
      );
      expect(receipt.state, DeliveryReceiptState.storedForPeer);
      final inbound = await received.timeout(const Duration(seconds: 5));
      expect(inbound.transport, TransportKind.matrix);
      expect(inbound.senderTransportIdentity, 'dev-alice');
      expect(inbound.bytes, payload);
      // The homeserver only ever saw sealed bytes.
      for (final frame in server.sent.where((f) => f.content['i'] == 0)) {
        expect(
          utf8.decode(
            base64Decode(frame.content['d'] as String),
            allowMalformed: true,
          ),
          startsWith('sealed:'),
        );
      }
    });

    test('a peer without a Matrix address gets no route', () async {
      final alice = await adapter('alice', 'alice-pass');
      expect(
        await alice.discoverRoutes(const TransportPeer(deviceId: 'dev-x')),
        isEmpty,
      );
    });

    test('a rate-limited frame is retried once', () async {
      final alice = await adapter('alice', 'alice-pass');
      final bob = await adapter('bob', 'bob-pass');
      final received = bob.inboundEnvelopes.first;
      server
        ..rateLimitSends = 1
        ..retryAfter = const Duration(seconds: 1);
      final route = (await alice.discoverRoutes(peer('dev-bob', 'bob'))).single;
      await alice.sendEnvelope(
        peer: peer('dev-bob', 'bob'),
        route: route,
        envelope: TransportEnvelope(
          id: 'm2',
          recipientDeviceId: 'dev-bob',
          bytes: Uint8List.fromList([1, 2, 3]),
          createdAt: DateTime.now().toUtc(),
        ),
      );
      expect((await received.timeout(const Duration(seconds: 5))).bytes, [
        1,
        2,
        3,
      ]);
    });

    test('an unopenable frame does not block later ones', () async {
      final bobSealer = _PrefixSealer('bob')..failNextOpen = true;
      final alice = await adapter('alice', 'alice-pass');
      final bob = await adapter('bob', 'bob-pass', sealer: bobSealer);
      final received = bob.inboundEnvelopes.first;
      final route = (await alice.discoverRoutes(peer('dev-bob', 'bob'))).single;
      for (final bytes in [
        [9],
        [7],
      ]) {
        await alice.sendEnvelope(
          peer: peer('dev-bob', 'bob'),
          route: route,
          envelope: TransportEnvelope(
            id: 'm$bytes',
            recipientDeviceId: 'dev-bob',
            bytes: Uint8List.fromList(bytes),
            createdAt: DateTime.now().toUtc(),
          ),
        );
      }
      expect((await received.timeout(const Duration(seconds: 5))).bytes, [7]);
    });

    test('a revoked session stops syncing and reports it', () async {
      final revoked = Completer<void>();
      final bob = await adapter('bob', 'bob-pass', onRevoked: revoked.complete);
      server.revoke('@bob:fake.test');
      await revoked.future.timeout(const Duration(seconds: 5));
      expect(bob.status.signedIn, isFalse);
    });
  });
}

/// Test sealer: prefixes and strips a marker, and names the sender device
/// after the Matrix localpart.
class _PrefixSealer implements MatrixCarrierSealer {
  _PrefixSealer(this.owner);

  final String owner;
  bool failNextOpen = false;

  @override
  bool acceptsSender(String senderUserId) => true;

  @override
  Future<Uint8List> seal(String peerDeviceId, Uint8List envelope) async =>
      Uint8List.fromList([...utf8.encode('sealed:'), ...envelope]);

  @override
  Future<({String peerDeviceId, Uint8List envelope})?> open(
    String senderUserId,
    Uint8List sealed,
  ) async {
    if (failNextOpen) {
      failNextOpen = false;
      throw StateError('cannot open');
    }
    final marker = utf8.encode('sealed:');
    final localpart = senderUserId.substring(1, senderUserId.indexOf(':'));
    return (
      peerDeviceId: 'dev-$localpart',
      envelope: Uint8List.sublistView(sealed, marker.length),
    );
  }
}
