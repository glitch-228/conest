//! Full Matrix client (notes/MATRIX-CLIENT.md) over matrix-sdk.
//!
//! One client per process. Commands arrive as JSON through `call`, run on a
//! dedicated Tokio runtime and answer through the event queue, which a Dart
//! isolate drains with `next_event`. Nothing here blocks the caller beyond
//! queueing the command. The SDK store keeps sessions, sync position and
//! encryption keys; Dart owns only the access token copy in its vault.

use std::{
    collections::VecDeque,
    path::Path,
    sync::{Condvar, LazyLock, Mutex},
    time::Duration,
};

use anyhow::{Context, Result, anyhow};
use futures_util::StreamExt;
use matrix_sdk::encryption::verification::{
    SasState, SasVerification, Verification, VerificationRequest, VerificationRequestState,
};
use matrix_sdk::ruma::events::key::verification::request::ToDeviceKeyVerificationRequestEvent;
use matrix_sdk::{
    Client, RoomState, SessionChange, SessionMeta, SessionTokens,
    attachment::AttachmentConfig,
    authentication::{
        AuthSession,
        matrix::MatrixSession,
        oauth::{
            ClientId, ClientRegistrationData, CsrfToken, OAuthSession, UserSession,
            registration::{ApplicationType, ClientMetadata, Localized, OAuthGrantType},
        },
    },
    reqwest::Url,
    config::SyncSettings,
    media::{MediaFormat, MediaRequestParameters, MediaThumbnailSettings},
    room::MessagesOptions,
    ruma::{
        OwnedDeviceId, OwnedEventId, OwnedRoomId, OwnedUserId, TransactionId, UInt,
        api::client::{
            receipt::create_receipt::v3::ReceiptType,
            uiaa,
            to_device::send_event_to_device::v3::Request as ToDeviceRequest,
        },
        events::{
            ToDeviceEventType,
            receipt::ReceiptThread,
            room::{MediaSource, member::MembershipState, message::RoomMessageEventContent},
        },
        serde::Raw,
        to_device::DeviceIdOrAllDevices,
    },
    store::RoomLoadSettings,
};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use tokio::{runtime::Runtime, sync::broadcast::error::RecvError, task::JoinHandle};

static RUNTIME: LazyLock<Runtime> =
    LazyLock::new(|| Runtime::new().expect("create Conest Matrix Tokio runtime"));
static CLIENT: LazyLock<Mutex<Option<Client>>> = LazyLock::new(|| Mutex::new(None));
static SYNC_TASK: LazyLock<Mutex<Option<JoinHandle<()>>>> = LazyLock::new(|| Mutex::new(None));
static SESSION_TASK: LazyLock<Mutex<Option<JoinHandle<()>>>> = LazyLock::new(|| Mutex::new(None));
/// A browser sign-in between `oauth_start` and `oauth_finish`, with the
/// name of the store it opened.
static PENDING_OAUTH: LazyLock<Mutex<Option<(Client, CsrfToken, String)>>> =
    LazyLock::new(|| Mutex::new(None));
/// The store of the installed client, relative to the caller's store root.
/// Empty for a session from before per-login stores (the root itself).
static STORE_NAME: LazyLock<Mutex<String>> = LazyLock::new(|| Mutex::new(String::new()));
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

/// Each fresh login gets its own store under the root: the crypto store is
/// bound to one account and device, and a store left by an earlier session
/// would refuse the new one.
fn fresh_store(request: &Value) -> Result<String> {
    let root = Path::new(text(request, "storePath")?);
    let name = format!("s{}", TransactionId::new());
    std::fs::create_dir_all(root.join(&name))?;
    Ok(name)
}

/// Removes every store under the root except `keep`. Best effort: a store
/// still open on some platforms is retried at the next login.
fn prune_stores(request: &Value, keep: &str) {
    let Ok(root) = text(request, "storePath") else {
        return;
    };
    let Ok(entries) = std::fs::read_dir(root) else {
        return;
    };
    for entry in entries.flatten() {
        if entry.file_name().to_str() == Some(keep) {
            continue;
        }
        let path = entry.path();
        let _ = if path.is_dir() {
            std::fs::remove_dir_all(&path)
        } else {
            std::fs::remove_file(&path)
        };
    }
}

