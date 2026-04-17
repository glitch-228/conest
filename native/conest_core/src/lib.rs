use std::time::{Duration, SystemTime, UNIX_EPOCH};

use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use chacha20poly1305::aead::rand_core::RngCore;
use chacha20poly1305::aead::{Aead, KeyInit};
use chacha20poly1305::{ChaCha20Poly1305, Key, Nonce};
use ed25519_dalek::{SigningKey, VerifyingKey};
use hkdf::Hkdf;
use rand::rngs::OsRng;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use x25519_dalek::{PublicKey as X25519PublicKey, StaticSecret};

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct AccountId(pub String);

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct DeviceId(pub String);

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct ConversationId(pub String);

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub enum ConversationKind {
    Direct,
    Group,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub enum DeliveryState {
    Pending,
    Local,
    Relayed,
    Delivered,
    Failed,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub enum RouteKind {
    Lan,
    Relay,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub enum RouteProtocol {
    Tcp,
    Udp,
}

fn default_route_protocol() -> RouteProtocol {
    RouteProtocol::Tcp
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct PeerRoute {
    pub kind: RouteKind,
    pub host: String,
    pub port: u16,
    #[serde(default = "default_route_protocol")]
    pub protocol: RouteProtocol,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub enum EnvelopeKind {
    DirectMessage,
    Ack,
    KeyUpdate,
    MembershipUpdate,
    RelayStore,
    RelayFetch,
    AttachmentReserved,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct LocalIdentity {
    pub account_id: AccountId,
    pub device_id: DeviceId,
    pub display_name: String,
    pub signing_public_key_b64: String,
    pub signing_secret_key_b64: String,
    pub exchange_public_key_b64: String,
    pub exchange_secret_key_b64: String,
    pub internet_relay_hint: Option<PeerRoute>,
    pub local_relay_port: u16,
    pub relay_mode_enabled: bool,
    pub lan_addresses: Vec<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ContactInvite {
    pub version: u8,
    pub account_id: AccountId,
    pub device_id: DeviceId,
    pub display_name: String,
    pub signing_public_key_b64: String,
    pub exchange_public_key_b64: String,
    pub route_hints: Vec<PeerRoute>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ContactProfile {
    pub alias: String,
    pub account_id: AccountId,
    pub device_id: DeviceId,
    pub display_name: String,
    pub signing_public_key_b64: String,
    pub exchange_public_key_b64: String,
    pub route_hints: Vec<PeerRoute>,
    pub safety_number: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct MessageEnvelope {
    pub message_id: String,
    pub conversation_id: ConversationId,
    pub kind: EnvelopeKind,
    pub sender_account_id: AccountId,
    pub sender_device_id: DeviceId,
    pub recipient_device_id: DeviceId,
    pub nonce_b64: Option<String>,
    pub ciphertext_b64: Option<String>,
    pub created_at_millis: u64,
    pub acknowledged_message_id: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct BootstrapResult {
    pub identity: LocalIdentity,
    pub invite: ContactInvite,
    pub safety_number: String,
}

pub struct IdentityApi;
pub struct ContactsApi;
pub struct ChatApi;
pub struct NetworkApi;
pub struct RelayApi;

impl IdentityApi {
    pub fn bootstrap_device(
        display_name: &str,
        internet_relay_hint: Option<PeerRoute>,
        local_relay_port: u16,
        lan_addresses: Vec<String>,
    ) -> BootstrapResult {
        let signing_key = SigningKey::generate(&mut OsRng);
        let verifying_key: VerifyingKey = signing_key.verifying_key();

        let exchange_secret = StaticSecret::random_from_rng(OsRng);
        let exchange_public = X25519PublicKey::from(&exchange_secret);

        let account_id = AccountId(random_id("acc"));
        let device_id = DeviceId(random_id("dev"));

        let identity = LocalIdentity {
            account_id: account_id.clone(),
            device_id: device_id.clone(),
            display_name: display_name.to_owned(),
            signing_public_key_b64: URL_SAFE_NO_PAD.encode(verifying_key.as_bytes()),
            signing_secret_key_b64: URL_SAFE_NO_PAD.encode(signing_key.to_bytes()),
            exchange_public_key_b64: URL_SAFE_NO_PAD.encode(exchange_public.as_bytes()),
            exchange_secret_key_b64: URL_SAFE_NO_PAD.encode(exchange_secret.to_bytes()),
            internet_relay_hint,
            local_relay_port,
            relay_mode_enabled: true,
            lan_addresses,
        };

        let invite = ContactInvite {
            version: 2,
            account_id,
            device_id,
            display_name: display_name.to_owned(),
            signing_public_key_b64: identity.signing_public_key_b64.clone(),
            exchange_public_key_b64: identity.exchange_public_key_b64.clone(),
            route_hints: identity.advertised_route_hints(),
        };

        let safety_number = safety_number_for_public_keys(&[
            decode_b64(&identity.signing_public_key_b64).expect("signing key encoding is valid"),
            decode_b64(&identity.exchange_public_key_b64).expect("exchange key encoding is valid"),
        ]);

        BootstrapResult {
            identity,
            invite,
            safety_number,
        }
    }

    pub fn current_pairing_code_for_payload(payload: &str, current_millis: Option<u64>) -> String {
        let slot = pairing_slot(current_millis.unwrap_or_else(now_millis));
        derive_codephrase(&format!("{payload}:{slot}"))
    }

    pub fn matches_pairing_code_for_payload(
        payload: &str,
        codephrase: &str,
        current_millis: Option<u64>,
    ) -> bool {
        let slot = pairing_slot(current_millis.unwrap_or_else(now_millis)) as i64;
        let candidate = normalize_codephrase(codephrase);
        if candidate.is_empty() {
            return false;
        }
        (-1..=1).any(|offset| {
            normalize_codephrase(&derive_codephrase(&format!("{payload}:{}", slot + offset)))
                == candidate
        })
    }
}

impl ContactsApi {
    pub fn import_invite(
        alias: &str,
        payload: &str,
        codephrase: &str,
    ) -> Result<ContactProfile, String> {
        if !IdentityApi::matches_pairing_code_for_payload(payload, codephrase, None) {
            return Err(
                "Codephrase mismatch. It rotates every 30 seconds, so compare it again and retry."
                    .to_owned(),
            );
        }
        let invite = decode_invite(payload)?;
        Ok(ContactProfile {
            alias: alias.to_owned(),
            account_id: invite.account_id.clone(),
            device_id: invite.device_id.clone(),
            display_name: invite.display_name.clone(),
            signing_public_key_b64: invite.signing_public_key_b64.clone(),
            exchange_public_key_b64: invite.exchange_public_key_b64.clone(),
            route_hints: NetworkApi::select_routes(&invite.route_hints),
            safety_number: safety_number_for_public_keys(&[
                decode_b64(&invite.signing_public_key_b64)?,
                decode_b64(&invite.exchange_public_key_b64)?,
            ]),
        })
    }
}

impl ChatApi {
    pub fn encrypt_direct_message(
        local: &LocalIdentity,
        remote: &ContactProfile,
        conversation_id: ConversationId,
        body: &str,
    ) -> Result<MessageEnvelope, String> {
        let ciphertext = encrypt_payload(
            local,
            &remote.exchange_public_key_b64,
            &conversation_id,
            body,
        )?;
        Ok(MessageEnvelope {
            message_id: random_id("msg"),
            conversation_id,
            kind: EnvelopeKind::DirectMessage,
            sender_account_id: local.account_id.clone(),
            sender_device_id: local.device_id.clone(),
            recipient_device_id: remote.device_id.clone(),
            nonce_b64: Some(ciphertext.0),
            ciphertext_b64: Some(ciphertext.1),
            created_at_millis: now_millis(),
            acknowledged_message_id: None,
        })
    }

    pub fn decrypt_direct_message(
        local: &LocalIdentity,
        remote: &ContactProfile,
        envelope: &MessageEnvelope,
    ) -> Result<String, String> {
        let nonce_b64 = envelope
            .nonce_b64
            .clone()
            .ok_or_else(|| "Missing nonce.".to_owned())?;
        let ciphertext_b64 = envelope
            .ciphertext_b64
            .clone()
            .ok_or_else(|| "Missing ciphertext.".to_owned())?;
        let key = derive_session_key(
            &local.exchange_secret_key_b64,
            &remote.exchange_public_key_b64,
            &envelope.conversation_id,
        )?;
        let cipher = ChaCha20Poly1305::new(Key::from_slice(&key));
        let nonce_bytes = decode_b64(&nonce_b64)?;
        let ciphertext = decode_b64(&ciphertext_b64)?;
        let plaintext = cipher
            .decrypt(Nonce::from_slice(&nonce_bytes), ciphertext.as_ref())
            .map_err(|_| "Unable to decrypt envelope.".to_owned())?;
        String::from_utf8(plaintext).map_err(|_| "Envelope payload was not valid UTF-8.".to_owned())
    }
}

impl NetworkApi {
    pub fn select_routes(route_hints: &[PeerRoute]) -> Vec<PeerRoute> {
        let mut routes = Vec::new();
        let mut seen = std::collections::BTreeSet::new();
        for route in route_hints
            .iter()
            .filter(|route| matches!(route.kind, RouteKind::Lan))
            .chain(
                route_hints
                    .iter()
                    .filter(|route| matches!(route.kind, RouteKind::Relay)),
            )
        {
            let key = format!(
                "{:?}:{:?}:{}:{}",
                route.kind, route.protocol, route.host, route.port
            );
            if seen.insert(key) {
                routes.push(route.clone());
            }
        }
        routes
    }
}

impl RelayApi {
    pub fn default_queue_ttl() -> Duration {
        Duration::from_secs(7 * 24 * 60 * 60)
    }
}

pub fn encode_invite(invite: &ContactInvite) -> Result<String, String> {
    let json = serde_json::to_vec(invite).map_err(|error| error.to_string())?;
    Ok(URL_SAFE_NO_PAD.encode(json))
}

pub fn decode_invite(payload: &str) -> Result<ContactInvite, String> {
    let bytes = decode_b64(payload)?;
    serde_json::from_slice(&bytes).map_err(|error| error.to_string())
}

fn encrypt_payload(
    local: &LocalIdentity,
    remote_exchange_public_key_b64: &str,
    conversation_id: &ConversationId,
    body: &str,
) -> Result<(String, String), String> {
    let key = derive_session_key(
        &local.exchange_secret_key_b64,
        remote_exchange_public_key_b64,
        conversation_id,
    )?;
    let cipher = ChaCha20Poly1305::new(Key::from_slice(&key));
    let mut nonce = [0u8; 12];
    OsRng.fill_bytes(&mut nonce);
    let ciphertext = cipher
        .encrypt(Nonce::from_slice(&nonce), body.as_bytes())
        .map_err(|_| "Unable to encrypt direct message.".to_owned())?;
    Ok((
        URL_SAFE_NO_PAD.encode(nonce),
        URL_SAFE_NO_PAD.encode(ciphertext),
    ))
}

fn derive_session_key(
    local_exchange_secret_key_b64: &str,
    remote_exchange_public_key_b64: &str,
    conversation_id: &ConversationId,
) -> Result<[u8; 32], String> {
    let local_secret_bytes: [u8; 32] = decode_b64(local_exchange_secret_key_b64)?
        .try_into()
        .map_err(|_| "Local exchange secret must be 32 bytes.".to_owned())?;
    let remote_public_bytes: [u8; 32] = decode_b64(remote_exchange_public_key_b64)?
        .try_into()
        .map_err(|_| "Remote exchange public key must be 32 bytes.".to_owned())?;

    let local_secret = StaticSecret::from(local_secret_bytes);
    let remote_public = X25519PublicKey::from(remote_public_bytes);
    let shared_secret = local_secret.diffie_hellman(&remote_public);

    let hkdf = Hkdf::<Sha256>::new(Some(conversation_id.0.as_bytes()), shared_secret.as_bytes());
    let mut output = [0u8; 32];
    hkdf.expand(b"conest.direct.v1", &mut output)
        .map_err(|_| "Unable to derive conversation key.".to_owned())?;
    Ok(output)
}

fn safety_number_for_public_keys(values: &[Vec<u8>]) -> String {
    let mut encoded: Vec<String> = values.iter().map(hex::encode).collect();
    encoded.sort();
    let digest = Sha256::digest(encoded.join(":").as_bytes());
    let compact = hex::encode(&digest[..18]);
    compact
        .as_bytes()
        .chunks(4)
        .map(|chunk| String::from_utf8_lossy(chunk).to_string())
        .collect::<Vec<_>>()
        .join(" ")
}

fn decode_b64(value: &str) -> Result<Vec<u8>, String> {
    URL_SAFE_NO_PAD
        .decode(value)
        .map_err(|error| error.to_string())
}

fn random_id(prefix: &str) -> String {
    let mut bytes = [0u8; 10];
    OsRng.fill_bytes(&mut bytes);
    format!("{prefix}-{}", hex::encode(bytes))
}

fn now_millis() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}

impl LocalIdentity {
    pub fn advertised_route_hints(&self) -> Vec<PeerRoute> {
        let mut routes = Vec::new();
        if self.relay_mode_enabled {
            for address in &self.lan_addresses {
                routes.push(PeerRoute {
                    kind: RouteKind::Lan,
                    host: address.clone(),
                    port: self.local_relay_port,
                    protocol: RouteProtocol::Tcp,
                });
                routes.push(PeerRoute {
                    kind: RouteKind::Lan,
                    host: address.clone(),
                    port: self.local_relay_port,
                    protocol: RouteProtocol::Udp,
                });
            }
        }
        if let Some(route) = &self.internet_relay_hint {
            routes.push(route.clone());
        }
        NetworkApi::select_routes(&routes)
    }
}

fn derive_codephrase(seed: &str) -> String {
    const WORDS: &[&str] = &[
        "amber", "anchor", "birch", "cedar", "cipher", "comet", "ember", "fable", "harbor",
        "ivory", "linen", "lumen", "meadow", "morrow", "north", "orbit", "pepper", "quartz",
        "raven", "signal", "spruce", "sundial", "tidal", "vector", "velvet", "willow", "winter",
        "yonder",
    ];
    let mut accumulator: u32 = 0x811C_9DC5;
    for byte in seed.bytes() {
        accumulator ^= u32::from(byte);
        accumulator = accumulator.wrapping_mul(16_777_619);
    }
    let mut segments = Vec::new();
    for index in 0..3 {
        let shift = index * 5;
        let word = WORDS[((accumulator >> shift) as usize) % WORDS.len()];
        let number = ((accumulator >> (index * 7)) & 0xFF) + 11;
        segments.push(format!("{word}-{number:03}"));
    }
    segments.join("-")
}

fn pairing_slot(timestamp_millis: u64) -> u64 {
    timestamp_millis / 30_000
}

fn normalize_codephrase(value: &str) -> String {
    value
        .trim()
        .to_ascii_lowercase()
        .chars()
        .filter(|character| !character.is_whitespace())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn invite_round_trip_preserves_route_hints() {
        let bootstrap = IdentityApi::bootstrap_device(
            "Alice",
            Some(PeerRoute {
                kind: RouteKind::Relay,
                host: "relay.example".to_owned(),
                port: 7667,
                protocol: RouteProtocol::Tcp,
            }),
            7667,
            vec!["192.168.1.25".to_owned()],
        );
        let payload = encode_invite(&bootstrap.invite).expect("invite should encode");
        let decoded = decode_invite(&payload).expect("invite should decode");
        assert_eq!(decoded.device_id, bootstrap.invite.device_id);
        assert_eq!(decoded.route_hints, bootstrap.invite.route_hints);
        assert_eq!(decoded.route_hints[0].kind, RouteKind::Lan);
        assert_eq!(decoded.route_hints[0].protocol, RouteProtocol::Tcp);
        assert_eq!(decoded.route_hints[1].kind, RouteKind::Lan);
        assert_eq!(decoded.route_hints[1].protocol, RouteProtocol::Udp);
        assert_eq!(decoded.route_hints[2].kind, RouteKind::Relay);
    }

    #[test]
    fn pairing_code_is_derived_from_payload_and_rotates() {
        let bootstrap = IdentityApi::bootstrap_device("Alice", None, 7667, Vec::new());
        let payload = encode_invite(&bootstrap.invite).expect("invite should encode");
        let early = 1_735_728_000_000;
        let later = early + 60_000;

        let early_code = IdentityApi::current_pairing_code_for_payload(&payload, Some(early));
        let later_code = IdentityApi::current_pairing_code_for_payload(&payload, Some(later));

        assert_ne!(early_code, later_code);
        assert!(IdentityApi::matches_pairing_code_for_payload(
            &payload,
            &early_code,
            Some(early),
        ));
        assert!(!IdentityApi::matches_pairing_code_for_payload(
            &payload,
            &early_code,
            Some(later),
        ));
    }

    #[test]
    fn encryption_round_trip_works() {
        let alice = IdentityApi::bootstrap_device("Alice", None, 7667, Vec::new());
        let bob = IdentityApi::bootstrap_device("Bob", None, 7667, Vec::new());
        let bob_profile = ContactProfile {
            alias: "Bob".to_owned(),
            account_id: bob.identity.account_id.clone(),
            device_id: bob.identity.device_id.clone(),
            display_name: "Bob".to_owned(),
            signing_public_key_b64: bob.identity.signing_public_key_b64.clone(),
            exchange_public_key_b64: bob.identity.exchange_public_key_b64.clone(),
            route_hints: bob.identity.advertised_route_hints(),
            safety_number: bob.safety_number.clone(),
        };
        let alice_profile = ContactProfile {
            alias: "Alice".to_owned(),
            account_id: alice.identity.account_id.clone(),
            device_id: alice.identity.device_id.clone(),
            display_name: "Alice".to_owned(),
            signing_public_key_b64: alice.identity.signing_public_key_b64.clone(),
            exchange_public_key_b64: alice.identity.exchange_public_key_b64.clone(),
            route_hints: alice.identity.advertised_route_hints(),
            safety_number: alice.safety_number.clone(),
        };
        let envelope = ChatApi::encrypt_direct_message(
            &alice.identity,
            &bob_profile,
            ConversationId("conv-alice-bob".to_owned()),
            "hello world",
        )
        .expect("message should encrypt");
        let plaintext = ChatApi::decrypt_direct_message(&bob.identity, &alice_profile, &envelope)
            .expect("message should decrypt");
        assert_eq!(plaintext, "hello world");
    }

    #[test]
    fn route_planner_prefers_lan_then_relay() {
        let routes = NetworkApi::select_routes(&[
            PeerRoute {
                kind: RouteKind::Relay,
                host: "relay.example".to_owned(),
                port: 7667,
                protocol: RouteProtocol::Tcp,
            },
            PeerRoute {
                kind: RouteKind::Lan,
                host: "192.168.0.25".to_owned(),
                port: 7667,
                protocol: RouteProtocol::Udp,
            },
            PeerRoute {
                kind: RouteKind::Lan,
                host: "192.168.0.25".to_owned(),
                port: 7667,
                protocol: RouteProtocol::Udp,
            },
        ]);
        assert_eq!(routes[0].kind, RouteKind::Lan);
        assert_eq!(routes[0].protocol, RouteProtocol::Udp);
        assert_eq!(routes[1].kind, RouteKind::Relay);
        assert_eq!(routes.len(), 2);
    }
}
