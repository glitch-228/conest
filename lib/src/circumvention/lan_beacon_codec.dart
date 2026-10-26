import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// The LAN beacon without its telltale (M38-C). The beacon used to be
/// cleartext JSON on UDP 7668 (`{"app":"conest",...}`), recognisable to
/// anyone watching the network. Sealed, it is
///
///     nonce (12) | ChaCha20-Poly1305(u16 length | JSON | random padding)
///
/// with a random total size, so no byte string repeats from one beacon to
/// the next and its length varies.
///
/// The key comes from a fixed label, because the beacon must work between
/// devices that share nothing yet (pairing discovery, contacts coming back
/// on a LAN): it hides Conest from a network that only matches patterns,
/// not from someone who runs Conest on the same LAN. What a LAN neighbour
/// can still read is what the beacon always carried (device id, relay
/// port); it cannot be forged into anything new, since a beacon only ever
/// names the sender's own address.
class LanBeaconCodec {
  const LanBeaconCodec._();

  static final _aead = Chacha20.poly1305Aead();
  static final _random = Random.secure();
  static SecretKey? _key;

  /// Datagrams larger than this are not beacons.
  static const int maxDatagramBytes = 1024;
  static const int _nonceBytes = 12;
  static const int _tagBytes = 16;
  static const int _maxPad = 120;

  static Future<SecretKey> _secretKey() async => _key ??= SecretKey(
    (await Sha256().hash(utf8.encode('conest-lan-beacon-v1'))).bytes,
  );

  /// [message] sealed and padded.
  static Future<Uint8List> seal(Map<String, dynamic> message) async {
    final json = utf8.encode(jsonEncode(message));
    final pad = _random.nextInt(_maxPad + 1);
    final framed = Uint8List(2 + json.length + pad)
      ..[0] = json.length >> 8
      ..[1] = json.length & 0xff
      ..setRange(2, 2 + json.length, json);
    final nonce = Uint8List.fromList(
      List<int>.generate(_nonceBytes, (_) => _random.nextInt(256)),
    );
    final box = await _aead.encrypt(
      framed,
      secretKey: await _secretKey(),
      nonce: nonce,
    );
    return Uint8List.fromList([...nonce, ...box.cipherText, ...box.mac.bytes]);
  }

  /// The message in a sealed [datagram], or null when it is not one.
  static Future<Map<String, dynamic>?> open(List<int> datagram) async {
    if (datagram.length < _nonceBytes + _tagBytes + 2 ||
        datagram.length > maxDatagramBytes) {
      return null;
    }
    final cipherEnd = datagram.length - _tagBytes;
    try {
      final framed = await _aead.decrypt(
        SecretBox(
          datagram.sublist(_nonceBytes, cipherEnd),
          nonce: datagram.sublist(0, _nonceBytes),
          mac: Mac(datagram.sublist(cipherEnd)),
        ),
        secretKey: await _secretKey(),
      );
      if (framed.length < 2) return null;
      final length = (framed[0] << 8) | framed[1];
      if (2 + length > framed.length) return null;
      final decoded = jsonDecode(utf8.decode(framed.sublist(2, 2 + length)));
      return decoded is Map<String, dynamic> ? decoded : null;
    } on SecretBoxAuthenticationError {
      return null;
    } on FormatException {
      return null;
    }
  }
}
