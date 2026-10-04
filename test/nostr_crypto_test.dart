import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:conest/src/nostr/nip44.dart';
import 'package:conest/src/nostr/secp256k1.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _hex(String value) => hexDecode(value)!;

void main() {
  group('BIP-340', () {
    // The official vectors from bitcoin/bips (bip-0340/test-vectors.csv).
    final rows = File('test/fixtures/bip340_vectors.csv')
        .readAsLinesSync()
        .skip(1)
        .where((line) => line.trim().isNotEmpty)
        .map((line) => line.split(','))
        .toList();

    test('vectors are present', () => expect(rows.length, greaterThan(15)));

    for (final row in rows) {
      final [index, secret, public, aux, message, signature, result, ...] = row;
      test('vector $index', () {
        if (secret.isNotEmpty) {
          expect(
            hexEncode(Secp256k1.publicKey(_hex(secret))),
            public.toLowerCase(),
          );
          expect(
            hexEncode(
              Secp256k1.sign(_hex(message), _hex(secret), auxRand: _hex(aux)),
            ),
            signature.toLowerCase(),
          );
        }
        final valid = result == 'TRUE';
        // Vectors 15 and later use messages that are not 32 bytes; Nostr
        // only signs 32-byte event ids, so those still verify generically.
        expect(
          Secp256k1.verify(_hex(message), _hex(public), _hex(signature)),
          valid,
        );
      });
    }

    test('fresh keys sign and verify', () {
      final secret = Secp256k1.generateSecretKey();
      final message = Uint8List.fromList(sha256.convert([1, 2, 3]).bytes);
      final signature = Secp256k1.sign(message, secret);
      expect(
        Secp256k1.verify(message, Secp256k1.publicKey(secret), signature),
        isTrue,
      );
      message[0] ^= 1;
      expect(
        Secp256k1.verify(message, Secp256k1.publicKey(secret), signature),
        isFalse,
      );
    });
  });

  group('NIP-44', () {
    final vectors =
        (jsonDecode(File('test/fixtures/nip44_vectors.json').readAsStringSync())
                as Map<String, dynamic>)['v2']
            as Map<String, dynamic>;
    final valid = vectors['valid'] as Map<String, dynamic>;
    final invalid = vectors['invalid'] as Map<String, dynamic>;

    test('conversation keys', () {
      for (final vector in valid['get_conversation_key'] as List) {
        expect(
          hexEncode(
            Nip44.conversationKey(_hex(vector['sec1']), _hex(vector['pub2'])),
          ),
          vector['conversation_key'],
        );
      }
    });

    test('message keys', () {
      final entry = valid['get_message_keys'] as Map<String, dynamic>;
      final conversationKey = _hex(entry['conversation_key']);
      for (final vector in entry['keys'] as List) {
        final keys = Nip44.messageKeys(conversationKey, _hex(vector['nonce']));
        expect(hexEncode(keys.chachaKey), vector['chacha_key']);
        expect(hexEncode(keys.chachaNonce), vector['chacha_nonce']);
        expect(hexEncode(keys.hmacKey), vector['hmac_key']);
      }
    });

    test('padded lengths', () {
      for (final pair in valid['calc_padded_len'] as List) {
        expect(Nip44.paddedLength(pair[0] as int), pair[1]);
      }
    });

    test('encrypt and decrypt', () {
      for (final vector in valid['encrypt_decrypt'] as List) {
        final secret1 = _hex(vector['sec1']);
        final secret2 = _hex(vector['sec2']);
        final key = Nip44.conversationKey(
          secret1,
          Secp256k1.publicKey(secret2),
        );
        expect(hexEncode(key), vector['conversation_key']);
        expect(
          hexEncode(
            Nip44.conversationKey(secret2, Secp256k1.publicKey(secret1)),
          ),
          vector['conversation_key'],
        );
        final plaintext = utf8.encode(vector['plaintext'] as String);
        expect(
          Nip44.encrypt(plaintext, key, nonce: _hex(vector['nonce'])),
          vector['payload'],
        );
        expect(Nip44.decrypt(vector['payload'] as String, key), plaintext);
      }
    });

    test('long messages', () {
      for (final vector in valid['encrypt_decrypt_long_msg'] as List) {
        final plaintext = utf8.encode(
          (vector['pattern'] as String) * (vector['repeat'] as int),
        );
        expect(
          sha256.convert(plaintext).toString(),
          vector['plaintext_sha256'],
        );
        final payload = Nip44.encrypt(
          plaintext,
          _hex(vector['conversation_key']),
          nonce: _hex(vector['nonce']),
        );
        expect(
          sha256.convert(utf8.encode(payload)).toString(),
          vector['payload_sha256'],
        );
      }
    });

    test('invalid lengths are refused', () {
      for (final length in invalid['encrypt_msg_lengths'] as List) {
        expect(
          () => Nip44.encrypt(Uint8List(length as int), Uint8List(32)),
          throwsArgumentError,
        );
      }
    });

    test('invalid conversation keys are refused', () {
      for (final vector in invalid['get_conversation_key'] as List) {
        expect(
          () =>
              Nip44.conversationKey(_hex(vector['sec1']), _hex(vector['pub2'])),
          throwsArgumentError,
          reason: vector['note'] as String?,
        );
      }
    });

    test('invalid payloads are refused', () {
      for (final vector in invalid['decrypt'] as List) {
        expect(
          () => Nip44.decrypt(
            vector['payload'] as String,
            _hex(vector['conversation_key']),
          ),
          throwsFormatException,
          reason: vector['note'] as String?,
        );
      }
    });
  });
}
