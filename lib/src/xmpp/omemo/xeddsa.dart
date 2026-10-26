import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';

/// Curve25519 and Edwards25519 conversions and XEdDSA (Signal's signatures
/// with Montgomery keys), which OMEMO needs and the `cryptography` package
/// does not offer. Field and group arithmetic on [BigInt]: slow, but only
/// used for a few signatures and conversions per session.

final BigInt _p = (BigInt.one << 255) - BigInt.from(19);
final BigInt _l =
    (BigInt.one << 252) +
    BigInt.parse('27742317777372353535851937790883648493');
final BigInt _d =
    (-BigInt.from(121665) * BigInt.from(121666).modInverse(_p)) % _p;
final BigInt _sqrtM1 = BigInt.two.modPow(
  (_p - BigInt.one) ~/ BigInt.from(4),
  _p,
);
final BigInt _by = (BigInt.from(4) * BigInt.from(5).modInverse(_p)) % _p;
final _Point _base = _Point.fromY(_by, false)!;

BigInt _decodeLe(List<int> bytes) {
  var result = BigInt.zero;
  for (var index = bytes.length - 1; index >= 0; index--) {
    result = (result << 8) | BigInt.from(bytes[index]);
  }
  return result;
}

Uint8List _encodeLe(BigInt value, int length) {
  final out = Uint8List(length);
  var rest = value;
  for (var index = 0; index < length; index++) {
    out[index] = (rest & BigInt.from(0xff)).toInt();
    rest >>= 8;
  }
  return out;
}

/// A point in extended coordinates (X:Y:Z:T).
class _Point {
  _Point(this.x, this.y, this.z, this.t);

  final BigInt x;
  final BigInt y;
  final BigInt z;
  final BigInt t;

  static final _Point zero = _Point(
    BigInt.zero,
    BigInt.one,
    BigInt.one,
    BigInt.zero,
  );

  /// The point with [y] and the sign of x given by [negative], if any.
  static _Point? fromY(BigInt y, bool negative) {
    if (y >= _p) return null;
    final y2 = (y * y) % _p;
    final u = (y2 - BigInt.one) % _p;
    final v = (_d * y2 + BigInt.one) % _p;
    // x = sqrt(u / v)
    final candidate =
        (u *
            v.modPow(BigInt.from(3), _p) *
            (u * v.modPow(BigInt.from(7), _p)).modPow(
              (_p - BigInt.from(5)) ~/ BigInt.from(8),
              _p,
            )) %
        _p;
    var x = candidate;
    final check = (v * x * x) % _p;
    if (check != u % _p) {
      if (check == (-u) % _p) {
        x = (x * _sqrtM1) % _p;
      } else {
        return null;
      }
    }
    if (x == BigInt.zero && negative) return null;
    if (x.isOdd != negative) x = (_p - x) % _p;
    return _Point(x, y, BigInt.one, (x * y) % _p);
  }

  _Point add(_Point other) {
    final a = ((y - x) * (other.y - other.x)) % _p;
    final b = ((y + x) * (other.y + other.x)) % _p;
    final c = (t * BigInt.two * _d * other.t) % _p;
    final dd = (z * BigInt.two * other.z) % _p;
    final e = (b - a) % _p;
    final f = (dd - c) % _p;
    final g = (dd + c) % _p;
    final h = (b + a) % _p;
    return _Point((e * f) % _p, (g * h) % _p, (f * g) % _p, (e * h) % _p);
  }

  _Point multiply(BigInt scalar) {
    var result = zero;
    var addend = this;
    var rest = scalar;
    while (rest > BigInt.zero) {
      if (rest.isOdd) result = result.add(addend);
      addend = addend.add(addend);
      rest >>= 1;
    }
    return result;
  }

  Uint8List encode() {
    final zInverse = z.modInverse(_p);
    final ax = (x * zInverse) % _p;
    final ay = (y * zInverse) % _p;
    final out = _encodeLe(ay, 32);
    if (ax.isOdd) out[31] |= 0x80;
    return out;
  }
}

