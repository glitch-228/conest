use std::{str::FromStr, sync::Arc};

use anyhow::{Context, Result, anyhow, bail};
use flutter_rust_bridge::frb;
use iroh::{Endpoint, EndpointAddr, EndpointId, RelayMap, RelayMode, SecretKey, endpoint::presets};
use serde::{Deserialize, Serialize};
use tokio::sync::{Mutex, mpsc};

const CONEST_ALPN: &[u8] = b"conest/1";
const MAX_ENVELOPE_BYTES: usize = 4 * 1024 * 1024;
const INBOX_CAPACITY: usize = 256;

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct NativeEndpointStatus {
    pub endpoint_id: String,
    pub direct_addresses: Vec<String>,
    pub relay_url: Option<String>,
    pub relay_enabled: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct NativeDeliveryReceipt {
    pub endpoint_id: String,
    pub path: NativePathKind,
    pub accepted: bool,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub enum NativePathKind {
    Direct,
    Relayed,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct NativeInboundEnvelope {
    pub sender_endpoint_id: String,
    pub bytes: Vec<u8>,
    pub path: NativePathKind,
}

#[frb(opaque)]
pub struct NativeTransport {
    endpoint: Endpoint,
    inbox: Arc<Mutex<mpsc::Receiver<NativeInboundEnvelope>>>,
    relay_enabled: bool,
}

impl NativeTransport {
    /// Starts the single Iroh endpoint owned by this Conest installation.
    /// The 32-byte seed is the same Ed25519 installation identity that signs
    /// ci6 transport bindings, so the advertised EndpointId is intrinsically
    /// bound to that signature key.
    #[frb]
    pub async fn start(
        secret_key_seed: Vec<u8>,
        relay_enabled: bool,
        relay_urls: Vec<String>,
    ) -> Result<Self, String> {
        Self::start_inner(secret_key_seed, relay_enabled, relay_urls)
            .await
            .map_err(|error| format!("{error:#}"))
    }

    async fn start_inner(
        secret_key_seed: Vec<u8>,
        relay_enabled: bool,
        relay_urls: Vec<String>,
    ) -> Result<Self> {
        let seed: [u8; 32] = secret_key_seed
            .try_into()
            .map_err(|_| anyhow!("Iroh secret key seed must be exactly 32 bytes"))?;
        let secret_key = SecretKey::from_bytes(&seed);
        let mut builder = Endpoint::builder(presets::N0)
            .secret_key(secret_key)
            .alpns(vec![CONEST_ALPN.to_vec()]);
        if !relay_enabled {
            builder = builder.relay_mode(RelayMode::Disabled);
        } else if !relay_urls.is_empty() {
            if relay_urls.len() > 8 {
                bail!("at most eight custom Iroh relays may be configured");
            }
            let normalized = relay_urls
                .iter()
                .map(|value| value.trim())
                .filter(|value| !value.is_empty())
                .collect::<std::collections::BTreeSet<_>>();
            if normalized.len() != relay_urls.len() {
                bail!("custom Iroh relay URLs must be non-empty and unique");
            }
            let relay_map =
                RelayMap::try_from_iter(normalized).context("parse custom Iroh relay URL list")?;
            builder = builder.relay_mode(RelayMode::Custom(relay_map));
        }
        let endpoint = builder.bind().await.context("bind Iroh endpoint")?;
        let (inbox_tx, inbox_rx) = mpsc::channel(INBOX_CAPACITY);
        tokio::spawn(run_accept_loop(endpoint.clone(), inbox_tx));
        Ok(Self {
            endpoint,
            inbox: Arc::new(Mutex::new(inbox_rx)),
            relay_enabled,
        })
    }

    #[frb]
    pub fn status(&self) -> NativeEndpointStatus {
        let addr = self.endpoint.addr();
        // Materialize the iterator result before constructing the status. The
        // relay iterator borrows `addr`, and leaving it in the tail expression
        // extends the temporary past the address value on recent Rust.
        let relay_url = addr.relay_urls().next().map(ToString::to_string);
        NativeEndpointStatus {
            endpoint_id: self.endpoint.id().to_string(),
            direct_addresses: addr.ip_addrs().map(ToString::to_string).collect(),
            relay_url,
            relay_enabled: self.relay_enabled,
        }
    }

    #[frb]
    pub async fn send_envelope(
        &self,
        remote_endpoint_id: String,
        bytes: Vec<u8>,
    ) -> Result<NativeDeliveryReceipt, String> {
        self.send_to(remote_endpoint_id, bytes)
            .await
            .map_err(|error| format!("{error:#}"))
    }

    async fn send_to(
        &self,
        remote_endpoint_id: String,
        bytes: Vec<u8>,
    ) -> Result<NativeDeliveryReceipt> {
        let endpoint_id =
            EndpointId::from_str(&remote_endpoint_id).context("parse remote Iroh EndpointId")?;
        self.send_to_addr(EndpointAddr::new(endpoint_id), bytes)
            .await
    }

    async fn send_to_addr(
        &self,
        remote_addr: EndpointAddr,
        bytes: Vec<u8>,
    ) -> Result<NativeDeliveryReceipt> {
        if bytes.is_empty() || bytes.len() > MAX_ENVELOPE_BYTES {
            bail!("Iroh envelope size is outside the allowed range");
        }
        let endpoint_id = remote_addr.id;
        let connection = self
            .endpoint
            .connect(remote_addr, CONEST_ALPN)
            .await
            .context("connect to Iroh peer")?;
        let path = path_kind(&connection);
        if !self.relay_enabled && path == NativePathKind::Relayed {
            bail!("Iroh relay path is disabled by policy");
        }
        let (mut send, mut recv) = connection.open_bi().await.context("open stream")?;
        send.write_all(&bytes).await.context("write envelope")?;
        send.finish().context("finish envelope stream")?;
        let response = recv
            .read_to_end(1)
            .await
            .context("read delivery acknowledgement")?;
        if response.as_slice() != [1] {
            bail!("peer rejected Iroh envelope");
        }
        Ok(NativeDeliveryReceipt {
            endpoint_id: endpoint_id.to_string(),
            path,
            accepted: true,
        })
    }

    #[frb]
    pub async fn next_envelope(&self) -> Option<NativeInboundEnvelope> {
        self.inbox.lock().await.recv().await
    }

    pub(crate) async fn try_next_envelope(&self) -> Option<NativeInboundEnvelope> {
        self.inbox.lock().await.try_recv().ok()
    }

    #[frb]
    pub async fn close(&self) {
        self.endpoint.close().await;
    }
}

async fn run_accept_loop(endpoint: Endpoint, inbox: mpsc::Sender<NativeInboundEnvelope>) {
    while let Some(incoming) = endpoint.accept().await {
        let inbox = inbox.clone();
        tokio::spawn(async move {
            let Ok(connection) = incoming.await else {
                return;
            };
            let sender_endpoint_id = connection.remote_id().to_string();
            let path = path_kind(&connection);
            loop {
                let Ok((mut send, mut recv)) = connection.accept_bi().await else {
                    break;
                };
                let Ok(bytes) = recv.read_to_end(MAX_ENVELOPE_BYTES).await else {
                    continue;
                };
                if bytes.is_empty() {
                    continue;
                }
                let accepted = inbox
                    .send(NativeInboundEnvelope {
                        sender_endpoint_id: sender_endpoint_id.clone(),
                        bytes,
                        path,
                    })
                    .await
                    .is_ok();
                let ack = if accepted { 1 } else { 0 };
                if send.write_all(&[ack]).await.is_ok() {
                    let _ = send.finish();
                }
            }
        });
    }
}

fn path_kind(connection: &iroh::endpoint::Connection) -> NativePathKind {
    let paths = connection.paths();
    let selected_is_direct = paths
        .iter()
        .find(|path| path.is_selected())
        .map(|path| path.is_ip())
        .unwrap_or_else(|| paths.iter().any(|path| path.is_ip()));
    if selected_is_direct {
        NativePathKind::Direct
    } else {
        NativePathKind::Relayed
    }
}

#[frb(sync)]
pub fn iroh_endpoint_id_for_seed(secret_key_seed: Vec<u8>) -> Result<String, String> {
    let seed: [u8; 32] = secret_key_seed
        .try_into()
        .map_err(|_| "Iroh secret key seed must be exactly 32 bytes".to_owned())?;
    Ok(SecretKey::from_bytes(&seed).public().to_string())
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use super::*;

    #[test]
    fn endpoint_id_is_stable_for_seed() {
        let seed = vec![7; 32];
        assert_eq!(
            iroh_endpoint_id_for_seed(seed.clone()).unwrap(),
            iroh_endpoint_id_for_seed(seed).unwrap()
        );
    }

    #[tokio::test]
    async fn rejects_invalid_seed_length() {
        let error = match NativeTransport::start_inner(vec![1, 2, 3], false, vec![]).await {
            Ok(_) => panic!("invalid Iroh seed unexpectedly started an endpoint"),
            Err(error) => error,
        };
        assert!(error.to_string().contains("exactly 32 bytes"));
    }

    #[tokio::test]
    async fn rejects_invalid_custom_relay_url() {
        let error = match NativeTransport::start_inner(
            vec![3; 32],
            true,
            vec!["not-a-relay-url".to_owned()],
        )
        .await
        {
            Ok(_) => panic!("invalid custom relay URL unexpectedly started an endpoint"),
            Err(error) => error,
        };
        assert!(error.to_string().contains("parse custom Iroh relay"));
    }

    #[tokio::test]
    async fn two_endpoints_exchange_an_acknowledged_direct_envelope() {
        let sender = NativeTransport::start_inner(vec![11; 32], false, vec![])
            .await
            .unwrap();
        let receiver = NativeTransport::start_inner(vec![22; 32], false, vec![])
            .await
            .unwrap();
        let receiver_addr = receiver.endpoint.addr();
        assert!(receiver_addr.ip_addrs().next().is_some());

        let receipt = tokio::time::timeout(
            Duration::from_secs(10),
            sender.send_to_addr(receiver_addr, b"direct integration".to_vec()),
        )
        .await
        .expect("direct Iroh send timed out")
        .unwrap();
        assert!(receipt.accepted);
        assert_eq!(receipt.path, NativePathKind::Direct);

        let inbound = tokio::time::timeout(Duration::from_secs(2), receiver.next_envelope())
            .await
            .expect("receiver inbox timed out")
            .expect("receiver inbox closed");
        assert_eq!(inbound.bytes, b"direct integration");
        assert_eq!(inbound.sender_endpoint_id, sender.endpoint.id().to_string());
        assert_eq!(inbound.path, NativePathKind::Direct);

        sender.close().await;
        receiver.close().await;
    }
}
