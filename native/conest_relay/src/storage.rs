//! The relay's queue: one SQLite database (one connection, so one writer;
//! the tokio server reaches it through blocking tasks) and the per-mailbox
//! arrival signals long-polls and subscriptions wait on.

use std::collections::HashMap;
use std::fs;
use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;

use base64::Engine;
use base64::engine::general_purpose::STANDARD as BASE64_STANDARD;
use ed25519_dalek::SigningKey;
use rusqlite::{Connection, params};
use serde_json::Value;

use crate::config::{DEFAULT_LEASE_MILLIS, MAX_PAIRING_PER_MAILBOX, RelayConfig, now_millis};
use crate::identity::RelayIdentity;
use crate::limits::{BanEntry, MailboxByteWindow, RateBucket, StoreWindow, peer_group};
use crate::v1::{
    LONG_POLL_MAX_WAIT_MS, RelayStats, envelope_kind, envelope_sender_device_id,
    validate_mailbox_id,
};

/// Per-mailbox arrival notifier shared between [`RelayState::store`] (which
/// signals on a successful enqueue) and [`RelayState::fetch`]'s long-poll
/// path (which waits up to `LONG_POLL_MAX_WAIT_MS` on the condvar). The
/// The generation predicate closes the drain-before-wait race: a store that
/// lands between the initial drain and the condvar wait increments the value,
/// so the fetch observes the change instead of sleeping through it.
///
/// The tokio server waits on [notify] instead of the condvar (a waiting
/// fetch there holds no thread); a store wakes both.
#[derive(Default)]
pub(crate) struct MailboxSignal {
    pub(crate) generation: u64,
    pub(crate) waiters: usize,
    pub(crate) notify: Arc<tokio::sync::Notify>,
}

pub(crate) type MailboxNotifier = Arc<(Mutex<MailboxSignal>, Condvar)>;

#[derive(Clone)]
pub(crate) struct RelayState {
    pub(crate) config: RelayConfig,
    pub(crate) database: Arc<Mutex<Connection>>,
    pub(crate) notifiers: Arc<Mutex<HashMap<String, MailboxNotifier>>>,
    pub(crate) rate_buckets: Arc<Mutex<HashMap<String, RateBucket>>>,
    pub(crate) store_windows: Arc<Mutex<HashMap<String, StoreWindow>>>,
    pub(crate) long_polls: Arc<Mutex<HashMap<String, usize>>>,
    pub(crate) connections: Arc<Mutex<HashMap<String, usize>>>,
    // When the rate maps were last pruned (at most once a second).
    pub(crate) rates_pruned_at: Arc<std::sync::atomic::AtomicU64>,
    // Signs UDP cookies only (never the relay's identity key).
    pub(crate) udp_cookie_key: Arc<SigningKey>,
    pub(crate) mailbox_bytes: Arc<Mutex<HashMap<String, MailboxByteWindow>>>,
    pub(crate) banned_peers: Arc<Mutex<HashMap<String, BanEntry>>>,
    pub(crate) identity: Arc<RelayIdentity>,
    /// Who owns which mailbox (see `owners.rs`).
    pub(crate) owners: Arc<Mutex<crate::owners::Owners>>,
    /// Registered accounts (see `registration.rs`).
    pub(crate) accounts: Arc<Mutex<crate::registration::Accounts>>,
    /// The key tokens are MACed with (kept in the database).
    pub(crate) token_secret: Arc<Vec<u8>>,
    /// How many times the queue was read (tests watch for busy loops).
    pub(crate) queue_reads: Arc<std::sync::atomic::AtomicU64>,
}

impl RelayState {
    #[cfg(test)]
    pub(crate) fn new(config: RelayConfig, identity: RelayIdentity) -> Self {
        Self::try_new(config, identity).expect("relay database should initialize")
    }

