//! Full Matrix client (notes/MATRIX-CLIENT.md) over matrix-sdk.
//!
//! One client per process. Commands arrive as JSON through `call`, run on a
//! dedicated Tokio runtime and answer through the event queue, which a Dart
//! isolate drains with `next_event`. Nothing here blocks the caller beyond
//! queueing the command. The SDK store keeps sessions, sync position and
//! encryption keys; Dart owns only the access token copy in its vault.

use std::{
    collections::VecDeque,
    sync::{Condvar, LazyLock, Mutex},
    time::Duration,
};

use anyhow::{Context, Result, anyhow};
use matrix_sdk::{
    Client, SessionMeta, SessionTokens,
    attachment::AttachmentConfig,
    authentication::matrix::MatrixSession,
    config::SyncSettings,
    media::{MediaFormat, MediaRequestParameters, MediaThumbnailSettings},
    room::MessagesOptions,
    ruma::{
        OwnedDeviceId, OwnedEventId, OwnedRoomId, OwnedUserId, TransactionId, UInt,
        api::client::{
            receipt::create_receipt::v3::ReceiptType,
            to_device::send_event_to_device::v3::Request as ToDeviceRequest,
        },
        events::{
            ToDeviceEventType,
            receipt::ReceiptThread,
            room::{MediaSource, message::RoomMessageEventContent},
        },
        serde::Raw,
        to_device::DeviceIdOrAllDevices,
    },
    store::RoomLoadSettings,
};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use tokio::{runtime::Runtime, task::JoinHandle};

static RUNTIME: LazyLock<Runtime> =
    LazyLock::new(|| Runtime::new().expect("create Conest Matrix Tokio runtime"));
static CLIENT: LazyLock<Mutex<Option<Client>>> = LazyLock::new(|| Mutex::new(None));
static SYNC_TASK: LazyLock<Mutex<Option<JoinHandle<()>>>> = LazyLock::new(|| Mutex::new(None));
static EVENTS: LazyLock<(Mutex<VecDeque<String>>, Condvar)> =
    LazyLock::new(|| (Mutex::new(VecDeque::new()), Condvar::new()));

/// Bound on queued events: a stalled reader must not grow memory without end.
const MAX_QUEUED_EVENTS: usize = 4096;

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

/// Waits up to `timeout` for the next event.
pub fn next_event(timeout: Duration) -> Option<String> {
    let (queue, ready) = &*EVENTS;
    let guard = queue.lock().ok()?;
    let (mut guard, _) = ready
        .wait_timeout_while(guard, timeout, |queue| queue.is_empty())
        .ok()?;
    guard.pop_front()
}

/// Queues one command. Returns at once; the outcome arrives as a `result`
/// event carrying the command's `requestId`.
pub fn call(request: Value) -> Result<()> {
    let op = request["op"]
        .as_str()
        .context("missing Matrix operation")?
        .to_owned();
    let request_id = request["requestId"].as_str().unwrap_or_default().to_owned();
    RUNTIME.spawn(async move {
        let outcome = run(&op, &request).await;
        push_event(match outcome {
            Ok(value) => json!({"type": "result", "requestId": request_id, "ok": true, "value": value}),
            Err(error) => {
                json!({"type": "result", "requestId": request_id, "ok": false, "error": format!("{error:#}")})
            }
        });
    });
    Ok(())
}

fn client() -> Result<Client> {
    CLIENT
        .lock()
        .map_err(|_| anyhow!("Matrix client lock poisoned"))?
        .clone()
        .context("not signed in to Matrix")
}

fn text<'a>(request: &'a Value, field: &str) -> Result<&'a str> {
    request[field]
        .as_str()
        .with_context(|| format!("missing Matrix field {field}"))
}

async fn build_client(request: &Value, homeserver: &str) -> Result<Client> {
    Ok(Client::builder()
        .homeserver_url(homeserver)
        .sqlite_store(
            text(request, "storePath")?,
            Some(text(request, "passphrase")?),
        )
        .build()
        .await?)
}

