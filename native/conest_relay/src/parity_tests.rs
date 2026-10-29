//! v1 parity: the tokio server and the old threaded server give the same
//! answers to the same requests, budgets included (rate limits and soft
//! bans, store budgets, the storage cap, connection caps, the read
//! deadline, long-polls and UDP cookies).

use std::io::{BufRead, BufReader, Read, Write};
use std::net::{SocketAddr, TcpStream, UdpSocket};
use std::path::PathBuf;
use std::thread;
use std::time::{Duration, Instant};

use base64::Engine;
use base64::engine::general_purpose::STANDARD as BASE64_STANDARD;
use serde_json::{Value, json};

use crate::config::*;
use crate::identity::RelayIdentity;
use crate::storage::RelayState;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Mode {
    Legacy,
    Tokio,
}

pub(crate) fn parity_config() -> RelayConfig {
    RelayConfig {
        bind: "127.0.0.1:0".to_owned(),
        relay_id: "relay-parity".to_owned(),
        ttl: Duration::from_secs(DEFAULT_TTL_SECONDS),
        max_queue_per_mailbox: 16,
        max_fetch_limit: 8,
        max_envelope_bytes: DEFAULT_MAX_ENVELOPE_BYTES,
        max_line_bytes: DEFAULT_MAX_LINE_BYTES,
        max_requests_per_minute: DEFAULT_MAX_REQUESTS_PER_MINUTE,
        max_stores_per_minute: DEFAULT_MAX_STORES_PER_MINUTE,
        max_store_bytes_per_minute: DEFAULT_MAX_STORE_BYTES_PER_MINUTE,
        max_long_polls_per_peer: DEFAULT_MAX_LONG_POLLS_PER_PEER,
        max_connections_per_peer: DEFAULT_MAX_CONNECTIONS_PER_PEER,
        max_total_bytes: DEFAULT_MAX_TOTAL_BYTES,
        max_stored_bytes_per_peer: DEFAULT_MAX_STORED_BYTES_PER_PEER,
        max_rate_keys: DEFAULT_MAX_RATE_KEYS,
        trust_forwarded_for: false,
        identity_seed_path: PathBuf::from(""),
        identity_seed_inline: None,
        max_bytes_per_mailbox_per_minute: DEFAULT_MAX_BYTES_PER_MAILBOX_PER_MINUTE,
        soft_ban_threshold: DEFAULT_SOFT_BAN_THRESHOLD,
        soft_ban_duration: Duration::from_secs(DEFAULT_SOFT_BAN_SECONDS),
        max_connections: DEFAULT_MAX_CONNECTIONS,
        database_path: PathBuf::from(":memory:"),
        max_mailbox_bytes: DEFAULT_MAX_MAILBOX_BYTES,
        ext: ExtConfig::default(),
    }
}

pub(crate) struct Running {
    pub(crate) tcp: SocketAddr,
    pub(crate) udp: SocketAddr,
    #[allow(dead_code)]
    pub(crate) state: RelayState,
}

fn start(mode: Mode, config: RelayConfig) -> Running {
    let state = RelayState::new(config, RelayIdentity::from_seed_bytes([7_u8; 32]));
    let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind tcp");
    let tcp = listener.local_addr().expect("tcp address");
    let udp_socket = UdpSocket::bind("127.0.0.1:0").expect("bind udp");
    let udp = udp_socket.local_addr().expect("udp address");
    {
        let state = state.clone();
        let config = state.config.clone();
        thread::spawn(move || crate::legacy::serve_udp(udp_socket, state, config));
    }
    let serving = state.clone();
    match mode {
        Mode::Legacy => {
            thread::spawn(move || {
                let _ = crate::legacy::run(listener, serving);
            });
        }
        Mode::Tokio => {
            listener.set_nonblocking(true).expect("nonblocking");
            thread::spawn(move || {
                let runtime = tokio::runtime::Builder::new_multi_thread()
                    .worker_threads(2)
                    .enable_all()
                    .build()
                    .expect("runtime");
                runtime.block_on(async move {
                    let listener =
                        tokio::net::TcpListener::from_std(listener).expect("tokio listener");
                    let _ = crate::server::serve(listener, serving).await;
                });
            });
        }
    }
    Running { tcp, udp, state }
}

/// Starts a tokio relay for other tests (sessions, TLS).
#[allow(dead_code)]
pub(crate) fn start_tokio(config: RelayConfig) -> Running {
    start(Mode::Tokio, config)
}

fn connect(address: SocketAddr) -> TcpStream {
    let stream = TcpStream::connect(address).expect("connect");
    stream
        .set_read_timeout(Some(Duration::from_secs(10)))
        .expect("read timeout");
    stream
}