/// The Edwards form of a Montgomery (X25519) public key, with the given
/// sign bit (XEdDSA uses 0).
Uint8List? montgomeryToEdwards(List<int> u, {bool negative = false}) {
  if (u.length != 32) return null;
  final value = _decodeLe(u) & ((BigInt.one << 255) - BigInt.one);
  if (value >= _p) return null;
  final denominator = (value + BigInt.one) % _p;
  if (denominator == BigInt.zero) return null;
  final y = ((value - BigInt.one) * denominator.modInverse(_p)) % _p;
  final out = _encodeLe(y, 32);
  if (negative) out[31] |= 0x80;
  return out;
}

/// The Montgomery (X25519) form of an Ed25519 public key.
Uint8List? edwardsToMontgomery(List<int> a) {
  if (a.length != 32) return null;
  final y = _decodeLe(a) & ((BigInt.one << 255) - BigInt.one);
  if (y >= _p) return null;
  final denominator = (BigInt.one - y) % _p;
  if (denominator == BigInt.zero) return null;
  final u = ((BigInt.one + y) * denominator.modInverse(_p)) % _p;
  return _encodeLe(u, 32);
}

/// The X25519 private key of an Ed25519 seed (as Ed25519 itself derives
/// its scalar): SHA-512, first half, clamped.
Uint8List ed25519SeedToX25519Private(List<int> seed) {
  final digest = sha512.convert(seed).bytes;
  final key = Uint8List.fromList(digest.sublist(0, 32));
  key[0] &= 248;
  key[31] &= 127;
  key[31] |= 64;
  return key;
}

Uint8List _clamp(List<int> key) {
  final out = Uint8List.fromList(key);
  out[0] &= 248;
  out[31] &= 127;
  out[31] |= 64;
  return out;
}

/// An XEdDSA signature of [message] with the X25519 private key
/// [privateKey] (Signal's specification, with 64 bytes of [random]).
Uint8List xeddsaSign(
  List<int> privateKey,
  List<int> message,
  List<int> random,
) {
  if (privateKey.length != 32 || random.length != 64) {
    throw ArgumentError('XEdDSA needs a 32-byte key and 64 random bytes.');
  }
  final k = _decodeLe(_clamp(privateKey)) % _l;
  final e = _base.multiply(k);
  final encoded = e.encode();
  // A has sign bit 0: the scalar is negated when E's x is odd.
  final negative = encoded[31] & 0x80 != 0;
  final a = negative ? (_l - k) % _l : k;
  encoded[31] &= 0x7f;
  final prefix = Uint8List(32)..fillRange(0, 32, 0xff);
  prefix[0] = 0xfe;
  final r =
      _decodeLe(
        sha512.convert([
          ...prefix,
          ..._encodeLe(a, 32),
          ...message,
          ...random,
        ]).bytes,
      ) %
      _l;
  final rPoint = _base.multiply(r).encode();
  final h =
      _decodeLe(sha512.convert([...rPoint, ...encoded, ...message]).bytes) % _l;
  final s = (r + h * a) % _l;
  return Uint8List.fromList([...rPoint, ..._encodeLe(s, 32)]);
}

/// Checks an XEdDSA signature by the Montgomery public key [publicKey].
/// Older Signal libraries put the Edwards sign bit into the signature's
/// last byte; both forms are accepted.
Future<bool> xeddsaVerify(
  List<int> publicKey,
  List<int> message,
  List<int> signature,
) async {
  if (signature.length != 64 || publicKey.length != 32) return false;
  final negative = signature[63] & 0x80 != 0;
  final edwards = montgomeryToEdwards(publicKey, negative: negative);
  if (edwards == null) return false;
  final cleaned = Uint8List.fromList(signature);
  cleaned[63] &= 0x7f;
  return ed25519Verify(edwards, message, cleaned);
}

/// A plain Ed25519 signature check.
Future<bool> ed25519Verify(
  List<int> publicKey,
  List<int> message,
  List<int> signature,
) async {
  if (signature.length != 64 || publicKey.length != 32) return false;
  try {
    return await Ed25519().verify(
      message,
      signature: Signature(
        signature,
        publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519),
      ),
    );
  } catch (_) {
    return false;
  }
}
