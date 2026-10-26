import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Sealed UDP (M38-C): a v1 request over UDP without the telltale cleartext
/// JSON, for a relay whose session key is known and signed by its pinned
/// identity (`stats.v2.udp_sealed`). The wire format is described in
/// `native/conest_relay/src/udp_sealed.rs`:
///
///     ephemeral X25519 public key (32) | nonce (12) |
///         ChaCha20-Poly1305(u16 length | request | padding)
///
/// The answer is `nonce (12) | ChaCha20-Poly1305(u16 length | answer |
/// padding)`, under keys both sides derive from the Diffie-Hellman of the
/// ephemeral key and the relay's session key.
class UdpSeal {
  UdpSeal._(this._responseKey);

  final SecretKey _responseKey;

  static final _x25519 = X25519();
  static final _sha256 = Sha256();
  static final _aead = Chacha20.poly1305Aead();
  static final _random = Random.secure();

  static final List<int> _label = utf8.encode('conest-relay-udp-v2');
  static const int ephemeralBytes = 32;
  static const int nonceBytes = 12;
  static const int tagBytes = 16;

  /// The least a datagram weighs around its request (key, nonce, tag,
  /// length).
  static const int overhead = ephemeralBytes + nonceBytes + tagBytes + 2;

  static Future<Uint8List> _derive(
    List<int> direction,
    List<int> shared,
    List<int> ephemeral,
    List<int> relayPublic,
  ) async => Uint8List.fromList(
    (await _sha256.hash([
      ..._label,
      ...direction,
      ...shared,
      ...ephemeral,
      ...relayPublic,
    ])).bytes,
  );

  static Uint8List _frame(List<int> plaintext, int pad) {
    final out = Uint8List(2 + plaintext.length + pad);
    out[0] = plaintext.length >> 8;
    out[1] = plaintext.length & 0xff;
    out.setRange(2, 2 + plaintext.length, plaintext);
    return out;
  }

  static List<int>? _unframe(List<int> framed) {
    if (framed.length < 2) return null;
    final length = (framed[0] << 8) | framed[1];
    if (2 + length > framed.length) return null;
    return framed.sublist(2, 2 + length);
  }

  static Uint8List _randomBytes(int count) => Uint8List.fromList(
    List<int>.generate(count, (_) => _random.nextInt(256)),
  );

  /// Seals [request] to the relay with session key [relayPublic], with
  /// [padding] zero bytes of padding inside. [fixedEphemeralSeed] is for tests.
  static Future<(Uint8List datagram, UdpSeal reply)> seal({
    required List<int> relayPublic,
    required List<int> request,
    int padding = 0,
    List<int>? fixedEphemeralSeed,
  }) async {
    if (relayPublic.length != 32) {
      throw ArgumentError('The relay session key must be 32 bytes.');
    }
    // Not a key starting with `{` (that is the cleartext form).
    SimpleKeyPair pair;
    SimplePublicKey publicKey;
    do {
      pair = fixedEphemeralSeed == null
          ? await _x25519.newKeyPair()
          : await _x25519.newKeyPairFromSeed(fixedEphemeralSeed);
      publicKey = await pair.extractPublicKey();
    } while (fixedEphemeralSeed == null && publicKey.bytes[0] == 0x7b);
    final shared = await (await _x25519.sharedSecretKey(
      keyPair: pair,
      remotePublicKey: SimplePublicKey(relayPublic, type: KeyPairType.x25519),
    )).extractBytes();
    final requestKey = await _derive(
      utf8.encode('|request'),
      shared,
      publicKey.bytes,
      relayPublic,
    );
    final responseKey = await _derive(
      utf8.encode('|response'),
      shared,
      publicKey.bytes,
      relayPublic,
    );
    final nonce = _randomBytes(nonceBytes);
    final box = await _aead.encrypt(
      _frame(request, padding),
      secretKey: SecretKey(requestKey),
      nonce: nonce,
      aad: publicKey.bytes,
    );
    return (
      Uint8List.fromList([
        ...publicKey.bytes,
        ...nonce,
        ...box.cipherText,
        ...box.mac.bytes,
      ]),
      UdpSeal._(SecretKey(responseKey)),
    );
  }

  /// The answer in [datagram], or null when it is not one for this
  /// exchange (damaged, forged, from another request).
  Future<List<int>?> open(List<int> datagram) async {
    if (datagram.length < nonceBytes + tagBytes + 2) return null;
    final cipherEnd = datagram.length - tagBytes;
    try {
      final framed = await _aead.decrypt(
        SecretBox(
          datagram.sublist(nonceBytes, cipherEnd),
          nonce: datagram.sublist(0, nonceBytes),
          mac: Mac(datagram.sublist(cipherEnd)),
        ),
        secretKey: _responseKey,
      );
      return _unframe(framed);
    } on SecretBoxAuthenticationError {
      return null;
    }
  }

  /// Random padding for a request: enough that a cookie request is as
  /// long as the relay needs (128 bytes on the wire), then 0..63 more.
  static int paddingFor(int requestLength, {required bool cookieRequest}) {
    final minimum = cookieRequest
        ? (128 - overhead - requestLength).clamp(0, 1 << 16)
        : 0;
    return minimum + _random.nextInt(64);
  }
}
