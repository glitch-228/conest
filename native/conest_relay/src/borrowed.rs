//! A borrowed TLS handshake (M38-D, "Reality-like", in the manner of
//! ShadowTLS): the relay listens on 443 and, for everyone, plays the TLS
//! handshake of a real site it points at (`--borrow-site`, say
//! `www.example.com:443`): bytes both ways are forwarded to that site, so
//! the client sees the real site's real certificate, and a prober sees
//! exactly what the site would send. A Conest client does a real TLS
//! handshake with its SNI set to that site, and right after it puts one
//! more application-data record on the wire that only the relay can
//! recognise:
//!
//! ```text
//! 0x17 0x03 0x03 | len | ephemeral X25519 public key (32) | tag (16) | random padding
//! ```
//!
//! `tag` is an HMAC over the real site's ServerHello random (so it is of no
//! use on any other connection), keyed from the Diffie-Hellman of the
//! ephemeral key and the relay's session key (the key v2 sessions use,
//! which the client learned from a signed health answer). When the tag
//! holds, the relay stops forwarding in both directions at a record
//! boundary, answers with one acknowledging record, and from then on both
//! sides exchange application-data-looking records whose payloads are
//! ChaCha20-Poly1305 boxes (padded) carrying the relay's ordinary byte
//! stream (v2 sessions, v1 lines). Anyone without the key sees a TLS
//! session with the real site.
//!
//! What this does not hide: the relay's IP address is not the real site's
//! (a censor that checks that sees it), and the ClientHello is the
//! client's TLS library's, not a browser's.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use chacha20poly1305::aead::{Aead, KeyInit, Payload};
use chacha20poly1305::{ChaCha20Poly1305, Key, Nonce};
use hmac::{Hmac, Mac};
use rand::{Rng, RngCore};
use sha2::{Digest, Sha256};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio::net::tcp::{OwnedReadHalf, OwnedWriteHalf};
use tokio::sync::Notify;
use tokio::time::{Instant, timeout, timeout_at};

use crate::outer::{BoxedStream, Opened, OuterLayer};

pub(crate) const LABEL: &[u8] = b"conest-borrowed-v1";
const HEADER: usize = 5;
/// The most a TLS record may carry (16384 plus the protocol's allowance).
const MAX_PAYLOAD: usize = 16_384 + 256;
/// The most data one tunnel record carries.
const MAX_DATA: usize = 8 * 1024;
const MAX_PAD: usize = 32;
const TAG: usize = 16;
const EPHEMERAL: usize = 32;
/// Records after the handshake in which the marker is looked for.
const MAX_AUTH_RECORDS: usize = 8;
/// A connection that never proves itself is the real site's, up to this.
const FORWARD_LIMIT: Duration = Duration::from_secs(600);
const CONNECT_LIMIT: Duration = Duration::from_secs(10);

/// The random of a HelloRetryRequest: not the session's ServerHello.
const HELLO_RETRY: [u8; 32] = [
    0xCF, 0x21, 0xAD, 0x74, 0xE5, 0x9A, 0x61, 0x11, 0xBE, 0x1D, 0x8C, 0x02, 0x1E, 0x65, 0xB8, 0x91,
    0xC2, 0xA2, 0x11, 0x16, 0x7A, 0xBB, 0x8C, 0x5E, 0x07, 0x9E, 0x09, 0xE2, 0xC8, 0xA8, 0x33, 0x9C,
];

/// The key pair the layer runs on, from the relay's identity seed: the
/// X25519 form of its Ed25519 identity (the clamped first half of the
/// seed's SHA-512, as for any Ed25519 key), so a client that has pinned
/// the identity needs nothing else to address the relay.
pub(crate) fn key_pair_from_seed(seed: &[u8; 32]) -> ([u8; 32], [u8; 32]) {
    let digest = sha2::Sha512::digest(seed);
    let mut secret = [0_u8; 32];
    secret.copy_from_slice(&digest[..32]);
    secret[0] &= 248;
    secret[31] &= 127;
    secret[31] |= 64;
    let public = x25519_dalek::PublicKey::from(&x25519_dalek::StaticSecret::from(secret));
    (secret, public.to_bytes())
}

