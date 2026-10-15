//! Platform callback ordering and per-peer failure isolation, tested without
//! Bluetooth hardware. WinRT's immediate callbacks use the same policies.
use std::{
    collections::{BTreeMap, BTreeSet},
    future::Future,
};

use super::{
    Shared,
    core::{MAX_LINKS, Role},
};

pub trait PeripheralAdapter {
    type Client;
    type Error;
    fn count(&self) -> Result<usize, Self::Error>;
    fn client(&self, index: usize) -> Result<Self::Client, Self::Error>;
    fn key(&self, client: &Self::Client) -> Result<String, Self::Error>;
    fn limit(&self, client: &Self::Client) -> Result<usize, Self::Error>;
    async fn peer(&self, client: &Self::Client, key: &str) -> Result<u64, Self::Error>;
}

#[derive(Default)]
pub struct Subscribers {
    links: BTreeMap<String, u64>,
    next: usize,
}

impl Subscribers {
    pub fn id(&self, shared: &Shared, key: &str) -> Option<u64> {
        self.links
            .get(key)
            .copied()
            .filter(|id| shared.core.lock().unwrap().contains(*id))
    }

    /// Errors from one disappearing peer never discard another's slot.
    /// Only a complete OS snapshot can remove missing subscriptions.
    pub async fn refresh<A: PeripheralAdapter, F: FnMut(u64, A::Client)>(
        &mut self,
        shared: &Shared,
        adapter: &A,
        available_workers: usize,
        admit: F,
    ) -> Result<usize, A::Error> {
        self.inspect(shared, adapter, available_workers, None, admit)
            .await
    }

    async fn inspect<A: PeripheralAdapter, F: FnMut(u64, A::Client)>(
        &mut self,
        shared: &Shared,
        adapter: &A,
        available_workers: usize,
        wanted: Option<&str>,
        mut admit: F,
    ) -> Result<usize, A::Error> {
        let count = adapter.count()?.min(MAX_LINKS);
        self.links
            .retain(|_, id| shared.core.lock().unwrap().contains(*id));
        let mut seen = BTreeSet::new();
        let mut complete = wanted.is_none();
        let mut added = 0;
        let start = if wanted.is_none() && count > 0 {
            self.next % count
        } else {
            0
        };
        for offset in 0..count {
            let index = (start + offset) % count;
            // Advance before the cancellable lookup so the next periodic
            // pass can reach other peers when this one always stalls.
            if wanted.is_none() {
                self.next = (index + 1) % count;
            }
            let mut requested = false;
            let result: Result<(), A::Error> = async {
                let client = adapter.client(index)?;
                let key = adapter.key(&client)?;
                if key.is_empty() || key.len() > 512 {
                    return Ok(());
                }
                if wanted.is_some_and(|wanted| wanted != key) {
                    return Ok(());
                }
                requested = wanted.is_some();
                seen.insert(key.clone());
                let limit = adapter.limit(&client)?;
                if let Some(id) = self.id(shared, &key) {
                    shared.core.lock().unwrap().ready(id, limit);
                    return Ok(());
                }
                if added >= available_workers.min(MAX_LINKS) || self.links.len() >= MAX_LINKS {
                    return Ok(());
                }
                let peer = adapter.peer(&client, &key).await?;
                let id = {
                    let mut core = shared.core.lock().unwrap();
                    core.reserve(peer, Role::Peripheral, shared.now())
                        .filter(|id| {
                            if core.ready(*id, limit) {
                                return true;
                            }
                            core.remove(*id, false, shared.now());
                            false
                        })
                };
                if let Some(id) = id {
                    self.links.insert(key, id);
                    added += 1;
                    // Start the writer synchronously with admission. A later
                    // peer lookup may time out or cancel this entire refresh.
                    // No ready link can be left holding an unpumped queue.
                    admit(id, client);
                }
                Ok(())
            }
            .await;
            if result.is_err() {
                complete = false;
            }
            if requested {
                break;
            }
        }
        if complete {
            self.links.retain(|key, id| {
                if seen.contains(key) {
                    return true;
                }
                shared.core.lock().unwrap().remove(*id, false, shared.now());
                false
            });
        }
        Ok(added)
    }

