//! Mailbox ownership (relay v2, phase C).
//!
//! A mailbox is a device id, which anyone it ever wrote to knows. Its owner
//! registers an Ed25519 key (first come, first served: device ids are
//! random, so the relay cannot check a key against one); after that,
//! `fetch`, `fetch_leased`, `ack_lease` and `subscribe` need a fresh
//! signature by that key. `store` stays open to everyone. A mailbox nobody
//! has claimed keeps v1's behaviour, so old clients are unaffected.
//!
//! Proofs:
//! - in a v2 session, once per mailbox: `mailbox_auth` with the key and a
//!   signature over `conest-mailbox-auth-v2 | handshake hash | mailbox`
//!   (bound to that session);
//! - over v1 (TCP, UDP, HTTP), on each request: `"auth": {"key", "ts",
//!   "sig"}`, the signature over
//!   `conest-mailbox-auth-v1|action|mailbox|ts|nonce` (the request's own
//!   nonce, remembered so it cannot be replayed; `ts` within five minutes).
//!
//! Trade-off: someone who knows a device id can claim its mailbox on a
//! relay before its owner does (its owner then cannot fetch there; what it
//! takes is end-to-end encrypted). Claims are bounded per address and day,
//! lapse after a while unused, and new clients claim on first use.

use std::collections::{HashMap, HashSet, VecDeque};

use base64::Engine;
use base64::engine::general_purpose::STANDARD as BASE64_STANDARD;
use ed25519_dalek::{Signature, VerifyingKey};
use rusqlite::params;
use serde_json::Value;

use crate::config::now_millis;
use crate::limits::peer_group;
use crate::storage::RelayState;
use crate::v1::RelayRequest;

pub(crate) const V1_AUTH_LABEL: &str = "conest-mailbox-auth-v1";
pub(crate) const V2_AUTH_LABEL: &[u8] = b"conest-mailbox-auth-v2";
/// How long after a claim its owner may still vouch before senders treat
/// the claim as a stranger's.
const VOUCH_GRACE_MILLIS: u64 = 10 * 60 * 1000;
/// How old an owner's claim must be before its session is trusted with
/// the hidden addresses (a throwaway claim proves nothing).
pub(crate) const TRUSTED_OWNER_AGE_MILLIS: u64 = 3 * DAY_MILLIS;

/// What the device's long-term key signs to vouch for a mailbox's owner key.
pub(crate) const DEVICE_VOUCH_LABEL: &[u8] = b"conest-mailbox-device-v1";
const DAY_MILLIS: u64 = 24 * 60 * 60 * 1000;
/// How far a v1 proof's time may be from the relay's.
const AUTH_SKEW_MILLIS: u64 = 5 * 60 * 1000;
/// v1 proof nonces remembered (each for twice the skew).
const MAX_REMEMBERED_NONCES: usize = 200_000;
/// ...of which one address group (an IPv6 /48, or an IPv4 address) may
/// hold this many.
const MAX_NONCES_PER_GROUP: usize = 2_048;

#[derive(Debug, Clone)]
pub(crate) struct OwnerEntry {
    pub(crate) key: [u8; 32],
    /// The device's long-term signing key, once the owner vouched for the
    /// link inside a session (never learned over cleartext v1): what a
    /// sender compares with the contact's key, without ever seeing it.
    pub(crate) device_key: Option<[u8; 32]>,
    /// When the claim was made.
    pub(crate) claimed_millis: u64,
    /// The day (since the epoch) it was last used.
    pub(crate) used_day: u64,
}

/// The ownership state the relay keeps in memory (mirrored in SQLite).
#[derive(Default)]
pub(crate) struct Owners {
    pub(crate) by_mailbox: HashMap<String, OwnerEntry>,
    /// Claims per address group today: (day, count).
    pub(crate) claims: HashMap<String, (u64, u32)>,
    /// v1 proof nonces seen, until when.
    pub(crate) nonces: HashMap<String, u64>,
    /// The same nonces in the order they were remembered (all last the
    /// same time, so the oldest expire first): (until, key, group).
    pub(crate) nonce_order: VecDeque<(u64, String, String)>,
    /// How many nonces each address group holds.
    pub(crate) nonce_groups: HashMap<String, usize>,
}

fn today() -> u64 {
    now_millis() / DAY_MILLIS
}

/// The mailbox a request reads or acknowledges (what needs its owner).
pub(crate) fn owned_mailbox_of(request: &RelayRequest) -> Option<&str> {
    match request {
        RelayRequest::Fetch {
            recipient_device_id,
            ..
        }
        | RelayRequest::FetchLeased {
            recipient_device_id,
            ..
        }
        | RelayRequest::AckLease {
            recipient_device_id,
            ..
        } => Some(recipient_device_id),
        RelayRequest::Store { .. }
        | RelayRequest::MailboxOwner { .. }
        | RelayRequest::Health => None,
    }
}

fn decode_key(value: &str) -> Option<[u8; 32]> {
    let bytes = BASE64_STANDARD.decode(value).ok()?;
    bytes.try_into().ok()
}

fn verify(key: &[u8; 32], message: &[u8], signature: &str) -> bool {
    let Ok(verifying) = VerifyingKey::from_bytes(key) else {
        return false;
    };
    let Some(bytes) = BASE64_STANDARD
        .decode(signature)
        .ok()
        .and_then(|bytes| <[u8; 64]>::try_from(bytes).ok())
    else {
        return false;
    };
    verifying
        .verify_strict(message, &Signature::from_bytes(&bytes))
        .is_ok()
}

