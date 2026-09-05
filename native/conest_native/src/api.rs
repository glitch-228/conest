#[cfg(test)]
use std::sync::atomic::{AtomicUsize, Ordering};
use std::{
    collections::HashMap,
    net::SocketAddr,
    str::FromStr,
    sync::{Arc, Weak},
    time::Duration,
};

use anyhow::{Context, Result, anyhow, bail};
use flutter_rust_bridge::frb;
use iroh::{
    Endpoint, EndpointAddr, EndpointId, RelayMap, RelayMode, SecretKey,
    endpoint::{Connection, presets},
};
use serde::{Deserialize, Serialize};
use tokio::sync::{Mutex, mpsc};

const CONEST_ALPN: &[u8] = b"conest/1";
const MAX_ENVELOPE_BYTES: usize = 5 * 1024 * 1024;
const INBOX_CAPACITY: usize = 256;
const STREAM_TIMEOUT: Duration = Duration::from_secs(60);
const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
const MAX_INBOUND_STREAMS: usize = 8;

type ConnectionPool = Arc<Mutex<HashMap<EndpointId, Connection>>>;

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
    inbox_tx: mpsc::Sender<NativeInboundEnvelope>,
    /// QUIC is designed to multiplex streams. Keeping the established
    /// connection here avoids a full discovery/NAT/TLS handshake for every
    /// message or attachment block.
    connections: ConnectionPool,
    connect_locks: Mutex<HashMap<EndpointId, Weak<Mutex<()>>>>,
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
            inbox_tx.clone(),
            Arc::clone(&connections),
        ));
        Ok(Self {
            endpoint,
            inbox: Arc::new(Mutex::new(inbox_rx)),
            inbox_tx,
            connections,
            connect_locks: Mutex::new(HashMap::new()),
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

    pub async fn send_envelope_with_hints(
        &self,
        remote_endpoint_id: String,
        direct_addresses: Vec<String>,
        bytes: Vec<u8>,
        allow_relay: bool,
    ) -> Result<NativeDeliveryReceipt, String> {
        self.send_to_with_hints(remote_endpoint_id, direct_addresses, bytes, allow_relay)
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

    async fn send_to_with_hints(
        &self,
        remote_endpoint_id: String,
        direct_addresses: Vec<String>,
        bytes: Vec<u8>,
        allow_relay: bool,
    ) -> Result<NativeDeliveryReceipt> {
        if direct_addresses.len() > 8 {
            bail!("at most eight direct Iroh address hints may be supplied");
        }
        let endpoint_id =
            EndpointId::from_str(&remote_endpoint_id).context("parse remote Iroh EndpointId")?;
        let mut remote_addr = EndpointAddr::new(endpoint_id);
        for value in direct_addresses {
            let address = SocketAddr::from_str(value.trim())
                .with_context(|| format!("parse direct Iroh address hint {value}"))?;
            remote_addr = remote_addr.with_ip_addr(address);
        }
        self.send_to_addr_with_policy(remote_addr, bytes, allow_relay)
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
        // Coalesce dials for one peer without blocking other peers or inbound
        // accepts behind an unreachable endpoint's handshake.
        let gate = {
            let mut locks = self.connect_locks.lock().await;
            locks.retain(|_, gate| gate.strong_count() > 0);
            if let Some(gate) = locks.get(&endpoint_id).and_then(Weak::upgrade) {
                gate
            } else {
                let gate = Arc::new(Mutex::new(()));
                locks.insert(endpoint_id, Arc::downgrade(&gate));
                gate
            }
        };
        let _connecting = gate.lock().await;
        if let Some(connection) = self.connections.lock().await.get(&endpoint_id).cloned()
            && connection.close_reason().is_none()
        {
            return Ok(connection);
        }
        #[cfg(test)]
        self.connection_attempts.fetch_add(1, Ordering::Relaxed);
        let connection = tokio::time::timeout(
            CONNECT_TIMEOUT,
            self.endpoint.connect(remote_addr, CONEST_ALPN),
        )
        .await
        .context("Iroh connection timed out")?
        .context("connect to Iroh peer")?;
        self.connections
            .lock()
            .await
            .insert(endpoint_id, connection.clone());
        // Both dialed and accepted connections are duplex. The remote can
        // open reply/control streams on this same pooled connection.
        tokio::spawn(run_connection(
            connection.clone(),
            self.inbox_tx.clone(),
            Arc::clone(&self.connections),
        ));
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
        tokio::time::timeout(
            STREAM_TIMEOUT,
            self.send_stream(endpoint_id, connection, bytes, allow_relay),
        )
        .await
        .context("Iroh stream timed out")?
    }

    async fn send_stream(
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
        tokio::select! {
            envelope = async { self.inbox.lock().await.recv().await } => envelope,
            _ = self.endpoint.closed() => None,
        }
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
    connections: ConnectionPool,
) {
    while let Some(incoming) = endpoint.accept().await {
        let inbox = inbox.clone();
        let connections = Arc::clone(&connections);
        tokio::spawn(async move {
            let Ok(Ok(connection)) = tokio::time::timeout(CONNECT_TIMEOUT, incoming).await else {
                return;
            };
            let sender_endpoint = connection.remote_id();
            connections
                .lock()
                .await
                .insert(sender_endpoint, connection.clone());
            run_connection(connection, inbox, connections).await;
        });
    }
}

async fn run_connection(
    connection: Connection,
    inbox: mpsc::Sender<NativeInboundEnvelope>,
    connections: ConnectionPool,
) {
    let sender_endpoint = connection.remote_id();
    let mut streams = tokio::task::JoinSet::new();
    loop {
        // Bound concurrent buffers while allowing a slow stream to coexist
        // with control messages and the rest of an attachment's range window.
        if streams.len() >= MAX_INBOUND_STREAMS {
            streams.join_next().await;
            continue;
        }
        tokio::select! {
            _ = streams.join_next(), if !streams.is_empty() => {},
            incoming = connection.accept_bi() => {
                let Ok((mut send, mut recv)) = incoming else { break; };
                let inbox = inbox.clone();
                let connection = connection.clone();
                streams.spawn(async move {
                    let _ = tokio::time::timeout(STREAM_TIMEOUT, async {
                        let bytes = recv.read_to_end(MAX_ENVELOPE_BYTES).await?;
                        if bytes.is_empty() { bail!("empty Iroh envelope"); }
                        let accepted = inbox.send(NativeInboundEnvelope {
                            sender_endpoint_id: sender_endpoint.to_string(),
                            bytes,
                            path: path_kind(&connection),
                        }).await.is_ok();
                        send.write_all(&[u8::from(accepted)]).await?;
                        send.finish()?;
                        Ok::<(), anyhow::Error>(())
                    }).await;
                });
            }
        }
    }
    let mut pool = connections.lock().await;
    if pool
        .get(&sender_endpoint)
        .is_some_and(|entry| entry.stable_id() == connection.stable_id())
    {
        pool.remove(&sender_endpoint);
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
            .send_to_with_hints(
                receiver.endpoint.id().to_string(),
                receiver.status().direct_addresses,
                b"same connection".to_vec(),
                false,
            )
            .await
            .unwrap();
        assert!(second.accepted);
        assert_eq!(sender.connections.lock().await.len(), 1);

        let reply = tokio::time::timeout(
            Duration::from_secs(2),
            receiver.send_to(
                sender.endpoint.id().to_string(),
                b"reply on pooled connection".to_vec(),
                false,
            ),
        )
        .await
        .expect("reply on the existing connection timed out")
        .unwrap();
        assert!(reply.accepted);
        let inbound = tokio::time::timeout(Duration::from_secs(2), sender.next_envelope())
            .await
            .expect("sender inbox timed out")
            .expect("sender inbox closed");
        assert_eq!(inbound.bytes, b"reply on pooled connection");
        assert_eq!(
            inbound.sender_endpoint_id,
            receiver.endpoint.id().to_string()
        );
        assert_eq!(receiver.connection_attempts.load(Ordering::Relaxed), 0);

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

    #[tokio::test]
    async fn stalled_stream_does_not_block_control_messages() {
        let sender = NativeTransport::start_inner(vec![51; 32], false, vec![])
            .await
            .unwrap();
        let receiver = NativeTransport::start_inner(vec![52; 32], false, vec![])
            .await
            .unwrap();
        let connection = sender
            .connection_for(receiver.endpoint.addr())
            .await
            .unwrap();
        let (mut stalled, _reply) = connection.open_bi().await.unwrap();
        stalled.write_all(b"unfinished block").await.unwrap();
        let receipt = tokio::time::timeout(
            Duration::from_secs(2),
            sender.send_to(
                receiver.endpoint.id().to_string(),
                b"control".to_vec(),
                false,
            ),
        )
        .await
        .expect("control message was blocked by a partial stream")
        .unwrap();
        assert!(receipt.accepted);
        assert_eq!(receiver.next_envelope().await.unwrap().bytes, b"control");
        sender.close().await;
        receiver.close().await;
    }

    #[tokio::test]
    async fn stalled_peer_dial_does_not_lock_other_connections() {
        let sender = NativeTransport::start_inner(vec![61; 32], false, vec![])
            .await
            .unwrap();
        let receiver = NativeTransport::start_inner(vec![62; 32], false, vec![])
            .await
            .unwrap();
        let stalled_peer = SecretKey::from_bytes(&[63; 32]).public();
        let blocked_gate = Arc::new(Mutex::new(()));
        sender
            .connect_locks
            .lock()
            .await
            .insert(stalled_peer, Arc::downgrade(&blocked_gate));
        let _blocked = blocked_gate.lock().await;
        let stalled = sender.connection_for(EndpointAddr::new(stalled_peer));
        let reachable =
            sender.send_to_addr_with_policy(receiver.endpoint.addr(), b"reachable".to_vec(), false);
        tokio::select! {
            result = stalled => panic!("stalled dial unexpectedly completed: {}", result.is_ok()),
            receipt = tokio::time::timeout(Duration::from_secs(2), reachable) => {
                assert!(receipt.expect("another peer's dial blocked delivery").unwrap().accepted);
            }
        }
        sender.close().await;
        receiver.close().await;
    }

    #[tokio::test]
    async fn close_wakes_waiting_inbox_reader() {
        let endpoint = NativeTransport::start_inner(vec![71; 32], false, vec![])
            .await
            .unwrap();
        tokio::time::timeout(Duration::from_secs(2), async {
            let (envelope, ()) = tokio::join!(endpoint.next_envelope(), endpoint.close());
            assert!(envelope.is_none());
        })
        .await
        .expect("close left the inbox reader blocked");
    }

    /// Slow opt-in certification for the requested online attachment target.
    /// It carries 250 MiB over direct authenticated Iroh/QUIC with relays
    /// disabled, validates every byte, and keeps only a bounded stream window
    /// resident. Run with:
    /// `cargo test direct_iroh_certifies_250_mib -- --ignored`.
    #[tokio::test]
    #[ignore = "opt-in 250 MiB direct-Iroh certification"]
    async fn direct_iroh_certifies_250_mib() {
        const BLOCK_BYTES: usize = 1024 * 1024;
        const BLOCK_COUNT: u32 = 250;
        const STREAM_WINDOW: usize = 8;

        tokio::time::timeout(Duration::from_secs(300), async {
            let sender = Arc::new(
                NativeTransport::start_inner(vec![41; 32], false, vec![])
                    .await
                    .unwrap(),
            );
            let receiver = Arc::new(
                NativeTransport::start_inner(vec![42; 32], false, vec![])
                    .await
                    .unwrap(),
            );
            let receiver_addr = receiver.endpoint.addr();
            let receiving = {
                let receiver = Arc::clone(&receiver);
                tokio::spawn(async move {
                    let mut received = std::collections::BTreeSet::new();
                    for _ in 0..BLOCK_COUNT {
                        let envelope = receiver
                            .next_envelope()
                            .await
                            .expect("direct Iroh receiver closed early");
                        assert_eq!(envelope.path, NativePathKind::Direct);
                        assert_eq!(envelope.bytes.len(), BLOCK_BYTES);
                        let index = u32::from_be_bytes(
                            envelope.bytes[..4].try_into().expect("block index"),
                        );
                        assert!(index < BLOCK_COUNT);
                        let expected = (index.wrapping_mul(31) & 0xff) as u8;
                        assert!(envelope.bytes[4..].iter().all(|byte| *byte == expected));
                        assert!(received.insert(index), "duplicate direct Iroh block");
                    }
                    received
                })
            };

            let permits = Arc::new(tokio::sync::Semaphore::new(STREAM_WINDOW));
            let mut sends = tokio::task::JoinSet::new();
            for index in 0..BLOCK_COUNT {
                let sender = Arc::clone(&sender);
                let receiver_addr = receiver_addr.clone();
                let permits = Arc::clone(&permits);
                sends.spawn(async move {
                    let _permit = permits.acquire_owned().await.expect("stream permit");
                    let fill = (index.wrapping_mul(31) & 0xff) as u8;
                    let mut payload = vec![fill; BLOCK_BYTES];
                    payload[..4].copy_from_slice(&index.to_be_bytes());
                    sender
                        .send_to_addr_with_policy(receiver_addr, payload, false)
                        .await
                });
            }
            while let Some(result) = sends.join_next().await {
                let receipt = result
                    .expect("direct Iroh send task")
                    .expect("direct Iroh send");
                assert!(receipt.accepted);
                assert_eq!(receipt.path, NativePathKind::Direct);
            }
            let received = receiving.await.expect("direct Iroh receive task");
            assert_eq!(received.len(), BLOCK_COUNT as usize);
            assert_eq!(sender.connection_attempts.load(Ordering::Relaxed), 1);
            sender.close().await;
            receiver.close().await;
        })
        .await
        .expect("250 MiB direct Iroh certification timed out");
    }
}
