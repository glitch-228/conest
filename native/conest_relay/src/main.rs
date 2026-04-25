use std::collections::{HashMap, VecDeque};
use std::env;
use std::io::{BufRead, BufReader, BufWriter, Write};
use std::net::{SocketAddr, TcpListener, UdpSocket};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use serde_json::Value;

const DEFAULT_BIND: &str = "0.0.0.0:7667";
const DEFAULT_TTL_SECONDS: u64 = 7 * 24 * 60 * 60;
const DEFAULT_MAX_QUEUE_PER_MAILBOX: usize = 512;
const DEFAULT_MAX_FETCH_LIMIT: usize = 128;
const DEFAULT_MAX_ENVELOPE_BYTES: usize = 256 * 1024;
const DEFAULT_MAX_LINE_BYTES: usize = 300 * 1024;
const DEFAULT_MAX_REQUESTS_PER_MINUTE: u32 = 240;

#[derive(Debug, Clone)]
struct RelayConfig {
    bind: String,
    relay_id: String,
    ttl: Duration,
    max_queue_per_mailbox: usize,
    max_fetch_limit: usize,
    max_envelope_bytes: usize,
    max_line_bytes: usize,
    max_requests_per_minute: u32,
}

impl RelayConfig {
    fn from_env_and_args() -> Result<Self, String> {
        let mut config = Self {
            bind: env::var("CONEST_RELAY_BIND").unwrap_or_else(|_| DEFAULT_BIND.to_owned()),
            relay_id: env::var("CONEST_RELAY_ID").unwrap_or_else(|_| default_relay_id()),
            ttl: Duration::from_secs(env_u64("CONEST_RELAY_TTL_SECONDS", DEFAULT_TTL_SECONDS)),
            max_queue_per_mailbox: env_usize(
                "CONEST_RELAY_MAX_QUEUE_PER_MAILBOX",
                DEFAULT_MAX_QUEUE_PER_MAILBOX,
            ),
            max_fetch_limit: env_usize("CONEST_RELAY_MAX_FETCH_LIMIT", DEFAULT_MAX_FETCH_LIMIT),
            max_envelope_bytes: env_usize(
                "CONEST_RELAY_MAX_ENVELOPE_BYTES",
                DEFAULT_MAX_ENVELOPE_BYTES,
            ),
            max_line_bytes: env_usize("CONEST_RELAY_MAX_LINE_BYTES", DEFAULT_MAX_LINE_BYTES),
            max_requests_per_minute: env_u32(
                "CONEST_RELAY_MAX_REQUESTS_PER_MINUTE",
                DEFAULT_MAX_REQUESTS_PER_MINUTE,
            ),
        };

        let mut args = env::args().skip(1).peekable();
        while let Some(arg) = args.next() {
            match arg.as_str() {
                "--help" | "-h" => return Err(usage()),
                "--ttl-seconds" => {
                    config.ttl = Duration::from_secs(parse_next_u64(&mut args, &arg)?);
                }
                "--relay-id" => {
                    config.relay_id = parse_next_string(&mut args, &arg)?;
                }
                "--max-queue-per-mailbox" => {
                    config.max_queue_per_mailbox = parse_next_usize(&mut args, &arg)?;
                }
                "--max-fetch-limit" => {
                    config.max_fetch_limit = parse_next_usize(&mut args, &arg)?;
                }
                "--max-envelope-bytes" => {
                    config.max_envelope_bytes = parse_next_usize(&mut args, &arg)?;
                }
                "--max-line-bytes" => {
                    config.max_line_bytes = parse_next_usize(&mut args, &arg)?;
                }
                "--max-requests-per-minute" => {
                    config.max_requests_per_minute = parse_next_u32(&mut args, &arg)?;
                }
                value if value.starts_with('-') => {
                    return Err(format!("unknown option: {value}\n\n{}", usage()));
                }
                bind => config.bind = bind.to_owned(),
            }
        }

        if config.max_fetch_limit == 0 {
            return Err("max fetch limit must be greater than zero".to_owned());
        }
        if config.max_queue_per_mailbox == 0 {
            return Err("max queue per mailbox must be greater than zero".to_owned());
        }
        if config.max_envelope_bytes == 0 || config.max_line_bytes < config.max_envelope_bytes {
            return Err("max line bytes must be at least max envelope bytes".to_owned());
        }
        if config.max_requests_per_minute == 0 {
            return Err("max requests per minute must be greater than zero".to_owned());
        }
        if config.relay_id.trim().is_empty() {
            return Err("relay id must not be empty".to_owned());
        }
        Ok(config)
    }
}

