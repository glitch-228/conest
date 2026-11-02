import 'dart:typed_data';

import 'package:conest/src/crypto_service.dart';
import 'package:conest/src/models.dart';
import 'package:conest/src/transport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'sealed bytes are made again once what they depend on is stale',
    () async {
      var calls = 0;
      var stale = false;
      RelayEnvelope header() => RelayEnvelope(
        protocolVersion: 3,
        kind: 'direct_message',
        messageId: 'm',
        conversationId: 'c',
        senderAccountId: 'a',
        senderDeviceId: 's',
        recipientDeviceId: 'r',
        createdAt: DateTime.utc(2026, 11, 2),
      );
      final lazy = LazySeal(() async {
        calls++;
        return header();
      }, stale: () => stale);
      await lazy();
      await lazy();
      expect(calls, 1, reason: 'shared while fresh');
      stale = true;
      await lazy();
      expect(calls, 2, reason: 'the peer spoke: sealed again');
      stale = false;
      await lazy();
      expect(calls, 2);
      // The same for the bytes a transport asks for.
      var bytes = 0;
      var old = false;
      final envelope = TransportEnvelope(
        id: 'x',
        recipientDeviceId: 'r',
        bytes: Uint8List(10),
        createdAt: DateTime.utc(2026, 11, 2),
        seal: () async {
          bytes++;
          return Uint8List(5);
        },
        sealIsStale: () => old,
      );
      await envelope.sealedBytes();
      await envelope.sealedBytes();
      expect(bytes, 1);
      old = true;
      await envelope.sealedBytes();
      expect(bytes, 2, reason: 'the next route used out-of-date bytes');
    },
  );

  test('the placeholder is never smaller than what Olm makes', () {
    // Olm adds a version byte, ratchet key (32), counter, ciphertext padding
    // (up to 16), a MAC (8) and, for a pre-key message, the identity and
    // one-time keys (about 100): under 190 bytes in all.
    for (final n in [0, 1, 100, 5000]) {
      expect(
        CryptoService.ratchetCiphertextUpperBound(n),
        greaterThanOrEqualTo(n + 190),
      );
    }
  });
}
