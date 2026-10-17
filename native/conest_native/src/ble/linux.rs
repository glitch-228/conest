//! BlueZ GATT server + central. USB adapters use the same OS API.
use std::{
    collections::{HashMap, VecDeque, hash_map::DefaultHasher},
    hash::{Hash, Hasher},
    sync::{
        Arc, Mutex,
        atomic::{AtomicUsize, Ordering},
    },
    time::Duration,
};

use anyhow::{Context, bail};
use bluer::{
    Adapter, AdapterEvent, Address, Device, DiscoveryFilter, DiscoveryTransport, Uuid,
    adv::Advertisement,
    gatt::{
        CharacteristicWriter,
        local::{
            Application, Characteristic, CharacteristicControlEvent, CharacteristicNotify,
            CharacteristicNotifyMethod, CharacteristicWrite, CharacteristicWriteMethod, ReqError,
            Service, characteristic_control,
        },
    },
};
use futures_util::{FutureExt, StreamExt, future::join_all, stream::BoxStream};
use tokio::{
    io::AsyncReadExt,
    task::JoinSet,
    time::{interval, timeout},
};

use super::{
    CHARACTERISTIC_UUID, PERIPHERAL_WARNING, SERVICE_UUID, Shared,
    core::{MAX_LINKS, MAX_PACKET, Role},
};

fn peer(address: Address) -> u64 {
    u64::from_be_bytes([
        0,
        0,
        address.0[0],
        address.0[1],
        address.0[2],
        address.0[3],
        address.0[4],
        address.0[5],
    ])
}

async fn adapter(session: &bluer::Session) -> anyhow::Result<Adapter> {
    if let Ok(default) = session.default_adapter().await {
        if default.is_powered().await.unwrap_or(false) {
            return Ok(default);
        }
    }
    for name in session.adapter_names().await?.into_iter().take(32) {
        let adapter = session.adapter(&name)?;
        if adapter.is_powered().await.unwrap_or(false) {
            return Ok(adapter);
        }
    }
    bail!("Bluetooth is off or no Bluetooth adapter is available. Turn it on in system settings.")
}

