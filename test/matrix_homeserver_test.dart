// Compatibility check against a real homeserver. Runs only when
// CONEST_MATRIX_HOMESERVER points at a server with open registration (the
// debug workflow starts Synapse for it); skipped otherwise.
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:conest/src/matrix_carrier.dart';
import 'package:conest/src/matrix_client.dart';
import 'package:conest/src/transport.dart';
import 'package:conest/src/transport_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final homeserverUrl = Platform.environment['CONEST_MATRIX_HOMESERVER'];
  if (homeserverUrl == null || homeserverUrl.isEmpty) {
    test(
      'real homeserver',
      () {},
      skip: 'Set CONEST_MATRIX_HOMESERVER to run against a real server.',
    );
    return;
  }
  final homeserver = Uri.parse(homeserverUrl);
  final suffix = Random.secure().nextInt(1 << 30).toRadixString(36);

  Future<MatrixSession> registerAndLogin(String name) async {
    final client = HttpClient();
    try {
      final request = await client.postUrl(
        homeserver.replace(path: '/_matrix/client/v3/register'),
      );
      request.headers.contentType = ContentType.json;
      request.write(
        jsonEncode({
          'username': '$name$suffix',
          'password': 'pw-$name-$suffix',
          'auth': {'type': 'm.login.dummy'},
          'inhibit_login': true,
        }),
      );
      final response = await request.close();
      final body = await utf8.decoder.bind(response).join();
      expect(response.statusCode, 200, reason: body);
    } finally {
      client.close();
    }
    return MatrixClient.login(
      homeserver: homeserver,
      user: '$name$suffix',
      password: 'pw-$name-$suffix',
      deviceId: 'CONEST_$name',
    );
  }

  test('discovery, login and to-device acknowledgement', () async {
    expect(
      (await MatrixClient.resolveHomeserver(homeserverUrl)).port,
      homeserver.port,
    );
    final alice = MatrixClient(await registerAndLogin('alice'));
    final bob = MatrixClient(await registerAndLogin('bob'));
    addTearDown(alice.close);
    addTearDown(bob.close);
    expect(await alice.whoami(), alice.session.userId);
    // Establish a sync position first, as a running carrier would have.
    final start = await bob.sync(timeout: Duration.zero);
    await alice.sendToDevice(matrixCarrierEventType, {
      bob.session.userId: {
        bob.session.deviceId: {'v': 1, 'probe': true},
      },
    });
    final first = await bob.sync(
      since: start.nextBatch,
      timeout: const Duration(seconds: 10),
    );
    expect(
      first.toDevice.where((event) => event.type == matrixCarrierEventType),
      hasLength(1),
    );
    expect(first.toDevice.single.sender, alice.session.userId);
    final acked = await bob.sync(
      since: first.nextBatch,
      timeout: Duration.zero,
    );
    expect(acked.toDevice, isEmpty);
  });

  test('the carrier moves a 200 KiB envelope between two accounts', () async {
    final aliceSession = await registerAndLogin('carriera');
    final bobSession = await registerAndLogin('carrierb');
    final alice = MatrixTransportAdapter(sealer: _PlainSealer('dev-a'))
      ..attach(aliceSession);
    final bob = MatrixTransportAdapter(
      sealer: _PlainSealer('dev-a'),
      syncTimeout: const Duration(seconds: 5),
    )..attach(bobSession);
    await alice.start();
    await bob.start();
    addTearDown(alice.stop);
    addTearDown(bob.stop);
    final received = bob.inboundEnvelopes.first;
    final peer = TransportPeer(
      deviceId: 'dev-b',
      transportAddresses: {
        TransportKind.matrix: MatrixAddress(
          userId: bobSession.userId,
          deviceId: bobSession.deviceId,
        ).encode(),
      },
    );
    final payload = Uint8List.fromList(
      List<int>.generate(200 * 1024, (index) => (index * 7) % 256),
    );
    await alice.sendEnvelope(
      peer: peer,
      route: (await alice.discoverRoutes(peer)).single,
      envelope: TransportEnvelope(
        id: 'live',
        recipientDeviceId: 'dev-b',
        bytes: payload,
        createdAt: DateTime.now().toUtc(),
      ),
    );
    final inbound = await received.timeout(const Duration(seconds: 60));
    expect(inbound.bytes, payload);
  });
}

class _PlainSealer implements MatrixCarrierSealer {
  _PlainSealer(this.sender);
  final String sender;

  @override
  Future<Uint8List> seal(String peerDeviceId, Uint8List envelope) async =>
      envelope;

  @override
  Future<({String peerDeviceId, Uint8List envelope})?> open(
    String senderUserId,
    Uint8List sealed,
  ) async => (peerDeviceId: sender, envelope: sealed);
}
