//! Sealed UDP (M38-C): v1 requests over UDP without the telltale cleartext
//! JSON. A client that knows the relay's session key (health, signed by the
//! pinned identity) sends
//!
//! ```text
//! ephemeral X25519 public key (32) | nonce (12) | ChaCha20-Poly1305(u16 len | request | padding)
//! ```
//!
//! and gets `nonce (12) | ChaCha20-Poly1305(u16 len | response | padding)`
//! back, under a key both sides derive from the Diffie-Hellman of the
//! ephemeral key and the relay's static key. Lengths vary (random padding),
//! nothing in the datagram is a fixed byte string, and the request stays
//! under the same cookie, rate and size budgets as a cleartext one (the
//! datagram's wire length counts). A datagram starting with `{` is the old
//! cleartext form; a client picks an ephemeral key that does not start
//! with it.

use std::net::SocketAddr;

use chacha20poly1305::aead::{Aead, KeyInit, Payload};
use chacha20poly1305::{ChaCha20Poly1305, Key, Nonce};
use rand::{Rng, RngCore};
use serde_json::Value;
use sha2::{Digest, Sha256};

use crate::identity::RelayIdentity;
use crate::storage::RelayState;
use crate::v1::handle_udp_datagram;

pub(crate) const KEY_LABEL: &[u8] = b"conest-relay-udp-v2";
const EPHEMERAL: usize = 32;
const NONCE: usize = 12;
const TAG: usize = 16;
/// The smallest datagram that can hold a sealed request.
pub(crate) const MIN_DATAGRAM: usize = EPHEMERAL + NONCE + TAG + 2;
/// Random padding added to an answer, at most.
const MAX_REPLY_PAD: usize = 96;

/// The keys of one exchange: request and response directions.
pub(crate) struct ExchangeKeys {
    request: [u8; 32],
    response: [u8; 32],
}

fn derive(shared: &[u8; 32], ephemeral: &[u8], relay_public: &[u8; 32]) -> ExchangeKeys {
    let one = |direction: &[u8]| {
        let mut hasher = Sha256::new();
        hasher.update(KEY_LABEL);
        hasher.update(direction);
        hasher.update(shared);
        hasher.update(ephemeral);
        hasher.update(relay_public);
        let mut key = [0_u8; 32];
        key.copy_from_slice(&hasher.finalize());
        key
    };
    ExchangeKeys {
        request: one(b"|request"),
        response: one(b"|response"),
    }
}

fn frame(plaintext: &[u8], pad: usize) -> Vec<u8> {
    let mut out = Vec::with_capacity(2 + plaintext.len() + pad);
    out.extend_from_slice(&(plaintext.len() as u16).to_be_bytes());
    out.extend_from_slice(plaintext);
    out.resize(out.len() + pad, 0);
    out
}

fn unframe(framed: &[u8]) -> Option<&[u8]> {
    let length = u16::from_be_bytes([*framed.first()?, *framed.get(1)?]) as usize;
    framed.get(2..2 + length)
}

fn cipher(key: &[u8; 32]) -> ChaCha20Poly1305 {
    ChaCha20Poly1305::new(Key::from_slice(key))
}

/// The request inside a sealed datagram, and the keys to answer with.
/// `None` for anything that is not one (wrong key, damaged, too short).
pub(crate) fn open_request(
    datagram: &[u8],
    identity: &RelayIdentity,
) -> Option<(Vec<u8>, ExchangeKeys)> {
    if datagram.len() < MIN_DATAGRAM || datagram[0] == b'{' {
        return None;
    }
    let ephemeral: [u8; 32] = datagram[..EPHEMERAL].try_into().ok()?;
    let shared = x25519_dalek::StaticSecret::from(identity.noise_private)
        .diffie_hellman(&x25519_dalek::PublicKey::from(ephemeral));
    // A low-order ephemeral key gives an all-zero secret anyone can compute.
    if !shared.was_contributory() {
        return None;
    }
    let keys = derive(shared.as_bytes(), &ephemeral, &identity.noise_public);
    let nonce = Nonce::from_slice(&datagram[EPHEMERAL..EPHEMERAL + NONCE]);
    let framed = cipher(&keys.request)
        .decrypt(
            nonce,
            Payload {
                msg: &datagram[EPHEMERAL + NONCE..],
                aad: &ephemeral,
            },
        )
        .ok()?;
    let request = unframe(&framed)?.to_vec();
    Some((request, keys))
}