/// Sends [bytes] and reads one answer line ("<closed>" when the relay
/// closed without one).
fn exchange(address: SocketAddr, bytes: &[u8]) -> String {
    let mut stream = connect(address);
    if stream.write_all(bytes).is_err() {
        return "<closed>".to_owned();
    }
    let mut reader = BufReader::new(stream);
    let mut line = String::new();
    match reader.read_line(&mut line) {
        Ok(0) | Err(_) => "<closed>".to_owned(),
        Ok(_) => normalize(line.trim_end()),
    }
}

fn request(address: SocketAddr, value: Value) -> String {
    exchange(address, format!("{value}\n").as_bytes())
}

/// Sends a raw HTTP request and reads the whole answer.
fn http(address: SocketAddr, raw: &str) -> String {
    let mut stream = connect(address);
    if stream.write_all(raw.as_bytes()).is_err() {
        return "<closed>".to_owned();
    }
    let mut answer = String::new();
    let _ = stream.read_to_string(&mut answer);
    if answer.is_empty() {
        return "<closed>".to_owned();
    }
    match answer.split_once("\r\n\r\n") {
        Some((head, body)) => format!("{}|{}", head, normalize(body)),
        None => answer,
    }
}

/// Lease ids are random: replaced by a marker.
fn normalize(text: &str) -> String {
    let Ok(mut value) = serde_json::from_str::<Value>(text) else {
        return text.to_owned();
    };
    if value.get("lease_id").and_then(Value::as_str).is_some() {
        value["lease_id"] = json!("<lease>");
    }
    value.to_string()
}

fn envelope(id: &str) -> Value {
    json!({
        "kind": "direct_message",
        "messageId": id,
        "conversationId": "conv",
        "senderAccountId": "acc-a",
        "senderDeviceId": "dev-a",
        "recipientDeviceId": "dev-b",
        "createdAt": "2026-04-16T00:00:00.000Z",
        "payloadBase64": "aGVsbG8="
    })
}

fn store(mailbox: &str, id: &str) -> Value {
    json!({"action": "store", "recipient_device_id": mailbox, "envelope": envelope(id)})
}

/// The basic exchange: v1 lines and HTTP, answers compared.
fn basic(mode: Mode) -> Vec<String> {
    let relay = start(mode, parity_config());
    let address = relay.tcp;
    let mut answers = Vec::new();
    answers.push(request(address, store("dev-b", "m1")));
    answers.push(request(address, store("dev-b", "m2")));
    answers.push(request(address, store("dev-b", "m2")));
    answers.push(request(
        address,
        json!({"action": "fetch", "recipient_device_id": "dev-b", "limit": 1}),
    ));
    let leased = {
        let mut stream = connect(address);
        stream
            .write_all(
                format!(
                    "{}\n",
                    json!({"action": "fetch_leased", "recipient_device_id": "dev-b", "limit": 4})
                )
                .as_bytes(),
            )
            .expect("write");
        let mut line = String::new();
        BufReader::new(stream).read_line(&mut line).expect("read");
        line
    };
    let lease_id = serde_json::from_str::<Value>(&leased).expect("json")["lease_id"]
        .as_str()
        .expect("a lease")
        .to_owned();
    answers.push(normalize(leased.trim_end()));
    answers.push(request(
        address,
        json!({"action": "ack_lease", "recipient_device_id": "dev-b", "lease_id": lease_id}),
    ));
    answers.push(request(
        address,
        json!({"action": "fetch", "recipient_device_id": "dev-b"}),
    ));
    // Signed, both ways.
    let nonce = BASE64_STANDARD.encode([3_u8; 16]);
    answers.push(request(
        address,
        json!({"action": "health", "nonce": nonce, "sig_mode": "detached"}),
    ));
    answers.push(request(
        address,
        json!({"action": "health", "nonce": nonce}),
    ));
    answers.push(request(address, json!({"action": "health"})));
    // Refusals.
    answers.push(request(address, json!({"action": "nope"})));
    answers.push(exchange(address, b"not json\n"));
    answers.push(exchange(address, b"{\"action\":\xff}\n"));
    answers.push(request(
        address,
        json!({"action": "fetch", "recipient_device_id": "../bad"}),
    ));
    let oversized = format!(
        "{{\"pad\":\"{}\"}}\n",
        "x".repeat(DEFAULT_MAX_LINE_BYTES + 10)
    );
    answers.push(exchange(address, oversized.as_bytes()));
    // A line without its newline, then the end of the stream.
    {
        let mut stream = connect(address);
        stream
            .write_all(json!({"action": "health"}).to_string().as_bytes())
            .expect("write");
        stream
            .shutdown(std::net::Shutdown::Write)
            .expect("shutdown");
        let mut line = String::new();
        let _ = BufReader::new(stream).read_line(&mut line);
        answers.push(normalize(line.trim_end()));
    }
    // HTTP.
    let body = store("dev-c", "h1").to_string();
    answers.push(http(
        address,
        &format!(
            "POST /relay HTTP/1.1\r\nHost: relay.test\r\nContent-Length: {}\r\n\r\n{}",
            body.len(),
            body
        ),
    ));
    let body = json!({"action": "fetch", "recipient_device_id": "dev-c"}).to_string();
    answers.push(http(
        address,
        &format!(
            "POST / HTTP/1.1\r\nHost: relay.test\r\nContent-Length: {}\r\n\r\n{}",
            body.len(),
            body
        ),
    ));
    answers.push(http(
        address,
        "GET /health HTTP/1.1\r\nHost: relay.test\r\n\r\n",
    ));
    answers.push(http(
        address,
        "OPTIONS / HTTP/1.1\r\nHost: relay.test\r\n\r\n",
    ));
    answers.push(http(
        address,
        "GET /nope HTTP/1.1\r\nHost: relay.test\r\n\r\n",
    ));
    answers.push(http(address, "POST / HTTP/1.1\r\nHost: relay.test\r\n\r\n"));
    answers.push(http(
        address,
        "POST / HTTP/1.1\r\nHost: relay.test\r\nContent-Length: 5\r\nContent-Length: 6\r\n\r\nhello",
    ));
    answers.push(http(
        address,
        &format!(
            "POST / HTTP/1.1\r\nHost: relay.test\r\nContent-Length: {}\r\n\r\n",
            DEFAULT_MAX_LINE_BYTES + 1
        ),
    ));
    answers.push(http(address, "PUT / HTTP/1.1\r\n\r\n"));
    answers
}

