//! Budgets: requests and stores per address, connection and long-poll
//! slots, soft bans, UDP cookies and per-mailbox throughput.

use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::{Arc, Mutex};

use base64::Engine;
use base64::engine::general_purpose::STANDARD as BASE64_STANDARD;
use ed25519_dalek::Signer;

use crate::config::now_millis;
use crate::storage::RelayState;

#[derive(Clone)]
pub(crate) struct RateBucket {
    pub(crate) window_started_millis: u64,
    pub(crate) count: u32,
}

/// Stores (and UDP requests) from one address in the current minute.
pub(crate) struct StoreWindow {
    pub(crate) window_started_millis: u64,
    pub(crate) count: u32,
    pub(crate) bytes: u64,
}

/// One of an address's limited slots (a long-poll, a connection), given
/// back when dropped.
pub(crate) struct PeerSlot {
    pub(crate) slots: Arc<Mutex<HashMap<String, usize>>>,
    pub(crate) peer: String,
}

impl Drop for PeerSlot {
    fn drop(&mut self) {
        let mut slots = self.slots.lock().expect("slot lock should not poison");
        if let Some(count) = slots.get_mut(&self.peer) {
            *count = count.saturating_sub(1);
            if *count == 0 {
                slots.remove(&self.peer);
            }
        }
    }
}

/// Takes one of [peer]'s slots in [slots], or none when it holds [max].
pub(crate) fn take_peer_slot(
    slots: &Arc<Mutex<HashMap<String, usize>>>,
    peer: &str,
    max: usize,
) -> Option<PeerSlot> {
    let mut map = slots.lock().expect("slot lock should not poison");
    let count = map.entry(peer.to_owned()).or_insert(0);
    if *count >= max {
        return None;
    }
    *count += 1;
    Some(PeerSlot {
        slots: Arc::clone(slots),
        peer: peer.to_owned(),
    })
}

/// The key an address is counted under: an IPv6 address by its /64 (one
/// site; a /64 holds more addresses than could ever be counted one by one),
/// an IPv4-mapped one as IPv4.
pub(crate) fn peer_key(address: std::net::IpAddr) -> String {
    match address {
        std::net::IpAddr::V4(v4) => v4.to_string(),
        std::net::IpAddr::V6(v6) => {
            if let Some(v4) = v6.to_ipv4_mapped() {
                return v4.to_string();
            }
            let s = v6.segments();
            format!("{:x}:{:x}:{:x}:{:x}::/64", s[0], s[1], s[2], s[3])
        }
    }
}

/// The group an address key belongs to for what it may hold: an IPv6 /64
/// key widened to its /48 (one site can have 65,536 /64s); others as they
/// are. A UDP key counts with its address.
pub(crate) fn peer_group(peer: &str) -> String {
    let peer = peer.strip_prefix("udp:").unwrap_or(peer);
    match peer.strip_suffix("::/64") {
        Some(prefix) => {
            let segments: Vec<&str> = prefix.split(':').collect();
            if segments.len() == 4 {
                format!("{}:{}:{}::/48", segments[0], segments[1], segments[2])
            } else {
                peer.to_owned()
            }
        }
        None => peer.to_owned(),
    }
}

/// The client address a trusted proxy's X-Forwarded-For names: its last
/// entry (the one the proxy saw), a port stripped.
pub(crate) fn forwarded_peer(value: &str) -> Option<String> {
    let last = value.split(',').next_back()?.trim();
    if last.is_empty() {
        return None;
    }
    if let Ok(address) = last.parse::<std::net::IpAddr>() {
        return Some(peer_key(address));
    }
    if let Ok(address) = last.parse::<SocketAddr>() {
        return Some(peer_key(address.ip()));
    }
    Some(last.to_owned())
}

#[derive(Clone)]
pub(crate) struct MailboxByteWindow {
    pub(crate) window_started_millis: u64,
    pub(crate) bytes_used: u64,
}

#[derive(Clone)]
pub(crate) struct BanEntry {
    pub(crate) banned_until_millis: u64,
    pub(crate) consecutive_violations: u32,
}

