//! Interface and address changes, for cable links (M54a).
//!
//! Dart needs to know when a cable or a USB tethering link appears or goes,
//! without polling. On Linux and Windows `netwatch` (the crate Iroh watches
//! the network with: netlink, IP-change notifications) says so. Android has
//! no such monitor for apps: the Kotlin side sends events there.
//!
//! [`LinkMonitorCore`] is the part Dart waits on: a generation number that
//! goes up with every change. It is shared (`Arc`) between the event source
//! and every waiter, so stopping it while a wait is running neither frees it
//! under the waiter nor leaves the waiter blocked.

use std::{
    sync::{Arc, Condvar, Mutex},
    time::Duration,
};

/// The longest a single wait may last.
pub const MAX_WAIT: Duration = Duration::from_secs(60);

struct CoreState {
    generation: u64,
    stopped: bool,
}

pub struct LinkMonitorCore {
    state: Mutex<CoreState>,
    changed: Condvar,
}

impl LinkMonitorCore {
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            // Generation 0 is what a wait returns once the monitor is
            // stopped, so counting starts at 1.
            state: Mutex::new(CoreState {
                generation: 1,
                stopped: false,
            }),
            changed: Condvar::new(),
        })
    }

    /// The links may have changed.
    pub fn notify_change(&self) {
        if let Ok(mut state) = self.state.lock() {
            state.generation = state.generation.wrapping_add(1).max(1);
        }
        self.changed.notify_all();
    }

    /// Ends the monitor: every wait returns at once, and later ones too.
    pub fn stop(&self) {
        if let Ok(mut state) = self.state.lock() {
            state.stopped = true;
        }
        self.changed.notify_all();
    }

    pub fn generation(&self) -> u64 {
        self.state.lock().map(|state| state.generation).unwrap_or(0)
    }

    /// Blocks until the generation is not `seen` any more, the monitor is
    /// stopped, or `timeout` (at most [`MAX_WAIT`]) has passed. Returns the
    /// generation and whether the monitor is stopped. A timeout returns
    /// `seen` unchanged.
    pub fn wait(&self, seen: u64, timeout: Duration) -> (u64, bool) {
        let timeout = timeout.min(MAX_WAIT);
        let Ok(guard) = self.state.lock() else {
            return (seen, true);
        };
        match self
            .changed
            .wait_timeout_while(guard, timeout, |state| {
                state.generation == seen && !state.stopped
            }) {
            Ok((state, _)) => (state.generation, state.stopped),
            Err(_) => (seen, true),
        }
    }
}

/// A running monitor: the core, and on Linux and Windows the task that feeds
/// it from `netwatch`.
pub struct LinkMonitor {
    pub core: Arc<LinkMonitorCore>,
    feed: Mutex<Option<tokio::task::JoinHandle<()>>>,
}

impl LinkMonitor {
    /// A monitor nothing feeds (tests, and Android, where Kotlin does).
    pub fn idle() -> Arc<Self> {
        Arc::new(Self {
            core: LinkMonitorCore::new(),
            feed: Mutex::new(None),
        })
    }

    /// Starts watching the system's interfaces where there is a monitor.
    pub fn start(runtime: &tokio::runtime::Runtime) -> Arc<Self> {
        let monitor = Self::idle();
        #[cfg(any(target_os = "linux", target_os = "windows"))]
        {
            let core = Arc::clone(&monitor.core);
            let task = runtime.spawn(async move {
                use n0_watcher::Watcher as _;
                let Ok(netmon) = netwatch::netmon::Monitor::new().await else {
                    return;
                };
                let mut watcher = netmon.interface_state();
                while watcher.updated().await.is_ok() {
                    core.notify_change();
                }
            });
            if let Ok(mut feed) = monitor.feed.lock() {
                *feed = Some(task);
            }
        }
        #[cfg(not(any(target_os = "linux", target_os = "windows"))]
        let _ = runtime;
        monitor
    }

    /// Stops the feed and wakes every waiter. The core stays alive for as
    /// long as a waiter holds it.
    pub fn stop(&self) {
        if let Ok(mut feed) = self.feed.lock() {
            if let Some(task) = feed.take() {
                task.abort();
            }
        }
        self.core.stop();
    }
}

#[cfg(test)]
mod tests {
    use std::{
        thread,
        time::{Duration, Instant},
    };

    use super::*;

    #[test]
    fn a_change_wakes_a_waiter_with_the_new_generation() {
        let core = LinkMonitorCore::new();
        let seen = core.generation();
        let waiter = {
            let core = Arc::clone(&core);
            thread::spawn(move || core.wait(seen, Duration::from_secs(20)))
        };
        thread::sleep(Duration::from_millis(50));
        core.notify_change();
        let (generation, stopped) = waiter.join().unwrap();
        assert_eq!(generation, seen + 1);
        assert!(!stopped);
    }

    #[test]
    fn a_wait_that_times_out_returns_the_generation_it_was_given() {
        let core = LinkMonitorCore::new();
        let seen = core.generation();
        let started = Instant::now();
        let (generation, stopped) = core.wait(seen, Duration::from_millis(80));
        assert_eq!(generation, seen);
        assert!(!stopped);
        assert!(started.elapsed() >= Duration::from_millis(70));
    }

    #[test]
    fn a_change_already_made_is_not_waited_for() {
        let core = LinkMonitorCore::new();
        let seen = core.generation();
        core.notify_change();
        let started = Instant::now();
        let (generation, _) = core.wait(seen, Duration::from_secs(20));
        assert_eq!(generation, seen + 1);
        assert!(started.elapsed() < Duration::from_secs(5));
    }

    #[test]
    fn stop_ends_a_running_wait_at_once() {
        let monitor = LinkMonitor::idle();
        let seen = monitor.core.generation();
        let waiter = {
            let core = Arc::clone(&monitor.core);
            thread::spawn(move || core.wait(seen, Duration::from_secs(30)))
        };
        thread::sleep(Duration::from_millis(100));
        let started = Instant::now();
        monitor.stop();
        let (_, stopped) = waiter.join().unwrap();
        assert!(stopped);
        assert!(started.elapsed() < Duration::from_secs(5));
    }

    #[test]
    fn the_core_outlives_its_monitor_while_a_wait_holds_it() {
        let monitor = LinkMonitor::idle();
        let core = Arc::clone(&monitor.core);
        let seen = core.generation();
        let waiter = thread::spawn(move || core.wait(seen, Duration::from_secs(30)));
        thread::sleep(Duration::from_millis(100));
        // The monitor goes (its handle is freed) while the wait still runs.
        monitor.stop();
        drop(monitor);
        let (_, stopped) = waiter.join().unwrap();
        assert!(stopped);
    }

    #[test]
    fn a_wait_after_stop_returns_at_once_and_a_wait_is_capped() {
        let core = LinkMonitorCore::new();
        core.stop();
        let started = Instant::now();
        let (_, stopped) = core.wait(core.generation(), Duration::from_secs(600));
        assert!(stopped);
        assert!(started.elapsed() < Duration::from_secs(5));
        assert_eq!(MAX_WAIT, Duration::from_secs(60));
    }

    #[test]
    fn the_generation_never_returns_to_zero() {
        let core = LinkMonitorCore::new();
        {
            let mut state = core.state.lock().unwrap();
            state.generation = u64::MAX;
        }
        core.notify_change();
        assert_eq!(core.generation(), 1);
    }
}
