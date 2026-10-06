import 'dart:convert';
import 'dart:io';

import 'package:conest/src/bitchat/noise.dart';
import 'package:conest/src/nostr/secp256k1.dart' show hexDecode, hexEncode;
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Noise XX matches the cacophony test vector', () async {
    final vector =
        jsonDecode(
              File('test/fixtures/noise_xx_vector.json').readAsStringSync(),
            )
            as Map<String, dynamic>;
    expect(vector['protocol_name'], bitchatNoiseProtocol);
    final initiator = await NoiseXXHandshake.start(
      initiator: true,
      staticSeed: hexDecode(vector['init_static'] as String)!,
      prologue: hexDecode(vector['init_prologue'] as String)!,
      ephemeralSeed: hexDecode(vector['init_ephemeral'] as String)!,
    );
    final responder = await NoiseXXHandshake.start(
      initiator: false,
      staticSeed: hexDecode(vector['resp_static'] as String)!,
      prologue: hexDecode(vector['resp_prologue'] as String)!,
      ephemeralSeed: hexDecode(vector['resp_ephemeral'] as String)!,
    );
    final messages = (vector['messages'] as List).cast<Map<String, dynamic>>();
    for (var index = 0; index < messages.length; index++) {
      final payload = hexDecode(messages[index]['payload'] as String)!;
      final expected = messages[index]['ciphertext'] as String;
      final fromInitiator = index.isEven;
      final sender = fromInitiator ? initiator : responder;
      final receiver = fromInitiator ? responder : initiator;
      if (index < 3) {
        final ciphertext = await sender.writeMessage(payload);
        expect(hexEncode(ciphertext), expected, reason: 'handshake $index');
        expect(await receiver.readMessage(ciphertext), payload);
      } else {
        final ciphertext = await sender.sendCipher!.encryptWithAd(
          const [],
          payload,
        );
        expect(hexEncode(ciphertext), expected, reason: 'transport $index');
        expect(
          await receiver.receiveCipher!.decryptWithAd(const [], ciphertext),
          payload,
        );
      }
    }
    expect(hexEncode(initiator.handshakeHash), vector['handshake_hash']);
    expect(initiator.remoteStaticKey, responder.localStaticKey);
    expect(responder.remoteStaticKey, initiator.localStaticKey);
  });

  test('a tampered handshake message is refused', () async {
    final initiator = await NoiseXXHandshake.start(
      initiator: true,
      staticSeed: List.filled(32, 1),
    );
    final responder = await NoiseXXHandshake.start(
      initiator: false,
      staticSeed: List.filled(32, 2),
    );
    await responder.readMessage(await initiator.writeMessage());
    final second = await responder.writeMessage();
    second[40] ^= 1;
    await expectLater(initiator.readMessage(second), throwsFormatException);
  });
}
