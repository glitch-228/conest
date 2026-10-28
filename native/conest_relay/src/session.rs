//! Relay v2 sessions: one long-lived, encrypted connection carrying many
//! requests and subscriptions.
//!
//! On the wire (after the `CNS2` magic the server detects):
//!
//! ```text
//! client: "CNS2" | version u8 (1) | u16 length | Noise message 1 (-> e, es)
//! relay:  u16 length | Noise message 2 (<- e, ee)
//! then, both ways: records of u16 length | ciphertext (at most 65535)
//! ```
//!
//! The handshake is `Noise_NK_25519_ChaChaPoly_SHA256` with the prologue
//! `conest-relay-v2`, against the relay's static X25519 key, which its
//! Ed25519 identity signs (published in health). Records decrypt to a
//! stream of frames, `u32 length | u8 type | u32 stream | payload`, which
//! may span records. Requests are v1 JSON objects; responses are v1 JSON.
//! Mailbox ids and tokens never cross the network in the clear.

use std::collections::{HashMap, VecDeque};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::{Value, json};
use snow::{Builder, StatelessTransportState};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::sync::mpsc;
use tokio::task::{AbortHandle, JoinSet};
use tokio::time::{Instant, timeout, timeout_at};

use crate::config::{DEFAULT_LEASE_MILLIS, RESPONSE_WRITE_DEADLINE};
use crate::owners::{MAX_SESSION_MAILBOXES, ProvedMailboxes};
use crate::storage::RelayState;
use crate::v1::{
    Prepared, PreparedRequest, envelope_kind, execute_async, finalize_wire, prepare_request,
    validate_mailbox_id,
};

pub(crate) const NOISE_PARAMS: &str = "Noise_NK_25519_ChaChaPoly_SHA256";
pub(crate) const PROLOGUE: &[u8] = b"conest-relay-v2";
pub(crate) const SESSION_VERSION: u8 = 1;
/// A handshake message: 32 bytes of key, a payload, a 16-byte tag.
const MAX_HANDSHAKE_MESSAGE: usize = 2048;
const MIN_HANDSHAKE_MESSAGE: usize = 32 + 16;
const MAX_RECORD: usize = 65_535;
const TAG: usize = 16;
pub(crate) const MAX_RECORD_PLAINTEXT: usize = MAX_RECORD - TAG;
pub(crate) const FRAME_HEADER: usize = 9;
/// Mailboxes one subscription may watch.
pub(crate) const MAX_SUBSCRIBE_MAILBOXES: usize = 8;
/// How often a subscription looks again without a store (leases that ran
/// out come back this way).
const SUBSCRIPTION_RECHECK: Duration = Duration::from_secs(20);
/// Pairing announcements a subscription remembers having pushed (they stay
/// queued, so each look returns them again).
const MAX_PUSHED_PAIRING: usize = 64;
/// Frames waiting for the writer.
const OUTBOX: usize = 64;

/// Frame types. 0x10–0x1f are reserved for blobs, 0x20–0x2f for chunk sets
/// (M27), 0x30–0x3f for call media (M28); the relay answers them (and any
/// other unknown type on a stream) with "unsupported".
pub(crate) mod frame_type {
    /// Client: a v1 JSON request on a new stream.
    pub(crate) const REQUEST: u8 = 0x01;
    /// Relay: the answer; it ends the stream.
    pub(crate) const RESPONSE: u8 = 0x02;
    /// Relay: one of several pushes on a stream (subscriptions).
    pub(crate) const EVENT: u8 = 0x03;
    /// Client: ends a stream (a subscription) early.
    pub(crate) const CANCEL: u8 = 0x04;
    /// Either side; answered with PONG and the same payload.
    pub(crate) const PING: u8 = 0x05;
    pub(crate) const PONG: u8 = 0x06;
    /// Relay: it is closing the session; payload says why.
    pub(crate) const GOAWAY: u8 = 0x07;
    /// Ignored (traffic shaping).
    pub(crate) const PAD: u8 = 0x0f;
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Frame {
    pub(crate) kind: u8,
    pub(crate) stream: u32,
    pub(crate) payload: Vec<u8>,
}

pub(crate) fn encode_frame(kind: u8, stream: u32, payload: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(FRAME_HEADER + payload.len());
    out.extend_from_slice(&(payload.len() as u32).to_be_bytes());
    out.push(kind);
    out.extend_from_slice(&stream.to_be_bytes());
    out.extend_from_slice(payload);
    out
}

/// Frames out of decrypted record bytes, each at most [max_payload].
pub(crate) struct FrameDecoder {
    buffer: Vec<u8>,
    max_payload: usize,
}

impl FrameDecoder {
    pub(crate) fn new(max_payload: usize) -> Self {
        Self {
            buffer: Vec::new(),
            max_payload,
        }
    }

    pub(crate) fn push(&mut self, bytes: &[u8]) {
        self.buffer.extend_from_slice(bytes);
    }

