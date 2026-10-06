//! Tor carrier (M20) over Arti: one onion service per device, reached by
//! contacts over Tor, optionally through bridges and pluggable transports.
//!
//! Same shape as `matrix.rs`: commands arrive as JSON through `call`, run
//! on a dedicated Tokio runtime and answer through an event queue that a
//! Dart isolate drains with `next_event`.
//!
//! Wire format between onion services: a stream carries frames, each a
//! 4-byte big-endian length then the bytes (at most [`MAX_FRAME`]). The
//! frames are Conest carrier frames, already sealed per contact.
//!
//! Anyone who learns the onion address can connect, so everything a
//! stranger can cause is bounded: concurrent streams, streams per circuit,
//! introductions, idle time, memory per frame and the bytes waiting in the
//! event queue.

use std::{
    collections::{HashMap, VecDeque},
    future::Future,
    panic::AssertUnwindSafe,
    sync::{
        Arc, Condvar, LazyLock, Mutex, Once,
        atomic::{AtomicU64, Ordering},
    },
    time::{Duration, Instant},
};

use anyhow::{Context, Result, anyhow, bail};
use arti_client::{
    DataStream, TorClient,
    config::{
        BridgeConfigBuilder, CfgPath, TorClientConfigBuilder,
        onion_service::OnionServiceConfigBuilder, pt::TransportConfigBuilder,
    },
};
use base64::Engine;
use futures_util::{
    FutureExt, StreamExt,
    future::{Either, select},
};
use safelog::DisplayRedacted;
use serde_json::{Value, json};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    runtime::Runtime,
    sync::{Mutex as AsyncMutex, Notify},
    task::{AbortHandle, JoinHandle, JoinSet},
    time::timeout,
};
use tor_cell::relaycell::msg::Connected;
use tor_hsservice::{
    RendRequest, RunningOnionService, config::TokenBucketConfig, handle_rend_requests,
    status::State,
};
use tor_proto::stream::IncomingStreamRequest;
use tor_rtcompat::PreferredRuntime;

/// The virtual port of Conest's onion service.
pub const ONION_PORT: u16 = 7177;

/// Largest frame accepted on a stream.
pub const MAX_FRAME: usize = 1 << 20;

/// Idle outgoing streams are closed after this long; incoming ones a little
/// later, so the sender closes first.
const IDLE: Duration = Duration::from_secs(300);
const INCOMING_IDLE: Duration = Duration::from_secs(360);

/// Time a new incoming stream has to deliver its first frame.
const FIRST_FRAME: Duration = Duration::from_secs(30);

/// Time to receive a frame's bytes once its length has arrived.
const FRAME_READ: Duration = Duration::from_secs(90);

/// Incoming streams served at once; a new one replaces the quietest.
const MAX_INCOMING_STREAMS: usize = 32;

/// Streams one rendezvous circuit may open at once.
const MAX_STREAMS_PER_CIRCUIT: u32 = 4;

/// First bootstrap, possibly through bridges.
const BOOTSTRAP: Duration = Duration::from_secs(240);

/// Reaching a contact's onion service, writing one frame to it, and a whole
/// send including waiting for an earlier send to the same contact: all
/// within the Dart side's three-minute send timeout.
const CONNECT: Duration = Duration::from_secs(75);
const WRITE: Duration = Duration::from_secs(40);
const SEND: Duration = Duration::from_secs(170);

/// Frame events waiting for Dart, in bytes; further frames are dropped
/// (their senders retry), command results never are.
const MAX_QUEUED_FRAME_BYTES: usize = 32 << 20;

static RUNTIME: LazyLock<Runtime> =
    LazyLock::new(|| Runtime::new().expect("create Conest Tor Tokio runtime"));

/// Queued events, each marked whether it is a received frame.
struct Events {
    queue: VecDeque<(String, bool)>,
    frame_bytes: usize,
}

static EVENTS: LazyLock<(Mutex<Events>, Condvar)> = LazyLock::new(|| {
    (
        Mutex::new(Events {
            queue: VecDeque::new(),
            frame_bytes: 0,
        }),
        Condvar::new(),
    )
});
static STATE: LazyLock<Mutex<Option<TorState>>> = LazyLock::new(|| Mutex::new(None));

