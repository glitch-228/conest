# Conest implementation roadmap

Approved 2026-09-09. Reference baseline: README.md, NIGHTLY_RELEASE_NOTES.md,
v0.3.9 nightly. Priority updated 2026-09-14: M4 → M3 → remaining M2,
with outstanding M1 qualification retained. Web clients and voice calls are
documentation only until separately scheduled. Preserve colors and the existing 16-member cap.

## Current implementation cadence (2026-09-15)

### Resource priority update (2026-09-17)

Minimize token/limit use while pursuing the full goal. Implement release-critical
end-to-end features in larger batches; use bounded sub-agents with separate file
ownership and concise handoffs. Run only crucial checks for authorization, data
integrity, restart recovery, and touched integration paths. Avoid repeated broad
exploration, full suites, cosmetic tests, and repeated status-only turns. Delegate
small tasks or defer them with UI polish until after the core release. Record
unverified behavior honestly; do not shrink the full goal or claim release readiness
from isolated unit tests. Immediate priority: native group-file LAN/Iroh bridge,
sender seeding and receive controls, then release-candidate device testing.

Current handoff: service/transport agents stopped with workspace-credit errors;
their bounded service, wire, store, scheduler, and tile work is now integrated
and committed. Physical network qualification is still open; do not treat the
focused tests as native interoperability evidence.

Reviewed integration update: service, transport and minimal tile are now combined
with signed attachment metadata projection and vault message persistence. Fixed
availability cancellation window accounting; fourteen focused tests pass (service,
transport, file core). Still callback-level transport, not native qualification.

Next bounded release tasks (keep ownership separate):
1. Native bridge: encrypt/decrypt group-file binary frames using authenticated
   group-member identities; route through LAN binary ingress and Iroh binary
   sends. Bind group/event/request before routing to the session. Preserve 2 MiB
   ordinary-envelope limit; group frames may carry a 4 MiB piece. Join underlying
   sends on cancellation, since Iroh adapter cancellation currently does not.
2. Controller service wiring: instantiate one service per identity, connect
   signed history authorization and vault preferences, implement storage-space
   reservation plus route/Iroh limits, seed outgoing staged copies, refresh peer
   availability on reconnection, and close sessions before identity reset.
3. User flow: connect group picker/drop/paste to publishing, bind tile progress
   and Download/Pause/Resume/Stop sharing/Open actions to live sessions. Current
   metadata tile alone does not implement those actions.
4. Release gate: focused direct-transfer regression and real Android/Linux LAN
   and Iroh group transfer; publish matching debug candidate without waiting for
   asynchronous build results. Record tester evidence before release/nightly.

Native bridge progress: `CryptoService` encrypts/decrypts bounded group binary
frames with a separately derived key and authenticated group/event/request/sender/
recipient header. The controller now sends 4 MiB pieces through Iroh's binary
attachment-range framing and the existing LAN `/v2/block` channel, verifies LAN
ciphertext digests, and authorizes/decrypts frames before session delivery. Group
drop publishing hashes and signs a manifest, seeds the verified cache, and
announces durable history. Cancellation still joins tracked sends; the underlying
Iroh adapter has no native abort. Focused integrity/recovery checks pass; physical
LAN/Iroh qualification and multi-provider qualification remain open.

Iroh bridge wiring recognizes group binary magic before ordinary envelope parsing,
pins ingress to the signed member's Iroh identity, resolves the retained
authorized manifest, decrypts, and dispatches to its session. LAN discovery is
attempted before online discovery when a peer advertises a binary endpoint. Group
downloads retain the storage reserve, 15 MiB automatic online threshold, and
Iroh size policy. Multi-provider/device qualification and any remaining route
fallback defects are still outstanding.

Release-first priority update: stabilize direct messaging/files on LAN/Iroh,
qualify group messaging, then deliver core multi-peer group files and a release
candidate. Pause additional Telegram layout work and cosmetic polish. Remaining
M4/M2 requirements stay in this roadmap for after the usable release; the full
goal is not complete until they are implemented and qualified.