    /// The next whole frame, if one is buffered; an error for a frame over
    /// the limit (the session ends).
    pub(crate) fn next_frame(&mut self) -> Result<Option<Frame>, String> {
        if self.buffer.len() < FRAME_HEADER {
            return Ok(None);
        }
        let length = u32::from_be_bytes([
            self.buffer[0],
            self.buffer[1],
            self.buffer[2],
            self.buffer[3],
        ]) as usize;
        if length > self.max_payload {
            return Err(format!(
                "frame too large: {length} bytes > {}",
                self.max_payload
            ));
        }
        if self.buffer.len() < FRAME_HEADER + length {
            return Ok(None);
        }
        let kind = self.buffer[4];
        let stream = u32::from_be_bytes([
            self.buffer[5],
            self.buffer[6],
            self.buffer[7],
            self.buffer[8],
        ]);
        let payload = self.buffer[FRAME_HEADER..FRAME_HEADER + length].to_vec();
        self.buffer.drain(..FRAME_HEADER + length);
        Ok(Some(Frame {
            kind,
            stream,
            payload,
        }))
    }
}

fn invalid(what: impl Into<String>) -> std::io::Error {
    std::io::Error::new(std::io::ErrorKind::InvalidData, what.into())
}

fn timed_out(what: &str) -> std::io::Error {
    std::io::Error::new(std::io::ErrorKind::TimedOut, what.to_owned())
}

fn noise_error(error: snow::Error) -> std::io::Error {
    invalid(format!("noise: {error}"))
}

/// The relay's side of the handshake.
pub(crate) fn responder(private: &[u8; 32]) -> Result<snow::HandshakeState, std::io::Error> {
    let params: snow::params::NoiseParams = NOISE_PARAMS.parse().map_err(noise_error)?;
    Builder::new(params)
        .local_private_key(private)
        .prologue(PROLOGUE)
        .build_responder()
        .map_err(noise_error)
}

/// What the relay says in its handshake reply.
fn server_hello(state: &RelayState) -> Vec<u8> {
    json!({
        "v": SESSION_VERSION,
        "max_frame": max_frame_payload(state),
        "max_streams": state.config.ext.session_max_streams,
        "idle_s": state.config.ext.session_idle.as_secs(),
    })
    .to_string()
    .into_bytes()
}

/// The largest frame a client may send: a v1 request line and a little.
pub(crate) fn max_frame_payload(state: &RelayState) -> usize {
    state.config.max_line_bytes + 4096
}

/// Reads until [buffer] holds [wanted] bytes, by [deadline].
async fn fill<R: AsyncRead + Unpin>(
    reader: &mut R,
    buffer: &mut Vec<u8>,
    wanted: usize,
    deadline: Instant,
) -> std::io::Result<()> {
    let mut chunk = [0_u8; 4096];
    while buffer.len() < wanted {
        let room = (wanted - buffer.len()).min(chunk.len());
        let read = timeout_at(deadline, reader.read(&mut chunk[..room]))
            .await
            .map_err(|_| timed_out("handshake took too long"))??;
        if read == 0 {
            return Err(std::io::Error::new(
                std::io::ErrorKind::UnexpectedEof,
                "session closed during the handshake",
            ));
        }
        buffer.extend_from_slice(&chunk[..read]);
    }
    Ok(())
}

/// Serves one v2 session; [buffer] holds what was read while detecting it.
pub(crate) async fn serve_session<S>(
    stream: S,
    state: RelayState,
    peer: String,
    mut buffer: Vec<u8>,
) -> std::io::Result<()>
where
    S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
{
    let deadline = Instant::now() + state.config.ext.read_deadline;
    let (mut reader, mut writer) = tokio::io::split(stream);
    fill(&mut reader, &mut buffer, 7, deadline).await?;
    if buffer[4] != SESSION_VERSION {
        return Err(invalid("unsupported session version"));
    }
    let length = u16::from_be_bytes([buffer[5], buffer[6]]) as usize;
    if !(MIN_HANDSHAKE_MESSAGE..=MAX_HANDSHAKE_MESSAGE).contains(&length) {
        return Err(invalid("bad handshake length"));
    }
    fill(&mut reader, &mut buffer, 7 + length, deadline).await?;
    if buffer.len() != 7 + length {
        // Nothing may follow before the relay's reply: the client has no
        // keys yet.
        return Err(invalid("data before the handshake finished"));
    }
    if !state.allow_request(&peer) {
        return Err(invalid("rate limit exceeded"));
    }
    let mut handshake = responder(&state.identity.noise_private)?;
    let mut payload = vec![0_u8; MAX_HANDSHAKE_MESSAGE];
    handshake
        .read_message(&buffer[7..7 + length], &mut payload)
        .map_err(noise_error)?;
    let hello = server_hello(&state);
    let mut message = vec![0_u8; MAX_HANDSHAKE_MESSAGE];
    let written = handshake
        .write_message(&hello, &mut message)
        .map_err(noise_error)?;
    let mut reply = Vec::with_capacity(2 + written);
    reply.extend_from_slice(&(written as u16).to_be_bytes());
    reply.extend_from_slice(&message[..written]);
    timeout(RESPONSE_WRITE_DEADLINE, async {
        writer.write_all(&reply).await?;
        writer.flush().await
    })
    .await
    .map_err(|_| timed_out("handshake reply not taken"))??;
    let handshake_hash = handshake.get_handshake_hash().to_vec();
    let transport = Arc::new(
        handshake
            .into_stateless_transport_mode()
            .map_err(noise_error)?,
    );
    run_session(reader, writer, transport, state, peer, handshake_hash).await
}

/// What a session's tasks share.
pub(crate) struct Session {
    pub(crate) state: RelayState,
    pub(crate) peer: String,
    /// Unique to this session (the Noise handshake hash): what mailbox
    /// owners sign, so a proof cannot be replayed on another session.
    pub(crate) handshake_hash: Vec<u8>,
    out: mpsc::Sender<Frame>,
    streams: Mutex<HashMap<u32, AbortHandle>>,
    subscriptions: AtomicUsize,
    /// Set once the session shows it is a real user: it proved a mailbox
    /// whose claim is days old (not a throwaway one; mail stored to one's own
    /// mailbox proves nothing). (Claiming a fresh id with a throwaway key proves nothing.)
    trusted: std::sync::atomic::AtomicBool,
    /// Mailboxes whose owner proved itself on this session.
    proved: Mutex<ProvedMailboxes>,
}

async fn run_session<R, W>(
    mut reader: R,
    writer: W,
    transport: Arc<StatelessTransportState>,
    state: RelayState,
    peer: String,
    handshake_hash: Vec<u8>,
) -> std::io::Result<()>
where
    R: AsyncRead + Unpin + Send + 'static,
    W: AsyncWrite + Unpin + Send + 'static,
{
    let (out, outbox) = mpsc::channel::<Frame>(OUTBOX);
    let writer_task = tokio::spawn(write_frames(writer, Arc::clone(&transport), outbox));
    let session = Arc::new(Session {
        state,
        peer,
        handshake_hash,
        out,
        streams: Mutex::new(HashMap::new()),
        subscriptions: AtomicUsize::new(0),
        trusted: std::sync::atomic::AtomicBool::new(false),
        proved: Mutex::new(ProvedMailboxes::new()),
    });
    let result = read_frames(&mut reader, &transport, &session).await;
    // Every stream ends with the session.
    session.abort_all();
    writer_task.abort();
    result
}

/// Encrypts frames into records and writes them, each frame taken within
/// the write deadline.
async fn write_frames<W: AsyncWrite + Unpin>(
    mut writer: W,
    transport: Arc<StatelessTransportState>,
    mut outbox: mpsc::Receiver<Frame>,
) -> std::io::Result<()> {
    let mut nonce: u64 = 0;
    let mut sealed = vec![0_u8; MAX_RECORD];
    while let Some(frame) = outbox.recv().await {
        let plain = encode_frame(frame.kind, frame.stream, &frame.payload);
        let mut records =
            Vec::with_capacity(plain.len() + (plain.len() / MAX_RECORD_PLAINTEXT + 1) * (2 + TAG));
        for chunk in plain.chunks(MAX_RECORD_PLAINTEXT) {
            let written = transport
                .write_message(nonce, chunk, &mut sealed)
                .map_err(noise_error)?;
            nonce += 1;
            records.extend_from_slice(&(written as u16).to_be_bytes());
            records.extend_from_slice(&sealed[..written]);
        }
        timeout(RESPONSE_WRITE_DEADLINE, async {
            writer.write_all(&records).await?;
            writer.flush().await
        })
        .await
        .map_err(|_| timed_out("session frame not taken"))??;
    }
    Ok(())
}

/// Reads records, decrypts them and acts on each frame, until the client
/// closes, goes quiet past the idle limit, or breaks the protocol.
async fn read_frames<R: AsyncRead + Unpin>(
    reader: &mut R,
    transport: &StatelessTransportState,
    session: &Arc<Session>,
) -> std::io::Result<()> {
    let idle = session.state.config.ext.session_idle;
    let record_deadline = session.state.config.ext.read_deadline;
    let mut decoder = FrameDecoder::new(max_frame_payload(&session.state));
    let mut nonce: u64 = 0;
    let mut header = [0_u8; 2];
    let mut record = vec![0_u8; MAX_RECORD];
    let mut plain = vec![0_u8; MAX_RECORD];
    // Padding and pongs cost the sender nothing: only a real frame (a
    // request, a ping) keeps the session alive.
    let mut last_real = Instant::now();
    loop {
        match timeout_at(last_real + idle, reader.read_exact(&mut header)).await {
            Err(_) => return Err(timed_out("session idle")),
            Ok(Err(error)) if error.kind() == std::io::ErrorKind::UnexpectedEof => return Ok(()),
            Ok(Err(error)) => return Err(error),
            Ok(Ok(_)) => {}
        }
        let length = u16::from_be_bytes(header) as usize;
        if length < TAG {
            return Err(invalid("record too short"));
        }
        timeout(record_deadline, reader.read_exact(&mut record[..length]))
            .await
            .map_err(|_| timed_out("record took too long"))??;
        let read = transport
            .read_message(nonce, &record[..length], &mut plain)
            .map_err(noise_error)?;
        nonce += 1;
        decoder.push(&plain[..read]);
        while let Some(frame) = decoder.next_frame().map_err(invalid)? {
            if frame.kind != frame_type::PAD && frame.kind != frame_type::PONG {
                last_real = Instant::now();
            }
            session.dispatch(frame).await?;
        }
    }
}

fn error_json(message: impl Into<String>) -> Value {
    json!({
        "ok": false,
        "stored": false,
        "messages": [],
        "error": message.into(),
        "stats": null,
    })
}

impl Session {
    async fn send(&self, kind: u8, stream: u32, payload: Vec<u8>) -> Result<(), ()> {
        self.out
            .send(Frame {
                kind,
                stream,
                payload,
            })
            .await
            .map_err(|_| ())
    }