/// One start at a time; `stop` bumps the generation and wakes a start in
/// progress, which then gives up instead of installing a client.
static START: LazyLock<AsyncMutex<()>> = LazyLock::new(|| AsyncMutex::new(()));
static GENERATION: AtomicU64 = AtomicU64::new(0);
static CANCEL: LazyLock<Notify> = LazyLock::new(Notify::new);

type Outgoing = Arc<AsyncMutex<Option<(DataStream, Instant)>>>;

/// Outgoing streams by onion host, each behind its own lock so one slow
/// contact does not hold back sends to the others.
static OUTGOING: LazyLock<Mutex<HashMap<String, Outgoing>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

struct TorState {
    client: Arc<TorClient<PreferredRuntime>>,
    service: Arc<RunningOnionService>,
    address: String,
    tasks: Vec<JoinHandle<()>>,
}

fn push_event(value: Value) {
    let (events, ready) = &*EVENTS;
    if let Ok(mut events) = events.lock() {
        events.queue.push_back((value.to_string(), false));
        ready.notify_one();
    }
}

/// Queues a received frame unless too many bytes already wait for Dart.
fn push_frame(frame: &[u8]) {
    let event = json!({
        "type": "frame",
        "data": base64::engine::general_purpose::STANDARD.encode(frame),
    })
    .to_string();
    let (events, ready) = &*EVENTS;
    if let Ok(mut events) = events.lock() {
        if events.frame_bytes + event.len() > MAX_QUEUED_FRAME_BYTES {
            return;
        }
        events.frame_bytes += event.len();
        events.queue.push_back((event, true));
        ready.notify_one();
    }
}

/// Waits up to `timeout` for the next event (JSON).
pub fn next_event(timeout: Duration) -> Option<String> {
    let (events, ready) = &*EVENTS;
    let guard = events.lock().ok()?;
    let (mut guard, _) = ready
        .wait_timeout_while(guard, timeout, |events| events.queue.is_empty())
        .ok()?;
    let (event, frame) = guard.queue.pop_front()?;
    if frame {
        guard.frame_bytes = guard.frame_bytes.saturating_sub(event.len());
    }
    Some(event)
}

/// Queues one command; its outcome arrives as a `result` event carrying the
/// command's `requestId`.
pub fn call(request: Value) -> Result<()> {
    let op = request["op"]
        .as_str()
        .context("missing Tor operation")?
        .to_owned();
    let request_id = request["requestId"].as_str().unwrap_or_default().to_owned();
    install_crypto_provider();
    RUNTIME.spawn(async move {
        // A panic still answers the command instead of leaving it to time
        // out.
        let outcome = match AssertUnwindSafe(run(&op, &request)).catch_unwind().await {
            Ok(outcome) => outcome,
            Err(panic) => Err(anyhow!(
                "Tor {op} failed: {}",
                panic
                    .downcast_ref::<String>()
                    .map(String::as_str)
                    .or_else(|| panic.downcast_ref::<&str>().copied())
                    .unwrap_or("internal error")
            )),
        };
        push_event(match outcome {
            Ok(value) => {
                json!({"type": "result", "requestId": request_id, "ok": true, "value": value})
            }
            Err(error) => json!({
                "type": "result",
                "requestId": request_id,
                "ok": false,
                "error": format!("{error:#}"),
            }),
        });
    });
    Ok(())
}

/// Arti builds its TLS settings from rustls's process-wide provider, which
/// rustls cannot choose by itself here because dependencies enable both
/// ring and aws-lc-rs. Everything else in the library passes its provider
/// explicitly, so this only decides Arti's.
fn install_crypto_provider() {
    static INSTALL: Once = Once::new();
    INSTALL.call_once(|| {
        let _ = rustls::crypto::ring::default_provider().install_default();
    });
}

async fn run(op: &str, request: &Value) -> Result<Value> {
    match op {
        "start" => start(request).await,
        "stop" => {
            stop().await;
            Ok(Value::Null)
        }
        "send" => send(request).await,
        "status" => Ok(json!({
            "running": STATE.lock().map(|state| state.is_some()).unwrap_or(false),
        })),
        other => Err(anyhow!("unknown Tor operation {other}")),
    }
}

