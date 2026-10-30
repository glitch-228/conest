//! Relay blobs (M27 tier 2): encrypted file blocks a sender leaves for a
//! receiver that is offline or slow. The relay sees only ciphertext.
//!
//! - `blob_put` (registered account, extended scope): uploads one blob in
//!   parts that fit a session frame (`offset`, `total`), checked against
//!   its SHA-256 (`hash`, lowercase hex) when the last part lands. At most
//!   `blob_max_bytes` a blob, a time to live up to `blob_max_ttl`, and a
//!   per-account and a total byte budget.
//! - `blob_get`: the hash is the read capability (nobody can ask for what
//!   they cannot name). Rate-limited per address by bytes a minute.
//! - `blob_has`: which of up to 64 hashes are held.
//!
//! Blobs are files in `blob_dir` (default: `blobs/` beside the database)
//! with an index in SQLite; a sweeper (run when a blob request comes and
//! the last sweep is a minute old) removes what expired, and uploads that
//! stopped. Nothing here touches v1.

use std::fs;
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::PathBuf;
use std::sync::atomic::Ordering;

use base64::Engine;
use base64::engine::general_purpose::STANDARD as BASE64_STANDARD;
use rusqlite::{Connection, OptionalExtension, params};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use crate::config::now_millis;
use crate::limits::peer_group;
#[cfg(test)]
use crate::registration::SCOPE_EXTENDED;
use crate::registration::SCOPE_BLOBS;
use crate::storage::RelayState;

/// The most one request carries (fits a session frame after base64).
pub(crate) const BLOB_PART_MAX: usize = 192 * 1024;
const MAX_HAS_HASHES: usize = 64;
/// Uploads one account may have under way at once.
const MAX_PARTIALS_PER_ACCOUNT: i64 = 4;
/// An upload that stops for this long is dropped.
const PARTIAL_IDLE_MILLIS: u64 = 10 * 60 * 1000;
const SWEEP_EVERY_MILLIS: u64 = 60 * 1000;
const MINUTE_MILLIS: u64 = 60 * 1000;
const MIN_TTL_SECS: u64 = 60;

pub(crate) fn init_tables(database: &Connection) -> Result<(), String> {
    database
        .execute_batch(
            "CREATE TABLE IF NOT EXISTS blobs (
               hash TEXT PRIMARY KEY,
               size INTEGER NOT NULL,
               account BLOB NOT NULL,
               created_millis INTEGER NOT NULL,
               expires_millis INTEGER NOT NULL
             );
             CREATE INDEX IF NOT EXISTS blobs_expiry ON blobs (expires_millis);
             CREATE TABLE IF NOT EXISTS blob_parts (
               hash TEXT NOT NULL,
               account BLOB NOT NULL,
               received INTEGER NOT NULL,
               total INTEGER NOT NULL,
               ttl_millis INTEGER NOT NULL,
               touched_millis INTEGER NOT NULL,
               PRIMARY KEY (hash, account)
             );",
        )
        .map_err(|error| format!("initializing blob storage: {error}"))
}

