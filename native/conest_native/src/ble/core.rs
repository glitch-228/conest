//! Bounded, OS-independent BLE link state. Radio bytes are never trusted.
use std::collections::{BTreeMap, VecDeque};

use base64::{Engine as _, engine::general_purpose::STANDARD};
use serde::Serialize;

pub const MAX_LINKS: usize = 8;
pub const MAX_WRITE: usize = 512;
pub const MAX_PACKET: usize = 4096;
pub const MAX_QUEUE_BYTES: usize = 16 * 1024;
pub const MAX_QUEUE_PACKETS: usize = 64;
pub const MAX_EVENTS: usize = 256;
const MAX_BACKOFF: usize = 128;
const MAX_CHUNKS_PER_SECOND: u32 = 256;
const MAX_BYTES_PER_SECOND: usize = 16 * 1024;
const MAX_PACKETS_PER_SECOND: u32 = 40;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Role {
    Central,
    Peripheral,
}

#[derive(Clone, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Status {
    pub adapter: Option<String>,
    pub powered: bool,
    pub central: bool,
    pub peripheral: bool,
    pub scanning: bool,
    pub problem: Option<String>,
    pub dropped_events: u64,
    pub dropped_input: u64,
}

#[derive(Serialize)]
pub struct Event {
    pub link: String,
    pub data: String,
}

#[derive(Serialize)]
pub struct Poll {
    pub events: Vec<Event>,
    pub links: BTreeMap<String, usize>,
    pub status: Status,
}

struct Link {
    peer: u64,
    role: Role,
    limit: Option<usize>,
    queue: VecDeque<Vec<u8>>,
    queued_bytes: usize,
    input: Reassembler,
    since: u64,
    heard: u64,
    second: u64,
    chunks: u32,
    bytes: usize,
    packets: u32,
}

pub struct Core {
    local: u64,
    next: u64,
    links: BTreeMap<u64, Link>,
    backoff: BTreeMap<u64, (u64, u64)>,
    events: VecDeque<Event>,
    pub status: Status,
}

impl Default for Core {
    fn default() -> Self {
        Self {
            local: 0,
            next: 0,
            links: BTreeMap::new(),
            backoff: BTreeMap::new(),
            events: VecDeque::new(),
            status: Status::default(),
        }
    }
}

impl Core {
    pub fn set_local(&mut self, local: u64) {
        self.local = local;
    }

    pub fn id(id: u64) -> String {
        format!("ble:{id:016x}")
    }

    pub fn parse_id(id: &str) -> Option<u64> {
        (id.len() == 20 && id.starts_with("ble:"))
            .then(|| u64::from_str_radix(&id[4..], 16).ok())
            .flatten()
    }

    /// Reserve before starting any OS work, including connection setup.
    /// A lower local address keeps the central direction of a crossed link.
    /// Both directions use the same rule; a lone incoming link is always usable.
    pub fn reserve(&mut self, peer: u64, role: Role, now: u64) -> Option<u64> {
        if peer == self.local || peer == 0 {
            return None;
        }
        if let Some((&id, old)) = self.links.iter().find(|(_, link)| link.peer == peer) {
            let preferred = if self.local < peer {
                Role::Central
            } else {
                Role::Peripheral
            };
            if old.role == role || role != preferred {
                return None;
            }
            self.remove(id, false, now);
        } else if role == Role::Central && self.backoff.get(&peer).is_some_and(|b| now < b.0) {
            return None;
        }
        self.expire(now);
        if self.links.len() >= MAX_LINKS {
            return None;
        }
        self.next = self.next.checked_add(1)?;
        let id = self.next;
        self.links.insert(
            id,
            Link {
                peer,
                role,
                limit: None,
                queue: VecDeque::new(),
                queued_bytes: 0,
                input: Reassembler::default(),
                since: now,
                heard: now,
                second: now / 1000,
                chunks: 0,
                bytes: 0,
                packets: 0,
            },
        );
        Some(id)
    }

    pub fn peer_link(&self, peer: u64, role: Role) -> Option<u64> {
        self.links
            .iter()
            .find_map(|(&id, l)| (l.peer == peer && l.role == role).then_some(id))
    }