impl RelayState {
    pub(crate) fn allow_request(&self, peer: &str) -> bool {
        self.allow_request_banning(peer, true)
    }

    /// Whether the rate maps are due a prune (at most once a second; doing
    /// it on every request cost a full scan each time).
    pub(crate) fn prune_due(&self, now: u64) -> bool {
        let last = self
            .rates_pruned_at
            .load(std::sync::atomic::Ordering::Relaxed);
        now.saturating_sub(last) >= 1_000
            && self
                .rates_pruned_at
                .compare_exchange(
                    last,
                    now,
                    std::sync::atomic::Ordering::AcqRel,
                    std::sync::atomic::Ordering::Relaxed,
                )
                .is_ok()
    }

    /// The general limit. [ban]: refusals count towards the soft ban (not
    /// for datagrams, whose source can be forged to get someone banned).
    pub(crate) fn allow_request_banning(&self, peer: &str, ban: bool) -> bool {
        let now = now_millis();
        // Soft-ban check first — a banned peer is rejected outright until
        // the timer expires, regardless of per-minute budget. Expired
        // ban entries and stale violation tallies (no violation in the
        // last two minutes) are dropped so the map stays bounded; an
        // active violation tally below the threshold is kept so a peer
        // can't reset its slate by sleeping through the rate-limit window.
        {
            let mut bans = self
                .banned_peers
                .lock()
                .expect("ban lock should not poison");
            bans.retain(|_, entry| {
                if entry.banned_until_millis > now {
                    return true;
                }
                if entry.banned_until_millis > 0 {
                    // Ban expired and no longer in flight.
                    return false;
                }
                // Pending tally (never banned): keep it as long as the
                // tally is non-zero — the per-minute window already
                // resets the bucket count, so the tally itself drives
                // the soft-ban threshold across consecutive bursts.
                entry.consecutive_violations > 0
            });
            if let Some(entry) = bans.get(peer)
                && entry.banned_until_millis > now
            {
                return false;
            }
        }

        let mut buckets = self
            .rate_buckets
            .lock()
            .expect("rate bucket lock should not poison");
        if self.prune_due(now) {
            buckets.retain(|_, bucket| now.saturating_sub(bucket.window_started_millis) < 120_000);
        }
        if buckets.len() >= self.config.max_rate_keys && !buckets.contains_key(peer) {
            return false;
        }
        let bucket = buckets.entry(peer.to_owned()).or_insert(RateBucket {
            window_started_millis: now,
            count: 0,
        });
        if now.saturating_sub(bucket.window_started_millis) >= 60_000 {
            bucket.window_started_millis = now;
            bucket.count = 0;
        }
        if bucket.count >= self.config.max_requests_per_minute {
            // Over the rate limit: tally a violation and, if it crosses
            // the soft-ban threshold, install a temporary ban that even
            // a fresh minute window cannot bypass.
            drop(buckets);
            if ban {
                self.note_rate_violation(peer, now);
            }
            return false;
        }
        bucket.count += 1;
        // A legit request resets the consecutive-violation counter so
        // well-behaved clients don't accumulate slate after a brief burst.
        drop(buckets);
        self.note_rate_compliance(peer);
        true
    }

    /// The heavier budget: stores (by count and bytes) and UDP requests.
    /// Going over it refuses the request; only the general limit leads to
    /// the soft ban.
    pub(crate) fn allow_store(&self, peer: &str, bytes: u64) -> bool {
        let now = now_millis();
        let mut windows = self
            .store_windows
            .lock()
            .expect("store window lock should not poison");
        if self.prune_due(now) {
            windows.retain(|_, window| now.saturating_sub(window.window_started_millis) < 120_000);
        }
        if windows.len() >= self.config.max_rate_keys && !windows.contains_key(peer) {
            return false;
        }
        let window = windows.entry(peer.to_owned()).or_insert(StoreWindow {
            window_started_millis: now,
            count: 0,
            bytes: 0,
        });
        if now.saturating_sub(window.window_started_millis) >= 60_000 {
            window.window_started_millis = now;
            window.count = 0;
            window.bytes = 0;
        }
        if window.count >= self.config.max_stores_per_minute
            || window.bytes.saturating_add(bytes) > self.config.max_store_bytes_per_minute
        {
            return false;
        }
        window.count += 1;
        window.bytes = window.bytes.saturating_add(bytes);
        true
    }