#[derive(Debug, Deserialize)]
#[serde(tag = "action", rename_all = "snake_case")]
enum RelayRequest {
    Store {
        recipient_device_id: String,
        envelope: Value,
    },
    Fetch {
        recipient_device_id: String,
        limit: Option<usize>,
    },
    Health,
}

#[derive(Debug, Serialize)]
struct RelayStats {
    relay_id: String,
    queue_count: usize,
    queued_envelope_count: usize,
    ttl_seconds: u64,
    max_queue_per_mailbox: usize,
    max_fetch_limit: usize,
}

#[derive(Debug, Serialize)]
struct RelayResponse {
    ok: bool,
    stored: bool,
    messages: Vec<Value>,
    error: Option<String>,
    stats: Option<RelayStats>,
}

impl RelayResponse {
    fn ok(stats: Option<RelayStats>) -> Self {
        Self {
            ok: true,
            stored: false,
            messages: Vec::new(),
            error: None,
            stats,
        }
    }

    fn stored() -> Self {
        Self {
            ok: true,
            stored: true,
            messages: Vec::new(),
            error: None,
            stats: None,
        }
    }

    fn messages(messages: Vec<Value>) -> Self {
        Self {
            ok: true,
            stored: false,
            messages,
            error: None,
            stats: None,
        }
    }

    fn error(message: impl Into<String>) -> Self {
        Self {
            ok: false,
            stored: false,
            messages: Vec::new(),
            error: Some(message.into()),
            stats: None,
        }
    }
}

#[derive(Clone)]
struct QueueEntry {
    queued_at_millis: u64,
    envelope: Value,
}

#[derive(Clone)]
struct RateBucket {
    window_started_millis: u64,
    count: u32,
}

#[derive(Clone)]
struct RelayState {
    config: RelayConfig,
    queues: Arc<Mutex<HashMap<String, VecDeque<QueueEntry>>>>,
    rate_buckets: Arc<Mutex<HashMap<String, RateBucket>>>,
}

