//! The relay behind the operator's web server (M38 S3).
//!
//! nginx or Caddy owns port 443 (the real certificate, HTTP/2, the real
//! site) and proxies only the secret path, with its WebSocket upgrade, to
//! this plain listener on loopback. So what a prober meets on 443 is a real
//! web server's TLS stack, not the relay's. What differs from the TLS layer
//! in `outer.rs`:
//! - clients all arrive from the front's one address, so the per-address
//!   connection slot is taken after the upgrade request names the client
//!   (its last `X-Forwarded-For` entry, believed only from a loopback peer
//!   and only when it is an IP address), not at accept; a request that
//!   names no client shares one key ([FRONT_KEY]) and its slots;
//! - anything that is not a valid upgrade on the secret path gets an empty
//!   404, which the front is told (RELAY.md) to turn into the site's own
//!   404, so a prober behind it never sees a 502;
//! - there is no decoy here: the front is the decoy.
//!
//! The listener is loopback-only unless the operator says `--ws-bind-public`
//! (see `config::validate_ws_bind`). It carries only the relay's own
//! protocols, so it is no proxy.

use std::net::IpAddr;
use std::sync::Arc;
use std::time::Duration;

use tokio::io::{AsyncWriteExt, DuplexStream};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::Semaphore;
use tokio::time::{Instant, timeout_at};

use crate::limits::{PeerSlot, peer_key};
use crate::outer::{Head, parse_head, read_head, websocket_accept, websocket_bridge};
use crate::storage::RelayState;

/// The key clients are counted under when the front does not name them.
pub(crate) const FRONT_KEY: &str = "front";

/// What anything invalid on the secret path gets.
const NOT_FOUND: &[u8] =
    b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";

/// The key a request is counted under: the client address the front named
/// (the last entry of the last `X-Forwarded-For` header, when it is an IP
/// address) if the connection came from this host, else the connection's
/// own address.
pub(crate) fn client_key(tcp_peer: IpAddr, head: &Head) -> String {
    if !tcp_peer.is_loopback() {
        return peer_key(tcp_peer);
    }
    head.headers
        .iter()
        .rev()
        .find(|(name, _)| name.eq_ignore_ascii_case("x-forwarded-for"))
        .and_then(|(_, value)| value.split(',').next_back())
        .and_then(|last| last.trim().parse::<IpAddr>().ok())
        .map(peer_key)
        .unwrap_or_else(|| FRONT_KEY.to_owned())
}

/// The `Sec-WebSocket-Key` of a valid upgrade on [path], if [head] is one.
fn upgrade_key(head: &Head, path: &str) -> Option<String> {
    let upgrade = head
        .header("upgrade")
        .is_some_and(|value| value.eq_ignore_ascii_case("websocket"));
    let version = head.header("sec-websocket-version") == Some("13");
    let key = head.header("sec-websocket-key")?;
    (head.method == "GET" && head.path == path && upgrade && version && key.len() <= 64)
        .then(|| key.to_owned())
}

/// The relay's byte stream for one connection from the front, the key it is
/// counted under, and its slot; none when it was not a valid upgrade (the
/// front's request was answered or dropped here).
async fn open_front(
    mut stream: TcpStream,
    tcp_peer: IpAddr,
    state: &RelayState,
    path: &str,
) -> Option<(DuplexStream, String, PeerSlot)> {
    let until = Instant::now() + state.config.ext.read_deadline;
    let (end, read) = read_head(&mut stream, until).await;
    let end = end?;
    // Not HTTP at all: closed without a word.
    let head = parse_head(&read[..end])?;
    let Some(key) = upgrade_key(&head, path) else {
        let _ = timeout_at(until, stream.write_all(NOT_FOUND)).await;
        return None;
    };
    let peer = client_key(tcp_peer, &head);
    // Past the cap the connection is closed, as everywhere else.
    let slot = state.connection_slot(&peer)?;
    let reply = format!(
        "HTTP/1.1 101 Switching Protocols\r\n\
         Upgrade: websocket\r\n\
         Connection: Upgrade\r\n\
         Sec-WebSocket-Accept: {}\r\n\r\n",
        websocket_accept(&key)
    );
    timeout_at(until, stream.write_all(reply.as_bytes()))
        .await
        .ok()?
        .ok()?;
    let initial = read[end..].to_vec();
    Some((websocket_bridge(stream, initial), peer, slot))
}