/// The running service's address, unless `stop` came after `generation`.
/// `stop` changes the generation under the same lock.
fn running_address(generation: u64) -> Result<Option<String>> {
    let state = STATE.lock().map_err(|_| anyhow!("Tor state poisoned"))?;
    if GENERATION.load(Ordering::SeqCst) != generation {
        bail!("Tor was stopped");
    }
    Ok(state.as_ref().map(|state| state.address.clone()))
}

/// Runs `work` unless `stop` is called first.
async fn unless_stopped<T>(generation: u64, work: impl Future<Output = T>) -> Result<T> {
    // Registered before the check, so a stop in between still wakes it.
    let cancelled = CANCEL.notified();
    if GENERATION.load(Ordering::SeqCst) != generation {
        bail!("Tor was stopped");
    }
    match select(Box::pin(work), Box::pin(cancelled)).await {
        Either::Left((value, _)) if GENERATION.load(Ordering::SeqCst) == generation => Ok(value),
        _ => bail!("Tor was stopped"),
    }
}

/// Bootstraps Tor (through bridges when given) and launches the onion
/// service; answers with its address.
async fn start(request: &Value) -> Result<Value> {
    let generation = GENERATION.load(Ordering::SeqCst);
    let _single = START.lock().await;
    if let Some(address) = running_address(generation)? {
        return Ok(json!({"address": address}));
    }
    let state_dir = request["stateDir"].as_str().context("missing stateDir")?;
    let cache_dir = request["cacheDir"].as_str().context("missing cacheDir")?;
    let mut builder = TorClientConfigBuilder::from_directories(state_dir, cache_dir);
    let mut bridges = 0;
    for line in request["bridges"].as_array().into_iter().flatten() {
        let line = line.as_str().context("bridge lines are strings")?.trim();
        if line.is_empty() {
            continue;
        }
        let bridge: BridgeConfigBuilder = line
            .parse()
            .map_err(|error| anyhow!("bad bridge line: {error}"))?;
        builder.bridges().bridges().push(bridge);
        bridges += 1;
    }
    if let Some(path) = request["transportPath"].as_str() {
        let mut transport = TransportConfigBuilder::default();
        transport
            .protocols(vec![
                "obfs4".parse()?,
                "webtunnel".parse()?,
                "snowflake".parse()?,
                "meek_lite".parse()?,
            ])
            .path(CfgPath::new(path.to_owned()))
            .run_on_startup(false);
        builder.bridges().transports().push(transport);
    }
    if bridges > 0 {
        builder.bridges().enabled(arti_client::config::BoolOrAuto::Explicit(true));
    }
    let config = builder.build().context("Tor configuration")?;
    let client = TorClient::builder()
        .config(config)
        .create_unbootstrapped_async()
        .await
        .context("create Tor client")?;
    let mut progress = client.bootstrap_events();
    let progress_task = RUNTIME.spawn(async move {
        while let Some(status) = progress.next().await {
            push_event(json!({
                "type": "bootstrap",
                "fraction": status.as_frac(),
                "ready": status.ready_for_traffic(),
                "detail": status.to_string(),
            }));
        }
    });
    let bootstrapped = unless_stopped(generation, timeout(BOOTSTRAP, client.bootstrap())).await;
    let bootstrapped = match bootstrapped {
        Ok(Ok(result)) => result.context("connect to Tor"),
        Ok(Err(_)) => Err(anyhow!("Tor did not connect within four minutes")),
        Err(error) => Err(error),
    };
    if let Err(error) = bootstrapped {
        progress_task.abort();
        return Err(error);
    }

    let nickname = request["nickname"].as_str().unwrap_or("conest");
    let mut service_config = OnionServiceConfigBuilder::default();
    service_config
        .nickname(nickname.parse().map_err(|error| anyhow!("bad nickname: {error}"))?)
        .max_concurrent_streams_per_circuit(MAX_STREAMS_PER_CIRCUIT)
        .rate_limit_at_intro(Some(TokenBucketConfig::new(10, 50)));
    let service_config = service_config.build().context("onion service configuration")?;
    // A just-stopped service may still hold its keystore lock briefly.
    let mut attempt = 0;
    let (service, requests) = loop {
        match client.launch_onion_service(service_config.clone()) {
            Ok(Some(launched)) => break launched,
            Ok(None) => {
                progress_task.abort();
                bail!("onion services are disabled");
            }
            Err(_) if attempt < 10 => {
                attempt += 1;
                tokio::time::sleep(Duration::from_millis(500)).await;
            }
            Err(error) => {
                progress_task.abort();
                return Err(error).context("launch onion service");
            }
        }
    };
    let address = service
        .onion_address()
        .ok_or_else(|| anyhow!("the onion service has no address yet"))?
        .display_unredacted()
        .to_string();
    let accept_task = RUNTIME.spawn(accept_streams(requests));
    {
        // Checked and installed under the lock `stop` changes the
        // generation under, so a stop cannot slip in between.
        let mut state = STATE.lock().map_err(|_| anyhow!("Tor state poisoned"))?;
        if GENERATION.load(Ordering::SeqCst) != generation {
            drop(state);
            accept_task.abort();
            progress_task.abort();
            bail!("Tor was stopped");
        }
        *state = Some(TorState {
            client,
            service,
            address: address.clone(),
            tasks: vec![progress_task, accept_task],
        });
    }
    Ok(json!({"address": address}))
}

