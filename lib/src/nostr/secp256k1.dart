import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// secp256k1 arithmetic and BIP-340 Schnorr signatures, as Nostr uses them.
///
/// Plain [BigInt] arithmetic: correct (checked against the BIP-340 vectors)
/// but not constant-time. Conest signs Nostr events with throwaway keys, and
/// the long-term carrier key only guards an outer layer around envelopes that
/// are sealed again per contact.
abstract final class Secp256k1 {
  static final BigInt p = BigInt.parse(
    'fffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffc2f',
    radix: 16,
  );
  static final BigInt n = BigInt.parse(
    'fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141',
    radix: 16,
  );
  static final _Point _g = _Point(
    BigInt.parse(
      '79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798',
      radix: 16,
    ),
    BigInt.parse(
      '483ada7726a3c4655da4fbfc0e1108a8fd17b448a68554199c47d08ffb10d4b8',
      radix: 16,
    ),
    BigInt.one,
  );
  static final BigInt _sqrtExponent = (p + BigInt.one) >> 2;

  /// A fresh random secret key.
  static Uint8List generateSecretKey([Random? random]) {
    final source = random ?? Random.secure();
    while (true) {
      final candidate = Uint8List.fromList(
        List<int>.generate(32, (_) => source.nextInt(256)),
      );
      final value = _toInt(candidate);
      if (value > BigInt.zero && value < n) return candidate;
    }
  }

  /// The 32-byte x-only public key of [secretKey].
  static Uint8List publicKey(Uint8List secretKey) {
    final d = _secretScalar(secretKey);
    return _toBytes(_mul(_g, d).affine().x);
  }

  /// The x coordinate of [secretKey] times the point with x-only key
  /// [publicKey] (even y): the shared secret NIP-44 starts from.
  static Uint8List sharedX(Uint8List secretKey, Uint8List publicKey) {
    final d = _secretScalar(secretKey);
    final point = _liftX(_toInt(publicKey));
    if (point == null) throw ArgumentError('Not a valid public key.');
    return _toBytes(_mul(point, d).affine().x);
  }

  /// Whether [publicKey] is a valid x-only key.
  static bool isValidPublicKey(Uint8List publicKey) =>
      publicKey.length == 32 && _liftX(_toInt(publicKey)) != null;

  /// A BIP-340 signature of the 32-byte [message].
  static Uint8List sign(
    Uint8List message,
    Uint8List secretKey, {
    Uint8List? auxRand,
  }) {
    final d0 = _secretScalar(secretKey);
    final point = _mul(_g, d0).affine();
    final d = point.y.isEven ? d0 : n - d0;
    final aux = auxRand ?? generateSecretKey();
    final masked = _toBytes(d ^ _toInt(_taggedHash('BIP0340/aux', aux)));
    final pBytes = _toBytes(point.x);
    final k0 =
        _toInt(
          _taggedHash('BIP0340/nonce', [...masked, ...pBytes, ...message]),
        ) %
        n;
    if (k0 == BigInt.zero) throw StateError('Signing nonce was zero.');
    final r = _mul(_g, k0).affine();
    final k = r.y.isEven ? k0 : n - k0;
    final rBytes = _toBytes(r.x);
    final e =
        _toInt(
          _taggedHash('BIP0340/challenge', [...rBytes, ...pBytes, ...message]),
        ) %
        n;
    return Uint8List.fromList([...rBytes, ..._toBytes((k + e * d) % n)]);
  }

  /// Whether [signature] is a valid BIP-340 signature of [message] by the
  /// x-only key [publicKey].
  static bool verify(
    Uint8List message,
    Uint8List publicKey,
    Uint8List signature,
  ) {
    if (publicKey.length != 32 || signature.length != 64) return false;
    final point = _liftX(_toInt(publicKey));
    if (point == null) return false;
    final r = _toInt(Uint8List.sublistView(signature, 0, 32));
    final s = _toInt(Uint8List.sublistView(signature, 32));
    if (r >= p || s >= n) return false;
    final e =
        _toInt(
          _taggedHash('BIP0340/challenge', [
            ...Uint8List.sublistView(signature, 0, 32),
            ...publicKey,
            ...message,
          ]),
        ) %
        n;
    final result = _add(_mul(_g, s), _mul(point, n - e));
    if (result.isInfinity) return false;
    final affine = result.affine();
    return affine.y.isEven && affine.x == r;
  }