/// Serves [listener] (the front's connections) until it fails: the relay-wide
/// connection cap at accept, the per-address slot once the client is named.
pub(crate) async fn serve_front(
    listener: TcpListener,
    state: RelayState,
    path: String,
) -> std::io::Result<()> {
    let permits = Arc::new(Semaphore::new(state.config.max_connections));
    loop {
        let (stream, address) = match listener.accept().await {
            Ok(accepted) => accepted,
            Err(error) => {
                eprintln!("relay accept error: {error}");
                tokio::time::sleep(Duration::from_millis(20)).await;
                continue;
            }
        };
        let _ = stream.set_nodelay(true);
        let Ok(permit) = Arc::clone(&permits).try_acquire_owned() else {
            continue;
        };
        // What came through the front was written by the client itself: its
        // X-Forwarded-For is believed only here, to name it, never by the
        // relay's own limits.
        let mut state = state.clone();
        state.config.trust_forwarded_for = false;
        let path = path.clone();
        tokio::spawn(async move {
            let _permit = permit;
            let Some((inner, peer, slot)) = open_front(stream, address.ip(), &state, &path).await
            else {
                return;
            };
            let _slot = slot;
            if let Err(error) = crate::server::handle_connection(inner, state, peer).await {
                eprintln!("relay connection error: {error}");
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::parity_tests::parity_config;
    use std::io::{Read, Write};
    use std::net::SocketAddr;

    const SECRET: &str = "/s3cret-path-for-tests";

    fn start_front() -> (SocketAddr, RelayState) {
        let state = RelayState::new(
            parity_config(),
            crate::identity::RelayIdentity::from_seed_bytes([7_u8; 32]),
        );
        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind");
        let address = listener.local_addr().expect("address");
        listener.set_nonblocking(true).expect("nonblocking");
        let serving = state.clone();
        std::thread::spawn(move || {
            let runtime = tokio::runtime::Builder::new_multi_thread()
                .worker_threads(2)
                .enable_all()
                .build()
                .expect("runtime");
            runtime.block_on(async move {
                let listener = TcpListener::from_std(listener).expect("listener");
                let _ = serve_front(listener, serving, SECRET.to_owned()).await;
            });
        });
        (address, state)
    }

    fn connect(address: SocketAddr) -> std::net::TcpStream {
        let stream = std::net::TcpStream::connect(address).expect("connect");
        stream
            .set_read_timeout(Some(Duration::from_secs(5)))
            .expect("timeout");
        stream
    }

    fn upgrade_request(forwarded: Option<&str>) -> String {
        let mut request = format!(
            "GET {SECRET} HTTP/1.1\r\nHost: relay.example.org\r\nUpgrade: websocket\r\nConnection: upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n"
        );
        if let Some(value) = forwarded {
            request.push_str(&format!("X-Forwarded-For: {value}\r\n"));
        }
        request.push_str("\r\n");
        request
    }

    /// The answer's head, up to its blank line (what is there, if the
    /// connection ends first).
    fn read_reply(stream: &mut std::net::TcpStream) -> String {
        let mut head = Vec::new();
        let mut byte = [0_u8; 1];
        while !head.ends_with(b"\r\n\r\n") {
            match stream.read(&mut byte) {
                Ok(1) => head.push(byte[0]),
                _ => break,
            }
        }
        String::from_utf8_lossy(&head).into_owned()
    }

    fn masked(opcode: u8, payload: &[u8]) -> Vec<u8> {
        let mask = [0x11_u8, 0x22, 0x33, 0x44];
        let mut out = vec![0x80 | opcode, 0x80 | payload.len() as u8];
        out.extend_from_slice(&mask);
        out.extend(
            payload
                .iter()
                .enumerate()
                .map(|(index, byte)| byte ^ mask[index % 4]),
        );
        out
    }

    fn head_of(text: &str) -> Head {
        parse_head(text.as_bytes()).expect("a request head")
    }

    #[test]
    fn the_secret_path_carries_relay_requests_over_a_plain_websocket() {
        let (address, state) = start_front();
        let mut stream = connect(address);
        stream
            .write_all(upgrade_request(Some("198.51.100.8")).as_bytes())
            .expect("upgrade");
        let head = read_reply(&mut stream);
        assert!(head.starts_with("HTTP/1.1 101"), "{head}");
        // RFC 6455's example key and answer.
        assert!(head.contains("s3pPLMBiTxaQ9kYGzzhZRbK+xOo="), "{head}");
        // The client the front named is who is counted, not the front.
        assert!(
            state
                .connections
                .lock()
                .unwrap()
                .contains_key("198.51.100.8")
        );
        assert!(!state.connections.lock().unwrap().contains_key("127.0.0.1"));
        // A v1 line over binary frames, and its answer.
        stream
            .write_all(&masked(0x2, b"{\"action\":\"health\"}\n"))
            .expect("frame");
        let mut answer = Vec::new();
        while !answer.ends_with(b"\n") {
            let mut header = [0_u8; 2];
            stream.read_exact(&mut header).expect("frame header");
            assert_eq!(header[0] & 0x0f, 0x2, "binary frames");
            let length = match header[1] & 0x7f {
                126 => {
                    let mut bytes = [0_u8; 2];
                    stream.read_exact(&mut bytes).expect("length");
                    u16::from_be_bytes(bytes) as usize
                }
                length => length as usize,
            };
            let mut payload = vec![0_u8; length];
            stream.read_exact(&mut payload).expect("payload");
            answer.extend_from_slice(&payload);
        }
        let answer: serde_json::Value = serde_json::from_slice(&answer).expect("json");
        assert_eq!(answer["ok"], true, "{answer}");
    }

    #[test]
    fn clients_through_one_front_are_not_counted_as_one_peer() {
        let (address, state) = start_front();
        // More clients than one address may hold at once (16 by default),
        // each named by the front, all connected together.
        let mut open = Vec::new();
        for index in 1..=20 {
            let mut stream = connect(address);
            stream
                .write_all(upgrade_request(Some(&format!("198.51.100.{index}"))).as_bytes())
                .expect("upgrade");
            let head = read_reply(&mut stream);
            assert!(
                head.starts_with("HTTP/1.1 101"),
                "client {index} was refused: {head:?}"
            );
            open.push(stream);
        }
        assert_eq!(state.connections.lock().unwrap().len(), 20);
    }

    #[test]
    fn a_request_that_names_no_client_shares_the_fronts_slots() {
        let (address, _) = start_front();
        let mut open = Vec::new();
        // No header, and a header that is no address: both are the front's.
        for index in 0..16 {
            let forwarded = if index % 2 == 0 {
                None
            } else {
                Some("not-an-ip")
            };
            let mut stream = connect(address);
            stream
                .write_all(upgrade_request(forwarded).as_bytes())
                .expect("upgrade");
            let head = read_reply(&mut stream);
            assert!(head.starts_with("HTTP/1.1 101"), "{index}: {head:?}");
            open.push(stream);
        }
        let mut seventeenth = connect(address);
        seventeenth
            .write_all(upgrade_request(None).as_bytes())
            .expect("upgrade");
        let head = read_reply(&mut seventeenth);
        assert!(
            !head.starts_with("HTTP/1.1 101"),
            "the front's slots are shared and used up: {head:?}"
        );
    }

    #[test]
    fn anything_else_on_the_secret_path_is_an_empty_404() {
        let (address, _) = start_front();
        let long_key = "a".repeat(65);
        for request in [
            // No upgrade.
            format!("GET {SECRET} HTTP/1.1\r\nHost: x\r\n\r\n"),
            // The wrong path.
            "GET /nope HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nSec-WebSocket-Key: abc\r\nSec-WebSocket-Version: 13\r\n\r\n"
                .to_owned(),
            // The wrong version.
            format!(
                "GET {SECRET} HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nSec-WebSocket-Key: abc\r\nSec-WebSocket-Version: 12\r\n\r\n"
            ),
            // A key too long to be one.
            format!(
                "GET {SECRET} HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nSec-WebSocket-Key: {long_key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
            ),
            // No key.
            format!(
                "GET {SECRET} HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nSec-WebSocket-Version: 13\r\n\r\n"
            ),
            // The wrong method.
            format!(
                "POST {SECRET} HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nSec-WebSocket-Key: abc\r\nSec-WebSocket-Version: 13\r\nContent-Length: 0\r\n\r\n"
            ),
        ] {
            let mut stream = connect(address);
            stream.write_all(request.as_bytes()).expect("send");
            let mut answer = Vec::new();
            let _ = stream.read_to_end(&mut answer);
            // The literal bytes, not the constant: what a prober behind the
            // front is shown is an empty 404 and nothing else.
            assert_eq!(
                answer,
                b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                "{request:?}"
            );
        }
        // Not HTTP at all: closed without a word.
        let mut stream = connect(address);
        stream.write_all(b"CNS2\x01\r\n\r\n").expect("send");
        let mut answer = Vec::new();
        let _ = stream.read_to_end(&mut answer);
        assert!(answer.is_empty(), "{answer:?}");
    }

    #[test]
    fn a_named_client_is_believed_from_this_host_only_and_only_as_an_address() {
        let loopback: IpAddr = "127.0.0.1".parse().unwrap();
        let elsewhere: IpAddr = "203.0.113.5".parse().unwrap();
        let named = |value: &str| {
            head_of(&format!(
                "GET / HTTP/1.1\r\nHost: x\r\nX-Forwarded-For: {value}\r\n\r\n"
            ))
        };
        assert_eq!(client_key(loopback, &named("198.51.100.8")), "198.51.100.8");
        // Several entries: the last is the one the front saw.
        assert_eq!(
            client_key(loopback, &named("1.2.3.4, 198.51.100.9")),
            "198.51.100.9"
        );
        // IPv6 is counted by its /64, as everywhere.
        assert_eq!(
            client_key(loopback, &named("2001:db8:1:2:3:4:5:6")),
            "2001:db8:1:2::/64"
        );
        // Not an address, or a name with a port: the front's shared key.
        assert_eq!(client_key(loopback, &named("not-an-ip")), FRONT_KEY);
        assert_eq!(client_key(loopback, &named("198.51.100.8:4000")), FRONT_KEY);
        let none = head_of("GET / HTTP/1.1\r\nHost: x\r\n\r\n");
        assert_eq!(client_key(loopback, &none), FRONT_KEY);
        // A peer that is not this host cannot name anyone but itself.
        assert_eq!(client_key(elsewhere, &named("198.51.100.8")), "203.0.113.5");
        // Two headers: the last header's last entry.
        let two = head_of(
            "GET / HTTP/1.1\r\nHost: x\r\nX-Forwarded-For: 1.1.1.1\r\nx-forwarded-for: 198.51.100.7\r\n\r\n",
        );
        assert_eq!(client_key(loopback, &two), "198.51.100.7");
    }
}
