//! WinRT GATT peripheral and central. Callbacks only touch bounded state or
//! try a bounded channel; no task is spawned for an incoming notification.
use std::{sync::Arc, time::Duration};

use anyhow::{Context, bail};
use tokio::{
    sync::mpsc,
    task::JoinSet,
    time::{interval, timeout},
};
use windows::{
    Devices::{
        Bluetooth::{
            Advertisement::{
                BluetoothLEAdvertisementReceivedEventArgs, BluetoothLEAdvertisementWatcher,
                BluetoothLEAdvertisementWatcherStatus, BluetoothLEScanningMode,
            },
            BluetoothAdapter, BluetoothConnectionStatus, BluetoothError, BluetoothLEDevice,
            GenericAttributeProfile::*,
        },
        Enumeration::DeviceInformation,
        Radios::RadioState,
    },
    Foundation::{Deferral, TypedEventHandler},
    Storage::Streams::{DataReader, DataWriter, IBuffer},
    Win32::System::WinRT::{RO_INIT_MULTITHREADED, RoInitialize, RoUninitialize},
    core::{GUID, HSTRING},
};

use super::{
    CHARACTERISTIC_UUID, PERIPHERAL_WARNING, SERVICE_UUID, Shared,
    callbacks::{self, PeripheralAdapter, Subscribers},
    core::{Core, MAX_LINKS, MAX_PACKET, Role},
};

const SERVICE: GUID = GUID::from_u128(SERVICE_UUID);
const CHARACTERISTIC: GUID = GUID::from_u128(CHARACTERISTIC_UUID);

pub struct Apartment(bool);
impl Apartment {
    pub fn new() -> Self {
        // This is a fresh, dedicated native worker thread.
        Self(unsafe { RoInitialize(RO_INIT_MULTITHREADED) }.is_ok())
    }
}
impl Drop for Apartment {
    fn drop(&mut self) {
        if self.0 {
            unsafe {
                RoUninitialize();
            }
        }
    }
}

struct Cleanup(Option<Box<dyn FnOnce() + Send>>);
impl Drop for Cleanup {
    fn drop(&mut self) {
        if let Some(cleanup) = self.0.take() {
            cleanup();
        }
    }
}

struct Deferred(Deferral);
impl Drop for Deferred {
    fn drop(&mut self) {
        let _ = self.0.Complete();
    }
}

fn session_key(session: &GattSession) -> windows::core::Result<String> {
    let id = session.DeviceId()?.Id()?;
    if id.len() > 512 {
        return Err(windows::core::Error::from_hresult(windows::core::HRESULT(
            0x80070057_u32 as i32,
        )));
    }
    Ok(id.to_string())
}

fn bytes(buffer: &IBuffer) -> windows::core::Result<Option<Vec<u8>>> {
    let length = buffer.Length()? as usize;
    if length == 0 || length > MAX_PACKET {
        return Ok(None);
    }
    let mut bytes = vec![0; length];
    DataReader::FromBuffer(buffer)?.ReadBytes(&mut bytes)?;
    Ok(Some(bytes))
}

fn buffer(bytes: &[u8]) -> windows::core::Result<IBuffer> {
    let writer = DataWriter::new()?;
    writer.WriteBytes(bytes)?;
    writer.DetachBuffer()
}

async fn adapter() -> anyhow::Result<BluetoothAdapter> {
    if let Ok(default) = BluetoothAdapter::GetDefaultAsync()?.await {
        if default.GetRadioAsync()?.await?.State()? == RadioState::On {
            return Ok(default);
        }
    }
    let devices =
        DeviceInformation::FindAllAsyncAqsFilter(&BluetoothAdapter::GetDeviceSelector()?)?.await?;
    for index in 0..devices.Size()?.min(32) {
        let adapter = BluetoothAdapter::FromIdAsync(&devices.GetAt(index)?.Id()?)?.await?;
        if adapter.GetRadioAsync()?.await?.State()? == RadioState::On {
            return Ok(adapter);
        }
    }
    bail!("Bluetooth is off or no Bluetooth adapter is available. Turn it on in system settings.")
}