#[test]
fn both_servers_answer_v1_and_http_alike() {
    let legacy = basic(Mode::Legacy);
    let tokio = basic(Mode::Tokio);
    assert_eq!(legacy.len(), tokio.len());
    for (index, (old, new)) in legacy.iter().zip(&tokio).enumerate() {
        assert_eq!(old, new, "answer {index} differs");
    }
    // The exchange meant something.
    assert!(legacy[0].contains("\"stored\":true"), "{}", legacy[0]);
    assert!(legacy[3].contains("m1"), "{}", legacy[3]);
    assert!(legacy.iter().any(|answer| answer.contains("\"sig_v\":2")));
    assert!(
        legacy
            .iter()
            .any(|answer| answer.contains("unknown HTTP relay path"))
    );
    assert!(legacy.iter().any(|answer| answer == "<closed>"));
}

/// The general budget and the soft ban, over the wire.
fn rate_limits(mode: Mode) -> Vec<String> {
    let mut config = parity_config();
    config.max_requests_per_minute = 3;
    config.soft_ban_threshold = 2;
    config.soft_ban_duration = Duration::from_secs(60);
    let relay = start(mode, config);
    let mut answers = Vec::new();
    for _ in 0..7 {
        answers.push(request(relay.tcp, json!({"action": "health"})));
    }
    answers.push(http(relay.tcp, "GET /health HTTP/1.1\r\n\r\n"));
    answers
}

#[test]
fn both_servers_rate_limit_and_ban_alike() {
    let legacy = rate_limits(Mode::Legacy);
    let tokio = rate_limits(Mode::Tokio);
    assert_eq!(legacy, tokio);
    assert!(legacy[3].contains("rate limit exceeded"), "{}", legacy[3]);
    assert!(legacy[7].starts_with("HTTP/1.1 429"), "{}", legacy[7]);
}

/// Stores have their own budget, and what one address holds is bounded,
/// and a full relay makes room from its largest holder.
fn store_budgets(mode: Mode) -> Vec<String> {
    let mut config = parity_config();
    config.max_stores_per_minute = 3;
    let line = format!("{}\n", store("dev-x", "s0"));
    config.max_total_bytes = line.len() as u64 * 2;
    let relay = start(mode, config);
    let mut answers = Vec::new();
    for index in 0..4 {
        answers.push(request(relay.tcp, store("dev-x", &format!("s{index}"))));
    }
    answers.push(request(
        relay.tcp,
        json!({"action": "fetch", "recipient_device_id": "dev-x"}),
    ));
    answers
}

#[test]
fn both_servers_keep_store_budgets_alike() {
    let legacy = store_budgets(Mode::Legacy);
    let tokio = store_budgets(Mode::Tokio);
    assert_eq!(legacy, tokio);
    assert!(legacy[3].contains("rate limit exceeded"), "{}", legacy[3]);
    // Room for two: the oldest went.
    assert!(!legacy[4].contains("\"s0\""), "{}", legacy[4]);
    assert!(legacy[4].contains("\"s2\""), "{}", legacy[4]);
}

