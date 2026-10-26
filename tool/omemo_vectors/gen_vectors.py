#!/usr/bin/env python3
"""Generates Conest's OMEMO test vectors with the reference libraries.

The references are python-oldmemo / python-twomemo (with python-omemo,
python-x3dh and python-doubleratchet), the code behind the Python OMEMO
stack that Conversations, Dino and Gajim interoperate with. They are not
part of the repository: download the pinned sdists (see PINS), unpack them
into one directory and run

    python3 tool/omemo_vectors/gen_vectors.py DEPS_DIR > test/fixtures/omemo_vectors.json

DEPS_DIR holds the unpacked sdists (oldmemo-2.1.0/, twomemo-2.1.0/, ...).
Needs the `cryptography`, `protobuf`, `pydantic` and `typing_extensions`
Python packages. The C library behind `xeddsa` is replaced by the
pure-Python stand-in in shim/, so nothing is compiled.

Every random value is drawn from a scripted stream, so the output is
reproducible. The Dart test replays the same draws per actor and must
produce the same bytes; it also decrypts the reference's messages.

NOTE: written without being able to run the reference code in the session
that authored it (the code is external and was not executed there). If a
detail of the reference API differs from what is assumed below, fix it here;
the assertions on the way (every message decrypts on the reference side)
guard the output."""
import asyncio
import base64
import hashlib
import json
import os
import secrets
import sys

PINS = {
    "oldmemo": "2.1.0",
    "twomemo": "2.1.0",
    "omemo": "2.1.0",
    "x3dh": "1.3.0",
    "doubleratchet": "1.3.0",
}

here = os.path.dirname(os.path.abspath(__file__))
deps = sys.argv[1]
sys.path.insert(0, os.path.join(here, "shim"))
for name, version in PINS.items():
    sys.path.insert(0, os.path.join(deps, f"{name}-{version}"))

import doubleratchet.recommended.diffie_hellman_ratchet_curve25519 as dh25519  # noqa: E402
import oldmemo.oldmemo as oldmemo_mod  # noqa: E402
import twomemo.twomemo as twomemo_mod  # noqa: E402
import xeddsa  # noqa: E402
from omemo.storage import Storage, Just, Nothing  # noqa: E402
from omemo.session import Initiation  # noqa: E402


class Script:
    """Deterministic randomness, logged per actor."""

    def __init__(self, label):
        self.label = label
        self.counter = 0
        self.actor = "setup"
        self.log = {}

    def draw(self, n, what):
        out = b""
        while len(out) < n:
            out += hashlib.sha256(f"{self.label}/{self.counter}".encode()).digest()
            self.counter += 1
        out = out[:n]
        self.log.setdefault(self.actor, []).append({"what": what, "hex": out.hex()})
        return out


SCRIPT = None


def token_bytes(n=32):
    return SCRIPT.draw(n, "token")


secrets.token_bytes = token_bytes
dh25519.DiffieHellmanRatchet._generate_priv = staticmethod(
    lambda: SCRIPT.draw(32, "ratchet")
)


class MemoryStorage(Storage):
    def __init__(self):
        super().__init__(disable_cache=True)
        self.data = {}

    async def _load(self, key):
        return Just(self.data[key]) if key in self.data else Nothing()

    async def _store(self, key, value):
        self.data[key] = json.loads(json.dumps(value))

    async def _delete(self, key):
        self.data.pop(key, None)


async def make_backend(cls, seed):
    storage = MemoryStorage()
    await storage.store("/ikp/is_seed", True)
    await storage.store_bytes("/ikp/key", seed)
    return cls(storage), storage


def b64(data):
    return base64.b64encode(data).decode()


