# Conest implementation roadmap

Approved 2026-09-09. Reference baseline: README.md, NIGHTLY_RELEASE_NOTES.md,
v0.3.9 nightly. Implement in order; web clients and voice calls are documentation
only until separately scheduled. Preserve colors and the existing 16-member cap.

## Status and delivery

- [x] Record the approved roadmap.
- [ ] M1: implemented and debug artifacts built; physical network qualification remains.
- [ ] M2: signed, durable, peer-carried group history.
- [ ] M3: group attachments from multiple providers.
- [ ] M4: Telegram interface and everyday chat features.

Use separate reviewable commits and matching debug artifacts per milestone.
Record automated checks separately from physical device qualification. Do not
claim simulated transport tests establish native/network interoperability.
Baseline: 22 selected existing controller tests passed during planning; these
cover Iroh pairing/bootstrap and legacy groups, not group Iroh or history sync.

## M1 — transport reliability

- Remove bundled relay endpoints and automatic bootstrap/refresh. Idempotently
  retire previously bundled routes and stale health state without removing
  explicitly configured/imported relays, LAN service, or Iroh discovery/fallback.
  Stale advertisements must not silently restore retired default endpoints.
- Carry signing identity, pinned Iroh endpoint and capabilities in group member
  profiles. Authenticate Iroh group-only peers without trusting them for private
  messages. Preserve contact approval, rejection, presence and recipient receipts.
- Qualify signed QR/paste/Beam pairing over direct and relayed Iroh. Codephrase
  discovery still requires LAN or a shared configured Conest relay.
- Test members who are not direct contacts over isolated LAN, Iroh direct,
  Iroh fallback and a disposable custom relay. Queue across route changes;
  delivered means recipient acknowledgment, not successful relay storage.

### M1 evidence (2026-09-09)

- Implemented relay retirement and custom-route preservation, group profile
  transport pins, group-scoped Iroh ingress, delivery/read receipt lookup/retry,
  membership receipt correlation, and duplicate membership acknowledgment.
- Passed simulated direct/relayed Iroh group-only messages, receipts, private-DM
  rejection, admin removal and re-admission; native direct-Iroh messaging/receipts
  and moderation passed in the final suite.
- Passed actual loopback LAN and a separate signed native Conest relay with
  alternate transports disabled. Three provenance migrations and stale retired
  advertisements passed. Native relay fallback and physical cross-device/network
  qualification remain separate from simulated fallback and local native tests.
- Full Flutter suite: **314 passed, 2 optional certifications skipped** with
  native group Iroh and signed custom-relay certifications enabled. Legacy
  membership updates retain transport pins and reject identity replacement.
  Analyzer reports no issues. Corrected the existing transient binary PUT test
  to inject exactly one block failure and verify recovery by the completed hash.