impl RelayState {
    fn new(config: RelayConfig) -> Self {
        Self {
            config,
            queues: Arc::new(Mutex::new(HashMap::new())),
            rate_buckets: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    fn allow_request(&self, peer: &str) -> bool {
        let now = now_millis();
        let mut buckets = self
            .rate_buckets
            .lock()
            .expect("rate bucket lock should not poison");
        buckets.retain(|_, bucket| now.saturating_sub(bucket.window_started_millis) < 120_000);
        let bucket = buckets.entry(peer.to_owned()).or_insert(RateBucket {
            window_started_millis: now,
            count: 0,
        });
        if now.saturating_sub(bucket.window_started_millis) >= 60_000 {
            bucket.window_started_millis = now;
            bucket.count = 0;
        }
        if bucket.count >= self.config.max_requests_per_minute {
            return false;
        }
        bucket.count += 1;
        true
    }

    fn store(&self, recipient_device_id: String, envelope: Value) -> Result<(), String> {
        validate_mailbox_id(&recipient_device_id)?;
        let envelope_bytes = serde_json::to_vec(&envelope).map_err(|error| error.to_string())?;
        if envelope_bytes.len() > self.config.max_envelope_bytes {
            return Err(format!(
                "envelope too large: {} bytes > {}",
                envelope_bytes.len(),
                self.config.max_envelope_bytes
            ));
        }

        let mut queues = self
            .queues
            .lock()
            .expect("relay queue lock should not poison");
        self.cleanup_locked(&mut queues);
        let queue = queues.entry(recipient_device_id).or_default();

        if envelope_kind(&envelope) == Some("pairing_announcement")
            && let Some(sender) = envelope_sender_device_id(&envelope)
        {
            queue.retain(|entry| {
                envelope_kind(&entry.envelope) != Some("pairing_announcement")
                    || envelope_sender_device_id(&entry.envelope) != Some(sender)
            });
        }

        while queue.len() >= self.config.max_queue_per_mailbox {
            if let Some(index) = queue
                .iter()
                .position(|entry| envelope_kind(&entry.envelope) != Some("pairing_announcement"))
            {
                queue.remove(index);
            } else {
                queue.pop_front();
            }
        }

        queue.push_back(QueueEntry {
            queued_at_millis: now_millis(),
            envelope,
        });
        Ok(())
    }

    fn fetch(&self, recipient_device_id: &str, limit: Option<usize>) -> Result<Vec<Value>, String> {
        validate_mailbox_id(recipient_device_id)?;
        let limit = limit
            .unwrap_or(self.config.max_fetch_limit)
            .clamp(1, self.config.max_fetch_limit);
        let mut queues = self
            .queues
            .lock()
            .expect("relay queue lock should not poison");
        self.cleanup_locked(&mut queues);
        let queue = queues.entry(recipient_device_id.to_owned()).or_default();
        let entries: Vec<QueueEntry> = queue.drain(..).collect();
        let mut messages = Vec::new();

        for entry in entries {
            if messages.len() < limit {
                messages.push(entry.envelope.clone());
                if envelope_kind(&entry.envelope) == Some("pairing_announcement") {
                    queue.push_back(entry);
                }
            } else {
                queue.push_back(entry);
            }
        }

        Ok(messages)
    }

    fn stats(&self) -> RelayStats {
        let mut queues = self
            .queues
            .lock()
            .expect("relay queue lock should not poison");
        self.cleanup_locked(&mut queues);
        RelayStats {
            relay_id: self.config.relay_id.clone(),
            queue_count: queues.len(),
            queued_envelope_count: queues.values().map(VecDeque::len).sum(),
            ttl_seconds: self.config.ttl.as_secs(),
            max_queue_per_mailbox: self.config.max_queue_per_mailbox,
            max_fetch_limit: self.config.max_fetch_limit,
        }
    }

    fn cleanup_locked(&self, queues: &mut HashMap<String, VecDeque<QueueEntry>>) {
        let ttl_millis = self.config.ttl.as_millis() as u64;
        let now = now_millis();
        queues.retain(|_, queue| {
            queue.retain(|entry| now.saturating_sub(entry.queued_at_millis) <= ttl_millis);
            !queue.is_empty()
        });
    }
}

fn main() -> std::io::Result<()> {
    if env::args().any(|arg| arg == "--help" || arg == "-h") {
        println!("{}", usage());
        return Ok(());
    }

    let config = match RelayConfig::from_env_and_args() {
        Ok(config) => config,
        Err(message) => {
            eprintln!("{message}");
            std::process::exit(2);
        }
    };
    let listener = TcpListener::bind(&config.bind)?;
    let udp_socket = UdpSocket::bind(&config.bind)?;
    let state = RelayState::new(config.clone());
    println!(
        "conest relay listening on tcp+udp {} id={} ttl={}s max_queue={} max_fetch={} max_envelope={}B max_rate={}/min",
        config.bind,
        config.relay_id,
        config.ttl.as_secs(),
        config.max_queue_per_mailbox,
        config.max_fetch_limit,
        config.max_envelope_bytes,
        config.max_requests_per_minute
    );

    {
        let state = state.clone();
        let config = config.clone();
        thread::spawn(move || serve_udp(udp_socket, state, config));
    }

    for stream in listener.incoming() {
        match stream {
            Ok(stream) => {
                let state = state.clone();
                thread::spawn(move || {
                    let peer = stream
                        .peer_addr()
                        .map(|address| address.ip().to_string())
                        .unwrap_or_else(|_| "unknown".to_owned());
                    if let Err(error) = handle_client(stream, state, peer) {
                        eprintln!("relay connection error: {error}");
                    }
                });
            }
            Err(error) => eprintln!("relay accept error: {error}"),
        }
    }

    Ok(())
}

fn handle_client(
    stream: std::net::TcpStream,
    state: RelayState,
    peer: String,
) -> std::io::Result<()> {
    let reader_stream = stream.try_clone()?;
    reader_stream.set_read_timeout(Some(Duration::from_secs(5)))?;
    let mut reader = BufReader::new(reader_stream);
    let mut writer = BufWriter::new(stream);

    let mut line = String::new();
    let bytes_read = reader.read_line(&mut line)?;
    if bytes_read == 0 {
        return Ok(());
    }
    if is_http_request_line(&line) {
        let (status, response) = handle_http_request(&line, &mut reader, &state, &peer);
        write_http_response(&mut writer, status, &response)?;
    } else {
        let response = handle_request_bytes(line.as_bytes(), bytes_read, &state, &peer);
        serde_json::to_writer(&mut writer, &response)?;
        writer.write_all(b"\n")?;
    }
    writer.flush()?;

    Ok(())
}

fn is_http_request_line(line: &str) -> bool {
    line.starts_with("GET ") || line.starts_with("POST ") || line.starts_with("OPTIONS ")
}

fn handle_http_request<R: BufRead>(
    request_line: &str,
    reader: &mut R,
    state: &RelayState,
    peer: &str,
) -> (u16, RelayResponse) {
    let mut parts = request_line.split_whitespace();
    let method = parts.next().unwrap_or_default();
    let path = parts.next().unwrap_or("/");
    if path != "/" && path != "/health" && path != "/relay" {
        return (404, RelayResponse::error("unknown HTTP relay path"));
    }

    let mut headers = Vec::new();
    let mut content_length = 0_usize;
    loop {
        let mut line = String::new();
        match reader.read_line(&mut line) {
            Ok(0) => return (400, RelayResponse::error("incomplete HTTP headers")),
            Ok(_) => {
                if line == "\r\n" || line == "\n" {
                    break;
                }
                if headers.len() + line.len() > state.config.max_line_bytes {
                    return (413, RelayResponse::error("HTTP headers too large"));
                }
                if let Some((name, value)) = line.split_once(':')
                    && name.trim().eq_ignore_ascii_case("content-length")
                {
                    content_length = value.trim().parse::<usize>().unwrap_or(0);
                }
                headers.extend_from_slice(line.as_bytes());
            }
            Err(error) => {
                return (
                    400,
                    RelayResponse::error(format!("HTTP header read failed: {error}")),
                );
            }
        }
    }

    match method {
        "GET" | "OPTIONS" => (200, handle_request(RelayRequest::Health, state)),
        "POST" => {
            if content_length == 0 {
                return (400, RelayResponse::error("HTTP relay POST body is empty"));
            }
            if content_length > state.config.max_line_bytes {
                return (413, RelayResponse::error("HTTP relay POST body too large"));
            }
            let mut body = vec![0_u8; content_length];
            if let Err(error) = reader.read_exact(&mut body) {
                return (
                    400,
                    RelayResponse::error(format!("HTTP body read failed: {error}")),
                );
            }
            (200, handle_request_bytes(&body, body.len(), state, peer))
        }
        _ => (405, RelayResponse::error("unsupported HTTP method")),
    }
}

fn write_http_response<W: Write>(
    writer: &mut W,
    status: u16,
    response: &RelayResponse,
) -> std::io::Result<()> {
    let body = serde_json::to_vec(response)?;
    let status_text = match status {
        200 => "OK",
        400 => "Bad Request",
        404 => "Not Found",
        405 => "Method Not Allowed",
        413 => "Payload Too Large",
        _ => "Relay Response",
    };
    write!(
        writer,
        "HTTP/1.1 {status} {status_text}\r\n\
         Content-Type: application/json\r\n\
         Content-Length: {}\r\n\
         Cache-Control: no-store\r\n\
         Access-Control-Allow-Origin: *\r\n\
         Access-Control-Allow-Headers: content-type, bypass-tunnel-reminder, ngrok-skip-browser-warning\r\n\
         Connection: close\r\n\
         \r\n",
        body.len()
    )?;
    writer.write_all(&body)
}

fn serve_udp(socket: UdpSocket, state: RelayState, config: RelayConfig) {
    let buffer_len = config.max_line_bytes.min(65_507);
    let mut buffer = vec![0_u8; buffer_len];
    loop {
        match socket.recv_from(&mut buffer) {
            Ok((bytes_read, peer)) => {
                let response = handle_udp_datagram(&buffer[..bytes_read], bytes_read, &state, peer);
                let response_bytes = match serde_json::to_vec(&response) {
                    Ok(bytes) => bytes,
                    Err(error) => {
                        eprintln!("relay udp encode error: {error}");
                        continue;
                    }
                };
                if let Err(error) = socket.send_to(&response_bytes, peer) {
                    eprintln!("relay udp send error: {error}");
                }
            }
            Err(error) => eprintln!("relay udp receive error: {error}"),
        }
    }
}

fn handle_udp_datagram(
    datagram: &[u8],
    bytes_read: usize,
    state: &RelayState,
    peer: SocketAddr,
) -> RelayResponse {
    let peer_key = peer.ip().to_string();
    handle_request_bytes(datagram, bytes_read, state, &peer_key)
}

fn handle_request_bytes(
    bytes: &[u8],
    bytes_read: usize,
    state: &RelayState,
    peer: &str,
) -> RelayResponse {
    if bytes_read > state.config.max_line_bytes {
        return RelayResponse::error("request line too large");
    }
    if !state.allow_request(peer) {
        return RelayResponse::error("rate limit exceeded");
    }
    match std::str::from_utf8(bytes) {
        Ok(line) => match serde_json::from_str::<RelayRequest>(line.trim()) {
            Ok(request) => handle_request(request, state),
            Err(error) => RelayResponse::error(format!("invalid request: {error}")),
        },
        Err(error) => RelayResponse::error(format!("request is not utf-8: {error}")),
    }
}

fn handle_request(request: RelayRequest, state: &RelayState) -> RelayResponse {
    match request {
        RelayRequest::Store {
            recipient_device_id,
            envelope,
        } => match state.store(recipient_device_id, envelope) {
            Ok(()) => RelayResponse::stored(),
            Err(error) => RelayResponse::error(error),
        },
        RelayRequest::Fetch {
            recipient_device_id,
            limit,
        } => match state.fetch(&recipient_device_id, limit) {
            Ok(messages) => RelayResponse::messages(messages),
            Err(error) => RelayResponse::error(error),
        },
        RelayRequest::Health => RelayResponse::ok(Some(state.stats())),
    }
}

fn envelope_kind(envelope: &Value) -> Option<&str> {
    envelope.get("kind")?.as_str()
}

fn envelope_sender_device_id(envelope: &Value) -> Option<&str> {
    envelope.get("senderDeviceId")?.as_str()
}

fn validate_mailbox_id(value: &str) -> Result<(), String> {
    if value.is_empty() || value.len() > 160 {
        return Err("mailbox id must be 1..160 characters".to_owned());
    }
    if !value
        .bytes()
        .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.' | b':'))
    {
        return Err("mailbox id contains unsupported characters".to_owned());
    }
    Ok(())
}

fn env_u64(name: &str, default: u64) -> u64 {
    env::var(name)
        .ok()
        .and_then(|value| value.parse::<u64>().ok())
        .unwrap_or(default)
}

fn env_u32(name: &str, default: u32) -> u32 {
    env::var(name)
        .ok()
        .and_then(|value| value.parse::<u32>().ok())
        .unwrap_or(default)
}

fn env_usize(name: &str, default: usize) -> usize {
    env::var(name)
        .ok()
        .and_then(|value| value.parse::<usize>().ok())
        .unwrap_or(default)
}

fn parse_next_u64<I>(args: &mut I, name: &str) -> Result<u64, String>
where
    I: Iterator<Item = String>,
{
    args.next()
        .ok_or_else(|| format!("{name} requires a value"))?
        .parse::<u64>()
        .map_err(|_| format!("{name} requires an integer value"))
}

fn parse_next_u32<I>(args: &mut I, name: &str) -> Result<u32, String>
where
    I: Iterator<Item = String>,
{
    args.next()
        .ok_or_else(|| format!("{name} requires a value"))?
        .parse::<u32>()
        .map_err(|_| format!("{name} requires an integer value"))
}

fn parse_next_usize<I>(args: &mut I, name: &str) -> Result<usize, String>
where
    I: Iterator<Item = String>,
{
    args.next()
        .ok_or_else(|| format!("{name} requires a value"))?
        .parse::<usize>()
        .map_err(|_| format!("{name} requires an integer value"))
}

fn parse_next_string<I>(args: &mut I, name: &str) -> Result<String, String>
where
    I: Iterator<Item = String>,
{
    args.next()
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| format!("{name} requires a non-empty value"))
}

fn usage() -> String {
    format!(
        "Usage: conest_relay [BIND] [options]\n\n\
         BIND defaults to {DEFAULT_BIND} or CONEST_RELAY_BIND.\n\n\
         Options:\n\
           --ttl-seconds N\n\
           --relay-id ID\n\
           --max-queue-per-mailbox N\n\
           --max-fetch-limit N\n\
           --max-envelope-bytes N\n\
           --max-line-bytes N\n\
           --max-requests-per-minute N"
    )
}

fn default_relay_id() -> String {
    format!("relay-{}-{}", std::process::id(), now_millis())
}

fn now_millis() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn test_config() -> RelayConfig {
        RelayConfig {
            bind: "127.0.0.1:0".to_owned(),
            relay_id: "relay-test".to_owned(),
            ttl: Duration::from_secs(DEFAULT_TTL_SECONDS),
            max_queue_per_mailbox: 3,
            max_fetch_limit: 2,
            max_envelope_bytes: DEFAULT_MAX_ENVELOPE_BYTES,
            max_line_bytes: DEFAULT_MAX_LINE_BYTES,
            max_requests_per_minute: DEFAULT_MAX_REQUESTS_PER_MINUTE,
        }
    }