    pub fn has_peer(&self, peer: u64) -> bool {
        self.links.values().any(|link| link.peer == peer)
    }

    pub fn contains(&self, id: u64) -> bool {
        self.links.contains_key(&id)
    }

    /// A central that writes to this device's characteristic: its existing
    /// link, or a new one ready at once. (BlueZ may deliver the first write
    /// before telling anyone of the subscription, and tells only the first
    /// subscriber's at all.)
    pub fn admit_peripheral(&mut self, peer: u64, limit: usize, now: u64) -> Option<u64> {
        if let Some(id) = self.peer_link(peer, Role::Peripheral) {
            return Some(id);
        }
        let id = self.reserve(peer, Role::Peripheral, now)?;
        if !self.ready(id, limit) {
            self.remove(id, false, now);
            return None;
        }
        Some(id)
    }

    /// Links in one role, oldest first.
    pub fn role_links(&self, role: Role) -> Vec<u64> {
        self.links
            .iter()
            .filter_map(|(&id, link)| (link.role == role).then_some(id))
            .collect()
    }

    pub fn ready(&mut self, id: u64, limit: usize) -> bool {
        let Some(link) = self.links.get_mut(&id) else {
            return false;
        };
        if limit == 0 {
            return false;
        }
        link.limit = Some(limit.min(MAX_WRITE));
        self.backoff.remove(&link.peer);
        true
    }

    pub fn remove(&mut self, id: u64, failed: bool, now: u64) {
        if let Some(link) = self.links.remove(&id) {
            if failed && link.role == Role::Central {
                let delay = self
                    .backoff
                    .get(&link.peer)
                    .map_or(30_000, |b| (b.1 * 2).min(300_000));
                if self.backoff.len() >= MAX_BACKOFF && !self.backoff.contains_key(&link.peer) {
                    if let Some(peer) = self
                        .backoff
                        .iter()
                        .min_by_key(|(_, b)| b.0)
                        .map(|(&p, _)| p)
                    {
                        self.backoff.remove(&peer);
                    }
                }
                self.backoff
                    .insert(link.peer, (now.saturating_add(delay), delay));
            }
        }
    }

    pub fn clear_links(&mut self) {
        self.links.clear();
        self.events.clear();
    }

    pub fn expire(&mut self, now: u64) {
        let expired: Vec<_> = self
            .links
            .iter()
            .filter_map(|(&id, l)| {
                ((l.limit.is_none() && now.saturating_sub(l.since) > 15_000)
                    || now.saturating_sub(l.heard) > 120_000)
                    .then_some(id)
            })
            .collect();
        for id in expired {
            self.remove(id, true, now);
        }
    }

    pub fn enqueue(&mut self, id: u64, bytes: &[u8]) -> bool {
        let Some(link) = self.links.get_mut(&id) else {
            return false;
        };
        if bytes.is_empty()
            || bytes.len() > link.limit.unwrap_or(0)
            || link.queue.len() >= MAX_QUEUE_PACKETS
            || link.queued_bytes + bytes.len() > MAX_QUEUE_BYTES
        {
            return false;
        }
        link.queue.push_back(bytes.to_vec());
        link.queued_bytes += bytes.len();
        true
    }

    pub fn broadcast(&mut self, bytes: &[u8], except: Option<u64>) -> usize {
        let ids: Vec<_> = self.links.keys().copied().collect();
        ids.into_iter()
            .filter(|id| Some(*id) != except && self.enqueue(*id, bytes))
            .count()
    }

    /// One OS task owns each link's writer. At most one additional packet
    /// (512 bytes) can be in flight outside its bounded queue.
    pub fn take_write(&mut self, id: u64) -> Option<Vec<u8>> {
        let link = self.links.get_mut(&id)?;
        let bytes = link.queue.pop_front()?;
        link.queued_bytes -= bytes.len();
        Some(bytes)
    }

