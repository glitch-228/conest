//! The relay's configuration: defaults, environment variables and flags.

use std::env;
use std::path::PathBuf;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

pub(crate) const DEFAULT_BIND: &str = "0.0.0.0:7667";
pub(crate) const DEFAULT_TTL_SECONDS: u64 = 7 * 24 * 60 * 60;
pub(crate) const DEFAULT_MAX_QUEUE_PER_MAILBOX: usize = 512;
pub(crate) const DEFAULT_MAX_FETCH_LIMIT: usize = 128;
pub(crate) const DEFAULT_MAX_ENVELOPE_BYTES: usize = 256 * 1024;
pub(crate) const DEFAULT_MAX_LINE_BYTES: usize = 300 * 1024;
// Per address, every request: many users can share one behind a carrier's
// NAT, and fetches, acks and health checks cost the relay little.
pub(crate) const DEFAULT_MAX_REQUESTS_PER_MINUTE: u32 = 1200;
// Per address, what fills the disk or answers unproven sources: stores
// (count and bytes), and every UDP request (a datagram's source can be
// forged, so its answer must not be worth reflecting).
pub(crate) const DEFAULT_MAX_STORES_PER_MINUTE: u32 = 240;
pub(crate) const DEFAULT_MAX_STORE_BYTES_PER_MINUTE: u64 = 32 * 1024 * 1024;
// Long-polls one address may hold open at once (each holds a worker); more
// are answered at once instead of waiting.
pub(crate) const DEFAULT_MAX_LONG_POLLS_PER_PEER: usize = 16;
// Connections one address may hold open at once (past it, refused at once):
// one address cannot take every worker. Not applied behind a trusted proxy,
// where every client shares the proxy's address.
pub(crate) const DEFAULT_MAX_CONNECTIONS_PER_PEER: usize = 16;
// Everything the relay keeps, all mailboxes together: past it, stores are
// refused (a mailbox's own quota does not bound a flood of new mailboxes).
pub(crate) const DEFAULT_MAX_TOTAL_BYTES: u64 = 4 * 1024 * 1024 * 1024;
// What one address (an IPv6 /48) may hold on the relay at once: past it,
// its stores are refused; when the relay is full, the largest holder's
// oldest entries make room.
pub(crate) const DEFAULT_MAX_STORED_BYTES_PER_PEER: u64 = 256 * 1024 * 1024;
// A request must arrive within this, however slowly its bytes come.
pub(crate) const REQUEST_READ_DEADLINE: Duration = Duration::from_secs(10);
// A response must be taken within this (a big fetch on a slow link fits).
pub(crate) const RESPONSE_WRITE_DEADLINE: Duration = Duration::from_secs(120);
// Addresses tracked by each rate map at most: past it, new ones are refused
// (a flood of forged UDP sources cannot grow them without bound).
pub(crate) const DEFAULT_MAX_RATE_KEYS: usize = 100_000;
// A cookie request (no cookie yet) is answered only when it is at least
// this long, so the answer is never larger than what came in.
pub(crate) const UDP_COOKIE_REQUEST_MIN_BYTES: usize = 128;
pub(crate) const DEFAULT_IDENTITY_SEED_FILE: &str = "conest_relay_identity.seed";
pub(crate) const DEFAULT_MAX_BYTES_PER_MAILBOX_PER_MINUTE: u64 = 10 * 1024 * 1024;
pub(crate) const DEFAULT_SOFT_BAN_THRESHOLD: u32 = 10;
pub(crate) const DEFAULT_SOFT_BAN_SECONDS: u64 = 300;
pub(crate) const DEFAULT_MAX_CONNECTIONS: usize = 1024;
pub(crate) const DEFAULT_DATABASE_PATH: &str = "conest_relay.sqlite3";
pub(crate) const DEFAULT_MAX_MAILBOX_BYTES: u64 = 64 * 1024 * 1024;
pub(crate) const DEFAULT_LEASE_MILLIS: u64 = 30_000;
// `senderDeviceId` is client-controlled, so the dedup-by-sender pass alone
// cannot bound pairing announcements in a mailbox: a flood of announcements
// with random sender ids would otherwise bypass the byte quota (pairing is
// exempt from it by design) and crowd the queue. Capping the count bounds
// the worst case to MAX_PAIRING_PER_MAILBOX * max_envelope_bytes.
pub(crate) const MAX_PAIRING_PER_MAILBOX: usize = 8;

