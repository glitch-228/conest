//! The Conest relay: a store-and-forward mailbox server.
//!
//! Modules: `config` (defaults, environment, flags), `storage` (the SQLite
//! queue), `limits` (budgets), `v1` (the JSON line protocol), `http` (its
//! HTTP form), `server` (the tokio server) and `legacy` (the old threaded
//! server, kept behind `--legacy-threads`).

mod borrowed;
mod config;
mod http;
mod identity;
mod legacy;
mod limits;
mod outer;
mod owners;
mod registration;
mod server;
mod session;
mod storage;
mod udp_sealed;
mod v1;

#[cfg(test)]
mod parity_tests;

use std::env;
use std::thread;

#[allow(unused_imports)]
use config::*;
#[allow(unused_imports)]
use http::*;
#[allow(unused_imports)]
use identity::*;
#[allow(unused_imports)]
use legacy::*;
#[allow(unused_imports)]
use limits::*;
#[allow(unused_imports)]
use storage::*;
#[allow(unused_imports)]
use v1::*;

// What the v1 tests below use from the standard library and dependencies.
#[cfg(test)]
use base64::Engine;
#[cfg(test)]
use base64::engine::general_purpose::STANDARD as BASE64_STANDARD;
#[cfg(test)]
use serde_json::Value;
#[cfg(test)]
use std::fs;
#[cfg(test)]
use std::io::{BufReader, Write};
#[cfg(test)]
use std::net::SocketAddr;
#[cfg(test)]
use std::path::PathBuf;
#[cfg(test)]
use std::sync::Arc;
#[cfg(test)]
use std::time::Duration;