/// The message a v1 proof signs.
pub(crate) fn v1_auth_message(
    action: &str,
    mailbox: &str,
    ts: u64,
    nonce: &str,
    extra: &str,
) -> Vec<u8> {
    format!("{V1_AUTH_LABEL}|{action}|{mailbox}|{ts}|{nonce}|{extra}").into_bytes()
}

/// The parameters a v1 proof also signs, so a captured proof cannot be
/// reused with other leases or limits: `lease_id|limit|wait_ms|lease_ms`
/// (empty where the request has none).
pub(crate) fn v1_auth_extra(request: &RelayRequest) -> String {
    let number = |value: Option<u64>| value.map(|v| v.to_string()).unwrap_or_default();
    match request {
        RelayRequest::Fetch { limit, wait_ms, .. } => {
            format!("|{}|{}|", number(limit.map(|v| v as u64)), number(*wait_ms))
        }
        RelayRequest::FetchLeased {
            limit,
            wait_ms,
            lease_ms,
            ..
        } => format!(
            "|{}|{}|{}",
            number(limit.map(|v| v as u64)),
            number(*wait_ms),
            number(*lease_ms)
        ),
        RelayRequest::AckLease { lease_id, .. } => format!("{lease_id}|||"),
        RelayRequest::Store { .. }
        | RelayRequest::MailboxOwner { .. }
        | RelayRequest::Health => String::new(),
    }
}

/// The message a session proof signs.
pub(crate) fn v2_auth_message(handshake_hash: &[u8], mailbox: &str) -> Vec<u8> {
    let mut message =
        Vec::with_capacity(V2_AUTH_LABEL.len() + handshake_hash.len() + mailbox.len());
    message.extend_from_slice(V2_AUTH_LABEL);
    message.extend_from_slice(handshake_hash);
    message.extend_from_slice(mailbox.as_bytes());
    message
}