    async fn respond(&self, stream: u32, value: &Value) -> Result<(), ()> {
        self.send(frame_type::RESPONSE, stream, value.to_string().into_bytes())
            .await
    }

    fn abort_all(&self) {
        let mut streams = self.streams.lock().expect("stream lock should not poison");
        for (_, handle) in streams.drain() {
            handle.abort();
        }
    }

    async fn dispatch(self: &Arc<Self>, frame: Frame) -> std::io::Result<()> {
        let closed = || std::io::Error::new(std::io::ErrorKind::BrokenPipe, "session writer gone");
        match frame.kind {
            frame_type::REQUEST => {
                if let Some(refusal) = self.start_stream(frame.stream, frame.payload) {
                    self.respond(frame.stream, &refusal)
                        .await
                        .map_err(|_| closed())?;
                }
            }
            frame_type::CANCEL => {
                let handle = self
                    .streams
                    .lock()
                    .expect("stream lock should not poison")
                    .remove(&frame.stream);
                if let Some(handle) = handle {
                    handle.abort();
                }
            }
            frame_type::PING => {
                // Counted like a request: a flood of pings is refused.
                if self.state.allow_request(&self.peer) {
                    self.send(frame_type::PONG, frame.stream, frame.payload)
                        .await
                        .map_err(|_| closed())?;
                }
            }
            frame_type::PONG | frame_type::PAD => {}
            _ => {
                if frame.stream != 0 {
                    self.respond(frame.stream, &error_json("unsupported"))
                        .await
                        .map_err(|_| closed())?;
                }
            }
        }
        Ok(())
    }

    /// Starts a request on [stream]; a refusal to send instead when it
    /// cannot start.
    fn start_stream(self: &Arc<Self>, stream: u32, payload: Vec<u8>) -> Option<Value> {
        if stream == 0 {
            return Some(error_json("stream 0 is reserved"));
        }
        let mut streams = self.streams.lock().expect("stream lock should not poison");
        if streams.contains_key(&stream) {
            return Some(error_json("stream already in use"));
        }
        if streams.len() >= self.state.config.ext.session_max_streams {
            return Some(error_json("too many requests in flight"));
        }
        let session = Arc::clone(self);
        // The lock is held until the handle is in the map, so the task
        // cannot finish (and remove it) first.
        let task = tokio::spawn(async move {
            let response = session.run_request(stream, payload).await;
            session
                .streams
                .lock()
                .expect("stream lock should not poison")
                .remove(&stream);
            let _ = session.respond(stream, &response).await;
        });
        streams.insert(stream, task.abort_handle());
        None
    }