/// The answer, sealed under [keys] with random padding.
pub(crate) fn seal_response(keys: &ExchangeKeys, response: &[u8]) -> Option<Vec<u8>> {
    let mut rng = rand::thread_rng();
    let mut nonce = [0_u8; NONCE];
    rng.fill_bytes(&mut nonce);
    let pad = rng.gen_range(0..=MAX_REPLY_PAD);
    let sealed = cipher(&keys.response)
        .encrypt(
            Nonce::from_slice(&nonce),
            Payload {
                msg: &frame(response, pad),
                aad: &[],
            },
        )
        .ok()?;
    let mut out = nonce.to_vec();
    out.extend_from_slice(&sealed);
    Some(out)
}

/// What to send back for one datagram, sealed or cleartext as it came.
/// `None`: nothing goes back (refused, invalid, or not even a request).
pub(crate) fn answer_datagram(
    datagram: &[u8],
    state: &RelayState,
    peer: SocketAddr,
) -> Option<Vec<u8>> {
    let sealed = open_request(datagram, &state.identity);
    let response: Value = match &sealed {
        // The wire length counts for the cookie and size rules.
        Some((request, _)) => handle_udp_datagram(request, datagram.len(), state, peer),
        None => handle_udp_datagram(datagram, datagram.len(), state, peer),
    };
    if response.is_null() {
        return None;
    }
    let bytes = serde_json::to_vec(&response).ok()?;
    match sealed {
        Some((_, keys)) => seal_response(&keys, &bytes),
        None => Some(bytes),
    }
}

#[cfg(test)]
pub(crate) mod client_for_tests {
    //! A client's side, to test against (the app's Dart code does the same).
    use super::*;

    pub(crate) fn seal_request(
        relay_public: &[u8; 32],
        request: &[u8],
        pad: usize,
    ) -> (Vec<u8>, ExchangeKeys) {
        let mut rng = rand::thread_rng();
        loop {
            let mut secret = [0_u8; 32];
            rng.fill_bytes(&mut secret);
            let secret = x25519_dalek::StaticSecret::from(secret);
            let ephemeral = x25519_dalek::PublicKey::from(&secret).to_bytes();
            if ephemeral[0] == b'{' {
                continue;
            }
            let shared = secret.diffie_hellman(&x25519_dalek::PublicKey::from(*relay_public));
            let keys = derive(shared.as_bytes(), &ephemeral, relay_public);
            let mut nonce = [0_u8; NONCE];
            rng.fill_bytes(&mut nonce);
            let sealed = cipher(&keys.request)
                .encrypt(
                    Nonce::from_slice(&nonce),
                    Payload {
                        msg: &frame(request, pad),
                        aad: &ephemeral,
                    },
                )
                .unwrap();
            let mut out = ephemeral.to_vec();
            out.extend_from_slice(&nonce);
            out.extend_from_slice(&sealed);
            return (out, keys);
        }
    }

    pub(crate) fn open_response(keys: &ExchangeKeys, datagram: &[u8]) -> Option<Vec<u8>> {
        let framed = cipher(&keys.response)
            .decrypt(
                Nonce::from_slice(datagram.get(..NONCE)?),
                Payload {
                    msg: datagram.get(NONCE..)?,
                    aad: &[],
                },
            )
            .ok()?;
        Some(unframe(&framed)?.to_vec())
    }
}
