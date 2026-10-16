//! Desktop Bluetooth transport. All OS work lives on a dedicated runtime;
//! FFI only copies bounded queues under a short-lived mutex.
#[cfg(any(target_os = "windows", test))]
mod callbacks;
pub mod core;
#[cfg(target_os = "linux")]
mod linux;
#[cfg(target_os = "windows")]
mod windows;

use std::sync::{
    Arc, Mutex, MutexGuard, PoisonError,
    atomic::{AtomicBool, Ordering},
};
use std::time::{Duration, Instant};

pub const SERVICE_UUID: u128 = 0xf47b5e2d_4a9e_4c5a_9b3f_8e1d2c3a4b5c;
pub const CHARACTERISTIC_UUID: u128 = 0xa1b2c3d4_e5f6_4a5b_8c9d_0e1f2a3b4c5d;
pub const PERIPHERAL_WARNING: &str = "This Bluetooth adapter cannot advertise: nearby phones can't find this computer, but it can still connect to them.";

pub struct Shared {
    pub core: Mutex<core::Core>,
    pub stop: AtomicBool,
    epoch: Instant,
}

impl Shared {
    /// The link state, also after a panic elsewhere poisoned its lock: a
    /// panic inside an OS callback (WinRT, BlueZ) aborts the whole app.
    pub fn core(&self) -> MutexGuard<'_, core::Core> {
        self.core.lock().unwrap_or_else(PoisonError::into_inner)
    }

    pub fn now(&self) -> u64 {
        self.epoch.elapsed().as_millis().min(u64::MAX as u128) as u64
    }
    pub fn stopped(&self) -> bool {
        self.stop.load(Ordering::Acquire)
    }
}

pub struct Session {
    pub shared: Arc<Shared>,
    worker: Option<std::thread::JoinHandle<()>>,
}

impl Session {
    pub fn open() -> std::io::Result<Self> {
        let shared = Arc::new(Shared {
            core: Mutex::new(core::Core::default()),
            stop: AtomicBool::new(false),
            epoch: Instant::now(),
        });
        let state = shared.clone();
        let worker = std::thread::Builder::new().name("conest-ble".into()).spawn(move || {
            #[cfg(target_os = "windows")]
            let _apartment = windows::Apartment::new();
            let runtime = match tokio::runtime::Builder::new_current_thread().enable_all().build() {
                Ok(runtime) => runtime,
                Err(_) => {
                    state.core().status.problem = Some("Bluetooth could not start its worker.".into());
                    return;
                }
            };
            runtime.block_on(async {
                while !state.stopped() {
                    // Cancellation drops all platform guards, event handlers,
                    // advertising and bounded link tasks, even during setup.
                    let result = tokio::select! {
                        result = run(state.clone()) => result,
                        _ = async {
                            while !state.stopped() { tokio::time::sleep(Duration::from_millis(100)).await; }
                            // On Linux run() notices the stop itself and closes
                            // the connections it opened; it is cut off only if
                            // that takes too long.
                            #[cfg(target_os = "linux")]
                            tokio::time::sleep(Duration::from_secs(3)).await;
                        } => break,
                    };
                    {
                        let mut core = state.core();
                        core.clear_links();
                        core.status.powered = false;
                        core.status.central = false;
                        core.status.peripheral = false;
                        core.status.scanning = false;
                        core.status.problem = Some(result.err().map_or_else(|| "Bluetooth disconnected.".into(), |e| e.to_string()));
                    }
                    for _ in 0..50 {
                        if state.stopped() { break; }
                        tokio::time::sleep(Duration::from_millis(100)).await;
                    }
                }
            });
        })?;
        Ok(Self {
            shared,
            worker: Some(worker),
        })
    }
}

#[cfg(target_os = "linux")]
async fn run(state: Arc<Shared>) -> anyhow::Result<()> {
    linux::run(state).await
}
#[cfg(target_os = "windows")]
async fn run(state: Arc<Shared>) -> anyhow::Result<()> {
    windows::run(state).await
}

impl Drop for Session {
    fn drop(&mut self) {
        self.shared.stop.store(true, Ordering::Release);
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}