#[derive(Debug, Clone)]
pub(crate) struct RelayConfig {
    pub(crate) bind: String,
    pub(crate) relay_id: String,
    pub(crate) ttl: Duration,
    pub(crate) max_queue_per_mailbox: usize,
    pub(crate) max_fetch_limit: usize,
    pub(crate) max_envelope_bytes: usize,
    pub(crate) max_line_bytes: usize,
    pub(crate) max_requests_per_minute: u32,
    pub(crate) max_stores_per_minute: u32,
    pub(crate) max_store_bytes_per_minute: u64,
    pub(crate) max_long_polls_per_peer: usize,
    pub(crate) max_connections_per_peer: usize,
    pub(crate) max_total_bytes: u64,
    pub(crate) max_stored_bytes_per_peer: u64,
    pub(crate) max_rate_keys: usize,
    pub(crate) trust_forwarded_for: bool,
    pub(crate) identity_seed_path: PathBuf,
    pub(crate) identity_seed_inline: Option<String>,
    pub(crate) max_bytes_per_mailbox_per_minute: u64,
    pub(crate) soft_ban_threshold: u32,
    pub(crate) soft_ban_duration: Duration,
    pub(crate) max_connections: usize,
    pub(crate) database_path: PathBuf,
    pub(crate) max_mailbox_bytes: u64,
    /// Everything added after v1 (the tokio server, sessions, registration,
    /// the outer layer): one field, so the v1 fields stay as they were.
    pub(crate) ext: ExtConfig,
}

/// Settings added with relay v2. Every default keeps an updated relay
/// serving v1 exactly as before.
#[derive(Debug, Clone)]
pub(crate) struct ExtConfig {
    /// Run the old server, one thread per connection (a rollback the
    /// supervisor can choose).
    pub(crate) legacy_threads: bool,
    /// How long a request may take to arrive (tests shorten it).
    pub(crate) read_deadline: Duration,
    /// Serve v2 sessions (`CNS2`) on the same port (`--no-sessions` turns
    /// them off; the threaded server has none).
    pub(crate) sessions: bool,
    /// Requests one session may have in flight at once.
    pub(crate) session_max_streams: usize,
    /// Subscriptions one session may hold.
    pub(crate) session_max_subscriptions: usize,
    /// A session that sends nothing (not even a ping) for this long ends.
    pub(crate) session_idle: Duration,
    /// Mailboxes one address (an IPv6 /48) may claim a day.
    pub(crate) mailbox_claims_per_day: u32,
    /// A claim unused this many days lapses (the mailbox is open again).
    pub(crate) owner_idle_days: u64,
    /// Claimed mailboxes the relay keeps at most.
    pub(crate) max_owners: usize,
    /// Who may store messages (tier 1): open, registered or off.
    pub(crate) tier1: crate::registration::Tier1Policy,
    /// How accounts register: open, invite, password or closed.
    pub(crate) registration: crate::registration::RegistrationPolicy,
    /// The password `registration password` asks for.
    pub(crate) registration_password: Option<String>,
    /// A new account's store budget, in bytes a minute.
    pub(crate) account_quota_bytes: u64,
    /// How long a token lasts (clients refresh before).
    pub(crate) token_lifetime: Duration,
    /// Where TLS (the outer layer) listens, e.g. 0.0.0.0:443 (off: none).
    pub(crate) tls_bind: Option<String>,
    /// The certificate chain and private key (PEM) TLS serves.
    pub(crate) tls_cert: Option<PathBuf>,
    pub(crate) tls_key: Option<PathBuf>,
    /// The secret WebSocket path (default: made once, kept).
    pub(crate) ws_path: Option<String>,
    /// What everything else on the TLS port gets: files from a directory,
    /// or a reverse proxy to `host:port` (default: a plain welcome page).
    pub(crate) decoy_dir: Option<PathBuf>,
    pub(crate) decoy_proxy: Option<String>,
    /// The name clients reach the TLS port by (its certificate's): with
    /// it, the relay tells clients in a session its hidden address,
    /// `wss://<public-host>[:port]/<path>` (never over v1).
    pub(crate) public_host: Option<String>,
    /// Where the borrowed-handshake layer listens (M38-D), the real site
    /// it plays (`host:port`), and the name clients put in their SNI
    /// (default: the site's host).
    pub(crate) borrow_bind: Option<String>,
    pub(crate) borrow_site: Option<String>,
    pub(crate) borrow_sni: Option<String>,
}

