//! Registration, capability tokens and quotas (relay v2, phase D).
//!
//! Like a Matrix homeserver, an operator chooses who may use the relay:
//! - tier 1 (messages): `open` (the default, as before), `registered`
//!   (stores need a token) or `off` (no new messages);
//! - registration (which also opens tiers 2–4, blobs, chunk sets and call
//!   media, in later milestones): `open`, `invite`, `password` or
//!   `closed` (the default).
//!
//! A client registers an account key over a v2 session (`register`, with
//! an invite code or the password when asked, signed by the account key
//! and bound to the session) and gets a token:
//! `v1.<account>.<scope>.<quota>.<expiry>.<mac>`, the MAC being
//! HMAC-SHA256(relay secret, account ‖ scope ‖ quota ‖ expiry). Registering
//! again with the same key refreshes it. Accounts are per device for now
//! (M29 links devices into one).

use std::collections::HashMap;

use base64::Engine;
use base64::engine::general_purpose::STANDARD as BASE64_STANDARD;
use base64::engine::general_purpose::URL_SAFE_NO_PAD as BASE64_URL;
use ed25519_dalek::{Signature, VerifyingKey};
use hmac::{Hmac, Mac};
use rusqlite::{Connection, OptionalExtension, params};
use serde_json::{Value, json};
use sha2::Sha256;

use crate::config::now_millis;
use crate::limits::peer_group;
use crate::storage::RelayState;

pub(crate) const REGISTER_LABEL: &[u8] = b"conest-relay-register-v1";
/// Scope bits a token carries.
pub(crate) const SCOPE_MESSAGES: u8 = 1;
pub(crate) const SCOPE_EXTENDED: u8 = 2 | 4 | 8;
const DAY_MILLIS: u64 = 24 * 60 * 60 * 1000;
/// Registrations one address may make a day.
const REGISTRATIONS_PER_DAY: u32 = 16;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Tier1Policy {
    Open,
    Registered,
    Off,
}

impl Tier1Policy {
    pub(crate) fn parse(value: &str) -> Result<Self, String> {
        match value {
            "open" => Ok(Self::Open),
            "registered" => Ok(Self::Registered),
            "off" => Ok(Self::Off),
            _ => Err(format!(
                "tier 1 policy must be open, registered or off: {value}"
            )),
        }
    }

    pub(crate) fn name(self) -> &'static str {
        match self {
            Self::Open => "open",
            Self::Registered => "registered",
            Self::Off => "off",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum RegistrationPolicy {
    Open,
    Invite,
    Password,
    Closed,
}

impl RegistrationPolicy {
    pub(crate) fn parse(value: &str) -> Result<Self, String> {
        match value {
            "open" => Ok(Self::Open),
            "invite" => Ok(Self::Invite),
            "password" => Ok(Self::Password),
            "closed" => Ok(Self::Closed),
            _ => Err(format!(
                "registration must be open, invite, password or closed: {value}"
            )),
        }
    }

    pub(crate) fn name(self) -> &'static str {
        match self {
            Self::Open => "open",
            Self::Invite => "invite",
            Self::Password => "password",
            Self::Closed => "closed",
        }
    }
}

/// What a valid token says.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Token {
    pub(crate) account: [u8; 32],
    pub(crate) scope: u8,
    pub(crate) quota: u64,
    pub(crate) expiry_millis: u64,
}

/// Accounts kept in memory (mirrored in SQLite): quota, or removed.
#[derive(Default)]
pub(crate) struct Accounts {
    pub(crate) quotas: HashMap<[u8; 32], u64>,
    /// Registrations per address group today: (day, count).
    pub(crate) registrations: HashMap<String, (u64, u32)>,
    /// Bytes stored per account this minute: (minute, bytes).
    pub(crate) usage: HashMap<[u8; 32], (u64, u64)>,
    /// When the accounts were last read from the database (the operator's
    /// `account remove` and `quota set` write there while the relay runs).
    pub(crate) loaded_millis: u64,
}

/// How often a running relay re-reads its accounts.
const ACCOUNTS_REFRESH_MILLIS: u64 = 5_000;

type HmacSha256 = Hmac<Sha256>;

