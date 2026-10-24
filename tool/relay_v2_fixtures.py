#!/usr/bin/env python3
"""Generates test/fixtures/relay_v2/session.json: the relay v2 session
handshake (Noise_NK_25519_ChaChaPoly_SHA256) with fixed keys, transport
records and sample frames.

An implementation of its own (Python `cryptography`), so the Rust relay
(snow) and the Dart client are each checked against a third party rather
than against each other. Run from the repository root:

    python3 tool/relay_v2_fixtures.py
"""

import hashlib
import hmac
import json
import struct
from pathlib import Path

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.asymmetric.x25519 import (
    X25519PrivateKey,
    X25519PublicKey,
)
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305
from cryptography.hazmat.primitives import serialization

PROTOCOL = b"Noise_NK_25519_ChaChaPoly_SHA256"
PROLOGUE = b"conest-relay-v2"
NOISE_KEY_LABEL = b"conest-relay-noise-static-v1"
BINDING_LABEL = b"conest-relay-noise-key-v1"
MAGIC = b"CNS2"
VERSION = 1


def raw_public(private: X25519PrivateKey) -> bytes:
    return private.public_key().public_bytes(
        serialization.Encoding.Raw, serialization.PublicFormat.Raw
    )


def hkdf(chaining_key: bytes, material: bytes, outputs: int):
    temp = hmac.new(chaining_key, material, hashlib.sha256).digest()
    first = hmac.new(temp, b"\x01", hashlib.sha256).digest()
    second = hmac.new(temp, first + b"\x02", hashlib.sha256).digest()
    if outputs == 2:
        return first, second
    third = hmac.new(temp, second + b"\x03", hashlib.sha256).digest()
    return first, second, third


def nonce_bytes(counter: int) -> bytes:
    return b"\x00\x00\x00\x00" + struct.pack("<Q", counter)


class Cipher:
    def __init__(self, key=None):
        self.key = key
        self.n = 0

    def encrypt(self, ad: bytes, plaintext: bytes) -> bytes:
        if self.key is None:
            return plaintext
        out = ChaCha20Poly1305(self.key).encrypt(nonce_bytes(self.n), plaintext, ad)
        self.n += 1
        return out

    def decrypt(self, ad: bytes, ciphertext: bytes) -> bytes:
        if self.key is None:
            return ciphertext
        out = ChaCha20Poly1305(self.key).decrypt(nonce_bytes(self.n), ciphertext, ad)
        self.n += 1
        return out


class Symmetric:
    def __init__(self):
        assert len(PROTOCOL) == 32
        self.h = PROTOCOL
        self.ck = PROTOCOL
        self.cipher = Cipher()

    def mix_hash(self, data: bytes):
        self.h = hashlib.sha256(self.h + data).digest()

    def mix_key(self, material: bytes):
        self.ck, key = hkdf(self.ck, material, 2)
        self.cipher = Cipher(key)

    def encrypt_and_hash(self, plaintext: bytes) -> bytes:
        ciphertext = self.cipher.encrypt(self.h, plaintext)
        self.mix_hash(ciphertext)
        return ciphertext

    def decrypt_and_hash(self, ciphertext: bytes) -> bytes:
        plaintext = self.cipher.decrypt(self.h, ciphertext)
        self.mix_hash(ciphertext)
        return plaintext

    def split(self):
        first, second = hkdf(self.ck, b"", 2)
        return Cipher(first), Cipher(second)


def dh(private: X25519PrivateKey, public: bytes) -> bytes:
    return private.exchange(X25519PublicKey.from_public_bytes(public))


def frame(kind: int, stream: int, payload: bytes) -> bytes:
    return struct.pack(">IBI", len(payload), kind, stream) + payload