    async fn run_request(self: &Arc<Self>, stream: u32, payload: Vec<u8>) -> Value {
        let action = serde_json::from_slice::<Value>(&payload)
            .ok()
            .and_then(|value| {
                value
                    .get("action")
                    .and_then(Value::as_str)
                    .map(str::to_owned)
            })
            .unwrap_or_default();
        if action == "subscribe" {
            return self.run_subscription(stream, &payload).await;
        }
        if action == "mailbox_auth" {
            return self.prove_mailbox(&payload);
        }
        if action == "register" {
            if !self.state.allow_request(&self.peer) {
                return error_json("rate limit exceeded");
            }
            let Ok(request) = serde_json::from_slice::<Value>(&payload) else {
                return error_json("invalid request");
            };
            let hash = self.handshake_hash.clone();
            let peer = self.peer.clone();
            return self
                .state
                .blocking(move |state| state.register(&request, &hash, &peer))
                .await
                .and_then(|result| result)
                .unwrap_or_else(|error| error_json(error));
        }
        // Scoped: the check is not Send, and must not live across awaits.
        let prepared = {
            let proved: &dyn Fn(&str) -> bool = &|mailbox: &str| self.has_proved(mailbox);
            prepare_request(
                &payload,
                payload.len(),
                &self.state,
                &self.peer,
                None,
                Some(proved),
            )
        };
        match prepared {
            Prepared::Done(value) => value,
            Prepared::Run(prepared) => {
                let PreparedRequest {
                    request,
                    action,
                    nonce,
                    detached,
                    long_poll,
                } = prepared;
                let response = execute_async(request, &self.state, &self.peer).await;
                drop(long_poll);
                let mut answer = finalize_wire(
                    response,
                    &action,
                    nonce.as_deref(),
                    detached,
                    &self.state.identity,
                );
                // Inside a session only, and only to one that has shown it
                // is a user (a registered token, or a mailbox it proved):
                // the hidden addresses are not for every anonymous caller.
                let trusted = action == "health" && self.session_is_trusted(&payload);
                if trusted
                    && let Some(hidden) = self.state.hidden_address()
                    && let Some(v2) = answer
                        .get_mut("stats")
                        .and_then(|stats| stats.get_mut("v2"))
                        .and_then(Value::as_object_mut)
                {
                    v2.insert("hidden".to_owned(), Value::String(hidden));
                }
                // And the borrowed-handshake address (M38-D).
                if trusted
                    && let Some(cert) = self.state.tls_cert_info()
                    && let Some(v2) = answer
                        .get_mut("stats")
                        .and_then(|stats| stats.get_mut("v2"))
                        .and_then(Value::as_object_mut)
                {
                    v2.insert("tls_cert".to_owned(), cert);
                }
                if trusted
                    && let Some(borrowed) = self.state.borrowed_info()
                    && let Some(v2) = answer
                        .get_mut("stats")
                        .and_then(|stats| stats.get_mut("v2"))
                        .and_then(Value::as_object_mut)
                {
                    v2.insert("borrowed".to_owned(), borrowed);
                }
                answer
            }
        }
    }

    /// Whether this session has a valid registration token in [payload]'s
    /// request, or showed itself a user (see [Session::trusted]).
    fn session_is_trusted(&self, payload: &[u8]) -> bool {
        if self.trusted.load(Ordering::Acquire) {
            return true;
        }
        serde_json::from_slice::<Value>(payload)
            .ok()
            .and_then(|request| request.get("token")?.as_str().map(str::to_owned))
            .is_some_and(|token| self.state.valid_token(&token).is_some())
    }

    fn has_proved(&self, mailbox: &str) -> bool {
        self.proved
            .lock()
            .expect("proved lock should not poison")
            .contains(mailbox)
    }

    /// `{"action":"mailbox_auth","mailbox":…,"auth_key":…,"signature":…}`:
    /// the owner proves itself for this session (claiming the mailbox when
    /// nobody has).
    fn prove_mailbox(&self, payload: &[u8]) -> Value {
        if !self.state.allow_request(&self.peer) {
            return error_json("rate limit exceeded");
        }
        let Ok(request) = serde_json::from_slice::<Value>(payload) else {
            return error_json("invalid request");
        };
        if self
            .proved
            .lock()
            .expect("proved lock should not poison")
            .len()
            >= MAX_SESSION_MAILBOXES
        {
            return error_json("too many mailboxes on one session");
        }
        let mailbox_text = request.get("mailbox").and_then(Value::as_str);
        let owned_before =
            mailbox_text.is_some_and(|mailbox| self.state.owner_is_established(mailbox));
        match self
            .state
            .authorize_session(&request, &self.handshake_hash, &self.peer)
        {
            Ok(mailbox) => {
                if owned_before {
                    self.trusted.store(true, Ordering::Release);
                }
                self.proved
                    .lock()
                    .expect("proved lock should not poison")
                    .insert(mailbox);
                json!({"ok": true, "stored": false, "messages": [], "error": null, "stats": null})
            }
            Err(error) => error_json(error),
        }
    }

    /// `{"action":"subscribe","mailboxes":[…],"limit":N,"lease_ms":N}`:
    /// pushes what arrives for those mailboxes as EVENT frames, leased as
    /// `fetch_leased` leases them (acknowledged with `ack_lease`), until the
    /// client cancels the stream or the session ends. The first event says
    /// it is in place.
    async fn run_subscription(self: &Arc<Self>, stream: u32, payload: &[u8]) -> Value {
        if !self.state.allow_request(&self.peer) {
            return error_json("rate limit exceeded");
        }
        let Ok(request) = serde_json::from_slice::<Value>(payload) else {
            return error_json("invalid request");
        };
        let mut mailboxes: Vec<String> = Vec::new();
        match request.get("mailboxes").and_then(Value::as_array) {
            Some(list) if !list.is_empty() && list.len() <= MAX_SUBSCRIBE_MAILBOXES => {
                for item in list {
                    let Some(mailbox) = item.as_str() else {
                        return error_json("mailboxes must be strings");
                    };
                    if let Err(error) = validate_mailbox_id(mailbox) {
                        return error_json(error);
                    }
                    if self.state.owner_of(mailbox).is_some() && !self.has_proved(mailbox) {
                        return error_json("this mailbox needs its owner's signature");
                    }
                    if !mailboxes.iter().any(|known| known == mailbox) {
                        mailboxes.push(mailbox.to_owned());
                    }
                }
            }
            _ => {
                return error_json(format!(
                    "subscribe needs 1..{MAX_SUBSCRIBE_MAILBOXES} mailboxes"
                ));
            }
        }
        let max_fetch = self.state.config.max_fetch_limit;
        let limit = request
            .get("limit")
            .and_then(Value::as_u64)
            .map_or(max_fetch, |value| value.min(max_fetch as u64) as usize)
            .max(1);
        let lease_ms = request
            .get("lease_ms")
            .and_then(Value::as_u64)
            .unwrap_or(DEFAULT_LEASE_MILLIS)
            .clamp(5_000, 300_000);
        let held = self.subscriptions.fetch_add(1, Ordering::AcqRel);
        let _counted = SubscriptionSlot(Arc::clone(self));
        if held >= self.state.config.ext.session_max_subscriptions {
            return error_json("too many subscriptions");
        }
        let started = json!({"ok": true, "subscribed": mailboxes});
        if self
            .send(frame_type::EVENT, stream, started.to_string().into_bytes())
            .await
            .is_err()
        {
            return error_json("session closed");
        }
        let mut watchers = JoinSet::new();
        for mailbox in mailboxes {
            let session = Arc::clone(self);
            watchers.spawn(async move { session.watch(stream, mailbox, limit, lease_ms).await });
        }
        // Watchers end only when the session's writer is gone; a cancel
        // aborts this task, and dropping the set aborts them.
        while watchers.join_next().await.is_some() {}
        error_json("session closed")
    }