fn mac(secret: &[u8], account: &[u8; 32], scope: u8, quota: u64, expiry: u64) -> [u8; 32] {
    let mut hmac = HmacSha256::new_from_slice(secret).expect("any key length works");
    hmac.update(account);
    hmac.update(&[scope]);
    hmac.update(&quota.to_be_bytes());
    hmac.update(&expiry.to_be_bytes());
    let mut out = [0_u8; 32];
    out.copy_from_slice(&hmac.finalize().into_bytes());
    out
}

pub(crate) fn encode_token(secret: &[u8], token: &Token) -> String {
    let tag = mac(
        secret,
        &token.account,
        token.scope,
        token.quota,
        token.expiry_millis,
    );
    format!(
        "v1.{}.{}.{}.{}.{}",
        BASE64_URL.encode(token.account),
        token.scope,
        token.quota,
        token.expiry_millis,
        BASE64_URL.encode(tag)
    )
}

/// The token [text] carries if its MAC checks out (expiry not checked).
pub(crate) fn decode_token(secret: &[u8], text: &str) -> Option<Token> {
    if text.len() > 256 {
        return None;
    }
    let mut parts = text.split('.');
    if parts.next()? != "v1" {
        return None;
    }
    let account: [u8; 32] = BASE64_URL.decode(parts.next()?).ok()?.try_into().ok()?;
    let scope: u8 = parts.next()?.parse().ok()?;
    let quota: u64 = parts.next()?.parse().ok()?;
    let expiry_millis: u64 = parts.next()?.parse().ok()?;
    let tag: [u8; 32] = BASE64_URL.decode(parts.next()?).ok()?.try_into().ok()?;
    if parts.next().is_some() {
        return None;
    }
    let mut hmac = HmacSha256::new_from_slice(secret).ok()?;
    hmac.update(&account);
    hmac.update(&[scope]);
    hmac.update(&quota.to_be_bytes());
    hmac.update(&expiry_millis.to_be_bytes());
    // Constant time.
    hmac.verify_slice(&tag).ok()?;
    Some(Token {
        account,
        scope,
        quota,
        expiry_millis,
    })
}

/// Creates the registration tables (and the relay secret) if missing.
pub(crate) fn init_tables(database: &Connection) -> Result<Vec<u8>, String> {
    database
        .execute_batch(
            "CREATE TABLE IF NOT EXISTS relay_settings (
               name TEXT PRIMARY KEY,
               value BLOB NOT NULL
             );
             CREATE TABLE IF NOT EXISTS accounts (
               account_key BLOB PRIMARY KEY,
               created_millis INTEGER NOT NULL,
               quota_bytes INTEGER NOT NULL
             );
             CREATE TABLE IF NOT EXISTS invites (
               code TEXT PRIMARY KEY,
               uses_left INTEGER NOT NULL,
               expires_millis INTEGER,
               created_millis INTEGER NOT NULL
             );",
        )
        .map_err(|error| format!("initializing registration: {error}"))?;
    let secret: Option<Vec<u8>> = database
        .query_row(
            "SELECT value FROM relay_settings WHERE name = 'token_secret'",
            [],
            |row| row.get(0),
        )
        .optional()
        .map_err(|error| format!("reading the token secret: {error}"))?;
    if let Some(secret) = secret
        && secret.len() == 32
    {
        return Ok(secret);
    }
    use rand::RngCore;
    let mut secret = vec![0_u8; 32];
    rand::rngs::OsRng.fill_bytes(&mut secret);
    database
        .execute(
            "INSERT OR REPLACE INTO relay_settings (name, value) VALUES ('token_secret', ?1)",
            params![secret],
        )
        .map_err(|error| format!("storing the token secret: {error}"))?;
    Ok(secret)
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

/// Compares two byte strings in time that does not depend on where they
/// differ.
fn same(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    let mut difference = 0_u8;
    for (x, y) in a.iter().zip(b) {
        difference |= x ^ y;
    }
    difference == 0
}

impl RelayState {
    /// Loads accounts at startup.
    pub(crate) fn load_accounts(&self) -> Result<(), String> {
        // The accounts lock is held across the read and the replacement: a
        // registration that lands in between cannot be lost (it inserts into
        // the database first, and only then into the map).
        let mut accounts = self
            .accounts
            .lock()
            .expect("account lock should not poison");
        let database = self
            .database
            .lock()
            .expect("relay database lock should not poison");
        let mut statement = database
            .prepare("SELECT account_key, quota_bytes FROM accounts")
            .map_err(|error| format!("reading accounts: {error}"))?;
        let rows = statement
            .query_map([], |row| {
                Ok((row.get::<_, Vec<u8>>(0)?, row.get::<_, i64>(1)?))
            })
            .map_err(|error| format!("reading accounts: {error}"))?;
        let mut quotas = HashMap::new();
        for row in rows {
            let (key, quota) = row.map_err(|error| format!("reading an account: {error}"))?;
            if let Ok(key) = <[u8; 32]>::try_from(key) {
                quotas.insert(key, quota.max(0) as u64);
            }
        }
        // Replaced, not merged: a removed account is gone.
        accounts.quotas = quotas;
        accounts.loaded_millis = now_millis();
        Ok(())
    }

