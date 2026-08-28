use std::collections::HashMap;
use std::env;
use std::fs;
use std::io::{BufRead, BufReader, BufWriter, Write};
use std::net::{SocketAddr, TcpListener, UdpSocket};
use std::path::PathBuf;
use std::sync::{Arc, Condvar, Mutex};
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use base64::Engine;
use base64::engine::general_purpose::STANDARD as BASE64_STANDARD;
use ed25519_dalek::{Signer, SigningKey};
use rusqlite::{Connection, params};
use serde::{Deserialize, Serialize};
use serde_json::Value;

const DEFAULT_BIND: &str = "0.0.0.0:7667";
const DEFAULT_TTL_SECONDS: u64 = 7 * 24 * 60 * 60;
const DEFAULT_MAX_QUEUE_PER_MAILBOX: usize = 512;
const DEFAULT_MAX_FETCH_LIMIT: usize = 128;
const DEFAULT_MAX_ENVELOPE_BYTES: usize = 256 * 1024;
const DEFAULT_MAX_LINE_BYTES: usize = 300 * 1024;
const DEFAULT_MAX_REQUESTS_PER_MINUTE: u32 = 240;
const DEFAULT_IDENTITY_SEED_FILE: &str = "conest_relay_identity.seed";
const DEFAULT_MAX_BYTES_PER_MAILBOX_PER_MINUTE: u64 = 10 * 1024 * 1024;
const DEFAULT_SOFT_BAN_THRESHOLD: u32 = 5;
const DEFAULT_SOFT_BAN_SECONDS: u64 = 300;
const DEFAULT_MAX_CONNECTIONS: usize = 1024;
const DEFAULT_DATABASE_PATH: &str = "conest_relay.sqlite3";
const DEFAULT_MAX_MAILBOX_BYTES: u64 = 64 * 1024 * 1024;
const DEFAULT_LEASE_MILLIS: u64 = 30_000;
// `senderDeviceId` is client-controlled, so the dedup-by-sender pass alone
// cannot bound pairing announcements in a mailbox: a flood of announcements
// with random sender ids would otherwise bypass the byte quota (pairing is
// exempt from it by design) and crowd the queue. Capping the count bounds
// the worst case to MAX_PAIRING_PER_MAILBOX * max_envelope_bytes.
const MAX_PAIRING_PER_MAILBOX: usize = 8;

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
    trust_forwarded_for: bool,
    identity_seed_path: PathBuf,
    identity_seed_inline: Option<String>,
    max_bytes_per_mailbox_per_minute: u64,
    soft_ban_threshold: u32,
    soft_ban_duration: Duration,
    max_connections: usize,
    database_path: PathBuf,
    max_mailbox_bytes: u64,
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
            trust_forwarded_for: env_bool("CONEST_RELAY_TRUST_FORWARDED_FOR", false),
            identity_seed_path: env::var("CONEST_RELAY_IDENTITY_SEED_PATH")
                .map(PathBuf::from)
                .unwrap_or_else(|_| PathBuf::from(DEFAULT_IDENTITY_SEED_FILE)),
            identity_seed_inline: env::var("CONEST_RELAY_IDENTITY_SEED").ok(),
            max_bytes_per_mailbox_per_minute: env_u64(
                "CONEST_RELAY_MAX_BYTES_PER_MAILBOX_PER_MINUTE",
                DEFAULT_MAX_BYTES_PER_MAILBOX_PER_MINUTE,
            ),
            soft_ban_threshold: env_u32(
                "CONEST_RELAY_SOFT_BAN_THRESHOLD",
                DEFAULT_SOFT_BAN_THRESHOLD,
            ),
            soft_ban_duration: Duration::from_secs(env_u64(
                "CONEST_RELAY_SOFT_BAN_SECONDS",
                DEFAULT_SOFT_BAN_SECONDS,
            )),
            max_connections: env_usize("CONEST_RELAY_MAX_CONNECTIONS", DEFAULT_MAX_CONNECTIONS),
            database_path: env::var("CONEST_RELAY_DATABASE_PATH")
                .map(PathBuf::from)
                .unwrap_or_else(|_| PathBuf::from(DEFAULT_DATABASE_PATH)),
            max_mailbox_bytes: env_u64("CONEST_RELAY_MAX_MAILBOX_BYTES", DEFAULT_MAX_MAILBOX_BYTES),
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
                "--trust-forwarded-for" => {
                    config.trust_forwarded_for = true;
                }
                "--identity-seed-path" => {
                    config.identity_seed_path = PathBuf::from(parse_next_string(&mut args, &arg)?);
                }
                "--max-bytes-per-mailbox-per-minute" => {
                    config.max_bytes_per_mailbox_per_minute = parse_next_u64(&mut args, &arg)?;
                }
                "--soft-ban-threshold" => {
                    config.soft_ban_threshold = parse_next_u32(&mut args, &arg)?;
                }
                "--soft-ban-seconds" => {
                    config.soft_ban_duration =
                        Duration::from_secs(parse_next_u64(&mut args, &arg)?);
                }
                "--max-connections" => {
                    config.max_connections = parse_next_usize(&mut args, &arg)?;
                }
                "--database-path" => {
                    config.database_path = PathBuf::from(parse_next_string(&mut args, &arg)?);
                }
                "--max-mailbox-bytes" => {
                    config.max_mailbox_bytes = parse_next_u64(&mut args, &arg)?;
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
        if config.max_connections == 0 {
            return Err("max connections must be greater than zero".to_owned());
        }
        if config.max_mailbox_bytes == 0 {
            return Err("max mailbox bytes must be greater than zero".to_owned());
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

const LONG_POLL_MAX_WAIT_MS: u64 = 25_000;

#[derive(Debug, Serialize)]
#[cfg_attr(test, derive(Deserialize))]
struct RelayStats {
    relay_id: String,
    version: String,
    queue_count: usize,
    queued_envelope_count: usize,
    queued_bytes: u64,
    active_leases: usize,
    ttl_seconds: u64,
    max_queue_per_mailbox: usize,
    max_fetch_limit: usize,
    identity_public_key: String,
}

#[derive(Clone)]
struct RelayIdentity {
    signing_key: SigningKey,
    public_key_b64: String,
}

impl std::fmt::Debug for RelayIdentity {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("RelayIdentity")
            .field("public_key_b64", &self.public_key_b64)
            .finish()
    }
}

impl RelayIdentity {
    fn from_seed_bytes(seed: [u8; 32]) -> Self {
        let signing_key = SigningKey::from_bytes(&seed);
        let public_key_b64 = BASE64_STANDARD.encode(signing_key.verifying_key().to_bytes());
        Self {
            signing_key,
            public_key_b64,
        }
    }

    /// Loads the relay's persistent Ed25519 identity. Resolution order:
    ///   1. `identity_seed_inline` (base64) — for stateless deployments
    ///      where the seed comes from a secrets manager.
    ///   2. `identity_seed_path` — read 32 raw bytes if the file exists.
    ///   3. Generate a fresh seed with `OsRng` and persist it to the path.
    ///
    /// On unix the freshly-written file is chmod'd 0600. Failures during
    /// the read/write are propagated so the operator notices instead of
    /// silently rotating the relay's identity.
    fn load_or_generate(config: &RelayConfig) -> Result<Self, String> {
        if let Some(inline) = &config.identity_seed_inline {
            let trimmed = inline.trim();
            if !trimmed.is_empty() {
                let bytes = BASE64_STANDARD.decode(trimmed).map_err(|error| {
                    format!("CONEST_RELAY_IDENTITY_SEED is not base64: {error}")
                })?;
                if bytes.len() != 32 {
                    return Err(format!(
                        "CONEST_RELAY_IDENTITY_SEED must decode to 32 bytes (got {})",
                        bytes.len()
                    ));
                }
                let mut seed = [0_u8; 32];
                seed.copy_from_slice(&bytes);
                return Ok(Self::from_seed_bytes(seed));
            }
        }
        let path = &config.identity_seed_path;
        if path.exists() {
            let bytes = fs::read(path)
                .map_err(|error| format!("reading identity seed at {}: {error}", path.display()))?;
            if bytes.len() != 32 {
                return Err(format!(
                    "identity seed at {} must be exactly 32 bytes (got {})",
                    path.display(),
                    bytes.len()
                ));
            }
            let mut seed = [0_u8; 32];
            seed.copy_from_slice(&bytes);
            return Ok(Self::from_seed_bytes(seed));
        }
        // Generate + persist a fresh seed.
        use rand::RngCore;
        let mut seed = [0_u8; 32];
        rand::rngs::OsRng.fill_bytes(&mut seed);
        if let Some(parent) = path.parent()
            && !parent.as_os_str().is_empty()
        {
            fs::create_dir_all(parent).map_err(|error| {
                format!(
                    "creating identity seed directory {}: {error}",
                    parent.display()
                )
            })?;
        }
        fs::write(path, seed)
            .map_err(|error| format!("writing identity seed to {}: {error}", path.display()))?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = fs::set_permissions(path, fs::Permissions::from_mode(0o600));
        }
        Ok(Self::from_seed_bytes(seed))
    }

    fn sign(&self, message: &[u8]) -> [u8; 64] {
        self.signing_key.sign(message).to_bytes()
    }
}

