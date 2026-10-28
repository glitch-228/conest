//! Protocol v1: one JSON request per line (over TCP, UDP or an HTTP
//! POST), answered with one JSON response, optionally signed.

use std::net::SocketAddr;

use base64::Engine;
use base64::engine::general_purpose::STANDARD as BASE64_STANDARD;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::config::{UDP_COOKIE_REQUEST_MIN_BYTES, now_millis};
use crate::identity::RelayIdentity;
use crate::limits::{PeerSlot, peer_key};
use crate::storage::RelayState;

#[derive(Debug, Deserialize)]
#[serde(tag = "action", rename_all = "snake_case")]
pub(crate) enum RelayRequest {
    Store {
        recipient_device_id: String,
        envelope: Value,
    },
    Fetch {
        recipient_device_id: String,
        limit: Option<usize>,
        /// Long-poll duration in milliseconds. When non-zero and the
        /// recipient mailbox is empty, the relay blocks the request thread
        /// on a per-mailbox Condvar for up to `wait_ms` (capped at
        /// `LONG_POLL_MAX_WAIT_MS`) and returns as soon as a new envelope
        /// arrives via [`store`]. Older clients omit the field — the relay
        /// behaves exactly like before for them.
        wait_ms: Option<u64>,
    },
    /// Durable v2 fetch. Messages remain in SQLite under a lease until the
    /// client explicitly acknowledges the returned lease id. A relay restart
    /// releases all outstanding leases back to their mailboxes.
    FetchLeased {
        recipient_device_id: String,
        limit: Option<usize>,
        wait_ms: Option<u64>,
        lease_ms: Option<u64>,
    },
    AckLease {
        recipient_device_id: String,
        lease_id: String,
    },
    Health,
}

pub(crate) const LONG_POLL_MAX_WAIT_MS: u64 = 25_000;

#[derive(Debug, Serialize)]
#[cfg_attr(test, derive(Deserialize))]
pub(crate) struct RelayStats {
    pub(crate) relay_id: String,
    pub(crate) version: String,
    pub(crate) queue_count: usize,
    pub(crate) queued_envelope_count: usize,
    pub(crate) queued_bytes: u64,
    pub(crate) active_leases: usize,
    pub(crate) ttl_seconds: u64,
    pub(crate) max_queue_per_mailbox: usize,
    pub(crate) max_fetch_limit: usize,
    pub(crate) identity_public_key: String,
    /// What this relay offers beyond v1 (sessions and their key, signed by
    /// the identity); absent on relays without them.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) v2: Option<Value>,
}

#[derive(Debug, Serialize)]
#[cfg_attr(test, derive(Deserialize))]
pub(crate) struct RelayResponse {
    pub(crate) ok: bool,
    pub(crate) stored: bool,
    pub(crate) messages: Vec<Value>,
    pub(crate) error: Option<String>,
    pub(crate) stats: Option<RelayStats>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) nonce_echo: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) signature: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) lease_id: Option<String>,
}

impl RelayResponse {
    pub(crate) fn ok(stats: Option<RelayStats>) -> Self {
        Self {
            ok: true,
            stored: false,
            messages: Vec::new(),
            error: None,
            stats,
            nonce_echo: None,
            signature: None,
            lease_id: None,
        }
    }

    pub(crate) fn stored() -> Self {
        Self {
            ok: true,
            stored: true,
            messages: Vec::new(),
            error: None,
            stats: None,
            nonce_echo: None,
            signature: None,
            lease_id: None,
        }
    }

    pub(crate) fn messages(messages: Vec<Value>) -> Self {
        Self {
            ok: true,
            stored: false,
            messages,
            error: None,
            stats: None,
            nonce_echo: None,
            signature: None,
            lease_id: None,
        }
    }

    pub(crate) fn error(message: impl Into<String>) -> Self {
        Self {
            ok: false,
            stored: false,
            messages: Vec::new(),
            error: Some(message.into()),
            stats: None,
            nonce_echo: None,
            signature: None,
            lease_id: None,
        }
    }