    /// Re-reads the accounts when they were read more than a few seconds
    /// ago, so the operator's removals and quotas apply without a restart.
    fn refresh_accounts_if_due(&self) {
        let due = {
            let accounts = self
                .accounts
                .lock()
                .expect("account lock should not poison");
            now_millis().saturating_sub(accounts.loaded_millis) >= ACCOUNTS_REFRESH_MILLIS
        };
        if due {
            let _ = self.load_accounts();
        }
    }

    /// What health tells clients about who may use the relay.
    pub(crate) fn policy_info(&self) -> Value {
        json!({
            "tier1": self.config.ext.tier1.name(),
            "registration": self.config.ext.registration.name(),
        })
    }

    /// A token in [text] that is valid now, for an account still there.
    pub(crate) fn valid_token(&self, text: &str) -> Option<Token> {
        let token = decode_token(&self.token_secret, text)?;
        if token.expiry_millis <= now_millis() {
            return None;
        }
        self.refresh_accounts_if_due();
        let accounts = self
            .accounts
            .lock()
            .expect("account lock should not poison");
        accounts
            .quotas
            .contains_key(&token.account)
            .then_some(token)
    }

    /// Whether a store of [bytes] may go in under tier 1's policy, with the
    /// request's [token] when one came.
    pub(crate) fn admit_store(&self, token: Option<&str>, bytes: u64) -> Result<(), String> {
        match self.config.ext.tier1 {
            Tier1Policy::Open => Ok(()),
            Tier1Policy::Off => Err("this relay takes no messages".to_owned()),
            Tier1Policy::Registered => {
                let token = token
                    .and_then(|text| self.valid_token(text))
                    .ok_or("this relay takes messages from registered accounts only")?;
                if token.scope & SCOPE_MESSAGES == 0 {
                    return Err("this token does not cover messages".to_owned());
                }
                self.allow_account_bytes(&token, bytes)
            }
        }
    }

    /// An account's store budget: its quota, in bytes a minute.
    fn allow_account_bytes(&self, token: &Token, bytes: u64) -> Result<(), String> {
        let minute = now_millis() / 60_000;
        let mut accounts = self
            .accounts
            .lock()
            .expect("account lock should not poison");
        let quota = accounts
            .quotas
            .get(&token.account)
            .copied()
            .unwrap_or(token.quota);
        if accounts.usage.len() >= self.config.max_rate_keys
            && !accounts.usage.contains_key(&token.account)
        {
            accounts
                .usage
                .retain(|_, (used_minute, _)| *used_minute == minute);
        }
        let used = accounts.usage.entry(token.account).or_insert((minute, 0));
        if used.0 != minute {
            *used = (minute, 0);
        }
        if used.1.saturating_add(bytes) > quota {
            return Err("account quota exceeded".to_owned());
        }
        used.1 = used.1.saturating_add(bytes);
        Ok(())
    }

