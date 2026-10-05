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

use std::{
    collections::{HashMap, VecDeque},
    sync::{Arc, Condvar, LazyLock, Mutex},
    time::Duration,
};

use anyhow::{Context, Result, anyhow};
use arti_client::{
    DataStream, TorClient,
    config::{
        BridgeConfigBuilder, CfgPath, TorClientConfigBuilder,
        onion_service::OnionServiceConfigBuilder, pt::TransportConfigBuilder,
    },
};
use base64::Engine;
use futures_util::StreamExt;
use safelog::DisplayRedacted;
use serde_json::{Value, json};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    runtime::Runtime,
    sync::Mutex as AsyncMutex,
    task::JoinHandle,
};
use tor_cell::relaycell::msg::Connected;
use tor_hsservice::{RunningOnionService, handle_rend_requests};
use tor_proto::stream::IncomingStreamRequest;
use tor_rtcompat::PreferredRuntime;

/// The virtual port of Conest's onion service.
pub const ONION_PORT: u16 = 7177;

/// Largest frame accepted on a stream.
pub const MAX_FRAME: usize = 1 << 20;

/// Idle outgoing streams are closed after this long.
const IDLE: Duration = Duration::from_secs(300);

static RUNTIME: LazyLock<Runtime> =
    LazyLock::new(|| Runtime::new().expect("create Conest Tor Tokio runtime"));
static EVENTS: LazyLock<(Mutex<VecDeque<String>>, Condvar)> =
    LazyLock::new(|| (Mutex::new(VecDeque::new()), Condvar::new()));
static STATE: LazyLock<Mutex<Option<TorState>>> = LazyLock::new(|| Mutex::new(None));
/// Outgoing streams by onion host, reused while they work.
static OUTGOING: LazyLock<AsyncMutex<HashMap<String, (DataStream, std::time::Instant)>>> =
    LazyLock::new(|| AsyncMutex::new(HashMap::new()));

const MAX_QUEUED_EVENTS: usize = 4096;

struct TorState {
    client: Arc<TorClient<PreferredRuntime>>,
    // Kept alive while the service runs.
    _service: Arc<RunningOnionService>,
    address: String,
    tasks: Vec<JoinHandle<()>>,
}

fn push_event(value: Value) {
    let (queue, ready) = &*EVENTS;
    if let Ok(mut queue) = queue.lock() {
        if queue.len() >= MAX_QUEUED_EVENTS {
            queue.pop_front();
        }
        queue.push_back(value.to_string());
        ready.notify_one();
    }
}

/// Waits up to `timeout` for the next event (JSON).
pub fn next_event(timeout: Duration) -> Option<String> {
    let (queue, ready) = &*EVENTS;
    let guard = queue.lock().ok()?;
    let (mut guard, _) = ready
        .wait_timeout_while(guard, timeout, |queue| queue.is_empty())
        .ok()?;
    guard.pop_front()
}