Per user direction: implement core features in larger batches. Run only crucial
correctness checks during implementation; leave broader device/UI testing to the
user/testers and final polishing to the final phase. Interim debug artifacts may
use the explicit `quick_build` workflow option, which builds all platforms without
qualification tests. Such artifacts are unqualified development snapshots, not
nightly-release evidence. Do not wait for their results unless the user asks.

Interim snapshot dispatched on 2026-09-15: `df5304c`, branch
`debug/m4-midimplementation-20260915`, Android/Linux/Windows with `quick_build`.
Run: https://github.com/glitch-228/conest/actions/runs/35017669082
Workflow results have not been checked, per user direction.

Core group-file batches after that snapshot: `65fb3ba` adds authored group
publishing and Iroh binary-range delivery; `82ccea9` adds LAN binary-block
delivery and LAN-first provider discovery. Debug artifact dispatched from
`82ccea9`: https://github.com/glitch-228/conest/actions/runs/35714230152.
The artifact is an unqualified development build until physical tester results
are recorded.

Subsequent core work (not in that artifact): author-scoped group edit/deletion
reducer and rebuildable journal mutation indexes. Deletion dominates subsequent
edits; malformed records and other authors cannot shadow a valid mutation.
Focused journal/projection tests: 18 passed initially; the projection suite now
has 5 passing tests including persisted tombstones. Coordinator projection and
controller mutation creation are connected: mutations are signed, persisted before
peer hints, and checked against the original author and membership history. Hidden
tombstones survive vault saves and prevent replay/retry resurrection. History page
projection now persists its result. The two simulated Iroh catch-up/admission
tests pass, with the carrier scenario extended to reject another member's edit,
carry an offline edit, and propagate deletion with the original author offline.
This does not establish physical network qualification.

Group text edit/delete controls are now wired, including the edited marker and
compatibility notices for older/unconfirmed peers. Support is learned only from
correlated authenticated history responses; reconnect clears that knowledge.
Catch-up refreshes retained messages through journal indexes so mutations outside
the initial page still apply, while older unseen text stays paginated. Unchanged
projections avoid rewriting conversation lists. Automated: 9 focused wire and
projection tests plus 2 catch-up/admission tests pass; the carrier test now buries
a deletion under 55 later events. UI/device qualification, reaction events, and
remaining M4 features are still outstanding. These changes are not in the earlier
dispatched debug artifact.

## Status and delivery

- [x] Record the approved roadmap.
- [ ] M1: implemented and debug artifacts built; physical network qualification remains.
- [ ] M2: basic authenticated catch-up working; remaining requirements deferred
  until after M4 and M3, except blocking regressions.
- [ ] M3: group attachments from multiple providers (core signed/verified LAN and
  Iroh path implemented; provider switching and physical qualification remain).
- [ ] M4: Telegram interface and everyday chat features — active priority.

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
- Foundation commit: `4afc1c7`. Added signed membership records anchored to the
  approved owner, historical author checks, current carrier/recipient checks,
  immutable admission references, checkpoint-based since-admission policy,
  admin/owner authorization and owner resolution of competing membership heads.
  Membership changes during signature verification invalidate the decision.
- 21 focused history/membership tests passed: partition arrival order, duplicates,
  restart, forgery, wrong key/group, corruption, immutable payloads, inventory
  gaps, pagination, the 1 MiB page budget, history policy changes, removal,
  re-admission, owner handoff, admin restrictions and membership conflicts.
  These are storage/protocol tests,
  not the four-device transport catch-up acceptance tests.
- Added a durable replica/exchange engine: dependency-ordered membership replay,
  validate-before-flush membership publication, bounded inventories and event
  requests, encrypted resumable cursors, and retry of bounded partial responses.
  Journal offsets and retained IDs prevent duplicate writes/downloads.