    fn envelope(kind: &str, id: &str, sender: &str) -> Value {
        json!({
            "kind": kind,
            "messageId": id,
            "conversationId": "conv",
            "senderAccountId": "acc-a",
            "senderDeviceId": sender,
            "recipientDeviceId": "dev-b",
            "createdAt": "2026-04-16T00:00:00.000Z",
            "payloadBase64": "aGVsbG8="
        })
    }

    #[test]
    fn pairing_announcements_are_reusable_and_deduped_by_sender() {
        let state = RelayState::new(test_config());
        state
            .store(
                "pair-mailbox".to_owned(),
                envelope("pairing_announcement", "pair-1", "dev-a"),
            )
            .expect("store should work");
        state
            .store(
                "pair-mailbox".to_owned(),
                envelope("pairing_announcement", "pair-2", "dev-a"),
            )
            .expect("store should work");

        let first = state
            .fetch("pair-mailbox", Some(8))
            .expect("fetch should work");
        let second = state
            .fetch("pair-mailbox", Some(8))
            .expect("fetch should work");

        assert_eq!(first.len(), 1);
        assert_eq!(first[0]["messageId"], "pair-2");
        assert_eq!(second.len(), 1);
        assert_eq!(second[0]["messageId"], "pair-2");
    }

    #[test]
    fn non_pairing_envelopes_are_consumed_and_fetch_limit_is_clamped() {
        let state = RelayState::new(test_config());
        for index in 0..3 {
            state
                .store(
                    "dev-b".to_owned(),
                    envelope("direct_message", &format!("msg-{index}"), "dev-a"),
                )
                .expect("store should work");
        }

        let first = state.fetch("dev-b", Some(99)).expect("fetch should work");
        let second = state.fetch("dev-b", Some(99)).expect("fetch should work");

        assert_eq!(first.len(), 2);
        assert_eq!(second.len(), 1);
    }