impl Default for ExtConfig {
    fn default() -> Self {
        Self {
            legacy_threads: false,
            read_deadline: REQUEST_READ_DEADLINE,
            sessions: true,
            session_max_streams: DEFAULT_SESSION_MAX_STREAMS,
            session_max_subscriptions: DEFAULT_SESSION_MAX_SUBSCRIPTIONS,
            session_idle: DEFAULT_SESSION_IDLE,
            mailbox_claims_per_day: DEFAULT_MAILBOX_CLAIMS_PER_DAY,
            owner_idle_days: DEFAULT_OWNER_IDLE_DAYS,
            max_owners: DEFAULT_MAX_OWNERS,
            tier1: crate::registration::Tier1Policy::Open,
            registration: crate::registration::RegistrationPolicy::Closed,
            registration_password: None,
            account_quota_bytes: DEFAULT_MAX_STORE_BYTES_PER_MINUTE,
            token_lifetime: DEFAULT_TOKEN_LIFETIME,
            tls_bind: None,
            tls_cert: None,
            tls_key: None,
            ws_path: None,
            decoy_dir: None,
            decoy_proxy: None,
            public_host: None,
            borrow_bind: None,
            borrow_site: None,
            borrow_sni: None,
        }
    }
}

impl ExtConfig {
    /// Whether this relay serves (and so advertises) v2 sessions.
    pub(crate) fn sessions_enabled(&self) -> bool {
        self.sessions && !self.legacy_threads
    }
}

pub(crate) const DEFAULT_SESSION_MAX_STREAMS: usize = 32;
pub(crate) const DEFAULT_SESSION_MAX_SUBSCRIPTIONS: usize = 4;
pub(crate) const DEFAULT_SESSION_IDLE: Duration = Duration::from_secs(120);
pub(crate) const DEFAULT_MAILBOX_CLAIMS_PER_DAY: u32 = 64;
pub(crate) const DEFAULT_OWNER_IDLE_DAYS: u64 = 60;
pub(crate) const DEFAULT_MAX_OWNERS: usize = 1_000_000;
pub(crate) const DEFAULT_TOKEN_LIFETIME: Duration = Duration::from_secs(30 * 24 * 60 * 60);
/// The configuration file a relay reads when started without `--config`:
/// next to its database. Each line is `name = value` (or a bare `name`),
/// the name a flag without its dashes; flags on the command line win.
pub(crate) const DEFAULT_CONFIG_FILE: &str = "relay.conf";

/// The arguments a configuration file adds (before the command line's).
pub(crate) fn config_file_args(cli: &[String]) -> Result<Vec<String>, String> {
    let explicit = cli
        .iter()
        .position(|arg| arg == "--config")
        .map(|index| {
            cli.get(index + 1)
                .cloned()
                .ok_or_else(|| "--config requires a path".to_owned())
        })
        .transpose()?;
    let path = match explicit {
        Some(path) => PathBuf::from(path),
        None => {
            let database = cli
                .iter()
                .position(|arg| arg == "--database-path")
                .and_then(|index| cli.get(index + 1).cloned())
                .or_else(|| env::var("CONEST_RELAY_DATABASE_PATH").ok())
                .unwrap_or_else(|| DEFAULT_DATABASE_PATH.to_owned());
            let candidate = PathBuf::from(database)
                .parent()
                .map(|parent| parent.join(DEFAULT_CONFIG_FILE))
                .unwrap_or_else(|| PathBuf::from(DEFAULT_CONFIG_FILE));
            if !candidate.is_file() {
                return Ok(Vec::new());
            }
            candidate
        }
    };
    let text = std::fs::read_to_string(&path)
        .map_err(|error| format!("reading {}: {error}", path.display()))?;
    parse_config_text(&text)
}