pub async fn run(state: Arc<Shared>) -> anyhow::Result<()> {
    let session = bluer::Session::new()
        .await
        .context("Bluetooth needs the BlueZ service running")?;
    let adapter = adapter(&session).await?;
    let local = adapter.address().await?;
    {
        let mut core = state.core();
        core.set_local(peer(local));
        core.status.adapter = Some(adapter.name().to_string());
        core.status.powered = true;
        core.status.central = true;
        core.status.problem = None;
    }
    let (control, handle) = characteristic_control();
    let write_state = state.clone();
    // The notification channel's MTU once a subscriber opened it (0: none).
    let hub_mtu = Arc::new(AtomicUsize::new(0));
    let write_hub_mtu = hub_mtu.clone();
    let app = Application {
        services: vec![Service {
            uuid: Uuid::from_u128(SERVICE_UUID),
            primary: true,
            characteristics: vec![Characteristic {
                uuid: Uuid::from_u128(CHARACTERISTIC_UUID),
                write: Some(CharacteristicWrite {
                    write: true,
                    write_without_response: true,
                    method: CharacteristicWriteMethod::Fun(Box::new(move |value, request| {
                        let state = write_state.clone();
                        let hub_mtu = write_hub_mtu.clone();
                        async move {
                            if request.offset != 0 || value.is_empty() || value.len() > MAX_PACKET {
                                return Err(ReqError::InvalidValueLength);
                            }
                            // Admitted by its writes: BlueZ may deliver the
                            // first before the subscription, and announces a
                            // subscription only for the first central.
                            let mut limit = usize::from(request.mtu).saturating_sub(3);
                            let hub = hub_mtu.load(Ordering::Acquire);
                            if hub > 0 {
                                limit = limit.min(hub);
                            }
                            let now = state.now();
                            let mut core = state.core();
                            let id = core
                                .admit_peripheral(peer(request.device_address), limit, now)
                                .ok_or(ReqError::NotPermitted)?;
                            core.receive(id, &value, now);
                            Ok(())
                        }
                        .boxed()
                    })),
                    ..Default::default()
                }),
                notify: Some(CharacteristicNotify {
                    notify: true,
                    method: CharacteristicNotifyMethod::Io,
                    ..Default::default()
                }),
                control_handle: handle,
                ..Default::default()
            }],
            ..Default::default()
        }],
        ..Default::default()
    };
    // Advertising is optional. Retain a working central if registration or
    // advertising is unsupported or denied by BlueZ policy.
    let app_handle = adapter.serve_gatt_application(app).await.ok();
    let advertisement = if app_handle.is_some() {
        adapter
            .advertise(Advertisement {
                service_uuids: [Uuid::from_u128(SERVICE_UUID)].into_iter().collect(),
                discoverable: Some(true),
                ..Default::default()
            })
            .await
            .ok()
    } else {
        None
    };
    {
        let mut core = state.core();
        core.status.peripheral = advertisement.is_some();
        if advertisement.is_none() {
            core.status.problem = Some(format!(
                "{PERIPHERAL_WARNING} Check BlueZ advertising support and Bluetooth permissions."
            ));
        }
    }
    // No service UUIDs in the filter (the mesh service is checked per device
    // below): BlueZ 5.87 calls a filter UUID as a function when a device
    // advertising any service is found (adapter.c is_filter_match passes
    // queue_find's arguments swapped; fixed upstream after 5.87), so
    // bluetoothd crashed every few seconds and dropped every other
    // Bluetooth device, headphones included.
    adapter
        .set_discovery_filter(DiscoveryFilter {
            transport: DiscoveryTransport::Le,
            duplicate_data: false,
            ..Default::default()
        })
        .await
        .context("Bluetooth scanning was refused; check Bluetooth permissions")?;

    let mut control = Box::pin(control);
    let mut discovery: Option<BoxStream<'static, AdapterEvent>> = None;
    let mut tasks = JoinSet::new();
    let mut tick = interval(Duration::from_millis(100));
    let mut powered_at = 0;
    // Devices this side connected to, so that stopping (or failing) closes
    // their connections: tasks dropped mid-way never reach their own close.
    let connected: Arc<Mutex<HashMap<Address, Device>>> = Arc::default();
    let mut hub: Option<tokio::task::AbortHandle> = None;
    let outcome: anyhow::Result<()> = async { loop {
        tokio::select! {
            _ = tick.tick() => {
                if state.stopped() { return Ok(()); }
                let now = state.now();
                state.core().expire(now);
                if now.saturating_sub(powered_at) >= 2000 {
                    powered_at = now;
                    if !adapter.is_powered().await? { bail!("Bluetooth is off. Turn it on in system settings."); }
                }
                // One discovery session for the whole run, not the 20 s in
                // every 30 the other platforms scan: BlueZ duty-cycles the
                // radio itself, and each restart is more D-Bus traffic.
                if discovery.is_none() {
                    discovery = Some(adapter.discover_devices().await.context("Bluetooth scanning is unavailable")?.boxed());
                    state.core().status.scanning = true;
                }
            }
            event = async { match &mut discovery { Some(d) => d.next().await, None => std::future::pending().await } } => {
                if let Some(AdapterEvent::DeviceAdded(address)) = event {
                    // JoinSet also counts retiring duplicate tasks until they
                    // finish, so crossed connections cannot grow OS workers.
                    if tasks.len() >= MAX_LINKS * 2 { continue; }
                    let device = adapter.device(address)?;
                    // A vanished or inaccessible candidate must not reset
                    // established neighbours on the adapter.
                    let Ok(Some(uuids)) = device.uuids().await else { continue; };
                    if !uuids.contains(&Uuid::from_u128(SERVICE_UUID)) { continue; }
                    let id = state.core().reserve(peer(address), Role::Central, state.now());
                    if let Some(id) = id {
                        connected.lock().unwrap_or_else(std::sync::PoisonError::into_inner).insert(address, device.clone());
                        tasks.spawn(central(state.clone(), device, id, connected.clone()));
                    }
                } else if event.is_none() {
                    bail!("Bluetooth scanning stopped. Check the adapter and BlueZ service.");
                }
            }
            event = control.next(), if app_handle.is_some() => {
                match event {
                    Some(CharacteristicControlEvent::Notify(writer)) => {
                        // One notification channel serves every subscribed
                        // central (BlueZ notifies all of them through it).
                        // bluer already subtracts its conservative ATT
                        // overhead from the writer's MTU.
                        hub_mtu.store(writer.mtu(), Ordering::Release);
                        let now = state.now();
                        let _ = state.core().admit_peripheral(peer(writer.device_address()), writer.mtu(), now);
                        if let Some(old) = hub.take() { old.abort(); }
                        hub = Some(tasks.spawn(notify_hub(state.clone(), writer, hub_mtu.clone())));
                    }
                    Some(CharacteristicControlEvent::Write(request)) => request.reject(ReqError::NotSupported),
                    None => bail!("Bluetooth GATT server stopped."),
                }
            }
            _ = tasks.join_next(), if !tasks.is_empty() => {}
        }
    } }.await;
    tasks.abort_all();
    let devices: Vec<Device> = connected
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .drain()
        .map(|(_, device)| device)
        .collect();
    let _ = timeout(
        Duration::from_millis(2500),
        join_all(devices.iter().map(|device| device.disconnect())),
    )
    .await;
    outcome
}