fn session_json(client: &Client) -> Result<Value> {
    let session = client
        .matrix_auth()
        .session()
        .context("no Matrix session")?;
    Ok(json!({
        "homeserver": client.homeserver().to_string(),
        "userId": session.meta.user_id.to_string(),
        "deviceId": session.meta.device_id.to_string(),
        "accessToken": session.tokens.access_token,
        "refreshToken": session.tokens.refresh_token,
    }))
}

fn install(client: Client) -> Result<()> {
    stop_sync();
    *CLIENT
        .lock()
        .map_err(|_| anyhow!("Matrix client lock poisoned"))? = Some(client);
    Ok(())
}

fn stop_sync() {
    if let Ok(mut task) = SYNC_TASK.lock() {
        if let Some(handle) = task.take() {
            handle.abort();
        }
    }
}

fn room(client: &Client, request: &Value) -> Result<matrix_sdk::Room> {
    let room_id: OwnedRoomId = text(request, "roomId")?.parse()?;
    client.get_room(&room_id).context("unknown Matrix room")
}

async fn room_summary(room: &matrix_sdk::Room, invited: bool) -> Value {
    let counts = room.unread_notification_counts();
    json!({
        "roomId": room.room_id().to_string(),
        "name": room.display_name().await.map(|name| name.to_string()).unwrap_or_default(),
        "direct": room.is_direct().await.unwrap_or(false),
        "encrypted": room.encryption_state().is_encrypted(),
        "invited": invited,
        "unread": counts.notification_count,
        "highlight": counts.highlight_count,
    })
}