#[derive(Debug, Serialize)]
#[cfg_attr(test, derive(Deserialize))]
struct RelayResponse {
    ok: bool,
    stored: bool,
    messages: Vec<Value>,
    error: Option<String>,
    stats: Option<RelayStats>,
    #[serde(skip_serializing_if = "Option::is_none")]
    nonce_echo: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    signature: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    lease_id: Option<String>,
}

impl RelayResponse {
    fn ok(stats: Option<RelayStats>) -> Self {
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

    fn stored() -> Self {
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

    fn messages(messages: Vec<Value>) -> Self {
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

    fn error(message: impl Into<String>) -> Self {
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

    fn leased(messages: Vec<Value>, lease_id: Option<String>) -> Self {
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

#[derive(Clone)]
struct RateBucket {
    window_started_millis: u64,
    count: u32,
}

#[derive(Clone)]
struct MailboxByteWindow {
    window_started_millis: u64,
    bytes_used: u64,
}

#[derive(Clone)]
struct BanEntry {
    banned_until_millis: u64,
    consecutive_violations: u32,
}

/// Per-mailbox arrival notifier shared between [`RelayState::store`] (which
/// signals on a successful enqueue) and [`RelayState::fetch`]'s long-poll
/// path (which waits up to `LONG_POLL_MAX_WAIT_MS` on the condvar). The
/// The generation predicate closes the drain-before-wait race: a store that
/// lands between the initial drain and the condvar wait increments the value,
/// so the fetch observes the change instead of sleeping through it.
#[derive(Default)]
struct MailboxSignal {
    generation: u64,
    waiters: usize,
}

type MailboxNotifier = Arc<(Mutex<MailboxSignal>, Condvar)>;

#[derive(Clone)]
struct RelayState {
    config: RelayConfig,
    database: Arc<Mutex<Connection>>,
    notifiers: Arc<Mutex<HashMap<String, MailboxNotifier>>>,
    rate_buckets: Arc<Mutex<HashMap<String, RateBucket>>>,
    mailbox_bytes: Arc<Mutex<HashMap<String, MailboxByteWindow>>>,
    banned_peers: Arc<Mutex<HashMap<String, BanEntry>>>,
    identity: Arc<RelayIdentity>,
}

impl RelayState {
    #[cfg(test)]
    fn new(config: RelayConfig, identity: RelayIdentity) -> Self {
        Self::try_new(config, identity).expect("relay database should initialize")
    }

    fn try_new(config: RelayConfig, identity: RelayIdentity) -> Result<Self, String> {
        if config.database_path.as_path() != std::path::Path::new(":memory:")
            && let Some(parent) = config.database_path.parent()
            && !parent.as_os_str().is_empty()
        {
            fs::create_dir_all(parent).map_err(|error| {
                format!(
                    "creating relay database directory {}: {error}",
                    parent.display()
                )
            })?;
        }
        let database = Connection::open(&config.database_path).map_err(|error| {
            format!(
                "opening relay database at {}: {error}",
                config.database_path.display()
            )
        })?;
        database
            .busy_timeout(Duration::from_secs(5))
            .map_err(|error| format!("configuring relay database timeout: {error}"))?;
        database
            .execute_batch(
                "PRAGMA journal_mode=WAL;
                 PRAGMA synchronous=FULL;
                 PRAGMA foreign_keys=ON;
                 CREATE TABLE IF NOT EXISTS queue_entries (
                   id INTEGER PRIMARY KEY AUTOINCREMENT,
                   mailbox TEXT NOT NULL,
                   queued_at_millis INTEGER NOT NULL,
                   envelope_json TEXT NOT NULL,
                   envelope_bytes INTEGER NOT NULL,
                   kind TEXT,
                   sender_device_id TEXT,
                   dedup_key TEXT,
                   lease_id TEXT,
                   lease_until_millis INTEGER
                 );
                 CREATE INDEX IF NOT EXISTS queue_mailbox_ready
                   ON queue_entries(mailbox, lease_id, id);
                 CREATE UNIQUE INDEX IF NOT EXISTS queue_mailbox_dedup
                   ON queue_entries(mailbox, dedup_key)
                   WHERE dedup_key IS NOT NULL;
                 CREATE INDEX IF NOT EXISTS queue_lease
                   ON queue_entries(lease_id);
                 UPDATE queue_entries
                    SET lease_id = NULL, lease_until_millis = NULL
                  WHERE lease_id IS NOT NULL;",
            )
            .map_err(|error| format!("initializing relay database: {error}"))?;
        Ok(Self {
            config,
            database: Arc::new(Mutex::new(database)),
            notifiers: Arc::new(Mutex::new(HashMap::new())),
            rate_buckets: Arc::new(Mutex::new(HashMap::new())),
            mailbox_bytes: Arc::new(Mutex::new(HashMap::new())),
            banned_peers: Arc::new(Mutex::new(HashMap::new())),
            identity: Arc::new(identity),
        })
    }

    fn notifier_for(&self, mailbox: &str) -> MailboxNotifier {
        let mut map = self
            .notifiers
            .lock()
            .expect("notifier lock should not poison");
        map.entry(mailbox.to_owned())
            .or_insert_with(|| Arc::new((Mutex::new(MailboxSignal::default()), Condvar::new())))
            .clone()
    }

    fn existing_notifier(&self, mailbox: &str) -> Option<MailboxNotifier> {
        self.notifiers
            .lock()
            .expect("notifier lock should not poison")
            .get(mailbox)
            .cloned()
    }

    fn prune_notifier(&self, mailbox: &str, notifier: &MailboxNotifier) {
        let mut map = self
            .notifiers
            .lock()
            .expect("notifier lock should not poison");
        let removable = map
            .get(mailbox)
            .is_some_and(|current| Arc::ptr_eq(current, notifier))
            && notifier
                .0
                .lock()
                .expect("notifier mutex should not poison")
                .waiters
                == 0
            && Arc::strong_count(notifier) <= 2;
        if removable {
            map.remove(mailbox);
        }
    }

    fn allow_request(&self, peer: &str) -> bool {
        let now = now_millis();
        // Soft-ban check first — a banned peer is rejected outright until
        // the timer expires, regardless of per-minute budget. Expired
        // ban entries and stale violation tallies (no violation in the
        // last two minutes) are dropped so the map stays bounded; an
        // active violation tally below the threshold is kept so a peer
        // can't reset its slate by sleeping through the rate-limit window.
        {
            let mut bans = self
                .banned_peers
                .lock()
                .expect("ban lock should not poison");
            bans.retain(|_, entry| {
                if entry.banned_until_millis > now {
                    return true;
                }
                if entry.banned_until_millis > 0 {
                    // Ban expired and no longer in flight.
                    return false;
                }
                // Pending tally (never banned): keep it as long as the
                // tally is non-zero — the per-minute window already
                // resets the bucket count, so the tally itself drives
                // the soft-ban threshold across consecutive bursts.
                entry.consecutive_violations > 0
            });
            if let Some(entry) = bans.get(peer)
                && entry.banned_until_millis > now
            {
                return false;
            }
        }

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
            // Over the rate limit: tally a violation and, if it crosses
            // the soft-ban threshold, install a temporary ban that even
            // a fresh minute window cannot bypass.
            drop(buckets);
            self.note_rate_violation(peer, now);
            return false;
        }
        bucket.count += 1;
        // A legit request resets the consecutive-violation counter so
        // well-behaved clients don't accumulate slate after a brief burst.
        drop(buckets);
        self.note_rate_compliance(peer);
        true
    }

    fn note_rate_violation(&self, peer: &str, now_millis_value: u64) {
        let mut bans = self
            .banned_peers
            .lock()
            .expect("ban lock should not poison");
        let entry = bans.entry(peer.to_owned()).or_insert(BanEntry {
            banned_until_millis: 0,
            consecutive_violations: 0,
        });
        entry.consecutive_violations = entry.consecutive_violations.saturating_add(1);
        if entry.consecutive_violations >= self.config.soft_ban_threshold {
            entry.banned_until_millis =
                now_millis_value.saturating_add(self.config.soft_ban_duration.as_millis() as u64);
        }
    }

    fn note_rate_compliance(&self, peer: &str) {
        let mut bans = self
            .banned_peers
            .lock()
            .expect("ban lock should not poison");
        if let Some(entry) = bans.get_mut(peer)
            && entry.banned_until_millis == 0
        {
            // Only reset the counter if no active ban is in flight;
            // otherwise we'd let banned peers wear down the counter
            // mid-ban by piggybacking on others' compliance signals.
            entry.consecutive_violations = 0;
        }
    }

    fn allow_mailbox_bytes(&self, mailbox: &str, bytes: u64) -> bool {
        if self.config.max_bytes_per_mailbox_per_minute == 0 {
            return true;
        }
        let now = now_millis();
        let mut windows = self
            .mailbox_bytes
            .lock()
            .expect("mailbox bytes lock should not poison");
        windows.retain(|_, w| now.saturating_sub(w.window_started_millis) < 120_000);
        let window = windows
            .entry(mailbox.to_owned())
            .or_insert(MailboxByteWindow {
                window_started_millis: now,
                bytes_used: 0,
            });
        if now.saturating_sub(window.window_started_millis) >= 60_000 {
            window.window_started_millis = now;
            window.bytes_used = 0;
        }
        if window.bytes_used.saturating_add(bytes) > self.config.max_bytes_per_mailbox_per_minute {
            return false;
        }
        window.bytes_used = window.bytes_used.saturating_add(bytes);
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
        // Pairing-announcement envelopes bypass the per-mailbox throughput
        // cap: they're tiny, dedup-by-sender already at the queue layer,
        // and rate-limiting them would defeat codephrase discovery.
        let counts_against_quota = envelope_kind(&envelope) != Some("pairing_announcement");
        if counts_against_quota
            && !self.allow_mailbox_bytes(&recipient_device_id, envelope_bytes.len() as u64)
        {
            return Err("mailbox throughput quota exceeded".to_owned());
        }
        let kind = envelope_kind(&envelope).map(str::to_owned);
        let sender = envelope_sender_device_id(&envelope).map(str::to_owned);
        let dedup_key = envelope
            .get("messageId")
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty() && value.len() <= 256)
            .map(str::to_owned);
        let encoded = String::from_utf8(envelope_bytes)
            .map_err(|_| "serialized envelope was not UTF-8".to_owned())?;
        let encoded_len = encoded.len() as u64;
        let now = now_millis();
        let cutoff = now.saturating_sub(self.config.ttl.as_millis() as u64);
        let mut database = self
            .database
            .lock()
            .expect("relay database lock should not poison");
        let transaction = database
            .transaction()
            .map_err(|error| format!("beginning relay enqueue: {error}"))?;
        transaction
            .execute(
                "DELETE FROM queue_entries WHERE queued_at_millis < ?1",
                params![cutoff],
            )
            .map_err(|error| format!("cleaning relay queue: {error}"))?;

        if let Some(key) = &dedup_key {
            let already_present: bool = transaction
                .query_row(
                    "SELECT EXISTS(SELECT 1 FROM queue_entries
                                    WHERE mailbox = ?1 AND dedup_key = ?2)",
                    params![&recipient_device_id, key],
                    |row| row.get(0),
                )
                .map_err(|error| format!("checking relay deduplication: {error}"))?;
            if already_present {
                transaction
                    .commit()
                    .map_err(|error| format!("committing relay deduplication: {error}"))?;
                return Ok(());
            }
        }

        if kind.as_deref() == Some("pairing_announcement") {
            if let Some(sender) = &sender {
                transaction
                    .execute(
                        "DELETE FROM queue_entries
                          WHERE mailbox = ?1 AND kind = 'pairing_announcement'
                            AND sender_device_id = ?2",
                        params![&recipient_device_id, sender],
                    )
                    .map_err(|error| format!("deduplicating pairing announcement: {error}"))?;
            }
            loop {
                let pairing_count: usize = transaction
                    .query_row(
                        "SELECT COUNT(*) FROM queue_entries
                          WHERE mailbox = ?1 AND kind = 'pairing_announcement'",
                        params![&recipient_device_id],
                        |row| row.get(0),
                    )
                    .map_err(|error| format!("counting pairing announcements: {error}"))?;
                if pairing_count < MAX_PAIRING_PER_MAILBOX {
                    break;
                }
                transaction
                    .execute(
                        "DELETE FROM queue_entries WHERE id = (
                           SELECT id FROM queue_entries
                            WHERE mailbox = ?1 AND kind = 'pairing_announcement'
                              AND lease_id IS NULL
                            ORDER BY id LIMIT 1
                         )",
                        params![&recipient_device_id],
                    )
                    .map_err(|error| format!("evicting pairing announcement: {error}"))?;
            }
        }

        loop {
            let (count, bytes): (usize, u64) = transaction
                .query_row(
                    "SELECT COUNT(*), COALESCE(SUM(envelope_bytes), 0)
                       FROM queue_entries WHERE mailbox = ?1",
                    params![&recipient_device_id],
                    |row| Ok((row.get(0)?, row.get(1)?)),
                )
                .map_err(|error| format!("measuring relay mailbox: {error}"))?;
            if count < self.config.max_queue_per_mailbox
                && bytes.saturating_add(encoded_len) <= self.config.max_mailbox_bytes
            {
                break;
            }
            let removed = transaction
                .execute(
                    "DELETE FROM queue_entries WHERE id = COALESCE(
                       (SELECT id FROM queue_entries
                         WHERE mailbox = ?1 AND lease_id IS NULL
                           AND kind != 'pairing_announcement'
                         ORDER BY id LIMIT 1),
                       (SELECT id FROM queue_entries
                         WHERE mailbox = ?1 AND lease_id IS NULL
                         ORDER BY id LIMIT 1)
                     )",
                    params![&recipient_device_id],
                )
                .map_err(|error| format!("evicting over-quota relay envelope: {error}"))?;
            if removed == 0 {
                return Err("envelope exceeds mailbox byte quota".to_owned());
            }
        }

        transaction
            .execute(
                "INSERT INTO queue_entries
                   (mailbox, queued_at_millis, envelope_json, envelope_bytes,
                    kind, sender_device_id, dedup_key)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
                params![
                    &recipient_device_id,
                    now,
                    encoded,
                    encoded_len,
                    kind,
                    sender,
                    dedup_key
                ],
            )
            .map_err(|error| format!("persisting relay envelope: {error}"))?;
        transaction
            .commit()
            .map_err(|error| format!("committing relay envelope: {error}"))?;
        if let Some(notifier) = self.existing_notifier(&recipient_device_id) {
            let mut signal = notifier.0.lock().expect("notifier mutex should not poison");
            signal.generation = signal.generation.wrapping_add(1);
            notifier.1.notify_all();
        }
        Ok(())
    }

    fn fetch(
        &self,
        recipient_device_id: &str,
        limit: Option<usize>,
        wait_ms: Option<u64>,
    ) -> Result<Vec<Value>, String> {
        validate_mailbox_id(recipient_device_id)?;
        let limit = limit
            .unwrap_or(self.config.max_fetch_limit)
            .clamp(1, self.config.max_fetch_limit);
        let wait_ms = match wait_ms {
            Some(value) if value > 0 => Some(value.min(LONG_POLL_MAX_WAIT_MS)),
            _ => None,
        };
        let notifier = wait_ms.map(|_| self.notifier_for(recipient_device_id));
        let observed_generation = notifier.as_ref().map(|notifier| {
            notifier
                .0
                .lock()
                .expect("notifier mutex should not poison")
                .generation
        });
        let first = self.drain_queue_result(recipient_device_id, limit)?;
        if !first.is_empty() {
            if let Some(notifier) = &notifier {
                self.prune_notifier(recipient_device_id, notifier);
            }
            return Ok(first);
        }
        let Some(wait_ms) = wait_ms else {
            return Ok(first);
        };
        let notifier = notifier.expect("wait duration implies notifier");
        let observed_generation = observed_generation.expect("wait duration implies generation");
        let mut guard = notifier.0.lock().expect("notifier mutex should not poison");
        if guard.generation == observed_generation {
            guard.waiters += 1;
            let (returned, _) = notifier
                .1
                .wait_timeout_while(guard, Duration::from_millis(wait_ms), |signal| {
                    signal.generation == observed_generation
                })
                .expect("notifier condvar should not poison");
            guard = returned;
            guard.waiters = guard.waiters.saturating_sub(1);
        }
        drop(guard);
        let result = self.drain_queue_result(recipient_device_id, limit)?;
        self.prune_notifier(recipient_device_id, &notifier);
        Ok(result)
    }

    #[cfg(test)]
    fn drain_queue(&self, recipient_device_id: &str, limit: usize) -> Vec<Value> {
        self.drain_queue_result(recipient_device_id, limit)
            .unwrap_or_default()
    }

    fn drain_queue_result(
        &self,
        recipient_device_id: &str,
        limit: usize,
    ) -> Result<Vec<Value>, String> {
        self.take_queue(recipient_device_id, limit, None)
            .map(|(messages, _)| messages)
    }

    fn fetch_leased(
        &self,
        recipient_device_id: &str,
        limit: Option<usize>,
        wait_ms: Option<u64>,
        lease_ms: Option<u64>,
    ) -> Result<(Vec<Value>, Option<String>), String> {
        validate_mailbox_id(recipient_device_id)?;
        let limit = limit
            .unwrap_or(self.config.max_fetch_limit)
            .clamp(1, self.config.max_fetch_limit);
        let lease_ms = lease_ms
            .unwrap_or(DEFAULT_LEASE_MILLIS)
            .clamp(5_000, 300_000);
        let wait_ms = match wait_ms {
            Some(value) if value > 0 => Some(value.min(LONG_POLL_MAX_WAIT_MS)),
            _ => None,
        };
        let notifier = wait_ms.map(|_| self.notifier_for(recipient_device_id));
        let observed_generation = notifier.as_ref().map(|notifier| {
            notifier
                .0
                .lock()
                .expect("notifier mutex should not poison")
                .generation
        });
        let first = self.take_queue(recipient_device_id, limit, Some(lease_ms))?;
        if !first.0.is_empty() {
            if let Some(notifier) = &notifier {
                self.prune_notifier(recipient_device_id, notifier);
            }
            return Ok(first);
        }
        let Some(wait_ms) = wait_ms else {
            return Ok(first);
        };
        let notifier = notifier.expect("wait duration implies notifier");
        let observed_generation = observed_generation.expect("wait duration implies generation");
        let mut guard = notifier.0.lock().expect("notifier mutex should not poison");
        if guard.generation == observed_generation {
            guard.waiters += 1;
            let (returned, _) = notifier
                .1
                .wait_timeout_while(guard, Duration::from_millis(wait_ms), |signal| {
                    signal.generation == observed_generation
                })
                .expect("notifier condvar should not poison");
            guard = returned;
            guard.waiters = guard.waiters.saturating_sub(1);
        }
        drop(guard);
        let result = self.take_queue(recipient_device_id, limit, Some(lease_ms));
        self.prune_notifier(recipient_device_id, &notifier);
        result
    }

    fn take_queue(
        &self,
        recipient_device_id: &str,
        limit: usize,
        lease_ms: Option<u64>,
    ) -> Result<(Vec<Value>, Option<String>), String> {
        let now = now_millis();
        let cutoff = now.saturating_sub(self.config.ttl.as_millis() as u64);
        let lease_id = lease_ms.map(|_| {
            use rand::RngCore;
            let mut bytes = [0_u8; 18];
            rand::rngs::OsRng.fill_bytes(&mut bytes);
            BASE64_STANDARD.encode(bytes)
        });
        let mut database = self
            .database
            .lock()
            .expect("relay database lock should not poison");
        let transaction = database
            .transaction()
            .map_err(|error| format!("beginning relay fetch: {error}"))?;
        transaction
            .execute(
                "DELETE FROM queue_entries WHERE queued_at_millis < ?1",
                params![cutoff],
            )
            .map_err(|error| format!("cleaning relay queue: {error}"))?;
        transaction
            .execute(
                "UPDATE queue_entries
                    SET lease_id = NULL, lease_until_millis = NULL
                  WHERE lease_until_millis IS NOT NULL AND lease_until_millis <= ?1",
                params![now],
            )
            .map_err(|error| format!("releasing expired relay leases: {error}"))?;
        let rows: Vec<(i64, String, Option<String>)> = {
            let mut statement = transaction
                .prepare(
                    "SELECT id, envelope_json, kind FROM queue_entries
                      WHERE mailbox = ?1 AND lease_id IS NULL
                      ORDER BY id LIMIT ?2",
                )
                .map_err(|error| format!("preparing relay fetch: {error}"))?;
            let selected = statement
                .query_map(params![recipient_device_id, limit], |row| {
                    Ok((row.get(0)?, row.get(1)?, row.get(2)?))
                })
                .map_err(|error| format!("querying relay fetch: {error}"))?;
            selected
                .collect::<Result<Vec<_>, _>>()
                .map_err(|error| format!("reading relay fetch: {error}"))?
        };
        let mut messages = Vec::with_capacity(rows.len());
        for (id, encoded, kind) in &rows {
            match serde_json::from_str::<Value>(encoded) {
                Ok(envelope) => messages.push(envelope),
                Err(_) => {
                    transaction
                        .execute("DELETE FROM queue_entries WHERE id = ?1", params![id])
                        .map_err(|error| format!("dropping corrupt relay row: {error}"))?;
                    continue;
                }
            }
            if kind.as_deref() == Some("pairing_announcement") {
                continue;
            }
            if let (Some(lease_id), Some(lease_ms)) = (&lease_id, lease_ms) {
                transaction
                    .execute(
                        "UPDATE queue_entries
                            SET lease_id = ?1, lease_until_millis = ?2
                          WHERE id = ?3",
                        params![lease_id, now.saturating_add(lease_ms), id],
                    )
                    .map_err(|error| format!("leasing relay envelope: {error}"))?;
            } else {
                transaction
                    .execute("DELETE FROM queue_entries WHERE id = ?1", params![id])
                    .map_err(|error| format!("acknowledging legacy relay fetch: {error}"))?;
            }
        }
        transaction
            .commit()
            .map_err(|error| format!("committing relay fetch: {error}"))?;
        let returned_lease = if rows
            .iter()
            .any(|(_, _, kind)| kind.as_deref() != Some("pairing_announcement"))
        {
            lease_id
        } else {
            None
        };
        Ok((messages, returned_lease))
    }

    fn acknowledge_lease(&self, recipient_device_id: &str, lease_id: &str) -> Result<(), String> {
        validate_mailbox_id(recipient_device_id)?;
        if lease_id.len() < 16 || lease_id.len() > 128 {
            return Err("lease id has an invalid length".to_owned());
        }
        let database = self
            .database
            .lock()
            .expect("relay database lock should not poison");
        database
            .execute(
                "DELETE FROM queue_entries WHERE mailbox = ?1 AND lease_id = ?2",
                params![recipient_device_id, lease_id],
            )
            .map_err(|error| format!("acknowledging relay lease: {error}"))?;
        Ok(())
    }

    fn stats(&self) -> RelayStats {
        let now = now_millis();
        let cutoff = now.saturating_sub(self.config.ttl.as_millis() as u64);
        let database = self
            .database
            .lock()
            .expect("relay database lock should not poison");
        let _ = database.execute(
            "DELETE FROM queue_entries WHERE queued_at_millis < ?1",
            params![cutoff],
        );
        let (queue_count, queued_envelope_count, queued_bytes): (usize, usize, u64) = database
            .query_row(
                "SELECT COUNT(DISTINCT mailbox), COUNT(*),
                        COALESCE(SUM(envelope_bytes), 0)
                   FROM queue_entries",
                [],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .unwrap_or_default();
        let active_leases = database
            .query_row(
                "SELECT COUNT(DISTINCT lease_id) FROM queue_entries
                  WHERE lease_id IS NOT NULL AND lease_until_millis > ?1",
                params![now],
                |row| row.get(0),
            )
            .unwrap_or(0);
        RelayStats {
            relay_id: self.config.relay_id.clone(),
            // Release builds inject the signed manifest version so the
            // supervisor can prove that the staged binary, rather than an
            // older process, passed its post-update health gate. Local builds
            // retain the Cargo package version.
            version: option_env!("CONEST_BUILD_VERSION")
                .unwrap_or(env!("CARGO_PKG_VERSION"))
                .to_owned(),
            queue_count,
            queued_envelope_count,
            queued_bytes,
            active_leases,
            ttl_seconds: self.config.ttl.as_secs(),
            max_queue_per_mailbox: self.config.max_queue_per_mailbox,
            max_fetch_limit: self.config.max_fetch_limit,
            identity_public_key: self.identity.public_key_b64.clone(),
        }
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
    let identity = match RelayIdentity::load_or_generate(&config) {
        Ok(identity) => identity,
        Err(message) => {
            eprintln!("relay identity setup failed: {message}");
            std::process::exit(2);
        }
    };
    let listener = TcpListener::bind(&config.bind)?;
    let udp_socket = UdpSocket::bind(&config.bind)?;
    let identity_public_key = identity.public_key_b64.clone();
    let state = match RelayState::try_new(config.clone(), identity) {
        Ok(state) => state,
        Err(message) => {
            eprintln!("relay database setup failed: {message}");
            std::process::exit(2);
        }
    };
    println!(
        "conest relay listening on tcp+udp {} id={} ttl={}s max_queue={} max_fetch={} max_envelope={}B max_rate={}/min identity_pub={}",
        config.bind,
        config.relay_id,
        config.ttl.as_secs(),
        config.max_queue_per_mailbox,
        config.max_fetch_limit,
        config.max_envelope_bytes,
        config.max_requests_per_minute,
        identity_public_key,
    );

    {
        let state = state.clone();
        let config = config.clone();
        thread::spawn(move || serve_udp(udp_socket, state, config));
    }

    // Every accepted connection holds a worker thread — a long-poll fetch
    // for up to ~25 s — so an unbounded accept loop is a cheap thread/memory
    // exhaustion vector. Past the cap, connections get a best-effort error
    // line and are dropped; clients treat it like any other route failure.
    let active_connections = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    for stream in listener.incoming() {
        match stream {
            Ok(mut stream) => {
                let active = Arc::clone(&active_connections);
                if active.fetch_add(1, std::sync::atomic::Ordering::AcqRel)
                    >= config.max_connections
                {
                    active.fetch_sub(1, std::sync::atomic::Ordering::AcqRel);
                    let _ = stream.set_write_timeout(Some(Duration::from_secs(1)));
                    let _ = stream.write_all(b"{\"ok\":false,\"error\":\"relay at capacity\"}\n");
                    continue;
                }
                let state = state.clone();
                thread::spawn(move || {
                    let _guard = ConnectionGuard(active);
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

/// Decrements the active-connection counter when a worker thread exits,
/// including on panic, so a wedged or crashed handler can never leak a
/// connection slot.
struct ConnectionGuard(Arc<std::sync::atomic::AtomicUsize>);

impl Drop for ConnectionGuard {
    fn drop(&mut self) {
        self.0.fetch_sub(1, std::sync::atomic::Ordering::AcqRel);
    }
}

fn handle_client(
    stream: std::net::TcpStream,
    state: RelayState,
    peer: String,
) -> std::io::Result<()> {
    let reader_stream = stream.try_clone()?;
    reader_stream.set_read_timeout(Some(Duration::from_secs(5)))?;
    // A slow or stuck client should not be able to wedge a relay worker thread
    // by accepting writes byte-by-byte. The 10-second write timeout covers the
    // worst-case response size with plenty of headroom.
    stream.set_write_timeout(Some(Duration::from_secs(10)))?;
    let mut reader = BufReader::new(reader_stream);
    let mut writer = BufWriter::new(stream);

    let mut line = String::new();
    let bytes_read = read_line_bounded(&mut reader, &mut line, state.config.max_line_bytes)?;
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

fn read_line_bounded<R: BufRead>(
    reader: &mut R,
    output: &mut String,
    max_bytes: usize,
) -> std::io::Result<usize> {
    let mut bytes = Vec::with_capacity(max_bytes.min(8 * 1024));
    loop {
        let available = reader.fill_buf()?;
        if available.is_empty() {
            break;
        }
        let take = available
            .iter()
            .position(|byte| *byte == b'\n')
            .map_or(available.len(), |index| index + 1);
        if bytes.len().saturating_add(take) > max_bytes {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "request line too large",
            ));
        }
        bytes.extend_from_slice(&available[..take]);
        reader.consume(take);
        if bytes.last() == Some(&b'\n') {
            break;
        }
    }
    let text = std::str::from_utf8(&bytes).map_err(|error| {
        std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            format!("request line is not utf-8: {error}"),
        )
    })?;
    output.push_str(text);
    Ok(bytes.len())
}

fn is_http_request_line(line: &str) -> bool {
    line.starts_with("GET ") || line.starts_with("POST ") || line.starts_with("OPTIONS ")
}

fn handle_http_request<R: BufRead>(
    request_line: &str,
    reader: &mut R,
    state: &RelayState,
    peer: &str,
) -> (u16, Value) {
    let mut parts = request_line.split_whitespace();
    let method = parts.next().unwrap_or_default();
    let path = parts.next().unwrap_or("/");
    let path_without_query = match path.split_once('?') {
        Some((head, _)) => head,
        None => path,
    };
    if path_without_query != "/"
        && path_without_query != "/health"
        && path_without_query != "/relay"
    {
        return (
            404,
            to_wire(RelayResponse::error("unknown HTTP relay path")),
        );
    }

    let mut headers = Vec::new();
    let mut content_length: Option<usize> = None;
    let mut forwarded_for: Option<String> = None;
    let mut header_count = 0_usize;
    loop {
        let mut line = String::new();
        let remaining = state.config.max_line_bytes.saturating_sub(headers.len());
        match read_line_bounded(reader, &mut line, remaining) {
            Ok(0) => {
                return (
                    400,
                    to_wire(RelayResponse::error("incomplete HTTP headers")),
                );
            }
            Ok(_) => {
                if line == "\r\n" || line == "\n" {
                    break;
                }
                if headers.len() + line.len() > state.config.max_line_bytes {
                    return (413, to_wire(RelayResponse::error("HTTP headers too large")));
                }
                header_count += 1;
                if header_count > 100 {
                    return (413, to_wire(RelayResponse::error("too many HTTP headers")));
                }
                if let Some((name, value)) = line.split_once(':') {
                    let name = name.trim();
                    if name.eq_ignore_ascii_case("content-length") {
                        let parsed = match value.trim().parse::<usize>() {
                            Ok(value) => value,
                            Err(_) => {
                                return (
                                    400,
                                    to_wire(RelayResponse::error("invalid Content-Length")),
                                );
                            }
                        };
                        if content_length.is_some_and(|existing| existing != parsed) {
                            return (
                                400,
                                to_wire(RelayResponse::error("conflicting Content-Length")),
                            );
                        }
                        content_length = Some(parsed);
                    } else if state.config.trust_forwarded_for
                        && forwarded_for.is_none()
                        && name.eq_ignore_ascii_case("x-forwarded-for")
                    {
                        // Use the leftmost address: it is the original client
                        // per the convention used by every common proxy.
                        if let Some(first) = value.split(',').next() {
                            let trimmed = first.trim();
                            if !trimmed.is_empty() {
                                forwarded_for = Some(trimmed.to_owned());
                            }
                        }
                    }
                }
                headers.extend_from_slice(line.as_bytes());
            }
            Err(error) => {
                let status = if error.kind() == std::io::ErrorKind::InvalidData {
                    413
                } else {
                    400
                };
                return (
                    status,
                    to_wire(RelayResponse::error(format!(
                        "HTTP header read failed: {error}"
                    ))),
                );
            }
        }
    }

    let effective_peer = forwarded_for.as_deref().unwrap_or(peer);

    match method {
        "GET" | "OPTIONS" => {
            if !state.allow_request(effective_peer) {
                return (429, to_wire(RelayResponse::error("rate limit exceeded")));
            }
            (200, to_wire(handle_request(RelayRequest::Health, state)))
        }
        "POST" => {
            let content_length = content_length.unwrap_or(0);
            if content_length == 0 {
                return (
                    400,
                    to_wire(RelayResponse::error("HTTP relay POST body is empty")),
                );
            }
            if content_length > state.config.max_line_bytes {
                return (
                    413,
                    to_wire(RelayResponse::error("HTTP relay POST body too large")),
                );
            }
            let mut body = vec![0_u8; content_length];
            if let Err(error) = reader.read_exact(&mut body) {
                return (
                    400,
                    to_wire(RelayResponse::error(format!(
                        "HTTP body read failed: {error}"
                    ))),
                );
            }
            (
                200,
                handle_request_bytes(&body, body.len(), state, effective_peer),
            )
        }
        _ => (
            405,
            to_wire(RelayResponse::error("unsupported HTTP method")),
        ),
    }
}

fn write_http_response<W: Write>(
    writer: &mut W,
    status: u16,
    response: &Value,
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
) -> Value {
    let peer_key = peer.ip().to_string();
    handle_request_bytes(datagram, bytes_read, state, &peer_key)
}

fn handle_request_bytes(bytes: &[u8], bytes_read: usize, state: &RelayState, peer: &str) -> Value {
    if bytes_read > state.config.max_line_bytes {
        return to_wire(RelayResponse::error("request line too large"));
    }
    if !state.allow_request(peer) {
        return to_wire(RelayResponse::error("rate limit exceeded"));
    }
    let line = match std::str::from_utf8(bytes) {
        Ok(value) => value,
        Err(error) => {
            return to_wire(RelayResponse::error(format!(
                "request is not utf-8: {error}"
            )));
        }
    };
    let trimmed = line.trim();
    // Parse once into a Value so we can extract optional out-of-band fields
    // (like `nonce`) before deserializing into the typed request enum. New
    // clients pass `"nonce": "<base64-16-bytes>"` alongside the action;
    // legacy clients omit it and receive an unsigned response.
    let parsed: Value = match serde_json::from_str(trimmed) {
        Ok(value) => value,
        Err(error) => {
            return to_wire(RelayResponse::error(format!("invalid request: {error}")));
        }
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
    let request: RelayRequest = match serde_json::from_value(parsed) {
        Ok(request) => request,
        Err(error) => {
            return finalize_wire(
                RelayResponse::error(format!("invalid request: {error}")),
                &action,
                nonce_bytes.as_deref(),
                detached,
                &state.identity,
            );
        }
    };
    let response = handle_request(request, state);
    finalize_wire(
        response,
        &action,
        nonce_bytes.as_deref(),
        detached,
        &state.identity,
    )
}

/// Serializes a response for the wire. Infallible by construction; the
/// fallback shape only exists so a serialization bug cannot crash the relay.
fn to_wire(response: RelayResponse) -> Value {
    serde_json::to_value(&response)
        .unwrap_or_else(|_| serde_json::json!({"ok": false, "error": "response encoding failed"}))
}

fn finalize_wire(
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
fn finalize_detached_response(
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
fn finalize_response(
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

fn env_bool(name: &str, default: bool) -> bool {
    match env::var(name).ok().as_deref() {
        Some(value) => matches!(
            value.trim().to_ascii_lowercase().as_str(),
            "1" | "true" | "yes" | "on"
        ),
        None => default,
    }
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
           --max-requests-per-minute N\n\
           --database-path PATH       SQLite WAL queue database\n\
           --max-mailbox-bytes N      durable mailbox byte quota\n\
           --trust-forwarded-for  trust the leftmost X-Forwarded-For address\n\
                                  for per-IP rate limiting (only safe behind a\n\
                                  trusted proxy or HTTP tunnel)"
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
            trust_forwarded_for: false,
            identity_seed_path: PathBuf::from(""),
            identity_seed_inline: None,
            max_bytes_per_mailbox_per_minute: DEFAULT_MAX_BYTES_PER_MAILBOX_PER_MINUTE,
            soft_ban_threshold: DEFAULT_SOFT_BAN_THRESHOLD,
            soft_ban_duration: Duration::from_secs(DEFAULT_SOFT_BAN_SECONDS),
            max_connections: DEFAULT_MAX_CONNECTIONS,
            database_path: PathBuf::from(":memory:"),
            max_mailbox_bytes: DEFAULT_MAX_MAILBOX_BYTES,
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

        let stored = handle_udp_datagram(store.as_bytes(), store.len(), &state, peer);
        let fetched = handle_udp_datagram(fetch.as_bytes(), fetch.len(), &state, peer);

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
            }),
            nonce_echo: None,
            signature: None,
            lease_id: response.lease_id.clone(),
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
}