    pub(crate) fn leased(messages: Vec<Value>, lease_id: Option<String>) -> Self {
        Self {
            ok: true,
            stored: false,
            messages,
            error: None,
            stats: None,
            nonce_echo: None,
            signature: None,
            lease_id,
        }
    }
}

pub(crate) fn handle_udp_datagram(
    datagram: &[u8],
    bytes_read: usize,
    state: &RelayState,
    peer: SocketAddr,
) -> Value {
    // Kept apart from TCP and HTTP: a forged source spends only the UDP
    // budget of the address it names.
    let key = format!("udp:{}", peer_key(peer.ip()));
    // The cookie is the full address's (budgets go by /64): a neighbour in
    // the same /64 cannot aim answers at another host.
    let cookie_peer = format!("udp-cookie:{}", peer.ip());
    handle_request_from(datagram, bytes_read, state, &key, Some(&cookie_peer))
}

pub(crate) fn handle_request_bytes(
    bytes: &[u8],
    bytes_read: usize,
    state: &RelayState,
    peer: &str,
) -> Value {
    handle_request_from(bytes, bytes_read, state, peer, None)
}

/// One request from [peer]; over UDP, [cookie_peer] is the full address
/// its cookie is for.
pub(crate) fn handle_request_from(
    bytes: &[u8],
    bytes_read: usize,
    state: &RelayState,
    peer: &str,
    cookie_peer: Option<&str>,
) -> Value {
    match prepare_request(bytes, bytes_read, state, peer, cookie_peer, None) {
        Prepared::Done(value) => value,
        Prepared::Run(prepared) => {
            let PreparedRequest {
                request,
                action,
                nonce,
                detached,
                long_poll,
            } = prepared;
            let response = handle_request_for(request, state, peer);
            drop(long_poll);
            finalize_wire(
                response,
                &action,
                nonce.as_deref(),
                detached,
                &state.identity,
            )
        }
    }
}

/// [handle_request_from] for the tokio server (TCP and HTTP; never UDP):
/// a waiting fetch holds no thread, and the database is reached from a
/// blocking task.
pub(crate) async fn handle_request_async(
    bytes: &[u8],
    bytes_read: usize,
    state: &RelayState,
    peer: &str,
) -> Value {
    match prepare_request(bytes, bytes_read, state, peer, None, None) {
        Prepared::Done(value) => value,
        Prepared::Run(prepared) => {
            let PreparedRequest {
                request,
                action,
                nonce,
                detached,
                long_poll,
            } = prepared;
            let response = execute_async(request, state, peer).await;
            drop(long_poll);
            finalize_wire(
                response,
                &action,
                nonce.as_deref(),
                detached,
                &state.identity,
            )
        }
    }
}

/// Runs [request] from [source] on the tokio server.
pub(crate) async fn execute_async(
    request: RelayRequest,
    state: &RelayState,
    source: &str,
) -> RelayResponse {
    match request {
        RelayRequest::Fetch {
            recipient_device_id,
            limit,
            wait_ms,
        } => match state.fetch_async(recipient_device_id, limit, wait_ms).await {
            Ok(messages) => RelayResponse::messages(messages),
            Err(error) => RelayResponse::error(error),
        },
        RelayRequest::FetchLeased {
            recipient_device_id,
            limit,
            wait_ms,
            lease_ms,
        } => match state
            .fetch_leased_async(recipient_device_id, limit, wait_ms, lease_ms)
            .await
        {
            Ok((messages, lease_id)) => RelayResponse::leased(messages, lease_id),
            Err(error) => RelayResponse::error(error),
        },
        other => {
            let source = source.to_owned();
            state
                .blocking(move |state| handle_request_for(other, state, &source))
                .await
                .unwrap_or_else(|error| RelayResponse::error(error))
        }
    }
}