async fn run(op: &str, request: &Value) -> Result<Value> {
    match op {
        "login_password" => {
            let client = build_client(request, text(request, "homeserver")?).await?;
            let mut login = client
                .matrix_auth()
                .login_username(text(request, "user")?, text(request, "password")?)
                .initial_device_display_name(request["displayName"].as_str().unwrap_or("Conest"));
            if let Some(device_id) = request["deviceId"].as_str() {
                login = login.device_id(device_id);
            }
            login.send().await?;
            let session = session_json(&client)?;
            install(client)?;
            Ok(session)
        }
        "restore" => {
            let session = &request["session"];
            let client = build_client(request, text(session, "homeserver")?).await?;
            let user_id: OwnedUserId = text(session, "userId")?.parse()?;
            let device_id: OwnedDeviceId = text(session, "deviceId")?.into();
            client
                .matrix_auth()
                .restore_session(
                    MatrixSession {
                        meta: SessionMeta { user_id, device_id },
                        tokens: SessionTokens {
                            access_token: text(session, "accessToken")?.to_owned(),
                            refresh_token: session["refreshToken"].as_str().map(str::to_owned),
                        },
                    },
                    RoomLoadSettings::default(),
                )
                .await?;
            let restored = session_json(&client)?;
            install(client)?;
            Ok(restored)
        }
        "start_sync" => {
            let client = client()?;
            stop_sync();
            let handle = RUNTIME.spawn(sync_loop(client));
            *SYNC_TASK
                .lock()
                .map_err(|_| anyhow!("Matrix sync lock poisoned"))? = Some(handle);
            Ok(json!({}))
        }
        "stop_sync" => {
            stop_sync();
            Ok(json!({}))
        }
        "rooms" => {
            let client = client()?;
            let mut rooms = Vec::new();
            for room in client.joined_rooms() {
                rooms.push(room_summary(&room, false).await);
            }
            for room in client.invited_rooms() {
                rooms.push(room_summary(&room, true).await);
            }
            Ok(json!({"rooms": rooms}))
        }
        "messages" => {
            let room = room(&client()?, request)?;
            let mut options = MessagesOptions::backward();
            options.limit = UInt::from(request["limit"].as_u64().unwrap_or(30).min(100) as u32);
            options.from = request["from"].as_str().map(str::to_owned);
            let page = room.messages(options).await?;
            let events: Vec<Value> = page
                .chunk
                .iter()
                .filter_map(|event| serde_json::from_str(event.raw().json().get()).ok())
                .collect();
            Ok(json!({"events": events, "end": page.end}))
        }
        "send_text" => {
            let room = room(&client()?, request)?;
            let sent = room
                .send(RoomMessageEventContent::text_plain(text(request, "body")?))
                .await?;
            Ok(json!({"eventId": sent.response.event_id.to_string()}))
        }
        "send_raw" => {
            // Any message-like event (replies, edits, reactions); the SDK
            // encrypts it in encrypted rooms.
            let room = room(&client()?, request)?;
            let sent = room
                .send_raw(text(request, "type")?, request["content"].clone())
                .await?;
            Ok(json!({"eventId": sent.response.event_id.to_string()}))
        }
        "redact" => {
            let room = room(&client()?, request)?;
            let event_id: OwnedEventId = text(request, "eventId")?.parse()?;
            room.redact(&event_id, request["reason"].as_str(), None)
                .await?;
            Ok(json!({}))
        }
        "read_receipt" => {
            let room = room(&client()?, request)?;
            let event_id: OwnedEventId = text(request, "eventId")?.parse()?;
            room.send_single_receipt(ReceiptType::Read, ReceiptThread::Unthreaded, event_id)
                .await?;
            Ok(json!({}))
        }
        "member" => {
            let room = room(&client()?, request)?;
            let user_id: OwnedUserId = text(request, "userId")?.parse()?;
            let member = room.get_member(&user_id).await?;
            Ok(json!({
                "displayName": member.as_ref().and_then(|member| member.display_name().map(str::to_owned)),
                "avatarUrl": member.as_ref().and_then(|member| member.avatar_url().map(ToString::to_string)),
            }))
        }
        "send_file" => {
            let room = room(&client()?, request)?;
            let data = tokio::fs::read(text(request, "path")?).await?;
            let mime: mime::Mime = request["mimeType"]
                .as_str()
                .unwrap_or("application/octet-stream")
                .parse()
                .unwrap_or(mime::APPLICATION_OCTET_STREAM);
            let response = room
                .send_attachment(text(request, "name")?, &mime, data, AttachmentConfig::new())
                .await?;
            Ok(json!({"eventId": response.event_id.to_string()}))
        }
        "download" => {
            // `source` is the event content's `url`/`file` pair; encrypted
            // files are decrypted by the SDK.
            let source: MediaSource = serde_json::from_value(request["source"].clone())?;
            let format = match (request["width"].as_u64(), request["height"].as_u64()) {
                (Some(width), Some(height)) => MediaFormat::Thumbnail(MediaThumbnailSettings::new(
                    UInt::from(width.min(2048) as u32),
                    UInt::from(height.min(2048) as u32),
                )),
                _ => MediaFormat::File,
            };
            let data = client()?
                .media()
                .get_media_content(&MediaRequestParameters { source, format }, true)
                .await?;
            tokio::fs::write(text(request, "path")?, &data).await?;
            Ok(json!({"bytes": data.len()}))
        }
        "send_to_device" => {
            // Plain to-device messages for the Conest carrier, which seals
            // its own payloads.
            let user_id: OwnedUserId = text(request, "userId")?.parse()?;
            let device_id: OwnedDeviceId = text(request, "deviceId")?.into();
            let content = Raw::from_json(serde_json::value::to_raw_value(&request["content"])?);
            let messages = BTreeMap::from([(
                user_id,
                BTreeMap::from([(DeviceIdOrAllDevices::DeviceId(device_id), content)]),
            )]);
            let transaction = request["transactionId"]
                .as_str()
                .map(Into::into)
                .unwrap_or_else(TransactionId::new);
            client()?
                .send(ToDeviceRequest::new_raw(
                    ToDeviceEventType::from(text(request, "type")?),
                    transaction,
                    messages,
                ))
                .await?;
            Ok(json!({}))
        }
        "join" => {
            room(&client()?, request)?.join().await?;
            Ok(json!({}))
        }
        "leave" => {
            room(&client()?, request)?.leave().await?;
            Ok(json!({}))
        }
        "create_dm" => {
            let user_id: OwnedUserId = text(request, "userId")?.parse()?;
            let room = client()?.create_dm(&user_id).await?;
            Ok(json!({"roomId": room.room_id().to_string()}))
        }
        "logout" => {
            stop_sync();
            let client = client()?;
            *CLIENT
                .lock()
                .map_err(|_| anyhow!("Matrix client lock poisoned"))? = None;
            client.logout().await?;
            Ok(json!({}))
        }
        other => Err(anyhow!("unknown Matrix operation {other}")),
    }
}