/// The secret both sides derive from the key agreement.
pub(crate) fn exchange_key(dh: &[u8; 32], ephemeral: &[u8], relay_public: &[u8; 32]) -> [u8; 32] {
    let mut hasher = Sha256::new();
    hasher.update(LABEL);
    hasher.update(dh);
    hasher.update(ephemeral);
    hasher.update(relay_public);
    hasher.finalize().into()
}

fn mac(key: &[u8; 32], parts: &[&[u8]]) -> [u8; 32] {
    let mut mac = <Hmac<Sha256> as Mac>::new_from_slice(key).expect("hmac takes any key length");
    for part in parts {
        mac.update(part);
    }
    mac.finalize().into_bytes().into()
}

/// The tag the client's marker carries.
pub(crate) fn client_tag(key: &[u8; 32], server_random: &[u8; 32]) -> [u8; TAG] {
    let full = mac(key, &[b"client", server_random]);
    full[..TAG].try_into().expect("16 bytes")
}

/// The tag of the relay's acknowledging record.
pub(crate) fn server_ack(key: &[u8; 32], server_random: &[u8; 32], tag: &[u8]) -> [u8; TAG] {
    let full = mac(key, &[b"ack", server_random, tag]);
    full[..TAG].try_into().expect("16 bytes")
}

/// The keys of the two directions.
pub(crate) fn tunnel_keys(key: &[u8; 32], server_random: &[u8; 32]) -> ([u8; 32], [u8; 32]) {
    let derive = |direction: &[u8]| mac(key, &[b"tunnel", direction, server_random]);
    (derive(b"c2s"), derive(b"s2c"))
}

fn nonce(counter: u64) -> [u8; 12] {
    let mut nonce = [0_u8; 12];
    nonce[4..].copy_from_slice(&counter.to_be_bytes());
    nonce
}

fn record(kind: u8, payload: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(HEADER + payload.len());
    out.extend_from_slice(&[kind, 3, 3]);
    out.extend_from_slice(&(payload.len() as u16).to_be_bytes());
    out.extend_from_slice(payload);
    out
}

/// One tunnel record: [data] framed, padded and boxed under [key].
pub(crate) fn seal_record(key: &[u8; 32], counter: u64, data: &[u8]) -> Vec<u8> {
    let pad = rand::thread_rng().gen_range(0..=MAX_PAD);
    let mut framed = Vec::with_capacity(2 + data.len() + pad);
    framed.extend_from_slice(&(data.len() as u16).to_be_bytes());
    framed.extend_from_slice(data);
    framed.resize(framed.len() + pad, 0);
    let boxed = ChaCha20Poly1305::new(Key::from_slice(key))
        .encrypt(
            Nonce::from_slice(&nonce(counter)),
            Payload {
                msg: &framed,
                aad: &[],
            },
        )
        .expect("encryption of a bounded message");
    record(0x17, &boxed)
}

/// The data in a tunnel record's payload.
pub(crate) fn open_record(key: &[u8; 32], counter: u64, payload: &[u8]) -> Option<Vec<u8>> {
    let framed = ChaCha20Poly1305::new(Key::from_slice(key))
        .decrypt(
            Nonce::from_slice(&nonce(counter)),
            Payload {
                msg: payload,
                aad: &[],
            },
        )
        .ok()?;
    let length = u16::from_be_bytes([*framed.first()?, *framed.get(1)?]) as usize;
    Some(framed.get(2..2 + length)?.to_vec())
}

/// A complete record at the start of [buffer], taken out; `Ok(None)` when
/// more bytes are needed; `Err` when it is no TLS record (the stream is
/// then forwarded as it comes, unparsed).
fn take_record(buffer: &mut Vec<u8>) -> Result<Option<Vec<u8>>, ()> {
    if buffer.len() < HEADER {
        return Ok(None);
    }
    let length = u16::from_be_bytes([buffer[3], buffer[4]]) as usize;
    if !(0x14..=0x18).contains(&buffer[0]) || buffer[1] != 3 || length > MAX_PAYLOAD {
        return Err(());
    }
    if buffer.len() < HEADER + length {
        return Ok(None);
    }
    Ok(Some(buffer.drain(..HEADER + length).collect()))
}