/// A request that passed its budgets, ready to run.
pub(crate) struct PreparedRequest {
    pub(crate) request: RelayRequest,
    pub(crate) action: String,
    pub(crate) nonce: Option<Vec<u8>>,
    pub(crate) detached: bool,
    /// The long-poll slot a waiting fetch holds while it runs.
    pub(crate) long_poll: Option<PeerSlot>,
}

pub(crate) enum Prepared {
    /// Answered already (refused, invalid, or a UDP cookie).
    Done(Value),
    Run(PreparedRequest),
}

/// Checks one request from [peer] against its budgets and parses it; over
/// UDP, [cookie_peer] is the full address its cookie is for.
pub(crate) fn prepare_request(
    bytes: &[u8],
    bytes_read: usize,
    state: &RelayState,
    peer: &str,
    cookie_peer: Option<&str>,
    session: Option<&dyn Fn(&str) -> bool>,
) -> Prepared {
    let datagram = cookie_peer.is_some();
    // Over UDP nothing goes back for a refusal (a forged source must get
    // nothing back at all).
    let refuse = |message: String| -> Prepared {
        if datagram {
            Prepared::Done(Value::Null)
        } else {
            Prepared::Done(to_wire(RelayResponse::error(message)))
        }
    };
    if bytes_read > state.config.max_line_bytes {
        return refuse("request line too large".to_owned());
    }
    if !state.allow_request_banning(peer, !datagram) {
        return refuse("rate limit exceeded".to_owned());
    }
    let line = match std::str::from_utf8(bytes) {
        Ok(value) => value,
        Err(error) => return refuse(format!("request is not utf-8: {error}")),
    };
    let trimmed = line.trim();
    // Parse once into a Value so we can extract optional out-of-band fields
    // (like `nonce`) before deserializing into the typed request enum. New
    // clients pass `"nonce": "<base64-16-bytes>"` alongside the action;
    // legacy clients omit it and receive an unsigned response.
    let parsed: Value = match serde_json::from_str(trimmed) {
        Ok(value) => value,
        Err(error) => return refuse(format!("invalid request: {error}")),
    };
    let action = parsed
        .get("action")
        .and_then(|value| value.as_str())
        .unwrap_or("")
        .to_owned();
    let nonce_bytes = parsed
        .get("nonce")
        .and_then(|value| value.as_str())
        .and_then(|encoded| BASE64_STANDARD.decode(encoded).ok());
    let detached = parsed.get("sig_mode").and_then(|value| value.as_str()) == Some("detached");
    let cookie = parsed
        .get("cookie")
        .and_then(|value| value.as_str())
        .map(str::to_owned);
    let nonce_text = parsed
        .get("nonce")
        .and_then(|value| value.as_str())
        .map(str::to_owned);
    let auth = parsed.get("auth").cloned();
    // A bearer token is only ever honoured inside an encrypted session:
    // over cleartext v1 (TCP, UDP, HTTP) anyone on the path could lift it.
    let token = parsed
        .get("token")
        .and_then(|value| value.as_str())
        .map(str::to_owned)
        .filter(|_| session.is_some());
    let mut request: RelayRequest = match serde_json::from_value(parsed) {
        Ok(request) => request,
        Err(error) if datagram => return refuse(format!("invalid request: {error}")),
        Err(error) => {
            return Prepared::Done(finalize_wire(
                RelayResponse::error(format!("invalid request: {error}")),
                &action,
                nonce_bytes.as_deref(),
                detached,
                &state.identity,
            ));
        }
    };
    // Over UDP every request first needs the cookie only a client at that
    // address receives (what it changes is counted to that address, and
    // what answers at length cannot be aimed elsewhere). The cookie itself
    // goes back only to a request at least as long as the answer.
    if let Some(cookie_peer) = cookie_peer
        && !state.valid_udp_cookie(cookie_peer, cookie.as_deref())
    {
        if bytes_read < UDP_COOKIE_REQUEST_MIN_BYTES {
            return Prepared::Done(Value::Null);
        }
        return Prepared::Done(serde_json::json!({
            "ok": false,
            "error": "udp cookie required",
            "cookie": state.udp_cookie(cookie_peer, now_millis() / 60_000),
        }));
    }
    // The heavier budget, now that the kind of request is known.
    let heavy = datagram || matches!(request, RelayRequest::Store { .. });
    let stored_bytes = if matches!(request, RelayRequest::Store { .. }) {
        bytes_read as u64
    } else {
        0
    };
    if heavy && !state.allow_store(peer, stored_bytes) {
        if datagram {
            return refuse("rate limit exceeded".to_owned());
        }
        return Prepared::Done(finalize_wire(
            RelayResponse::error("rate limit exceeded"),
            &action,
            nonce_bytes.as_deref(),
            detached,
            &state.identity,
        ));
    }
    // Tier 1's policy: open, registered accounts only, or off.
    if matches!(request, RelayRequest::Store { .. })
        && let Err(message) = state.admit_store(token.as_deref(), stored_bytes)
    {
        if datagram {
            return refuse(message);
        }
        return Prepared::Done(finalize_wire(
            RelayResponse::error(message),
            &action,
            nonce_bytes.as_deref(),
            detached,
            &state.identity,
        ));
    }
    // A claimed mailbox needs its owner's proof (owners.rs).
    if let Err(message) = state.authorize_request(
        &request,
        &action,
        auth.as_ref(),
        nonce_text.as_deref(),
        session,
        peer,
    ) {
        return Prepared::Done(finalize_wire(
            RelayResponse::error(message),
            &action,
            nonce_bytes.as_deref(),
            detached,
            &state.identity,
        ));
    }
    // A long-poll over this address's share is answered at once instead;
    // over UDP none waits (one thread serves every datagram).
    let long_poll = match &mut request {
        RelayRequest::Fetch { wait_ms, .. } | RelayRequest::FetchLeased { wait_ms, .. }
            if wait_ms.unwrap_or(0) > 0 =>
        {
            let slot = if datagram {
                None
            } else {
                state.long_poll_slot(peer)
            };
            if slot.is_none() {
                *wait_ms = Some(0);
            }
            slot
        }
        _ => None,
    };
    Prepared::Run(PreparedRequest {
        request,
        action,
        nonce: nonce_bytes,
        detached,
        long_poll,
    })
}

