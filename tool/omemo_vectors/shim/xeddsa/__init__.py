"""A pure-Python stand-in for the `xeddsa` package (which needs the C library
libxeddsa), only for generating and checking Conest's OMEMO test vectors.

Written from RFC 8032 and Signal's XEdDSA specification, independently of the
Dart code it helps to check. Slow and not constant-time: never use it for
anything but tests."""
import hashlib

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import (
    Ed25519PrivateKey,
    Ed25519PublicKey,
)
from cryptography.hazmat.primitives.asymmetric.x25519 import (
    X25519PrivateKey,
    X25519PublicKey,
)
from cryptography.exceptions import InvalidSignature

P = 2**255 - 19
L = 2**252 + 27742317777372353535851937790883648493
D = (-121665 * pow(121666, P - 2, P)) % P
I = pow(2, (P - 1) // 4, P)


class XEdDSAException(Exception):
    pass


def _inv(x):
    return pow(x, P - 2, P)


def _recover_x(y, sign):
    xx = ((y * y - 1) * _inv(D * y * y + 1)) % P
    x = pow(xx, (P + 3) // 8, P)
    if (x * x - xx) % P != 0:
        x = (x * I) % P
    if (x * x - xx) % P != 0:
        raise ValueError("not on curve")
    if x & 1 != sign:
        x = P - x
    return x


_BY = (4 * _inv(5)) % P
_BX = _recover_x(_BY, 0)
BASE = (_BX, _BY)


def _add(p, q):
    x1, y1 = p
    x2, y2 = q
    t = (D * x1 * x2 * y1 * y2) % P
    x3 = ((x1 * y2 + x2 * y1) * _inv(1 + t)) % P
    y3 = ((y1 * y2 + x1 * x2) * _inv(1 - t)) % P
    return (x3, y3)


def _mul(p, n):
    r = (0, 1)
    while n > 0:
        if n & 1:
            r = _add(r, p)
        p = _add(p, p)
        n >>= 1
    return r


def _encode(p):
    x, y = p
    return (y | ((x & 1) << 255)).to_bytes(32, "little")


def _decode(b):
    v = int.from_bytes(b, "little")
    sign = v >> 255
    y = v & ((1 << 255) - 1)
    return (_recover_x(y, sign), y)


def _le(b):
    return int.from_bytes(b, "little")


def _clamp(b):
    a = bytearray(b)
    a[0] &= 248
    a[31] &= 127
    a[31] |= 64
    return bytes(a)


def seed_to_priv(seed):
    return _clamp(hashlib.sha512(seed).digest()[:32])


def priv_to_ed25519_pub(priv):
    return _encode(_mul(BASE, _le(priv)))


def seed_to_ed25519_pub(seed):
    return Ed25519PrivateKey.from_private_bytes(seed).public_key().public_bytes(
        serialization.Encoding.Raw, serialization.PublicFormat.Raw
    )


def priv_to_curve25519_pub(priv):
    return X25519PrivateKey.from_private_bytes(priv).public_key().public_bytes(
        serialization.Encoding.Raw, serialization.PublicFormat.Raw
    )


def priv_force_sign(priv, set_sign_bit):
    a = _le(priv) % L
    sign = priv_to_ed25519_pub(priv)[31] >> 7
    if bool(sign) != bool(set_sign_bit):
        a = (L - a) % L
    return a.to_bytes(32, "little")


def ed25519_priv_sign(priv, msg, nonce=None):
    import secrets

    if nonce is None:
        nonce = secrets.token_bytes(64)
    a = _le(priv) % L
    A = _encode(_mul(BASE, a))
    prefix = b"\xfe" + b"\xff" * 31
    r = _le(hashlib.sha512(prefix + a.to_bytes(32, "little") + msg + nonce).digest()) % L
    R = _encode(_mul(BASE, r))
    h = _le(hashlib.sha512(R + A + msg).digest()) % L
    s = (r + h * a) % L
    return R + s.to_bytes(32, "little")


def ed25519_seed_sign(seed, msg):
    return Ed25519PrivateKey.from_private_bytes(seed).sign(msg)


def ed25519_verify(sig, pub, msg):
    try:
        Ed25519PublicKey.from_public_bytes(pub).verify(sig, msg)
        return True
    except (InvalidSignature, ValueError):
        return False


def curve25519_pub_to_ed25519_pub(pub, set_sign_bit):
    u = _le(pub) & ((1 << 255) - 1)
    y = ((u - 1) * _inv(u + 1)) % P
    out = bytearray(y.to_bytes(32, "little"))
    if set_sign_bit:
        out[31] |= 0x80
    return bytes(out)


def ed25519_pub_to_curve25519_pub(pub):
    y = _le(pub) & ((1 << 255) - 1)
    u = ((1 + y) * _inv(1 - y)) % P
    return u.to_bytes(32, "little")


def x25519(priv, pub):
    out = X25519PrivateKey.from_private_bytes(priv).exchange(
        X25519PublicKey.from_public_bytes(pub)
    )
    return out