impl RelayState {
    /// Loads the claimed mailboxes (startup); lapsed claims are dropped.
    pub(crate) fn load_owners(&self) -> Result<(), String> {
        let database = self
            .database
            .lock()
            .expect("relay database lock should not poison");
        database
            .execute_batch(
                "CREATE TABLE IF NOT EXISTS mailbox_owners (
                   mailbox TEXT PRIMARY KEY,
                   auth_key BLOB NOT NULL,
                   claimed_millis INTEGER NOT NULL,
                   used_day INTEGER NOT NULL
                 );",
            )
            .map_err(|error| format!("initializing mailbox owners: {error}"))?;
        // Older databases lack the column; adding it twice is harmless.
        let _ = database.execute("ALTER TABLE mailbox_owners ADD COLUMN device_key BLOB", []);
        let lapsed = today().saturating_sub(self.config.ext.owner_idle_days);
        database
            .execute(
                "DELETE FROM mailbox_owners WHERE used_day < ?1",
                params![lapsed],
            )
            .map_err(|error| format!("dropping lapsed owners: {error}"))?;
        let mut statement = database
            .prepare("SELECT mailbox, auth_key, used_day, device_key, claimed_millis FROM mailbox_owners")
            .map_err(|error| format!("reading mailbox owners: {error}"))?;
        let rows = statement
            .query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, Vec<u8>>(1)?,
                    row.get::<_, i64>(2)?,
                    row.get::<_, Option<Vec<u8>>>(3)?,
                    row.get::<_, i64>(4)?,
                ))
            })
            .map_err(|error| format!("reading mailbox owners: {error}"))?;
        let mut owners = self.owners.lock().expect("owner lock should not poison");
        for row in rows {
            let (mailbox, key, used_day, device_key, claimed) =
                row.map_err(|error| format!("reading a mailbox owner: {error}"))?;
            if let Ok(key) = <[u8; 32]>::try_from(key) {
                owners.by_mailbox.insert(
                    mailbox,
                    OwnerEntry {
                        key,
                        device_key: device_key.and_then(|bytes| <[u8; 32]>::try_from(bytes).ok()),
                        used_day: used_day.max(0) as u64,
                        claimed_millis: claimed.max(0) as u64,
                    },
                );
            }
        }
        Ok(())
    }

    /// The key that owns [mailbox], if it is claimed.
    pub(crate) fn owner_of(&self, mailbox: &str) -> Option<[u8; 32]> {
        let lapsed = today().saturating_sub(self.config.ext.owner_idle_days);
        let owners = self.owners.lock().expect("owner lock should not poison");
        owners
            .by_mailbox
            .get(mailbox)
            .filter(|entry| entry.used_day >= lapsed)
            .map(|entry| entry.key)
    }

    /// Notes that [mailbox]'s owner used it (written at most once a day).
    pub(crate) fn touch_owner(&self, mailbox: &str) {
        let day = today();
        let changed = {
            let mut owners = self.owners.lock().expect("owner lock should not poison");
            match owners.by_mailbox.get_mut(mailbox) {
                Some(entry) if entry.used_day < day => {
                    entry.used_day = day;
                    true
                }
                _ => false,
            }
        };
        if changed {
            let database = self
                .database
                .lock()
                .expect("relay database lock should not poison");
            let _ = database.execute(
                "UPDATE mailbox_owners SET used_day = ?1 WHERE mailbox = ?2",
                params![day, mailbox],
            );
        }
    }

    /// Registers [key] as [mailbox]'s owner for a claim from [source].
    /// Ok(true) when claimed now, Ok(false) when [key] owned it already.
    pub(crate) fn claim_mailbox(
        &self,
        mailbox: &str,
        key: [u8; 32],
        source: &str,
    ) -> Result<bool, String> {
        let day = today();
        let group = peer_group(source);
        {
            let mut owners = self.owners.lock().expect("owner lock should not poison");
            let lapsed = day.saturating_sub(self.config.ext.owner_idle_days);
            if let Some(entry) = owners.by_mailbox.get(mailbox)
                && entry.used_day >= lapsed
            {
                return if entry.key == key {
                    Ok(false)
                } else {
                    Err("mailbox is claimed by another key".to_owned())
                };
            }
            if owners.by_mailbox.len() >= self.config.ext.max_owners
                && !owners.by_mailbox.contains_key(mailbox)
            {
                return Err("relay takes no more mailbox claims".to_owned());
            }
            owners.claims.retain(|_, (claim_day, _)| *claim_day == day);
            if owners.claims.len() >= self.config.max_rate_keys
                && !owners.claims.contains_key(&group)
            {
                return Err("mailbox claims are used up for today".to_owned());
            }
            let counted = owners.claims.entry(group).or_insert((day, 0));
            if counted.1 >= self.config.ext.mailbox_claims_per_day {
                return Err("mailbox claims from this address are used up for today".to_owned());
            }
            counted.1 += 1;
            owners
                .by_mailbox
                .insert(
                    mailbox.to_owned(),
                    OwnerEntry {
                        key,
                        device_key: None,
                        used_day: day,
                        claimed_millis: now_millis(),
                    },
                );
        }
        let database = self
            .database
            .lock()
            .expect("relay database lock should not poison");
        database
            .execute(
                "INSERT OR REPLACE INTO mailbox_owners
                   (mailbox, auth_key, claimed_millis, used_day)
                 VALUES (?1, ?2, ?3, ?4)",
                params![mailbox, key.to_vec(), now_millis(), day],
            )
            .map_err(|error| format!("recording a mailbox claim: {error}"))?;
        Ok(true)
    }

    /// Whether [request] may run: a claimed mailbox needs its owner's proof
    /// ([session] says whether this session proved it; [auth] is a v1
    /// proof). A valid v1 proof for an unclaimed mailbox claims it.
    pub(crate) fn authorize_request(
        &self,
        request: &RelayRequest,
        action: &str,
        auth: Option<&Value>,
        nonce: Option<&str>,
        session: Option<&dyn Fn(&str) -> bool>,
        source: &str,
    ) -> Result<(), String> {
        let Some(mailbox) = owned_mailbox_of(request) else {
            return Ok(());
        };
        let owner = self.owner_of(mailbox);
        if owner.is_some()
            && let Some(proved) = session
            && proved(mailbox)
        {
            self.touch_owner(mailbox);
            return Ok(());
        }
        let Some(auth) = auth else {
            return match owner {
                None => Ok(()),
                Some(_) => Err("this mailbox needs its owner's signature".to_owned()),
            };
        };
        let key = match (owner, auth.get("key").and_then(Value::as_str)) {
            (Some(owner), Some(given)) => {
                if decode_key(given) != Some(owner) {
                    return Err("mailbox is claimed by another key".to_owned());
                }
                owner
            }
            (Some(owner), None) => owner,
            (None, Some(given)) => decode_key(given).ok_or("invalid mailbox key")?,
            (None, None) => return Err("a mailbox proof needs its key".to_owned()),
        };
        self.check_v1_proof(&key, action, mailbox, auth, nonce, &v1_auth_extra(request))?;
        let nonce = nonce.unwrap_or_default();
        if owner.is_none() {
            // Claimed now; past this address's claims, the request still
            // runs as v1 would, and its proof is not remembered (it
            // claimed nothing).
            if self.claim_mailbox(mailbox, key, source).is_err() {
                return Ok(());
            }
        } else {
            self.touch_owner(mailbox);
        }
        self.remember_nonce(mailbox, nonce, source)
    }

    /// Remembers a proof's nonce (only after the proof did its work), for
    /// twice the skew: bounded in all and per address group, the oldest
    /// expiring from the front of a time-ordered queue.
    fn remember_nonce(&self, mailbox: &str, nonce: &str, source: &str) -> Result<(), String> {
        let now = now_millis();
        let group = peer_group(source);
        let mut owners = self.owners.lock().expect("owner lock should not poison");
        while let Some((until, _, _)) = owners.nonce_order.front() {
            if *until > now {
                break;
            }
            let (_, key, old_group) = owners.nonce_order.pop_front().expect("front exists");
            owners.nonces.remove(&key);
            if let Some(count) = owners.nonce_groups.get_mut(&old_group) {
                *count -= 1;
                if *count == 0 {
                    owners.nonce_groups.remove(&old_group);
                }
            }
        }
        let seen = format!("{mailbox}|{nonce}");
        if owners.nonces.contains_key(&seen) {
            return Err("mailbox proof was used already".to_owned());
        }
        if owners.nonces.len() >= MAX_REMEMBERED_NONCES
            || owners.nonce_groups.get(&group).copied().unwrap_or(0) >= MAX_NONCES_PER_GROUP
        {
            return Err("relay is busy; try again".to_owned());
        }
        let until = now + 2 * AUTH_SKEW_MILLIS;
        owners.nonces.insert(seen.clone(), until);
        owners.nonce_order.push_back((until, seen, group.clone()));
        *owners.nonce_groups.entry(group).or_insert(0) += 1;
        Ok(())
    }

    fn check_v1_proof(
        &self,
        key: &[u8; 32],
        action: &str,
        mailbox: &str,
        auth: &Value,
        nonce: Option<&str>,
        extra: &str,
    ) -> Result<(), String> {
        let nonce = nonce
            .filter(|nonce| !nonce.is_empty() && nonce.len() <= 64)
            .ok_or("a mailbox proof needs the request's nonce")?;
        let ts = auth
            .get("ts")
            .and_then(Value::as_u64)
            .ok_or("a mailbox proof needs its time")?;
        let now = now_millis();
        if ts.abs_diff(now) > AUTH_SKEW_MILLIS {
            return Err("mailbox proof is out of date".to_owned());
        }
        let signature = auth
            .get("sig")
            .and_then(Value::as_str)
            .ok_or("a mailbox proof needs its signature")?;
        if !verify(
            key,
            &v1_auth_message(action, mailbox, ts, nonce, extra),
            signature,
        ) {
            return Err("mailbox proof does not verify".to_owned());
        }
        // Seen already? (It is remembered once the proof has done its
        // work: see [Self::remember_nonce].)
        let owners = self.owners.lock().expect("owner lock should not poison");
        if owners.nonces.contains_key(&format!("{mailbox}|{nonce}")) {
            return Err("mailbox proof was used already".to_owned());
        }
        Ok(())
    }

    /// A session's `mailbox_auth`: checks the proof bound to
    /// [handshake_hash] and claims the mailbox when nobody has.
    pub(crate) fn authorize_session(
        &self,
        request: &Value,
        handshake_hash: &[u8],
        source: &str,
    ) -> Result<String, String> {
        let mailbox = request
            .get("mailbox")
            .and_then(Value::as_str)
            .ok_or("mailbox_auth needs a mailbox")?;
        crate::v1::validate_mailbox_id(mailbox)?;
        let key = request
            .get("auth_key")
            .and_then(Value::as_str)
            .and_then(decode_key)
            .ok_or("mailbox_auth needs a key")?;
        let signature = request
            .get("signature")
            .and_then(Value::as_str)
            .ok_or("mailbox_auth needs a signature")?;
        if !verify(&key, &v2_auth_message(handshake_hash, mailbox), signature) {
            return Err("mailbox proof does not verify".to_owned());
        }
        // The device's long-term key vouching for this owner key (only
        // ever sent inside a session): checked before anything changes.
        let device_key = match (
            request.get("device_key").and_then(Value::as_str),
            request.get("device_sig").and_then(Value::as_str),
        ) {
            (Some(given), Some(signature)) => {
                let device = decode_key(given).ok_or("invalid device key")?;
                let mut message = DEVICE_VOUCH_LABEL.to_vec();
                message.extend_from_slice(&(mailbox.len() as u16).to_be_bytes());
                message.extend_from_slice(mailbox.as_bytes());
                message.extend_from_slice(&key);
                message.extend_from_slice(&self.identity.signing_key.verifying_key().to_bytes());
                if !verify(&device, &message, signature) {
                    return Err("device vouch does not verify".to_owned());
                }
                Some(device)
            }
            (None, None) => None,
            _ => return Err("a device vouch needs its key and signature".to_owned()),
        };
        match self.owner_of(mailbox) {
            Some(owner) if owner == key => self.touch_owner(mailbox),
            // A claim nobody vouched for (a v1 auto-claim, an old claim) is
            // provisional: a session that vouches takes the mailbox over.
            Some(_) if device_key.is_some() && self.is_unvouched(mailbox) => {
                self.replace_owner(mailbox, key)?;
            }
            Some(_) => return Err("mailbox is claimed by another key".to_owned()),
            None => {
                self.claim_mailbox(mailbox, key, source)?;
            }
        }
        if let Some(device) = device_key {
            self.vouch_device(mailbox, device)?;
        }
        Ok(mailbox.to_owned())
    }

    fn is_unvouched(&self, mailbox: &str) -> bool {
        self.owners
            .lock()
            .expect("owner lock should not poison")
            .by_mailbox
            .get(mailbox)
            .is_some_and(|entry| entry.device_key.is_none())
    }

    /// A vouching session takes over a mailbox whose claim was never vouched.
    fn replace_owner(&self, mailbox: &str, key: [u8; 32]) -> Result<(), String> {
        {
            let mut owners = self.owners.lock().expect("owner lock should not poison");
            if let Some(entry) = owners.by_mailbox.get_mut(mailbox) {
                entry.key = key;
                entry.device_key = None;
                entry.used_day = today();
                entry.claimed_millis = now_millis();
            }
        }
        let database = self
            .database
            .lock()
            .expect("relay database lock should not poison");
        database
            .execute(
                "UPDATE mailbox_owners SET auth_key = ?1, device_key = NULL, claimed_millis = ?2, used_day = ?3 WHERE mailbox = ?4",
                params![key.to_vec(), now_millis(), today(), mailbox],
            )
            .map_err(|error| format!("replacing a provisional claim: {error}"))?;
        Ok(())
    }

    /// Whether [mailbox]'s claim is old enough for its owner's session to
    /// count as a user's.
    pub(crate) fn owner_is_established(&self, mailbox: &str) -> bool {
        let owners = self.owners.lock().expect("owner lock should not poison");
        owners.by_mailbox.get(mailbox).is_some_and(|entry| {
            now_millis().saturating_sub(entry.claimed_millis) >= TRUSTED_OWNER_AGE_MILLIS
        })
    }

    /// Records the device key behind [mailbox]'s owner key. The first
    /// vouch wins; a different one later is refused.
    fn vouch_device(&self, mailbox: &str, device: [u8; 32]) -> Result<(), String> {
        {
            let mut owners = self.owners.lock().expect("owner lock should not poison");
            let Some(entry) = owners.by_mailbox.get_mut(mailbox) else {
                return Ok(());
            };
            match entry.device_key {
                Some(known) if known == device => return Ok(()),
                Some(_) => return Err("mailbox is vouched for by another device key".to_owned()),
                None => entry.device_key = Some(device),
            }
        }
        let database = self
            .database
            .lock()
            .expect("relay database lock should not poison");
        database
            .execute(
                "UPDATE mailbox_owners SET device_key = ?1 WHERE mailbox = ?2",
                params![device.to_vec(), mailbox],
            )
            .map_err(|error| format!("recording a device vouch: {error}"))?;
        Ok(())
    }

    /// Answers a sender's "does this mailbox belong to [expected]'s
    /// device?" without telling it any key: `matches`, `unclaimed` (nobody
    /// vouched yet) or `other`.
    pub(crate) fn vouch_status(&self, mailbox: &str, expected: Option<[u8; 32]>) -> &'static str {
        let lapsed = today().saturating_sub(self.config.ext.owner_idle_days);
        let owners = self.owners.lock().expect("owner lock should not poison");
        match owners
            .by_mailbox
            .get(mailbox)
            .filter(|entry| entry.used_day >= lapsed)
        {
            None => "unclaimed",
            Some(entry) => match (entry.device_key, expected) {
                // Claimed but never vouched for: the real owner is given a
                // few minutes to vouch, after that it is a stranger's.
                (None, _) if now_millis().saturating_sub(entry.claimed_millis) < VOUCH_GRACE_MILLIS => {
                    "unclaimed"
                }
                (None, _) => "unvouched",
                (Some(known), Some(wanted)) if known == wanted => "matches",
                _ => "other",
            },
        }
    }
}

