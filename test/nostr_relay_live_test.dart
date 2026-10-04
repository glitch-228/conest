// Runs against a real relay when CONEST_NOSTR_RELAY is set (the debug
// workflow starts one), so event ids, signatures, NIP-44 content and frame
// sizes are checked by a relay implementation other than Conest's own.
import 'dart:io';
import 'dart:typed_data';

import 'package:conest/src/carrier.dart';
import 'package:conest/src/nostr/secp256k1.dart';
import 'package:conest/src/nostr_carrier.dart';
import 'package:conest/src/transport.dart';
import 'package:conest/src/transport_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final relayUrl = Platform.environment['CONEST_NOSTR_RELAY'];
  final skip = relayUrl == null ? 'CONEST_NOSTR_RELAY is not set' : null;

  test(
    'a multi-frame envelope crosses a real relay',
    () async {
      final relay = Uri.parse(relayUrl!);
      final aliceKey = Secp256k1.generateSecretKey();
      final bobKey = Secp256k1.generateSecretKey();
      final alicePub = hexEncode(Secp256k1.publicKey(aliceKey));
      final sealer = _PlainSealer({alicePub: 'dev-alice'});
      final aliceAdapter = createNostrCarrierAdapter(
        sealer: sealer,
        allowLoopbackRelays: true,
      );
      final bobAdapter = createNostrCarrierAdapter(
        sealer: sealer,
        allowLoopbackRelays: true,
      );
      final alice = NostrCarrierChannel(
        secretKey: aliceKey,
        relays: [relay],
        onFrame: aliceAdapter.receiveFrame,
        allowLoopbackRelays: true,
      );
      final bob = NostrCarrierChannel(
        secretKey: bobKey,
        relays: [relay],
        onFrame: bobAdapter.receiveFrame,
        allowLoopbackRelays: true,
      );
      aliceAdapter.attach(alice);
      bobAdapter.attach(bob);
      await aliceAdapter.start();
      await bobAdapter.start();
      addTearDown(aliceAdapter.stop);
      addTearDown(bobAdapter.stop);

      final envelope = Uint8List.fromList(
        List<int>.generate(70 * 1024, (index) => index * 7 % 256),
      );
      final inbound = bobAdapter.inboundEnvelopes.first;
      final peer = TransportPeer(
        deviceId: 'dev-bob',
        transportAddresses: {TransportKind.nostr: bob.localAddress!},
      );
      final route = (await aliceAdapter.discoverRoutes(peer)).single;
      await aliceAdapter.sendEnvelope(
        peer: peer,
        route: route,
        envelope: TransportEnvelope(
          id: 'live',
          recipientDeviceId: 'dev-bob',
          bytes: envelope,
          createdAt: DateTime.now().toUtc(),
        ),
      );
      final received = await inbound.timeout(const Duration(seconds: 30));
      expect(received.senderTransportIdentity, 'dev-alice');
      expect(received.bytes, envelope);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

/// Passes envelopes through unchanged and names senders from a table.
class _PlainSealer implements CarrierSealer {
  _PlainSealer(this._devices);

  final Map<String, String> _devices;

  @override
  bool acceptsSender(TransportKind kind, String sender) =>
      _devices.containsKey(sender);

  @override
  Future<Uint8List> seal(
    TransportKind kind,
    String peerDeviceId,
    Uint8List envelope,
  ) async => envelope;

  @override
  Future<({String peerDeviceId, Uint8List envelope})?> open(
    TransportKind kind,
    String sender,
    Uint8List sealed,
  ) async => (peerDeviceId: _devices[sender]!, envelope: sealed);
}