- Commit `40e532dc240c0bbd67fa896915012df47e0b1cba` passed regular CI and
  [debug #6](https://github.com/glitch-228/conest/actions/runs/34395113241).
  Linux artifacts additionally passed native Iroh and signed custom relay
  group tests. Matching artifact names: `conest-debug-android-arm64-6`,
  `conest-debug-linux-x64-6`, `conest-debug-windows-x64-6` (14-day retention).
  Physical Android/Linux/Windows and native Iroh fallback qualification remain
  outstanding; automated success is not a physical qualification claim.

## M2 — group synchronization

- Add versioned author-signed group events: stable ID, group/author identity,
  author sequence, deterministic ordering, membership reference, payload and
  signature, inside existing encrypted peer envelopes. Carriers cannot change
  authorship. Carry authenticated membership records with history.
- Validate historical messages against their membership record; do not reject
  all older membership versions. Detect membership conflicts and require an
  owner-signed resolution before extending disputed permissions.
- Exchange bounded inventories/missing ranges on reconnect, route changes and
  chat opening; persist cursors and deduplicate. Any authorized holder may
  carry history, without needing the author or owner online.
- Encrypted append-only journal, rebuildable indexes and paginated reads;
  worker-based processing, no full-history rewrite per received batch.
- Owner setting: all retained history (default) or since admission. Capture
  admission event checkpoints, not wall time; changes affect future admissions.
  Prior disclosures cannot be revoked. Disconnected devices cannot learn of a
  removal until it reaches them. Stop serving unauthorized data once known.
- Sync replies, edits, deletion records, reactions, manifests and receipts.
  Local group removal survives ordinary synchronization; re-admission may
  restore it. Retain message metadata after file-cache eviction.
- Retain legacy history locally. Only original authors may sign their retained
  outgoing legacy messages; carriers never synthesize original-author proofs.
- Negotiate capabilities, preserve IDs/roles and supported legacy text, show
  upgrade requirements for unsupported operations. Restart-safe migrations.

Acceptance: A/B talk on isolated LAN and C catches up; A/B/C talk on LAN1,
C moves to D on LAN2 and carries history; independently active partitions
converge despite duplicate/reordered deliveries, restarts and clock differences.
Test forged authors, removed members, membership conflicts and mixed versions.

### M2 progress (2026-09-10)

- Added immutable, versioned Ed25519 events with canonical digests, author
  sequence/predecessor references, Lamport ordering and membership references.
- Added an encrypted append-only journal with a dedicated worker, flushed
  appends, rebuildable offset indexes, bounded pages/ranges, duplicate and
  author-fork detection, exclusive opens and torn-tail recovery.
- 13 focused foundation tests passed: partition arrival order, duplicates,
  restart, forgery, wrong key/group, corruption, immutable payloads, inventory
  gaps, pagination and the 1 MiB page budget. These are storage/protocol tests,
  not the four-device transport catch-up acceptance tests.
- Not yet connected to the controller: membership proof validation, admission
  boundaries, inventory exchange, migration and live conversation pagination
  remain necessary before advertising synchronization support.

## M3 — group files

Inspiration: https://git.private.coffee/PrivateCoffee/transfer.coffee uses
WebTorrent with tracker/STUN/TURN support. Reuse the piece-sharing concept,
not a public tracker: discovery and access stay within authenticated groups.

- Shared direct/group conversation destination and attachment staging. Separate
  original author from serving provider. Signed metadata, whole-file hash and
  individual block hashes: group key holders must not substitute content.
- Advertise verified partial/complete availability. Prefer LAN, select scarce
  blocks, replace stalled providers. Start with 3 providers, 4 outstanding
  4 MiB blocks and a 16 MiB queued-payload cap per download. Prioritize messaging.
- Verify before storing/acknowledging/sharing; verify final file; unique durable
  byte accounting, persistent resume. No destructive retries when providers vanish.
- LAN: auto-download subject to storage. Off LAN: auto-download strictly below
  15 MiB; at/above 15 MiB show Accept/Download. Cached accepted files may seed
  automatically, with per-file Stop sharing. Withdraw availability on eviction.
- Keep the message/filename when no provider is reachable: "Waiting for someone
  with this file". Distinguish checking/reachable/waiting; resume accepted jobs
  when providers return. Available permitted relay storage may also supply data.
- Preserve 10% storage reserve, per-download override, 100 MiB default Iroh
  limit, 2 GiB ceiling and custom-relay limits. Acceptance never bypasses these.
  Recheck network policy on LAN-to-online transitions.

Acceptance: multiple/partial providers; provider loss/return; corrupt blocks;
restart; cache eviction; route changes; authorization; storage rejection;
boundaries at 15/100 MiB; large LAN files. File availability depends on retained
data held by a reachable peer or accessible allowed relay storage.

## M4 — Telegram layout and everyday behavior

Record reference versions of https://telegram.org/android and
https://desktop.telegram.org/ before visual qualification. Preserve colors and
brightness choices. One-time migration selects Telegram/Courier for existing
installations; retain Signature/Garrison choices and later user preferences.

- Complete Courier, including functional search. Mobile conversation list,
  drawer, new-chat action, full-screen chats, profiles/settings, attachment sheets.
  Desktop resizable sidebar/chat/details, keyboard navigation, context menus,
  drag/drop and paste. Telegram typography hierarchy/spacing/avatars/bubbles,
  timestamps/composer/selection/menus/transitions throughout every screen.
- Cover onboarding, approval, invites, group details, media, transfers/settings.
  Put diagnostics in details; ordinary chats retain understandable delivery,
  offline, waiting and availability states. No fake controls for deferred work.
- Working conversation/message search, per-chat drafts, pin/mute/archive,
  swipe reply, long-press selection, copy/forward, edit/delete and reactions.
  Pin/mute/archive/drafts are local. Edits/deletes/reactions are authorized
  synchronized events; forwarding creates a new message by the forwarding user.
- Preserve scroll during catch-up; summarize unread notifications; avoid whole
  screen rebuilds for transfer progress. Widget/screenshot coverage on mobile
  and desktop, keyboard/gesture/navigation/scaling/availability states.

Performance gate: profile builds, identical manual/automatic workloads; manual
LAN throughput target within 10% of automatic baseline, no reproducible
transfer-caused freezes above 100 ms. Record Android/Linux/Windows measurements
separately from automated checks before a nightly.

## Future work — documentation only

### Offline web

Installable cached web app or portable folder/local launcher is acceptable;
single HTML remains a feasibility goal. Abstract filesystem/FFI/storage/transport.
Evaluate messaging/files, encrypted persistence, export/recovery and native-peer
interop. Iroh browser/Wasm uses relay paths; offline LAN needs separate testing.
Reference: https://www.iroh.computer/blog/iroh-0-33-0-browsers-and-discovery-and-0-RTT-oh-my

### Hosted web

Optional relay-hosted client; temporary guest identities and operator quotas.
QR authorization by another device requires linked-device identities and
revocation, not uploading the primary private identity. Plan session lifetime,
storage limits and trust implications of operator-served client code.

### Direct voice

Feasibility comparison: WebRTC/Opus versus Iroh datagram media. Encrypted
one-to-one signaling via current transports; latency/loss, microphone permissions,
audio routing, mute, ringing expiry, Android lifecycle and fallback qualification
before selecting an implementation.

### Broader Telegram parity

Later: chat folders, scheduled messages, polls and voice messages; specify their
offline synchronization and storage semantics when scheduled.