    /// A session's `register`: checks the account key's signature (bound to
    /// [handshake_hash]) and the relay's policy, records the account, and
    /// returns a fresh token.
    pub(crate) fn register(
        &self,
        request: &Value,
        handshake_hash: &[u8],
        source: &str,
    ) -> Result<Value, String> {
        let account: [u8; 32] = request
            .get("account_key")
            .and_then(Value::as_str)
            .and_then(|text| BASE64_STANDARD.decode(text).ok())
            .and_then(|bytes| bytes.try_into().ok())
            .ok_or("register needs an account key")?;
        let signature = request
            .get("signature")
            .and_then(Value::as_str)
            .ok_or("register needs a signature")?;
        let mut message = Vec::with_capacity(REGISTER_LABEL.len() + handshake_hash.len() + 32);
        message.extend_from_slice(REGISTER_LABEL);
        message.extend_from_slice(handshake_hash);
        message.extend_from_slice(&account);
        if !verify(&account, &message, signature) {
            return Err("registration signature does not verify".to_owned());
        }
        let known = {
            let accounts = self
                .accounts
                .lock()
                .expect("account lock should not poison");
            accounts.quotas.get(&account).copied()
        };
        let quota = match known {
            // Registered already: a refresh.
            Some(quota) => quota,
            None => {
                // The address's allowance first: an invite is used up only
                // by a registration that goes through.
                self.count_registration(source)?;
                self.admit_registration(request)?;
                let quota = self.config.ext.account_quota_bytes;
                {
                    let database = self
                        .database
                        .lock()
                        .expect("relay database lock should not poison");
                    database
                        .execute(
                            "INSERT OR IGNORE INTO accounts
                               (account_key, created_millis, quota_bytes)
                             VALUES (?1, ?2, ?3)",
                            params![account.to_vec(), now_millis(), quota],
                        )
                        .map_err(|error| format!("recording an account: {error}"))?;
                }
                self.accounts
                    .lock()
                    .expect("account lock should not poison")
                    .quotas
                    .insert(account, quota);
                quota
            }
        };
        let scope = if self.config.ext.registration == RegistrationPolicy::Closed {
            SCOPE_MESSAGES
        } else {
            SCOPE_MESSAGES | SCOPE_EXTENDED
        };
        let token = Token {
            account,
            scope,
            quota,
            expiry_millis: now_millis() + self.config.ext.token_lifetime.as_millis() as u64,
        };
        Ok(json!({
            "ok": true,
            "stored": false,
            "messages": [],
            "error": null,
            "stats": null,
            "token": encode_token(&self.token_secret, &token),
            "expires": token.expiry_millis,
            "scope": scope,
            "quota": quota,
        }))
    }

    /// Whether a new account may register under the policy (an invite is
    /// used up here).
    fn admit_registration(&self, request: &Value) -> Result<(), String> {
        match self.config.ext.registration {
            RegistrationPolicy::Open => Ok(()),
            RegistrationPolicy::Closed => Err("registration is closed".to_owned()),
            RegistrationPolicy::Password => {
                let expected = self
                    .config
                    .ext
                    .registration_password
                    .as_deref()
                    .ok_or("registration is closed")?;
                let given = request
                    .get("password")
                    .and_then(Value::as_str)
                    .ok_or("registration needs the password")?;
                if same(given.as_bytes(), expected.as_bytes()) {
                    Ok(())
                } else {
                    Err("wrong registration password".to_owned())
                }
            }
            RegistrationPolicy::Invite => {
                let code = request
                    .get("invite")
                    .and_then(Value::as_str)
                    .filter(|code| !code.is_empty() && code.len() <= 64)
                    .ok_or("registration needs an invite code")?;
                let database = self
                    .database
                    .lock()
                    .expect("relay database lock should not poison");
                let used = database
                    .execute(
                        "UPDATE invites SET uses_left = uses_left - 1
                          WHERE code = ?1 AND uses_left > 0
                            AND (expires_millis IS NULL OR expires_millis > ?2)",
                        params![code, now_millis()],
                    )
                    .map_err(|error| format!("using an invite: {error}"))?;
                if used == 1 {
                    Ok(())
                } else {
                    Err("invite code is not valid".to_owned())
                }
            }
        }
    }

    fn count_registration(&self, source: &str) -> Result<(), String> {
        let day = now_millis() / DAY_MILLIS;
        let group = peer_group(source);
        let mut accounts = self
            .accounts
            .lock()
            .expect("account lock should not poison");
        accounts
            .registrations
            .retain(|_, (counted_day, _)| *counted_day == day);
        if accounts.registrations.len() >= self.config.max_rate_keys
            && !accounts.registrations.contains_key(&group)
        {
            return Err("registrations are used up for today".to_owned());
        }
        let counted = accounts.registrations.entry(group).or_insert((day, 0));
        if counted.1 >= REGISTRATIONS_PER_DAY {
            return Err("registrations from this address are used up for today".to_owned());
        }
        counted.1 += 1;
        Ok(())
    }
}