    pub fn receive(&mut self, id: u64, bytes: &[u8], now: u64) {
        let Some(link) = self.links.get_mut(&id) else {
            return;
        };
        if link.second != now / 1000 {
            link.second = now / 1000;
            link.chunks = 0;
            link.bytes = 0;
            link.packets = 0;
        }
        link.chunks = link.chunks.saturating_add(1);
        link.bytes = link.bytes.saturating_add(bytes.len());
        if bytes.is_empty()
            || bytes.len() > MAX_PACKET
            || link.limit.is_none()
            || link.chunks > MAX_CHUNKS_PER_SECOND
            || link.bytes > MAX_BYTES_PER_SECOND
        {
            link.input = Reassembler::default();
            self.status.dropped_input = self.status.dropped_input.saturating_add(1);
            return;
        }
        let packets = match link.input.push(bytes, now) {
            Ok(packets) => packets,
            Err(()) => {
                self.status.dropped_input = self.status.dropped_input.saturating_add(1);
                return;
            }
        };
        for bytes in packets {
            link.packets = link.packets.saturating_add(1);
            if link.packets > MAX_PACKETS_PER_SECOND {
                self.status.dropped_input = self.status.dropped_input.saturating_add(1);
                continue;
            }
            link.heard = now;
            if self.events.len() >= MAX_EVENTS {
                self.events.pop_front();
                self.status.dropped_events = self.status.dropped_events.saturating_add(1);
            }
            self.events.push_back(Event {
                link: Self::id(id),
                data: STANDARD.encode(bytes),
            });
        }
    }

    pub fn limits(&self) -> BTreeMap<String, usize> {
        self.links
            .iter()
            .filter_map(|(&id, l)| l.limit.map(|limit| (Self::id(id), limit)))
            .collect()
    }

    pub fn poll(&mut self) -> Poll {
        Poll {
            events: self.events.drain(..self.events.len().min(32)).collect(),
            links: self.limits(),
            status: self.status.clone(),
        }
    }

    pub fn scan_due(now: u64) -> bool {
        now % 30_000 < 20_000
    }
}

/// BLE notifications have no Conest framing. Read the existing bitchat
/// length fields and strip only its optional block padding. Do not inflate,
/// authenticate or change wire packets here; Dart handles those operations.
#[derive(Default)]
struct Reassembler {
    bytes: Vec<u8>,
    padding: (u8, usize),
    last: u64,
}

impl Reassembler {
    fn push(&mut self, mut chunk: &[u8], now: u64) -> Result<Vec<Vec<u8>>, ()> {
        if now.saturating_sub(self.last) > 5000 {
            *self = Self::default();
        }
        self.last = now;
        if chunk.len() > MAX_PACKET || self.bytes.len() + chunk.len() > MAX_PACKET {
            *self = Self::default();
            return Err(());
        }
        let mut out = Vec::new();
        while !chunk.is_empty() {
            if self.bytes.is_empty() && self.padding.1 > 0 {
                if chunk[0] == self.padding.0 {
                    self.padding.1 -= 1;
                    chunk = &chunk[1..];
                    continue;
                }
                self.padding = (0, 0);
            }
            // Append incrementally so concatenated packets and a following
            // padding block are handled without ambiguous buffer boundaries.
            self.bytes.push(chunk[0]);
            chunk = &chunk[1..];
            let size = match packet_size(&self.bytes) {
                Ok(size) => size,
                Err(()) => {
                    *self = Self::default();
                    return Err(());
                }
            };
            if size == Some(self.bytes.len()) {
                let raw = std::mem::take(&mut self.bytes);
                let target = [256, 512, 1024, 2048]
                    .into_iter()
                    .find(|b| raw.len() + 16 <= *b);
                let padding = target.map_or(0, |b| b - raw.len());
                self.padding = if padding <= 255 {
                    (padding as u8, padding)
                } else {
                    (0, 0)
                };
                out.push(raw);
            }
        }
        Ok(out)
    }
}

