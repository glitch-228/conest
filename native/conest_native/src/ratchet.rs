//! Stateless Olm (vodozemac) operations for Conest's forward-secret sessions.
//!
//! Every call takes the encrypted account/session pickles it needs and returns
//! the updated pickles alongside its result. Dart owns persistence, so a
//! ratchet step is committed only when Dart durably stores the returned
//! pickle before sending, and a failed decrypt never mutates stored state.
//! Keys travel as vodozemac's unpadded base64; payloads as standard base64.

use anyhow::{Context, Result, anyhow, ensure};
use base64::{Engine as _, engine::general_purpose::STANDARD as BASE64};
use serde_json::{Value, json};
use vodozemac::{
    Curve25519PublicKey,
    olm::{Account, AccountPickle, OlmMessage, Session, SessionConfig, SessionPickle},
};

/// Upper bound on one plaintext: the app's 2 MiB envelope ciphertext cap
/// minus room for Olm framing. Larger content uses per-transfer keys.
const MAX_PLAINTEXT_BYTES: usize = 2 * 1024 * 1024 - 64 * 1024;

pub fn call(request: &Value) -> Result<Value> {
    let op = string(request, "op")?;
    let pickle_key = pickle_key(request)?;
    match op {
        "account_new" => {
            let account = Account::new();
            Ok(json!({
                "account": account.pickle().encrypt(&pickle_key),
                "identityKey": account.curve25519_key().to_base64(),
            }))
        }
        "bundle" => {
            let mut account = load_account(request, &pickle_key)?;
            if account.fallback_key().is_empty() {
                account.generate_fallback_key();
            }
            let fallback_key = current_fallback_key(&account)?;
            let one_time_key = if request["oneTimeKey"].as_bool() == Some(true) {
                let generated = account.generate_one_time_keys(1);
                Some(
                    generated
                        .created
                        .first()
                        .copied()
                        .ok_or_else(|| anyhow!("no one-time key was generated"))?
                        .to_base64(),
                )
            } else {
                None
            };
            Ok(json!({
                "account": account.pickle().encrypt(&pickle_key),
                "identityKey": account.curve25519_key().to_base64(),
                "fallbackKey": fallback_key,
                "oneTimeKey": one_time_key,
            }))
        }
        "rotate_fallback" => {
            let mut account = load_account(request, &pickle_key)?;
            account.generate_fallback_key();
            let fallback_key = current_fallback_key(&account)?;
            Ok(json!({
                "account": account.pickle().encrypt(&pickle_key),
                "fallbackKey": fallback_key,
            }))
        }
        "outbound" => {
            let account = load_account(request, &pickle_key)?;
            let identity = public_key(request, "peerIdentityKey")?;
            let one_time = public_key(request, "peerOneTimeKey")?;
            let session =
                account.create_outbound_session(SessionConfig::version_1(), identity, one_time)?;
            Ok(json!({
                "session": session.pickle().encrypt(&pickle_key),
                "sessionId": session.session_id(),
            }))
        }
        "encrypt" => {
            let mut session = load_session(request, &pickle_key)?;
            let plaintext = bytes(request, "plaintext")?;
            ensure!(
                plaintext.len() <= MAX_PLAINTEXT_BYTES,
                "ratchet plaintext is too large"
            );
            let (message_type, ciphertext) = session.encrypt(&plaintext)?.to_parts();
            Ok(json!({
                "session": session.pickle().encrypt(&pickle_key),
                "sessionId": session.session_id(),
                "messageType": message_type,
                "ciphertext": BASE64.encode(ciphertext),
            }))
        }
        "decrypt" => {
            let mut session = load_session(request, &pickle_key)?;
            let message = message(request)?;
            let plaintext = session.decrypt(&message)?;
            Ok(json!({
                "session": session.pickle().encrypt(&pickle_key),
                "sessionId": session.session_id(),
                "plaintext": BASE64.encode(plaintext),
            }))
        }
        "inbound" => {
            let mut account = load_account(request, &pickle_key)?;
            let identity = public_key(request, "peerIdentityKey")?;
            let OlmMessage::PreKey(pre_key) = message(request)? else {
                return Err(anyhow!("only a pre-key message can open a session"));
            };
            let created =
                account.create_inbound_session(SessionConfig::version_1(), identity, &pre_key)?;
            Ok(json!({
                "account": account.pickle().encrypt(&pickle_key),
                "session": created.session.pickle().encrypt(&pickle_key),
                "sessionId": created.session.session_id(),
                "plaintext": BASE64.encode(created.plaintext),
            }))
        }
        other => Err(anyhow!("unknown ratchet operation {other}")),
    }
}