- **27 history tests passed**, including four-replica A/B → C → D carriage,
  independently active partitions, interrupted catch-up plus restart, one-page
  work budgets across restarts, partial responses and failed membership writes.
  The exchange interface is exercised in-process; this does not qualify native
  transport or physical isolated-LAN behavior.
- Controller integration now archives newly sent group text, attaches signed
  membership proofs to membership updates, and exposes encrypted group-scoped
  catch-up with strict request/peer/group correlation. Compatible group traffic
  schedules debounced catch-up. Vault close/reset also closes/removes journals.
- Initial text projection keeps original authorship and handles sender-controlled
  legacy message-ID collisions. Bounded pages and author-scoped source indexes
  prevent repeated imports from replacing existing messages.
- Full Flutter suite after controller integration: **344 passed, 6 optional
  certifications skipped**. Additional focused checks cover the source-ID
  regression and native Iroh catch-up. The four-controller simulated-Iroh test
  proves C → D carriage with A/B disconnected and no C/D private contact.
- Startup, network reconnection and group conversation opening now schedule
  debounced catch-up against active signed group peers. The four-controller
  partition regression passes using the network-change and conversation-open
  hooks instead of manually invoking both catch-up exchanges (2026-09-14).
- Group details now exposes the owner-only **History for new members** choice:
  all retained history (default) or since admission. Policy updates are signed
  membership records, preserve existing admission IDs, and new admissions capture
  retained author sequence/event checkpoints rather than wall-clock time.
  The controller regression verifies owner-only updates and subsequent partition
  catch-up; comprehensive widget/admission qualification remains outstanding.
- End-to-end admission regression now verifies older history stays unavailable,
  post-admission messages resume after an offline interval, and later changes
  to all-retained history do not rewrite that member's original grant. This
  exposed and fixed stale in-flight catch-up reuse after an interface change;
  reconnection now cancels old requests and resumes with fresh correlation IDs.
- Added a group-chat **Load older messages** control using stable signed-event
  cursors. Each page rechecks history authorization; the controller admission
  regression verifies pagination does not reveal pre-admission messages.
  Large-history widget/scroll-position qualification remains outstanding.
- Remaining M2 integration:
  complete event projection/authorization
  (edits/deletions/reactions/receipts), migration and conversation pagination
  remain necessary before claiming the milestone complete. Finish journal-backed
  conversation persistence/pagination (the current projection still enters the
  vault snapshot), legacy outgoing-history migration, admission after owner
  handoff, and off-UI validation/profile measurements. Persist local
  removal independently of received proofs; recheck membership before sending
  each history batch. Four-device isolated-LAN catch-up remains unqualified.

## M3 — group files

Core work started: versioned attachment-event manifest with whole-file and 4 MiB
piece hashes, off-UI single-pass file hashing (one piece of working memory), and
a bounded scheduler selecting scarce pieces, preferring LAN and spreading load.
Reservations cap at four pieces and three peers; stalled/withdrawn providers
release reservations and late replies cannot inflate unique durable progress.
Added app-owned partial-piece storage with verification before flush/rename,
verification on recovery and before serving, and whole-file verification before
publishing an assembled file. Worker entry points run outside the UI isolate;
queued writes are capped at four pieces. Five focused core tests pass and analysis
is clean, including damaged cache recovery and inconsistent whole-file manifests.
These modules are not yet connected to group publishing, binary transport,
or chat download controls. Receive policy, authorization, storage reservation,
sharing preferences and single-owner store lifecycle must be integrated by the
group transfer service. Existing direct-file
transfer behavior is unchanged by this foundation.

History integration added: coordinator can publish author-signed attachment
events, project retained manifests through an attachment callback, and authorize
a provider/recipient pair against signed membership and admission history before
resolving a file. Controller/transport/UI wiring remains outstanding. Fourteen
focused membership and file-core tests pass, including file-manifest forwarding
and removal denial; this does not yet test an actual group file transfer.