async fn peripheral(
    state: Arc<Shared>,
    requests: mpsc::Sender<(GattWriteRequestedEventArgs, Deferred)>,
) -> anyhow::Result<(GattLocalCharacteristic, GattServiceProvider, Cleanup)> {
    let result = GattServiceProvider::CreateAsync(SERVICE)?.await?;
    if result.Error()? != BluetoothError::Success {
        bail!("Windows refused the Bluetooth GATT server");
    }
    let provider = result.ServiceProvider()?;
    let params = GattLocalCharacteristicParameters::new()?;
    params.SetCharacteristicProperties(
        GattCharacteristicProperties::Write
            | GattCharacteristicProperties::WriteWithoutResponse
            | GattCharacteristicProperties::Notify,
    )?;
    params.SetWriteProtectionLevel(GattProtectionLevel::Plain)?;
    let result = provider
        .Service()?
        .CreateCharacteristicAsync(CHARACTERISTIC, &params)?
        .await?;
    if result.Error()? != BluetoothError::Success {
        bail!("Windows refused the Bluetooth mesh characteristic");
    }
    let characteristic = result.Characteristic()?;
    let handler = TypedEventHandler::<GattLocalCharacteristic, GattWriteRequestedEventArgs>::new(
        move |_, args| {
            if state.stopped() {
                return Ok(());
            }
            if let Some(args) = args.as_ref() {
                let deferred = Deferred(args.GetDeferral()?);
                // Include a newly subscribed client's very first write:
                // the periodic session snapshot may not have run yet.
                // The bounded queue completes rejected deferrals on drop.
                let _ = requests.try_send((args.clone(), deferred));
            }
            Ok(())
        },
    );
    let token = characteristic.WriteRequested(&handler)?;
    let cleanup_characteristic = characteristic.clone();
    let cleanup_provider = provider.clone();
    let guard = Cleanup(Some(Box::new(move || {
        let _ = cleanup_characteristic.RemoveWriteRequested(token);
        let _ = cleanup_provider.StopAdvertising();
    })));
    let parameters = GattServiceProviderAdvertisingParameters::new()?;
    parameters.SetIsConnectable(true)?;
    parameters.SetIsDiscoverable(true)?;
    provider.StartAdvertisingWithParameters(&parameters)?;
    Ok((characteristic, provider, guard))
}

pub async fn run(state: Arc<Shared>) -> anyhow::Result<()> {
    let adapter = adapter()
        .await
        .context("Windows Bluetooth is unavailable; check Bluetooth access in system settings")?;
    let radio = adapter.GetRadioAsync()?.await?;
    let local = adapter.BluetoothAddress()?;
    {
        let mut core = state.core.lock().unwrap();
        core.set_local(local);
        core.status.adapter = Some("Windows Bluetooth".into());
        core.status.powered = true;
        core.status.central = adapter.IsCentralRoleSupported()?;
        core.status.problem = None;
    }
    let mut subscribers = Subscribers::default();
    let (requests_tx, mut requests) = mpsc::channel(16);
    let peripheral = if adapter.IsPeripheralRoleSupported().unwrap_or(false) {
        timeout(
            Duration::from_secs(15),
            peripheral(state.clone(), requests_tx),
        )
        .await
        .ok()
        .and_then(Result::ok)
    } else {
        None
    };
    {
        let mut core = state.core.lock().unwrap();
        core.status.peripheral = peripheral.is_some();
        if peripheral.is_none() {
            core.status.problem = Some(PERIPHERAL_WARNING.into());
        }
    }
    let watcher = BluetoothLEAdvertisementWatcher::new()?;
    watcher.SetScanningMode(BluetoothLEScanningMode::Active)?;
    watcher
        .AdvertisementFilter()?
        .Advertisement()?
        .ServiceUuids()?
        .Append(SERVICE)?;
    let (found_tx, mut found) = mpsc::channel(32);
    let handler = TypedEventHandler::<
        BluetoothLEAdvertisementWatcher,
        BluetoothLEAdvertisementReceivedEventArgs,
    >::new(move |_, args| {
        if let Some(args) = args.as_ref() {
            let _ = found_tx.try_send(args.BluetoothAddress()?);
        }
        Ok(())
    });
    let token = watcher.Received(&handler)?;
    let cleanup_watcher = watcher.clone();
    let _watcher_guard = Cleanup(Some(Box::new(move || {
        let _ = cleanup_watcher.Stop();
        let _ = cleanup_watcher.RemoveReceived(token);
    })));
    let mut tasks = JoinSet::new();
    let mut tick = interval(Duration::from_millis(250));
    let mut scanning = false;
    loop {
        tokio::select! {
            _ = tick.tick() => {
                if radio.State()? != RadioState::On { bail!("Bluetooth is off. Turn it on in system settings."); }
                state.core.lock().unwrap().expire(state.now());
                let scan = Core::scan_due(state.now());
                if scan != scanning {
                    if scan { watcher.Start()?; } else { watcher.Stop()?; }
                    scanning = scan;
                    state.core.lock().unwrap().status.scanning = scan;
                }
                if scanning && watcher.Status()? == BluetoothLEAdvertisementWatcherStatus::Aborted {
                    bail!("Bluetooth scanning was refused. Check Bluetooth permissions in Windows settings.");
                }
                if let Some((characteristic, provider, _)) = &peripheral {
                    let advertising = matches!(provider.AdvertisementStatus()?, GattServiceProviderAdvertisementStatus::Started | GattServiceProviderAdvertisementStatus::StartedWithoutAllAdvertisementData);
                    {
                        let mut core = state.core.lock().unwrap();
                        core.status.peripheral = advertising;
                        core.status.problem = if advertising { None } else { Some(PERIPHERAL_WARNING.into()) };
                    }
                    refresh_subscribers(&state, characteristic, &mut subscribers, &mut tasks, None).await?;
                }
            }
            Some(peer) = found.recv() => {
                if !scanning || tasks.len() >= MAX_LINKS * 2 { continue; }
                let id = state.core.lock().unwrap().reserve(peer, Role::Central, state.now());
                if let Some(id) = id { tasks.spawn(central(state.clone(), peer, id)); }
            }
            Some((args, _deferred)) = requests.recv() => {
                // The deferral's guard runs on success, errors and cancellation.
                let _ = timeout(Duration::from_secs(3), async {
                    let key = session_key(&args.Session()?)?;
                    if let Some((characteristic, _, _)) = &peripheral {
                        refresh_subscribers(&state, characteristic, &mut subscribers, &mut tasks, Some(&key)).await?;
                    }
                    receive_write(&state, &subscribers, args).await
                }).await;
            }
            _ = tasks.join_next(), if !tasks.is_empty() => {}
        }
    }
}