async fn central(
    state: Arc<Shared>,
    device: Device,
    id: u64,
    connected: Arc<Mutex<HashMap<Address, Device>>>,
) {
    let result: anyhow::Result<()> = async {
        let (characteristic, mut reader) = timeout(Duration::from_secs(15), async {
            if !device.is_connected().await? { device.connect().await?; }
            for service in device.services().await?.into_iter().take(64) {
                if service.uuid().await? != Uuid::from_u128(SERVICE_UUID) { continue; }
                for characteristic in service.characteristics().await?.into_iter().take(64) {
                    if characteristic.uuid().await? == Uuid::from_u128(CHARACTERISTIC_UUID) {
                        let reader = characteristic.notify_io().await?;
                        return Ok::<_, anyhow::Error>((characteristic, reader));
                    }
                }
            }
            bail!("Bluetooth neighbour has no mesh characteristic")
        }).await??;
        // AcquireNotify negotiates the symmetric ATT MTU before this point.
        if !state.core().ready(id, reader.mtu().saturating_sub(3)) { return Ok(()); }
        let mut tick = interval(Duration::from_millis(20));
        let mut buffer = [0; MAX_PACKET];
        loop {
            tokio::select! {
                read = reader.read(&mut buffer) => {
                    let count = read?;
                    if count == 0 { break; }
                    state.core().receive(id, &buffer[..count], state.now());
                }
                _ = tick.tick() => {
                    let next = {
                        let mut core = state.core();
                        if !core.contains(id) { break; }
                        core.take_write(id)
                    };
                    if let Some(bytes) = next { timeout(Duration::from_secs(5), characteristic.write(&bytes)).await??; }
                }
            }
        }
        Ok(())
    }.await;
    let disconnect = {
        let mut core = state.core();
        core.remove(id, result.is_err(), state.now());
        !core.has_peer(peer(device.address()))
    };
    if disconnect {
        connected
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .remove(&device.address());
        let _ = timeout(Duration::from_secs(2), device.disconnect()).await;
    }
}

/// Sends every subscribed central's packets through the one notification
/// channel BlueZ gives the first subscriber. Whatever goes in reaches every
/// subscriber; a packet queued for several links goes once.
async fn notify_hub(state: Arc<Shared>, writer: CharacteristicWriter, hub_mtu: Arc<AtomicUsize>) {
    let mut tick = interval(Duration::from_millis(20));
    let mut recent: VecDeque<(u64, u64)> = VecDeque::new();
    'serve: loop {
        tokio::select! {
            _ = writer.closed() => break,
            _ = tick.tick() => {
                let now = state.now();
                while recent.front().is_some_and(|(_, at)| now.saturating_sub(*at) > 2000) {
                    recent.pop_front();
                }
                let next: Vec<Vec<u8>> = {
                    let mut core = state.core();
                    core.role_links(Role::Peripheral)
                        .into_iter()
                        .filter_map(|id| core.take_write(id))
                        .collect()
                };
                for bytes in next {
                    if bytes.len() > writer.mtu() { continue; }
                    let mut hasher = DefaultHasher::new();
                    bytes.hash(&mut hasher);
                    let digest = hasher.finish();
                    if recent.iter().any(|(seen, _)| *seen == digest) { continue; }
                    if recent.len() >= 256 { recent.pop_front(); }
                    recent.push_back((digest, now));
                    if !matches!(timeout(Duration::from_secs(2), writer.send(&bytes)).await, Ok(Ok(()))) {
                        break 'serve;
                    }
                }
            }
        }
    }
    // Closed when the last central unsubscribed: its links have no way out.
    hub_mtu.store(0, Ordering::Release);
    let now = state.now();
    let mut core = state.core();
    for id in core.role_links(Role::Peripheral) {
        core.remove(id, false, now);
    }
}