async fn build_client(request: &Value, homeserver: &str, store: &str) -> Result<Client> {
    let path = Path::new(text(request, "storePath")?).join(store);
    Ok(Client::builder()
        .homeserver_url(homeserver)
        .sqlite_store(path, Some(text(request, "passphrase")?))
        .handle_refresh_tokens()
        .build()
        .await?)
}

fn session_json(client: &Client) -> Result<Value> {
    let meta = client.session_meta().context("no Matrix session")?;
    let tokens = client.session_tokens().context("no Matrix session")?;
    let mut session = json!({
        "homeserver": client.homeserver().to_string(),
        "userId": meta.user_id.to_string(),
        "deviceId": meta.device_id.to_string(),
        "accessToken": tokens.access_token,
        "refreshToken": tokens.refresh_token,
    });
    if let Ok(store) = STORE_NAME.lock() {
        session["store"] = json!(*store);
    }
    // Browser sign-ins also need the registered client to refresh tokens.
    if let Some(client_id) = client.oauth().client_id().map(|id| id.as_str().to_owned()) {
        session["oauthClientId"] = json!(client_id);
    }
    Ok(session)
}

/// What the account server shows on its consent screen. A native client
/// receives the code on a loopback redirect (RFC 8252), on every platform.
fn oauth_registration(redirect_uri: &Url) -> Result<ClientRegistrationData> {
    let mut metadata = ClientMetadata::new(
        ApplicationType::Native,
        vec![OAuthGrantType::AuthorizationCode {
            redirect_uris: vec![redirect_uri.clone()],
        }],
        Localized::new(Url::parse("https://github.com/glitch-228/conest")?, []),
    );
    metadata.client_name = Some(Localized::new("Conest".to_owned(), []));
    Ok(Raw::new(&metadata)?.into())
}

fn install(client: Client, store: String) -> Result<()> {
    stop_sync();
    *STORE_NAME
        .lock()
        .map_err(|_| anyhow!("Matrix store lock poisoned"))? = store;
    // Another of the user's sessions asks to verify this one.
    client.add_event_handler(|event: ToDeviceKeyVerificationRequestEvent| async move {
        push_event(json!({
            "type": "verification_request",
            "userId": event.sender.to_string(),
            "flowId": event.content.transaction_id.to_string(),
            "fromDevice": event.content.from_device.to_string(),
        }));
    });
    // Refreshed tokens must reach the vault copy, or a restart would restore
    // a dead token; a refused refresh means the session is gone.
    let mut changes = client.subscribe_to_session_changes();
    let watcher = client.clone();
    let task = RUNTIME.spawn(async move {
        loop {
            let change = match changes.recv().await {
                Ok(change) => change,
                Err(RecvError::Lagged(_)) => continue,
                Err(RecvError::Closed) => break,
            };
            match change {
                SessionChange::TokensRefreshed => {
                    if let Ok(session) = session_json(&watcher) {
                        push_event(json!({"type": "session", "session": session}));
                    }
                }
                SessionChange::UnknownToken(_) => {
                    push_event(json!({"type": "session_revoked"}));
                }
            }
        }
    });
    replace_task(&SESSION_TASK, Some(task));
    *CLIENT
        .lock()
        .map_err(|_| anyhow!("Matrix client lock poisoned"))? = Some(client);
    Ok(())
}

fn stop_sync() {
    replace_task(&SYNC_TASK, None);
}

fn replace_task(slot: &Mutex<Option<JoinHandle<()>>>, next: Option<JoinHandle<()>>) {
    if let Ok(mut task) = slot.lock() {
        if let Some(handle) = std::mem::replace(&mut *task, next) {
            handle.abort();
        }
    }
}

fn take_pending_oauth() -> Option<(Client, CsrfToken, String)> {
    PENDING_OAUTH.lock().ok()?.take()
}