/// Streams being read, by id: when they last delivered a frame (or were
/// accepted), and how to end them.
type Readers = Arc<Mutex<HashMap<u64, (Instant, AbortHandle)>>>;

/// Serves streams contacts open to the onion service. When all slots are
/// taken, the stream quiet the longest makes room, so streams that send
/// nothing cannot keep contacts out for long.
async fn accept_streams(requests: impl futures_util::Stream<Item = RendRequest> + Send) {
    let mut streams = std::pin::pin!(handle_rend_requests(requests));
    let active: Readers = Arc::new(Mutex::new(HashMap::new()));
    // Owned here: aborting this task drops the set and every reader.
    let mut readers = JoinSet::new();
    let mut next_id = 0u64;
    while let Some(stream_request) = streams.next().await {
        while readers.try_join_next().is_some() {}
        let wanted = matches!(
            stream_request.request(),
            IncomingStreamRequest::Begin(begin) if begin.port() == ONION_PORT
        );
        if !wanted {
            let _ = stream_request.shutdown_circuit();
            continue;
        }
        let Ok(mut map) = active.lock() else { return };
        if map.len() >= MAX_INCOMING_STREAMS {
            let quietest = map
                .iter()
                .min_by_key(|(_, (heard, _))| *heard)
                .map(|(id, _)| *id);
            if let Some((_, handle)) = quietest.and_then(|id| map.remove(&id)) {
                handle.abort();
            }
        }
        let id = next_id;
        next_id += 1;
        let tracker = active.clone();
        let handle = readers.spawn(async move {
            if let Ok(stream) = stream_request.accept(Connected::new_empty()).await {
                read_frames(stream, || {
                    if let Ok(mut map) = tracker.lock() {
                        if let Some(entry) = map.get_mut(&id) {
                            entry.0 = Instant::now();
                        }
                    }
                })
                .await;
            }
            if let Ok(mut map) = tracker.lock() {
                map.remove(&id);
            }
        });
        map.insert(id, (Instant::now(), handle));
    }
}

/// Stops the onion service and Tor; a start in progress gives up.
async fn stop() {
    // The generation changes under the state lock (see `running_address`
    // and the install in `start`).
    let state = match STATE.lock() {
        Ok(mut state) => {
            GENERATION.fetch_add(1, Ordering::SeqCst);
            state.take()
        }
        Err(_) => {
            GENERATION.fetch_add(1, Ordering::SeqCst);
            None
        }
    };
    CANCEL.notify_waiters();
    if let Ok(mut outgoing) = OUTGOING.lock() {
        outgoing.clear();
    }
    let Some(state) = state else { return };
    for task in state.tasks {
        task.abort();
    }
    let mut status = state.service.status_events();
    drop(state.service);
    drop(state.client);
    // Wait (briefly) for the service to let go of its keys, so a restart
    // or deleting the state directory does not race it.
    let _ = timeout(Duration::from_secs(5), async {
        while let Some(update) = status.next().await {
            if update.state() == State::Shutdown {
                break;
            }
        }
    })
    .await;
}