async fn receive_write(
    state: &Shared,
    subscribers: &Subscribers,
    args: GattWriteRequestedEventArgs,
) -> anyhow::Result<()> {
    let key = session_key(&args.Session()?)?;
    let request = args.GetRequestAsync()?.await?;
    let id = subscribers.id(state, &key);
    let value = bytes(&request.Value()?)?;
    if let (Some(id), Some(value), 0) = (id, value, request.Offset()?) {
        state.core.lock().unwrap().receive(id, &value, state.now());
        if request.Option()? == GattWriteOption::WriteWithResponse {
            request.Respond()?;
        }
    } else if request.Option()? == GattWriteOption::WriteWithResponse {
        request.RespondWithProtocolError(0x0d)?; // invalid attribute value length
    }
    Ok(())
}

struct WinSubscribers(Vec<windows::core::Result<GattSubscribedClient>>);

impl WinSubscribers {
    fn new(characteristic: &GattLocalCharacteristic) -> anyhow::Result<Self> {
        let clients = characteristic.SubscribedClients()?;
        Ok(Self(
            (0..clients.Size()?.min(MAX_LINKS as u32))
                .map(|i| clients.GetAt(i))
                .collect(),
        ))
    }
}

impl PeripheralAdapter for WinSubscribers {
    type Client = GattSubscribedClient;
    type Error = anyhow::Error;
    fn count(&self) -> anyhow::Result<usize> {
        Ok(self.0.len())
    }
    fn client(&self, index: usize) -> anyhow::Result<Self::Client> {
        Ok(self.0[index].clone()?)
    }
    fn key(&self, client: &Self::Client) -> anyhow::Result<String> {
        Ok(session_key(&client.Session()?)?)
    }
    fn limit(&self, client: &Self::Client) -> anyhow::Result<usize> {
        Ok(client.MaxNotificationSize()? as usize)
    }
    async fn peer(&self, _: &Self::Client, key: &str) -> anyhow::Result<u64> {
        let device = timeout(
            Duration::from_secs(2),
            BluetoothLEDevice::FromIdAsync(&HSTRING::from(key))?,
        )
        .await??;
        let peer = device.BluetoothAddress();
        let _ = device.Close();
        Ok(peer?)
    }
}

async fn refresh_subscribers(
    state: &Arc<Shared>,
    characteristic: &GattLocalCharacteristic,
    subscribers: &mut Subscribers,
    tasks: &mut JoinSet<()>,
    first_write: Option<&str>,
) -> anyhow::Result<()> {
    if first_write.is_some_and(|key| subscribers.id(state, key).is_some()) {
        return Ok(());
    }
    let adapter = WinSubscribers::new(characteristic)?;
    let available = (MAX_LINKS * 2).saturating_sub(tasks.len());
    let admit = |id, client| {
        tasks.spawn(notify(state.clone(), characteristic.clone(), client, id));
    };
    if let Some(key) = first_write {
        subscribers
            .before_write(state, &adapter, key, available, admit)
            .await?;
    } else {
        subscribers
            .refresh(state, &adapter, available, admit)
            .await?;
    }
    Ok(())
}