fn valid_hash(hash: &str) -> bool {
    hash.len() == 64
        && hash
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

fn ok(extra: Value) -> Value {
    let mut answer = json!({
        "ok": true,
        "stored": false,
        "messages": [],
        "error": null,
        "stats": null,
    });
    if let (Some(target), Some(extra)) = (answer.as_object_mut(), extra.as_object()) {
        for (name, value) in extra {
            target.insert(name.clone(), value.clone());
        }
    }
    answer
}

impl RelayState {
    /// Where blobs live; none when the relay has no place for them.
    fn blob_dir(&self) -> Option<PathBuf> {
        if let Some(dir) = &self.config.ext.blob_dir {
            return Some(dir.clone());
        }
        let path = self.config.database_path.as_path();
        if path == std::path::Path::new(":memory:") {
            return None;
        }
        Some(path.parent()?.join("blobs"))
    }

    /// What health tells clients about blobs (none: not offered).
    pub(crate) fn blob_info(&self) -> Option<Value> {
        let ext = &self.config.ext;
        if ext.blob_max_bytes == 0 || self.blob_dir().is_none() {
            return None;
        }
        Some(json!({
            "max_bytes": ext.blob_max_bytes,
            "max_ttl_secs": ext.blob_max_ttl.as_secs(),
            "part_bytes": BLOB_PART_MAX,
        }))
    }

    fn blob_ready(&self) -> Result<PathBuf, String> {
        if self.config.ext.blob_max_bytes == 0 {
            return Err("this relay keeps no blobs".to_owned());
        }
        let dir = self
            .blob_dir()
            .ok_or_else(|| "this relay keeps no blobs".to_owned())?;
        fs::create_dir_all(&dir).map_err(|error| format!("blob storage: {error}"))?;
        Ok(dir)
    }

    fn sweep_blobs_if_due(&self, dir: &std::path::Path) {
        let now = now_millis();
        let last = self.blob_sweep.load(Ordering::Relaxed);
        if now.saturating_sub(last) < SWEEP_EVERY_MILLIS
            || self
                .blob_sweep
                .compare_exchange(last, now, Ordering::AcqRel, Ordering::Relaxed)
                .is_err()
        {
            return;
        }
        self.sweep_blobs(dir, now);
    }

    /// Removes expired blobs and stalled uploads (files and index rows).
    pub(crate) fn sweep_blobs(&self, dir: &std::path::Path, now: u64) {
        let database = self
            .database
            .lock()
            .expect("relay database lock should not poison");
        let expired: Vec<String> = database
            .prepare("SELECT hash FROM blobs WHERE expires_millis <= ?1")
            .and_then(|mut statement| {
                statement
                    .query_map(params![now], |row| row.get(0))?
                    .collect()
            })
            .unwrap_or_default();
        for hash in &expired {
            let _ = fs::remove_file(dir.join(format!("{hash}.blob")));
        }
        let _ = database.execute("DELETE FROM blobs WHERE expires_millis <= ?1", params![now]);
        let stalled: Vec<(String, Vec<u8>)> = database
            .prepare("SELECT hash, account FROM blob_parts WHERE touched_millis <= ?1")
            .and_then(|mut statement| {
                statement
                    .query_map(params![now.saturating_sub(PARTIAL_IDLE_MILLIS)], |row| {
                        Ok((row.get(0)?, row.get(1)?))
                    })?
                    .collect()
            })
            .unwrap_or_default();
        for (hash, account) in &stalled {
            let _ = fs::remove_file(part_path(dir, hash, account));
            let _ = database.execute(
                "DELETE FROM blob_parts WHERE hash = ?1 AND account = ?2",
                params![hash, account],
            );
        }
    }

    /// `blob_put`: one part of a blob.
    pub(crate) fn blob_put(&self, request: &Value) -> Result<Value, String> {
        let dir = self.blob_ready()?;
        let token = request
            .get("token")
            .and_then(Value::as_str)
            .and_then(|text| self.valid_token(text))
            .ok_or("blobs need a registered account")?;
        if token.scope & SCOPE_BLOBS == 0 {
            return Err("this token does not cover blobs".to_owned());
        }
        let ext = &self.config.ext;
        let hash = request
            .get("hash")
            .and_then(Value::as_str)
            .filter(|hash| valid_hash(hash))
            .ok_or("the blob hash must be 64 lowercase hex digits")?
            .to_owned();
        let total = request.get("total").and_then(Value::as_u64).unwrap_or(0);
        if total == 0 || total > ext.blob_max_bytes {
            return Err("the blob is empty or larger than this relay keeps".to_owned());
        }
        let offset = request.get("offset").and_then(Value::as_u64).unwrap_or(0);
        let data = BASE64_STANDARD
            .decode(request.get("data").and_then(Value::as_str).unwrap_or(""))
            .map_err(|_| "the blob data is not base64".to_owned())?;
        if data.is_empty() || data.len() > BLOB_PART_MAX {
            return Err("a blob part is empty or too large".to_owned());
        }
        if offset
            .checked_add(data.len() as u64)
            .is_none_or(|end| end > total)
        {
            return Err("the part goes past the end of the blob".to_owned());
        }
        let ttl_millis = request
            .get("ttl_secs")
            .and_then(Value::as_u64)
            .unwrap_or(ext.blob_max_ttl.as_secs())
            .clamp(MIN_TTL_SECS, ext.blob_max_ttl.as_secs().max(MIN_TTL_SECS))
            * 1000;
        self.sweep_blobs_if_due(&dir);
        let now = now_millis();
        let account = token.account.to_vec();
        // Bytes budget per minute, as for messages. Before the database
        // lock is taken: accounts are locked first everywhere else.
        if offset == 0 {
            self.allow_account_bytes(&token, total)?;
        }
        {
            let database = self
                .database
                .lock()
                .expect("relay database lock should not poison");
            // Held already (by anyone): nothing to upload.
            let held: Option<u64> = database
                .query_row(
                    "SELECT expires_millis FROM blobs WHERE hash = ?1 AND expires_millis > ?2",
                    params![hash, now],
                    |row| row.get(0),
                )
                .optional()
                .map_err(|error| format!("reading blobs: {error}"))?;
            if let Some(expires) = held {
                return Ok(ok(
                    json!({"have": true, "complete": true, "expires": expires}),
                ));
            }
            let part = part_path(&dir, &hash, &account);
            if offset == 0 {
                // A new upload: the budgets.
                let (stored, totals): (u64, u64) = database
                    .query_row(
                        "SELECT COALESCE(SUM(size), 0), (SELECT COALESCE(SUM(total), 0)
                           FROM blob_parts WHERE account = ?1) FROM blobs WHERE account = ?1",
                        params![account],
                        |row| Ok((row.get(0)?, row.get(1)?)),
                    )
                    .map_err(|error| format!("reading blobs: {error}"))?;
                if stored.saturating_add(totals).saturating_add(total) > ext.blob_account_bytes {
                    return Err("account blob quota exceeded".to_owned());
                }
                let (all, all_parts): (u64, u64) = database
                    .query_row(
                        "SELECT (SELECT COALESCE(SUM(size), 0) FROM blobs),
                                (SELECT COALESCE(SUM(total), 0) FROM blob_parts)",
                        [],
                        |row| Ok((row.get(0)?, row.get(1)?)),
                    )
                    .map_err(|error| format!("reading blobs: {error}"))?;
                if all.saturating_add(all_parts).saturating_add(total) > ext.blob_total_bytes {
                    return Err("this relay's blob storage is full".to_owned());
                }
                let open: i64 = database
                    .query_row(
                        "SELECT COUNT(*) FROM blob_parts WHERE account = ?1 AND hash != ?2",
                        params![account, hash],
                        |row| row.get(0),
                    )
                    .map_err(|error| format!("reading blobs: {error}"))?;
                if open >= MAX_PARTIALS_PER_ACCOUNT {
                    return Err("too many uploads under way".to_owned());
                }
                fs::File::create(&part).map_err(|error| format!("blob storage: {error}"))?;
                database
                    .execute(
                        "INSERT OR REPLACE INTO blob_parts
                           (hash, account, received, total, ttl_millis, touched_millis)
                         VALUES (?1, ?2, 0, ?3, ?4, ?5)",
                        params![hash, account, total, ttl_millis, now],
                    )
                    .map_err(|error| format!("recording an upload: {error}"))?;
            }
            let (received, expected): (u64, u64) = database
                .query_row(
                    "SELECT received, total FROM blob_parts WHERE hash = ?1 AND account = ?2",
                    params![hash, account],
                    |row| Ok((row.get(0)?, row.get(1)?)),
                )
                .optional()
                .map_err(|error| format!("reading blobs: {error}"))?
                .ok_or("no upload under way for this blob")?;
            if expected != total || received != offset {
                return Err("the part is not the next one".to_owned());
            }
            let mut file = fs::OpenOptions::new()
                .write(true)
                .open(&part)
                .map_err(|error| format!("blob storage: {error}"))?;
            file.seek(SeekFrom::Start(offset))
                .and_then(|_| file.write_all(&data))
                .map_err(|error| format!("blob storage: {error}"))?;
            let received = offset + data.len() as u64;
            if received < total {
                database
                    .execute(
                        "UPDATE blob_parts SET received = ?3, touched_millis = ?4
                         WHERE hash = ?1 AND account = ?2",
                        params![hash, account, received, now],
                    )
                    .map_err(|error| format!("recording an upload: {error}"))?;
                return Ok(ok(json!({"complete": false, "received": received})));
            }
            // The last part: the whole must be what it says.
            let mut whole = Vec::with_capacity(total as usize);
            let verified = fs::File::open(&part)
                .and_then(|mut file| file.read_to_end(&mut whole))
                .is_ok()
                && whole.len() as u64 == total
                && hex(&Sha256::digest(&whole)) == hash;
            let _ = database.execute(
                "DELETE FROM blob_parts WHERE hash = ?1 AND account = ?2",
                params![hash, account],
            );
            if !verified {
                let _ = fs::remove_file(&part);
                return Err("the blob does not match its hash".to_owned());
            }
            fs::rename(&part, dir.join(format!("{hash}.blob")))
                .map_err(|error| format!("blob storage: {error}"))?;
            let expires = now + ttl_millis;
            database
                .execute(
                    "INSERT OR REPLACE INTO blobs
                       (hash, size, account, created_millis, expires_millis)
                     VALUES (?1, ?2, ?3, ?4, ?5)",
                    params![hash, total, account, now, expires],
                )
                .map_err(|error| format!("recording a blob: {error}"))?;
            Ok(ok(json!({"complete": true, "expires": expires})))
        }
    }

    /// `blob_get`: [len] bytes of the blob [hash] from [offset].
    pub(crate) fn blob_get(&self, request: &Value, peer: &str) -> Result<Value, String> {
        let dir = self.blob_ready()?;
        let hash = request
            .get("hash")
            .and_then(Value::as_str)
            .filter(|hash| valid_hash(hash))
            .ok_or("the blob hash must be 64 lowercase hex digits")?;
        let offset = request.get("offset").and_then(Value::as_u64).unwrap_or(0);
        let len = (request
            .get("len")
            .and_then(Value::as_u64)
            .unwrap_or(BLOB_PART_MAX as u64) as usize)
            .clamp(1, BLOB_PART_MAX);
        self.sweep_blobs_if_due(&dir);
        let now = now_millis();
        let size: u64 = {
            let database = self
                .database
                .lock()
                .expect("relay database lock should not poison");
            database
                .query_row(
                    "SELECT size FROM blobs WHERE hash = ?1 AND expires_millis > ?2",
                    params![hash, now],
                    |row| row.get(0),
                )
                .optional()
                .map_err(|error| format!("reading blobs: {error}"))?
                .ok_or("no such blob")?
        };
        if offset >= size {
            return Err("the offset is past the end of the blob".to_owned());
        }
        let len = len.min((size - offset) as usize);
        self.allow_blob_bytes(peer, len as u64)?;
        let mut data = vec![0_u8; len];
        let mut file = fs::File::open(dir.join(format!("{hash}.blob")))
            .map_err(|_| "no such blob".to_owned())?;
        file.seek(SeekFrom::Start(offset))
            .and_then(|_| file.read_exact(&mut data))
            .map_err(|_| "no such blob".to_owned())?;
        Ok(ok(json!({
            "size": size,
            "offset": offset,
            "data": BASE64_STANDARD.encode(&data),
        })))
    }

    /// `blob_has`: which of `hashes` are held (and not expired).
    pub(crate) fn blob_has(&self, request: &Value) -> Result<Value, String> {
        let dir = self.blob_ready()?;
        let hashes = request
            .get("hashes")
            .and_then(Value::as_array)
            .ok_or("blob_has needs hashes")?;
        if hashes.len() > MAX_HAS_HASHES {
            return Err("too many hashes".to_owned());
        }
        self.sweep_blobs_if_due(&dir);
        let now = now_millis();
        let database = self
            .database
            .lock()
            .expect("relay database lock should not poison");
        let mut have = Vec::new();
        for hash in hashes {
            let Some(hash) = hash.as_str().filter(|hash| valid_hash(hash)) else {
                return Err("the blob hash must be 64 lowercase hex digits".to_owned());
            };
            let held = database
                .query_row(
                    "SELECT 1 FROM blobs WHERE hash = ?1 AND expires_millis > ?2",
                    params![hash, now],
                    |_| Ok(()),
                )
                .optional()
                .map_err(|error| format!("reading blobs: {error}"))?
                .is_some();
            if held {
                have.push(hash.to_owned());
            }
        }
        Ok(ok(json!({"have": have})))
    }

    /// Bytes one address group may fetch a minute.
    fn allow_blob_bytes(&self, peer: &str, bytes: u64) -> Result<(), String> {
        let minute = now_millis() / MINUTE_MILLIS;
        let group = peer_group(peer);
        let mut served = self
            .blob_served
            .lock()
            .expect("blob lock should not poison");
        if served.len() >= self.config.max_rate_keys && !served.contains_key(&group) {
            served.retain(|_, (used, _)| *used == minute);
            if served.len() >= self.config.max_rate_keys {
                return Err("rate limit exceeded".to_owned());
            }
        }
        let used = served.entry(group).or_insert((minute, 0));
        if used.0 != minute {
            *used = (minute, 0);
        }
        if used.1.saturating_add(bytes) > self.config.ext.blob_get_bytes_per_minute {
            return Err("rate limit exceeded".to_owned());
        }
        used.1 += bytes;
        Ok(())
    }
}

