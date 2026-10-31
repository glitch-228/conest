//! Relay blobs (M27 tier 2): encrypted file blocks a sender leaves for a
//! receiver that is offline or slow. The relay sees only ciphertext.
//!
//! - `blob_put` (registered account, extended scope): uploads one blob in
//!   parts that fit a session frame (`offset`, `total`), checked against
//!   its SHA-256 (`hash`, lowercase hex) when the last part lands. At most
//!   `blob_max_bytes` a blob, a time to live up to `blob_max_ttl`, and a
//!   per-account and a total byte budget.
//! - `blob_get`: needs the blob's read secret, which the sender chose at
//!   upload and sends to the receiver inside the end-to-end encrypted
//!   announcement. The relay keeps only the secret's SHA-256 and compares
//!   in constant time; a wrong or missing secret answers exactly like a
//!   blob that is not there. Rate-limited per address by bytes a minute.
//! - `blob_has`: which of up to 64 `{hash, secret}` pairs are held.
//! - `blob_delete`: the uploading account removes its blob.
//!
//! Blobs are off unless the operator sets `--blob-max-bytes`. Storage is
//! budgeted per account, per address (accounts created from one address
//! share a budget) and for the whole relay. File writes, reads and hashing
//! run outside the database lock, which only guards the index.
//!
//! Blobs are files in `blob_dir` (default: `blobs/` beside the database)
//! with an index in SQLite; a sweeper (run when a blob request comes and
//! the last sweep is a minute old) removes what expired, and uploads that
//! stopped. Nothing here touches v1.

