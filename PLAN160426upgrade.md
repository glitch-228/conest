# Revised Roadmap: Relays, LAN Lobby, Files, And Future Mesh

## Summary
- Relay is not required for LAN direct chat, LAN free-for-all chat, or direct file transfer when peers are reachable.
- Relay is required for reliable internet discovery, offline message queues, and fallback when NAT/firewall blocks direct P2P.
- Keep v0.1 focused on text, pairing, route discovery, direct/LAN delivery, relay fallback, and offline queueing.
- Move images/files before v0.4 as v0.3.x work: direct minimal first, torrent-like group transfer after groups and relay maturity.
- Add a simple LAN “free-for-all” lobby in v0.3 so anyone on the same LAN can chat without adding contacts.

## Phase Changes
| Phase | Goal | Decision |
|---|---|---|
| `v0.1` | Reliable 1:1 text base | Text only, contact pairing, LAN/direct routes, default relay list, relay queue, route rediscovery, best-effort direct internet route checks. |
| `v0.1.x` | Hardening gate | Stabilize pairing, reconnect, relay fallback, pending sends, migrations, and debug diagnostics before adding major features. |
| `v0.2` | Trusted groups | Invite-only groups up to 16 members, pairwise encrypted fanout, no attachments yet. |
| `v0.3` | Relay maturity + LAN lobby | Standalone relay package, signed default relay list, quotas/TTL/rate limits, plus simple LAN free-for-all chat. |
| `v0.3.1` | Minimal images/files | 1:1 direct attachment transfer only, small files/images, LAN/direct-internet first, relay metadata only unless relay file queue is explicitly enabled. |
| `v0.3.2` | Group file fulfillment | Torrent-like encrypted chunk transfer for groups, where online members can fetch chunks from multiple peers. |
| `v0.4` | Full local network mode | Stronger LAN route preference, LAN reconnect behavior, local-first UX, and broader local discovery polish. |
| `v0.5` | Multi-device identity | Multiple devices per account, encrypted state sync, per-device sessions, route sync per device. |
| Later | Channels, mesh, big background package | Broadcast/channels, mesh cache/relay nodes, push/background service, media history package, voice/video later. |

## Implementation Changes
- Add `ConversationKind.lanLobby` for LAN free-for-all chat, separate from trusted `direct` and `group` conversations.
- LAN lobby messages should be signed by an ephemeral LAN session key, marked untrusted, visible only on the local network, and not require contact creation.
- LAN lobby should use UDP discovery plus local relay-style TCP delivery; no internet relay fallback for v0.3 lobby messages.
- Add `AttachmentDescriptor`, `AttachmentChunk`, `TransferSession`, `ChunkHash`, and `TransferState` as reserved protocol/storage types before implementing files.
- v0.3.1 direct attachments should send a metadata envelope first, then transfer encrypted chunks over the best direct route.
- v0.3.1 should support images/files in 1:1 chats only, with conservative limits and resumable transfer state.
- v0.3.2 group attachments should use content-addressed encrypted chunks, a manifest, per-recipient access keys, and multi-peer chunk fetching.
- Relays in v0.3.2 should relay only manifests and small control messages by default; large relay-backed file storage belongs to the later background package.
- Future mesh support should reuse the same chunk model, allowing trusted peers or desktop nodes to cache encrypted chunks without reading content.
- Route ranking stays: LAN first, direct internet second, relay third, then pending retry.

## Minimal Relay Package
- Required in v0.1: `health`, `publish_pairing`, `query_pairing`, `store_envelope`, `fetch_envelopes`, queue TTL, basic quotas, and debug loopback.
- Required in v0.3: standalone relay binary, signed default relay list, custom relay list, rate limits, relay identity keys, relay health scoring, and abuse controls.
- Default relay list is the v0.1/v0.3 answer for “different relays can still find each other”; federation is deferred.
- Relay federation comes later and should gossip only bounded rendezvous metadata, not plaintext or unrestricted queues.

## Test Plan
- v0.3 LAN lobby tests: discover LAN participants, send/receive lobby messages without contacts, leave/rejoin LAN, duplicate suppression, warning that lobby users are untrusted.
- v0.3 relay tests: signed default relay list validation, expired/tampered list rejection, codephrase discovery across default relays, queue TTL, quota/rate-limit behavior.
- v0.3.1 attachment tests: direct 1:1 image/file send, cancel, resume, failed route fallback, hash verification, encrypted local storage, receiver offline behavior.
- v0.3.2 group transfer tests: manifest fanout, chunk fetch from multiple online members, missing chunk retry, removed-member exclusion from future files, corrupted chunk rejection.
- Future mesh tests: encrypted chunk cache, peer availability changes, cache eviction, no plaintext exposure, route ranking between direct peer and mesh cache.

## Assumptions
- “Free-for-all” LAN chat means simple local-network lobby, not trusted identity, not internet-visible, and not part of encrypted contact history by default.
- “Direct as minimal” for files means one sender to one receiver over an available direct route, with relay fallback only for metadata/control unless explicitly enabled later.
- “Torrent-like for groups” means encrypted chunk swarm among authorized group members, not public BitTorrent compatibility.
- The bigger Matrix/Telegram-style package is later than v0.5 because it needs mature relay, media storage, quotas, push/background behavior, and multi-device identity.