fn string<'a>(request: &'a Value, field: &str) -> Result<&'a str> {
    request[field]
        .as_str()
        .with_context(|| format!("missing ratchet field {field}"))
}

fn bytes(request: &Value, field: &str) -> Result<Vec<u8>> {
    BASE64
        .decode(string(request, field)?)
        .with_context(|| format!("invalid base64 in ratchet field {field}"))
}

fn pickle_key(request: &Value) -> Result<[u8; 32]> {
    bytes(request, "pickleKey")?
        .try_into()
        .map_err(|_| anyhow!("ratchet pickle key must be 32 bytes"))
}

fn public_key(request: &Value, field: &str) -> Result<Curve25519PublicKey> {
    Curve25519PublicKey::from_base64(string(request, field)?)
        .with_context(|| format!("invalid Curve25519 key in {field}"))
}

fn load_account(request: &Value, pickle_key: &[u8; 32]) -> Result<Account> {
    let pickle = AccountPickle::from_encrypted(string(request, "account")?, pickle_key)
        .context("cannot open the ratchet account")?;
    Ok(Account::from_pickle(pickle))
}

fn load_session(request: &Value, pickle_key: &[u8; 32]) -> Result<Session> {
    let pickle = SessionPickle::from_encrypted(string(request, "session")?, pickle_key)
        .context("cannot open the ratchet session")?;
    Ok(Session::from_pickle(pickle))
}

fn message(request: &Value) -> Result<OlmMessage> {
    let message_type = request["messageType"]
        .as_u64()
        .context("missing ratchet field messageType")?;
    let ciphertext = bytes(request, "ciphertext")?;
    Ok(OlmMessage::from_parts(message_type as usize, &ciphertext)?)
}

fn current_fallback_key(account: &Account) -> Result<String> {
    account
        .fallback_key()
        .values()
        .next()
        .map(Curve25519PublicKey::to_base64)
        .ok_or_else(|| anyhow!("the ratchet account has no fallback key"))
}

#[cfg(test)]
mod tests {
    use super::call;
    use base64::{Engine as _, engine::general_purpose::STANDARD as BASE64};
    use serde_json::{Value, json};

    const KEY_A: [u8; 32] = [7; 32];
    const KEY_B: [u8; 32] = [9; 32];

    fn run(mut request: Value, key: [u8; 32]) -> Value {
        request["pickleKey"] = json!(BASE64.encode(key));
        call(&request).expect("ratchet call succeeds")
    }

    fn try_run(mut request: Value, key: [u8; 32]) -> anyhow::Result<Value> {
        request["pickleKey"] = json!(BASE64.encode(key));
        call(&request)
    }

    fn text(value: &Value) -> String {
        String::from_utf8(BASE64.decode(value["plaintext"].as_str().unwrap()).unwrap()).unwrap()
    }

    struct Pair {
        alice_session: String,
        bob_account: String,
        bob_identity: String,
        alice_identity: String,
    }

    fn pair(one_time_key: bool) -> Pair {
        let alice = run(json!({"op": "account_new"}), KEY_A);
        let bob = run(json!({"op": "account_new"}), KEY_B);
        let bundle = run(
            json!({"op": "bundle", "account": bob["account"], "oneTimeKey": one_time_key}),
            KEY_B,
        );
        let peer_key = if one_time_key {
            bundle["oneTimeKey"].clone()
        } else {
            bundle["fallbackKey"].clone()
        };
        let outbound = run(
            json!({
                "op": "outbound",
                "account": alice["account"],
                "peerIdentityKey": bundle["identityKey"],
                "peerOneTimeKey": peer_key,
            }),
            KEY_A,
        );
        Pair {
            alice_session: outbound["session"].as_str().unwrap().to_owned(),
            bob_account: bundle["account"].as_str().unwrap().to_owned(),
            bob_identity: bundle["identityKey"].as_str().unwrap().to_owned(),
            alice_identity: alice["identityKey"].as_str().unwrap().to_owned(),
        }
    }