fn part_path(dir: &std::path::Path, hash: &str, account: &[u8]) -> PathBuf {
    dir.join(format!(
        "{hash}.{}.part",
        hex(&account[..account.len().min(8)])
    ))
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::parity_tests::parity_config;
    use crate::registration::{SCOPE_MESSAGES, Token, encode_token};

    fn temp_dir(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "conest-blobs-{name}-{}-{}",
            std::process::id(),
            now_millis()
        ));
        let _ = fs::remove_dir_all(&dir);
        dir
    }

    fn state_with(
        name: &str,
        configure: impl FnOnce(&mut crate::config::RelayConfig),
    ) -> RelayState {
        let mut config = parity_config();
        config.ext.blob_dir = Some(temp_dir(name));
        configure(&mut config);
        RelayState::new(
            config,
            crate::identity::RelayIdentity::from_seed_bytes([7_u8; 32]),
        )
    }

    /// A token for a new account (registered in the state's account list).
    fn token_for(state: &RelayState, seed: u8, scope: u8) -> String {
        let account = [seed; 32];
        state
            .database
            .lock()
            .unwrap()
            .execute(
                "INSERT OR REPLACE INTO accounts (account_key, created_millis, quota_bytes)
                 VALUES (?1, ?2, ?3)",
                params![account.to_vec(), now_millis(), 1_i64 << 30],
            )
            .unwrap();
        state.load_accounts().unwrap();
        encode_token(
            &state.token_secret,
            &Token {
                account,
                scope,
                quota: 1 << 30,
                expiry_millis: now_millis() + 3_600_000,
            },
        )
    }

    fn sha(data: &[u8]) -> String {
        hex(&Sha256::digest(data))
    }

    fn put(
        state: &RelayState,
        token: &str,
        hash: &str,
        data: &[u8],
        total: u64,
        offset: u64,
    ) -> Result<Value, String> {
        state.blob_put(&json!({
            "action": "blob_put",
            "token": token,
            "hash": hash,
            "total": total,
            "offset": offset,
            "data": BASE64_STANDARD.encode(data),
        }))
    }

    fn get(state: &RelayState, hash: &str, offset: u64, len: u64) -> Result<Value, String> {
        state.blob_get(
            &json!({"action": "blob_get", "hash": hash, "offset": offset, "len": len}),
            "198.51.100.7",
        )
    }

    fn blob(len: usize, seed: u8) -> Vec<u8> {
        (0..len)
            .map(|i| (i as u8).wrapping_mul(31).wrapping_add(seed))
            .collect()
    }

    fn upload(state: &RelayState, token: &str, data: &[u8]) -> Result<String, String> {
        let hash = sha(data);
        let mut offset = 0;
        while offset < data.len() {
            let end = (offset + BLOB_PART_MAX).min(data.len());
            put(
                state,
                token,
                &hash,
                &data[offset..end],
                data.len() as u64,
                offset as u64,
            )?;
            offset = end;
        }
        Ok(hash)
    }

    #[test]
    fn a_blob_goes_up_in_parts_and_comes_back_by_its_hash() {
        let state = state_with("roundtrip", |_| {});
        let token = token_for(&state, 1, SCOPE_MESSAGES | SCOPE_EXTENDED);
        let data = blob(BLOB_PART_MAX * 2 + 123, 5);
        let hash = upload(&state, &token, &data).expect("upload");
        let has = state
            .blob_has(&json!({"hashes": [hash, sha(b"other")]}))
            .expect("has");
        assert_eq!(has["have"], json!([hash]));
        let mut got = Vec::new();
        while got.len() < data.len() {
            let part = get(&state, &hash, got.len() as u64, BLOB_PART_MAX as u64).expect("get");
            assert_eq!(part["size"], data.len());
            got.extend(
                BASE64_STANDARD
                    .decode(part["data"].as_str().unwrap())
                    .unwrap(),
            );
        }
        assert_eq!(got, data);
        assert!(get(&state, &hash, data.len() as u64, 10).is_err());
        assert!(get(&state, &sha(b"nothing"), 0, 10).is_err());
    }

    #[test]
    fn the_hash_is_checked_when_the_last_part_lands() {
        let state = state_with("hash", |_| {});
        let token = token_for(&state, 1, SCOPE_MESSAGES | SCOPE_EXTENDED);
        let data = blob(1000, 1);
        let wrong = sha(b"something else");
        let error = put(&state, &token, &wrong, &data, 1000, 0).unwrap_err();
        assert!(error.contains("hash"), "{error}");
        assert_eq!(
            state.blob_has(&json!({"hashes": [wrong]})).unwrap()["have"],
            json!([])
        );
        // Nothing is left of the upload: it cannot be continued.
        assert!(put(&state, &token, &wrong, &data, 1000, 500).is_err());
    }

    #[test]
    fn only_a_registered_account_with_the_extended_scope_may_put() {
        let state = state_with("scope", |_| {});
        let data = blob(100, 2);
        let hash = sha(&data);
        assert!(put(&state, "", &hash, &data, 100, 0).is_err());
        assert!(put(&state, "v1.bogus", &hash, &data, 100, 0).is_err());
        let narrow = token_for(&state, 2, SCOPE_MESSAGES);
        assert!(put(&state, &narrow, &hash, &data, 100, 0).is_err());
        let wide = token_for(&state, 3, SCOPE_MESSAGES | SCOPE_EXTENDED);
        assert!(put(&state, &wide, &hash, &data, 100, 0).is_ok());
    }

    #[test]
    fn size_and_quota_limits_hold() {
        let state = state_with("limits", |config| {
            config.ext.blob_max_bytes = 4096;
            config.ext.blob_account_bytes = 6000;
            config.ext.blob_total_bytes = 9000;
        });
        let a = token_for(&state, 1, SCOPE_MESSAGES | SCOPE_EXTENDED);
        let b = token_for(&state, 2, SCOPE_MESSAGES | SCOPE_EXTENDED);
        let big = blob(4097, 1);
        assert!(
            put(&state, &a, &sha(&big), &big[..100], 4097, 0).is_err(),
            "over the largest blob"
        );
        let first = blob(4000, 2);
        upload(&state, &a, &first).expect("first fits");
        let second = blob(3000, 3);
        let error = upload(&state, &a, &second).unwrap_err();
        assert!(error.contains("quota"), "{error}");
        // Another account still has room, until the relay's total is used.
        let third = blob(4000, 4);
        upload(&state, &b, &third).expect("another account");
        let fourth = blob(2000, 5);
        let error = upload(&state, &b, &fourth).unwrap_err();
        assert!(error.contains("quota") || error.contains("full"), "{error}");
        let c = token_for(&state, 3, SCOPE_MESSAGES | SCOPE_EXTENDED);
        let error = upload(&state, &c, &blob(2000, 6)).unwrap_err();
        assert!(error.contains("full"), "{error}");
    }

    #[test]
    fn parts_must_come_in_order_and_inside_the_blob() {
        let state = state_with("order", |_| {});
        let token = token_for(&state, 1, SCOPE_MESSAGES | SCOPE_EXTENDED);
        let data = blob(1000, 7);
        let hash = sha(&data);
        assert!(
            put(&state, &token, &hash, &data[500..], 1000, 500).is_err(),
            "no upload yet"
        );
        put(&state, &token, &hash, &data[..400], 1000, 0).unwrap();
        assert!(
            put(&state, &token, &hash, &data[500..], 1000, 500).is_err(),
            "a gap"
        );
        assert!(
            put(&state, &token, &hash, &data[400..], 999, 400).is_err(),
            "another total"
        );
        assert!(
            put(&state, &token, &hash, &blob(700, 1), 1000, 400).is_err(),
            "past the end"
        );
        let done = put(&state, &token, &hash, &data[400..], 1000, 400).unwrap();
        assert_eq!(done["complete"], true);
    }

    #[test]
    fn hashes_are_hex_only_so_no_path_can_be_named() {
        let state = state_with("names", |_| {});
        let token = token_for(&state, 1, SCOPE_MESSAGES | SCOPE_EXTENDED);
        for bad in [
            "../../etc/passwd",
            &"A".repeat(64),
            &"g".repeat(64),
            "abc",
            "",
        ] {
            assert!(put(&state, &token, bad, b"x", 1, 0).is_err(), "{bad}");
            assert!(get(&state, bad, 0, 1).is_err(), "{bad}");
            assert!(state.blob_has(&json!({"hashes": [bad]})).is_err(), "{bad}");
        }
        let many: Vec<String> = (0..65).map(|i| sha(&[i])).collect();
        assert!(state.blob_has(&json!({"hashes": many})).is_err());
    }

    #[test]
    fn a_blob_expires_and_the_sweeper_removes_it_and_stalled_uploads() {
        let state = state_with("expiry", |_| {});
        let token = token_for(&state, 1, SCOPE_MESSAGES | SCOPE_EXTENDED);
        let data = blob(500, 9);
        let hash = upload(&state, &token, &data).unwrap();
        let dir = state.blob_dir().unwrap();
        assert!(dir.join(format!("{hash}.blob")).exists());
        // The time to live never goes past the relay's.
        let expires: u64 = state
            .database
            .lock()
            .unwrap()
            .query_row(
                "SELECT expires_millis FROM blobs WHERE hash = ?1",
                params![hash],
                |r| r.get(0),
            )
            .unwrap();
        assert!(expires <= now_millis() + state.config.ext.blob_max_ttl.as_millis() as u64);
        // A stalled upload.
        let other = blob(900, 3);
        let other_hash = sha(&other);
        put(&state, &token, &other_hash, &other[..300], 900, 0).unwrap();
        // Time passes (the index is moved back; a minute-old sweep is due).
        state
            .database
            .lock()
            .unwrap()
            .execute("UPDATE blobs SET expires_millis = 1", [])
            .unwrap();
        state
            .database
            .lock()
            .unwrap()
            .execute("UPDATE blob_parts SET touched_millis = 1", [])
            .unwrap();
        state.sweep_blobs(&dir, now_millis());
        assert!(get(&state, &hash, 0, 10).is_err());
        assert!(!dir.join(format!("{hash}.blob")).exists());
        assert!(put(&state, &token, &other_hash, &other[300..], 900, 300).is_err());
        let leftovers: Vec<_> = fs::read_dir(&dir).unwrap().collect();
        assert!(leftovers.is_empty(), "{leftovers:?}");
    }

    #[test]
    fn a_ttl_is_clamped_to_the_relays_and_a_minute() {
        let state = state_with("ttl", |config| {
            config.ext.blob_max_ttl = std::time::Duration::from_secs(3600);
        });
        let token = token_for(&state, 1, SCOPE_MESSAGES | SCOPE_EXTENDED);
        let data = blob(50, 1);
        let answer = state
            .blob_put(&json!({
                "token": token, "hash": sha(&data), "total": 50, "offset": 0,
                "data": BASE64_STANDARD.encode(&data), "ttl_secs": 10_000_000,
            }))
            .unwrap();
        let expires = answer["expires"].as_u64().unwrap();
        assert!(expires <= now_millis() + 3_600_000);
        assert!(expires >= now_millis() + 3_500_000);
    }

    #[test]
    fn fetching_is_rate_limited_per_address() {
        let state = state_with("rate", |config| {
            config.ext.blob_get_bytes_per_minute = 1000;
        });
        let token = token_for(&state, 1, SCOPE_MESSAGES | SCOPE_EXTENDED);
        let data = blob(800, 4);
        let hash = upload(&state, &token, &data).unwrap();
        assert!(get(&state, &hash, 0, 800).is_ok());
        let error = get(&state, &hash, 0, 800).unwrap_err();
        assert!(error.contains("rate limit"), "{error}");
        // Another address has its own allowance.
        assert!(
            state
                .blob_get(
                    &json!({"hash": hash, "offset": 0, "len": 800}),
                    "203.0.113.9"
                )
                .is_ok()
        );
    }

    #[test]
    fn a_blob_already_held_is_not_uploaded_again() {
        let state = state_with("dedupe", |_| {});
        let a = token_for(&state, 1, SCOPE_MESSAGES | SCOPE_EXTENDED);
        let b = token_for(&state, 2, SCOPE_MESSAGES | SCOPE_EXTENDED);
        let data = blob(300, 8);
        let hash = upload(&state, &a, &data).unwrap();
        let answer = put(&state, &b, &hash, &data, 300, 0).unwrap();
        assert_eq!(answer["have"], true);
        assert_eq!(answer["complete"], true);
    }

    #[test]
    fn no_blobs_when_the_relay_keeps_none() {
        let state = state_with("off", |config| config.ext.blob_max_bytes = 0);
        let token = token_for(&state, 1, SCOPE_MESSAGES | SCOPE_EXTENDED);
        assert!(put(&state, &token, &sha(b"x"), b"x", 1, 0).is_err());
        assert!(get(&state, &sha(b"x"), 0, 1).is_err());
        assert!(state.blob_info().is_none());
        assert!(state.policy_info()["blobs"].is_null());
    }

    #[test]
    fn health_tells_clients_what_blobs_are_offered() {
        let state = state_with("info", |_| {});
        let info = state.policy_info();
        assert_eq!(info["blobs"]["max_bytes"], 4 * 1024 * 1024);
        assert_eq!(info["blobs"]["max_ttl_secs"], 24 * 3600);
    }
}
