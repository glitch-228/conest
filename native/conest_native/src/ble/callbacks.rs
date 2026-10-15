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
pub struct Subscribers(BTreeMap<String, u64>);

impl Subscribers {
    pub fn id(&self, shared: &Shared, key: &str) -> Option<u64> {
        self.0
            .get(key)
            .copied()
            .filter(|id| shared.core.lock().unwrap().contains(*id))
    }

    /// Errors from one disappearing peer never discard another's slot.
    /// Only a complete OS snapshot can remove missing subscriptions.
    pub async fn refresh<A: PeripheralAdapter>(
        &mut self,
        shared: &Shared,
        adapter: &A,
        available_workers: usize,
    ) -> Result<Vec<(u64, A::Client)>, A::Error> {
        let count = adapter.count()?.min(MAX_LINKS);
        self.0
            .retain(|_, id| shared.core.lock().unwrap().contains(*id));
        let mut seen = BTreeSet::new();
        let mut complete = true;
        let mut added = Vec::new();
        for index in 0..count {
            let result: Result<(), A::Error> = async {
                let client = adapter.client(index)?;
                let key = adapter.key(&client)?;
                if key.is_empty() || key.len() > 512 {
                    return Ok(());
                }
                seen.insert(key.clone());
                let limit = adapter.limit(&client)?;
                if let Some(id) = self.id(shared, &key) {
                    shared.core.lock().unwrap().ready(id, limit);
                    return Ok(());
                }
                if added.len() >= available_workers.min(MAX_LINKS) || self.0.len() >= MAX_LINKS {
                    return Ok(());
                }
                let peer = adapter.peer(&client, &key).await?;
                let mut core = shared.core.lock().unwrap();
                if let Some(id) = core.reserve(peer, Role::Peripheral, shared.now()) {
                    if core.ready(id, limit) {
                        self.0.insert(key, id);
                        added.push((id, client));
                    } else {
                        core.remove(id, false, shared.now());
                    }
                }
                Ok(())
            }
            .await;
            if result.is_err() {
                complete = false;
            }
        }
        if complete {
            self.0.retain(|key, id| {
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
    pub async fn before_write<A: PeripheralAdapter>(
        &mut self,
        shared: &Shared,
        adapter: &A,
        key: &str,
        available_workers: usize,
    ) -> Result<Vec<(u64, A::Client)>, A::Error> {
        if self.id(shared, key).is_some() {
            return Ok(Vec::new());
        }
        self.refresh(shared, adapter, available_workers).await
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
        async fn peer(&self, client: &usize, _: &str) -> Result<u64, Self::Error> {
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
            .before_write(&shared, &adapter, "new", 8)
            .await
            .unwrap();
        assert_eq!(added.len(), 1);
        let id = subscribers.id(&shared, "new").unwrap();
        let packet = vec![
            1, 2, 7, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1,
        ];
        shared.core.lock().unwrap().receive(id, &packet, 0);
        assert_eq!(shared.core.lock().unwrap().poll().events.len(), 1);
        assert!(
            subscribers
                .before_write(&shared, &adapter, "new", 8)
                .await
                .unwrap()
                .is_empty()
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
            )
            .await
            .unwrap();
        let healthy = subscribers.id(&shared, "healthy").unwrap();
        let adapter = MockAdapter(vec![
            Err("vanished during inspection"),
            Ok(("another".into(), 2, 100)),
        ]);
        let added = subscribers.refresh(&shared, &adapter, 8).await.unwrap();
        assert_eq!(added.len(), 1);
        assert_eq!(subscribers.id(&shared, "healthy"), Some(healthy));
        assert!(subscribers.id(&shared, "another").is_some());
        assert_eq!(shared.core.lock().unwrap().limits().len(), 2);
        subscribers
            .refresh(&shared, &MockAdapter(vec![]), 8)
            .await
            .unwrap();
        assert!(shared.core.lock().unwrap().limits().is_empty());
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