/// Keeps the store current and tells Dart which rooms changed. The SDK
/// persists the sync position itself, so a restart resumes where it was.
async fn sync_loop(client: Client) {
    let mut backoff = Duration::from_secs(2);
    loop {
        let settings = SyncSettings::default().timeout(Duration::from_secs(30));
        match client.sync_once(settings).await {
            Ok(response) => {
                backoff = Duration::from_secs(2);
                // New timeline events, already decrypted where keys exist.
                for (room_id, update) in &response.rooms.joined {
                    let events: Vec<Value> = update
                        .timeline
                        .events
                        .iter()
                        .filter_map(|event| serde_json::from_str(event.raw().json().get()).ok())
                        .collect();
                    if !events.is_empty() || update.timeline.limited {
                        push_event(json!({
                            "type": "timeline",
                            "roomId": room_id.to_string(),
                            "events": events,
                            "limited": update.timeline.limited,
                            "prevBatch": update.timeline.prev_batch,
                        }));
                    }
                }
                // Custom to-device messages (the Conest carrier); the SDK
                // consumes its own key-sharing traffic.
                for event in &response.to_device {
                    if let Ok(value) = serde_json::from_str::<Value>(event.as_raw().json().get()) {
                        if value["type"]
                            .as_str()
                            .is_some_and(|kind| kind.starts_with("dev.conest."))
                        {
                            push_event(json!({"type": "to_device", "event": value}));
                        }
                    }
                }
                let changed: Vec<String> = response
                    .rooms
                    .joined
                    .keys()
                    .chain(response.rooms.invited.keys())
                    .chain(response.rooms.left.keys())
                    .map(ToString::to_string)
                    .collect();
                push_event(json!({"type": "sync", "rooms": changed}));
            }
            Err(error) => {
                push_event(json!({"type": "sync_error", "error": format!("{error:#}")}));
                tokio::time::sleep(backoff).await;
                backoff = (backoff * 2).min(Duration::from_secs(60));
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{call, next_event};
    use serde_json::{Value, json};
    use std::time::Duration;

    fn result_for(request_id: &str) -> Value {
        for _ in 0..50 {
            if let Some(event) = next_event(Duration::from_millis(100)) {
                let value: Value = serde_json::from_str(&event).unwrap();
                if value["requestId"] == request_id {
                    return value;
                }
            }
        }
        panic!("no result for {request_id}");
    }

    /// One test: the event queue is process-wide, so parallel tests would
    /// consume each other's results.
    #[test]
    fn commands_fail_through_the_event_queue_without_a_session() {
        call(json!({"op": "rooms", "requestId": "r1"})).unwrap();
        let result = result_for("r1");
        assert_eq!(result["type"], "result");
        assert_eq!(result["ok"], false);
        assert!(result["error"].as_str().unwrap().contains("not signed in"));

        call(json!({"op": "nope", "requestId": "r2"})).unwrap();
        assert_eq!(result_for("r2")["ok"], false);
        assert!(call(json!({"requestId": "r3"})).is_err());
    }
}