async fn notify(
    state: Arc<Shared>,
    characteristic: GattLocalCharacteristic,
    client: GattSubscribedClient,
    id: u64,
) {
    let result: anyhow::Result<()> = async {
        let mut tick = interval(Duration::from_millis(20));
        loop {
            tick.tick().await;
            let next = {
                let mut core = state.core.lock().unwrap();
                if !core.contains(id) {
                    break;
                }
                core.take_write(id)
            };
            if let Some(bytes) = next {
                let operation = {
                    let value = buffer(&bytes)?;
                    characteristic.NotifyValueForSubscribedClientAsync(&value, &client)?
                };
                let result = timeout(Duration::from_secs(2), operation).await??;
                if result.Status()? != GattCommunicationStatus::Success {
                    break;
                }
            }
        }
        Ok(())
    }
    .await;
    let _ = result;
    state.core.lock().unwrap().remove(id, false, state.now());
}

async fn central(state: Arc<Shared>, peer: u64, id: u64) {
    let result: anyhow::Result<()> = async {
        let (device, service, characteristic) = timeout(Duration::from_secs(15), async {
            let device = BluetoothLEDevice::FromBluetoothAddressAsync(peer)?.await?;
            let services = device.GetGattServicesForUuidAsync(SERVICE)?.await?;
            if services.Status()? != GattCommunicationStatus::Success
                || services.Services()?.Size()? == 0
            {
                bail!("No Bluetooth mesh service");
            }
            let service = services.Services()?.GetAt(0)?;
            let chars = service
                .GetCharacteristicsForUuidAsync(CHARACTERISTIC)?
                .await?;
            if chars.Status()? != GattCommunicationStatus::Success
                || chars.Characteristics()?.Size()? == 0
            {
                bail!("No Bluetooth mesh characteristic");
            }
            Ok::<_, anyhow::Error>((device, service, chars.Characteristics()?.GetAt(0)?))
        })
        .await??;
        let input_state = state.clone();
        let token = {
            let handler = TypedEventHandler::<GattCharacteristic, GattValueChangedEventArgs>::new(
                move |_, args| {
                    if let Some(args) = args.as_ref() {
                        if let Some(value) = bytes(&args.CharacteristicValue()?)? {
                            input_state
                                .core
                                .lock()
                                .unwrap()
                                .receive(id, &value, input_state.now());
                        }
                    }
                    Ok(())
                },
            );
            characteristic.ValueChanged(&handler)?
        };
        let cleanup_char = characteristic.clone();
        let cleanup_service = service.clone();
        let cleanup_device = device.clone();
        let _guard = Cleanup(Some(Box::new(move || {
            let _ = cleanup_char.RemoveValueChanged(token);
            let _ = cleanup_service.Close();
            let _ = cleanup_device.Close();
        })));
        let session = service.Session()?;
        if !callbacks::enable_notifications(
            &state,
            id,
            session.MaxPduSize()?.saturating_sub(3) as usize,
            || async {
                let status = timeout(
                    Duration::from_secs(5),
                    characteristic.WriteClientCharacteristicConfigurationDescriptorAsync(
                        GattClientCharacteristicConfigurationDescriptorValue::Notify,
                    )?,
                )
                .await??;
                if status != GattCommunicationStatus::Success {
                    bail!("Bluetooth notifications were refused");
                }
                Ok::<_, anyhow::Error>(())
            },
        )
        .await?
        {
            return Ok(());
        }
        let mut tick = interval(Duration::from_millis(20));
        loop {
            tick.tick().await;
            if device.ConnectionStatus()? == BluetoothConnectionStatus::Disconnected {
                break;
            }
            let next = {
                let mut core = state.core.lock().unwrap();
                if !core.contains(id) {
                    break;
                }
                core.ready(id, session.MaxPduSize()?.saturating_sub(3) as usize);
                core.take_write(id)
            };
            if let Some(bytes) = next {
                let operation = {
                    let value = buffer(&bytes)?;
                    characteristic
                        .WriteValueWithOptionAsync(&value, GattWriteOption::WriteWithResponse)?
                };
                let result = timeout(Duration::from_secs(5), operation).await??;
                if result != GattCommunicationStatus::Success {
                    bail!("Bluetooth write failed");
                }
            }
        }
        Ok(())
    }
    .await;
    state
        .core
        .lock()
        .unwrap()
        .remove(id, result.is_err(), state.now());
}