use std::collections::HashSet;
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
use crate::registration::{SCOPE_BLOBS, same};
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
    // An older layout (before read secrets) cannot be kept: its blobs are
    // dropped (they are at most a day old anyway).
    let columns = |table: &str| -> Vec<String> {
        database
            .prepare(&format!("SELECT name FROM pragma_table_info('{table}')"))
            .and_then(|mut statement| {
                statement
                    .query_map([], |row| row.get::<_, String>(0))?
                    .collect()
            })
            .unwrap_or_default()
    };
    let have = columns("blobs");
    if !have.is_empty() && !have.iter().any(|name| name == "secret_hash") {
        database
            .execute_batch("DROP TABLE blobs; DROP TABLE IF EXISTS blob_parts;")
            .map_err(|error| format!("migrating blob storage: {error}"))?;
    } else if !have.is_empty() && !have.iter().any(|name| name == "served") {
        database
            .execute_batch("ALTER TABLE blobs ADD COLUMN served INTEGER NOT NULL DEFAULT 0;")
            .map_err(|error| format!("migrating blob storage: {error}"))?;
    }
    database
        .execute_batch(
            "CREATE TABLE IF NOT EXISTS blobs (
               hash TEXT NOT NULL,
               size INTEGER NOT NULL,
               account BLOB NOT NULL,
               created_millis INTEGER NOT NULL,
               expires_millis INTEGER NOT NULL,
               secret_hash BLOB NOT NULL,
               served INTEGER NOT NULL DEFAULT 0,
               PRIMARY KEY (hash, account)
             );
             CREATE INDEX IF NOT EXISTS blobs_expiry ON blobs (expires_millis);
             CREATE INDEX IF NOT EXISTS blobs_account ON blobs (account);
             CREATE TABLE IF NOT EXISTS blob_parts (
               hash TEXT NOT NULL,
               account BLOB NOT NULL,
               received INTEGER NOT NULL,
               total INTEGER NOT NULL,
               ttl_millis INTEGER NOT NULL,
               touched_millis INTEGER NOT NULL,
               secret_hash BLOB NOT NULL,
               PRIMARY KEY (hash, account)
             );
             CREATE INDEX IF NOT EXISTS blob_parts_account ON blob_parts (account);
             CREATE TABLE IF NOT EXISTS blob_account_groups (
               account BLOB PRIMARY KEY,
               grp TEXT NOT NULL
             );
             CREATE INDEX IF NOT EXISTS blob_account_groups_grp ON blob_account_groups (grp);",
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

    /// Removes expired blobs and stalled uploads (index rows under the lock,
    /// files after it). An upload being handled right now is left alone.
    pub(crate) fn sweep_blobs(&self, dir: &std::path::Path, now: u64) {
        let mut guards = Vec::new();
        let mut files = Vec::new();
        {
            let database = self
                .database
                .lock()
                .expect("relay database lock should not poison");
            let expired: Vec<(String, Vec<u8>)> = database
                .prepare("SELECT hash, account FROM blobs WHERE expires_millis <= ?1")
                .and_then(|mut statement| {
                    statement
                        .query_map(params![now], |row| Ok((row.get(0)?, row.get(1)?)))?
                        .collect()
                })
                .unwrap_or_default();
            for (hash, account) in expired {
                let Ok(guard) = BusyUpload::take(&self.blob_busy, busy_key(&hash, &account))
                else {
                    continue;
                };
                guards.push(guard);
                let _ = database.execute(
                    "DELETE FROM blobs WHERE hash = ?1 AND account = ?2 AND expires_millis <= ?3",
                    params![hash, account, now],
                );
                files.push(blob_path(dir, &hash, &account));
            }
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
            for (hash, account) in stalled {
                let Ok(guard) = BusyUpload::take(&self.blob_busy, busy_key(&hash, &account))
                else {
                    continue;
                };
                guards.push(guard);
                let _ = database.execute(
                    "DELETE FROM blob_parts WHERE hash = ?1 AND account = ?2",
                    params![hash, account],
                );
                files.push(part_path(dir, &hash, &account));
            }
        }
        for file in files {
            let _ = fs::remove_file(file);
        }
        drop(guards);
    }

    /// Once at start: removes blob files that belong to no index row (a
    /// crash between the rename and the index, or an older layout). Only
    /// files named like ours (`<64 hex>...blob` or `...part`) are touched.
    pub(crate) fn blob_startup_cleanup(&self) {
        let Some(dir) = self.blob_dir() else { return };
        let Ok(entries) = fs::read_dir(&dir) else {
            return;
        };
        let mut known = HashSet::new();
        {
            let database = self
                .database
                .lock()
                .expect("relay database lock should not poison");
            for (table, path) in [
                ("blobs", blob_path as fn(&std::path::Path, &str, &[u8]) -> PathBuf),
                ("blob_parts", part_path),
            ] {
                let rows: Vec<(String, Vec<u8>)> = database
                    .prepare(&format!("SELECT hash, account FROM {table}"))
                    .and_then(|mut statement| {
                        statement
                            .query_map([], |row| Ok((row.get(0)?, row.get(1)?)))?
                            .collect()
                    })
                    .unwrap_or_default();
                for (hash, account) in rows {
                    known.insert(path(&dir, &hash, &account));
                }
            }
        }
        for entry in entries.flatten() {
            let path = entry.path();
            let name = entry.file_name().to_string_lossy().into_owned();
            let ours = (name.ends_with(".blob") || name.ends_with(".part"))
                && valid_hash(name.get(..64).unwrap_or(""));
            if ours && !known.contains(&path) {
                let _ = fs::remove_file(path);
            }
        }
    }

    /// The registered account of a request's token, with the blob scope.
    fn blob_token(&self, request: &Value) -> Result<crate::registration::Token, String> {
        let token = request
            .get("token")
            .and_then(Value::as_str)
            .and_then(|text| self.valid_token(text))
            .ok_or("blobs need a registered account")?;
        if token.scope & SCOPE_BLOBS == 0 {
            return Err("this token does not cover blobs".to_owned());
        }
        Ok(token)
    }

    /// `blob_put`: one part of a blob. The first part (offset 0) carries the
    /// `secret` that later reads must show. File writes and hashing happen
    /// outside the database lock, which is only held for the index.
    pub(crate) fn blob_put(&self, request: &Value, peer: &str) -> Result<Value, String> {
        let dir = self.blob_ready()?;
        let token = self.blob_token(request)?;
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
        let secret = if offset == 0 {
            Some(secret_digest(request)?)
        } else {
            None
        };
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
        // One request at a time per upload (the file is written unlocked).
        let _busy = BusyUpload::take(&self.blob_busy, busy_key(&hash, &account))?;
        let part = part_path(&dir, &hash, &account);
        let secret_hash: Vec<u8>;
        {
            let database = self
                .database
                .lock()
                .expect("relay database lock should not poison");
            // Held already by this account: nothing to upload.
            let held: Option<u64> = database
                .query_row(
                    "SELECT expires_millis FROM blobs
                      WHERE hash = ?1 AND account = ?2 AND expires_millis > ?3",
                    params![hash, account, now],
                    |row| row.get(0),
                )
                .optional()
                .map_err(|error| format!("reading blobs: {error}"))?;
            if let Some(expires) = held {
                // The secret it was stored with stays: a repeated upload
                // (after a sender restart) must not lock the receiver out.
                return Ok(ok(
                    json!({"have": true, "complete": true, "expires": expires}),
                ));
            }
            if let Some(secret) = secret {
                // A new upload: the budgets.
                // This upload's own earlier attempt (same hash) is not counted
                // twice.
                let own: u64 = database
                    .query_row(
                        "SELECT (SELECT COALESCE(SUM(size), 0) FROM blobs
                                  WHERE account = ?1 AND hash != ?2)
                              + (SELECT COALESCE(SUM(total), 0) FROM blob_parts
                                  WHERE account = ?1 AND hash != ?2)",
                        params![account, hash],
                        |row| row.get(0),
                    )
                    .map_err(|error| format!("reading blobs: {error}"))?;
                if own.saturating_add(total) > ext.blob_account_bytes {
                    return Err("account blob quota exceeded".to_owned());
                }
                // The address the account registered from (an account that
                // registered before this existed is filed on its first
                // upload): every account made there counts toward one budget.
                note_account_group(&database, &account, &peer_group(peer));
                let group: Option<String> = database
                    .query_row(
                        "SELECT grp FROM blob_account_groups WHERE account = ?1",
                        params![account],
                        |row| row.get(0),
                    )
                    .optional()
                    .map_err(|error| format!("reading blobs: {error}"))?;
                if let Some(group) = group {
                    let used: u64 = database
                        .query_row(
                            "SELECT (SELECT COALESCE(SUM(size), 0) FROM blobs
                                      WHERE NOT (hash = ?2 AND account = ?3) AND account IN
                                       (SELECT account FROM blob_account_groups WHERE grp = ?1))
                                  + (SELECT COALESCE(SUM(total), 0) FROM blob_parts
                                      WHERE NOT (hash = ?2 AND account = ?3) AND account IN
                                       (SELECT account FROM blob_account_groups WHERE grp = ?1))",
                            params![group, hash, account],
                            |row| row.get(0),
                        )
                        .map_err(|error| format!("reading blobs: {error}"))?;
                    if used.saturating_add(total) > ext.blob_address_bytes {
                        return Err("address blob quota exceeded".to_owned());
                    }
                }
                let (all, all_parts): (u64, u64) = database
                    .query_row(
                        "SELECT (SELECT COALESCE(SUM(size), 0) FROM blobs
                                  WHERE NOT (hash = ?1 AND account = ?2)),
                                (SELECT COALESCE(SUM(total), 0) FROM blob_parts
                                  WHERE NOT (hash = ?1 AND account = ?2))",
                        params![hash, account],
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
                database
                    .execute(
                        "INSERT OR REPLACE INTO blob_parts
                           (hash, account, received, total, ttl_millis, touched_millis, secret_hash)
                         VALUES (?1, ?2, 0, ?3, ?4, ?5, ?6)",
                        params![hash, account, total, ttl_millis, now, secret],
                    )
                    .map_err(|error| format!("recording an upload: {error}"))?;
            }
            let (received, expected, stored_secret): (u64, u64, Vec<u8>) = database
                .query_row(
                    "SELECT received, total, secret_hash FROM blob_parts
                      WHERE hash = ?1 AND account = ?2",
                    params![hash, account],
                    |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
                )
                .optional()
                .map_err(|error| format!("reading blobs: {error}"))?
                .ok_or("no upload under way for this blob")?;
            if expected != total || received != offset {
                return Err("the part is not the next one".to_owned());
            }
            secret_hash = stored_secret;
        }
        // The data: unlocked.
        let wrote = (|| -> std::io::Result<()> {
            let mut file = if offset == 0 {
                fs::File::create(&part)?
            } else {
                fs::OpenOptions::new().write(true).open(&part)?
            };
            file.seek(SeekFrom::Start(offset))?;
            file.write_all(&data)
        })();
        if let Err(error) = wrote {
            if offset == 0 {
                self.drop_upload(&hash, &account, &part);
            }
            return Err(format!("blob storage: {error}"));
        }
        let received = offset + data.len() as u64;
        if received < total {
            let database = self
                .database
                .lock()
                .expect("relay database lock should not poison");
            database
                .execute(
                    "UPDATE blob_parts SET received = ?3, touched_millis = ?4
                     WHERE hash = ?1 AND account = ?2",
                    params![hash, account, received, now],
                )
                .map_err(|error| format!("recording an upload: {error}"))?;
            return Ok(ok(json!({"complete": false, "received": received})));
        }
        // The last part: the whole must be what it says (hashed unlocked).
        let verified = hash_file(&part).is_ok_and(|(sum, len)| len == total && sum == hash);
        if !verified {
            self.drop_upload(&hash, &account, &part);
            return Err("the blob does not match its hash".to_owned());
        }
        let blob = blob_path(&dir, &hash, &account);
        if let Err(error) = fs::rename(&part, &blob) {
            self.drop_upload(&hash, &account, &part);
            return Err(format!("blob storage: {error}"));
        }
        let expires = now + ttl_millis;
        let recorded = {
            let database = self
                .database
                .lock()
                .expect("relay database lock should not poison");
            let _ = database.execute(
                "DELETE FROM blob_parts WHERE hash = ?1 AND account = ?2",
                params![hash, account],
            );
            database.execute(
                "INSERT OR REPLACE INTO blobs
                   (hash, size, account, created_millis, expires_millis, secret_hash)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                params![hash, total, account, now, expires, secret_hash],
            )
        };
        if let Err(error) = recorded {
            let _ = fs::remove_file(&blob);
            return Err(format!("recording a blob: {error}"));
        }
        Ok(ok(json!({"complete": true, "expires": expires})))
    }

    /// Forgets an upload (index row and file).
    fn drop_upload(&self, hash: &str, account: &[u8], part: &std::path::Path) {
        let _ = fs::remove_file(part);
        let database = self
            .database
            .lock()
            .expect("relay database lock should not poison");
        let _ = database.execute(
            "DELETE FROM blob_parts WHERE hash = ?1 AND account = ?2",
            params![hash, account],
        );
    }

    /// `blob_delete`: the owner removes its blobs (`hash`, or up to 64
    /// `hashes`) and any upload of them.
    pub(crate) fn blob_delete(&self, request: &Value) -> Result<Value, String> {
        let dir = self.blob_ready()?;
        let token = self.blob_token(request)?;
        let mut hashes: Vec<String> = Vec::new();
        if let Some(hash) = request.get("hash").and_then(Value::as_str) {
            hashes.push(hash.to_owned());
        }
        if let Some(list) = request.get("hashes").and_then(Value::as_array) {
            for hash in list {
                hashes.push(hash.as_str().unwrap_or("").to_owned());
            }
        }
        if hashes.is_empty() || hashes.len() > MAX_HAS_HASHES {
            return Err("blob_delete needs 1 to 64 hashes".to_owned());
        }
        if hashes.iter().any(|hash| !valid_hash(hash)) {
            return Err("the blob hash must be 64 lowercase hex digits".to_owned());
        }
        let account = token.account.to_vec();
        let mut guards = Vec::new();
        let mut files = Vec::new();
        let mut removed = 0_usize;
        {
            let database = self
                .database
                .lock()
                .expect("relay database lock should not poison");
            for hash in &hashes {
                // An upload being handled right now finishes first.
                let guard = BusyUpload::take(&self.blob_busy, busy_key(hash, &account))?;
                guards.push(guard);
                removed += database
                    .execute(
                        "DELETE FROM blobs WHERE hash = ?1 AND account = ?2",
                        params![hash, account],
                    )
                    .map_err(|error| format!("deleting a blob: {error}"))?;
                let _ = database.execute(
                    "DELETE FROM blob_parts WHERE hash = ?1 AND account = ?2",
                    params![hash, account],
                );
                files.push(blob_path(&dir, hash, &account));
                files.push(part_path(&dir, hash, &account));
            }
        }
        for file in files {
            let _ = fs::remove_file(file);
        }
        drop(guards);
        Ok(ok(json!({"deleted": removed > 0, "count": removed})))
    }

    /// `blob_get`: [len] bytes of the blob [hash] from [offset], to whoever
    /// shows the blob's read secret. A wrong or missing secret looks exactly
    /// like a blob that is not there.
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
        let digest = secret_digest(request).unwrap_or_else(|_| vec![0_u8; 32]);
        let found = {
            let database = self
                .database
                .lock()
                .expect("relay database lock should not poison");
            find_readable(&database, hash, &digest, now, self.config.ext.blob_serve_factor)?
        };
        let Some((account, size)) = found else {
            return Err("no such blob".to_owned());
        };
        if offset >= size {
            return Err("the offset is past the end of the blob".to_owned());
        }
        let len = len.min((size - offset) as usize);
        self.allow_blob_bytes(peer, len as u64)?;
        // What has been served counts toward the blob's budget.
        {
            let database = self
                .database
                .lock()
                .expect("relay database lock should not poison");
            let _ = database.execute(
                "UPDATE blobs SET served = served + ?3 WHERE hash = ?1 AND account = ?2",
                params![hash, account, len as u64],
            );
        }
        // The read: unlocked.
        let mut data = vec![0_u8; len];
        let mut file = fs::File::open(blob_path(&dir, hash, &account))
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

    /// `blob_has`: which of `items` (`{hash, secret}`) are held (and not
    /// expired). Without the secret a blob is not reported.
    pub(crate) fn blob_has(&self, request: &Value) -> Result<Value, String> {
        let dir = self.blob_ready()?;
        let items = request
            .get("items")
            .and_then(Value::as_array)
            .ok_or("blob_has needs items")?;
        if items.len() > MAX_HAS_HASHES {
            return Err("too many hashes".to_owned());
        }
        self.sweep_blobs_if_due(&dir);
        let now = now_millis();
        let database = self
            .database
            .lock()
            .expect("relay database lock should not poison");
        let mut have = Vec::new();
        for item in items {
            let Some(hash) = item
                .get("hash")
                .and_then(Value::as_str)
                .filter(|hash| valid_hash(hash))
            else {
                return Err("the blob hash must be 64 lowercase hex digits".to_owned());
            };
            let digest = secret_digest(item).unwrap_or_else(|_| vec![0_u8; 32]);
            if find_readable(&database, hash, &digest, now, self.config.ext.blob_serve_factor)?.is_some() {
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

fn busy_key(hash: &str, account: &[u8]) -> String {
    format!("{hash}:{}", hex(account))
}

fn account_tag(account: &[u8]) -> String {
    hex(&account[..account.len().min(16)])
}

fn part_path(dir: &std::path::Path, hash: &str, account: &[u8]) -> PathBuf {
    dir.join(format!("{hash}.{}.part", account_tag(account)))
}

fn blob_path(dir: &std::path::Path, hash: &str, account: &[u8]) -> PathBuf {
    dir.join(format!("{hash}.{}.blob", account_tag(account)))
}

/// SHA-256 of a request's read secret (16 to 128 ASCII characters).
fn secret_digest(request: &Value) -> Result<Vec<u8>, String> {
    let secret = request
        .get("secret")
        .and_then(Value::as_str)
        .filter(|secret| (16..=128).contains(&secret.len()) && secret.is_ascii())
        .ok_or("a blob needs a read secret of 16 to 128 characters")?;
    Ok(Sha256::digest(secret.as_bytes()).to_vec())
}

/// The (account, size) of an unexpired blob [hash] whose stored secret
/// hash equals [digest] (compared in constant time, over every holder) and
/// that has not been served more than [factor] times its size (0: no
/// limit): a relay is no file host for the public.
fn find_readable(
    database: &Connection,
    hash: &str,
    digest: &[u8],
    now: u64,
    factor: u64,
) -> Result<Option<(Vec<u8>, u64)>, String> {
    let mut statement = database
        .prepare(
            "SELECT account, size, secret_hash, served FROM blobs
              WHERE hash = ?1 AND expires_millis > ?2",
        )
        .map_err(|error| format!("reading blobs: {error}"))?;
    let rows = statement
        .query_map(params![hash, now], |row| {
            Ok((
                row.get::<_, Vec<u8>>(0)?,
                row.get::<_, u64>(1)?,
                row.get::<_, Vec<u8>>(2)?,
                row.get::<_, u64>(3)?,
            ))
        })
        .map_err(|error| format!("reading blobs: {error}"))?;
    let mut found = None;
    let mut any = false;
    for row in rows {
        let (account, size, stored, served) =
            row.map_err(|error| format!("reading blobs: {error}"))?;
        any = true;
        let spent = factor > 0 && served >= size.saturating_mul(factor);
        if same(&stored, digest) && !spent && found.is_none() {
            found = Some((account, size));
        }
    }
    if !any {
        // Work as for a hit, so a missing blob is not quicker to refuse.
        let _ = same(&[0_u8; 32], digest);
    }
    Ok(found)
}

/// SHA-256 (lowercase hex) and length of a file, read in small pieces.
fn hash_file(path: &std::path::Path) -> std::io::Result<(String, u64)> {
    let mut file = fs::File::open(path)?;
    let mut hasher = Sha256::new();
    let mut buffer = vec![0_u8; 64 * 1024];
    let mut len = 0_u64;
    loop {
        let read = file.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
        len += read as u64;
    }
    Ok((hex(&hasher.finalize()), len))
}

/// Marks one upload as being handled; a second request for the same upload
/// meanwhile is refused.
struct BusyUpload<'a> {
    set: &'a std::sync::Mutex<HashSet<String>>,
    key: String,
}

impl<'a> BusyUpload<'a> {
    fn take(set: &'a std::sync::Mutex<HashSet<String>>, key: String) -> Result<Self, String> {
        if !set
            .lock()
            .expect("blob lock should not poison")
            .insert(key.clone())
        {
            return Err("this upload is busy".to_owned());
        }
        Ok(Self { set, key })
    }
}

impl Drop for BusyUpload<'_> {
    fn drop(&mut self) {
        if let Ok(mut set) = self.set.lock() {
            set.remove(&self.key);
        }
    }
}

/// Remembers the address an account was created from (registration), so
/// blob storage can be budgeted per address as well as per account.
pub(crate) fn note_account_group(database: &Connection, account: &[u8], group: &str) {
    let _ = database.execute(
        "INSERT OR IGNORE INTO blob_account_groups (account, grp) VALUES (?1, ?2)",
        params![account, group],
    );
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
        config.ext.blob_max_bytes = 4 * 1024 * 1024;
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

    const PEER: &str = "198.51.100.77";
    const SECRET: &str = "read-secret-0123456789abcdef";

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
            "secret": SECRET,
        }), PEER)
    }

    fn has(state: &RelayState, hash: &str, secret: &str) -> Vec<String> {
        let answer = state
            .blob_has(&json!({"items": [{"hash": hash, "secret": secret}]}))
            .expect("has");
        serde_json::from_value(answer["have"].clone()).unwrap()
    }

    fn get(state: &RelayState, hash: &str, offset: u64, len: u64) -> Result<Value, String> {
        state.blob_get(
            &json!({"action": "blob_get", "hash": hash, "offset": offset, "len": len, "secret": SECRET}),
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
        assert_eq!(has(&state, &hash, SECRET), vec![hash.clone()]);
        assert!(has(&state, &sha(b"other"), SECRET).is_empty());
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
        assert!(has(&state, &wrong, SECRET).is_empty());
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
            assert!(
                state
                    .blob_has(&json!({"items": [{"hash": bad, "secret": SECRET}]}))
                    .is_err(),
                "{bad}"
            );
        }
        let many: Vec<Value> = (0..65)
            .map(|i| json!({"hash": sha(&[i]), "secret": SECRET}))
            .collect();
        assert!(state.blob_has(&json!({"items": many})).is_err());
    }

    #[test]
    fn a_blob_expires_and_the_sweeper_removes_it_and_stalled_uploads() {
        let state = state_with("expiry", |_| {});
        let token = token_for(&state, 1, SCOPE_MESSAGES | SCOPE_EXTENDED);
        let data = blob(500, 9);
        let hash = upload(&state, &token, &data).unwrap();
        let dir = state.blob_dir().unwrap();
        assert!(blob_path(&dir, &hash, &[1_u8; 32]).exists());
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
        assert!(!blob_path(&dir, &hash, &[1_u8; 32]).exists());
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
                "secret": SECRET,
            }), PEER)
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
                    &json!({"hash": hash, "offset": 0, "len": 800, "secret": SECRET}),
                    "203.0.113.9"
                )
                .is_ok()
        );
    }

    #[test]
    fn a_blob_already_held_by_the_account_is_not_uploaded_again() {
        let state = state_with("dedupe", |_| {});
        let a = token_for(&state, 1, SCOPE_MESSAGES | SCOPE_EXTENDED);
        let b = token_for(&state, 2, SCOPE_MESSAGES | SCOPE_EXTENDED);
        let data = blob(300, 8);
        let hash = upload(&state, &a, &data).unwrap();
        // Uploading it again with another secret (a sender that lost its
        // state) changes nothing: the receiver's secret keeps working.
        let answer = state
            .blob_put(&json!({
                "token": a, "hash": hash, "total": 300, "offset": 0,
                "data": BASE64_STANDARD.encode(&data),
                "secret": "a-different-secret-0123456789",
            }), PEER)
            .unwrap();
        assert_eq!(answer["have"], true);
        assert_eq!(answer["complete"], true);
        assert_eq!(has(&state, &hash, SECRET), vec![hash.clone()]);
        assert!(has(&state, &hash, "a-different-secret-0123456789").is_empty());
        // Another account is not told the blob exists: it uploads its own,
        // with its own secret.
        let answer = put(&state, &b, &hash, &data, 300, 0).unwrap();
        assert_eq!(answer["complete"], true);
        assert!(answer["have"].is_null());
    }

    #[test]
    fn reading_needs_the_blobs_secret_and_a_wrong_one_looks_like_no_blob() {
        let state = state_with("secret", |_| {});
        let token = token_for(&state, 1, SCOPE_MESSAGES | SCOPE_EXTENDED);
        let data = blob(400, 3);
        let hash = upload(&state, &token, &data).unwrap();
        let ask = |secret: Option<&str>| {
            let mut request = json!({"hash": hash, "offset": 0, "len": 400});
            if let Some(secret) = secret {
                request["secret"] = json!(secret);
            }
            state.blob_get(&request, "198.51.100.7")
        };
        assert!(ask(Some(SECRET)).is_ok());
        let missing = state.blob_get(
            &json!({"hash": sha(b"not there"), "offset": 0, "secret": SECRET}),
            "198.51.100.7",
        );
        let wrong = ask(Some("another-secret-0123456789ab"));
        let none = ask(None);
        let short = ask(Some("short"));
        // The same answer as for a blob that is not there: no oracle.
        for refused in [wrong, none, short] {
            assert_eq!(refused.unwrap_err(), missing.clone().unwrap_err());
        }
        assert!(has(&state, &hash, "another-secret-0123456789ab").is_empty());
        assert!(has(&state, &hash, SECRET).len() == 1);
        // An upload needs a secret too.
        let other = blob(50, 9);
        let error = state
            .blob_put(&json!({
                "token": token, "hash": sha(&other), "total": 50, "offset": 0,
                "data": BASE64_STANDARD.encode(&other),
            }), PEER)
            .unwrap_err();
        assert!(error.contains("secret"), "{error}");
    }

    #[test]
    fn the_owner_can_delete_a_blob_and_nobody_else() {
        let state = state_with("delete", |config| {
            config.ext.blob_account_bytes = 1000;
        });
        let a = token_for(&state, 1, SCOPE_MESSAGES | SCOPE_EXTENDED);
        let b = token_for(&state, 2, SCOPE_MESSAGES | SCOPE_EXTENDED);
        let data = blob(800, 2);
        let hash = upload(&state, &a, &data).unwrap();
        let dir = state.blob_dir().unwrap();
        let delete = |token: &str, hash: &str| {
            state.blob_delete(&json!({"token": token, "hash": hash}))
        };
        assert_eq!(delete(&b, &hash).unwrap()["deleted"], false);
        assert!(get(&state, &hash, 0, 10).is_ok(), "another account's delete");
        assert!(delete("", &hash).is_err());
        assert!(delete(&token_for(&state, 3, SCOPE_MESSAGES), &hash).is_err());
        assert_eq!(delete(&a, &hash).unwrap()["deleted"], true);
        assert!(get(&state, &hash, 0, 10).is_err());
        assert!(has(&state, &hash, SECRET).is_empty());
        let leftovers: Vec<_> = fs::read_dir(&dir).unwrap().collect();
        assert!(leftovers.is_empty(), "{leftovers:?}");
        // The quota is free again.
        upload(&state, &a, &blob(800, 5)).expect("room after the delete");
        assert_eq!(delete(&a, &hash).unwrap()["deleted"], false);
    }

    #[test]
    fn accounts_made_from_one_address_share_one_storage_budget() {
        let state = state_with("address", |config| {
            config.ext.blob_account_bytes = 4000;
            config.ext.blob_address_bytes = 5000;
        });
        let a = token_for(&state, 1, SCOPE_MESSAGES | SCOPE_EXTENDED);
        let b = token_for(&state, 2, SCOPE_MESSAGES | SCOPE_EXTENDED);
        let c = token_for(&state, 3, SCOPE_MESSAGES | SCOPE_EXTENDED);
        {
            let database = state.database.lock().unwrap();
            note_account_group(&database, &[1_u8; 32], "198.51.100.1");
            note_account_group(&database, &[2_u8; 32], "198.51.100.1");
            note_account_group(&database, &[3_u8; 32], "203.0.113.1");
        }
        upload(&state, &a, &blob(3000, 1)).expect("first account");
        // Under its own quota, but the address is nearly used up.
        let error = upload(&state, &b, &blob(3000, 2)).unwrap_err();
        assert!(error.contains("address"), "{error}");
        upload(&state, &b, &blob(2000, 3)).expect("what is left of the address");
        // Another address is unaffected.
        upload(&state, &c, &blob(3000, 4)).expect("another address");
        // Deleting frees the address's budget.
        let hash = sha(&blob(3000, 1));
        state
            .blob_delete(&json!({"token": a, "hash": hash}))
            .unwrap();
        upload(&state, &b, &blob(1800, 5)).expect("after a delete");
    }

    #[test]
    fn a_second_request_for_an_upload_under_way_is_refused() {
        let state = state_with("busy", |_| {});
        let token = token_for(&state, 1, SCOPE_MESSAGES | SCOPE_EXTENDED);
        let data = blob(1000, 7);
        let hash = sha(&data);
        put(&state, &token, &hash, &data[..400], 1000, 0).unwrap();
        let _held = BusyUpload::take(&state.blob_busy, format!("{hash}:{}", hex(&[1_u8; 32])))
            .expect("free");
        let error = put(&state, &token, &hash, &data[400..], 1000, 400).unwrap_err();
        assert!(error.contains("busy"), "{error}");
        drop(_held);
        assert!(put(&state, &token, &hash, &data[400..], 1000, 400).is_ok());
    }

    #[test]
    fn blobs_are_off_unless_the_operator_turns_them_on() {
        let config = parity_config();
        assert_eq!(config.ext.blob_max_bytes, 0);
        let state = RelayState::new(
            config,
            crate::identity::RelayIdentity::from_seed_bytes([7_u8; 32]),
        );
        assert!(state.blob_info().is_none());
        assert!(state.policy_info()["blobs"].is_null());
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

    fn row_count(state: &RelayState, table: &str) -> i64 {
        state
            .database
            .lock()
            .unwrap()
            .query_row(&format!("SELECT COUNT(*) FROM {table}"), [], |r| r.get(0))
            .unwrap()
    }

    #[test]
    fn a_blob_is_served_only_a_few_times_its_size() {
        let state = state_with("served", |config| config.ext.blob_serve_factor = 2);
        let token = token_for(&state, 1, SCOPE_MESSAGES | SCOPE_EXTENDED);
        let data = blob(1000, 6);
        let hash = upload(&state, &token, &data).unwrap();
        assert!(get(&state, &hash, 0, 1000).is_ok());
        assert!(get(&state, &hash, 0, 1000).is_ok(), "a retry or a second device");
        // Spent: the same answer as for a blob that is not there.
        let spent = get(&state, &hash, 0, 1000).unwrap_err();
        assert_eq!(spent, get(&state, &sha(b"nothing"), 0, 10).unwrap_err());
        assert!(has(&state, &hash, SECRET).is_empty());
        // The owner may still delete it, and a factor of 0 means no limit.
        let open = state_with("served-open", |config| config.ext.blob_serve_factor = 0);
        let token = token_for(&open, 1, SCOPE_MESSAGES | SCOPE_EXTENDED);
        let hash = upload(&open, &token, &data).unwrap();
        for _ in 0..10 {
            assert!(get(&open, &hash, 0, 1000).is_ok());
        }
    }

    #[test]
    fn an_old_layout_is_dropped_and_stray_files_are_removed_at_start() {
        let old = Connection::open_in_memory().unwrap();
        old.execute_batch(
            "CREATE TABLE blobs (hash TEXT PRIMARY KEY, size INTEGER NOT NULL,
               account BLOB NOT NULL, created_millis INTEGER NOT NULL,
               expires_millis INTEGER NOT NULL);
             INSERT INTO blobs VALUES ('aa', 1, x'01', 1, 1);",
        )
        .unwrap();
        init_tables(&old).unwrap();
        let columns: Vec<String> = old
            .prepare("SELECT name FROM pragma_table_info('blobs')")
            .unwrap()
            .query_map([], |r| r.get(0))
            .unwrap()
            .map(Result::unwrap)
            .collect();
        assert!(columns.contains(&"secret_hash".to_owned()));
        assert!(columns.contains(&"served".to_owned()));
        assert_eq!(
            old.query_row("SELECT COUNT(*) FROM blobs", [], |r| r.get::<_, i64>(0))
                .unwrap(),
            0
        );
        // Files: the indexed one stays, ours without a row go, others stay.
        let state = state_with("startup", |_| {});
        let token = token_for(&state, 1, SCOPE_MESSAGES | SCOPE_EXTENDED);
        let hash = upload(&state, &token, &blob(300, 3)).unwrap();
        let dir = state.blob_dir().unwrap();
        let stray_old = dir.join(format!("{}.blob", sha(b"old layout")));
        let stray_new = blob_path(&dir, &sha(b"crash"), &[9_u8; 32]);
        let foreign = dir.join("notes.txt");
        for file in [&stray_old, &stray_new, &foreign] {
            fs::write(file, b"x").unwrap();
        }
        state.blob_startup_cleanup();
        assert!(!stray_old.exists());
        assert!(!stray_new.exists());
        assert!(foreign.exists(), "files that are not ours are left alone");
        assert!(get(&state, &hash, 0, 10).is_ok());
    }

    #[test]
    fn an_account_without_a_group_is_filed_on_its_first_upload_and_a_restart_is_not_counted_twice() {
        let state = state_with("late-group", |config| {
            config.ext.blob_account_bytes = 10_000;
            config.ext.blob_address_bytes = 2500;
        });
        let a = token_for(&state, 1, SCOPE_MESSAGES | SCOPE_EXTENDED);
        let b = token_for(&state, 2, SCOPE_MESSAGES | SCOPE_EXTENDED);
        assert_eq!(row_count(&state, "blob_account_groups"), 0);
        let data = blob(2000, 1);
        let hash = sha(&data);
        // A first attempt stops half way; starting it again is no extra.
        put(&state, &a, &hash, &data[..1000], 2000, 0).unwrap();
        put(&state, &a, &hash, &data[..1000], 2000, 0).unwrap();
        put(&state, &a, &hash, &data[1000..], 2000, 1000).unwrap();
        assert_eq!(row_count(&state, "blob_account_groups"), 1);
        // The address (all accounts without a record share the one they
        // upload from) is nearly full.
        let error = upload(&state, &b, &blob(1000, 2)).unwrap_err();
        assert!(error.contains("address"), "{error}");
        upload(&state, &b, &blob(400, 3)).expect("what is left");
    }

    #[test]
    fn deleting_takes_many_hashes_and_the_sweeper_leaves_busy_uploads() {
        let state = state_with("batch", |_| {});
        let token = token_for(&state, 1, SCOPE_MESSAGES | SCOPE_EXTENDED);
        let hashes: Vec<String> = (0..5)
            .map(|i| upload(&state, &token, &blob(200 + i, i as u8)).unwrap())
            .collect();
        let answer = state
            .blob_delete(&json!({"token": token, "hashes": hashes[..4]}))
            .unwrap();
        assert_eq!(answer["count"], 4);
        assert_eq!(row_count(&state, "blobs"), 1);
        let many: Vec<String> = (0..65).map(|i| sha(&[i])).collect();
        assert!(state
            .blob_delete(&json!({"token": token, "hashes": many}))
            .is_err());
        assert!(state.blob_delete(&json!({"token": token})).is_err());
        // An upload being handled is not swept or deleted from under it.
        let dir = state.blob_dir().unwrap();
        state
            .database
            .lock()
            .unwrap()
            .execute("UPDATE blobs SET expires_millis = 1", [])
            .unwrap();
        let busy = BusyUpload::take(&state.blob_busy, busy_key(&hashes[4], &[1_u8; 32])).unwrap();
        state.sweep_blobs(&dir, now_millis());
        assert_eq!(row_count(&state, "blobs"), 1, "busy: left alone");
        assert!(state
            .blob_delete(&json!({"token": token, "hash": hashes[4]}))
            .is_err());
        drop(busy);
        state.sweep_blobs(&dir, now_millis());
        assert_eq!(row_count(&state, "blobs"), 0);
        let leftovers: Vec<_> = fs::read_dir(&dir).unwrap().collect();
        assert!(leftovers.is_empty(), "{leftovers:?}");
    }
}