fn packet_size(bytes: &[u8]) -> Result<Option<usize>, ()> {
    let version = bytes[0];
    if version != 1 && version != 2 {
        return Err(());
    }
    let header = if version == 1 { 14 } else { 16 };
    if bytes.len() < header {
        return Ok(None);
    }
    let flags = bytes[11];
    if flags & !15 != 0 || (version == 1 && flags & 8 != 0) {
        return Err(());
    }
    let payload = if version == 1 {
        u16::from_be_bytes(bytes[12..14].try_into().map_err(|_| ())?) as usize
    } else {
        u32::from_be_bytes(bytes[12..16].try_into().map_err(|_| ())?) as usize
    };
    if payload > MAX_PACKET {
        return Err(());
    }
    let mut size = header + 8 + if flags & 1 != 0 { 8 } else { 0 };
    if flags & 8 != 0 {
        if bytes.len() <= size {
            return Ok(None);
        }
        size += 1 + bytes[size] as usize * 8;
    }
    size += payload + if flags & 2 != 0 { 64 } else { 0 };
    if size > MAX_PACKET {
        return Err(());
    }
    Ok(Some(size))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_first_write_admits_its_central_once() {
        let mut core = Core::default();
        core.set_local(9);
        let id = core.admit_peripheral(5, 180, 0).unwrap();
        assert_eq!(core.admit_peripheral(5, 180, 1), Some(id));
        assert_eq!(core.role_links(Role::Peripheral), vec![id]);
        // Ready at once: packets can go out before any subscription event.
        assert!(core.enqueue(id, &[1, 2, 3]));
        // A zero MTU admits nothing and leaves nothing behind.
        assert_eq!(core.admit_peripheral(6, 0, 2), None);
        assert!(!core.has_peer(6));
        // Our own address is never a peer.
        assert_eq!(core.admit_peripheral(9, 180, 3), None);
    }

    fn packet(version: u8, flags: u8) -> Vec<u8> {
        let mut p = vec![version, 0x11, 7];
        p.extend_from_slice(&123_u64.to_be_bytes());
        p.push(flags);
        if version == 1 {
            p.extend_from_slice(&31_u16.to_be_bytes());
        } else {
            p.extend_from_slice(&31_u32.to_be_bytes());
        }
        p.extend_from_slice(&[5; 8]);
        if flags & 1 != 0 {
            p.extend_from_slice(&[6; 8]);
        }
        if flags & 8 != 0 {
            p.push(2);
            p.extend_from_slice(&[7; 16]);
        }
        p.extend_from_slice(&[42; 31]);
        if flags & 2 != 0 {
            p.extend_from_slice(&[8; 64]);
        }
        p
    }

    struct MockAdapter {
        writes: Vec<(u64, Vec<u8>)>,
    }
    impl MockAdapter {
        fn pump(&mut self, core: &mut Core, id: u64) {
            if let Some(bytes) = core.take_write(id) {
                self.writes.push((id, bytes));
            }
        }
    }

    #[test]
    fn link_table_and_queue_limits() {
        let mut c = Core::default();
        for peer in 1..=MAX_LINKS as u64 {
            let id = c.reserve(peer, Role::Central, 0).unwrap();
            assert!(!c.enqueue(id, &[1])); // setup is not yet usable
            assert!(c.ready(id, 517));
        }
        assert!(c.reserve(99, Role::Central, 0).is_none());
        assert_eq!(c.limits().len(), MAX_LINKS);
        assert!(!c.enqueue(1, &[0; 513]));
        for _ in 0..MAX_QUEUE_BYTES / MAX_WRITE {
            assert!(c.enqueue(1, &[0; MAX_WRITE]));
        }
        assert!(!c.enqueue(1, &[1]));
        let mut mock = MockAdapter { writes: Vec::new() };
        mock.pump(&mut c, 1);
        assert_eq!(mock.writes, vec![(1, vec![0; MAX_WRITE])]);
        assert!(c.enqueue(1, &[1]));
        for _ in 0..MAX_QUEUE_PACKETS {
            c.enqueue(2, &[1]);
        }
        assert!(!c.enqueue(2, &[1]));
        assert_eq!(c.broadcast(&[3], Some(2)), MAX_LINKS - 1);
        assert_eq!(c.links[&2].queue.len(), MAX_QUEUE_PACKETS);
        c.remove(1, false, 0);
        assert!(!c.enqueue(1, &[1]));
    }

    #[test]
    fn crossed_links_converge_and_stale_callbacks_cannot_remove_replacement() {
        for local in [1, 3] {
            let mut c = Core::default();
            c.set_local(local);
            let preferred = if local == 1 {
                Role::Central
            } else {
                Role::Peripheral
            };
            let other = if preferred == Role::Central {
                Role::Peripheral
            } else {
                Role::Central
            };
            let old = c.reserve(2, other, 0).unwrap();
            let new = c.reserve(2, preferred, 0).unwrap();
            assert_ne!(old, new);
            c.remove(old, true, 0);
            assert!(c.contains(new));
            assert!(c.reserve(2, other, 0).is_none());
            assert_eq!(c.links.len(), 1);
        }
    }

    #[test]
    fn packets_split_at_every_boundary_including_padding_and_routes() {
        for (v, flags) in [(1, 0), (1, 3), (2, 11), (2, 15)] {
            let raw = packet(v, flags);
            let mut padded = raw.clone();
            let pad = 256 - padded.len();
            padded.extend(vec![pad as u8; pad]);
            padded.extend_from_slice(&raw);
            for split in 0..=padded.len() {
                let mut r = Reassembler::default();
                let mut out = r.push(&padded[..split], 0).unwrap();
                out.extend(r.push(&padded[split..], 1).unwrap());
                assert_eq!(out, vec![raw.clone(), raw.clone()], "v{v} split {split}");
            }
            let mut r = Reassembler::default();
            let out: Vec<_> = padded
                .iter()
                .flat_map(|b| r.push(&[*b], 0).unwrap())
                .collect();
            assert_eq!(out, vec![raw.clone(), raw]);
        }
    }

    #[test]
    fn rejects_oversize_malformed_and_expired_partial_packets() {
        let mut r = Reassembler::default();
        assert!(r.push(&[0; MAX_PACKET + 1], 0).is_err());
        let mut bad = packet(2, 0);
        bad[12..16].copy_from_slice(&u32::MAX.to_be_bytes());
        assert!(r.push(&bad, 0).is_err());
        let raw = packet(1, 3);
        assert!(r.push(&raw[..20], 0).unwrap().is_empty());
        assert!(r.push(&raw[20..], 6000).is_err());
        assert_eq!(r.push(&raw, 6001).unwrap(), vec![raw]);
    }

    #[test]
    fn notification_flood_and_event_buffer_are_bounded() {
        let mut c = Core::default();
        let id = c.reserve(1, Role::Central, 0).unwrap();
        c.ready(id, 512);
        let p = packet(1, 0);
        for _ in 0..10_000 {
            c.receive(id, &p, 0);
        }
        assert_eq!(c.events.len(), MAX_PACKETS_PER_SECOND as usize);
        assert!(c.status.dropped_input > 0);
        for second in 1..20 {
            for _ in 0..40 {
                c.receive(id, &p, second * 1000);
            }
        }
        assert_eq!(c.events.len(), MAX_EVENTS);
        assert!(c.status.dropped_events > 0);
        let poll = c.poll();
        assert_eq!(poll.events.len(), 32);
        assert_eq!(poll.links.len(), 1);
        assert_eq!(c.events.len(), MAX_EVENTS - 32);
        c.clear_links();
        assert!(c.events.is_empty());
    }

    #[test]
    fn retries_duty_cycle_and_setup_slots_are_bounded() {
        let mut c = Core::default();
        for peer in 1..300 {
            let id = c.reserve(peer, Role::Central, 0).unwrap();
            c.remove(id, true, 0);
        }
        assert_eq!(c.backoff.len(), MAX_BACKOFF);
        assert!(c.reserve(299, Role::Central, 29_999).is_none());
        let id = c.reserve(299, Role::Central, 30_000).unwrap();
        c.remove(id, true, 30_000);
        assert!(c.reserve(299, Role::Central, 89_999).is_none());
        assert!(c.reserve(299, Role::Central, 90_000).is_some());
        c.expire(105_001);
        assert!(c.links.is_empty());
        assert!(Core::scan_due(19_999));
        assert!(!Core::scan_due(20_000));
        assert!(Core::scan_due(30_000));
    }
}