Download-session integration: scheduler and durable store now run as one bounded
pump with shared concurrent wakeups, verified progress, corruption/provider
fallback, pause, restart recovery, and final assembly. Authorization and current
route policy are checked before fetching and again before writing received bytes.
Seven file-core tests pass, including corrupt-provider replacement, cached restart
without network reads, and removal during fetch; analysis is clean. Transport
callbacks must release timed-out requests before returning. Native LAN/Iroh
callbacks, durable acceptance/sharing preferences, storage reservations and chat
controls are still required before this becomes user-facing group file transfer.

Provider integration: verified partial-file availability and piece reads now
recheck authorization around disk work; reads are bounded and concurrent
availability scans are shared. Stop sharing disables immediately and invalidates
in-flight reads without deleting cached bytes. Persistence is injected and still
needs the application vault connection. Eight file-core tests pass, including a
download assembled from two separate partial providers and denied reads after
Stop sharing. This is an in-process storage/session test, not LAN/Iroh proof.

Vault integration now retains per-group/event acceptance, pause, sharing, and
storage-reserve override with legacy-safe defaults. The controller requires a
retained signed manifest and current history permission before updating these
preferences. Nine focused file/provider/preference tests pass. Running providers
and downloads still need to be wired to these preferences by the group transfer
service; no claim of an operational group file UI or native transport yet.

Binary request correlation added: per-file requests bind authenticated peer,
event, piece index and exact length, with at most four pending requests. Timeout
completion waits for the transport cancellation callback; late/duplicate replies
are ignored. Eleven focused core/provider/preference/wire tests pass. This layer
still requires native LAN/Iroh send/receive and cancellation callbacks; it does
not establish native transport support by itself.

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

### M4 progress (2026-09-14)

- Restored pending-contact-request visibility in Courier through a chat-list
  request row/count and drawer inbox. The inbox updates after approval/rejection.
  Review now displays the same pairwise safety number used by approved contacts,
  without granting trust during preview; rejection errors are surfaced. The
  existing controller approval and identity checks remain authoritative.
  Analyzer qualification only; inbox interaction and Iroh approval/rejection
  integration tests remain in the rollout gates.

- Courier direct/group timelines now display calendar-day separators, localized
  compact message times and tighter bubble spacing. Courier app themes use Roboto
  text and compact, flat app bars while preserving palette values; bootstrap and
  onboarding receive the same theme. Legacy layouts keep their display font.
  Calendar/time, album boundaries, scaling and visual-reference checks remain
  outstanding for the integrated UI validation pass.

- Added Courier desktop chat navigation with Alt+Up/Down in the visible filtered
  order, Ctrl/Cmd+K for chat search and Ctrl/Cmd+N for the contact picker. Local
  draft changes notify the sidebar separately so previews update while typing
  without broadcasting a full controller rebuild. Removed the overlapping global
  Transfers floating button in Courier; transfers remain in the drawer.
  Analysis passes. Shortcut, draft-rebuild and navigation qualification remains
  part of the integrated M4 test pass.

- Added adaptive full-screen Courier pages on narrow displays for settings,
  contact profiles, adding contacts, group creation and group details, retaining
  desktop and legacy-layout dialogs. Mobile settings exposes Personal, Storage,
  Connectivity, Relays, Updates and Account categories backed by existing form
  state/actions. Keyboard, scrolling, scaling and screenshots await the integrated
  M4 validation pass; this is not a claim of complete visual parity.

- Added direct/group in-chat search for loaded text and filenames, reachable
  from the chat header and Ctrl/Cmd+F. Search results navigate to the matching
  message or album anchor and flash it. Group search can request older authorized
  pages. Navigation yields frames while seeking lazily built rows; large-history,
  highly variable row heights and concurrent catch-up still need qualification.
  Full journal search indexing and query highlighting remain outstanding.

- Added directional swipe-to-reply for Courier direct/group message lists and
  album rows, with threshold, cancellation, haptic feedback and return animation.
  Selection disables the gesture. Added searchable text forwarding to contacts
  and groups through existing send APIs (new author/message identity), plus a
  direct-message Reply menu action and Message details for route metadata.
  Attachment forwarding and comprehensive gesture/forwarding tests remain pending.