def main():
    identity_seed = bytes(range(1, 33))
    identity = Ed25519PrivateKey.from_private_bytes(identity_seed)
    identity_public = identity.public_key().public_bytes(
        serialization.Encoding.Raw, serialization.PublicFormat.Raw
    )
    noise_private = hashlib.sha256(NOISE_KEY_LABEL + identity_seed).digest()
    relay_static = X25519PrivateKey.from_private_bytes(noise_private)
    relay_static_public = raw_public(relay_static)
    binding_message = BINDING_LABEL + relay_static_public
    binding_signature = identity.sign(binding_message)

    client_ephemeral_private = bytes([0x11] * 32)
    relay_ephemeral_private = bytes([0x22] * 32)
    client_e = X25519PrivateKey.from_private_bytes(client_ephemeral_private)
    relay_e = X25519PrivateKey.from_private_bytes(relay_ephemeral_private)

    msg1_payload = json.dumps({"v": 1}, separators=(",", ":")).encode()
    msg2_payload = json.dumps(
        {"v": 1, "max_frame": 1048576, "max_streams": 32, "idle_s": 120},
        separators=(",", ":"),
    ).encode()

    # Initiator (client).
    initiator = Symmetric()
    initiator.mix_hash(PROLOGUE)
    initiator.mix_hash(relay_static_public)
    e_pub = raw_public(client_e)
    initiator.mix_hash(e_pub)
    initiator.mix_key(dh(client_e, relay_static_public))
    msg1 = e_pub + initiator.encrypt_and_hash(msg1_payload)

    # Responder (relay).
    responder = Symmetric()
    responder.mix_hash(PROLOGUE)
    responder.mix_hash(relay_static_public)
    re = msg1[:32]
    responder.mix_hash(re)
    responder.mix_key(dh(relay_static, re))
    assert responder.decrypt_and_hash(msg1[32:]) == msg1_payload
    relay_e_pub = raw_public(relay_e)
    responder.mix_hash(relay_e_pub)
    responder.mix_key(dh(relay_e, re))
    msg2 = relay_e_pub + responder.encrypt_and_hash(msg2_payload)

    initiator.mix_hash(msg2[:32])
    initiator.mix_key(dh(client_e, msg2[:32]))
    assert initiator.decrypt_and_hash(msg2[32:]) == msg2_payload
    assert initiator.h == responder.h
    client_send, client_receive = initiator.split()
    relay_receive, relay_send = responder.split()

    request = json.dumps(
        {"action": "health"}, separators=(",", ":")
    ).encode()
    response = json.dumps(
        {"ok": True, "stored": False, "messages": [], "error": None, "stats": None},
        separators=(",", ":"),
    ).encode()
    frames = [
        {"type": 1, "stream": 1, "payload": request.decode(), "hex": frame(1, 1, request).hex()},
        {"type": 2, "stream": 1, "payload": response.decode(), "hex": frame(2, 1, response).hex()},
        {"type": 5, "stream": 0, "payload": "", "hex": frame(5, 0, b"").hex()},
        {
            "type": 16,
            "stream": 7,
            "payload": "",
            "hex": frame(16, 7, b"").hex(),
        },
    ]
    transport = []
    for direction, plaintext in [
        ("client", frame(1, 1, request)),
        ("client", frame(5, 0, b"")),
        ("relay", frame(2, 1, response)),
    ]:
        cipher = client_send if direction == "client" else relay_send
        check = relay_receive if direction == "client" else client_receive
        ciphertext = cipher.encrypt(b"", plaintext)
        assert check.decrypt(b"", ciphertext) == plaintext
        transport.append(
            {
                "from": direction,
                "plaintext": plaintext.hex(),
                "record": (struct.pack(">H", len(ciphertext)) + ciphertext).hex(),
            }
        )

    fixture = {
        "comment": "Generated by tool/relay_v2_fixtures.py; checked by the Rust relay and the Dart client.",
        "protocol": PROTOCOL.decode(),
        "prologue": PROLOGUE.hex(),
        "identity_seed": identity_seed.hex(),
        "identity_public": identity_public.hex(),
        "noise_key_label": NOISE_KEY_LABEL.decode(),
        "relay_static_private": noise_private.hex(),
        "relay_static_public": relay_static_public.hex(),
        "binding_message": binding_message.hex(),
        "binding_signature": binding_signature.hex(),
        "client_ephemeral_private": client_ephemeral_private.hex(),
        "relay_ephemeral_private": relay_ephemeral_private.hex(),
        "client_hello": (MAGIC + bytes([VERSION]) + struct.pack(">H", len(msg1)) + msg1).hex(),
        "msg1_payload": msg1_payload.hex(),
        "msg1": msg1.hex(),
        "relay_hello": (struct.pack(">H", len(msg2)) + msg2).hex(),
        "msg2_payload": msg2_payload.hex(),
        "msg2": msg2.hex(),
        "handshake_hash": initiator.h.hex(),
        "transport": transport,
        "frames": frames,
    }
    out = Path("test/fixtures/relay_v2/session.json")
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(fixture, indent=2) + "\n")
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