/// The ServerHello's random in a handshake record, if it is one.
fn server_hello_random(record: &[u8]) -> Option<[u8; 32]> {
    if record.first() != Some(&0x16) {
        return None;
    }
    let payload = record.get(HEADER..)?;
    if payload.first() != Some(&2) || payload.get(4..6) != Some(&[3, 3]) {
        return None;
    }
    let random: [u8; 32] = payload.get(6..38)?.try_into().ok()?;
    (random != HELLO_RETRY).then_some(random)
}

/// The layer: forward to the real site until a client proves itself.
pub(crate) struct BorrowedLayer {
    site: String,
    secret: [u8; 32],
    public: [u8; 32],
}

impl BorrowedLayer {
    /// [site]: `host:port` of the real site. [secret], [public]: the
    /// relay's session key pair (the one v2 sessions use).
    pub(crate) fn new(site: String, secret: [u8; 32], public: [u8; 32]) -> Self {
        Self {
            site,
            secret,
            public,
        }
    }
}

impl OuterLayer for BorrowedLayer {
    fn open(&self, client: TcpStream, _deadline: Duration) -> Opened {
        let site = self.site.clone();
        let (secret, public) = (self.secret, self.public);
        Box::pin(async move {
            let upstream = match timeout(CONNECT_LIMIT, TcpStream::connect(&site)).await {
                Ok(Ok(stream)) => stream,
                // The real site is out of reach: nothing to play.
                _ => return Ok(None),
            };
            let _ = upstream.set_nodelay(true);
            run(client, upstream, secret, public).await
        })
    }
}

async fn run(
    client: TcpStream,
    upstream: TcpStream,
    secret: [u8; 32],
    public: [u8; 32],
) -> std::io::Result<Option<BoxedStream>> {
    let (mut client_read, client_write) = client.into_split();
    let (mut up_read, mut up_write) = upstream.into_split();
    let random: Arc<Mutex<Option<[u8; 32]>>> = Arc::new(Mutex::new(None));
    let stop = Arc::new(Notify::new());

    // The real site's answers, record by record, to the client.
    let mut down = {
        let (random, stop) = (Arc::clone(&random), Arc::clone(&stop));
        tokio::spawn(async move {
            let mut client_write = client_write;
            let mut buffer: Vec<u8> = Vec::new();
            let mut chunk = vec![0_u8; 16 * 1024];
            let mut raw = false;
            loop {
                tokio::select! {
                    biased;
                    _ = stop.notified() => return Some(client_write),
                    read = up_read.read(&mut chunk) => {
                        let Ok(read) = read else { return None };
                        if read == 0 {
                            let _ = client_write.shutdown().await;
                            return None;
                        }
                        if raw {
                            if client_write.write_all(&chunk[..read]).await.is_err() {
                                return None;
                            }
                            continue;
                        }
                        buffer.extend_from_slice(&chunk[..read]);
                        loop {
                            match take_record(&mut buffer) {
                                Ok(Some(record)) => {
                                    if let Some(found) = server_hello_random(&record) {
                                        let mut slot = random.lock().expect("random lock");
                                        slot.get_or_insert(found);
                                    }
                                    if client_write.write_all(&record).await.is_err() {
                                        return None;
                                    }
                                }
                                Ok(None) => break,
                                Err(()) => {
                                    raw = true;
                                    let rest = std::mem::take(&mut buffer);
                                    if client_write.write_all(&rest).await.is_err() {
                                        return None;
                                    }
                                    break;
                                }
                            }
                        }
                    }
                }
            }
        })
    };

    // The client's records, to the real site, unless one is the marker.
    let started = Instant::now();
    let mut buffer: Vec<u8> = Vec::new();
    let mut chunk = vec![0_u8; 16 * 1024];
    let mut raw = false;
    let mut application_records = 0_usize;
    loop {
        let read = tokio::select! {
            read = timeout_at(started + FORWARD_LIMIT, client_read.read(&mut chunk)) => read,
            _ = &mut down => return Ok(None),
        };
        let read = match read {
            Ok(Ok(read)) if read > 0 => read,
            _ => return Ok(None),
        };
        if raw {
            if up_write.write_all(&chunk[..read]).await.is_err() {
                return Ok(None);
            }
            continue;
        }
        buffer.extend_from_slice(&chunk[..read]);
        loop {
            match take_record(&mut buffer) {
                Ok(Some(record)) => {
                    if record[0] == 0x17 && application_records < MAX_AUTH_RECORDS {
                        application_records += 1;
                        let server_random = *random.lock().expect("random lock");
                        if let Some(server_random) = server_random
                            && let Some(key) =
                                recognise(&record[HEADER..], &secret, &public, &server_random)
                        {
                            stop.notify_one();
                            let Ok(Some(client_write)) = down.await else {
                                return Ok(None);
                            };
                            drop(up_write);
                            let tag = client_tag(&key, &server_random);
                            return Ok(Some(tunnel(
                                client_read,
                                client_write,
                                std::mem::take(&mut buffer),
                                key,
                                server_random,
                                tag,
                            )));
                        }
                    }
                    if up_write.write_all(&record).await.is_err() {
                        return Ok(None);
                    }
                }
                Ok(None) => break,
                Err(()) => {
                    raw = true;
                    let rest = std::mem::take(&mut buffer);
                    if up_write.write_all(&rest).await.is_err() {
                        return Ok(None);
                    }
                    break;
                }
            }
        }
    }
}