/// Serializes a response for the wire. Infallible by construction; the
/// fallback shape only exists so a serialization bug cannot crash the relay.
pub(crate) fn to_wire(response: RelayResponse) -> Value {
    serde_json::to_value(&response)
        .unwrap_or_else(|_| serde_json::json!({"ok": false, "error": "response encoding failed"}))
}

pub(crate) fn finalize_wire(
    response: RelayResponse,
    action: &str,
    nonce_bytes: Option<&[u8]>,
    detached: bool,
    identity: &RelayIdentity,
) -> Value {
    match (detached, nonce_bytes) {
        (true, Some(nonce)) => finalize_detached_response(response, action, nonce, identity),
        _ => to_wire(finalize_response(response, action, nonce_bytes, identity)),
    }
}

/// Detached-signature wire format, requested via `"sig_mode": "detached"`
/// alongside the nonce. The response body is serialized exactly once,
/// signed over those bytes, and transmitted as a JSON *string* inside a
/// small wrapper:
///
/// ```json
/// {"sig_v":2,"body":"<body JSON>","nonce_echo":"…","signature":"…"}
/// ```
///
/// The client verifies Ed25519 over `action || nonce || body-string-bytes`
/// before parsing the body, so verification no longer depends on the
/// client's JSON encoder reproducing serde's output byte-for-byte (field
/// order, float formatting, large integers — the inline scheme silently
/// degrades to "unsigned" the moment any of those diverge).
pub(crate) fn finalize_detached_response(
    response: RelayResponse,
    action: &str,
    nonce: &[u8],
    identity: &RelayIdentity,
) -> Value {
    let body = match serde_json::to_string(&response) {
        Ok(body) => body,
        Err(_) => return to_wire(RelayResponse::error("response encoding failed")),
    };
    let mut signing_input = Vec::with_capacity(action.len() + nonce.len() + body.len());
    signing_input.extend_from_slice(action.as_bytes());
    signing_input.extend_from_slice(nonce);
    signing_input.extend_from_slice(body.as_bytes());
    let signature = identity.sign(&signing_input);
    serde_json::json!({
        "sig_v": 2,
        "body": body,
        "nonce_echo": BASE64_STANDARD.encode(nonce),
        "signature": BASE64_STANDARD.encode(signature),
    })
}