    fn encrypt(session: &str, key: [u8; 32], plaintext: &str) -> Value {
        run(
            json!({"op": "encrypt", "session": session, "plaintext": BASE64.encode(plaintext)}),
            key,
        )
    }

    fn decrypt(session: &str, key: [u8; 32], message: &Value) -> anyhow::Result<Value> {
        try_run(
            json!({
                "op": "decrypt",
                "session": session,
                "messageType": message["messageType"],
                "ciphertext": message["ciphertext"],
            }),
            key,
        )
    }

    /// Opens Bob's inbound session from Alice's first message.
    fn accept(pair: &Pair, first: &Value) -> Value {
        run(
            json!({
                "op": "inbound",
                "account": pair.bob_account,
                "peerIdentityKey": pair.alice_identity,
                "messageType": first["messageType"],
                "ciphertext": first["ciphertext"],
            }),
            KEY_B,
        )
    }

    #[test]
    fn one_time_and_fallback_keys_both_open_sessions_and_reply() {
        for one_time_key in [true, false] {
            let pair = pair(one_time_key);
            let first = encrypt(&pair.alice_session, KEY_A, "hello bob");
            assert_eq!(
                first["messageType"], 0,
                "first message is a pre-key message"
            );
            let inbound = accept(&pair, &first);
            assert_eq!(text(&inbound), "hello bob");
            let bob_session = inbound["session"].as_str().unwrap();
            let reply = encrypt(bob_session, KEY_B, "hi alice");
            assert_eq!(reply["messageType"], 1);
            let opened = decrypt(first["session"].as_str().unwrap(), KEY_A, &reply).unwrap();
            assert_eq!(text(&opened), "hi alice");
            assert_eq!(opened["sessionId"], inbound["sessionId"]);
        }
    }

    #[test]
    fn bundle_reports_a_stable_fallback_until_rotation() {
        let bob = run(json!({"op": "account_new"}), KEY_B);
        let first = run(json!({"op": "bundle", "account": bob["account"]}), KEY_B);
        let second = run(json!({"op": "bundle", "account": first["account"]}), KEY_B);
        assert_eq!(first["fallbackKey"], second["fallbackKey"]);
        assert!(second["oneTimeKey"].is_null());
        let rotated = run(
            json!({"op": "rotate_fallback", "account": second["account"]}),
            KEY_B,
        );
        assert_ne!(rotated["fallbackKey"], second["fallbackKey"]);
    }

    #[test]
    fn previous_fallback_still_opens_a_session_after_one_rotation() {
        let pair = pair(false);
        let rotated = run(
            json!({"op": "rotate_fallback", "account": pair.bob_account}),
            KEY_B,
        );
        let first = encrypt(&pair.alice_session, KEY_A, "slow first message");
        let inbound = run(
            json!({
                "op": "inbound",
                "account": rotated["account"],
                "peerIdentityKey": pair.alice_identity,
                "messageType": first["messageType"],
                "ciphertext": first["ciphertext"],
            }),
            KEY_B,
        );
        assert_eq!(text(&inbound), "slow first message");
    }

    #[test]
    fn out_of_order_delivery_within_the_window_decrypts() {
        let pair = pair(true);
        let first = encrypt(&pair.alice_session, KEY_A, "m0");
        let inbound = accept(&pair, &first);
        let mut bob = inbound["session"].as_str().unwrap().to_owned();
        let reply = encrypt(&bob, KEY_B, "ack");
        bob = reply["session"].as_str().unwrap().to_owned();
        let mut alice =
            decrypt(first["session"].as_str().unwrap(), KEY_A, &reply).unwrap()["session"]
                .as_str()
                .unwrap()
                .to_owned();
        let mut sent = Vec::new();
        for index in 1..=30 {
            let message = encrypt(&alice, KEY_A, &format!("m{index}"));
            alice = message["session"].as_str().unwrap().to_owned();
            sent.push(message);
        }
        for (position, message) in sent.iter().enumerate().rev() {
            let opened = decrypt(&bob, KEY_B, message).unwrap();
            assert_eq!(text(&opened), format!("m{}", position + 1));
            bob = opened["session"].as_str().unwrap().to_owned();
        }
    }