/// Reads length-prefixed frames from an incoming stream until it ends,
/// idles or misbehaves; [heard] runs after each frame. A new stream must
/// deliver its first frame quickly; after that it may idle longer.
async fn read_frames(mut stream: DataStream, heard: impl Fn()) {
    let mut idle = FIRST_FRAME;
    loop {
        let mut header = [0u8; 4];
        match timeout(idle, stream.read_exact(&mut header)).await {
            Ok(Ok(_)) => {}
            _ => return,
        }
        let length = u32::from_be_bytes(header) as usize;
        if length == 0 || length > MAX_FRAME {
            return;
        }
        // Grows as bytes arrive rather than trusting the length up front.
        let mut frame = Vec::with_capacity(length.min(64 << 10));
        let read = timeout(FRAME_READ, async {
            let mut chunk = [0u8; 16 << 10];
            while frame.len() < length {
                let wanted = (length - frame.len()).min(chunk.len());
                let count = stream.read(&mut chunk[..wanted]).await?;
                if count == 0 {
                    return Err(std::io::Error::from(std::io::ErrorKind::UnexpectedEof));
                }
                frame.extend_from_slice(&chunk[..count]);
            }
            Ok(())
        })
        .await;
        match read {
            Ok(Ok(())) => {
                push_frame(&frame);
                heard();
                idle = INCOMING_IDLE;
            }
            _ => return,
        }
    }
}

/// Sends one frame to the onion service `onion` (a `.onion` host), within
/// [`SEND`] overall; `stop` ends it.
async fn send(request: &Value) -> Result<Value> {
    let onion = request["onion"].as_str().context("missing onion")?.to_owned();
    anyhow::ensure!(
        onion.ends_with(".onion") && onion.len() == 62,
        "not a v3 onion address"
    );
    let data = base64::engine::general_purpose::STANDARD
        .decode(request["data"].as_str().context("missing data")?)?;
    anyhow::ensure!(!data.is_empty() && data.len() <= MAX_FRAME, "frame size");
    let (client, generation) = {
        let state = STATE.lock().map_err(|_| anyhow!("Tor state poisoned"))?;
        let client = state
            .as_ref()
            .map(|state| state.client.clone())
            .ok_or_else(|| anyhow!("Tor is not running"))?;
        (client, GENERATION.load(Ordering::SeqCst))
    };
    match timeout(SEND, unless_stopped(generation, deliver(client, onion, data))).await {
        Ok(Ok(result)) => result,
        Ok(Err(stopped)) => Err(stopped),
        Err(_) => Err(anyhow!("sending over Tor timed out")),
    }
}

async fn deliver(
    client: Arc<TorClient<PreferredRuntime>>,
    onion: String,
    data: Vec<u8>,
) -> Result<Value> {
    let slot = {
        let mut outgoing = OUTGOING.lock().map_err(|_| anyhow!("Tor state poisoned"))?;
        // Forget streams idle too long, but never a slot some send holds
        // or is about to lock.
        outgoing.retain(|host, slot| {
            host == &onion
                || Arc::strong_count(slot) > 1
                || slot
                    .try_lock()
                    .map(|guard| guard.as_ref().is_some_and(|(_, used)| used.elapsed() < IDLE))
                    .unwrap_or(true)
        });
        outgoing.entry(onion.clone()).or_default().clone()
    };
    let mut slot = slot.lock().await;
    if slot
        .as_ref()
        .is_some_and(|(_, used)| used.elapsed() >= IDLE)
    {
        *slot = None;
    }
    // A cached stream may have died; one fresh attempt follows a failure.
    for attempt in 0..2 {
        if attempt == 1 || slot.is_none() {
            let stream = timeout(CONNECT, client.connect((onion.as_str(), ONION_PORT)))
                .await
                .map_err(|_| anyhow!("the contact's onion service did not answer"))?
                .context("reach the contact's onion service")?;
            *slot = Some((stream, Instant::now()));
        }
        let (stream, used) = slot.as_mut().expect("just connected");
        let written = timeout(WRITE, async {
            stream.write_all(&(data.len() as u32).to_be_bytes()).await?;
            stream.write_all(&data).await?;
            stream.flush().await
        })
        .await;
        match written {
            Ok(Ok(())) => {
                *used = Instant::now();
                return Ok(Value::Null);
            }
            failed => {
                *slot = None;
                if attempt == 1 {
                    return match failed {
                        Ok(Err(error)) => Err(error).context("send over Tor"),
                        _ => Err(anyhow!("sending over Tor timed out")),
                    };
                }
            }
        }
    }
    unreachable!()
}