/// Mailboxes a session proved, bounded.
pub(crate) const MAX_SESSION_MAILBOXES: usize = 64;

pub(crate) type ProvedMailboxes = HashSet<String>;

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::parity_tests::{parity_config, start_tokio};
    use crate::session::frame_type;
    use crate::session::tests::{TestClient, relay_public};
    use crate::v1::handle_request_bytes;
    use ed25519_dalek::{Signer, SigningKey};
    use serde_json::json;

    fn state() -> RelayState {
        RelayState::new(
            parity_config(),
            crate::identity::RelayIdentity::from_seed_bytes([7_u8; 32]),
        )
    }

    pub(crate) fn owner_key(seed: u8) -> SigningKey {
        SigningKey::from_bytes(&[seed; 32])
    }

    /// A v1 request for [action] on [mailbox] with a proof by [key] (or
    /// none), its nonce [nonce], made at [ts].
    fn v1(action: &str, mailbox: &str, key: Option<&SigningKey>, nonce: &str, ts: u64) -> Value {
        let mut request = json!({
            "action": action,
            "recipient_device_id": mailbox,
            "nonce": nonce,
        });
        if action == "ack_lease" {
            request["lease_id"] = json!("AAAAAAAAAAAAAAAAAAAAAAAA");
        }
        if let Some(key) = key {
            let extra = match action {
                "ack_lease" => "AAAAAAAAAAAAAAAAAAAAAAAA|||",
                "fetch" => "|||",
                "fetch_leased" => "|||",
                _ => "",
            };
            let signature = key.sign(&v1_auth_message(action, mailbox, ts, nonce, extra));
            request["auth"] = json!({
                "key": BASE64_STANDARD.encode(key.verifying_key().to_bytes()),
                "ts": ts,
                "sig": BASE64_STANDARD.encode(signature.to_bytes()),
            });
        }
        request
    }

    fn send(state: &RelayState, request: &Value, peer: &str) -> Value {
        let line = request.to_string();
        handle_request_bytes(line.as_bytes(), line.len(), state, peer)
    }

    fn store(state: &RelayState, mailbox: &str, id: &str) -> Value {
        send(
            state,
            &json!({
                "action": "store",
                "recipient_device_id": mailbox,
                "envelope": {"kind": "direct_message", "messageId": id, "senderDeviceId": "dev-a"},
            }),
            "198.51.100.50",
        )
    }

    #[test]
    fn an_unclaimed_mailbox_keeps_v1_and_a_proof_claims_it() {
        let state = state();
        let now = now_millis();
        let owner = owner_key(1);
        assert_eq!(store(&state, "dev-o", "m1")["ok"], true);
        // Nobody claimed it: as before.
        let answer = send(
            &state,
            &v1("fetch", "dev-o", None, "bm9uY2UtMA==", now),
            "198.51.100.1",
        );
        assert_eq!(answer["ok"], true, "{answer}");
        // A proof claims it.
        let answer = send(
            &state,
            &v1("fetch", "dev-o", Some(&owner), "bm9uY2UtMQ==", now),
            "198.51.100.1",
        );
        assert_eq!(answer["ok"], true, "{answer}");
        assert_eq!(
            state.owner_of("dev-o"),
            Some(owner.verifying_key().to_bytes())
        );
    }

    #[test]
    fn a_claimed_mailbox_needs_its_owners_fresh_proof_and_store_stays_open() {
        let state = state();
        let now = now_millis();
        let owner = owner_key(1);
        let stranger = owner_key(2);
        state
            .claim_mailbox("dev-o", owner.verifying_key().to_bytes(), "198.51.100.1")
            .expect("claim");
        assert_eq!(store(&state, "dev-o", "m1")["ok"], true, "store stays open");
        for action in ["fetch", "fetch_leased", "ack_lease"] {
            let answer = send(
                &state,
                &v1(action, "dev-o", None, "bm9uY2UtYQ==", now),
                "198.51.100.9",
            );
            assert_eq!(
                answer["error"], "this mailbox needs its owner's signature",
                "{action}"
            );
            let answer = send(
                &state,
                &v1(action, "dev-o", Some(&stranger), "bm9uY2UtYg==", now),
                "198.51.100.9",
            );
            assert_eq!(
                answer["error"], "mailbox is claimed by another key",
                "{action}"
            );
        }
        // Out of date.
        let answer = send(
            &state,
            &v1(
                "fetch",
                "dev-o",
                Some(&owner),
                "bm9uY2UtYw==",
                now - 10 * 60 * 1000,
            ),
            "198.51.100.1",
        );
        assert_eq!(answer["error"], "mailbox proof is out of date");
        // A proof over another action does not verify.
        let mut forged = v1("fetch", "dev-o", Some(&owner), "bm9uY2UtZA==", now);
        forged["action"] = json!("fetch_leased");
        let answer = send(&state, &forged, "198.51.100.1");
        assert_eq!(answer["error"], "mailbox proof does not verify");
        // The owner fetches, once per proof.
        let good = v1("fetch", "dev-o", Some(&owner), "bm9uY2UtZQ==", now);
        let answer = send(&state, &good, "198.51.100.1");
        assert_eq!(answer["messages"][0]["messageId"], "m1", "{answer}");
        let answer = send(&state, &good, "198.51.100.1");
        assert_eq!(answer["error"], "mailbox proof was used already");
    }

    #[test]
    fn claims_are_bounded_per_address_and_day_and_survive_a_restart() {
        let mut config = parity_config();
        config.ext.mailbox_claims_per_day = 1;
        let path = std::env::temp_dir().join(format!(
            "conest-owners-{}-{}.sqlite3",
            std::process::id(),
            now_millis()
        ));
        config.database_path = path.clone();
        let identity = crate::identity::RelayIdentity::from_seed_bytes([7_u8; 32]);
        {
            let state = RelayState::new(config.clone(), identity.clone());
            assert_eq!(
                state.claim_mailbox("dev-1", [1_u8; 32], "198.51.100.1"),
                Ok(true)
            );
            assert!(
                state
                    .claim_mailbox("dev-2", [2_u8; 32], "198.51.100.1")
                    .is_err()
            );
            // Another address has claims of its own.
            assert_eq!(
                state.claim_mailbox("dev-2", [2_u8; 32], "198.51.100.2"),
                Ok(true)
            );
            // The same key again is not a new claim.
            assert_eq!(
                state.claim_mailbox("dev-1", [1_u8; 32], "198.51.100.1"),
                Ok(false)
            );
        }
        let restarted = RelayState::new(config, identity);
        assert_eq!(restarted.owner_of("dev-1"), Some([1_u8; 32]));
        assert_eq!(restarted.owner_of("dev-2"), Some([2_u8; 32]));
        let _ = std::fs::remove_file(&path);
    }

    pub(crate) fn prove(
        client: &mut TestClient,
        stream: u32,
        mailbox: &str,
        key: &SigningKey,
        hash: &[u8],
    ) -> Value {
        let signature = key.sign(&v2_auth_message(hash, mailbox));
        client.request(
            stream,
            &json!({
                "action": "mailbox_auth",
                "mailbox": mailbox,
                "auth_key": BASE64_STANDARD.encode(key.verifying_key().to_bytes()),
                "signature": BASE64_STANDARD.encode(signature.to_bytes()),
            }),
        );
        client.next_json().1
    }

    #[test]
    fn a_session_proves_a_mailbox_once_and_the_proof_stays_with_it() {
        let relay = start_tokio(parity_config());
        let key = relay_public(&relay.state);
        let owner = owner_key(5);
        let mut first = TestClient::connect(relay.tcp, &key);
        let hash = first.handshake_hash.clone();
        let answer = prove(&mut first, 1, "dev-s", &owner, &hash);
        assert_eq!(answer["ok"], true, "{answer}");
        assert!(relay.state.owner_of("dev-s").is_some(), "claimed");
        first.request(
            3,
            &json!({"action": "fetch_leased", "recipient_device_id": "dev-s"}),
        );
        let (_, answer) = first.next_json();
        assert_eq!(answer["ok"], true, "{answer}");
        // Another session has not proved it: refused, and the first
        // session's proof does not carry over.
        let mut second = TestClient::connect(relay.tcp, &key);
        second.request(
            1,
            &json!({"action": "fetch", "recipient_device_id": "dev-s"}),
        );
        let (_, answer) = second.next_json();
        assert_eq!(answer["error"], "this mailbox needs its owner's signature");
        second.request(3, &json!({"action": "subscribe", "mailboxes": ["dev-s"]}));
        let (frame, answer) = second.next_json();
        assert_eq!(frame.kind, frame_type::RESPONSE);
        assert_eq!(answer["error"], "this mailbox needs its owner's signature");
        let answer = prove(&mut second, 5, "dev-s", &owner, &hash);
        assert_eq!(answer["error"], "mailbox proof does not verify");
        // Someone else's key cannot take it.
        let second_hash = second.handshake_hash.clone();
        let answer = prove(&mut second, 7, "dev-s", &owner_key(6), &second_hash);
        assert_eq!(answer["error"], "mailbox is claimed by another key");
        // The owner proves itself on the second session too.
        let answer = prove(&mut second, 9, "dev-s", &owner, &second_hash);
        assert_eq!(answer["ok"], true, "{answer}");
        second.request(11, &json!({"action": "subscribe", "mailboxes": ["dev-s"]}));
        let (frame, answer) = second.next_json();
        assert_eq!(frame.kind, frame_type::EVENT);
        assert_eq!(answer["subscribed"], json!(["dev-s"]));
    }

    #[test]
    fn a_subscription_loses_a_mailbox_claimed_after_it_began() {
        let relay = start_tokio(parity_config());
        let key = relay_public(&relay.state);
        let mut watcher = TestClient::connect(relay.tcp, &key);
        watcher.request(1, &json!({"action": "subscribe", "mailboxes": ["dev-late"], "lease_ms": 30000}));
        let (_, started) = watcher.next_json();
        assert_eq!(started["subscribed"], json!(["dev-late"]));
        // The owner claims it afterwards, over another session.
        let mut owner = TestClient::connect(relay.tcp, &key);
        let hash = owner.handshake_hash.clone();
        let answer = prove(&mut owner, 1, "dev-late", &owner_key(5), &hash);
        assert_eq!(answer["ok"], true, "{answer}");
        // A store wakes the watcher: it is told, and leases nothing.
        owner.request(
            3,
            &json!({"action": "store", "recipient_device_id": "dev-late",
                "envelope": {"kind": "direct_message", "messageId": "m-late",
                "conversationId": "c", "senderAccountId": "a", "senderDeviceId": "s",
                "recipientDeviceId": "dev-late", "createdAt": "2026-04-16T00:00:00.000Z",
                "payloadBase64": "aGVsbG8="}}),
        );
        let _ = owner.next_json();
        let (frame, event) = watcher.next_json();
        assert_eq!(frame.kind, frame_type::EVENT);
        assert_eq!(event["ok"], false, "{event}");
        assert_eq!(event["error"], "this mailbox needs its owner's signature");
        assert!(event.get("messages").is_none(), "{event}");
        let leased: i64 = relay
            .state
            .database
            .lock()
            .unwrap()
            .query_row(
                "SELECT COUNT(*) FROM queue_entries WHERE lease_id IS NOT NULL",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(leased, 0, "the watcher leased the owner's message");
    }

    #[test]
    fn a_proof_that_claimed_nothing_is_not_remembered() {
        let mut config = parity_config();
        config.ext.mailbox_claims_per_day = 1;
        config.max_requests_per_minute = 100_000;
        let state = RelayState::new(
            config,
            crate::identity::RelayIdentity::from_seed_bytes([7_u8; 32]),
        );
        let key = owner_key(3);
        let now = now_millis();
        let first = send(
            &state,
            &v1("fetch", "dev-x", Some(&key), "bm9uY2UtMQ==", now),
            "198.51.100.7",
        );
        assert_eq!(first["ok"], true, "{first}");
        // The address is out of claims: the request runs unowned, and the
        // proof is not kept (it claimed nothing), so a retry is no replay.
        let second = v1("fetch", "dev-y", Some(&key), "bm9uY2UtMg==", now);
        for _ in 0..3 {
            let answer = send(&state, &second, "198.51.100.7");
            assert_eq!(answer["ok"], true, "{answer}");
        }
        assert!(state.owner_of("dev-y").is_none());
        assert_eq!(state.owners.lock().unwrap().nonces.len(), 1);
    }

    #[test]
    fn remembered_proofs_are_bounded_per_address_group_and_expire_in_order() {
        let mut config = parity_config();
        config.max_requests_per_minute = 1_000_000;
        let state = RelayState::new(
            config,
            crate::identity::RelayIdentity::from_seed_bytes([7_u8; 32]),
        );
        let owner = owner_key(1);
        state
            .claim_mailbox("dev-o", owner.verifying_key().to_bytes(), "198.51.100.1")
            .expect("claim");
        let now = now_millis();
        let mut busy = 0;
        for index in 0..(MAX_NONCES_PER_GROUP + 20) {
            let answer = send(
                &state,
                &v1("fetch", "dev-o", Some(&owner), &format!("n{index}"), now),
                "198.51.100.1",
            );
            if answer["error"] == "relay is busy; try again" {
                busy += 1;
            }
        }
        assert_eq!(busy, 20, "the group's share is its cap");
        // Another address is not held up by it.
        let answer = send(
            &state,
            &v1("fetch", "dev-o", Some(&owner), "other", now),
            "198.51.100.2",
        );
        assert_eq!(answer["ok"], true, "{answer}");
        // Expired proofs leave from the front of the queue.
        {
            let mut owners = state.owners.lock().unwrap();
            for entry in owners.nonce_order.iter_mut() {
                entry.0 = 1;
            }
        }
        let answer = send(
            &state,
            &v1("fetch", "dev-o", Some(&owner), "fresh", now),
            "198.51.100.1",
        );
        assert_eq!(answer["ok"], true, "{answer}");
        assert!(state.owners.lock().unwrap().nonces.len() <= 2);
    }

    fn prove_vouched(
        client: &mut TestClient,
        stream: u32,
        mailbox: &str,
        key: &SigningKey,
        device: &SigningKey,
        identity_public: &[u8; 32],
    ) -> Value {
        let hash = client.handshake_hash.clone();
        let signature = key.sign(&v2_auth_message(&hash, mailbox));
        let mut vouch = DEVICE_VOUCH_LABEL.to_vec();
        vouch.extend_from_slice(&(mailbox.len() as u16).to_be_bytes());
        vouch.extend_from_slice(mailbox.as_bytes());
        vouch.extend_from_slice(&key.verifying_key().to_bytes());
        vouch.extend_from_slice(identity_public);
        client.request(
            stream,
            &json!({
                "action": "mailbox_auth",
                "mailbox": mailbox,
                "auth_key": BASE64_STANDARD.encode(key.verifying_key().to_bytes()),
                "signature": BASE64_STANDARD.encode(signature.to_bytes()),
                "device_key": BASE64_STANDARD.encode(device.verifying_key().to_bytes()),
                "device_sig": BASE64_STANDARD.encode(device.sign(&vouch).to_bytes()),
            }),
        );
        client.next_json().1
    }

    #[test]
    fn senders_ask_whether_a_mailbox_is_vouched_for_without_being_told_a_key() {
        let relay = start_tokio(parity_config());
        let key = relay_public(&relay.state);
        let identity_public = relay.state.identity.signing_key.verifying_key().to_bytes();
        let device = owner_key(40);
        let ask = |client: &mut TestClient, stream: u32, expected: Option<&SigningKey>| {
            let mut request = json!({"action": "mailbox_owner", "recipient_device_id": "dev-q"});
            if let Some(expected) = expected {
                request["expected_key"] =
                    json!(BASE64_STANDARD.encode(expected.verifying_key().to_bytes()));
            }
            client.request(stream, &request);
            client.next_json().1
        };
        let mut asker = TestClient::connect(relay.tcp, &key);
        assert_eq!(ask(&mut asker, 1, Some(&device))["vouch"], "unclaimed");
        // The device claims with a derived key and vouches for it.
        let mut owner = TestClient::connect(relay.tcp, &key);
        let answer = prove_vouched(&mut owner, 1, "dev-q", &owner_key(4), &device, &identity_public);
        assert_eq!(answer["ok"], true, "{answer}");
        let matches = ask(&mut asker, 3, Some(&device));
        assert_eq!(matches["vouch"], "matches", "{matches}");
        assert!(!matches.to_string().contains(&BASE64_STANDARD.encode(device.verifying_key().to_bytes())));
        assert_eq!(ask(&mut asker, 5, Some(&owner_key(41)))["vouch"], "other");
        assert_eq!(ask(&mut asker, 7, None)["vouch"], "other");
        // A second vouch from another device key is refused.
        let mut thief = TestClient::connect(relay.tcp, &key);
        let refused = prove_vouched(&mut thief, 1, "dev-q", &owner_key(4), &owner_key(42), &identity_public);
        assert_eq!(refused["error"], "mailbox is vouched for by another device key");
        // A vouch that does not verify (signed for another relay) is refused.
        let mut forged = TestClient::connect(relay.tcp, &key);
        let refused = prove_vouched(&mut forged, 1, "dev-z", &owner_key(5), &device, &[9_u8; 32]);
        assert_eq!(refused["error"], "device vouch does not verify");
        // Over cleartext v1 nothing is told.
        let line = json!({"action": "mailbox_owner", "recipient_device_id": "dev-q"}).to_string();
        let v1 = crate::v1::handle_request_bytes(line.as_bytes(), line.len(), &relay.state, "198.51.100.3");
        assert_eq!(v1["error"], "mailbox_owner needs an encrypted session");
    }

    #[test]
    fn a_claim_nobody_vouched_for_becomes_unvouched_and_a_vouching_session_takes_it_over() {
        let relay = start_tokio(parity_config());
        let key = relay_public(&relay.state);
        let identity_public = relay.state.identity.signing_key.verifying_key().to_bytes();
        let device = owner_key(50);
        // A squatter claims the victim's id over v1, without any vouch.
        let squatter = owner_key(51);
        let now = now_millis();
        let claimed = send(
            &relay.state,
            &v1("fetch", "dev-victim", Some(&squatter), "c3F1YXQ=", now),
            "198.51.100.77",
        );
        assert_eq!(claimed["ok"], true, "{claimed}");
        assert!(relay.state.owner_of("dev-victim").is_some());
        let ask = |client: &mut TestClient, stream: u32| {
            client.request(
                stream,
                &json!({"action": "mailbox_owner", "recipient_device_id": "dev-victim",
                    "expected_key": BASE64_STANDARD.encode(device.verifying_key().to_bytes())}),
            );
            client.next_json().1
        };
        let mut asker = TestClient::connect(relay.tcp, &key);
        // Within the grace the real owner may still vouch.
        assert_eq!(ask(&mut asker, 1)["vouch"], "unclaimed");
        // Past it, the claim is a stranger's: senders must not use it.
        relay
            .state
            .owners
            .lock()
            .unwrap()
            .by_mailbox
            .get_mut("dev-victim")
            .unwrap()
            .claimed_millis -= 60 * 60 * 1000;
        assert_eq!(ask(&mut asker, 3)["vouch"], "unvouched");
        // The real device, in a session, vouches with another derived key
        // and takes the provisional claim over.
        let mut owner = TestClient::connect(relay.tcp, &key);
        let answer = prove_vouched(&mut owner, 1, "dev-victim", &owner_key(52), &device, &identity_public);
        assert_eq!(answer["ok"], true, "{answer}");
        assert_eq!(ask(&mut asker, 5)["vouch"], "matches");
        assert_eq!(
            relay.state.owner_of("dev-victim"),
            Some(owner_key(52).verifying_key().to_bytes())
        );
        // The squatter's v1 proof no longer works.
        let again = send(
            &relay.state,
            &v1("fetch", "dev-victim", Some(&squatter), "c3F1YXQy", now),
            "198.51.100.77",
        );
        assert_eq!(again["error"], "mailbox is claimed by another key");
        // A claim that was vouched for is not taken over by anyone.
        let mut thief = TestClient::connect(relay.tcp, &key);
        let refused = prove_vouched(&mut thief, 1, "dev-victim", &squatter, &owner_key(53), &identity_public);
        assert_eq!(refused["error"], "mailbox is claimed by another key");
        // A session claim without a vouch is provisional too.
        let mut plain = TestClient::connect(relay.tcp, &key);
        let hash = plain.handshake_hash.clone();
        let plain_claim = prove(&mut plain, 1, "dev-plain", &owner_key(54), &hash);
        assert_eq!(plain_claim["ok"], true, "{plain_claim}");
        relay
            .state
            .owners
            .lock()
            .unwrap()
            .by_mailbox
            .get_mut("dev-plain")
            .unwrap()
            .claimed_millis -= 60 * 60 * 1000;
        assert_eq!(relay.state.vouch_status("dev-plain", None), "unvouched");
    }
}
