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

/// The answer, sealed under [keys] with random padding. [at_most]: the
/// reply may not be longer than this (an answer to a request that has no
/// cookie must not be bigger than the request, or it amplifies); the
/// padding shrinks to fit, and no reply is sent if even the bare box does
/// not.
pub(crate) fn seal_response(
    keys: &ExchangeKeys,
    response: &[u8],
    at_most: Option<usize>,
) -> Option<Vec<u8>> {
    let mut rng = rand::thread_rng();
    let mut nonce = [0_u8; NONCE];
    rng.fill_bytes(&mut nonce);
    let bare = NONCE + 2 + response.len() + TAG;
    let mut room = MAX_REPLY_PAD;
    if let Some(limit) = at_most {
        room = room.min(limit.checked_sub(bare)?);
    }
    let pad = rng.gen_range(0..=room);
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

/// Key exchanges allowed per second in all, and per source a minute.
const MAX_EXCHANGES_PER_SECOND: u64 = 2_000;

/// Sources that completed an exchange with a valid cookie lately: they
/// skip the relay-wide cap (a flood of cookie-less datagrams cannot starve
/// them), still under their own per-source budget. A source address on UDP
/// can be forged, so this is a courtesy, not an identity: a forger who
/// spends a victim's per-source budget only slows the victim's UDP polls
/// (clients fall back to other routes), and cannot get anything but a
/// cookie-sized reply sent to the victim.
static GOOD_SOURCES: std::sync::Mutex<Vec<(String, u64)>> = std::sync::Mutex::new(Vec::new());
const MAX_GOOD_SOURCES: usize = 4096;
const GOOD_SOURCE_MILLIS: u64 = 120_000;

fn note_good_source(peer: SocketAddr) {
    let now = crate::config::now_millis();
    let key = crate::limits::peer_key(peer.ip());
    let mut good = GOOD_SOURCES.lock().expect("good sources lock");
    good.retain(|(_, until)| *until > now);
    if let Some(entry) = good.iter_mut().find(|(known, _)| *known == key) {
        entry.1 = now + GOOD_SOURCE_MILLIS;
    } else if good.len() < MAX_GOOD_SOURCES {
        good.push((key, now + GOOD_SOURCE_MILLIS));
    }
}

fn is_good_source(peer: SocketAddr) -> bool {
    let now = crate::config::now_millis();
    let key = crate::limits::peer_key(peer.ip());
    GOOD_SOURCES
        .lock()
        .expect("good sources lock")
        .iter()
        .any(|(known, until)| *known == key && *until > now)
}

fn allow_key_exchange(state: &RelayState, peer: SocketAddr) -> bool {
    use std::sync::atomic::{AtomicU64, Ordering};
    // (second, count): one window for the whole relay.
    static WINDOW: AtomicU64 = AtomicU64::new(0);
    static COUNT: AtomicU64 = AtomicU64::new(0);
    let second = crate::config::now_millis() / 1_000;
    if WINDOW.swap(second, Ordering::AcqRel) != second {
        COUNT.store(0, Ordering::Release);
    }
    if COUNT.fetch_add(1, Ordering::AcqRel) >= MAX_EXCHANGES_PER_SECOND && !is_good_source(peer) {
        return false;
    }
    // Per source, kept apart from every other budget; refusals here never
    // ban (the source of a datagram can be forged).
    let key = format!("udp-dh:{}", crate::limits::peer_key(peer.ip()));
    state.allow_request_banning(&key, false)
}

/// What to send back for one datagram, sealed or cleartext as it came.
/// `None`: nothing goes back (refused, invalid, or not even a request).
pub(crate) fn answer_datagram(
    datagram: &[u8],
    state: &RelayState,
    peer: SocketAddr,
) -> Option<Vec<u8>> {
    // Key exchanges are the costly step on the one UDP thread: a source
    // that asks too often, or all sources together, are not served.
    if datagram.len() >= MIN_DATAGRAM && datagram[0] != b'{' && !allow_key_exchange(state, peer) {
        return None;
    }
    let sealed = open_request(datagram, &state.identity);
    let response: Value = match &sealed {
        // The wire length counts for the cookie and size rules.
        Some((request, _)) => handle_udp_datagram(request, datagram.len(), state, peer),
        None => handle_udp_datagram(datagram, datagram.len(), state, peer),
    };
    if response.is_null() {
        return None;
    }
    // A request that carried a valid cookie got more than a cookie reply.
    if sealed.is_some() && response["error"] != "udp cookie required" {
        note_good_source(peer);
    }
    let bytes = serde_json::to_vec(&response).ok()?;
    // A cookie request is answered only with a reply no longer than itself.
    let at_most = (response["error"] == "udp cookie required").then_some(datagram.len());
    match sealed {
        Some((_, keys)) => seal_response(&keys, &bytes, at_most),
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