/// Queues one command; its outcome arrives as a `result` event carrying the
/// command's `requestId`.
pub fn call(request: Value) -> Result<()> {
    let op = request["op"]
        .as_str()
        .context("missing Tor operation")?
        .to_owned();
    let request_id = request["requestId"].as_str().unwrap_or_default().to_owned();
    RUNTIME.spawn(async move {
        let outcome = run(&op, &request).await;
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

/// Bootstraps Tor (through bridges when given) and launches the onion
/// service; answers with its address.
async fn start(request: &Value) -> Result<Value> {
    if let Some(address) = STATE
        .lock()
        .map_err(|_| anyhow!("Tor state poisoned"))?
        .as_ref()
        .map(|state| state.address.clone())
    {
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
    client.bootstrap().await.context("connect to Tor")?;

    let nickname = request["nickname"].as_str().unwrap_or("conest");
    let service_config = OnionServiceConfigBuilder::default()
        .nickname(nickname.parse().map_err(|error| anyhow!("bad nickname: {error}"))?)
        .build()
        .context("onion service configuration")?;
    let (service, requests) = client
        .launch_onion_service(service_config)
        .context("launch onion service")?
        .ok_or_else(|| anyhow!("onion services are disabled"))?;
    let address = service
        .onion_address()
        .ok_or_else(|| anyhow!("the onion service has no address yet"))?
        .display_unredacted()
        .to_string();
    let accept_task = RUNTIME.spawn(async move {
        let mut streams = handle_rend_requests(requests);
        while let Some(stream_request) = streams.next().await {
            let wanted = matches!(
                stream_request.request(),
                IncomingStreamRequest::Begin(begin) if begin.port() == ONION_PORT
            );
            if !wanted {
                let _ = stream_request.shutdown_circuit();
                continue;
            }
            RUNTIME.spawn(async move {
                if let Ok(stream) = stream_request.accept(Connected::new_empty()).await {
                    read_frames(stream).await;
                }
            });
        }
    });
    *STATE.lock().map_err(|_| anyhow!("Tor state poisoned"))? = Some(TorState {
        client,
        _service: service,
        address: address.clone(),
        tasks: vec![progress_task, accept_task],
    });
    Ok(json!({"address": address}))
}

async fn stop() {
    let state = STATE.lock().ok().and_then(|mut state| state.take());
    if let Some(state) = state {
        for task in state.tasks {
            task.abort();
        }
    }
    OUTGOING.lock().await.clear();
}

/// Reads length-prefixed frames from an incoming stream until it ends.
async fn read_frames(mut stream: DataStream) {
    let engine = base64::engine::general_purpose::STANDARD;
    loop {
        let mut header = [0u8; 4];
        if stream.read_exact(&mut header).await.is_err() {
            return;
        }
        let length = u32::from_be_bytes(header) as usize;
        if length == 0 || length > MAX_FRAME {
            return;
        }
        let mut frame = vec![0u8; length];
        if stream.read_exact(&mut frame).await.is_err() {
            return;
        }
        push_event(json!({"type": "frame", "data": engine.encode(&frame)}));
    }
}

/// Sends one frame to the onion service `onion` (a `.onion` host).
async fn send(request: &Value) -> Result<Value> {
    let onion = request["onion"].as_str().context("missing onion")?.to_owned();
    anyhow::ensure!(
        onion.ends_with(".onion") && onion.len() == 62,
        "not a v3 onion address"
    );
    let data = base64::engine::general_purpose::STANDARD
        .decode(request["data"].as_str().context("missing data")?)?;
    anyhow::ensure!(!data.is_empty() && data.len() <= MAX_FRAME, "frame size");
    let client = STATE
        .lock()
        .map_err(|_| anyhow!("Tor state poisoned"))?
        .as_ref()
        .map(|state| state.client.clone())
        .ok_or_else(|| anyhow!("Tor is not running"))?;
    let mut outgoing = OUTGOING.lock().await;
    outgoing.retain(|_, (_, used)| used.elapsed() < IDLE);
    // A cached stream may have died; one fresh attempt follows a failure.
    for attempt in 0..2 {
        if attempt == 1 || !outgoing.contains_key(&onion) {
            let stream = client
                .connect((onion.as_str(), ONION_PORT))
                .await
                .context("reach the contact's onion service")?;
            outgoing.insert(onion.clone(), (stream, std::time::Instant::now()));
        }
        let (stream, used) = outgoing.get_mut(&onion).expect("just inserted");
        let written = async {
            stream.write_all(&(data.len() as u32).to_be_bytes()).await?;
            stream.write_all(&data).await?;
            stream.flush().await
        }
        .await;
        match written {
            Ok(()) => {
                *used = std::time::Instant::now();
                return Ok(Value::Null);
            }
            Err(error) => {
                outgoing.remove(&onion);
                if attempt == 1 {
                    return Err(error).context("send over Tor");
                }
            }
        }
    }
    unreachable!()
}
