#[cfg(test)]
use std::sync::atomic::{AtomicUsize, Ordering};
use std::{collections::HashMap, str::FromStr, sync::Arc};

use anyhow::{Context, Result, anyhow, bail};
use flutter_rust_bridge::frb;
use iroh::{
    Endpoint, EndpointAddr, EndpointId, RelayMap, RelayMode, SecretKey,
    endpoint::{Connection, presets},
};
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
    /// QUIC is designed to multiplex streams. Keeping the established
    /// connection here avoids a full discovery/NAT/TLS handshake for every
    /// message or attachment block.
    connections: Arc<Mutex<HashMap<EndpointId, Connection>>>,
    #[cfg(test)]
    connection_attempts: Arc<AtomicUsize>,
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
        let connections = Arc::new(Mutex::new(HashMap::new()));
        tokio::spawn(run_accept_loop(
            endpoint.clone(),
            inbox_tx,
            Arc::clone(&connections),
        ));
        Ok(Self {
            endpoint,
            inbox: Arc::new(Mutex::new(inbox_rx)),
            connections,
            #[cfg(test)]
            connection_attempts: Arc::new(AtomicUsize::new(0)),
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
        self.send_envelope_with_policy(remote_endpoint_id, bytes, true)
            .await
    }

    pub async fn send_envelope_with_policy(
        &self,
        remote_endpoint_id: String,
        bytes: Vec<u8>,
        allow_relay: bool,
    ) -> Result<NativeDeliveryReceipt, String> {
        self.send_to(remote_endpoint_id, bytes, allow_relay)
            .await
            .map_err(|error| format!("{error:#}"))
    }

    async fn send_to(
        &self,
        remote_endpoint_id: String,
        bytes: Vec<u8>,
        allow_relay: bool,
    ) -> Result<NativeDeliveryReceipt> {
        let endpoint_id =
            EndpointId::from_str(&remote_endpoint_id).context("parse remote Iroh EndpointId")?;
        self.send_to_addr_with_policy(EndpointAddr::new(endpoint_id), bytes, allow_relay)
            .await
    }

    async fn send_to_addr_with_policy(
        &self,
        remote_addr: EndpointAddr,
        bytes: Vec<u8>,
        allow_relay: bool,
    ) -> Result<NativeDeliveryReceipt> {
        if bytes.is_empty() || bytes.len() > MAX_ENVELOPE_BYTES {
            bail!("Iroh envelope size is outside the allowed range");
        }
        let endpoint_id = remote_addr.id;
        let connection = self.connection_for(remote_addr.clone()).await?;
        match self
            .send_on_connection(endpoint_id, &connection, &bytes, allow_relay)
            .await
        {
            Ok(receipt) => Ok(receipt),
            Err(first_error) => {
                // A pooled connection may have closed between lookup and
                // open_bi. Evict it and retry exactly once on a fresh QUIC
                // connection; higher layers retain their normal route retry.
                self.evict_if_same(endpoint_id, &connection).await;
                let fresh = self.connection_for(remote_addr).await.with_context(|| {
                    format!("reconnect after pooled Iroh failure: {first_error:#}")
                })?;
                self.send_on_connection(endpoint_id, &fresh, &bytes, allow_relay)
                    .await
            }
        }
    }

    async fn connection_for(&self, remote_addr: EndpointAddr) -> Result<Connection> {
        let endpoint_id = remote_addr.id;
        // Hold the per-installation pool lock through connect. This makes a
        // burst of attachment streams single-flight instead of allowing all
        // callers to observe a miss and perform duplicate NAT/TLS handshakes.
        // The lock is released before any stream I/O, so established peers
        // still multiplex concurrently.
        let mut connections = self.connections.lock().await;
        if let Some(connection) = connections.get(&endpoint_id).cloned()
            && connection.close_reason().is_none()
        {
            return Ok(connection);
        }
        #[cfg(test)]
        self.connection_attempts.fetch_add(1, Ordering::Relaxed);
        let connection = self
            .endpoint
            .connect(remote_addr, CONEST_ALPN)
            .await
            .context("connect to Iroh peer")?;
        connections.insert(endpoint_id, connection.clone());
        Ok(connection)
    }

    async fn evict_if_same(&self, endpoint_id: EndpointId, failed: &Connection) {
        let mut connections = self.connections.lock().await;
        if connections
            .get(&endpoint_id)
            .is_some_and(|pooled| pooled.stable_id() == failed.stable_id())
        {
            connections.remove(&endpoint_id);
        }
    }

    async fn send_on_connection(
        &self,
        endpoint_id: EndpointId,
        connection: &Connection,
        bytes: &[u8],
        allow_relay: bool,
    ) -> Result<NativeDeliveryReceipt> {
        let path = path_kind(connection);
        if (!self.relay_enabled || !allow_relay) && path == NativePathKind::Relayed {
            bail!("Iroh relay path is disabled by policy");
        }
        let (mut send, mut recv) = connection.open_bi().await.context("open stream")?;
        send.write_all(bytes).await.context("write envelope")?;
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
        self.connections.lock().await.clear();
        self.endpoint.close().await;
    }
}

async fn run_accept_loop(
    endpoint: Endpoint,
    inbox: mpsc::Sender<NativeInboundEnvelope>,
    connections: Arc<Mutex<HashMap<EndpointId, Connection>>>,
) {
    while let Some(incoming) = endpoint.accept().await {
        let inbox = inbox.clone();
        let connections = Arc::clone(&connections);
        tokio::spawn(async move {
            let Ok(connection) = incoming.await else {
                return;
            };
            let sender_endpoint = connection.remote_id();
            let sender_endpoint_id = sender_endpoint.to_string();
            connections
                .lock()
                .await
                .insert(sender_endpoint, connection.clone());
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
                        path: path_kind(&connection),
                    })
                    .await
                    .is_ok();
                let ack = if accepted { 1 } else { 0 };
                if send.write_all(&[ack]).await.is_ok() {
                    let _ = send.finish();
                }
            }
            connections.lock().await.remove(&sender_endpoint);
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
            sender.send_to_addr_with_policy(receiver_addr, b"direct integration".to_vec(), true),
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

        let second = sender
            .send_to_addr_with_policy(receiver.endpoint.addr(), b"same connection".to_vec(), true)
            .await
            .unwrap();
        assert!(second.accepted);
        assert_eq!(sender.connections.lock().await.len(), 1);

        sender.close().await;
        receiver.close().await;
    }

    #[tokio::test]
    async fn concurrent_streams_share_one_connection_attempt() {
        let sender = Arc::new(
            NativeTransport::start_inner(vec![31; 32], false, vec![])
                .await
                .unwrap(),
        );
        let receiver = NativeTransport::start_inner(vec![32; 32], false, vec![])
            .await
            .unwrap();
        let receiver_addr = receiver.endpoint.addr();
        let mut sends = tokio::task::JoinSet::new();
        for index in 0..16_u8 {
            let sender = Arc::clone(&sender);
            let receiver_addr = receiver_addr.clone();
            sends.spawn(async move {
                sender
                    .send_to_addr_with_policy(receiver_addr, vec![index], true)
                    .await
            });
        }
        while let Some(result) = sends.join_next().await {
            assert!(result.expect("send task").expect("send stream").accepted);
        }

        assert_eq!(sender.connection_attempts.load(Ordering::Relaxed), 1);
        assert_eq!(sender.connections.lock().await.len(), 1);
        sender.close().await;
        receiver.close().await;
    }
}