    #[test]
    fn duplicate_and_tampered_messages_fail_without_changing_stored_state() {
        let pair = pair(true);
        let first = encrypt(&pair.alice_session, KEY_A, "once");
        let inbound = accept(&pair, &first);
        let bob = inbound["session"].as_str().unwrap();
        let reply = encrypt(bob, KEY_B, "reply");
        let alice = decrypt(first["session"].as_str().unwrap(), KEY_A, &reply).unwrap();
        let alice = alice["session"].as_str().unwrap();
        let message = encrypt(alice, KEY_A, "normal");
        let opened = decrypt(reply["session"].as_str().unwrap(), KEY_B, &message).unwrap();
        // The consumed message key is gone: a replay fails.
        assert!(decrypt(opened["session"].as_str().unwrap(), KEY_B, &message).is_err());
        let mut tampered = message.clone();
        let mut bytes = BASE64
            .decode(message["ciphertext"].as_str().unwrap())
            .unwrap();
        let last = bytes.len() - 1;
        bytes[last] ^= 1;
        tampered["ciphertext"] = json!(BASE64.encode(bytes));
        assert!(decrypt(reply["session"].as_str().unwrap(), KEY_B, &tampered).is_err());
        // The pre-failure pickle is still usable for the genuine message.
        assert_eq!(
            text(&decrypt(reply["session"].as_str().unwrap(), KEY_B, &message).unwrap()),
            "normal"
        );
    }

    #[test]
    fn wrong_pickle_key_and_unknown_operations_are_rejected() {
        let pair = pair(true);
        assert!(
            try_run(
                json!({"op": "encrypt", "session": pair.alice_session, "plaintext": ""}),
                KEY_B,
            )
            .is_err()
        );
        assert!(try_run(json!({"op": "nope"}), KEY_A).is_err());
        let first = encrypt(&pair.alice_session, KEY_A, "x");
        let reply_shaped = json!({"messageType": 1, "ciphertext": first["ciphertext"]});
        assert!(
            try_run(
                json!({
                    "op": "inbound",
                    "account": pair.bob_account,
                    "peerIdentityKey": pair.bob_identity,
                    "messageType": reply_shaped["messageType"],
                    "ciphertext": reply_shaped["ciphertext"],
                }),
                KEY_B,
            )
            .is_err()
        );
    }

    #[test]
    fn simultaneous_starts_leave_two_working_sessions() {
        let alice = run(json!({"op": "account_new"}), KEY_A);
        let bob = run(json!({"op": "account_new"}), KEY_B);
        let alice_bundle = run(
            json!({"op": "bundle", "account": alice["account"], "oneTimeKey": true}),
            KEY_A,
        );
        let bob_bundle = run(
            json!({"op": "bundle", "account": bob["account"], "oneTimeKey": true}),
            KEY_B,
        );
        let alice_out = run(
            json!({
                "op": "outbound",
                "account": alice_bundle["account"],
                "peerIdentityKey": bob_bundle["identityKey"],
                "peerOneTimeKey": bob_bundle["oneTimeKey"],
            }),
            KEY_A,
        );
        let bob_out = run(
            json!({
                "op": "outbound",
                "account": bob_bundle["account"],
                "peerIdentityKey": alice_bundle["identityKey"],
                "peerOneTimeKey": alice_bundle["oneTimeKey"],
            }),
            KEY_B,
        );
        let from_alice = encrypt(alice_out["session"].as_str().unwrap(), KEY_A, "a");
        let from_bob = encrypt(bob_out["session"].as_str().unwrap(), KEY_B, "b");
        let bob_in = run(
            json!({
                "op": "inbound",
                "account": bob_bundle["account"],
                "peerIdentityKey": alice_bundle["identityKey"],
                "messageType": from_alice["messageType"],
                "ciphertext": from_alice["ciphertext"],
            }),
            KEY_B,
        );
        let alice_in = run(
            json!({
                "op": "inbound",
                "account": alice_bundle["account"],
                "peerIdentityKey": bob_bundle["identityKey"],
                "messageType": from_bob["messageType"],
                "ciphertext": from_bob["ciphertext"],
            }),
            KEY_A,
        );
        assert_eq!(text(&bob_in), "a");
        assert_eq!(text(&alice_in), "b");
        assert_ne!(bob_in["sessionId"], alice_in["sessionId"]);
        // Each side can keep talking on the session the other opened.
        let more = encrypt(alice_in["session"].as_str().unwrap(), KEY_A, "c");
        let opened = decrypt(from_bob["session"].as_str().unwrap(), KEY_B, &more).unwrap();
        assert_eq!(text(&opened), "c");
    }
}