pub(crate) fn parse_config_text(text: &str) -> Result<Vec<String>, String> {
    let mut args = Vec::new();
    for (number, line) in text.lines().enumerate() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let (name, value) = match line.split_once('=') {
            Some((name, value)) => (name.trim(), Some(value.trim())),
            None => (line, None),
        };
        if name.is_empty()
            || !name
                .bytes()
                .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'-')
        {
            return Err(format!("config line {}: bad name {name:?}", number + 1));
        }
        if name == "config" {
            return Err(format!(
                "config line {}: config cannot name another",
                number + 1
            ));
        }
        args.push(format!("--{name}"));
        if let Some(value) = value {
            let value = value.trim_matches('"');
            if !matches!(value, "true" | "yes" | "on") {
                args.push(value.to_owned());
            }
        }
    }
    Ok(args)
}

impl RelayConfig {
    pub(crate) fn from_env_and_args() -> Result<Self, String> {
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
            max_stores_per_minute: env_u32(
                "CONEST_RELAY_MAX_STORES_PER_MINUTE",
                DEFAULT_MAX_STORES_PER_MINUTE,
            ),
            max_store_bytes_per_minute: env_u64(
                "CONEST_RELAY_MAX_STORE_BYTES_PER_MINUTE",
                DEFAULT_MAX_STORE_BYTES_PER_MINUTE,
            ),
            max_long_polls_per_peer: env_usize(
                "CONEST_RELAY_MAX_LONG_POLLS_PER_PEER",
                DEFAULT_MAX_LONG_POLLS_PER_PEER,
            ),
            max_connections_per_peer: env_usize(
                "CONEST_RELAY_MAX_CONNECTIONS_PER_PEER",
                DEFAULT_MAX_CONNECTIONS_PER_PEER,
            ),
            max_total_bytes: env_u64("CONEST_RELAY_MAX_TOTAL_BYTES", DEFAULT_MAX_TOTAL_BYTES),
            max_stored_bytes_per_peer: env_u64(
                "CONEST_RELAY_MAX_STORED_BYTES_PER_PEER",
                DEFAULT_MAX_STORED_BYTES_PER_PEER,
            ),
            max_rate_keys: env_usize("CONEST_RELAY_MAX_RATE_KEYS", DEFAULT_MAX_RATE_KEYS),
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
            ext: ExtConfig {
                legacy_threads: env_bool("CONEST_RELAY_LEGACY_THREADS", false),
                sessions: !env_bool("CONEST_RELAY_NO_SESSIONS", false),
                ..ExtConfig::default()
            },
        };