/// Drops the installed client and deletes its store: after a sign-out, a
/// revoked session, or when the user gives up on an unreachable server.
async fn forget(request: &Value) {
    stop_sync();
    replace_task(&SESSION_TASK, None);
    if let Some((pending, state, _)) = take_pending_oauth() {
        pending.oauth().abort_login(&state).await;
    }
    if let Ok(mut client) = CLIENT.lock() {
        *client = None;
    }
    let store = STORE_NAME
        .lock()
        .map(|mut name| std::mem::take(&mut *name))
        .unwrap_or_default();
    if !store.is_empty() {
        if let Ok(root) = text(request, "storePath") {
            let _ = std::fs::remove_dir_all(Path::new(root).join(store));
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
            let store = fresh_store(request)?;
            let client = build_client(request, text(request, "homeserver")?, &store).await?;
            let mut login = client
                .matrix_auth()
                .login_username(text(request, "user")?, text(request, "password")?)
                .initial_device_display_name(request["displayName"].as_str().unwrap_or("Conest"));
            if let Some(device_id) = request["deviceId"].as_str() {
                login = login.device_id(device_id);
            }
            login.send().await?;
            install(client.clone(), store.clone())?;
            prune_stores(request, &store);
            session_json(&client)
        }
        "oauth_start" => {
            if let Some((pending, state, _)) = take_pending_oauth() {
                pending.oauth().abort_login(&state).await;
            }
            let store = fresh_store(request)?;
            let client = build_client(request, text(request, "homeserver")?, &store).await?;
            let redirect_uri = Url::parse(text(request, "redirectUri")?)?;
            let device_id = request["deviceId"].as_str().map(OwnedDeviceId::from);
            let registration = oauth_registration(&redirect_uri)?;
            let authorization = client
                .oauth()
                .login(redirect_uri, device_id, Some(registration), None)
                .build()
                .await?;
            *PENDING_OAUTH
                .lock()
                .map_err(|_| anyhow!("Matrix sign-in lock poisoned"))? =
                Some((client, authorization.state, store));
            Ok(json!({"url": authorization.url.to_string()}))
        }
        "oauth_finish" => {
            let (client, _, store) =
                take_pending_oauth().context("no browser sign-in in progress")?;
            let callback = Url::parse(text(request, "callbackUrl")?)?;
            client.oauth().finish_login(callback.into()).await?;
            install(client.clone(), store.clone())?;
            prune_stores(request, &store);
            session_json(&client)
        }
        "oauth_abort" => {
            if let Some((pending, state, _)) = take_pending_oauth() {
                pending.oauth().abort_login(&state).await;
            }
            Ok(json!({}))
        }
        "restore" => {
            let session = &request["session"];
            let store = session["store"].as_str().unwrap_or_default().to_owned();
            let client = build_client(request, text(session, "homeserver")?, &store).await?;
            let user_id: OwnedUserId = text(session, "userId")?.parse()?;
            let device_id: OwnedDeviceId = text(session, "deviceId")?.into();
            let meta = SessionMeta { user_id, device_id };
            let tokens = SessionTokens {
                access_token: text(session, "accessToken")?.to_owned(),
                refresh_token: session["refreshToken"].as_str().map(str::to_owned),
            };
            let auth: AuthSession = match session["oauthClientId"].as_str() {
                Some(client_id) => OAuthSession {
                    client_id: ClientId::new(client_id.to_owned()),
                    user: UserSession { meta, tokens },
                }
                .into(),
                None => MatrixSession { meta, tokens }.into(),
            };
            client
                .restore_session_with(auth, RoomLoadSettings::default())
                .await?;
            install(client.clone(), store)?;
            session_json(&client)
        }
        "start_sync" => {
            // Replacing aborts the previous loop: two overlapping starts must
            // not leave a detached loop delivering every event twice.
            let handle = RUNTIME.spawn(sync_loop(client()?));
            replace_task(&SYNC_TASK, Some(handle));
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
            // Written aside and renamed, so a partial file never looks done.
            let path = text(request, "path")?;
            let partial = format!("{path}.part");
            tokio::fs::write(&partial, &data).await?;
            tokio::fs::rename(&partial, path).await?;
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
        "recovery_state" => {
            let client = client()?;
            let encryption = client.encryption();
            let cross_signing = encryption.cross_signing_status().await;
            Ok(json!({
                "recovery": format!("{:?}", encryption.recovery().state()),
                "crossSigning": cross_signing.map(|status| status.is_complete()).unwrap_or(false),
            }))
        }
        "enable_recovery" => {
            // Creates cross-signing keys if the account has none, then secret
            // storage and key backup; the returned key is the only way to
            // read history on a new device without another signed-in one.
            let client = client()?;
            let encryption = client.encryption();
            if encryption.secret_storage().is_enabled().await? {
                // A new store would replace the key the user already has.
                return Err(anyhow!(
                    "this account already has recovery set up; enter its recovery key \
                     or verify with another session"
                ));
            }
            if let Err(error) = encryption.bootstrap_cross_signing_if_needed(None).await {
                // Servers without MSC3967 ask for the password even for the
                // first cross-signing keys.
                let (Some(info), Some(password)) =
                    (error.as_uiaa_response(), request["password"].as_str())
                else {
                    return Err(match error.as_uiaa_response() {
                        Some(_) => anyhow!("M_CONEST_NEEDS_PASSWORD: the server asks for your password"),
                        None => error.into(),
                    });
                };
                let user = client.user_id().context("no Matrix session")?.to_string();
                let mut auth = uiaa::Password::new(
                    uiaa::UserIdentifier::Matrix(uiaa::MatrixUserIdentifier::new(user)),
                    password.to_owned(),
                );
                auth.session = info.session.clone();
                encryption
                    .bootstrap_cross_signing(Some(uiaa::AuthData::Password(auth)))
                    .await?;
            }
            let complete = encryption
                .cross_signing_status()
                .await
                .is_some_and(|status| status.is_complete());
            if !complete {
                return Err(anyhow!(
                    "this session does not hold the account's signing keys; \
                     verify it with another session first"
                ));
            }
            let key = encryption.recovery().enable().await?;
            Ok(json!({"recoveryKey": key}))
        }
        "recover" => {
            client()?
                .encryption()
                .recovery()
                .recover(text(request, "recoveryKey")?)
                .await?;
            Ok(json!({}))
        }
        "verify_own_session" => {
            // Ask another signed-in session of this account to verify us.
            let client = client()?;
            let user_id = client.user_id().context("not signed in")?.to_owned();
            let identity = client
                .encryption()
                .get_user_identity(&user_id)
                .await?
                .context("set up recovery or cross-signing first")?;
            let request = identity.request_verification().await?;
            let flow_id = request.flow_id().to_owned();
            RUNTIME.spawn(watch_request(request));
            Ok(json!({"flowId": flow_id}))
        }
        "verification_accept" => {
            let request = verification_request(request).await?;
            request.accept().await?;
            RUNTIME.spawn(watch_request(request));
            Ok(json!({}))
        }
        "verification_start_sas" => {
            let request = verification_request(request).await?;
            let flow_id = request.flow_id().to_owned();
            let sas = request
                .start_sas()
                .await?
                .context("the other session does not support emoji verification")?;
            RUNTIME.spawn(watch_sas(flow_id, sas));
            Ok(json!({}))
        }
        "verification_confirm" | "verification_mismatch" => {
            let client = client()?;
            let user_id: OwnedUserId = text(request, "userId")?.parse()?;
            let verification = client
                .encryption()
                .get_verification(&user_id, text(request, "flowId")?)
                .await
                .context("unknown verification")?;
            #[allow(irrefutable_let_patterns)]
            let Verification::SasV1(sas) = verification else {
                return Err(anyhow!("not an emoji verification"));
            };
            if op == "verification_confirm" {
                sas.confirm().await?;
            } else {
                sas.mismatch().await?;
            }
            Ok(json!({}))
        }
        "verification_cancel" => {
            verification_request(request).await?.cancel().await?;
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
            // Reuses the direct chat with this user when there is one, as
            // other Matrix apps do, instead of opening another room.
            let user_id: OwnedUserId = text(request, "userId")?.parse()?;
            let client = client()?;
            let mut existing = None;
            if let Some(room) = client.get_dm_room(&user_id) {
                // Only a chat both sides are still in: a message to a DM the
                // other person left would never reach them.
                let theirs = room.get_member_no_sync(&user_id).await?;
                let they_are_in = theirs.is_some_and(|member| {
                    matches!(
                        member.membership(),
                        MembershipState::Join | MembershipState::Invite
                    )
                });
                if room.state() == RoomState::Joined && they_are_in {
                    existing = Some(room);
                }
            }
            let room = match existing {
                Some(room) => room,
                None => client.create_dm(&user_id).await?,
            };
            Ok(json!({"roomId": room.room_id().to_string()}))
        }
        "logout" => {
            // The local session goes only once the server has revoked it;
            // otherwise the caller still holds a token it can retry with.
            client()?.logout().await?;
            forget(request).await;
            Ok(json!({}))
        }
        "forget" => {
            forget(request).await;
            Ok(json!({}))
        }
        other => Err(anyhow!("unknown Matrix operation {other}")),
    }
}

async fn verification_request(request: &Value) -> Result<VerificationRequest> {
    let user_id: OwnedUserId = text(request, "userId")?.parse()?;
    client()?
        .encryption()
        .get_verification_request(&user_id, text(request, "flowId")?)
        .await
        .context("unknown verification request")
}

/// Reports a request's progress; when it becomes emoji verification, hands
/// over to [`watch_sas`].
async fn watch_request(request: VerificationRequest) {
    let flow_id = request.flow_id().to_owned();
    let mut changes = request.changes();
    while let Some(state) = changes.next().await {
        match state {
            VerificationRequestState::Ready { .. } => {
                push_event(json!({"type": "verification", "flowId": flow_id, "state": "ready"}));
            }
            VerificationRequestState::Transitioned { verification } => {
                match verification {
                    Verification::SasV1(sas) => {
                        RUNTIME.spawn(watch_sas(flow_id.clone(), sas));
                    }
                    #[allow(unreachable_patterns)]
                    _ => {}
                }
                return;
            }
            VerificationRequestState::Done => {
                push_event(json!({"type": "verification", "flowId": flow_id, "state": "done"}));
                return;
            }
            VerificationRequestState::Cancelled(info) => {
                push_event(json!({
                    "type": "verification", "flowId": flow_id, "state": "cancelled",
                    "reason": info.reason(),
                }));
                return;
            }
            _ => {}
        }
    }
}

/// Emoji verification: accepts one the other side started, then reports
/// the emojis to compare and the outcome.
async fn watch_sas(flow_id: String, sas: SasVerification) {
    if !sas.we_started() {
        if let Err(error) = sas.accept().await {
            push_event(json!({
                "type": "verification", "flowId": flow_id, "state": "cancelled",
                "reason": format!("{error:#}"),
            }));
            return;
        }
    }
    let mut changes = sas.changes();
    while let Some(state) = changes.next().await {
        match state {
            SasState::KeysExchanged { emojis, .. } => {
                let emojis: Vec<Value> = emojis
                    .map(|short| {
                        short
                            .emojis
                            .iter()
                            .map(|emoji| json!({"symbol": emoji.symbol, "description": emoji.description}))
                            .collect()
                    })
                    .unwrap_or_default();
                push_event(json!({
                    "type": "verification", "flowId": flow_id, "state": "emojis",
                    "userId": sas.other_user_id().to_string(),
                    "emojis": emojis,
                }));
            }
            SasState::Done { .. } => {
                push_event(json!({"type": "verification", "flowId": flow_id, "state": "done"}));
                return;
            }
            SasState::Cancelled(info) => {
                push_event(json!({
                    "type": "verification", "flowId": flow_id, "state": "cancelled",
                    "reason": info.reason(),
                }));
                return;
            }
            _ => {}
        }
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