    /// A first write may arrive before the periodic subscription snapshot.
    pub async fn before_write<A: PeripheralAdapter, F: FnMut(u64, A::Client)>(
        &mut self,
        shared: &Shared,
        adapter: &A,
        key: &str,
        available_workers: usize,
        admit: F,
    ) -> Result<usize, A::Error> {
        if self.id(shared, key).is_some() {
            return Ok(0);
        }
        self.inspect(shared, adapter, available_workers, Some(key), admit)
            .await
    }
}

/// CCCD enabling can synchronously deliver ValueChanged before its future
/// completes. Arm reception before starting that OS operation. Outbound
/// pumping remains the caller's responsibility after it succeeds.
pub async fn enable_notifications<F, Fut, E>(
    shared: &Shared,
    id: u64,
    limit: usize,
    enable: F,
) -> Result<bool, E>
where
    F: FnOnce() -> Fut,
    Fut: Future<Output = Result<(), E>>,
{
    if !shared.core.lock().unwrap().ready(id, limit) {
        return Ok(false);
    }
    enable().await?;
    Ok(true)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        sync::{Mutex, atomic::AtomicBool},
        time::Instant,
    };

    struct MockAdapter(Vec<Result<(String, u64, usize), &'static str>>);
    impl PeripheralAdapter for MockAdapter {
        type Client = usize;
        type Error = &'static str;
        fn count(&self) -> Result<usize, Self::Error> {
            Ok(self.0.len())
        }
        fn client(&self, index: usize) -> Result<usize, Self::Error> {
            Ok(index)
        }
        fn key(&self, client: &usize) -> Result<String, Self::Error> {
            self.0[*client]
                .as_ref()
                .map(|p| p.0.clone())
                .map_err(|e| *e)
        }
        fn limit(&self, client: &usize) -> Result<usize, Self::Error> {
            self.0[*client].as_ref().map(|p| p.2).map_err(|e| *e)
        }
        async fn peer(&self, client: &usize, key: &str) -> Result<u64, Self::Error> {
            if key == "stall" {
                return std::future::pending().await;
            }
            self.0[*client].as_ref().map(|p| p.1).map_err(|e| *e)
        }
    }

    fn shared() -> Shared {
        Shared {
            core: Mutex::default(),
            stop: AtomicBool::new(false),
            epoch: Instant::now(),
        }
    }

    #[tokio::test]
    async fn first_write_refreshes_subscription_before_delivery() {
        let shared = shared();
        let mut subscribers = Subscribers::default();
        let adapter = MockAdapter(vec![Ok(("new".into(), 1, 182))]);
        let added = subscribers
            .before_write(&shared, &adapter, "new", 8, |_, _| {})
            .await
            .unwrap();
        assert_eq!(added, 1);
        let id = subscribers.id(&shared, "new").unwrap();
        let packet = vec![
            1, 2, 7, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1,
        ];
        shared.core.lock().unwrap().receive(id, &packet, 0);
        assert_eq!(shared.core.lock().unwrap().poll().events.len(), 1);
        assert_eq!(
            subscribers
                .before_write(&shared, &adapter, "new", 8, |_, _| {})
                .await
                .unwrap(),
            0
        );
    }

    #[tokio::test]
    async fn vanished_subscriber_does_not_reset_healthy_links() {
        let shared = shared();
        let mut subscribers = Subscribers::default();
        subscribers
            .refresh(
                &shared,
                &MockAdapter(vec![Ok(("healthy".into(), 1, 182))]),
                8,
                |_, _| {},
            )
            .await
            .unwrap();
        let healthy = subscribers.id(&shared, "healthy").unwrap();
        let adapter = MockAdapter(vec![
            Err("vanished during inspection"),
            Ok(("another".into(), 2, 100)),
        ]);
        let added = subscribers
            .refresh(&shared, &adapter, 8, |_, _| {})
            .await
            .unwrap();
        assert_eq!(added, 1);
        assert_eq!(subscribers.id(&shared, "healthy"), Some(healthy));
        assert!(subscribers.id(&shared, "another").is_some());
        assert_eq!(shared.core.lock().unwrap().limits().len(), 2);
        subscribers
            .refresh(&shared, &MockAdapter(vec![]), 8, |_, _| {})
            .await
            .unwrap();
        assert!(shared.core.lock().unwrap().limits().is_empty());
    }

    #[tokio::test]
    async fn cancelled_refresh_never_leaves_a_ready_link_without_a_writer() {
        let shared = shared();
        let mut subscribers = Subscribers::default();
        let adapter = MockAdapter(vec![
            Ok(("fast".into(), 1, 182)),
            Ok(("stall".into(), 2, 182)),
        ]);
        let mut writers = Vec::new();
        assert!(
            tokio::time::timeout(
                std::time::Duration::from_millis(10),
                subscribers.refresh(&shared, &adapter, 8, |id, _| writers.push(id))
            )
            .await
            .is_err()
        );
        let id = subscribers.id(&shared, "fast").unwrap();
        assert_eq!(writers, vec![id]);
        let mut core = shared.core.lock().unwrap();
        assert!(core.enqueue(id, &[1, 2, 3]));
        assert_eq!(core.take_write(writers[0]), Some(vec![1, 2, 3]));
    }

    #[tokio::test]
    async fn first_write_never_waits_for_unrelated_slow_subscribers() {
        let shared = shared();
        let mut subscribers = Subscribers::default();
        subscribers
            .refresh(
                &shared,
                &MockAdapter(vec![Ok(("healthy".into(), 1, 182))]),
                8,
                |_, _| {},
            )
            .await
            .unwrap();
        let healthy = subscribers.id(&shared, "healthy").unwrap();
        let adapter = MockAdapter(vec![
            Ok(("stall".into(), 3, 182)),
            Ok(("fast".into(), 2, 182)),
            Ok(("stall".into(), 4, 182)),
        ]);
        let mut writers = Vec::new();
        let admitted = tokio::time::timeout(
            std::time::Duration::from_millis(10),
            subscribers.before_write(&shared, &adapter, "fast", 8, |id, _| writers.push(id)),
        )
        .await
        .unwrap()
        .unwrap();
        assert_eq!(admitted, 1);
        assert_eq!(writers, vec![subscribers.id(&shared, "fast").unwrap()]);
        assert_eq!(subscribers.id(&shared, "healthy"), Some(healthy));
    }

    #[tokio::test]
    async fn periodic_refresh_progresses_past_a_permanently_slow_first_peer() {
        let shared = shared();
        let mut subscribers = Subscribers::default();
        let adapter = MockAdapter(vec![
            Ok(("stall".into(), 1, 182)),
            Ok(("healthy".into(), 2, 182)),
        ]);
        let mut writers = Vec::new();
        for _ in 0..2 {
            assert!(
                tokio::time::timeout(
                    std::time::Duration::from_millis(10),
                    subscribers.refresh(&shared, &adapter, 8, |id, _| writers.push(id))
                )
                .await
                .is_err()
            );
        }
        assert_eq!(writers, vec![subscribers.id(&shared, "healthy").unwrap()]);
    }

    #[tokio::test]
    async fn callbacks_during_cccd_setup_can_deliver_the_first_packet() {
        let shared = shared();
        let id = shared
            .core
            .lock()
            .unwrap()
            .reserve(1, Role::Central, 0)
            .unwrap();
        assert!(
            enable_notifications(&shared, id, 182, || async {
                let packet = vec![
                    1, 2, 7, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1,
                ];
                shared.core.lock().unwrap().receive(id, &packet, 0);
                Ok::<_, ()>(())
            })
            .await
            .unwrap()
        );
        assert_eq!(shared.core.lock().unwrap().poll().events.len(), 1);
    }
}