        let cli: Vec<String> = env::args().skip(1).collect();
        let mut all = config_file_args(&cli)?;
        all.extend(cli);
        let mut args = all.into_iter().peekable();
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
                "--max-stores-per-minute" => {
                    config.max_stores_per_minute = parse_next_u32(&mut args, &arg)?;
                }
                "--max-store-bytes-per-minute" => {
                    config.max_store_bytes_per_minute = parse_next_u64(&mut args, &arg)?;
                }
                "--max-long-polls-per-peer" => {
                    config.max_long_polls_per_peer = parse_next_usize(&mut args, &arg)?;
                }
                "--max-connections-per-peer" => {
                    config.max_connections_per_peer = parse_next_usize(&mut args, &arg)?;
                }
                "--max-total-bytes" => {
                    config.max_total_bytes = parse_next_u64(&mut args, &arg)?;
                }
                "--max-stored-bytes-per-peer" => {
                    config.max_stored_bytes_per_peer = parse_next_u64(&mut args, &arg)?;
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
                "--legacy-threads" => {
                    config.ext.legacy_threads = true;
                }
                "--no-sessions" => {
                    config.ext.sessions = false;
                }
                "--mailbox-claims-per-day" => {
                    config.ext.mailbox_claims_per_day = parse_next_u32(&mut args, &arg)?;
                }
                "--owner-idle-days" => {
                    config.ext.owner_idle_days = parse_next_u64(&mut args, &arg)?;
                }
                "--config" => {
                    // Read already (config_file_args).
                    let _ = parse_next_string(&mut args, &arg)?;
                }
                "--bind" => {
                    config.bind = parse_next_string(&mut args, &arg)?;
                }
                "--tier1" => {
                    config.ext.tier1 = crate::registration::Tier1Policy::parse(
                        &parse_next_string(&mut args, &arg)?,
                    )?;
                }
                "--registration" => {
                    config.ext.registration = crate::registration::RegistrationPolicy::parse(
                        &parse_next_string(&mut args, &arg)?,
                    )?;
                }
                "--registration-password" => {
                    config.ext.registration_password = Some(parse_next_string(&mut args, &arg)?);
                }
                "--tls-bind" => {
                    config.ext.tls_bind = Some(parse_next_string(&mut args, &arg)?);
                }
                "--tls-cert" => {
                    config.ext.tls_cert = Some(PathBuf::from(parse_next_string(&mut args, &arg)?));
                }
                "--tls-key" => {
                    config.ext.tls_key = Some(PathBuf::from(parse_next_string(&mut args, &arg)?));
                }
                "--ws-path" => {
                    config.ext.ws_path = Some(parse_next_string(&mut args, &arg)?);
                }
                "--decoy-dir" => {
                    config.ext.decoy_dir = Some(PathBuf::from(parse_next_string(&mut args, &arg)?));
                }
                "--public-host" => {
                    config.ext.public_host = Some(parse_next_string(&mut args, &arg)?);
                }
                "--borrow-bind" => {
                    config.ext.borrow_bind = Some(parse_next_string(&mut args, &arg)?);
                }
                "--borrow-site" => {
                    config.ext.borrow_site = Some(parse_next_string(&mut args, &arg)?);
                }
                "--borrow-sni" => {
                    config.ext.borrow_sni = Some(parse_next_string(&mut args, &arg)?);
                }
                "--decoy-proxy" => {
                    config.ext.decoy_proxy = Some(parse_next_string(&mut args, &arg)?);
                }
                "--account-quota-bytes" => {
                    config.ext.account_quota_bytes = parse_next_u64(&mut args, &arg)?;
                }
                "--token-days" => {
                    config.ext.token_lifetime = Duration::from_secs(
                        parse_next_u64(&mut args, &arg)?.clamp(1, 365) * 86_400,
                    );
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
        if config.max_long_polls_per_peer == 0
            || config.max_connections_per_peer == 0
            || config.max_total_bytes == 0
        {
            return Err(
                "long polls and connections per peer, and total bytes, must be greater than zero"
                    .to_owned(),
            );
        }
        if config.max_stores_per_minute == 0 || config.max_store_bytes_per_minute == 0 {
            return Err(
                "max stores and store bytes per minute must be greater than zero".to_owned(),
            );
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
        if config.ext.tls_bind.is_some()
            && (config.ext.tls_cert.is_none() || config.ext.tls_key.is_none())
        {
            return Err("--tls-bind needs --tls-cert and --tls-key".to_owned());
        }
        if config.ext.borrow_bind.is_some() && config.ext.borrow_site.is_none() {
            return Err("--borrow-bind needs --borrow-site (the real site to play)".to_owned());
        }
        if let Some(path) = &config.ext.ws_path {
            let path = path.trim_start_matches('/');
            if path.len() < 8
                || path.len() > 64
                || !path
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-' || byte == b'_')
            {
                return Err(
                    "--ws-path must be 8..64 letters, digits, - or _ (it is a secret)".to_owned(),
                );
            }
        }
        if config.ext.registration == crate::registration::RegistrationPolicy::Password
            && config
                .ext
                .registration_password
                .as_deref()
                .is_none_or(|password| password.len() < 8)
        {
            return Err(
                "registration password needs --registration-password (at least 8 characters)"
                    .to_owned(),
            );
        }
        Ok(config)
    }
}

pub(crate) fn env_u64(name: &str, default: u64) -> u64 {
    env::var(name)
        .ok()
        .and_then(|value| value.parse::<u64>().ok())
        .unwrap_or(default)
}

pub(crate) fn env_u32(name: &str, default: u32) -> u32 {
    env::var(name)
        .ok()
        .and_then(|value| value.parse::<u32>().ok())
        .unwrap_or(default)
}

pub(crate) fn env_usize(name: &str, default: usize) -> usize {
    env::var(name)
        .ok()
        .and_then(|value| value.parse::<usize>().ok())
        .unwrap_or(default)
}

pub(crate) fn env_bool(name: &str, default: bool) -> bool {
    match env::var(name).ok().as_deref() {
        Some(value) => matches!(
            value.trim().to_ascii_lowercase().as_str(),
            "1" | "true" | "yes" | "on"
        ),
        None => default,
    }
}

pub(crate) fn parse_next_u64<I>(args: &mut I, name: &str) -> Result<u64, String>
where
    I: Iterator<Item = String>,
{
    args.next()
        .ok_or_else(|| format!("{name} requires a value"))?
        .parse::<u64>()
        .map_err(|_| format!("{name} requires an integer value"))
}

pub(crate) fn parse_next_u32<I>(args: &mut I, name: &str) -> Result<u32, String>
where
    I: Iterator<Item = String>,
{
    args.next()
        .ok_or_else(|| format!("{name} requires a value"))?
        .parse::<u32>()
        .map_err(|_| format!("{name} requires an integer value"))
}

pub(crate) fn parse_next_usize<I>(args: &mut I, name: &str) -> Result<usize, String>
where
    I: Iterator<Item = String>,
{
    args.next()
        .ok_or_else(|| format!("{name} requires a value"))?
        .parse::<usize>()
        .map_err(|_| format!("{name} requires an integer value"))
}

pub(crate) fn parse_next_string<I>(args: &mut I, name: &str) -> Result<String, String>
where
    I: Iterator<Item = String>,
{
    args.next()
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| format!("{name} requires a non-empty value"))
}

pub(crate) fn usage() -> String {
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
           --max-requests-per-minute N   every request, per address\n\
           --max-stores-per-minute N     stores and UDP requests, per address\n\
           --max-store-bytes-per-minute N  bytes stored, per address\n\
           --max-long-polls-per-peer N   long-polls open at once, per address\n\
           --max-connections-per-peer N  connections open at once, per address\n\
           --max-total-bytes N           everything stored, all mailboxes\n\
           --max-stored-bytes-per-peer N what one address may hold at once\n\
           --database-path PATH       SQLite WAL queue database\n\
           --max-mailbox-bytes N      durable mailbox byte quota\n\
           --trust-forwarded-for  trust the last X-Forwarded-For address\n\
                                  for per-IP rate limiting (only safe behind a\n\
                                  trusted proxy or HTTP tunnel)\n\
           --legacy-threads       run the old one-thread-per-connection server\n\
           --no-sessions          do not serve v2 sessions (CNS2)\n\
           --mailbox-claims-per-day N  mailbox claims per address a day\n\
           --owner-idle-days N    days unused before a mailbox claim lapses\n\
           --config PATH          a file of `name = value` lines (default: relay.conf\n\
                                  next to the database, if there)\n\
           --tier1 open|registered|off      who may store messages (default open)\n\
           --registration open|invite|password|closed  (default closed)\n\
           --registration-password TEXT     (or CONEST_RELAY_REGISTRATION_PASSWORD)\n\
           --account-quota-bytes N          an account's bytes a minute\n\
           --token-days N                   how long a token lasts (default 30)\n\
           --tls-bind ADDR --tls-cert PEM --tls-key PEM  TLS (e.g. on 443) with a\n\
                                  WebSocket on a secret path and a decoy site\n\
           --ws-path SECRET       the WebSocket path (default: made once, kept)\n\
           --decoy-dir DIR | --decoy-proxy HOST:PORT  what everyone else sees\n\
           --borrow-bind ADDR --borrow-site HOST:PORT [--borrow-sni NAME]\n\
                                  play a real site's TLS handshake on ADDR\n\
                                  (forwarded to it); Conest clients prove\n\
                                  themselves right after it\n\
           --public-host NAME     the TLS port's name; clients in a session learn\n\
                                  the hidden address wss://NAME/<path>\n\n\
         Admin: conest_relay admin [--database-path PATH] invite create|invite list|\n\
                account list|account remove KEY|quota set KEY BYTES"
    )
}

pub(crate) fn default_relay_id() -> String {
    format!("relay-{}-{}", std::process::id(), now_millis())
}

pub(crate) fn now_millis() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}