    pub(crate) fn try_new(config: RelayConfig, identity: RelayIdentity) -> Result<Self, String> {
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
        // Who stored each entry (older databases get the column; their rows
        // count as no one's).
        let _ = database.execute("ALTER TABLE queue_entries ADD COLUMN source TEXT", []);
        // Everything stored, kept by the database itself on every insert and
        // delete (measuring it would read every row).
        database
            .execute_batch(
                "CREATE INDEX IF NOT EXISTS queue_source ON queue_entries(source);
                 CREATE TABLE IF NOT EXISTS stored_total (
                   id INTEGER PRIMARY KEY CHECK (id = 1),
                   bytes INTEGER NOT NULL
                 );
                 INSERT OR IGNORE INTO stored_total (id, bytes)
                   SELECT 1, COALESCE(SUM(envelope_bytes), 0) FROM queue_entries;
                 CREATE TRIGGER IF NOT EXISTS stored_total_insert
                   AFTER INSERT ON queue_entries BEGIN
                     UPDATE stored_total SET bytes = bytes + NEW.envelope_bytes WHERE id = 1;
                   END;
                 CREATE TRIGGER IF NOT EXISTS stored_total_delete
                   AFTER DELETE ON queue_entries BEGIN
                     UPDATE stored_total SET bytes = bytes - OLD.envelope_bytes WHERE id = 1;
                   END;",
            )
            .map_err(|error| format!("initializing relay storage total: {error}"))?;
        let token_secret = crate::registration::init_tables(&database)?;
        let state = Self {
            config,
            database: Arc::new(Mutex::new(database)),
            notifiers: Arc::new(Mutex::new(HashMap::new())),
            rate_buckets: Arc::new(Mutex::new(HashMap::new())),
            store_windows: Arc::new(Mutex::new(HashMap::new())),
            long_polls: Arc::new(Mutex::new(HashMap::new())),
            connections: Arc::new(Mutex::new(HashMap::new())),
            rates_pruned_at: Arc::new(std::sync::atomic::AtomicU64::new(0)),
            udp_cookie_key: Arc::new(SigningKey::generate(&mut rand::rngs::OsRng)),
            mailbox_bytes: Arc::new(Mutex::new(HashMap::new())),
            banned_peers: Arc::new(Mutex::new(HashMap::new())),
            identity: Arc::new(identity),
            owners: Arc::new(Mutex::new(crate::owners::Owners::default())),
            accounts: Arc::new(Mutex::new(crate::registration::Accounts::default())),
            token_secret: Arc::new(token_secret),
            queue_reads: Arc::new(std::sync::atomic::AtomicU64::new(0)),
        };
        state.load_owners()?;
        state.load_accounts()?;
        Ok(state)
    }

    pub(crate) fn notifier_for(&self, mailbox: &str) -> MailboxNotifier {
        let mut map = self
            .notifiers
            .lock()
            .expect("notifier lock should not poison");
        map.entry(mailbox.to_owned())
            .or_insert_with(|| Arc::new((Mutex::new(MailboxSignal::default()), Condvar::new())))
            .clone()
    }

    pub(crate) fn existing_notifier(&self, mailbox: &str) -> Option<MailboxNotifier> {
        self.notifiers
            .lock()
            .expect("notifier lock should not poison")
            .get(mailbox)
            .cloned()
    }