    /// Pushes what arrives for [mailbox] on [stream].
    async fn watch(self: Arc<Self>, stream: u32, mailbox: String, limit: usize, lease_ms: u64) {
        let mut pushed_pairing: VecDeque<String> = VecDeque::new();
        loop {
            // Ownership can be claimed after the subscription began: from
            // then on only the owner's session may keep leasing.
            if self.state.owner_of(&mailbox).is_some() && !self.has_proved(&mailbox) {
                let event = json!({
                    "ok": false,
                    "mailbox": mailbox,
                    "error": "this mailbox needs its owner's signature",
                });
                let _ = self
                    .send(frame_type::EVENT, stream, event.to_string().into_bytes())
                    .await;
                return;
            }
            let observed = self.state.observe(&mailbox);
            let wanted = mailbox.clone();
            let taken = self
                .state
                .blocking(move |state| state.take_queue(&wanted, limit, Some(lease_ms)))
                .await;
            let (messages, lease_id) = match taken {
                Ok(Ok(batch)) => batch,
                _ => {
                    drop(observed);
                    tokio::time::sleep(Duration::from_secs(5)).await;
                    continue;
                }
            };
            // Pairing announcements are never leased: they come back every
            // call, so they must not make a batch "full" (that would loop
            // without waiting).
            let leasable = messages
                .iter()
                .filter(|message| envelope_kind(message) != Some("pairing_announcement"))
                .count();
            let full = leasable >= limit;
            let mut fresh = Vec::with_capacity(messages.len());
            for message in messages {
                if envelope_kind(&message) == Some("pairing_announcement") {
                    // They stay queued: pushed once each.
                    let key = message.to_string();
                    if pushed_pairing.contains(&key) {
                        continue;
                    }
                    if pushed_pairing.len() >= MAX_PUSHED_PAIRING {
                        pushed_pairing.pop_front();
                    }
                    pushed_pairing.push_back(key);
                }
                fresh.push(message);
            }
            if !fresh.is_empty() {
                let event = json!({
                    "ok": true,
                    "mailbox": mailbox,
                    "messages": fresh,
                    "lease_id": lease_id,
                });
                if self
                    .send(frame_type::EVENT, stream, event.to_string().into_bytes())
                    .await
                    .is_err()
                {
                    return;
                }
            }
            if full && !fresh.is_empty() {
                continue;
            }
            self.state
                .wait_for_store(&mailbox, observed.generation, SUBSCRIPTION_RECHECK)
                .await;
        }
    }
}

/// A session's count of subscriptions, given back when one ends.
struct SubscriptionSlot(Arc<Session>);

impl Drop for SubscriptionSlot {
    fn drop(&mut self) {
        self.0.subscriptions.fetch_sub(1, Ordering::AcqRel);
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::identity::RelayIdentity;
    use crate::parity_tests::{parity_config, start_tokio};
    use std::io::{Read, Write};
    use std::net::TcpStream;

    fn hex(text: &str) -> Vec<u8> {
        (0..text.len())
            .step_by(2)
            .map(|index| u8::from_str_radix(&text[index..index + 2], 16).expect("hex"))
            .collect()
    }

    fn fixture() -> Value {
        serde_json::from_str(include_str!("../../../test/fixtures/relay_v2/session.json"))
            .expect("fixture json")
    }

    fn field(fixture: &Value, name: &str) -> Vec<u8> {
        hex(fixture[name].as_str().expect("fixture field"))
    }

    #[test]
    fn the_session_key_is_derived_and_signed_as_the_fixture_says() {
        use ed25519_dalek::{Signature, Verifier};
        let fixture = fixture();
        let mut seed = [0_u8; 32];
        seed.copy_from_slice(&field(&fixture, "identity_seed"));
        let identity = RelayIdentity::from_seed_bytes(seed);
        assert_eq!(
            identity.signing_key.verifying_key().to_bytes().to_vec(),
            field(&fixture, "identity_public")
        );
        assert_eq!(
            identity.noise_private.to_vec(),
            field(&fixture, "relay_static_private")
        );
        assert_eq!(
            identity.noise_public.to_vec(),
            field(&fixture, "relay_static_public")
        );
        // Ed25519 signs deterministically: the same bytes.
        assert_eq!(
            identity.noise_key_signature.to_vec(),
            field(&fixture, "binding_signature")
        );
        let mut signature = [0_u8; 64];
        signature.copy_from_slice(&field(&fixture, "binding_signature"));
        assert!(
            identity
                .signing_key
                .verifying_key()
                .verify(
                    &field(&fixture, "binding_message"),
                    &Signature::from_bytes(&signature)
                )
                .is_ok()
        );
    }

    #[test]
    fn the_handshake_matches_the_shared_fixture() {
        let fixture = fixture();
        assert_eq!(fixture["protocol"], NOISE_PARAMS);
        assert_eq!(field(&fixture, "prologue"), PROLOGUE.to_vec());
        let params: snow::params::NoiseParams = NOISE_PARAMS.parse().expect("params");
        let responder_params: snow::params::NoiseParams = NOISE_PARAMS.parse().expect("params");
        let relay_private = field(&fixture, "relay_static_private");
        let relay_public = field(&fixture, "relay_static_public");
        let client_ephemeral = field(&fixture, "client_ephemeral_private");
        let relay_ephemeral = field(&fixture, "relay_ephemeral_private");
        let mut initiator = Builder::new(params)
            .remote_public_key(&relay_public)
            .prologue(PROLOGUE)
            .fixed_ephemeral_key_for_testing_only(&client_ephemeral)
            .build_initiator()
            .expect("initiator");
        let mut responder = Builder::new(responder_params)
            .local_private_key(&relay_private)
            .prologue(PROLOGUE)
            .fixed_ephemeral_key_for_testing_only(&relay_ephemeral)
            .build_responder()
            .expect("responder");
        let mut message = vec![0_u8; 1024];
        let mut payload = vec![0_u8; 1024];
        let written = initiator
            .write_message(&field(&fixture, "msg1_payload"), &mut message)
            .expect("message 1");
        assert_eq!(message[..written].to_vec(), field(&fixture, "msg1"));
        let read = responder
            .read_message(&message[..written], &mut payload)
            .expect("read 1");
        assert_eq!(payload[..read].to_vec(), field(&fixture, "msg1_payload"));
        let written = responder
            .write_message(&field(&fixture, "msg2_payload"), &mut message)
            .expect("message 2");
        assert_eq!(message[..written].to_vec(), field(&fixture, "msg2"));
        let read = initiator
            .read_message(&message[..written], &mut payload)
            .expect("read 2");
        assert_eq!(payload[..read].to_vec(), field(&fixture, "msg2_payload"));
        assert_eq!(
            initiator.get_handshake_hash().to_vec(),
            field(&fixture, "handshake_hash")
        );
        let hello = field(&fixture, "client_hello");
        assert_eq!(&hello[..4], b"CNS2");
        assert_eq!(hello[4], SESSION_VERSION);
        assert_eq!(hello[7..].to_vec(), field(&fixture, "msg1"));

        let client = initiator.into_stateless_transport_mode().expect("client");
        let relay = responder.into_stateless_transport_mode().expect("relay");
        let mut client_nonce = 0_u64;
        let mut relay_nonce = 0_u64;
        for record in fixture["transport"].as_array().expect("transport") {
            let plaintext = hex(record["plaintext"].as_str().expect("plaintext"));
            let expected = hex(record["record"].as_str().expect("record"));
            let mut sealed = vec![0_u8; MAX_RECORD];
            let (written, nonce) = if record["from"] == "client" {
                let written = client
                    .write_message(client_nonce, &plaintext, &mut sealed)
                    .expect("seal");
                client_nonce += 1;
                (written, client_nonce - 1)
            } else {
                let written = relay
                    .write_message(relay_nonce, &plaintext, &mut sealed)
                    .expect("seal");
                relay_nonce += 1;
                (written, relay_nonce - 1)
            };
            assert_eq!(
                u16::from_be_bytes([expected[0], expected[1]]) as usize,
                written
            );
            assert_eq!(sealed[..written].to_vec(), expected[2..].to_vec());
            let mut opened = vec![0_u8; MAX_RECORD];
            let read = if record["from"] == "client" {
                relay
                    .read_message(nonce, &sealed[..written], &mut opened)
                    .expect("open")
            } else {
                client
                    .read_message(nonce, &sealed[..written], &mut opened)
                    .expect("open")
            };
            assert_eq!(opened[..read].to_vec(), plaintext);
        }
    }

    #[test]
    fn frames_encode_as_the_fixture_says_and_are_bounded() {
        let fixture = fixture();
        for sample in fixture["frames"].as_array().expect("frames") {
            let kind = sample["type"].as_u64().expect("type") as u8;
            let stream = sample["stream"].as_u64().expect("stream") as u32;
            let payload = sample["payload"].as_str().expect("payload").as_bytes();
            let encoded = encode_frame(kind, stream, payload);
            assert_eq!(encoded, hex(sample["hex"].as_str().expect("hex")));
            // Fed a byte at a time, the decoder finds the same frame.
            let mut decoder = FrameDecoder::new(1024);
            let mut found = None;
            for byte in &encoded {
                decoder.push(&[*byte]);
                if let Some(frame) = decoder.next_frame().expect("frame") {
                    found = Some(frame);
                }
            }
            assert_eq!(
                found,
                Some(Frame {
                    kind,
                    stream,
                    payload: payload.to_vec()
                })
            );
        }
        // A frame over the limit is refused once its header is in.
        let mut decoder = FrameDecoder::new(16);
        decoder.push(&encode_frame(frame_type::REQUEST, 1, &[0_u8; 17])[..FRAME_HEADER]);
        assert!(decoder.next_frame().is_err());
    }

    /// A blocking v2 client for tests.
    pub(crate) struct TestClient {
        stream: TcpStream,
        transport: StatelessTransportState,
        send_nonce: u64,
        receive_nonce: u64,
        decoder: FrameDecoder,
        pub(crate) handshake_hash: Vec<u8>,
        pub(crate) hello: Value,
    }

    impl TestClient {
        pub(crate) fn connect(address: std::net::SocketAddr, relay_public: &[u8]) -> Self {
            let stream = TcpStream::connect(address).expect("connect");
            stream
                .set_read_timeout(Some(Duration::from_secs(10)))
                .expect("timeout");
            Self::over(stream, relay_public)
        }

        pub(crate) fn over(mut stream: TcpStream, relay_public: &[u8]) -> Self {
            let params: snow::params::NoiseParams = NOISE_PARAMS.parse().expect("params");
            let mut handshake = Builder::new(params)
                .remote_public_key(relay_public)
                .prologue(PROLOGUE)
                .build_initiator()
                .expect("initiator");
            let mut message = vec![0_u8; 1024];
            let written = handshake
                .write_message(b"{\"v\":1}", &mut message)
                .expect("message 1");
            let mut hello = b"CNS2".to_vec();
            hello.push(SESSION_VERSION);
            hello.extend_from_slice(&(written as u16).to_be_bytes());
            hello.extend_from_slice(&message[..written]);
            stream.write_all(&hello).expect("send hello");
            let mut length = [0_u8; 2];
            stream.read_exact(&mut length).expect("reply length");
            let mut reply = vec![0_u8; u16::from_be_bytes(length) as usize];
            stream.read_exact(&mut reply).expect("reply");
            let mut payload = vec![0_u8; 1024];
            let read = handshake
                .read_message(&reply, &mut payload)
                .expect("message 2");
            let hello: Value = serde_json::from_slice(&payload[..read]).expect("hello json");
            let handshake_hash = handshake.get_handshake_hash().to_vec();
            Self {
                stream,
                transport: handshake
                    .into_stateless_transport_mode()
                    .expect("transport"),
                send_nonce: 0,
                receive_nonce: 0,
                decoder: FrameDecoder::new(64 * 1024 * 1024),
                handshake_hash,
                hello,
            }
        }

        pub(crate) fn send(&mut self, kind: u8, stream: u32, payload: &[u8]) {
            let plain = encode_frame(kind, stream, payload);
            for chunk in plain.chunks(MAX_RECORD_PLAINTEXT) {
                let mut sealed = vec![0_u8; MAX_RECORD];
                let written = self
                    .transport
                    .write_message(self.send_nonce, chunk, &mut sealed)
                    .expect("seal");
                self.send_nonce += 1;
                self.stream
                    .write_all(&(written as u16).to_be_bytes())
                    .expect("send");
                self.stream.write_all(&sealed[..written]).expect("send");
            }
        }

        pub(crate) fn request(&mut self, stream: u32, value: &Value) {
            self.send(frame_type::REQUEST, stream, value.to_string().as_bytes());
        }

        /// The next frame, or none when the relay closed.
        pub(crate) fn next(&mut self) -> Option<Frame> {
            loop {
                if let Some(frame) = self.decoder.next_frame().expect("frame") {
                    return Some(frame);
                }
                let mut length = [0_u8; 2];
                if self.stream.read_exact(&mut length).is_err() {
                    return None;
                }
                let mut sealed = vec![0_u8; u16::from_be_bytes(length) as usize];
                if self.stream.read_exact(&mut sealed).is_err() {
                    return None;
                }
                let mut plain = vec![0_u8; MAX_RECORD];
                let read = self
                    .transport
                    .read_message(self.receive_nonce, &sealed, &mut plain)
                    .expect("open");
                self.receive_nonce += 1;
                self.decoder.push(&plain[..read]);
            }
        }

        pub(crate) fn next_json(&mut self) -> (Frame, Value) {
            let frame = self.next().expect("a frame");
            let value = serde_json::from_slice(&frame.payload).expect("json payload");
            (frame, value)
        }
    }

    pub(crate) fn relay_public(state: &RelayState) -> Vec<u8> {
        state.identity.noise_public.to_vec()
    }

    fn envelope(id: &str) -> Value {
        json!({
            "kind": "direct_message",
            "messageId": id,
            "senderDeviceId": "dev-a",
            "recipientDeviceId": "dev-b",
            "payloadBase64": "aGVsbG8="
        })
    }

    #[test]
    fn a_session_carries_v1_requests_in_flight_together() {
        let relay = start_tokio(parity_config());
        let mut client = TestClient::connect(relay.tcp, &relay_public(&relay.state));
        assert_eq!(client.hello["v"], 1);
        // A waiting fetch, then a store on the same session that wakes it.
        client.request(
            3,
            &json!({"action": "fetch", "recipient_device_id": "dev-s", "wait_ms": 5000}),
        );
        client.request(
            5,
            &json!({"action": "store", "recipient_device_id": "dev-s", "envelope": envelope("s1")}),
        );
        let mut answers = HashMap::new();
        for _ in 0..2 {
            let (frame, value) = client.next_json();
            assert_eq!(frame.kind, frame_type::RESPONSE);
            answers.insert(frame.stream, value);
        }
        assert_eq!(answers[&5]["stored"], true, "{answers:?}");
        assert_eq!(answers[&3]["messages"][0]["messageId"], "s1", "{answers:?}");
        // Health over the session advertises the session key.
        client.request(7, &json!({"action": "health"}));
        let (_, health) = client.next_json();
        assert_eq!(health["stats"]["v2"]["sessions"], 1);
        // Reserved types and unknown actions are refused, the session goes on.
        client.send(0x10, 9, b"");
        let (frame, value) = client.next_json();
        assert_eq!((frame.kind, frame.stream), (frame_type::RESPONSE, 9));
        assert_eq!(value["error"], "unsupported");
        client.request(11, &json!({"action": "nope"}));
        let (_, value) = client.next_json();
        assert_eq!(value["ok"], false);
        client.send(frame_type::PING, 0, b"hi");
        let frame = client.next().expect("pong");
        assert_eq!(
            (frame.kind, frame.payload),
            (frame_type::PONG, b"hi".to_vec())
        );
    }

    #[test]
    fn a_session_bounds_streams_and_frames() {
        let mut config = parity_config();
        config.ext.session_max_streams = 2;
        let relay = start_tokio(config);
        let mut client = TestClient::connect(relay.tcp, &relay_public(&relay.state));
        let wait = json!({"action": "fetch", "recipient_device_id": "dev-q", "wait_ms": 3000});
        client.request(1, &wait);
        client.request(1, &wait);
        let (frame, value) = client.next_json();
        assert_eq!(frame.stream, 1);
        assert_eq!(value["error"], "stream already in use");
        client.request(2, &wait);
        client.request(4, &wait);
        let (frame, value) = client.next_json();
        assert_eq!(frame.stream, 4);
        assert_eq!(value["error"], "too many requests in flight");
        // A frame over the limit ends the session.
        let mut header = Vec::new();
        header.extend_from_slice(&((DEFAULT_MAX_LINE + 8192) as u32).to_be_bytes());
        header.push(frame_type::REQUEST);
        header.extend_from_slice(&6_u32.to_be_bytes());
        client.send_raw_plain(&header);
        let mut ended = false;
        for _ in 0..4 {
            if client.next().is_none() {
                ended = true;
                break;
            }
        }
        assert!(ended, "the session went on after an oversized frame");
    }

    const DEFAULT_MAX_LINE: usize = crate::config::DEFAULT_MAX_LINE_BYTES;

    impl TestClient {
        /// Sends [plain] as one record, whatever it holds.
        fn send_raw_plain(&mut self, plain: &[u8]) {
            let mut sealed = vec![0_u8; MAX_RECORD];
            let written = self
                .transport
                .write_message(self.send_nonce, plain, &mut sealed)
                .expect("seal");
            self.send_nonce += 1;
            self.stream
                .write_all(&(written as u16).to_be_bytes())
                .expect("send");
            self.stream.write_all(&sealed[..written]).expect("send");
        }
    }

    #[test]
    fn a_subscription_pushes_stores_and_ends_with_the_session() {
        let relay = start_tokio(parity_config());
        let mut client = TestClient::connect(relay.tcp, &relay_public(&relay.state));
        client.request(
            1,
            &json!({"action": "subscribe", "mailboxes": ["dev-sub", "dev-sub2"], "lease_ms": 30000}),
        );
        let (frame, started) = client.next_json();
        assert_eq!((frame.kind, frame.stream), (frame_type::EVENT, 1));
        assert_eq!(started["subscribed"], json!(["dev-sub", "dev-sub2"]));
        // A store from another connection is pushed.
        let mut other = TestClient::connect(relay.tcp, &relay_public(&relay.state));
        other.request(
            1,
            &json!({"action": "store", "recipient_device_id": "dev-sub2", "envelope": envelope("p1")}),
        );
        let (_, stored) = other.next_json();
        assert_eq!(stored["stored"], true);
        let (frame, pushed) = client.next_json();
        assert_eq!((frame.kind, frame.stream), (frame_type::EVENT, 1));
        assert_eq!(pushed["mailbox"], "dev-sub2");
        assert_eq!(pushed["messages"][0]["messageId"], "p1");
        let lease = pushed["lease_id"].as_str().expect("leased").to_owned();
        client.request(
            3,
            &json!({"action": "ack_lease", "recipient_device_id": "dev-sub2", "lease_id": lease}),
        );
        let (frame, acked) = client.next_json();
        assert_eq!(
            (frame.kind, frame.stream, acked["ok"].clone()),
            (frame_type::RESPONSE, 3, json!(true))
        );
        assert_eq!(relay.state.stats().queued_envelope_count, 0);
        // Cancelled, it pushes no more.
        client.send(frame_type::CANCEL, 1, b"");
        // Closed, its watchers go and the mailbox signals are pruned.
        drop(client);
        let started = std::time::Instant::now();
        loop {
            if relay.state.notifiers.lock().expect("lock").is_empty() {
                break;
            }
            assert!(
                started.elapsed() < Duration::from_secs(5),
                "signals stayed after the session ended"
            );
            std::thread::sleep(Duration::from_millis(50));
        }
    }

    #[test]
    fn a_subscription_on_pairing_announcements_waits_instead_of_spinning() {
        let relay = start_tokio(parity_config());
        let announcement = |id: &str| {
            let mut value = envelope(id);
            value["kind"] = json!("pairing_announcement");
            value["senderDeviceId"] = json!(format!("dev-{id}"));
            value
        };
        for index in 0..3 {
            relay
                .state
                .store(
                    "pair-watch".to_owned(),
                    announcement(&format!("pair-{index}")),
                )
                .expect("stored");
        }
        let mut client = TestClient::connect(relay.tcp, &relay_public(&relay.state));
        client.request(
            1,
            &json!({"action": "subscribe", "mailboxes": ["pair-watch"], "limit": 1}),
        );
        let (_, started) = client.next_json();
        assert_eq!(started["subscribed"], json!(["pair-watch"]));
        // The announcements stay queued (they are never leased) and are
        // pushed once each; then the watcher waits instead of re-reading.
        std::thread::sleep(Duration::from_millis(1500));
        let reads = relay
            .state
            .queue_reads
            .load(std::sync::atomic::Ordering::Relaxed);
        assert!(reads < 20, "the watcher spun: {reads} queue reads in 1.5 s");
        // A real message behind the announcements still arrives.
        let mut other = TestClient::connect(relay.tcp, &relay_public(&relay.state));
        other.request(
            1,
            &json!({"action": "store", "recipient_device_id": "pair-watch", "envelope": envelope("real-1")}),
        );
        let _ = other.next_json();
        let mut seen = false;
        for _ in 0..8 {
            let (_, event) = client.next_json();
            if event["messages"]
                .as_array()
                .is_some_and(|all| all.iter().any(|m| m["messageId"] == "real-1"))
            {
                seen = true;
                break;
            }
        }
        assert!(seen, "the real message was starved by the announcements");
    }

    #[test]
    fn padding_does_not_keep_a_session_alive() {
        let mut config = parity_config();
        config.ext.session_idle = Duration::from_secs(1);
        let relay = start_tokio(config);
        let mut client = TestClient::connect(relay.tcp, &relay_public(&relay.state));
        // Padding every 200 ms for 2.5 s: past the idle limit.
        for _ in 0..12 {
            std::thread::sleep(Duration::from_millis(200));
            let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                client.send(frame_type::PAD, 0, &[0_u8; 16]);
            }));
        }
        client
            .stream
            .set_read_timeout(Some(Duration::from_secs(2)))
            .expect("timeout");
        let mut chunk = [0_u8; 256];
        let mut closed = false;
        for _ in 0..20 {
            match client.stream.read(&mut chunk) {
                Ok(0) | Err(_) => {
                    closed = true;
                    break;
                }
                Ok(_) => {}
            }
        }
        assert!(closed, "the session outlived its idle limit on padding");
    }

    #[test]
    fn a_session_against_the_wrong_key_fails() {
        let relay = start_tokio(parity_config());
        let wrong = RelayIdentity::from_seed_bytes([9_u8; 32]);
        let mut stream = TcpStream::connect(relay.tcp).expect("connect");
        stream
            .set_read_timeout(Some(Duration::from_secs(5)))
            .expect("timeout");
        let params: snow::params::NoiseParams = NOISE_PARAMS.parse().expect("params");
        let mut handshake = Builder::new(params)
            .remote_public_key(&wrong.noise_public)
            .prologue(PROLOGUE)
            .build_initiator()
            .expect("initiator");
        let mut message = vec![0_u8; 1024];
        let written = handshake
            .write_message(b"", &mut message)
            .expect("message 1");
        let mut hello = b"CNS2".to_vec();
        hello.push(SESSION_VERSION);
        hello.extend_from_slice(&(written as u16).to_be_bytes());
        hello.extend_from_slice(&message[..written]);
        stream.write_all(&hello).expect("send");
        let mut reply = [0_u8; 2];
        assert!(
            stream.read_exact(&mut reply).is_err(),
            "the relay answered a handshake for another key"
        );
    }
}