    #[test]
    fn queue_limit_drops_oldest_non_pairing_envelopes() {
        let state = RelayState::new(test_config());
        for index in 0..4 {
            state
                .store(
                    "dev-b".to_owned(),
                    envelope("direct_message", &format!("msg-{index}"), "dev-a"),
                )
                .expect("store should work");
        }

        let fetched = state.fetch("dev-b", Some(10)).expect("fetch should work");
        let ids: Vec<&str> = fetched
            .iter()
            .filter_map(|value| value["messageId"].as_str())
            .collect();

        assert_eq!(ids, vec!["msg-1", "msg-2"]);
    }

    #[test]
    fn mailbox_ids_are_restricted() {
        assert!(validate_mailbox_id("dev-abc_123").is_ok());
        assert!(validate_mailbox_id("../bad").is_err());
        assert!(validate_mailbox_id("").is_err());
    }

    #[test]
    fn udp_datagram_handler_uses_same_relay_protocol() {
        let state = RelayState::new(test_config());
        let peer = "127.0.0.1:49152".parse().expect("test socket addr");
        let store = json!({
            "action": "store",
            "recipient_device_id": "dev-b",
            "envelope": envelope("direct_message", "msg-udp", "dev-a")
        })
        .to_string();
        let fetch = json!({
            "action": "fetch",
            "recipient_device_id": "dev-b",
            "limit": 4
        })
        .to_string();

        let stored = handle_udp_datagram(store.as_bytes(), store.len(), &state, peer);
        let fetched = handle_udp_datagram(fetch.as_bytes(), fetch.len(), &state, peer);

        assert!(stored.ok);
        assert!(stored.stored);
        assert_eq!(fetched.messages.len(), 1);
        assert_eq!(fetched.messages[0]["messageId"], "msg-udp");
    }