async def scenario(name, mod, backend_cls):
    global SCRIPT
    SCRIPT = Script(name)
    legacy = name == "oldmemo"
    alice_seed = SCRIPT.draw(32, "alice identity seed")
    bob_seed = SCRIPT.draw(32, "bob identity seed")
    SCRIPT.log.clear()
    alice, _ = await make_backend(backend_cls, alice_seed)
    bob, bob_storage = await make_backend(backend_cls, bob_seed)
    SCRIPT.actor = "setup"
    await bob.generate_pre_keys(1)
    bob_bundle = await bob.get_bundle("bob@example.org", 2222)
    alice_ed = xeddsa.seed_to_ed25519_pub(alice_seed)

    messages = []
    events = []

    def kex_blob(session, auth):
        if session.initiation is Initiation.ACTIVE and not session.confirmed:
            return session.key_exchange.serialize(auth)[0] if legacy else session.key_exchange.serialize(auth), True
        return auth, False

    def record(sender_role, kex, blob, content, plaintext):
        entry = {
            "from": sender_role,
            "kex": kex,
            "key": b64(blob),
            "payload": b64(content.ciphertext),
            "plaintext": plaintext.decode(),
        }
        if legacy:
            entry["iv"] = b64(content.initialization_vector)
        messages.append(entry)
        events.append({"op": "send", "msg": len(messages) - 1})
        return entry

    async def send(sender, role, session, plaintext):
        SCRIPT.actor = role
        content, key_material = await sender.encrypt_plaintext(plaintext)
        enc = await sender.encrypt_key_material(session, key_material)
        blob, kex = kex_blob(session, enc.serialize())
        await sender.store_session(session)
        return record(role, kex, blob, content, plaintext)

    async def receive(role, receiver, rsession, index, sender_jid, sender_id, sender_sign):
        SCRIPT.actor = role
        rec = messages[index]
        data = base64.b64decode(rec["key"])
        if rec["kex"]:
            if legacy:
                _, data = mod.KeyExchangeImpl.parse(data, sender_sign)
            else:
                _, data = mod.KeyExchangeImpl.parse(data)
        enc_in = mod.EncryptedKeyMaterialImpl.parse(data, sender_jid, sender_id)
        plain_key = await receiver.decrypt_key_material(rsession, enc_in)
        if legacy:
            content_in = mod.ContentImpl(
                base64.b64decode(rec["payload"]), base64.b64decode(rec["iv"])
            )
        else:
            content_in = mod.ContentImpl(base64.b64decode(rec["payload"]))
        got = await receiver.decrypt_plaintext(content_in, plain_key)
        assert got.decode() == rec["plaintext"], (got, rec)
        await receiver.store_session(rsession)
        events.append({"op": "recv", "msg": index})

    # Alice starts a session with Bob's bundle and sends the first message.
    SCRIPT.actor = "alice"
    content, key_material = await alice.encrypt_plaintext(b"hello bob")
    session, enc = await alice.build_session_active(
        "bob@example.org", 2222, bob_bundle, key_material
    )
    blob, kex = kex_blob(session, enc.serialize())
    await alice.store_session(session)
    first = record("alice", kex, blob, content, b"hello bob")

    # Bob builds the session from the key exchange and reads it.
    SCRIPT.actor = "bob"
    alice_sign = bool((alice_ed[31] >> 7) & 1)
    if legacy:
        kx, auth = mod.KeyExchangeImpl.parse(base64.b64decode(first["key"]), alice_sign)
        enc_in = mod.EncryptedKeyMaterialImpl.parse(auth, "alice@example.org", 1111)
        content_in = mod.ContentImpl(
            base64.b64decode(first["payload"]), base64.b64decode(first["iv"])
        )
    else:
        kx, auth = mod.KeyExchangeImpl.parse(base64.b64decode(first["key"]))
        enc_in = mod.EncryptedKeyMaterialImpl.parse(auth, "alice@example.org", 1111)
        content_in = mod.ContentImpl(base64.b64decode(first["payload"]))
    bob_session, plain_key = await bob.build_session_passive(
        "alice@example.org", 1111, kx, enc_in
    )
    assert await bob.decrypt_plaintext(content_in, plain_key) == b"hello bob"
    await bob.store_session(bob_session)
    events.append({"op": "recv", "msg": 0})

    # Alice's second message still carries the key exchange.
    await send(alice, "alice", session, b"second, before any reply")
    await receive("bob", bob, bob_session, 1, "alice@example.org", 1111, alice_sign)
    # Bob answers: a new ratchet step.
    await send(bob, "bob", bob_session, b"hi alice")
    await receive("alice", alice, session, 2, "bob@example.org", 2222, False)
    session.confirm()
    # Alice again, after the answer (no key exchange now, new ratchet key).
    await send(alice, "alice", session, b"third, after your reply")
    await receive("bob", bob, bob_session, 3, "alice@example.org", 1111, alice_sign)
    # Three messages that arrive out of order: 6, then 4, then 5.
    for text in (b"burst four", b"burst five", b"burst six"):
        await send(alice, "alice", session, text)
    await send(bob, "bob", bob_session, b"bob one")
    await send(bob, "bob", bob_session, b"bob two")
    for index in (6, 4, 5):
        await receive("bob", bob, bob_session, index, "alice@example.org", 1111, alice_sign)
    for index in (7, 8):
        await receive("alice", alice, session, index, "bob@example.org", 2222, False)

    ik_ed = bob_bundle.bundle.identity_key
    if legacy:
        sig = bytearray(bob_bundle.bundle.signed_pre_key_sig)
        sig[63] |= ik_ed[31] & 0x80
        bundle = {
            "identityKey": b64(b"\x05" + xeddsa.ed25519_pub_to_curve25519_pub(ik_ed)),
            "signedPreKeyId": bob_bundle.signed_pre_key_id,
            "signedPreKey": b64(b"\x05" + bob_bundle.bundle.signed_pre_key),
            "signedPreKeySignature": b64(bytes(sig)),
            "preKeys": {str(i): b64(b"\x05" + k) for k, i in bob_bundle.pre_key_ids.items()},
        }
    else:
        bundle = {
            "identityKey": b64(ik_ed),
            "signedPreKeyId": bob_bundle.signed_pre_key_id,
            "signedPreKey": b64(bob_bundle.bundle.signed_pre_key),
            "signedPreKeySignature": b64(bob_bundle.bundle.signed_pre_key_sig),
            "preKeys": {str(i): b64(k) for k, i in bob_bundle.pre_key_ids.items()},
        }

    state = bob_storage.data[f"/{mod.NAMESPACE}/x3dh"]

    def secret_bytes(value):
        """Stored secrets are base64 text (or lists of ints)."""
        if isinstance(value, str):
            return base64.b64decode(value)
        return bytes(value)

    spk_priv = secret_bytes(state["signed_pre_key"]["priv"])
    assert xeddsa.priv_to_curve25519_pub(spk_priv) == bob_bundle.bundle.signed_pre_key
    pre_key_privs = {}
    for stored in state["pre_keys"]:
        priv = secret_bytes(stored)
        pub = xeddsa.priv_to_curve25519_pub(priv)
        pre_key_privs[str(bob_bundle.pre_key_ids[pub])] = priv.hex()

    return {
        "namespace": mod.NAMESPACE,
        "alice": {
            "jid": "alice@example.org",
            "deviceId": 1111,
            "identitySeed": alice_seed.hex(),
        },
        "bob": {
            "jid": "bob@example.org",
            "deviceId": 2222,
            "identitySeed": bob_seed.hex(),
            "signedPreKeyId": bob_bundle.signed_pre_key_id,
            "signedPreKeyPriv": spk_priv.hex(),
            "preKeyPrivs": pre_key_privs,
        },
        "bundle": bundle,
        "draws": SCRIPT.log,
        "messages": messages,
        "events": events,
    }


async def main():
    out = {
        "generator": "tool/omemo_vectors/gen_vectors.py",
        "pins": PINS,
        "oldmemo": await scenario("oldmemo", oldmemo_mod, oldmemo_mod.Oldmemo),
        "twomemo": await scenario("twomemo", twomemo_mod, twomemo_mod.Twomemo),
    }
    json.dump(out, sys.stdout, indent=1, sort_keys=True)
    print()


asyncio.run(main())