pub(crate) fn handle_request(request: RelayRequest, state: &RelayState) -> RelayResponse {
    handle_request_for(request, state, "")
}

/// [request] from [source] (an address key; empty for none).
pub(crate) fn handle_request_for(
    request: RelayRequest,
    state: &RelayState,
    source: &str,
) -> RelayResponse {
    match request {
        RelayRequest::Store {
            recipient_device_id,
            envelope,
        } => match state.store_from(source, recipient_device_id, envelope) {
            Ok(()) => RelayResponse::stored(),
            Err(error) => RelayResponse::error(error),
        },
        RelayRequest::Fetch {
            recipient_device_id,
            limit,
            wait_ms,
        } => match state.fetch(&recipient_device_id, limit, wait_ms) {
            Ok(messages) => RelayResponse::messages(messages),
            Err(error) => RelayResponse::error(error),
        },
        RelayRequest::FetchLeased {
            recipient_device_id,
            limit,
            wait_ms,
            lease_ms,
        } => match state.fetch_leased(&recipient_device_id, limit, wait_ms, lease_ms) {
            Ok((messages, lease_id)) => RelayResponse::leased(messages, lease_id),
            Err(error) => RelayResponse::error(error),
        },
        RelayRequest::AckLease {
            recipient_device_id,
            lease_id,
        } => match state.acknowledge_lease(&recipient_device_id, &lease_id) {
            Ok(()) => RelayResponse::ok(None),
            Err(error) => RelayResponse::error(error),
        },
        RelayRequest::Health => RelayResponse::ok(Some(state.stats())),
    }
}

/// Attaches `nonce_echo` + `signature` to a response when the request
/// supplied a nonce. The signing input is `action || nonce || canonical_body`,
/// where `canonical_body` is the JSON serialization of the response with
/// both `nonce_echo` and `signature` set to `None` (and thus omitted by
/// the `skip_serializing_if = "Option::is_none"` markers). Legacy clients
/// that omit `nonce` receive the response unchanged — the signature is
/// opt-in so old releases keep working.
pub(crate) fn finalize_response(
    mut response: RelayResponse,
    action: &str,
    nonce_bytes: Option<&[u8]>,
    identity: &RelayIdentity,
) -> RelayResponse {
    let Some(nonce) = nonce_bytes else {
        return response;
    };
    response.nonce_echo = None;
    response.signature = None;
    let body = match serde_json::to_vec(&response) {
        Ok(bytes) => bytes,
        Err(_) => {
            // Should never fail given the response is a fixed shape, but
            // don't crash the relay if it does.
            return response;
        }
    };
    let mut signing_input = Vec::with_capacity(action.len() + nonce.len() + body.len());
    signing_input.extend_from_slice(action.as_bytes());
    signing_input.extend_from_slice(nonce);
    signing_input.extend_from_slice(&body);
    let signature = identity.sign(&signing_input);
    response.nonce_echo = Some(BASE64_STANDARD.encode(nonce));
    response.signature = Some(BASE64_STANDARD.encode(signature));
    response
}

pub(crate) fn envelope_kind(envelope: &Value) -> Option<&str> {
    envelope.get("kind")?.as_str()
}

pub(crate) fn envelope_sender_device_id(envelope: &Value) -> Option<&str> {
    envelope.get("senderDeviceId")?.as_str()
}

pub(crate) fn validate_mailbox_id(value: &str) -> Result<(), String> {
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