    #[test]
    fn http_post_handler_uses_same_relay_protocol() {
        let state = RelayState::new(test_config());
        let peer = "127.0.0.1";
        let store = json!({
            "action": "store",
            "recipient_device_id": "dev-b",
            "envelope": envelope("direct_message", "msg-http", "dev-a")
        })
        .to_string();
        let fetch = json!({
            "action": "fetch",
            "recipient_device_id": "dev-b",
            "limit": 4
        })
        .to_string();

        let store_request = format!(
            "Host: relay.test\r\nContent-Length: {}\r\n\r\n{}",
            store.len(),
            store
        );
        let fetch_request = format!(
            "Host: relay.test\r\nContent-Length: {}\r\n\r\n{}",
            fetch.len(),
            fetch
        );
        let mut store_reader = BufReader::new(store_request.as_bytes());
        let mut fetch_reader = BufReader::new(fetch_request.as_bytes());

        let (store_status, stored) =
            handle_http_request("POST / HTTP/1.1\r\n", &mut store_reader, &state, peer);
        let (fetch_status, fetched) =
            handle_http_request("POST /relay HTTP/1.1\r\n", &mut fetch_reader, &state, peer);

        assert_eq!(store_status, 200);
        assert!(stored.ok);
        assert!(stored.stored);
        assert_eq!(fetch_status, 200);
        assert_eq!(fetched.messages.len(), 1);
        assert_eq!(fetched.messages[0]["messageId"], "msg-http");
    }

    #[test]
    fn http_get_health_reports_relay_instance_id() {
        let state = RelayState::new(test_config());
        let mut reader = BufReader::new("Host: relay.test\r\n\r\n".as_bytes());
        let (status, response) =
            handle_http_request("GET /health HTTP/1.1\r\n", &mut reader, &state, "127.0.0.1");
        let stats = response.stats.expect("health should include stats");

        assert_eq!(status, 200);
        assert!(response.ok);
        assert_eq!(stats.relay_id, "relay-test");
    }

    #[test]
    fn health_reports_relay_instance_id() {
        let state = RelayState::new(test_config());
        let response = handle_request(RelayRequest::Health, &state);
        let stats = response.stats.expect("health should include stats");

        assert!(response.ok);
        assert_eq!(stats.relay_id, "relay-test");
    }
}