/// Connections one address may hold, the read deadline, and the
/// relay-wide cap.
fn connection_caps(mode: Mode) -> Vec<String> {
    let mut config = parity_config();
    config.max_connections_per_peer = 2;
    config.ext.read_deadline = Duration::from_millis(800);
    let relay = start(mode, config);
    let mut answers = Vec::new();
    let idle_a = connect(relay.tcp);
    let idle_b = connect(relay.tcp);
    thread::sleep(Duration::from_millis(100));
    answers.push(request(relay.tcp, json!({"action": "health"})));
    // The read deadline ends the idle ones without an answer.
    let started = Instant::now();
    let mut first = String::new();
    let _ = BufReader::new(idle_a).read_line(&mut first);
    answers.push(format!("idle:{first}"));
    assert!(started.elapsed() < Duration::from_secs(5));
    drop(idle_b);
    thread::sleep(Duration::from_millis(200));
    answers.push(request(relay.tcp, json!({"action": "health"})));

    let mut config = parity_config();
    config.max_connections = 1;
    config.ext.read_deadline = Duration::from_millis(800);
    let relay = start(mode, config);
    let idle = connect(relay.tcp);
    thread::sleep(Duration::from_millis(100));
    answers.push(request(relay.tcp, json!({"action": "health"})));
    drop(idle);
    answers
}

#[test]
fn both_servers_cap_connections_and_deadlines_alike() {
    let legacy = connection_caps(Mode::Legacy);
    let tokio = connection_caps(Mode::Tokio);
    assert_eq!(legacy, tokio);
    assert!(legacy[0].contains("too many connections"), "{}", legacy[0]);
    assert_eq!(legacy[1], "idle:");
    assert!(legacy[2].contains("\"ok\":true"), "{}", legacy[2]);
    assert!(legacy[3].contains("relay at capacity"), "{}", legacy[3]);
}

/// A waiting fetch wakes on a store; past an address's share of waiting
/// fetches, one is answered at once.
fn long_polls(mode: Mode) -> Vec<String> {
    let mut config = parity_config();
    config.max_long_polls_per_peer = 1;
    let relay = start(mode, config);
    let address = relay.tcp;
    let waiting = thread::spawn(move || {
        let started = Instant::now();
        let answer = request(
            address,
            json!({"action": "fetch", "recipient_device_id": "dev-w", "wait_ms": 5000}),
        );
        (answer, started.elapsed())
    });
    thread::sleep(Duration::from_millis(300));
    let started = Instant::now();
    let second = request(
        address,
        json!({"action": "fetch", "recipient_device_id": "dev-v", "wait_ms": 5000}),
    );
    let second_took = started.elapsed();
    let stored = request(address, store("dev-w", "late"));
    let (answer, took) = waiting.join().expect("waiting fetch");
    assert!(
        took < Duration::from_secs(3),
        "{mode:?}: woke after {took:?}"
    );
    assert!(
        second_took < Duration::from_secs(2),
        "{mode:?}: second waited {second_took:?}"
    );
    vec![answer, second, stored]
}

#[test]
fn both_servers_long_poll_alike() {
    let legacy = long_polls(Mode::Legacy);
    let tokio = long_polls(Mode::Tokio);
    assert_eq!(legacy, tokio);
    assert!(legacy[0].contains("late"), "{}", legacy[0]);
}

/// UDP: one thread in both modes; its cookie rules hold.
#[test]
fn udp_cookies_hold_in_both_modes() {
    for mode in [Mode::Legacy, Mode::Tokio] {
        let relay = start(mode, parity_config());
        let socket = UdpSocket::bind("127.0.0.1:0").expect("bind");
        socket
            .set_read_timeout(Some(Duration::from_millis(500)))
            .expect("timeout");
        let mut buffer = vec![0_u8; 65_536];
        // Too short to earn a cookie: nothing back.
        socket
            .send_to(br#"{"action":"health"}"#, relay.udp)
            .expect("send");
        assert!(socket.recv_from(&mut buffer).is_err(), "{mode:?}");
        let padded = json!({"action": "health", "pad": "x".repeat(UDP_COOKIE_REQUEST_MIN_BYTES)});
        socket
            .send_to(padded.to_string().as_bytes(), relay.udp)
            .expect("send");
        let (read, _) = socket.recv_from(&mut buffer).expect("cookie answer");
        let answer: Value = serde_json::from_slice(&buffer[..read]).expect("json");
        assert_eq!(answer["error"], "udp cookie required", "{mode:?}");
        let cookie = answer["cookie"].as_str().expect("cookie").to_owned();
        socket
            .send_to(
                json!({"action": "health", "cookie": cookie})
                    .to_string()
                    .as_bytes(),
                relay.udp,
            )
            .expect("send");
        let (read, _) = socket.recv_from(&mut buffer).expect("answer");
        let answer: Value = serde_json::from_slice(&buffer[..read]).expect("json");
        assert_eq!(answer["ok"], true, "{mode:?}");
    }
}