/// The operator's commands (`conest_relay admin ...`, also reached through
/// the supervisor): invites, accounts, quotas. They work on the database
/// directly, while the relay runs or not; a running relay sees new invites
/// at once and account changes at its next start.
pub(crate) fn admin(database_path: &std::path::Path, args: &[String]) -> Result<String, String> {
    let database = Connection::open(database_path)
        .map_err(|error| format!("opening {}: {error}", database_path.display()))?;
    database
        .busy_timeout(std::time::Duration::from_secs(5))
        .map_err(|error| format!("configuring the database: {error}"))?;
    init_tables(&database)?;
    let words: Vec<&str> = args.iter().map(String::as_str).collect();
    let option = |name: &str| -> Option<&str> {
        words
            .iter()
            .position(|word| *word == name)
            .and_then(|index| words.get(index + 1).copied())
    };
    match words.as_slice() {
        ["invite", "create", ..] => {
            let uses: i64 = option("--uses")
                .map(|value| value.parse().map_err(|_| "--uses needs a number"))
                .transpose()?
                .unwrap_or(1);
            if !(1..=1_000_000).contains(&uses) {
                return Err("--uses must be 1..1000000".to_owned());
            }
            let expires: Option<i64> = option("--expires-days")
                .map(|value| {
                    value
                        .parse::<u64>()
                        .map(|days| (now_millis() + days * DAY_MILLIS) as i64)
                        .map_err(|_| "--expires-days needs a number")
                })
                .transpose()?;
            use rand::RngCore;
            let mut bytes = [0_u8; 15];
            rand::rngs::OsRng.fill_bytes(&mut bytes);
            let code = BASE64_URL.encode(bytes);
            database
                .execute(
                    "INSERT INTO invites (code, uses_left, expires_millis, created_millis)
                     VALUES (?1, ?2, ?3, ?4)",
                    params![code, uses, expires, now_millis()],
                )
                .map_err(|error| format!("creating an invite: {error}"))?;
            Ok(code)
        }
        ["invite", "list"] => {
            let mut statement = database
                .prepare(
                    "SELECT code, uses_left, expires_millis FROM invites ORDER BY created_millis",
                )
                .map_err(|error| error.to_string())?;
            let rows = statement
                .query_map([], |row| {
                    Ok(format!(
                        "{} uses_left={} expires={}",
                        row.get::<_, String>(0)?,
                        row.get::<_, i64>(1)?,
                        row.get::<_, Option<i64>>(2)?
                            .map_or("never".to_owned(), |millis| millis.to_string())
                    ))
                })
                .map_err(|error| error.to_string())?;
            let lines: Result<Vec<String>, _> = rows.collect();
            Ok(lines.map_err(|error| error.to_string())?.join("\n"))
        }
        ["account", "list"] => {
            let mut statement = database
                .prepare("SELECT account_key, quota_bytes, created_millis FROM accounts ORDER BY created_millis")
                .map_err(|error| error.to_string())?;
            let rows = statement
                .query_map([], |row| {
                    Ok(format!(
                        "{} quota={}B/min created={}",
                        BASE64_STANDARD.encode(row.get::<_, Vec<u8>>(0)?),
                        row.get::<_, i64>(1)?,
                        row.get::<_, i64>(2)?
                    ))
                })
                .map_err(|error| error.to_string())?;
            let lines: Result<Vec<String>, _> = rows.collect();
            Ok(lines.map_err(|error| error.to_string())?.join("\n"))
        }
        ["account", "remove", key] => {
            let key = BASE64_STANDARD
                .decode(key)
                .map_err(|_| "the account key is base64")?;
            let removed = database
                .execute("DELETE FROM accounts WHERE account_key = ?1", params![key])
                .map_err(|error| error.to_string())?;
            Ok(format!("removed {removed} account(s)"))
        }
        ["quota", "set", key, bytes] => {
            let key = BASE64_STANDARD
                .decode(key)
                .map_err(|_| "the account key is base64")?;
            let bytes: i64 = bytes
                .parse()
                .map_err(|_| "the quota is a number of bytes")?;
            let changed = database
                .execute(
                    "UPDATE accounts SET quota_bytes = ?1 WHERE account_key = ?2",
                    params![bytes, key],
                )
                .map_err(|error| error.to_string())?;
            Ok(format!("updated {changed} account(s)"))
        }
        _ => Err(admin_usage()),
    }
}