    /// A long-poll slot for [peer], or none when it holds its share open.
    pub(crate) fn long_poll_slot(&self, peer: &str) -> Option<PeerSlot> {
        take_peer_slot(&self.long_polls, peer, self.config.max_long_polls_per_peer)
    }

    /// A connection slot for [peer] (an IPv6 /48 counts as one), or none
    /// when it holds its share open.
    pub(crate) fn connection_slot(&self, peer: &str) -> Option<PeerSlot> {
        take_peer_slot(
            &self.connections,
            &peer_group(peer),
            self.config.max_connections_per_peer,
        )
    }

    /// The cookie a UDP client at [peer] sends to be answered at length,
    /// for the minute [minute]: only a client that receives datagrams at
    /// that address learns it, so a forged source gets nothing large.
    pub(crate) fn udp_cookie(&self, peer: &str, minute: u64) -> String {
        let signature = self
            .udp_cookie_key
            .sign(format!("conest-udp-cookie|{peer}|{minute}").as_bytes());
        BASE64_STANDARD.encode(&signature.to_bytes()[..16])
    }

    /// Whether [cookie] is [peer]'s, from this minute or the one before.
    pub(crate) fn valid_udp_cookie(&self, peer: &str, cookie: Option<&str>) -> bool {
        let Some(cookie) = cookie else { return false };
        let minute = now_millis() / 60_000;
        cookie == self.udp_cookie(peer, minute)
            || cookie == self.udp_cookie(peer, minute.saturating_sub(1))
    }

    pub(crate) fn note_rate_violation(&self, peer: &str, now_millis_value: u64) {
        let mut bans = self
            .banned_peers
            .lock()
            .expect("ban lock should not poison");
        let entry = bans.entry(peer.to_owned()).or_insert(BanEntry {
            banned_until_millis: 0,
            consecutive_violations: 0,
        });
        entry.consecutive_violations = entry.consecutive_violations.saturating_add(1);
        if entry.consecutive_violations >= self.config.soft_ban_threshold {
            entry.banned_until_millis =
                now_millis_value.saturating_add(self.config.soft_ban_duration.as_millis() as u64);
        }
    }

    pub(crate) fn note_rate_compliance(&self, peer: &str) {
        let mut bans = self
            .banned_peers
            .lock()
            .expect("ban lock should not poison");
        if let Some(entry) = bans.get_mut(peer)
            && entry.banned_until_millis == 0
        {
            // Only reset the counter if no active ban is in flight;
            // otherwise we'd let banned peers wear down the counter
            // mid-ban by piggybacking on others' compliance signals.
            entry.consecutive_violations = 0;
        }
    }

    pub(crate) fn allow_mailbox_bytes(&self, mailbox: &str, bytes: u64) -> bool {
        if self.config.max_bytes_per_mailbox_per_minute == 0 {
            return true;
        }
        let now = now_millis();
        let mut windows = self
            .mailbox_bytes
            .lock()
            .expect("mailbox bytes lock should not poison");
        windows.retain(|_, w| now.saturating_sub(w.window_started_millis) < 120_000);
        let window = windows
            .entry(mailbox.to_owned())
            .or_insert(MailboxByteWindow {
                window_started_millis: now,
                bytes_used: 0,
            });
        if now.saturating_sub(window.window_started_millis) >= 60_000 {
            window.window_started_millis = now;
            window.bytes_used = 0;
        }
        if window.bytes_used.saturating_add(bytes) > self.config.max_bytes_per_mailbox_per_minute {
            return false;
        }
        window.bytes_used = window.bytes_used.saturating_add(bytes);
        true
    }
}