/// The exchange key, when [payload] is a valid marker for this connection.
fn recognise(
    payload: &[u8],
    secret: &[u8; 32],
    public: &[u8; 32],
    server_random: &[u8; 32],
) -> Option<[u8; 32]> {
    if payload.len() < EPHEMERAL + TAG {
        return None;
    }
    let ephemeral: [u8; 32] = payload[..EPHEMERAL].try_into().ok()?;
    let shared = x25519_dalek::StaticSecret::from(*secret)
        .diffie_hellman(&x25519_dalek::PublicKey::from(ephemeral));
    if !shared.was_contributory() {
        return None;
    }
    let key = exchange_key(shared.as_bytes(), &ephemeral, public);
    let expected = client_tag(&key, server_random);
    // Constant time enough: the tag is 16 bytes of an HMAC.
    let mut difference = 0_u8;
    for (a, b) in expected.iter().zip(&payload[EPHEMERAL..EPHEMERAL + TAG]) {
        difference |= a ^ b;
    }
    (difference == 0).then_some(key)
}

/// The relay's byte stream over the proven connection.
fn tunnel(
    client_read: OwnedReadHalf,
    client_write: OwnedWriteHalf,
    leftover: Vec<u8>,
    key: [u8; 32],
    server_random: [u8; 32],
    tag: [u8; TAG],
) -> BoxedStream {
    let (relay_side, bridge_side) = tokio::io::duplex(256 * 1024);
    let (mut bridge_read, mut bridge_write) = tokio::io::split(bridge_side);
    let (c2s, s2c) = tunnel_keys(&key, &server_random);
    let incoming = tokio::spawn(async move {
        let mut client_read = client_read;
        let mut buffer = leftover;
        let mut chunk = vec![0_u8; 16 * 1024];
        let mut counter = 0_u64;
        loop {
            loop {
                match take_record(&mut buffer) {
                    Ok(Some(record)) => {
                        if record[0] != 0x17 {
                            return;
                        }
                        let Some(data) = open_record(&c2s, counter, &record[HEADER..]) else {
                            return;
                        };
                        counter += 1;
                        if bridge_write.write_all(&data).await.is_err() {
                            return;
                        }
                    }
                    Ok(None) => break,
                    Err(()) => return,
                }
            }
            match client_read.read(&mut chunk).await {
                Ok(read) if read > 0 => buffer.extend_from_slice(&chunk[..read]),
                _ => return,
            }
        }
    });
    tokio::spawn(async move {
        let mut client_write = client_write;
        // The acknowledging record: the proof, in the shape of the others.
        let ack = server_ack(&key, &server_random, &tag);
        let mut payload = ack.to_vec();
        let pad = rand::thread_rng().gen_range(0..=MAX_PAD * 2);
        let mut padding = vec![0_u8; pad];
        rand::thread_rng().fill_bytes(&mut padding);
        payload.extend_from_slice(&padding);
        if client_write
            .write_all(&record(0x17, &payload))
            .await
            .is_err()
        {
            incoming.abort();
            return;
        }
        let mut chunk = vec![0_u8; MAX_DATA];
        let mut counter = 0_u64;
        loop {
            match bridge_read.read(&mut chunk).await {
                Ok(read) if read > 0 => {
                    let sealed = seal_record(&s2c, counter, &chunk[..read]);
                    counter += 1;
                    if client_write.write_all(&sealed).await.is_err() {
                        break;
                    }
                }
                _ => break,
            }
        }
        incoming.abort();
        let _ = client_write.shutdown().await;
    });
    Box::new(relay_side) as BoxedStream
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::identity::RelayIdentity;
    use crate::outer::serve_outer;
    use crate::parity_tests::parity_config;
    use crate::storage::RelayState;
    use std::io::{Read, Write};
    use std::net::SocketAddr;
    use std::sync::atomic::{AtomicU8, Ordering};
    use tokio::net::TcpListener;

    /// What a fake real site was sent, per connection.
    type Received = Arc<Mutex<Vec<Vec<u8>>>>;

    fn server_hello(random: [u8; 32]) -> Vec<u8> {
        let mut body = vec![3, 3];
        body.extend_from_slice(&random);
        body.extend_from_slice(&[0, 0x13, 0x01, 0, 0, 0]);
        let mut handshake = vec![2, 0, 0, body.len() as u8];
        handshake.extend_from_slice(&body);
        record(0x16, &handshake)
    }

    /// A fake real site: each connection gets its own ServerHello random
    /// (the connection's number repeated), two "encrypted" records, and
    /// everything it receives is kept.
    fn start_site() -> (String, Received) {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind");
        let address = listener.local_addr().expect("address").to_string();
        let received: Received = Arc::new(Mutex::new(Vec::new()));
        let kept = Arc::clone(&received);
        let counter = Arc::new(AtomicU8::new(1));
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(mut stream) = stream else { continue };
                let number = counter.fetch_add(1, Ordering::SeqCst);
                let index = {
                    let mut all = kept.lock().unwrap();
                    all.push(Vec::new());
                    all.len() - 1
                };
                let kept = Arc::clone(&kept);
                std::thread::spawn(move || {
                    let mut hello = server_hello([number; 32]);
                    hello.extend(record(0x17, &[0xAA; 90]));
                    hello.extend(record(0x17, &[0xBB; 40]));
                    stream.write_all(&hello).ok();
                    let mut chunk = [0_u8; 4096];
                    while let Ok(read) = stream.read(&mut chunk) {
                        if read == 0 {
                            break;
                        }
                        kept.lock().unwrap()[index].extend_from_slice(&chunk[..read]);
                    }
                });
            }
        });
        (address, received)
    }

    fn start_relay(site: &str) -> (SocketAddr, [u8; 32]) {
        let identity = RelayIdentity::from_seed_bytes([7_u8; 32]);
        let (secret, public) = key_pair_from_seed(&[7_u8; 32]);
        let state = RelayState::new(parity_config(), identity);
        let layer: Arc<dyn OuterLayer> =
            Arc::new(BorrowedLayer::new(site.to_owned(), secret, public));
        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind");
        let address = listener.local_addr().expect("address");
        listener.set_nonblocking(true).expect("nonblocking");
        std::thread::spawn(move || {
            let runtime = tokio::runtime::Builder::new_multi_thread()
                .worker_threads(2)
                .enable_all()
                .build()
                .expect("runtime");
            runtime.block_on(async move {
                let listener = TcpListener::from_std(listener).expect("listener");
                let _ = serve_outer(listener, layer, state).await;
            });
        });
        (address, public)
    }

    /// Reads TLS records from [stream] until [count] arrived.
    fn read_records(stream: &mut std::net::TcpStream, count: usize) -> Vec<Vec<u8>> {
        let mut records = Vec::new();
        let mut buffer = Vec::new();
        let mut chunk = [0_u8; 4096];
        while records.len() < count {
            let read = stream.read(&mut chunk).expect("records arrive");
            assert!(
                read > 0,
                "closed after {} of {count} records",
                records.len()
            );
            buffer.extend_from_slice(&chunk[..read]);
            while let Ok(Some(found)) = take_record(&mut buffer) {
                records.push(found);
            }
        }
        records
    }

    fn connect(address: SocketAddr) -> std::net::TcpStream {
        let stream = std::net::TcpStream::connect(address).expect("connect");
        stream
            .set_read_timeout(Some(Duration::from_secs(5)))
            .expect("timeout");
        stream
    }

    /// A client's marker for [server_random], and the exchange key.
    fn marker(relay_public: &[u8; 32], server_random: &[u8; 32]) -> (Vec<u8>, [u8; 32]) {
        let mut seed = [0_u8; 32];
        rand::thread_rng().fill_bytes(&mut seed);
        let secret = x25519_dalek::StaticSecret::from(seed);
        let ephemeral = x25519_dalek::PublicKey::from(&secret).to_bytes();
        let shared = secret.diffie_hellman(&x25519_dalek::PublicKey::from(*relay_public));
        let key = exchange_key(shared.as_bytes(), &ephemeral, relay_public);
        let mut payload = ephemeral.to_vec();
        payload.extend_from_slice(&client_tag(&key, server_random));
        payload.extend_from_slice(&[0x55; 20]);
        (record(0x17, &payload), key)
    }

    fn handshake_prefix() -> Vec<u8> {
        let mut bytes = record(0x16, &[1, 0, 0, 4, 3, 3, 0, 0]);
        bytes.extend(record(0x14, &[1]));
        bytes.extend(record(0x17, &[0x77; 53]));
        bytes
    }

    fn wait_for(received: &Received, index: usize, length: usize) -> Vec<u8> {
        for _ in 0..100 {
            if let Some(bytes) = received.lock().unwrap().get(index)
                && bytes.len() >= length
            {
                return bytes.clone();
            }
            std::thread::sleep(Duration::from_millis(30));
        }
        received
            .lock()
            .unwrap()
            .get(index)
            .cloned()
            .unwrap_or_default()
    }

    #[test]
    fn a_prober_gets_the_real_site_and_the_site_gets_the_probe_untouched() {
        let (site, received) = start_site();
        let (address, _) = start_relay(&site);
        let mut stream = connect(address);
        let probe = [handshake_prefix(), record(0x17, &[0x99; 70])].concat();
        stream.write_all(&probe).expect("write");
        // ServerHello, then the site's two records, exactly as the site sent.
        let records = read_records(&mut stream, 3);
        assert_eq!(records[0], server_hello([1; 32]));
        assert_eq!(records[1], record(0x17, &[0xAA; 90]));
        assert_eq!(records[2], record(0x17, &[0xBB; 40]));
        assert_eq!(wait_for(&received, 0, probe.len()), probe);
    }

    #[test]
    fn a_wrong_marker_is_forwarded_like_any_other_record() {
        let (site, received) = start_site();
        let (address, public) = start_relay(&site);
        // A marker made for another connection's ServerHello random.
        let (stale, _) = marker(&public, &[9; 32]);
        let mut stream = connect(address);
        stream.write_all(&handshake_prefix()).expect("write");
        read_records(&mut stream, 3);
        stream.write_all(&stale).expect("write");
        let sent = [handshake_prefix(), stale].concat();
        assert_eq!(wait_for(&received, 0, sent.len()), sent);
        // A marker for the right key but another relay's key.
        let (site2, received2) = start_site();
        let (address2, _) = start_relay(&site2);
        let (_, other_public) = key_pair_from_seed(&[8_u8; 32]);
        let (foreign, _) = marker(&other_public, &[1; 32]);
        let mut stream = connect(address2);
        stream.write_all(&handshake_prefix()).expect("write");
        read_records(&mut stream, 3);
        stream.write_all(&foreign).expect("write");
        let sent = [handshake_prefix(), foreign].concat();
        assert_eq!(wait_for(&received2, 0, sent.len()), sent);
    }

    #[test]
    fn a_client_with_the_key_gets_the_relay_through_the_borrowed_handshake() {
        let (site, received) = start_site();
        let (address, public) = start_relay(&site);
        let mut stream = connect(address);
        let prefix = handshake_prefix();
        stream.write_all(&prefix).expect("write");
        // The site's flight arrives untouched; the marker follows it, as a
        // client's Finished follows the server's.
        let flight = read_records(&mut stream, 3);
        assert_eq!(flight[0], server_hello([1; 32]));
        let (auth, key) = marker(&public, &[1; 32]);
        stream.write_all(&auth).expect("write");
        let ack_record = read_records(&mut stream, 1).remove(0);
        let tag = client_tag(&key, &[1; 32]);
        let ack = server_ack(&key, &[1; 32], &tag);
        assert_eq!(&ack_record[HEADER..HEADER + TAG], &ack);
        // A v1 health request through the tunnel, and its answer.
        let (c2s, s2c) = tunnel_keys(&key, &[1; 32]);
        let request = b"{\"action\":\"health\"}\n";
        stream
            .write_all(&seal_record(&c2s, 0, request))
            .expect("write");
        let answer = read_records(&mut stream, 1).remove(0);
        let line = open_record(&s2c, 0, &answer[HEADER..]).expect("the answer opens");
        let first = line.split(|byte| *byte == b'\n').next().unwrap();
        let health: serde_json::Value = serde_json::from_slice(first).expect("json");
        assert_eq!(health["ok"], true, "{health}");
        // The site saw the handshake it was sent, and nothing of the marker
        // or the tunnel.
        assert_eq!(wait_for(&received, 0, prefix.len()), prefix);
        std::thread::sleep(Duration::from_millis(200));
        assert_eq!(received.lock().unwrap()[0], prefix);
    }

    #[test]
    fn a_tunnel_record_that_does_not_open_ends_the_connection() {
        let (site, _) = start_site();
        let (address, public) = start_relay(&site);
        let mut stream = connect(address);
        stream.write_all(&handshake_prefix()).expect("write");
        read_records(&mut stream, 3);
        let (auth, key) = marker(&public, &[1; 32]);
        stream.write_all(&auth).expect("write");
        read_records(&mut stream, 1);
        let (c2s, _) = tunnel_keys(&key, &[1; 32]);
        let mut forged = seal_record(&c2s, 0, b"{\"action\":\"health\"}\n");
        let last = forged.len() - 1;
        forged[last] ^= 1;
        stream.write_all(&forged).expect("write");
        let mut chunk = [0_u8; 64];
        assert_eq!(stream.read(&mut chunk).unwrap_or(0), 0, "closed, no answer");
    }

    #[test]
    fn the_borrowed_address_is_told_when_a_public_host_is_set() {
        let identity = RelayIdentity::from_seed_bytes([7_u8; 32]);
        let mut config = parity_config();
        config.ext.borrow_bind = Some("0.0.0.0:443".to_owned());
        config.ext.borrow_site = Some("www.example.com:443".to_owned());
        let without_host = RelayState::new(config.clone(), identity.clone());
        assert!(without_host.borrowed_info().is_none());
        config.ext.public_host = Some("relay.example.org".to_owned());
        let state = RelayState::new(config.clone(), identity.clone());
        assert_eq!(
            state.borrowed_info().expect("info"),
            serde_json::json!({"host": "relay.example.org", "port": 443, "sni": "www.example.com"})
        );
        config.ext.borrow_sni = Some("cdn.example.com".to_owned());
        let named = RelayState::new(config, identity);
        assert_eq!(
            named.borrowed_info().expect("info")["sni"],
            "cdn.example.com"
        );
    }

    #[test]
    fn what_is_not_tls_is_forwarded_unparsed() {
        let (site, received) = start_site();
        let (address, _) = start_relay(&site);
        let mut stream = connect(address);
        let junk = b"GET / HTTP/1.1\r\nHost: x\r\n\r\n".to_vec();
        stream.write_all(&junk).expect("write");
        assert_eq!(wait_for(&received, 0, junk.len()), junk);
    }
}