  static BigInt _secretScalar(Uint8List secretKey) {
    if (secretKey.length != 32) {
      throw ArgumentError('Secret keys are 32 bytes.');
    }
    final d = _toInt(secretKey);
    if (d == BigInt.zero || d >= n) {
      throw ArgumentError('Secret key is out of range.');
    }
    return d;
  }

  static _Point? _liftX(BigInt x) {
    if (x >= p) return null;
    final c = (x.modPow(BigInt.from(3), p) + BigInt.from(7)) % p;
    final y = c.modPow(_sqrtExponent, p);
    if (y.modPow(BigInt.two, p) != c) return null;
    return _Point(x, y.isEven ? y : p - y, BigInt.one);
  }

  static Uint8List _taggedHash(String tag, List<int> message) {
    final tagHash = sha256.convert(tag.codeUnits).bytes;
    return Uint8List.fromList(
      sha256.convert([...tagHash, ...tagHash, ...message]).bytes,
    );
  }

  static _Point _mul(_Point point, BigInt scalar) {
    var result = _Point.infinity;
    var addend = point;
    var k = scalar;
    while (k > BigInt.zero) {
      if (k.isOdd) result = _add(result, addend);
      addend = _double(addend);
      k >>= 1;
    }
    return result;
  }

  // Jacobian coordinates on y² = x³ + 7.
  static _Point _double(_Point a) {
    if (a.isInfinity || a.y == BigInt.zero) return _Point.infinity;
    final ysq = (a.y * a.y) % p;
    final s = (BigInt.from(4) * a.x * ysq) % p;
    final m = (BigInt.from(3) * a.x * a.x) % p;
    final x = (m * m - BigInt.two * s) % p;
    final y = (m * (s - x) - BigInt.from(8) * ysq * ysq) % p;
    final z = (BigInt.two * a.y * a.z) % p;
    return _Point(x, y, z);
  }

  static _Point _add(_Point a, _Point b) {
    if (a.isInfinity) return b;
    if (b.isInfinity) return a;
    final z1z1 = (a.z * a.z) % p;
    final z2z2 = (b.z * b.z) % p;
    final u1 = (a.x * z2z2) % p;
    final u2 = (b.x * z1z1) % p;
    final s1 = (a.y * b.z * z2z2) % p;
    final s2 = (b.y * a.z * z1z1) % p;
    if (u1 == u2) {
      return s1 == s2 ? _double(a) : _Point.infinity;
    }
    final h = (u2 - u1) % p;
    final r = (s2 - s1) % p;
    final h2 = (h * h) % p;
    final h3 = (h * h2) % p;
    final u1h2 = (u1 * h2) % p;
    final x = (r * r - h3 - BigInt.two * u1h2) % p;
    final y = (r * (u1h2 - x) - s1 * h3) % p;
    final z = (h * a.z * b.z) % p;
    return _Point(x, y, z);
  }

  static BigInt _toInt(List<int> bytes) {
    var result = BigInt.zero;
    for (final byte in bytes) {
      result = (result << 8) | BigInt.from(byte);
    }
    return result;
  }

  static Uint8List _toBytes(BigInt value) {
    final out = Uint8List(32);
    var v = value;
    for (var index = 31; index >= 0; index--) {
      out[index] = (v & BigInt.from(0xff)).toInt();
      v >>= 8;
    }
    return out;
  }
}

class _Point {
  _Point(this.x, this.y, this.z);

  static final infinity = _Point(BigInt.one, BigInt.one, BigInt.zero);

  final BigInt x;
  final BigInt y;
  final BigInt z;

  bool get isInfinity => z == BigInt.zero;

  _Point affine() {
    final p = Secp256k1.p;
    final zInv = z.modInverse(p);
    final zInv2 = (zInv * zInv) % p;
    return _Point((x * zInv2) % p, (y * zInv2 * zInv) % p, BigInt.one);
  }
}

final _hex = RegExp(r'^[0-9a-fA-F]*$');

/// Lower-case hex of [bytes].
String hexEncode(List<int> bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

/// Bytes of lower- or upper-case hex; null when [hex] is not even-length hex.
Uint8List? hexDecode(String hex) {
  if (hex.length.isOdd || !_hex.hasMatch(hex)) return null;
  final out = Uint8List(hex.length ~/ 2);
  for (var index = 0; index < out.length; index++) {
    final value = int.tryParse(
      hex.substring(index * 2, index * 2 + 2),
      radix: 16,
    );
    if (value == null) return null;
    out[index] = value;
  }
  return out;
}