pub(crate) fn admin_usage() -> String {
    "usage: conest_relay admin [--database-path PATH] <command>\n\
     \x20 invite create [--uses N] [--expires-days D]\n\
     \x20 invite list\n\
     \x20 account list\n\
     \x20 account remove ACCOUNT_KEY\n\
     \x20 quota set ACCOUNT_KEY BYTES_PER_MINUTE"
        .to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::parse_config_text;
    use crate::parity_tests::{parity_config, start_tokio};
    use crate::session::tests::{TestClient, relay_public};
    use crate::v1::handle_request_bytes;
    use ed25519_dalek::{Signer, SigningKey};

    fn state_with(configure: impl FnOnce(&mut crate::config::RelayConfig)) -> RelayState {
        let mut config = parity_config();
        configure(&mut config);
        RelayState::new(
            config,
            crate::identity::RelayIdentity::from_seed_bytes([7_u8; 32]),
        )
    }

    fn register_request(account: &SigningKey, hash: &[u8], extra: Value) -> Value {
        let public = account.verifying_key().to_bytes();
        let mut message = REGISTER_LABEL.to_vec();
        message.extend_from_slice(hash);
        message.extend_from_slice(&public);
        let mut request = json!({
            "action": "register",
            "account_key": BASE64_STANDARD.encode(public),
            "signature": BASE64_STANDARD.encode(account.sign(&message).to_bytes()),
        });
        if let (Some(target), Some(extra)) = (request.as_object_mut(), extra.as_object()) {
            for (name, value) in extra {
                target.insert(name.clone(), value.clone());
            }
        }
        request
    }

    fn store(state: &RelayState, token: Option<&str>) -> Value {
        let mut request = json!({
            "action": "store",
            "recipient_device_id": "dev-r",
            "envelope": {"kind": "direct_message", "messageId": format!("m{}", now_millis()), "senderDeviceId": "dev-a"},
        });
        if let Some(token) = token {
            request["token"] = json!(token);
        }
        let line = request.to_string();
        handle_request_bytes(line.as_bytes(), line.len(), state, "198.51.100.60")
    }

    #[test]
    fn tokens_verify_and_refuse_tampering_expiry_and_removed_accounts() {
        let secret = [5_u8; 32];
        let token = Token {
            account: [1_u8; 32],
            scope: SCOPE_MESSAGES,
            quota: 1000,
            expiry_millis: now_millis() + 60_000,
        };
        let text = encode_token(&secret, &token);
        assert_eq!(decode_token(&secret, &text), Some(token.clone()));
        assert_eq!(decode_token(&[6_u8; 32], &text), None, "another relay's");
        let raised = text.replacen(".1000.", ".9999999.", 1);
        assert_eq!(decode_token(&secret, &raised), None, "quota raised");
        let state = state_with(|_| {});
        let expired = encode_token(
            &state.token_secret,
            &Token {
                expiry_millis: now_millis() - 1,
                ..token.clone()
            },
        );
        state
            .accounts
            .lock()
            .expect("lock")
            .quotas
            .insert([1_u8; 32], 1000);
        assert!(state.valid_token(&expired).is_none(), "expired");
        let fresh = encode_token(&state.token_secret, &token);
        assert!(state.valid_token(&fresh).is_some());
        state.accounts.lock().expect("lock").quotas.clear();
        assert!(state.valid_token(&fresh).is_none(), "account removed");
    }

    #[test]
    fn registration_follows_each_policy() {
        let hash = [9_u8; 32];
        let account = SigningKey::from_bytes(&[1_u8; 32]);
        let other = SigningKey::from_bytes(&[2_u8; 32]);

        let closed = state_with(|_| {});
        assert_eq!(
            closed
                .register(
                    &register_request(&account, &hash, json!({})),
                    &hash,
                    "198.51.100.1"
                )
                .unwrap_err(),
            "registration is closed"
        );

        let open = state_with(|config| {
            config.ext.registration = RegistrationPolicy::Open;
        });
        let answer = open
            .register(
                &register_request(&account, &hash, json!({})),
                &hash,
                "198.51.100.1",
            )
            .expect("open registration");
        assert!(
            open.valid_token(answer["token"].as_str().expect("token"))
                .is_some()
        );
        // Signed for another session: refused.
        assert!(
            open.register(
                &register_request(&other, &[8_u8; 32], json!({})),
                &hash,
                "198.51.100.1"
            )
            .is_err()
        );

        let password = state_with(|config| {
            config.ext.registration = RegistrationPolicy::Password;
            config.ext.registration_password = Some("correct horse".to_owned());
        });
        assert_eq!(
            password
                .register(
                    &register_request(&account, &hash, json!({"password": "wrong horse!"})),
                    &hash,
                    "198.51.100.1"
                )
                .unwrap_err(),
            "wrong registration password"
        );
        assert!(
            password
                .register(
                    &register_request(&account, &hash, json!({"password": "correct horse"})),
                    &hash,
                    "198.51.100.1"
                )
                .is_ok()
        );
    }

    #[test]
    fn invites_are_used_up_and_a_registered_account_refreshes() {
        let path = std::env::temp_dir().join(format!(
            "conest-invites-{}-{}.sqlite3",
            std::process::id(),
            now_millis()
        ));
        let code = admin(
            &path,
            &[
                "invite".into(),
                "create".into(),
                "--uses".into(),
                "1".into(),
            ],
        )
        .expect("invite");
        let listed = admin(&path, &["invite".into(), "list".into()]).expect("list");
        assert!(
            listed.contains(&code) && listed.contains("uses_left=1"),
            "{listed}"
        );
        let state = state_with(|config| {
            config.database_path = path.clone();
            config.ext.registration = RegistrationPolicy::Invite;
        });
        let hash = [9_u8; 32];
        let account = SigningKey::from_bytes(&[1_u8; 32]);
        let other = SigningKey::from_bytes(&[2_u8; 32]);
        assert_eq!(
            state
                .register(
                    &register_request(&account, &hash, json!({})),
                    &hash,
                    "198.51.100.1"
                )
                .unwrap_err(),
            "registration needs an invite code"
        );
        state
            .register(
                &register_request(&account, &hash, json!({"invite": code})),
                &hash,
                "198.51.100.1",
            )
            .expect("first use");
        assert_eq!(
            state
                .register(
                    &register_request(&other, &hash, json!({"invite": code})),
                    &hash,
                    "198.51.100.1"
                )
                .unwrap_err(),
            "invite code is not valid"
        );
        // Registered already: a refresh needs no invite.
        let refreshed = state
            .register(
                &register_request(&account, &hash, json!({})),
                &hash,
                "198.51.100.1",
            )
            .expect("refresh");
        assert!(refreshed["token"].is_string());
        let accounts = admin(&path, &["account".into(), "list".into()]).expect("accounts");
        let key = BASE64_STANDARD.encode(account.verifying_key().to_bytes());
        assert!(accounts.contains(&key), "{accounts}");
        assert_eq!(
            admin(
                &path,
                &["quota".into(), "set".into(), key.clone(), "5".into()]
            )
            .expect("quota"),
            "updated 1 account(s)"
        );
        assert_eq!(
            admin(&path, &["account".into(), "remove".into(), key]).expect("remove"),
            "removed 1 account(s)"
        );
        // The running relay notices without a restart.
        let token = refreshed["token"].as_str().expect("token").to_owned();
        state.accounts.lock().unwrap().loaded_millis = 0;
        assert!(
            state.valid_token(&token).is_none(),
            "a removed account's token still works"
        );
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn tier1_policies_gate_stores_and_quotas_count_per_account() {
        let off = state_with(|config| config.ext.tier1 = Tier1Policy::Off);
        assert_eq!(store(&off, None)["error"], "this relay takes no messages");

        let registered = state_with(|config| {
            config.ext.tier1 = Tier1Policy::Registered;
            config.ext.registration = RegistrationPolicy::Open;
            config.ext.account_quota_bytes = 400;
        });
        assert_eq!(
            store(&registered, None)["error"],
            "this relay takes messages from registered accounts only"
        );
        let hash = [9_u8; 32];
        let account = SigningKey::from_bytes(&[3_u8; 32]);
        let answer = registered
            .register(
                &register_request(&account, &hash, json!({})),
                &hash,
                "198.51.100.1",
            )
            .expect("register");
        let token = answer["token"].as_str().expect("token").to_owned();
        // Over cleartext v1 a token is not honoured (anyone on the path
        // could lift it); the policy and quota are the session's.
        assert_eq!(
            store(&registered, Some(&token))["error"],
            "this relay takes messages from registered accounts only"
        );
        assert!(registered.admit_store(Some(&token), 250).is_ok());
        assert!(registered.admit_store(Some("v1.forged"), 1).is_err());
        // About 250 bytes a store: the second goes past 400 a minute.
        assert_eq!(
            registered.admit_store(Some(&token), 250),
            Err("account quota exceeded".to_owned())
        );
        // Open (the default): as before.
        let open = state_with(|_| {});
        assert_eq!(store(&open, None)["stored"], true);
    }

    #[test]
    fn a_registered_account_stores_inside_a_session() {
        let mut config = parity_config();
        config.ext.tier1 = Tier1Policy::Registered;
        config.ext.registration = RegistrationPolicy::Open;
        let relay = start_tokio(config);
        let mut client = TestClient::connect(relay.tcp, &relay_public(&relay.state));
        let account = SigningKey::from_bytes(&[4_u8; 32]);
        let hash = client.handshake_hash.clone();
        client.request(1, &register_request(&account, &hash, json!({})));
        let (_, answer) = client.next_json();
        let token = answer["token"].as_str().expect("token").to_owned();
        let envelope = json!({"kind": "direct_message", "messageId": "m-reg", "senderDeviceId": "dev-a"});
        client.request(
            3,
            &json!({"action": "store", "recipient_device_id": "dev-r", "envelope": envelope}),
        );
        let (_, refused) = client.next_json();
        assert_eq!(refused["ok"], false, "{refused}");
        client.request(
            5,
            &json!({"action": "store", "recipient_device_id": "dev-r", "envelope": envelope, "token": token}),
        );
        let (_, stored) = client.next_json();
        assert_eq!(stored["stored"], true, "{stored}");
    }

    #[test]
    fn an_invite_is_not_used_up_by_a_registration_the_address_may_not_make() {
        let path = std::env::temp_dir().join(format!(
            "conest-invite-burn-{}-{}.sqlite3",
            std::process::id(),
            now_millis()
        ));
        let code = admin(
            &path,
            &[
                "invite".into(),
                "create".into(),
                "--uses".into(),
                "40".into(),
            ],
        )
        .expect("invite");
        let state = state_with(|config| {
            config.database_path = path.clone();
            config.ext.registration = RegistrationPolicy::Invite;
        });
        let hash = [9_u8; 32];
        for seed in 0..REGISTRATIONS_PER_DAY as u8 {
            let account = SigningKey::from_bytes(&[seed + 10; 32]);
            state
                .register(
                    &register_request(&account, &hash, json!({"invite": code})),
                    &hash,
                    "198.51.100.1",
                )
                .expect("within the day's allowance");
        }
        let account = SigningKey::from_bytes(&[99_u8; 32]);
        let refused = state
            .register(
                &register_request(&account, &hash, json!({"invite": code})),
                &hash,
                "198.51.100.1",
            )
            .unwrap_err();
        assert!(refused.contains("used up for today"), "{refused}");
        let listed = admin(&path, &["invite".into(), "list".into()]).expect("list");
        assert!(listed.contains("uses_left=24"), "burned an invite: {listed}");
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn a_config_file_reads_as_flags() {
        let args = parse_config_text(
            "# a relay\nregistration = invite\ntier1 = registered\nlegacy-threads\nno-sessions = yes\nmax-total-bytes = 1000\n",
        )
        .expect("parse");
        assert_eq!(
            args,
            [
                "--registration",
                "invite",
                "--tier1",
                "registered",
                "--legacy-threads",
                "--no-sessions",
                "--max-total-bytes",
                "1000"
            ]
        );
        assert!(parse_config_text("Bad Name = 1").is_err());
        assert!(parse_config_text("config = other.conf").is_err());
    }

    #[test]
    fn a_session_registers_and_health_tells_the_policy() {
        let mut config = parity_config();
        config.ext.registration = RegistrationPolicy::Open;
        let relay = start_tokio(config);
        let mut client = TestClient::connect(relay.tcp, &relay_public(&relay.state));
        let account = SigningKey::from_bytes(&[4_u8; 32]);
        let hash = client.handshake_hash.clone();
        client.request(1, &register_request(&account, &hash, json!({})));
        let (_, answer) = client.next_json();
        assert_eq!(answer["ok"], true, "{answer}");
        assert!(
            relay
                .state
                .valid_token(answer["token"].as_str().expect("token"))
                .is_some()
        );
        client.request(3, &json!({"action": "health"}));
        let (_, health) = client.next_json();
        assert_eq!(health["stats"]["v2"]["policy"]["registration"], "open");
        assert_eq!(health["stats"]["v2"]["policy"]["tier1"], "open");
    }
}