    pub(crate) fn prune_notifier(&self, mailbox: &str, notifier: &MailboxNotifier) {
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

    pub(crate) fn store(&self, recipient_device_id: String, envelope: Value) -> Result<(), String> {
        self.store_from("", recipient_device_id, envelope)
    }

    /// Stores [envelope], counting it to [source] (an address key; empty
    /// for none).
    pub(crate) fn store_from(
        &self,
        source: &str,
        recipient_device_id: String,
        envelope: Value,
    ) -> Result<(), String> {
        let source = if source.is_empty() {
            None
        } else {
            Some(peer_group(source))
        };
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

        // What this address holds already: a bounded share.
        if let Some(source) = &source {
            let held: u64 = transaction
                .query_row(
                    "SELECT COALESCE(SUM(envelope_bytes), 0) FROM queue_entries
                      WHERE source = ?1",
                    params![source],
                    |row| row.get(0),
                )
                .map_err(|error| format!("measuring an address's share: {error}"))?;
            if held.saturating_add(encoded_len) > self.config.max_stored_bytes_per_peer {
                return Err("this address holds too much on the relay".to_owned());
            }
        }
        // Everything stored: when full, the largest holder's oldest entries
        // make room (refusing everyone would let one holder stop the relay).
        let total = |transaction: &rusqlite::Transaction| -> Result<u64, String> {
            transaction
                .query_row("SELECT bytes FROM stored_total WHERE id = 1", [], |row| {
                    row.get::<_, i64>(0)
                })
                .map(|bytes| bytes.max(0) as u64)
                .map_err(|error| format!("reading relay storage: {error}"))
        };
        let mut largest: Option<Option<String>> = None;
        while total(&transaction)?.saturating_add(encoded_len) > self.config.max_total_bytes {
            if largest.is_none() {
                largest = Some(
                    transaction
                        .query_row(
                            "SELECT source FROM queue_entries WHERE lease_id IS NULL
                              GROUP BY source ORDER BY SUM(envelope_bytes) DESC LIMIT 1",
                            [],
                            |row| row.get::<_, Option<String>>(0),
                        )
                        .map_err(|_| "relay storage is full".to_owned())?,
                );
            }
            let holder = largest.clone().flatten();
            let removed = transaction
                .execute(
                    "DELETE FROM queue_entries WHERE id = (
                       SELECT id FROM queue_entries
                        WHERE source IS ?1 AND lease_id IS NULL
                        ORDER BY id LIMIT 1
                     )",
                    params![holder],
                )
                .map_err(|error| format!("making room on the relay: {error}"))?;
            if removed == 0 {
                // That holder has nothing left to give: look again (once).
                if largest.take().is_none() {
                    return Err("relay storage is full".to_owned());
                }
                largest = None;
                let again: Option<String> = transaction
                    .query_row(
                        "SELECT source FROM queue_entries WHERE lease_id IS NULL
                          GROUP BY source ORDER BY SUM(envelope_bytes) DESC LIMIT 1",
                        [],
                        |row| row.get(0),
                    )
                    .map_err(|_| "relay storage is full".to_owned())?;
                let removed = transaction
                    .execute(
                        "DELETE FROM queue_entries WHERE id = (
                           SELECT id FROM queue_entries
                            WHERE source IS ?1 AND lease_id IS NULL
                            ORDER BY id LIMIT 1
                         )",
                        params![again],
                    )
                    .map_err(|error| format!("making room on the relay: {error}"))?;
                if removed == 0 {
                    return Err("relay storage is full".to_owned());
                }
            }
        }
        transaction
            .execute(
                "INSERT INTO queue_entries
                   (mailbox, queued_at_millis, envelope_json, envelope_bytes,
                    kind, sender_device_id, dedup_key, source)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
                params![
                    &recipient_device_id,
                    now,
                    encoded,
                    encoded_len,
                    kind,
                    sender,
                    dedup_key,
                    source
                ],
            )
            .map_err(|error| format!("persisting relay envelope: {error}"))?;
        transaction
            .commit()
            .map_err(|error| format!("committing relay envelope: {error}"))?;
        if let Some(notifier) = self.existing_notifier(&recipient_device_id) {
            let mut signal = notifier.0.lock().expect("notifier mutex should not poison");
            signal.generation = signal.generation.wrapping_add(1);
            signal.notify.notify_waiters();
            notifier.1.notify_all();
        }
        Ok(())
    }

    pub(crate) fn fetch(
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
    pub(crate) fn drain_queue(&self, recipient_device_id: &str, limit: usize) -> Vec<Value> {
        self.drain_queue_result(recipient_device_id, limit)
            .unwrap_or_default()
    }

    pub(crate) fn drain_queue_result(
        &self,
        recipient_device_id: &str,
        limit: usize,
    ) -> Result<Vec<Value>, String> {
        self.take_queue(recipient_device_id, limit, None)
            .map(|(messages, _)| messages)
    }

    pub(crate) fn fetch_leased(
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

    pub(crate) fn take_queue(
        &self,
        recipient_device_id: &str,
        limit: usize,
        lease_ms: Option<u64>,
    ) -> Result<(Vec<Value>, Option<String>), String> {
        self.queue_reads
            .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
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
                      ORDER BY (kind IS 'pairing_announcement'), id LIMIT ?2",
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

    pub(crate) fn acknowledge_lease(
        &self,
        recipient_device_id: &str,
        lease_id: &str,
    ) -> Result<(), String> {
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

    pub(crate) fn stats(&self) -> RelayStats {
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
            v2: self.v2_info(),
        }
    }

    /// What health tells clients about v2: the session protocol and its
    /// key, which the identity signs.
    pub(crate) fn v2_info(&self) -> Option<Value> {
        if !self.config.ext.sessions_enabled() {
            return None;
        }
        Some(serde_json::json!({
            "sessions": 1,
            "noise": crate::session::NOISE_PARAMS,
            "noise_key": BASE64_STANDARD.encode(self.identity.noise_public),
            "noise_key_sig": BASE64_STANDARD.encode(self.identity.noise_key_signature),
            "mailbox_auth": 1,
            // UDP datagrams may be sealed under the session key (M38-C).
            "udp_sealed": 1,
            "policy": self.policy_info(),
        }))
    }

    /// Runs [work] on a blocking thread (the database is synchronous).
    pub(crate) async fn blocking<T, F>(&self, work: F) -> Result<T, String>
    where
        T: Send + 'static,
        F: FnOnce(&RelayState) -> T + Send + 'static,
    {
        let state = self.clone();
        tokio::task::spawn_blocking(move || work(&state))
            .await
            .map_err(|_| "relay worker failed".to_owned())
    }

    /// Waits, without holding a thread, until [mailbox] may have something
    /// new (a store since [observed]) or [wait] passes. The caller drains
    /// before and after, and keeps its [Observed] until then.
    pub(crate) async fn wait_for_store(&self, mailbox: &str, observed: u64, wait: Duration) {
        let mut guard = WaitGuard {
            state: self.clone(),
            mailbox: mailbox.to_owned(),
            notifier: self.notifier_for(mailbox),
            counted: false,
        };
        let notify = guard
            .notifier
            .0
            .lock()
            .expect("notifier mutex should not poison")
            .notify
            .clone();
        let notified = notify.notified();
        tokio::pin!(notified);
        notified.as_mut().enable();
        {
            let mut signal = guard
                .notifier
                .0
                .lock()
                .expect("notifier mutex should not poison");
            if signal.generation != observed {
                return;
            }
            signal.waiters += 1;
        }
        // Counted out again however the wait ends (a dropped connection
        // cancels it).
        guard.counted = true;
        let _ = tokio::time::timeout(wait, notified).await;
    }

    /// The generation [mailbox]'s signal is at; the signal is kept while
    /// the returned value lives (so a store in between is not missed) and
    /// pruned when the last holder lets go.
    pub(crate) fn observe(&self, mailbox: &str) -> Observed {
        let notifier = self.notifier_for(mailbox);
        let generation = notifier
            .0
            .lock()
            .expect("notifier mutex should not poison")
            .generation;
        Observed {
            state: self.clone(),
            mailbox: mailbox.to_owned(),
            notifier,
            generation,
        }
    }

    /// [fetch] for the tokio server: a waiting fetch holds no thread.
    pub(crate) async fn fetch_async(
        &self,
        recipient_device_id: String,
        limit: Option<usize>,
        wait_ms: Option<u64>,
    ) -> Result<Vec<Value>, String> {
        validate_mailbox_id(&recipient_device_id)?;
        let limit = limit
            .unwrap_or(self.config.max_fetch_limit)
            .clamp(1, self.config.max_fetch_limit);
        let wait_ms = match wait_ms {
            Some(value) if value > 0 => value.min(LONG_POLL_MAX_WAIT_MS),
            _ => 0,
        };
        if wait_ms == 0 {
            let mailbox = recipient_device_id;
            return self
                .blocking(move |state| state.drain_queue_result(&mailbox, limit))
                .await?;
        }
        let observed = self.observe(&recipient_device_id);
        let mailbox = recipient_device_id.clone();
        let first = self
            .blocking(move |state| state.drain_queue_result(&mailbox, limit))
            .await??;
        if !first.is_empty() {
            return Ok(first);
        }
        self.wait_for_store(
            &recipient_device_id,
            observed.generation,
            Duration::from_millis(wait_ms),
        )
        .await;
        let mailbox = recipient_device_id;
        let result = self
            .blocking(move |state| state.drain_queue_result(&mailbox, limit))
            .await?;
        drop(observed);
        result
    }

    /// [fetch_leased] for the tokio server.
    pub(crate) async fn fetch_leased_async(
        &self,
        recipient_device_id: String,
        limit: Option<usize>,
        wait_ms: Option<u64>,
        lease_ms: Option<u64>,
    ) -> Result<(Vec<Value>, Option<String>), String> {
        validate_mailbox_id(&recipient_device_id)?;
        let limit = limit
            .unwrap_or(self.config.max_fetch_limit)
            .clamp(1, self.config.max_fetch_limit);
        let lease_ms = lease_ms
            .unwrap_or(DEFAULT_LEASE_MILLIS)
            .clamp(5_000, 300_000);
        let wait_ms = match wait_ms {
            Some(value) if value > 0 => value.min(LONG_POLL_MAX_WAIT_MS),
            _ => 0,
        };
        if wait_ms == 0 {
            let mailbox = recipient_device_id;
            return self
                .blocking(move |state| state.take_queue(&mailbox, limit, Some(lease_ms)))
                .await?;
        }
        let observed = self.observe(&recipient_device_id);
        let mailbox = recipient_device_id.clone();
        let first = self
            .blocking(move |state| state.take_queue(&mailbox, limit, Some(lease_ms)))
            .await??;
        if !first.0.is_empty() {
            return Ok(first);
        }
        self.wait_for_store(
            &recipient_device_id,
            observed.generation,
            Duration::from_millis(wait_ms),
        )
        .await;
        let mailbox = recipient_device_id;
        let result = self
            .blocking(move |state| state.take_queue(&mailbox, limit, Some(lease_ms)))
            .await?;
        drop(observed);
        result
    }
}

/// A mailbox signal held while its holder drains and waits; pruned (when
/// nothing else holds or waits on it) as it goes.
pub(crate) struct Observed {
    state: RelayState,
    mailbox: String,
    notifier: MailboxNotifier,
    pub(crate) generation: u64,
}

impl Drop for Observed {
    fn drop(&mut self) {
        self.state.prune_notifier(&self.mailbox, &self.notifier);
    }
}

/// One wait on a mailbox signal: counted out, and the signal pruned, when
/// it ends (however it ends).
struct WaitGuard {
    state: RelayState,
    mailbox: String,
    notifier: MailboxNotifier,
    counted: bool,
}

impl Drop for WaitGuard {
    fn drop(&mut self) {
        if self.counted {
            let mut signal = self
                .notifier
                .0
                .lock()
                .expect("notifier mutex should not poison");
            signal.waiters = signal.waiters.saturating_sub(1);
        }
        self.state.prune_notifier(&self.mailbox, &self.notifier);
    }
}