- Added encrypted local pin/archive/mute flags with legacy defaults. Courier
  sorts pinned chats first, exposes archive navigation, retains archived chats in
  search, and offers pin/unpin, mute/unmute and archive/unarchive through mobile
  long-press sheets and desktop right-click menus. Draft previews and pin/mute
  indicators are shown in rows. Muting suppresses direct/group message alerts
  and dismisses the existing conversation notification. Notification, persistence
  and menu integration tests remain for the integrated M4 validation batch.

- UI work now proceeds in larger integrated batches, per user preference:
  analyzer checks during implementation, comprehensive UI/regression tests after
  screen structure and interactions are integrated.
- Added Courier navigation drawer (identity, contacts, groups, LAN lobby,
  transfers, invites, Beam, settings and debug tools), floating new-message
  action and searchable contact-picker screen. Group creation is accessible
  from both drawer and new-message screen.
- Courier direct/group chats now use edge-to-edge panes, compact tappable
  avatar/title/status headers, and chat-details menus. Direct connection details
  move behind the chat menu; the direct composer uses an icon send action.
  Legacy layouts retain their prior chat frame/header. These changes have only
  analyzer qualification so far; interaction/screenshots remain pending.
- Consulted official Android and Desktop landing pages on 2026-09-14. Specific
  reference build versions and visual comparison are still to be recorded before
  claiming Telegram visual parity.

- Desktop Courier now has a draggable sidebar divider, arrow-key resizing,
  assistive-technology increase/decrease actions and reset via Home/double-click.
  Width is bounded to 300–560 logical pixels, keeping at least 480 for chat.
  Two LTR/RTL divider widget tests pass; the desktop navigation test verifies
  both bounds and reset. Physical desktop qualification and persistence regression
  tests remain outstanding; analysis is clean. Width now persists in
  appearance preferences when an adjustment ends, including reset. Legacy files
  default to 380; stored widths clamp to 300–560. Appearance writes are serialized
  so rapid width/theme changes preserve their order.

- Courier is the default for new installations. Existing preference files migrate
  once, retaining brightness, decoration intensity and the older home-layout
  choice. Subsequent Signature/Garrison selections survive reloads.
- Replaced decorative Courier search with editable, clearable search across
  contact/group names and currently loaded message previews. Matching conversations
  show a matching preview; navigation still opens the conversation normally.
  Full journal search, result highlighting/jump, and large-history performance
  qualification remain outstanding.
- Direct, group and LAN-lobby composers now keep separate text drafts. Drafts
  persist locally in the encrypted vault with debounced writes and are never
  sent as network events. Sending clears the selected conversation's draft.
  Tests cover rapid updates, destination isolation, controller restart, legacy
  decoding and encrypted storage. A desktop Courier navigation widget test
  verifies separate private/lobby composers and restoration on return. Mobile and
  group navigation, reply-target drafts, send-failure restoration and physical
  lifecycle qualification remain outstanding.
- Draft lifecycle: inactive/background transitions and controller disposal flush
  queued edits. A debounced write now detaches its batch before awaiting storage,
  so later keystrokes queue another snapshot. Three focused controller regressions
  pass, covering delayed writes, background/disposal, and restart isolation;
  analysis is clean. Forced process termination can still interrupt an OS write.
- Full-suite run: 349 passed, 6 optional skipped, 1 failed because Courier lacked
  the contact-list online indicator after the default-layout migration. Remote
  commit 9f1be80 supplies presence marks and supersedes the local label fix.
  After integration, all 5 focused presence/draft/navigation regressions pass.
  Analysis is clean. The full suite has not been rerun after this UI-only fix.
- Automated: 10 theme tests pass, including legacy migration and post-migration
  preference persistence; Flutter analysis passes. Search widget/screenshot and
  physical-device qualification remain outstanding. No new debug release yet.

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
