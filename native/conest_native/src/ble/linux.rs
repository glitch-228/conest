//! BlueZ GATT server + central. USB adapters use the same OS API.
use std::{sync::Arc, time::Duration};

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
use futures_util::{FutureExt, StreamExt, stream::BoxStream};
use tokio::{
    io::AsyncReadExt,
    task::JoinSet,
    time::{interval, timeout},
};

use super::{
    CHARACTERISTIC_UUID, PERIPHERAL_WARNING, SERVICE_UUID, Shared,
    core::{Core, MAX_LINKS, MAX_PACKET, Role},
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
        let mut core = state.core.lock().unwrap();
        core.set_local(peer(local));
        core.status.adapter = Some(adapter.name().to_string());
        core.status.powered = true;
        core.status.central = true;
        core.status.problem = None;
    }
    let (control, handle) = characteristic_control();
    let write_state = state.clone();
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
                        async move {
                            if request.offset != 0 || value.is_empty() || value.len() > MAX_PACKET {
                                return Err(ReqError::InvalidValueLength);
                            }
                            let mut core = state.core.lock().unwrap();
                            let id = core
                                .peer_link(peer(request.device_address), Role::Peripheral)
                                .ok_or(ReqError::NotPermitted)?;
                            core.receive(id, &value, state.now());
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
        let mut core = state.core.lock().unwrap();
        core.status.peripheral = advertisement.is_some();
        if advertisement.is_none() {
            core.status.problem = Some(format!(
                "{PERIPHERAL_WARNING} Check BlueZ advertising support and Bluetooth permissions."
            ));
        }
    }
    adapter
        .set_discovery_filter(DiscoveryFilter {
            uuids: [Uuid::from_u128(SERVICE_UUID)].into_iter().collect(),
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
    loop {
        tokio::select! {
            _ = tick.tick() => {
                let now = state.now();
                state.core.lock().unwrap().expire(now);
                if now.saturating_sub(powered_at) >= 2000 {
                    powered_at = now;
                    if !adapter.is_powered().await? { bail!("Bluetooth is off. Turn it on in system settings."); }
                }
                let scan = Core::scan_due(now);
                if scan && discovery.is_none() {
                    discovery = Some(adapter.discover_devices().await.context("Bluetooth scanning is unavailable")?.boxed());
                    state.core.lock().unwrap().status.scanning = true;
                } else if !scan && discovery.is_some() {
                    discovery = None;
                    state.core.lock().unwrap().status.scanning = false;
                }
            }
            event = async { match &mut discovery { Some(d) => d.next().await, None => std::future::pending().await } } => {
                if let Some(AdapterEvent::DeviceAdded(address)) = event {
                    // JoinSet also counts retiring duplicate tasks until they
                    // finish, so crossed connections cannot grow OS workers.
                    if tasks.len() >= MAX_LINKS * 2 { continue; }
                    let device = adapter.device(address)?;
                    if !device.uuids().await?.unwrap_or_default().contains(&Uuid::from_u128(SERVICE_UUID)) { continue; }
                    let id = state.core.lock().unwrap().reserve(peer(address), Role::Central, state.now());
                    if let Some(id) = id { tasks.spawn(central(state.clone(), device, id)); }
                } else if event.is_none() {
                    bail!("Bluetooth scanning stopped. Check the adapter and BlueZ service.");
                }
            }
            event = control.next(), if app_handle.is_some() => {
                match event {
                    Some(CharacteristicControlEvent::Notify(writer)) => {
                        if tasks.len() >= MAX_LINKS * 2 { continue; }
                        let id = state.core.lock().unwrap().reserve(peer(writer.device_address()), Role::Peripheral, state.now());
                        if let Some(id) = id {
                            // bluer already subtracts its conservative ATT
                            // overhead from the notification writer's MTU.
                            state.core.lock().unwrap().ready(id, writer.mtu());
                            tasks.spawn(peripheral(state.clone(), writer, id));
                        }
                    }
                    Some(CharacteristicControlEvent::Write(request)) => request.reject(ReqError::NotSupported),
                    None => bail!("Bluetooth GATT server stopped."),
                }
            }
            _ = tasks.join_next(), if !tasks.is_empty() => {}
        }
    }
}

async fn central(state: Arc<Shared>, device: Device, id: u64) {
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
        if !state.core.lock().unwrap().ready(id, reader.mtu().saturating_sub(3)) { return Ok(()); }
        let mut tick = interval(Duration::from_millis(20));
        let mut buffer = [0; MAX_PACKET];
        loop {
            tokio::select! {
                read = reader.read(&mut buffer) => {
                    let count = read?;
                    if count == 0 { break; }
                    state.core.lock().unwrap().receive(id, &buffer[..count], state.now());
                }
                _ = tick.tick() => {
                    let next = {
                        let mut core = state.core.lock().unwrap();
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
        let mut core = state.core.lock().unwrap();
        core.remove(id, result.is_err(), state.now());
        !core.has_peer(peer(device.address()))
    };
    if disconnect {
        let _ = timeout(Duration::from_secs(2), device.disconnect()).await;
    }
}

async fn peripheral(state: Arc<Shared>, writer: CharacteristicWriter, id: u64) {
    let mut tick = interval(Duration::from_millis(20));
    loop {
        tokio::select! {
            _ = writer.closed() => break,
            _ = tick.tick() => {
                let next = {
                    let mut core = state.core.lock().unwrap();
                    if !core.contains(id) { break; }
                    core.take_write(id)
                };
                if let Some(bytes) = next {
                    if !matches!(timeout(Duration::from_secs(2), writer.send(&bytes)).await, Ok(Ok(()))) { break; }
                }
            }
        }
    }
    state.core.lock().unwrap().remove(id, false, state.now());
}