fn main() -> std::io::Result<()> {
    if env::args().nth(1).as_deref() == Some("admin") {
        let rest: Vec<String> = env::args().skip(2).collect();
        let (database, words) = match rest.iter().position(|arg| arg == "--database-path") {
            Some(index) if index + 1 < rest.len() => {
                let mut words = rest.clone();
                let path = words.remove(index + 1);
                words.remove(index);
                (std::path::PathBuf::from(path), words)
            }
            _ => (
                std::path::PathBuf::from(
                    env::var("CONEST_RELAY_DATABASE_PATH")
                        .unwrap_or_else(|_| DEFAULT_DATABASE_PATH.to_owned()),
                ),
                rest,
            ),
        };
        match registration::admin(&database, &words) {
            Ok(output) => {
                println!("{output}");
                return Ok(());
            }
            Err(message) => {
                eprintln!("{message}");
                std::process::exit(2);
            }
        }
    }
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
    let identity = match RelayIdentity::load_or_generate(&config) {
        Ok(identity) => identity,
        Err(message) => {
            eprintln!("relay identity setup failed: {message}");
            std::process::exit(2);
        }
    };
    let listener = std::net::TcpListener::bind(&config.bind)?;
    let udp_socket = std::net::UdpSocket::bind(&config.bind)?;
    let identity_public_key = identity.public_key_b64.clone();
    let state = match RelayState::try_new(config.clone(), identity) {
        Ok(state) => state,
        Err(message) => {
            eprintln!("relay database setup failed: {message}");
            std::process::exit(2);
        }
    };
    println!(
        "conest relay listening on tcp+udp {} id={} ttl={}s max_queue={} max_fetch={} max_envelope={}B max_rate={}/min identity_pub={} server={}",
        config.bind,
        config.relay_id,
        config.ttl.as_secs(),
        config.max_queue_per_mailbox,
        config.max_fetch_limit,
        config.max_envelope_bytes,
        config.max_requests_per_minute,
        identity_public_key,
        if config.ext.legacy_threads {
            "threads"
        } else {
            "tokio"
        },
    );

    {
        let state = state.clone();
        let config = config.clone();
        thread::spawn(move || serve_udp(udp_socket, state, config));
    }

    if config.ext.legacy_threads {
        if config.ext.tls_bind.is_some() || config.ext.borrow_bind.is_some() {
            eprintln!("TLS needs the tokio server: drop --legacy-threads");
            std::process::exit(2);
        }
        return legacy::run(listener, state);
    }
    let tls = match &config.ext.tls_bind {
        Some(bind) => {
            let layer = match outer::tls_layer(&state) {
                Ok(Some(layer)) => layer,
                Ok(None) => {
                    eprintln!("--tls-bind needs --tls-cert and --tls-key");
                    std::process::exit(2);
                }
                Err(message) => {
                    eprintln!("TLS setup failed: {message}");
                    std::process::exit(2);
                }
            };
            let tls_listener = std::net::TcpListener::bind(bind)?;
            tls_listener.set_nonblocking(true)?;
            println!(
                "conest relay TLS on {bind}, WebSocket path {}",
                state.ws_path().unwrap_or_default()
            );
            Some((tls_listener, layer))
        }
        None => None,
    };
    let borrowed = match (&config.ext.borrow_bind, &config.ext.borrow_site) {
        (Some(bind), Some(site)) => {
            let listener = std::net::TcpListener::bind(bind)?;
            listener.set_nonblocking(true)?;
            println!("conest relay borrowing the handshake of {site} on {bind}");
            let (secret, public) =
                borrowed::key_pair_from_seed(&state.identity.signing_key.to_bytes());
            let layer = borrowed::BorrowedLayer::new(site.clone(), secret, public);
            Some((listener, layer))
        }
        _ => None,
    };
    listener.set_nonblocking(true)?;
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()?;
    runtime.block_on(async move {
        if let Some((borrowed_listener, layer)) = borrowed {
            let borrowed_listener = tokio::net::TcpListener::from_std(borrowed_listener)?;
            let state = state.clone();
            tokio::spawn(async move {
                if let Err(error) =
                    outer::serve_outer(borrowed_listener, std::sync::Arc::new(layer), state).await
                {
                    eprintln!("relay borrowed-handshake listener stopped: {error}");
                }
            });
        }
        if let Some((tls_listener, layer)) = tls {
            let tls_listener = tokio::net::TcpListener::from_std(tls_listener)?;
            let state = state.clone();
            tokio::spawn(async move {
                if let Err(error) =
                    outer::serve_outer(tls_listener, std::sync::Arc::new(layer), state).await
                {
                    eprintln!("relay TLS listener stopped: {error}");
                }
            });
        }
        let listener = tokio::net::TcpListener::from_std(listener)?;
        server::serve(listener, state).await
    })
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

    fn test_identity() -> RelayIdentity {
        // Fixed seed so signing input ↔ signature is deterministic across runs.
        RelayIdentity::from_seed_bytes([7_u8; 32])
    }

    fn test_state() -> RelayState {
        RelayState::new(test_config(), test_identity())
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
        let state = RelayState::new(test_config(), test_identity());
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
            .fetch("pair-mailbox", Some(8), None)
            .expect("fetch should work");
        let second = state
            .fetch("pair-mailbox", Some(8), None)
            .expect("fetch should work");

        assert_eq!(first.len(), 1);
        assert_eq!(first[0]["messageId"], "pair-2");
        assert_eq!(second.len(), 1);
        assert_eq!(second[0]["messageId"], "pair-2");
    }

    #[test]
    fn non_pairing_envelopes_are_consumed_and_fetch_limit_is_clamped() {
        let state = RelayState::new(test_config(), test_identity());
        for index in 0..3 {
            state
                .store(
                    "dev-b".to_owned(),
                    envelope("direct_message", &format!("msg-{index}"), "dev-a"),
                )
                .expect("store should work");
        }

        let first = state
            .fetch("dev-b", Some(99), None)
            .expect("fetch should work");
        let second = state
            .fetch("dev-b", Some(99), None)
            .expect("fetch should work");

        assert_eq!(first.len(), 2);
        assert_eq!(second.len(), 1);
    }

    #[test]
    fn pairing_cap_bounds_flood_with_forged_sender_ids() {
        // senderDeviceId is client-controlled: dedup-by-sender alone cannot
        // bound the queue against an attacker rotating fake sender ids.
        let mut config = test_config();
        config.max_queue_per_mailbox = 64;
        config.max_fetch_limit = 64;
        let state = RelayState::new(config, test_identity());
        for index in 0..13 {
            state
                .store(
                    "pair-mailbox".to_owned(),
                    envelope(
                        "pairing_announcement",
                        &format!("pair-{index}"),
                        &format!("dev-forged-{index}"),
                    ),
                )
                .expect("store should work");
        }

        let fetched = state
            .fetch("pair-mailbox", Some(64), None)
            .expect("fetch should work");
        assert_eq!(fetched.len(), MAX_PAIRING_PER_MAILBOX);
        let ids: Vec<&str> = fetched
            .iter()
            .filter_map(|value| value["messageId"].as_str())
            .collect();
        // Oldest entries were evicted first; the newest cap-sized window stays.
        assert_eq!(ids[0], "pair-5");
        assert_eq!(ids[MAX_PAIRING_PER_MAILBOX - 1], "pair-12");
    }

    #[test]
    fn pairing_flood_does_not_evict_real_messages() {
        let mut config = test_config();
        config.max_queue_per_mailbox = 10;
        config.max_fetch_limit = 16;
        let state = RelayState::new(config, test_identity());
        for index in 0..2 {
            state
                .store(
                    "dev-b".to_owned(),
                    envelope("direct_message", &format!("msg-{index}"), "dev-a"),
                )
                .expect("store should work");
        }
        for index in 0..20 {
            state
                .store(
                    "dev-b".to_owned(),
                    envelope(
                        "pairing_announcement",
                        &format!("pair-{index}"),
                        &format!("dev-forged-{index}"),
                    ),
                )
                .expect("store should work");
        }

        let fetched = state
            .fetch("dev-b", Some(16), None)
            .expect("fetch should work");
        let ids: Vec<&str> = fetched
            .iter()
            .filter_map(|value| value["messageId"].as_str())
            .collect();
        assert!(ids.contains(&"msg-0"), "real message evicted: {ids:?}");
        assert!(ids.contains(&"msg-1"), "real message evicted: {ids:?}");
        assert_eq!(
            ids.iter().filter(|id| id.starts_with("pair-")).count(),
            MAX_PAIRING_PER_MAILBOX,
        );
    }

    #[test]
    fn queue_limit_drops_oldest_non_pairing_envelopes() {
        let state = RelayState::new(test_config(), test_identity());
        for index in 0..4 {
            state
                .store(
                    "dev-b".to_owned(),
                    envelope("direct_message", &format!("msg-{index}"), "dev-a"),
                )
                .expect("store should work");
        }

        let fetched = state
            .fetch("dev-b", Some(10), None)
            .expect("fetch should work");
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
        let state = RelayState::new(test_config(), test_identity());
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

        let _ = store;
        let stored = udp_with_cookie(
            &state,
            peer,
            json!({
                "action": "store",
                "recipient_device_id": "dev-b",
                "envelope": envelope("direct_message", "msg-udp", "dev-a")
            }),
        );
        let fetched = udp_with_cookie(
            &state,
            peer,
            json!({
                "action": "fetch",
                "recipient_device_id": "dev-b",
                "limit": 4
            }),
        );
        let _ = fetch;

        assert_eq!(stored["ok"], true);
        assert_eq!(stored["stored"], true);
        let messages = fetched["messages"].as_array().expect("messages array");
        assert_eq!(messages.len(), 1);
        assert_eq!(messages[0]["messageId"], "msg-udp");
    }

    #[test]
    fn http_post_handler_uses_same_relay_protocol() {
        let state = RelayState::new(test_config(), test_identity());
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
        assert_eq!(stored["ok"], true);
        assert_eq!(stored["stored"], true);
        assert_eq!(fetch_status, 200);
        let messages = fetched["messages"].as_array().expect("messages array");
        assert_eq!(messages.len(), 1);
        assert_eq!(messages[0]["messageId"], "msg-http");
    }

    #[test]
    fn http_get_health_reports_relay_instance_id() {
        let state = RelayState::new(test_config(), test_identity());
        let mut reader = BufReader::new("Host: relay.test\r\n\r\n".as_bytes());
        let (status, response) =
            handle_http_request("GET /health HTTP/1.1\r\n", &mut reader, &state, "127.0.0.1");

        assert_eq!(status, 200);
        assert_eq!(response["ok"], true);
        assert_eq!(response["stats"]["relay_id"], "relay-test");
    }

    #[test]
    fn health_reports_relay_instance_id() {
        let state = RelayState::new(test_config(), test_identity());
        let response = handle_request(RelayRequest::Health, &state);
        let stats = response.stats.expect("health should include stats");

        assert!(response.ok);
        assert_eq!(stats.relay_id, "relay-test");
    }

    #[test]
    fn http_path_with_query_string_is_accepted() {
        let state = RelayState::new(test_config(), test_identity());
        let mut reader = BufReader::new("Host: relay.test\r\n\r\n".as_bytes());
        let (status, response) = handle_http_request(
            "GET /health?cache=1 HTTP/1.1\r\n",
            &mut reader,
            &state,
            "127.0.0.1",
        );
        assert_eq!(status, 200);
        assert_eq!(response["ok"], true);
    }

    #[test]
    fn http_trusts_forwarded_for_when_enabled() {
        let mut config = test_config();
        config.trust_forwarded_for = true;
        config.max_requests_per_minute = 2;
        let state = RelayState::new(config, test_identity());

        // Two requests from the same forwarded client succeed, the third gets
        // rate-limited even though every connection looks like 127.0.0.1.
        for expected_status in [200_u16, 200, 429] {
            let mut reader = BufReader::new(
                "Host: relay.test\r\nX-Forwarded-For: 198.51.100.7, 10.0.0.1\r\n\r\n".as_bytes(),
            );
            let (status, _) =
                handle_http_request("GET /health HTTP/1.1\r\n", &mut reader, &state, "127.0.0.1");
            assert_eq!(status, expected_status);
        }
    }

    fn verify_signature(identity: &RelayIdentity, response: &RelayResponse, action: &str) -> bool {
        use ed25519_dalek::{Signature, Verifier};
        let nonce = match &response.nonce_echo {
            Some(value) => match BASE64_STANDARD.decode(value) {
                Ok(bytes) => bytes,
                Err(_) => return false,
            },
            None => return false,
        };
        let signature_bytes = match &response.signature {
            Some(value) => match BASE64_STANDARD.decode(value) {
                Ok(bytes) => bytes,
                Err(_) => return false,
            },
            None => return false,
        };
        if signature_bytes.len() != 64 {
            return false;
        }
        let mut sig_array = [0_u8; 64];
        sig_array.copy_from_slice(&signature_bytes);
        let signature = Signature::from_bytes(&sig_array);

        // Reproduce the canonical body the relay signed: response sans
        // nonce_echo + signature, via the same skip-if-none JSON path.
        let mut canonical = RelayResponse {
            ok: response.ok,
            stored: response.stored,
            messages: response.messages.clone(),
            error: response.error.clone(),
            stats: response.stats.as_ref().map(|stats| RelayStats {
                relay_id: stats.relay_id.clone(),
                version: stats.version.clone(),
                queue_count: stats.queue_count,
                queued_envelope_count: stats.queued_envelope_count,
                queued_bytes: stats.queued_bytes,
                active_leases: stats.active_leases,
                ttl_seconds: stats.ttl_seconds,
                max_queue_per_mailbox: stats.max_queue_per_mailbox,
                max_fetch_limit: stats.max_fetch_limit,
                identity_public_key: stats.identity_public_key.clone(),
                v2: stats.v2.clone(),
            }),
            nonce_echo: None,
            signature: None,
            lease_id: response.lease_id.clone(),
            owner: response.owner.clone(),
        };
        // The two None fields are already cleared; assigning again is a no-op
        // and reminds the reader why this clone exists.
        canonical.nonce_echo = None;
        canonical.signature = None;
        let body = serde_json::to_vec(&canonical).expect("response is serializable");
        let mut signing_input = Vec::with_capacity(action.len() + nonce.len() + body.len());
        signing_input.extend_from_slice(action.as_bytes());
        signing_input.extend_from_slice(&nonce);
        signing_input.extend_from_slice(&body);
        identity
            .signing_key
            .verifying_key()
            .verify(&signing_input, &signature)
            .is_ok()
    }

    #[test]
    fn identity_seed_round_trips_through_load_or_generate() {
        let tmp_dir = env::temp_dir().join(format!(
            "conest_relay_id_test_{}_{}",
            std::process::id(),
            now_millis()
        ));
        fs::create_dir_all(&tmp_dir).expect("create tmp dir");
        let seed_path = tmp_dir.join("seed");
        let mut config = test_config();
        config.identity_seed_path = seed_path.clone();
        config.identity_seed_inline = None;

        let first = RelayIdentity::load_or_generate(&config).expect("first load");
        assert!(
            seed_path.exists(),
            "seed file should be created on first run"
        );
        let second = RelayIdentity::load_or_generate(&config).expect("second load");
        assert_eq!(
            first.public_key_b64, second.public_key_b64,
            "subsequent loads must produce the same identity"
        );

        let _ = fs::remove_dir_all(&tmp_dir);
    }

    #[test]
    fn health_response_exposes_identity_public_key() {
        let state = test_state();
        let response = handle_request(RelayRequest::Health, &state);
        let stats = response.stats.expect("health response carries stats");
        assert!(
            !stats.identity_public_key.is_empty(),
            "stats must include the relay's identity public key"
        );
        assert_eq!(stats.identity_public_key, state.identity.public_key_b64);
    }

    #[test]
    fn request_with_nonce_receives_a_valid_signature() {
        let state = test_state();
        let request = json!({
            "action": "health",
            "nonce": BASE64_STANDARD.encode([1_u8; 16]),
        })
        .to_string();
        let raw = handle_request_bytes(request.as_bytes(), request.len(), &state, "127.0.0.1");
        let response: RelayResponse = serde_json::from_value(raw).expect("inline response decodes");
        assert!(response.signature.is_some(), "signed responses required");
        assert!(
            verify_signature(&state.identity, &response, "health"),
            "signature must verify against the relay's pinned key"
        );
    }

    #[test]
    fn request_without_nonce_returns_unsigned_response() {
        let state = test_state();
        let request = json!({ "action": "health" }).to_string();
        let response = handle_request_bytes(request.as_bytes(), request.len(), &state, "127.0.0.1");
        assert!(
            response.get("signature").is_none(),
            "legacy clients without a nonce keep getting unsigned responses"
        );
        assert!(response.get("nonce_echo").is_none());
    }

    #[test]
    fn tampered_response_body_invalidates_the_signature() {
        let state = test_state();
        let request = json!({
            "action": "health",
            "nonce": BASE64_STANDARD.encode([9_u8; 16]),
        })
        .to_string();
        let raw = handle_request_bytes(request.as_bytes(), request.len(), &state, "127.0.0.1");
        let mut response: RelayResponse =
            serde_json::from_value(raw).expect("inline response decodes");
        // Flip a byte of the response that participates in the signing
        // input. Verifier must reject it.
        if let Some(stats) = response.stats.as_mut() {
            stats.queue_count += 1;
        }
        assert!(
            !verify_signature(&state.identity, &response, "health"),
            "tampered body must fail signature verification"
        );
    }

    #[test]
    fn detached_sig_mode_signs_the_exact_body_bytes() {
        use ed25519_dalek::{Signature, Verifier};
        let state = test_state();
        let nonce = BASE64_STANDARD.encode([9_u8; 16]);
        let request = json!({
            "action": "health",
            "nonce": nonce,
            "sig_mode": "detached",
        })
        .to_string();
        let response = handle_request_bytes(request.as_bytes(), request.len(), &state, "127.0.0.1");

        assert_eq!(response["sig_v"], 2);
        assert_eq!(response["nonce_echo"], nonce.as_str());
        let body = response["body"].as_str().expect("body travels as a string");
        let signature_bytes = BASE64_STANDARD
            .decode(response["signature"].as_str().expect("signature present"))
            .expect("signature is base64");
        let mut sig_array = [0_u8; 64];
        sig_array.copy_from_slice(&signature_bytes);

        // Verification happens over the exact body-string bytes — no JSON
        // re-encoding round-trip on the verifier side.
        let mut signing_input = Vec::new();
        signing_input.extend_from_slice(b"health");
        signing_input.extend_from_slice(&[9_u8; 16]);
        signing_input.extend_from_slice(body.as_bytes());
        assert!(
            state
                .identity
                .signing_key
                .verifying_key()
                .verify(&signing_input, &Signature::from_bytes(&sig_array))
                .is_ok(),
            "detached signature must verify over the raw body bytes"
        );

        let parsed: Value = serde_json::from_str(body).expect("body parses as JSON");
        assert_eq!(parsed["ok"], true);
        assert!(
            parsed.get("signature").is_none() && parsed.get("nonce_echo").is_none(),
            "signed body must not embed the signature fields"
        );
    }

    #[test]
    fn mailbox_quota_rejects_oversized_throughput() {
        let mut config = test_config();
        config.max_bytes_per_mailbox_per_minute = 256;
        let state = RelayState::new(config, test_identity());

        // First small envelope fits well within the quota.
        let small = envelope("direct_message", "msg-quota-1", "dev-a");
        state
            .store("dev-b".to_owned(), small)
            .expect("first store fits within quota");

        // Build an envelope whose serialized form exceeds the remaining
        // budget — pad the payload base64 to push bytes over 256.
        let padded_payload = "A".repeat(400);
        let big = json!({
            "kind": "direct_message",
            "messageId": "msg-quota-2",
            "conversationId": "conv",
            "senderAccountId": "acc-a",
            "senderDeviceId": "dev-a",
            "recipientDeviceId": "dev-b",
            "createdAt": "2026-05-13T00:00:00.000Z",
            "payloadBase64": padded_payload,
        });
        let err = state
            .store("dev-b".to_owned(), big)
            .expect_err("oversized store should be rejected");
        assert!(err.contains("quota"), "error should mention quota: {err}");
    }

    #[test]
    fn pairing_announcement_envelopes_bypass_mailbox_quota() {
        let mut config = test_config();
        config.max_bytes_per_mailbox_per_minute = 1; // effectively impossible
        let state = RelayState::new(config, test_identity());

        let ann = envelope("pairing_announcement", "pair-1", "dev-a");
        state
            .store("pair-mailbox".to_owned(), ann)
            .expect("pairing announcements bypass the throughput quota");
    }

    #[test]
    fn soft_ban_triggers_after_threshold_violations() {
        let mut config = test_config();
        config.max_requests_per_minute = 1;
        config.soft_ban_threshold = 3;
        config.soft_ban_duration = Duration::from_secs(30);
        let state = RelayState::new(config, test_identity());

        assert!(state.allow_request("198.51.100.7"), "first request");
        // Subsequent requests inside the same minute window are rate-limited
        // and accumulate consecutive violations.
        for _ in 0..3 {
            assert!(
                !state.allow_request("198.51.100.7"),
                "rate-limited request rejected"
            );
        }
        // The 5th (after 3 violations) is still rejected — soft-ban now
        // takes over for the remainder of the duration.
        assert!(
            !state.allow_request("198.51.100.7"),
            "soft-banned peer stays rejected"
        );
        let bans = state.banned_peers.lock().expect("ban lock");
        let entry = bans.get("198.51.100.7").expect("banned peer recorded");
        assert!(
            entry.banned_until_millis > now_millis(),
            "ban timer points to the future"
        );
    }

    #[test]
    fn soft_ban_expires_after_short_duration() {
        let mut config = test_config();
        config.max_requests_per_minute = 1;
        config.soft_ban_threshold = 2;
        config.soft_ban_duration = Duration::from_millis(100);
        let state = RelayState::new(config, test_identity());

        // Burn through to trigger a ban.
        state.allow_request("203.0.113.4");
        for _ in 0..3 {
            state.allow_request("203.0.113.4");
        }
        // Still inside ban duration.
        assert!(!state.allow_request("203.0.113.4"));
        std::thread::sleep(Duration::from_millis(160));
        // After the ban window passes the peer cycles back through the
        // rate-limit path on its next request.
        let _ = state.allow_request("203.0.113.4");
        // And the ban entry should be drained or its `banned_until_millis`
        // should be in the past, by the retain() pass.
        let bans = state.banned_peers.lock().expect("ban lock");
        assert!(
            bans.get("203.0.113.4")
                .is_none_or(|e| e.banned_until_millis <= now_millis()),
            "expired ban must not remain active",
        );
    }

    #[test]
    fn http_ignores_forwarded_for_when_disabled() {
        // Default config does NOT trust X-Forwarded-For; budget should be tied
        // to the connection peer only.
        let mut config = test_config();
        config.max_requests_per_minute = 2;
        let state = RelayState::new(config, test_identity());
        for expected_status in [200_u16, 200, 429] {
            let mut reader = BufReader::new(
                "Host: relay.test\r\nX-Forwarded-For: 198.51.100.7\r\n\r\n".as_bytes(),
            );
            let (status, _) =
                handle_http_request("GET /health HTTP/1.1\r\n", &mut reader, &state, "127.0.0.1");
            assert_eq!(status, expected_status);
        }
    }

    #[test]
    fn long_poll_returns_immediately_when_envelope_already_queued() {
        let state = RelayState::new(test_config(), test_identity());
        state
            .store(
                "dev-bob".to_owned(),
                envelope("direct_message", "msg-1", "dev-alice"),
            )
            .expect("store");
        let start = std::time::Instant::now();
        let messages = state
            .fetch("dev-bob", Some(10), Some(5_000))
            .expect("fetch");
        // Fast path: envelope was already there, no waiting.
        assert!(start.elapsed() < Duration::from_millis(200));
        assert_eq!(messages.len(), 1);
    }

    #[test]
    fn long_poll_wakes_on_store_within_wait_window() {
        let state = Arc::new(RelayState::new(test_config(), test_identity()));
        let storer = state.clone();
        let waker = thread::spawn(move || {
            // Give the fetch a head start so it parks on the condvar.
            thread::sleep(Duration::from_millis(150));
            storer
                .store(
                    "dev-bob".to_owned(),
                    envelope("direct_message", "msg-late", "dev-alice"),
                )
                .expect("store");
        });
        let start = std::time::Instant::now();
        let messages = state
            .fetch("dev-bob", Some(10), Some(2_000))
            .expect("fetch");
        let elapsed = start.elapsed();
        waker.join().expect("waker thread");
        assert!(
            elapsed >= Duration::from_millis(100) && elapsed < Duration::from_millis(1_000),
            "fetch should wake within ~150ms, took {elapsed:?}"
        );
        assert_eq!(messages.len(), 1);
        assert_eq!(messages[0]["messageId"], "msg-late");
    }

    #[test]
    fn long_poll_returns_empty_after_timeout_when_no_store_arrives() {
        let state = RelayState::new(test_config(), test_identity());
        let start = std::time::Instant::now();
        let messages = state
            .fetch("dev-quiet", Some(10), Some(200))
            .expect("fetch");
        let elapsed = start.elapsed();
        assert!(messages.is_empty());
        assert!(
            elapsed >= Duration::from_millis(150) && elapsed < Duration::from_millis(800),
            "fetch should return after the wait window, took {elapsed:?}"
        );
    }

    #[test]
    fn generation_predicate_catches_store_between_drain_and_wait() {
        let state = RelayState::new(test_config(), test_identity());
        let notifier = state.notifier_for("dev-race");
        let observed = notifier.0.lock().expect("signal lock").generation;
        assert!(state.drain_queue("dev-race", 4).is_empty());

        state
            .store(
                "dev-race".to_owned(),
                envelope("direct_message", "msg-race", "dev-alice"),
            )
            .expect("store in race window");

        let current = notifier.0.lock().expect("signal lock").generation;
        assert_ne!(current, observed, "store must advance the wait predicate");
        let messages = state.drain_queue("dev-race", 4);
        assert_eq!(messages.len(), 1);
    }

    #[test]
    fn leased_fetch_requires_ack_and_ack_is_atomic() {
        let state = RelayState::new(test_config(), test_identity());
        state
            .store(
                "dev-bob".to_owned(),
                envelope("direct_message", "msg-leased", "dev-alice"),
            )
            .expect("store");
        let (messages, lease_id) = state
            .fetch_leased("dev-bob", Some(10), None, Some(30_000))
            .expect("leased fetch");
        assert_eq!(messages.len(), 1);
        let lease_id = lease_id.expect("message fetch has a lease");
        assert!(
            state
                .fetch_leased("dev-bob", Some(10), None, Some(30_000))
                .expect("second fetch")
                .0
                .is_empty(),
            "an active lease must hide its envelopes"
        );
        state
            .acknowledge_lease("dev-bob", &lease_id)
            .expect("ack lease");
        assert_eq!(state.stats().queued_envelope_count, 0);
        assert_eq!(state.stats().active_leases, 0);
    }

    #[test]
    fn mailbox_quota_never_evicts_an_active_lease() {
        let mut config = test_config();
        config.max_queue_per_mailbox = 1;
        let state = RelayState::new(config, test_identity());
        state
            .store(
                "dev-bob".to_owned(),
                envelope("direct_message", "msg-leased", "dev-alice"),
            )
            .expect("store leased message");
        let (_, lease_id) = state
            .fetch_leased("dev-bob", Some(1), None, Some(30_000))
            .expect("lease message");
        let lease_id = lease_id.expect("non-pairing message has a lease");

        assert!(
            state
                .store(
                    "dev-bob".to_owned(),
                    envelope("direct_message", "msg-new", "dev-alice"),
                )
                .is_err(),
            "a full mailbox with only leased rows must reject, not evict"
        );
        assert_eq!(state.stats().queued_envelope_count, 1);
        assert_eq!(state.stats().active_leases, 1);
        state
            .acknowledge_lease("dev-bob", &lease_id)
            .expect("leased row remains acknowledgeable");
    }

    #[test]
    fn restart_requeues_unacknowledged_sqlite_leases_and_preserves_identity_data() {
        let mut config = test_config();
        let database_path = std::env::temp_dir().join(format!(
            "conest-relay-test-{}-{}.sqlite3",
            std::process::id(),
            now_millis()
        ));
        config.database_path = database_path.clone();
        {
            let state = RelayState::new(config.clone(), test_identity());
            state
                .store(
                    "dev-bob".to_owned(),
                    envelope("direct_message", "msg-restart", "dev-alice"),
                )
                .expect("store");
            let (_, lease_id) = state
                .fetch_leased("dev-bob", Some(10), None, Some(300_000))
                .expect("lease");
            assert!(lease_id.is_some());
            assert_eq!(state.stats().active_leases, 1);
        }
        {
            let restarted = RelayState::new(config, test_identity());
            let messages = restarted
                .fetch("dev-bob", Some(10), None)
                .expect("fetch after restart");
            assert_eq!(messages.len(), 1);
            assert_eq!(messages[0]["messageId"], "msg-restart");
        }
        let _ = fs::remove_file(&database_path);
        let _ = fs::remove_file(database_path.with_extension("sqlite3-wal"));
        let _ = fs::remove_file(database_path.with_extension("sqlite3-shm"));
    }

    #[test]
    fn durable_queue_deduplicates_message_ids() {
        let state = RelayState::new(test_config(), test_identity());
        let value = envelope("direct_message", "msg-dedup", "dev-alice");
        state
            .store("dev-bob".to_owned(), value.clone())
            .expect("first store");
        state
            .store("dev-bob".to_owned(), value)
            .expect("duplicate store is idempotent");
        assert_eq!(state.stats().queued_envelope_count, 1);
    }

    #[test]
    fn idle_notifiers_are_pruned_and_store_does_not_create_them() {
        let state = RelayState::new(test_config(), test_identity());
        let messages = state
            .fetch("dev-idle", Some(4), Some(1))
            .expect("short long poll");
        assert!(messages.is_empty());
        assert!(state.notifiers.lock().expect("notifier map").is_empty());

        state
            .store(
                "dev-no-waiter".to_owned(),
                envelope("direct_message", "msg-no-waiter", "dev-alice"),
            )
            .expect("store without waiter");
        assert!(state.notifiers.lock().expect("notifier map").is_empty());
    }

    #[test]
    fn bounded_line_reader_rejects_oversized_input() {
        let input = format!("{}\n", "x".repeat(1024));
        let mut reader = BufReader::new(input.as_bytes());
        let mut line = String::new();
        let error = read_line_bounded(&mut reader, &mut line, 64)
            .expect_err("oversized request line must fail");
        assert_eq!(error.kind(), std::io::ErrorKind::InvalidData);
        assert!(line.is_empty());
    }

    #[test]
    fn oversized_http_header_line_is_rejected() {
        let mut config = test_config();
        config.max_line_bytes = 64;
        let state = RelayState::new(config, test_identity());
        let header = format!("X-Fill: {}\r\n\r\n", "x".repeat(128));
        let mut reader = BufReader::new(header.as_bytes());
        let (status, _) =
            handle_http_request("GET /health HTTP/1.1\r\n", &mut reader, &state, "127.0.0.1");
        assert_eq!(status, 413);
    }

    fn store_line(id: &str) -> String {
        json!({
            "action": "store",
            "recipient_device_id": "dev-b",
            "envelope": envelope("direct_message", id, "dev-a")
        })
        .to_string()
    }

    #[test]
    fn stores_have_their_own_budget_and_fetches_go_on() {
        let mut config = test_config();
        config.max_queue_per_mailbox = 16;
        config.max_stores_per_minute = 2;
        let state = RelayState::new(config, test_identity());
        for (index, expected) in [true, true, false].into_iter().enumerate() {
            let line = store_line(&format!("msg-{index}"));
            let response =
                handle_request_bytes(line.as_bytes(), line.len(), &state, "198.51.100.9");
            assert_eq!(response["ok"], expected, "store {index}: {response}");
        }
        // Over the store budget, the address still fetches.
        let fetch =
            json!({"action": "fetch", "recipient_device_id": "dev-b", "limit": 4}).to_string();
        let fetched = handle_request_bytes(fetch.as_bytes(), fetch.len(), &state, "198.51.100.9");
        assert_eq!(fetched["ok"], true, "{fetched}");
        // Another address has a budget of its own.
        let line = store_line("msg-other");
        let other = handle_request_bytes(line.as_bytes(), line.len(), &state, "198.51.100.10");
        assert_eq!(other["ok"], true, "{other}");
    }

    #[test]
    fn stored_bytes_per_address_are_limited() {
        let mut config = test_config();
        config.max_queue_per_mailbox = 16;
        let line = store_line("msg-0");
        // Room for one store of this size, not two.
        config.max_store_bytes_per_minute = line.len() as u64 + 10;
        let state = RelayState::new(config, test_identity());
        let first = handle_request_bytes(line.as_bytes(), line.len(), &state, "198.51.100.9");
        assert_eq!(first["ok"], true, "{first}");
        let line = store_line("msg-1");
        let second = handle_request_bytes(line.as_bytes(), line.len(), &state, "198.51.100.9");
        assert_eq!(second["ok"], false, "{second}");
        assert_eq!(second["error"], "rate limit exceeded");
    }

    /// [request] over UDP from [peer], with the cookie a first try asks for
    /// (that try padded to the length a cookie request needs).
    fn udp_with_cookie(state: &RelayState, peer: SocketAddr, request: Value) -> Value {
        let mut first = request.clone();
        first["pad"] = json!("x".repeat(UDP_COOKIE_REQUEST_MIN_BYTES));
        let line = first.to_string();
        let first = handle_udp_datagram(line.as_bytes(), line.len(), state, peer);
        let Some(cookie) = first["cookie"].as_str() else {
            return first;
        };
        let mut with_cookie = request.clone();
        with_cookie["cookie"] = json!(cookie);
        let line = with_cookie.to_string();
        handle_udp_datagram(line.as_bytes(), line.len(), state, peer)
    }

    #[test]
    fn every_udp_request_takes_the_store_budget_kept_apart_from_tcp() {
        let mut config = test_config();
        config.max_stores_per_minute = 2;
        config.max_queue_per_mailbox = 16;
        let state = RelayState::new(config, test_identity());
        let peer: SocketAddr = "198.51.100.11:40000".parse().expect("test socket addr");
        for _ in 0..2 {
            let response = udp_with_cookie(&state, peer, json!({"action": "health"}));
            assert_eq!(response["ok"], true, "{response}");
        }
        // Over its budget: nothing goes back at all.
        let response = udp_with_cookie(&state, peer, json!({"action": "health"}));
        assert!(response.is_null(), "{response}");
        // Forged datagrams naming an address do not spend its TCP budgets.
        let line = store_line("msg-tcp");
        let response = handle_request_bytes(line.as_bytes(), line.len(), &state, "198.51.100.11");
        assert_eq!(response["ok"], true, "{response}");
    }

    #[test]
    fn over_udp_everything_needs_the_cookie_of_that_very_address() {
        let state = RelayState::new(test_config(), test_identity());
        let peer: SocketAddr = "[2001:db8:1:2::1]:40000".parse().expect("test socket addr");
        // The same /64, another host.
        let neighbour: SocketAddr = "[2001:db8:1:2::2]:40000".parse().expect("test socket addr");
        let mut fetch = json!({"action": "fetch", "recipient_device_id": "dev-b", "limit": 4});
        // Too short to be answered with a cookie: nothing back.
        let line = fetch.to_string();
        assert!(handle_udp_datagram(line.as_bytes(), line.len(), &state, peer).is_null());
        fetch["pad"] = json!("x".repeat(UDP_COOKIE_REQUEST_MIN_BYTES));
        let line = fetch.to_string();
        let first = handle_udp_datagram(line.as_bytes(), line.len(), &state, peer);
        assert_eq!(first["error"], "udp cookie required");
        // Never longer than what came in.
        assert!(first.to_string().len() <= line.len(), "{first}");
        let cookie = first["cookie"].as_str().expect("a cookie").to_owned();
        let mut with_cookie =
            json!({"action": "fetch", "recipient_device_id": "dev-b", "limit": 4});
        with_cookie["cookie"] = json!(cookie);
        let line = with_cookie.to_string();
        assert!(handle_udp_datagram(line.as_bytes(), line.len(), &state, neighbour).is_null());
        let answered = handle_udp_datagram(line.as_bytes(), line.len(), &state, peer);
        assert_eq!(answered["ok"], true, "{answered}");
        // A store without a cookie is not taken.
        let store = store_line("msg-udp-store");
        let refused = handle_udp_datagram(store.as_bytes(), store.len(), &state, peer);
        assert_eq!(refused["error"], "udp cookie required");
        let stored = udp_with_cookie(
            &state,
            peer,
            serde_json::from_str(&store_line("msg-udp-store")).expect("json"),
        );
        assert_eq!(stored["ok"], true, "{stored}");
        // Nonsense, signed or not, gets nothing back.
        let junk = br#"{"action":"nope","nonce":"AAAAAAAAAAAAAAAAAAAAAA=="}"#;
        assert!(handle_udp_datagram(junk, junk.len(), &state, peer).is_null());
    }

    #[test]
    fn a_udp_fetch_never_waits() {
        let state = RelayState::new(test_config(), test_identity());
        let peer: SocketAddr = "198.51.100.15:40000".parse().expect("test socket addr");
        let started = std::time::Instant::now();
        let response = udp_with_cookie(
            &state,
            peer,
            json!({"action": "fetch", "recipient_device_id": "dev-b", "limit": 4, "wait_ms": 5000}),
        );
        assert_eq!(response["ok"], true, "{response}");
        assert!(started.elapsed() < Duration::from_secs(2), "it waited");
    }

    fn store_to(mailbox: &str, id: &str) -> String {
        json!({
            "action": "store",
            "recipient_device_id": mailbox,
            "envelope": envelope("direct_message", id, "dev-z")
        })
        .to_string()
    }

    #[test]
    fn one_address_holds_a_bounded_share() {
        let mut config = test_config();
        config.max_queue_per_mailbox = 16;
        let line = store_to("dev-c", "msg-0");
        config.max_stored_bytes_per_peer = line.len() as u64;
        let state = RelayState::new(config, test_identity());
        let response = handle_request_bytes(line.as_bytes(), line.len(), &state, "198.51.100.16");
        assert_eq!(response["ok"], true, "{response}");
        let line = store_to("dev-d", "msg-1");
        let response = handle_request_bytes(line.as_bytes(), line.len(), &state, "198.51.100.16");
        assert_eq!(
            response["error"],
            "this address holds too much on the relay"
        );
        let response = handle_request_bytes(line.as_bytes(), line.len(), &state, "198.51.100.17");
        assert_eq!(response["ok"], true, "{response}");
    }

    #[test]
    fn a_full_relay_makes_room_from_its_largest_holder() {
        let mut config = test_config();
        config.max_queue_per_mailbox = 16;
        let line = store_to("dev-c", "msg-0");
        // Room for about three.
        config.max_total_bytes = line.len() as u64 * 3;
        let state = RelayState::new(config, test_identity());
        for (index, mailbox) in ["dev-c", "dev-d", "dev-e"].iter().enumerate() {
            let line = store_to(mailbox, &format!("big-{index}"));
            let response =
                handle_request_bytes(line.as_bytes(), line.len(), &state, "198.51.100.30");
            assert_eq!(response["ok"], true, "{response}");
        }
        // Someone else is not refused: the largest holder's oldest goes.
        let line = store_to("dev-f", "other-0");
        let response = handle_request_bytes(line.as_bytes(), line.len(), &state, "198.51.100.31");
        assert_eq!(response["ok"], true, "{response}");
        let fetched = state.fetch("dev-c", Some(4), None).expect("fetch");
        assert!(fetched.is_empty(), "the oldest of the largest holder went");
        let fetched = state.fetch("dev-f", Some(4), None).expect("fetch");
        assert_eq!(fetched.len(), 1);
        // The running total follows inserts and deletes.
        let total: i64 = state
            .database
            .lock()
            .expect("lock")
            .query_row("SELECT bytes FROM stored_total WHERE id = 1", [], |row| {
                row.get(0)
            })
            .expect("total");
        let summed: i64 = state
            .database
            .lock()
            .expect("lock")
            .query_row(
                "SELECT COALESCE(SUM(envelope_bytes), 0) FROM queue_entries",
                [],
                |row| row.get(0),
            )
            .expect("sum");
        assert_eq!(total, summed);
    }

    #[test]
    fn an_ipv6_site_counts_as_one_for_what_it_holds() {
        assert_eq!(peer_group("2001:db8:1:2::/64"), "2001:db8:1::/48");
        assert_eq!(peer_group("udp:2001:db8:1:2::/64"), "2001:db8:1::/48");
        assert_eq!(peer_group("198.51.100.1"), "198.51.100.1");
        assert_eq!(peer_group("udp:198.51.100.1"), "198.51.100.1");
    }

    #[test]
    fn the_rate_maps_track_a_bounded_number_of_addresses() {
        let mut config = test_config();
        config.max_rate_keys = 2;
        let state = RelayState::new(config, test_identity());
        assert!(state.allow_request("198.51.100.40"));
        assert!(state.allow_request("198.51.100.41"));
        assert!(!state.allow_request("198.51.100.42"));
        // Those already known go on.
        assert!(state.allow_request("198.51.100.40"));
    }

    #[test]
    fn a_proxy_header_counts_its_last_line_and_strips_a_port() {
        assert_eq!(
            forwarded_peer("1.1.1.1, 198.51.100.20:5678").as_deref(),
            Some("198.51.100.20")
        );
        assert_eq!(
            forwarded_peer("[2001:db8:1:2::9]:443").as_deref(),
            Some("2001:db8:1:2::/64")
        );
        let mut config = test_config();
        config.trust_forwarded_for = true;
        config.max_requests_per_minute = 2;
        let state = RelayState::new(config, test_identity());
        // The client writes the first line; the proxy appends the second.
        for (forged, expected_status) in [("1.1.1.1", 200_u16), ("2.2.2.2", 200), ("3.3.3.3", 429)]
        {
            let headers = format!(
                "Host: relay.test\r\nX-Forwarded-For: {forged}\r\nX-Forwarded-For: 198.51.100.21\r\n\r\n"
            );
            let mut reader = BufReader::new(headers.as_bytes());
            let (status, _) =
                handle_http_request("GET /health HTTP/1.1\r\n", &mut reader, &state, "127.0.0.1");
            assert_eq!(status, expected_status, "{forged}");
        }
    }

    #[test]
    fn a_response_not_taken_ends_at_the_deadline() {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind");
        let address = listener.local_addr().expect("address");
        // A client that connects and never reads.
        let client = std::net::TcpStream::connect(address).expect("connect");
        let (stream, _) = listener.accept().expect("accept");
        let mut writer = DeadlineWriter {
            stream,
            limit: Duration::from_secs(1),
            deadline: None,
        };
        let started = std::time::Instant::now();
        let chunk = vec![0_u8; 1024 * 1024];
        let mut result = Ok(());
        for _ in 0..512 {
            result = writer.write_all(&chunk);
            if result.is_err() {
                break;
            }
        }
        assert!(result.is_err(), "the writes never stopped");
        assert!(started.elapsed() < Duration::from_secs(4));
        drop(client);
    }

    #[test]
    fn ipv6_addresses_count_by_their_64() {
        let key = |text: &str| peer_key(text.parse().expect("an address"));
        assert_eq!(key("2001:db8:1:2::1"), key("2001:db8:1:2:ffff::9"));
        assert_ne!(key("2001:db8:1:2::1"), key("2001:db8:1:3::1"));
        assert_eq!(key("::ffff:198.51.100.1"), "198.51.100.1");
        assert_eq!(key("198.51.100.1"), "198.51.100.1");
    }

    #[test]
    fn a_trusted_proxy_header_counts_the_address_the_proxy_saw() {
        let mut config = test_config();
        config.trust_forwarded_for = true;
        config.max_requests_per_minute = 2;
        let state = RelayState::new(config, test_identity());
        // The client writes the first part; changing it gains nothing.
        for (forged, expected_status) in [("1.1.1.1", 200_u16), ("2.2.2.2", 200), ("3.3.3.3", 429)]
        {
            let headers =
                format!("Host: relay.test\r\nX-Forwarded-For: {forged}, 198.51.100.20\r\n\r\n");
            let mut reader = BufReader::new(headers.as_bytes());
            let (status, _) =
                handle_http_request("GET /health HTTP/1.1\r\n", &mut reader, &state, "127.0.0.1");
            assert_eq!(status, expected_status, "{forged}");
        }
    }

    #[test]
    fn one_address_holds_a_bounded_number_of_connections() {
        let mut config = test_config();
        config.max_connections_per_peer = 2;
        let state = RelayState::new(config, test_identity());
        let first = state.connection_slot("198.51.100.21").expect("first");
        let _second = state.connection_slot("198.51.100.21").expect("second");
        assert!(state.connection_slot("198.51.100.21").is_none());
        assert!(state.connection_slot("198.51.100.22").is_some());
        drop(first);
        assert!(state.connection_slot("198.51.100.21").is_some());
    }

    #[test]
    fn a_request_trickling_in_ends_at_the_deadline() {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind");
        let address = listener.local_addr().expect("address");
        let writer = thread::spawn(move || {
            let mut client = std::net::TcpStream::connect(address).expect("connect");
            for _ in 0..20 {
                if client.write_all(b"{").is_err() {
                    break;
                }
                thread::sleep(Duration::from_millis(200));
            }
        });
        let (stream, _) = listener.accept().expect("accept");
        let state = RelayState::new(test_config(), test_identity());
        let started = std::time::Instant::now();
        let result = handle_client(
            stream,
            state,
            "127.0.0.1".to_owned(),
            Duration::from_secs(1),
        );
        assert!(result.is_err());
        assert!(started.elapsed() < Duration::from_secs(3));
        writer.join().expect("writer");
    }

    #[test]
    fn a_long_poll_over_the_address_share_is_answered_at_once() {
        let mut config = test_config();
        config.max_long_polls_per_peer = 1;
        let state = RelayState::new(config, test_identity());
        let held = state.long_poll_slot("198.51.100.12").expect("a first slot");
        let poll = json!({
            "action": "fetch",
            "recipient_device_id": "dev-b",
            "limit": 4,
            "wait_ms": 5000
        })
        .to_string();
        let started = std::time::Instant::now();
        let response = handle_request_bytes(poll.as_bytes(), poll.len(), &state, "198.51.100.12");
        assert_eq!(response["ok"], true, "{response}");
        assert!(started.elapsed() < Duration::from_secs(2), "it waited");
        drop(held);
        // The slot came back: another address's share is untouched, and
        // this one has its slot again.
        assert!(state.long_poll_slot("198.51.100.12").is_some());
        assert!(state.long_polls.lock().expect("lock").is_empty());
    }

    // --- Sealed UDP (M38-C) ---

    fn sealed_exchange(
        state: &RelayState,
        peer: SocketAddr,
        request: &Value,
        pad: usize,
    ) -> Option<Value> {
        use crate::udp_sealed::client_for_tests::{open_response, seal_request};
        let (datagram, keys) = seal_request(&state.identity.noise_public, request.to_string().as_bytes(), pad);
        let answer = crate::udp_sealed::answer_datagram(&datagram, state, peer)?;
        assert!(answer[0] != b'{', "a sealed request gets no cleartext answer");
        let plain = open_response(&keys, &answer).expect("answer opens under the exchange keys");
        Some(serde_json::from_slice(&plain).expect("json"))
    }

    #[test]
    fn a_sealed_udp_request_is_answered_sealed_under_the_cookie_rules() {
        let state = test_state();
        let peer: SocketAddr = "198.51.100.40:5000".parse().unwrap();
        // Without a cookie, a sealed request long enough gets the cookie.
        let health = json!({"action": "health"});
        let first = sealed_exchange(&state, peer, &health, 80).expect("cookie answer");
        assert_eq!(first["error"], "udp cookie required", "{first}");
        let cookie = first["cookie"].as_str().expect("cookie").to_owned();
        let mut with_cookie = health.clone();
        with_cookie["cookie"] = json!(cookie);
        let answer = sealed_exchange(&state, peer, &with_cookie, 7).expect("health");
        assert_eq!(answer["ok"], true, "{answer}");
        // A store goes through and can be fetched, all sealed.
        let mut store = json!({
            "action": "store",
            "recipient_device_id": "dev-b",
            "envelope": envelope("direct_message", "msg-sealed", "dev-a"),
        });
        store["cookie"] = json!(cookie);
        let stored = sealed_exchange(&state, peer, &store, 0).expect("stored");
        assert_eq!(stored["ok"], true, "{stored}");
        let mut fetch = json!({"action": "fetch", "recipient_device_id": "dev-b", "limit": 2});
        fetch["cookie"] = json!(cookie);
        let fetched = sealed_exchange(&state, peer, &fetch, 33).expect("fetched");
        assert_eq!(fetched["messages"][0]["messageId"], "msg-sealed", "{fetched}");
    }

    #[test]
    fn a_short_sealed_request_gets_nothing_not_even_a_cookie() {
        // The cookie goes only to a datagram as long as its answer: the
        // wire length counts, not the hidden request's.
        let state = test_state();
        let peer: SocketAddr = "198.51.100.41:5000".parse().unwrap();
        let tiny = json!({"a": 1});
        assert!(sealed_exchange(&state, peer, &tiny, 0).is_none());
    }

    #[test]
    fn sealed_udp_answers_vary_in_length_and_wrong_keys_get_nothing() {
        use crate::udp_sealed::client_for_tests::seal_request;
        let state = test_state();
        let peer: SocketAddr = "198.51.100.42:5000".parse().unwrap();
        let health = json!({"action": "health", "pad": "x".repeat(10)});
        let mut lengths = std::collections::HashSet::new();
        let (datagram, _) = seal_request(&state.identity.noise_public, health.to_string().as_bytes(), 90);
        for _ in 0..20 {
            if let Some(answer) = crate::udp_sealed::answer_datagram(&datagram, &state, peer) {
                lengths.insert(answer.len());
            }
        }
        assert!(lengths.len() > 3, "answers differ in length: {lengths:?}");
        // Sealed to another relay's key: not ours to open, nothing back.
        let other = RelayIdentity::from_seed_bytes([9_u8; 32]);
        let (wrong, _) = seal_request(&other.noise_public, health.to_string().as_bytes(), 90);
        assert!(crate::udp_sealed::answer_datagram(&wrong, &state, peer).is_none());
        // Damaged in flight.
        let mut damaged = datagram.clone();
        let last = damaged.len() - 1;
        damaged[last] ^= 1;
        assert!(crate::udp_sealed::answer_datagram(&damaged, &state, peer).is_none());
        // An all-zero (low order) ephemeral key.
        let zero = vec![0_u8; 200];
        assert!(crate::udp_sealed::answer_datagram(&zero, &state, peer).is_none());
    }

    #[test]
    fn cleartext_udp_still_works_and_health_offers_sealing() {
        let state = test_state();
        let peer: SocketAddr = "198.51.100.43:5000".parse().unwrap();
        let answer = udp_with_cookie(&state, peer, json!({"action": "health"}));
        assert_eq!(answer["ok"], true, "{answer}");
        let line = json!({"action": "health"}).to_string();
        let health = handle_request_bytes(line.as_bytes(), line.len(), &state, "198.51.100.43");
        // Session-only health may be hidden without sessions in this
        // config; when it shows v2, it offers sealed UDP.
        if health["stats"]["v2"].is_object() {
            assert_eq!(health["stats"]["v2"]["udp_sealed"], 1, "{health}");
        }
    }

    #[test]
    fn a_sealed_cookie_reply_is_never_longer_than_its_request() {
        use crate::udp_sealed::client_for_tests::seal_request;
        let state = test_state();
        let peer: SocketAddr = "198.51.100.50:5000".parse().unwrap();
        let health = json!({"action": "health"}).to_string();
        for _ in 0..30 {
            // The shortest request a cookie is given to: 128 bytes on the wire.
            let pad = 128 - 62 - health.len();
            let (datagram, _) = seal_request(&state.identity.noise_public, health.as_bytes(), pad);
            assert_eq!(datagram.len(), 128);
            let answer = crate::udp_sealed::answer_datagram(&datagram, &state, peer)
                .expect("a cookie reply");
            assert!(
                answer.len() <= datagram.len(),
                "{} byte reply to a {} byte request",
                answer.len(),
                datagram.len()
            );
        }
    }

    #[test]
    fn a_source_asking_for_too_many_key_exchanges_is_not_served() {
        use crate::udp_sealed::client_for_tests::seal_request;
        let mut config = test_config();
        config.max_requests_per_minute = 40;
        let state = RelayState::new(config, test_identity());
        let health = json!({"action": "health", "pad": "x".repeat(100)}).to_string();
        let (datagram, _) = seal_request(&state.identity.noise_public, health.as_bytes(), 0);
        let noisy: SocketAddr = "198.51.100.60:5000".parse().unwrap();
        let answered = (0..200)
            .filter(|_| crate::udp_sealed::answer_datagram(&datagram, &state, noisy).is_some())
            .count();
        assert!(answered <= 45, "{answered} of 200 were served");
        let quiet: SocketAddr = "198.51.100.61:5000".parse().unwrap();
        assert!(crate::udp_sealed::answer_datagram(&datagram, &state, quiet).is_some());
    }
}
