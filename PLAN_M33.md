# M33: full sync between own devices

Read `/home/glitch/Documents/conest/PLAN_AGENTS.md` in full first. It holds the shared rules: Lanes, Design note first, Known pitfalls 1–20 and Strict fakes.

- **Worktree:** `/home/glitch/Documents/conest/.worktrees/agent-m33`
- **Branch:** `agent/m33-own-device-sync`
- **Base:** `integration/g7-g8` (d794362).
  - M29 (groups by account, branch `agent/m29-groups-by-account`) is reviewed and merges into integration after the next nightly. You merge it into your branch when the main session says so.
  - Read M29's design, but do not depend on its unmerged code without saying so.
- **Lanes:**
  - **Careful:** the sync protocol and wire, storage and migrations, delivery and acks, and trust (which device may send what).
  - **Fast:** Settings → Devices UI, progress and texts.
- **Start with the design note** in this file: approach, invariants checked against Known pitfalls 1–20, failure cases, tests with strict fakes, and phases. Then stop and report. Implement only after the design review passes.

## Background (read only)

The maintainer's plan is `/home/glitch/.claude/plans/velvet-seeking-walrus.md`. Read these sections:
- **"M33. Peer-to-peer sync between own devices (after M32)"**: swarm sync, the speed policies (steady, fast after confirmation, paused) and per-type filters.
- **"5. M29e: one account on several devices"**, parts B and C: `rx`/`seen`/`reach`, digests and history pages, which already exist in part.
- **"Group 1"** item 2 (M27a: one scheduler for every transfer) and item 3 (M33 on the scheduler). Also the answer to the side question at the end of "M50": M33 reuses the group file swarm (`GroupFileScheduler` and `lib/src/transfer/`).
- **"D2. Own-device mesh"**, for what M45 adds later. Keep M33 to sync; leave transport sharing to M45.
- **The order list:** Slot A is M29 → **M33** → M45 → M30.

## Goal (user decisions, earlier)

Full own-device sync of messages, contacts, files and settings, configurable as already planned:
- `syncMode`: full, contacts only, or independent;
- per category: messages, media, files, contacts, settings, Saved;
- **Saved** has its own setting, so it can sync in full while contacts stay limited;
- **speed policies:**
  - steady by default, especially on battery;
  - fast only on unmetered networks and after the user confirms each time;
  - paused.

Files come piece by piece from every own device that has them (the swarm), over LAN, Iroh and relays, with content routing deciding which transports carry what.

## Today (verify, don't trust)

Partly built already:
- **Own-device sync:** `account_sync` events (`sent`, `rx`, `seen`, `reach`, `prefs`, `digest`, history pages), `OwnDeviceSyncPreferences`, sync speed in Settings → Devices.
- **Files through own devices:** M29e P4.
- **The transfer scheduler:** `lib/src/transfer/` from M27.

In the note's first section, find out exactly what exists and what is missing, with file:line evidence, so the design builds on it instead of rebuilding it.

## Must follow

- **Group parity:** groups sync too.
- **Battery and data:** cold mode and the energy policy apply. Nothing heavy runs in the background on metered networks. Budgets stay within bounds.
- **Performance is a release rule:** bounded work per event, no polling where events exist, and no full rescans on every change (digests).
- **Compatibility:** persisted enums are append-only. New behaviour sits behind a capability. Old own devices keep working at the old level.
- **The temporary session (M65) comes later:** keep the policy layer able to say "this device gets only a recent window, nothing heavy".

## Design note

Status: design note rev 1 (2026-11-07), base d794362. No code written. Evidence is `file:line` at d794362; `mc` = `lib/src/messenger_controller.dart`, `osp` = `lib/src/transfer/own_device_sync_policy.dart`. M29 is not merged here; where M33 touches groups it builds to M29's design note (PLAN_M29.md sections 8.3, 8.4, 9) and says so.

### 0. Summary

- Much of the plumbing exists (M29b, M29e P1-P4, M27 part 1, the policy file). M33 is therefore **not** a new sync engine. It is: (1) one policy and scope layer that every sync path obeys (today only some do); (2) convergence of **state**, not only of missing messages (edits, deletes, reactions, contacts, per-key settings); (3) a bounded, resumable backlog engine (digest per day bucket, persisted cursors, budgets, progress); (4) the file backlog by swarm under the same policy; (5) the settings UI.
- Principle: **push for live, pull for backlog.** A live change is one small event through the existing queue. A backlog never goes through the queue (`_enqueuePendingAckDelivery` copies the whole list per call, mc:28321); the receiving device pulls it by digest, ranged pages and file fetches, inside its own budgets.
- Correction to the task text: `OwnDeviceSyncPreferences` and the `prefs` event **do not exist** at d794362 (nothing in `lib/` or `test/`). The only stored sync setting is `GlobalConnectivityPreferences.syncSpeed` (models.dart:757, 811, 904, 943). The M29e "C" plan for them is unbuilt, so they are in M33's scope.

### 1. Inventory: what exists

**Events, queue, delivery**
- `account_sync` is a known and ratcheted kind (crypto_service.dart:41, mc:396), content class `ownSync` (content_routing.dart:71), dispatched at mc:21488 into `_handleAccountSync` (mc:40694).
- Event types handled (mc:40726-41060): `sent`, `rx`, `state`, `read` (messages and receipts); `seen`, `reach`, `digest`; `history_req`, `history_page`, `history_wait`; `have`, `have_q`; `settings`; `group_state`, `group_message`, `gtx` (the mirror workaround M29 replaces); `tgx` (Telegram bridge). **Unknown types are ignored** (no default case; events without `chat` hit `continue`), so a new event never breaks an old device.
- Sending: `_syncToOwnDevices` (mc:38948), one event per envelope, queued as `PendingAckDelivery(kind: accountSync)` (models.dart:4854) with the **plaintext**, encrypted afresh at each attempt (`_encryptQueuedPayload`, retry pass mc:28491). Caps: 500 events per device (mc:38917), 14 days (mc:38920), `rx` 200 and 4 MiB per device (`_makeRoomForReceived`, mc:39469), folding of superseded events (mc:38962). A device out of touch gets no bulky events queued (mc:39036).
- The queue entry is cleared when a transport **accepts** the envelope (mc:28455), not when the device acknowledges it. A relay that stores and drops loses the event. Nothing but the digest repairs it.
- `rx` pass-on: delay by energy mode and by reach rank, cancelled by `seen` (mc:39404, `_passOnDelayTo`, `_dropQueuedReceived`).

**Preferences and policy**
- `SyncSpeed {steady, fast, paused}`, persisted by name. `OwnDeviceSyncPolicy.permit` (osp:92): steady = 256 KB/s, 2 paths, stop below 20% battery or in saver; fast needs `fastConfirmed` and gives way on a metered network. `SyncPacer`, `shouldOfferFast`, `ChatDigest`, `chatsToAsk` (osp:136-205). Context: `_syncConditions` (mc:39096) reads battery, saver and metered only. `fastConfirmed` is a memory flag (mc:39089), so it lapses on restart.
- UI: a segmented control and the fast-confirm dialog (devices_panel.dart:72, 209-230).
- Settings sharing: opt-in `shareSettings`; 3 values (`_sharedSettingsOf`, mc:39113: auto-download preset, storage reserve, Iroh limit); **one timestamp for the whole bundle** (`settingsChangedAt`); also in the link grant (mc:37614).

**Digests and history**
- `_chatDigests` (mc:39221): per chat, count + 16-hex hash of the newest 200 ids of the last 7 days. Whole recompute with a sort, dropped on every upsert (`_digestCache = null`, mc:42451). Sent after a >=5 min quiet gap (`_noteOwnDeviceInTouch`, mc:38497 -> `_sendSyncStatusTo`, mc:39254). `_takeDigests` (mc:39273) asks for chats that differ.
- History pages (mc:40206-40240, 40367, 40553): 50 messages / 48 KiB per page; window 30 days, 500 per chat; **Saved 5000, no window**; no polls, group files or deleted messages; 4 chats at a time; 3 tries on a timer; 300 pages per hour per device; **no byte budget per day**. An imported page **skips ids already known**, so an edit, a delete or a reaction never converges. Group pages with attachments are skipped. Imported history is marked read.
- Cursors and "asked" sets are memory only (a restart resumes only if a page arrives).

**Files**
- `sent` and `rx` carry the file descriptor (`_syncedAttachment`, mc:39606). `_fetchFileFromOwnDevice` (mc:39737) -> `_startInboundAttachment(fromOwnDevice: true)` (mc:22620). **Whether bytes are fetched is decided by the auto-download preset** (mc:22638), not by any sync setting. History files are details only.
- Serving to an own device: `_ownDeviceServingState` (mc:39658: confirmed, in the signed list, file in a chat and on disk, rechecked every 5 s, at most 32). `_serveAttachmentChunkRequest` (mc:23152) **does not consult the sync permission or a pacer**.
- Several sources: `have` / `have_q` (mc:39798-39880), `OwnDeviceFileIndex` (block_sources.dart:343), `BlockSourceSet` over `RouteStriper` (block_sources.dart:48): up to 4 sources, window per source, hedging <= 10%, a bad block drops a non-sender source, files >= 512 KiB. Capabilities `ownDeviceFilesV1`, `multiSourceTransferV1` (feature_models.dart:50, 71; advertised mc:41688).
- Group files stay on `GroupFileScheduler`; the M27a generalisation (`transfer_scheduler.dart`) is **not built**. M33 reuses `BlockSourceSet` and does not generalise the group scheduler.

**Trust**
- `_handleAccountSync` gate (mc:40694-40716): sender is `ownDevice`, `canSendOutbound`, same account id, the conversation id of that device, **in the signed device list**. Out of touch beyond `ownDeviceTouchDays` (default 7, models.dart:1169) = unconfirmed: envelopes are parked (128, memory) until `confirmOwnDevice` (mc:38524). Device-list rules (24 h before managing devices, additions per day, revocation reserve) at mc:38732-38900.
- **Every confirmed own device holds the account private key** (link grant, mc:37611), so it can sign device lists. Revocation by another own device is the only cut-off.
- Link: the grant carries all accepted contacts once, groups to mirror, the 3 settings, then `_requestHistoryFrom` (mc:37590-37817).

**Cold mode and energy**
- Sync reads no cold mode and no `EnergyBudgetSetting`. `_hasWorkAwaitingAnswer` (mc:30427) counts every recent `pendingAckDeliveries` entry, accountSync included, so events queued for an absent own device keep waking a cold device (backed off). Every send wakes its routes in cold mode (mc:31609).

### 2. What is missing (gaps)

- **G1** No `syncMode`, no categories, no separate Saved setting (Saved is always "all"; windows are constants).
- **G2** No `prefs` event: a sender cannot know the receiver's scope.
- **G3** The speed policy is not enforced everywhere. The pacer covers history pages only. `maxPaths` and `shouldOfferFast` have no caller. Live events, `have` answers and block serving ignore it. Steady runs on metered networks.
- **G4** No cold-mode or energy input; the queue wakes cold devices (see above).
- **G5** Edits, deletes and reactions made on one device reach only the contact (`editMessage` mc:18315, `deleteMessage` mc:18266, `toggleMessageReaction` mc:18369). Digests hash ids only; import skips known ids.
- **G6** Local deletes are forgotten: `_locallyDeletedMessageIds` (mc:1115) is memory only and unbounded, so after a restart a history page brings a deleted message back.
- **G7** No contact sync after the link; settings are 3 keys with one clock.
- **G8** No backlog accounting: no progress, no fast offer, no daily byte budget, cursors lost on restart, and every digest mismatch re-sends the whole window.
- **G9** Digest cost: whole sort per recompute, invalidated by every upsert.
- **G10** Files: the fetch decision follows the preset; no inventory exchange for the backlog (`have` only on arrival or when a transfer starts); `have_q` answers are unlimited (M27 review L1); serving is unpaced.
- **G11** Queue bytes: only `rx` has a byte cap; `sent` may be 64 KiB x 500 per device inside the vault (pitfall 13).
- **G12** Group parity waits on M29 (own devices as members, group file providers).
- **G13** No per-device cleanup on revocation for the reach, history, serving and file-index maps.
- **G14** No hook for "this device gets only a recent window" (M65).

### 3. Approach and phases

New code in `lib/src/sync/`: `sync_prefs.dart`, `sync_policy.dart`, `sync_ledger.dart`, `sync_budget.dart`, `own_device_sync_service.dart` (+ tests). The service is owned by the controller and gets narrow callbacks (the `TelegramService.bridgeOut` pattern, mc:6147); it owns its state and clears it on dispose, on vault reset and on `forget(deviceId)`. Hooks in the two big files are 1-15 lines. With no own devices the service is dormant: every hook returns first, so single-device users pay nothing.

| Phase | Content | Lane |
|---|---|---|
| P0 | Enforce what exists, no wire change: one `SyncPermission` check at every sync path (live events held when paused, bulk gated, `have` answers, block serving paced per target); `maxPaths` caps sources; cold mode and energy as inputs; sync entries stop waking a cold device for an absent peer; per-device cleanup on revocation; `fastConfirmed` becomes `fastUntil` | Careful (delivery) |
| P1 | `OwnDeviceSyncPrefs` (syncMode, categories, Saved), the `prefs` event, `scopeFor(target)`, capability `ownDeviceSyncV2`, the M65 hook; receive side re-checks its own prefs | Careful (wire, storage) |
| P2 | State convergence: `mut` (edit, react, delete), persisted tombstones, `contact` / `contact_rm`, per-key `settings2` | Careful (wire, storage) |
| P3 | Ledger with day buckets, `dgs` / `dgb`, ranged `history_req2` / `history_page2` that also **update** known messages, persisted cursors, daily budgets, progress, the fast offer, sync-queue byte cap | Careful (wire, perf, storage) |
| P4 | File backlog: inventory (`have_qb`), wanted-files queue driven by the files/media categories (not the preset), serve pacing, answer limits; group files after M29 | Careful (delivery, trust) |
| P5 | Settings -> Devices UI: syncMode, category toggles, Saved, speed, progress line, "Sync 1.2 GB now?" offer, per-device sync state, texts in 6 ARBs | **Fast** (canary, behind `canaryFeatures`) |

Order: P0, then P1, then P2 and P3 (either order, both need P1), then P4 (needs P1 and P3). P0 to P4 are independent of M29 except the group parts of P3 and P4 (section 8). One Opus review round after P2 and one after P4. Each careful phase ends with a green debug run and "lab check needed" (section 13).

### 4. Wire and capabilities

- **One capability, `ownDeviceSyncV2`**, appended to `ApplicationCapability` (26 values today, cap 64; feature_models.dart:5, 91). `sharedSettingsV1` stays reserved for M45's transport sharing. A target without it gets only today's events and today's scope (pitfall 14): `sent`, `rx`, `state`, `read`, v1 `digest`, old `history_*`, 3-key `settings`, `have` / `have_q`.
- **Small live events in `account_sync`** (unknown to old builds, so ignored; also never sent to them):
  - `prefs`: `{v, at, mode, cats:{category:amount}, windowDays, mobileData}` (<= 400 bytes), sent on change, on first touch after start, and on a >=5 min touch gap.
  - `mut`: `{chat, id, op: edit|react|del, rev, ...}`. `edit` carries `body` (<= 64 KiB, `editedAt`); `react` carries `emoji`, `active`, `changedAt`; `del` carries nothing else.
  - `contact`: `{rev, c:{deviceId, accountId, alias, displayName, publicKey, signingKey, irohEndpointId?, accountKey?}}`; `contact_rm`: `{deviceId, rev}`.
  - `settings2`: `{k: [value, clockMs, deviceId]}` per key, <= 16 keys.
  - `dgs`: digest summary `{chats:{chat:[count, root, newestMs]}, contacts:[count, root], files?}`; `have_qb`: `{ids:[<= 64]}`.
- **Bulk in a new kind `account_sync_bulk`**, content class `history` (so contact-side refusals and the carrier rule "history only on request" keep pages off slow routes). Added to the two kind sets (crypto_service.dart:41, mc:396). Events: `dgb` (day buckets of one chat), `history_req2` (`{chat, fromDay, toDay, cursor}`), `history_page2` (messages with `rev`), `contacts_page`. Old builds drop an unknown kind, which is why these go only to `ownDeviceSyncV2` targets.
- **Old own devices keep working at the old level**; a v2 device accepts old `history_page` and v1 `digest` from them, but still drops what its own prefs say is off. M33 never changes what an old device sends or what it understands.
- Every new field is optional with a default; every list is bounded (events per envelope <= 32, page <= 48 KiB, ids <= 64, keys <= 16, chats <= 256).

### 5. Trust

- The gate is unchanged and runs first for every new event (mc:40694-40716): own device, confirmed, in the signed list, right account and conversation id. New handlers sit **after** it, inside the existing `try`, and check in this order: authorize -> the receiver's own prefs and permission -> bounds and shape -> effects (pitfall 9). Batched ids (`seen`, `have_qb`, `mut` lists) are checked one by one before any cache update.
- **Only confirmed, unrevoked own devices.** An unconfirmed device keeps today's rule (parked, nothing applied; queued bulk is not kept). A revoked device fails the list check on its next envelope; `forget(deviceId)` runs when the list changes (a tail hook in `_reconcileOwnDevices`) and clears prefs, budgets, cursors, reach, serving states, file-index entries, parked envelopes and queued entries (G13).
- **Scope is enforced by the sender, from the target's certificate, not from the target's word.** `scopeFor(target)` = my send prefs AND the target's declared prefs (default: the safe scope when unknown) AND the target's class from its `DeviceCert` AND the permission now. A thief that declares "send me everything" gets at most what its class allows. Receivers re-check their own prefs and never trust a sender to scope.
- **A compromised, not yet revoked own device can:** read everything within its scope; inject fake `sent` / `rx` for existing accepted chats (already possible; shown as "via your device" (`MessageRoute.viaOwnDevice`)); send `mut` and `contact` events (bounded below); sign device lists (it holds the account key; unchanged). **It cannot:** make a contact's message authentic (no contact signature is involved), add a contact with route hints or replace a pinned contact key (keys that differ are flagged `accountKeysDiffer`, as in the link flow; the whitelist has no routes), widen its own scope, exceed budgets, or delete more than the cap below.
- **Deletions are the destructive case.** A `del` is sent only by the explicit action "Delete on all my devices" (the plain delete stays local, as today). Receivers apply at most 50 per hour per device; beyond that they park the rest and show "Your other device deleted many messages: apply?". Applied deletes write a persisted tombstone (section 6). Saved is never deleted by a `del` from a device whose Saved category is not `all`.
- **A revoked device keeps what it already synced** (cannot be unsent); the Devices UI must say so when revoking. It receives nothing new from this account's devices, and contacts stop sending to it as soon as they apply the new list (existing behaviour).
- Contact sync takes **public data only**: no routes, no sessions, no private keys. The new device builds its own Olm session with each contact (contacts learn the device from the signed account statement, which exists). Contacts the user removed, or that are pending, declined or hidden never leave the device (the `_linkableContacts` rule, mc:37866).

### 6. Storage and migration (append-only)

- `GlobalConnectivityPreferences.ownDeviceSync` (appended, JSON key `ownDeviceSync`, omitted at default): `{mode, cats, windowDays, mobileData}`. Enums are persisted by name; unknown names load as the default. New enums: `OwnDeviceSyncMode {full, contactsOnly, independent, custom}`, `SyncCategory {messages, media, files, contacts, settings, saved}`, `SyncAmount {off, recent, all}`; all append-only.
- **Absent field = today's behaviour** (grandfather, pitfall 18): loads as `custom` with messages `recent` (30 days, 500 per chat), media and files `off` (details only), saved `all`, contacts `off`, settings = `shareSettings`. A fresh link defaults to `full`. Existing users see a one-time card "Sync contacts between your devices?" (fast lane); nothing starts without a choice.
- `GlobalConnectivityPreferences.settingsClocks` (appended): key -> clock ms, for `settings2`. `settingsChangedAt` is still written on every shared change so old devices keep working.
- **Tombstones** (`AppSnapshot.deletedMessageIds`, appended, optional): plain ids, newest last, <= 2048 entries and <= 128 KiB, entries older than 60 days dropped (Saved ones kept until the cap). Seeds `_locallyDeletedMessageIds` at load, so no `contains` call site changes; the two `add` sites (mc:26892, 42944) also note the id. Fixes G6. Bytes are counted in the vault size test.
- **Cursors** (`AppSnapshot.syncCursors`, appended): per (own device, chat) the last finished day and page cursor, <= 64 KiB, oldest dropped (a drop only costs a re-ask). Added in P3.
- **Sync queue byte cap**, per device, 4 MiB across all accountSync entries, oldest folding-eligible first. Ships in P3 with the digest that repairs a drop. A vault that already holds more keeps it (the cap applies to new entries only).
- Digest ledgers, prefs of other devices, budgets, progress and the wanted-file queue are derived, in memory, rebuilt on first touch. Nothing derived is migrated. No existing message, contact or file is rewritten or deleted by any migration.

### 7. The policy layer

**Categories and amounts.** `messages` (text of 1:1 and group chats, with edits, reactions, deletes), `media` (photos, voice, video inside chats), `files` (other attachments), `contacts`, `settings`, `saved`. `SyncAmount`: `off` / `recent` (window 7, 30 or 90 days, <= 500 per chat) / `all` (no window; <= 5000 per chat, the Saved cap today). For `media` and `files`: `off` = details only (today), `recent` = bytes fetched automatically inside the window, per file <= 100 MiB, `all` = every file in scope without the per-file cap. Presets fill the categories: **full** (messages `recent`, media `recent`, files `recent`, contacts `all`, settings per `shareSettings`, saved `all`), **contactsOnly** (contacts `all`, settings per `shareSettings`, the rest `off`, saved as set), **independent** (everything `off`, saved `off`). Editing any category switches the mode to `custom`. **Saved is its own entry**, so it can be `all` while contacts are `off`. The mode applies in both directions: a device that is `independent` neither sends nor imports.

**Conditions.** `SyncConditions` gains `cold`, `foreground`, `onMains` (from `_energyPolicy.isCold`, `power`, app state), so `permitFor(category, kind: live | bulk)` returns `SyncPermission{allowed, bytesPerSecond, maxPaths, dailyBytes, reason, speed}`. Live = one small event per change; bulk = pages, buckets, contact pages, file bytes, answers to `have_qb`.

| State | Live events | Bulk |
|---|---|---|
| paused | held in the queue (caps as today) | off |
| battery < 20% (not charging) or saver | sent (energy fanout already uses one route) | off |
| cold mode | sent; they wake routes like any send | only in the foreground, or charging and unmetered, or "Sync now"; **bulk never wakes a route**, it runs only on routes already up |
| metered or roaming | sent | text pages within a small daily budget (8 MiB); media and files **off** unless `mobileData` is on (default off); fast gives way to steady |
| steady (default) | sent | 256 KB/s per target, 2 paths, daily budget (history 32 MiB; files 1 GiB) |
| fast | sent | confirmed, no byte cap, up to 8 paths, history budget 256 MiB; ends when the backlog is drained, after 6 h, on restart, or on a metered switch |

All numbers are starting points for the lab; they are constants in one file.

**`scopeFor(ContactRecord target)`** returns per category the amount, window, per-chat cap, `bulkAllowed`, `bytesPerSecond`, `maxPaths`, `dailyBytes`. It is the **one place** that answers "what may this device send to that device now". **M65 hook:** `DeviceSyncProfile profileOf(DeviceCert)` returns `normal` today. A future `temporary` profile (from an appended `expiresAt` on the cert) clamps every category to `recent`, window <= 7 days, media and files to `off`, contacts and settings to `off`, saved to the recent window, and forbids bulk over metered or cold. The clamp is applied by the sender, so a temporary device cannot lie its way past it.

**Enforcement points (all call the same service):** live-event queueing (an `off` category is dropped at queue time, so the queue cannot grow; a `paused` or `held` condition keeps the event; a policy refusal is a hold, never a route failure), history page building, bucket and contact pages, `have` / `have_qb` answers, `_serveAttachmentChunkRequest` for own devices (pacer per target, bounded to 16 devices), and the wanted-file queue.

**Fast confirmation** becomes `fastUntil` (memory only). `shouldOfferFast` gets a caller: the service computes the backlog from the progress counters and raises one `SyncOffer` at most once per 24 h per device unless the backlog doubled. The UI shows "Sync 1.2 GB now?"; confirming sets `fastUntil`.

**Drivers, no new polling.** The pump runs on events: a device came into touch, `prefs` or a digest arrived, a page or file finished, power or network changed (existing `onPowerChanged` and connectivity listener), the cold wake (the existing `_cold.fetch` hook), "Sync now", the user confirming fast. Each step starts at most one request window per target. The only new timer is one one-shot deadline per exhausted daily budget, cancelled on dispose.

### 8. Group parity

- **Chat names.** The ledger, digest and pages already name chats `saved`, a contact device id, or `group:<id>` (mc:40297); groups use the same machinery, so `messages` / `saved` / `files` categories, budgets and speed apply to groups exactly as to 1:1.
- **Before M29 merges:** groups reach own devices through the mirror (`group_state`, `group_message`, `gtx`, mc:39952-40090) and `group:` history pages. M33 changes none of that. Group attachments in history stay skipped.
- **After M29 merges** (builds to PLAN_M29 section 8): own devices are real members. M33 adds **no second group message path**:
  - the policy gates M29's work: pokes and `catchup`, the history pull from a sibling (`_scheduleGroupHistorySync(..., passOn:false)`), sibling file-provider selection call the same `permitFor(messages | files, bulk)`;
  - for resolved groups the ledger only decides whether to trigger M29's history sync; `history_req2` is not used for them;
  - group files come from siblings through `GroupFileScheduler` (they are providers by membership); the wanted-file queue lists group attachments and starts them through `GroupFileService`;
  - `mirroredVia` groups keep the old path until M29 clears them.
- **Not synced by M33:** group membership and roles (the signed DAG owns them); group members who are not contacts (the `contacts` category carries contacts only); per-group local settings such as mute (a later settings key).
- The M29 code could not be read here; the group hooks are named to its design note and must be checked against the merged code first.

### 9. Performance

- **Ledger, incremental.** Per chat: `Map<dayIndex, (count, xorHash)>`, hash = XOR of 64-bit per-id hashes of `(id, rev)`, so add and remove are O(1) and order-free. Built lazily per chat on first request (one pass over that chat), kept current by dirty hooks in the four mutators (`_upsertMessage` mc:42450, `_upsertGroupMessage`, `_deleteMessage`, `_updateMessageBody` / reactions). It replaces the whole-sort `_chatDigests` for v2 targets (G9). The XOR hash is a convergence hint between trusted devices only; a collision delays a repair, never authorizes anything.
- **Cost is proportional to the difference.** `dgs` sends one root per chat; a mismatch asks `dgb` (<= 90 buckets); only differing days are paged (`history_req2`). Today any mismatch re-sends the whole window.
- **Bounded per event.** <= 32 events per envelope; one page <= 48 KiB; <= 4 chats and 1 page in flight per chat per target; the pump does one step per event; no rescan on a change (dirty chats only); the wanted-file queue holds <= 512 entries, refilled one chat page at a time when below 16.
- **No JSON in hot paths.** Prefs are parsed once into a typed object per device; the ledger holds ints; digests are built from the ledger without decoding messages. A page is decoded once to be sent. New events do not use the O(queue) fold scan (mc:38962, a risk the lab should time with 500 queued events); if it shows, an index is a later round.
- **Idle cost: zero.** No timers; no own devices means a dormant service; cold devices get no extra wake.
- **Before a release (measure, do not guess):** ledger build time for 50 chats x 5000 messages; vault save size with tombstones and cursors; frame times while a 1 GB backlog syncs on a phone; idle wakeups with one own device absent (expect none added); CPU of a fast sync.

### 10. Invariants against Known pitfalls 1-20

1. Inbound: new handlers only mutate memory and schedule; answers (`dgb`, `have`, pages, `contacts_page`) go to the queue, the pacer or `_afterProcessing`; file starts use `unawaited`. No send is awaited on the inbound path.
2. Queue stores plaintext; sealing stays at `_encryptQueuedPayload`. A page is built **after** the pacer releases it, so a pacing wait never holds ciphertext. **Inherited risk:** `_enqueueAndDeliverEnvelope` encrypts before the first `_deliverToContact` (mc:28434), which may wait in a limiter; bulk uses the same path. Not worsened, but P0 checks it for the accountSync kind.
3. No polling (section 7). The only timers: existing history-ask timeout (kept), pacer wait per page, one budget deadline per exhausted device; all cancelled on dispose and on `forget`.
4. No relay lease is held. The parked-unconfirmed pattern stays (<= 128).
5. A budget, pacer or policy refusal is a hold or a `history_wait`; it never cools a route or drops an event of a wanted category.
6. Service state, ledgers, budgets, cursors, wanted queue and timers are cleared in dispose, on vault reset and on `forget(deviceId)`.
7. The fetch queue holds nothing of its own: file transfers keep `_noteTransferMoved` (bytes in the last minute); `fastUntil` expires; no transport is held for sync.
8. A handed-off sync event is not delivery. Convergence is by ledger, not by acks. Receipts shown for messages still come only from the device that received them (`state`, unchanged).
9. Section 5: authorize -> own prefs -> bounds -> effects; per-id checks for batches; tombstones written only after the delete is authorized and within the cap.
10. Budgets and rate limits are charged in **one** function per direction (`SyncBudget.charge`), called from page build, bucket and contact pages, block serving and `have` answers. A test drives every path and checks each counts (also LAN, Iroh and relay delivery).
11. The pump is scheduled on the event loop and never calls itself; an exhausted budget returns a wait, not a callback.
12. Every map is capped: ledger (<= 256 chats x 90 days), prefs and budgets (<= 16 devices), cursors (64 KiB), tombstones (2048), wanted files (512), pacers (16). Expiry by age or LRU.
13. Vault bytes: tombstones <= 128 KiB, cursors <= 64 KiB, sync queue <= 4 MiB per device. A test measures the snapshot.
14. `ownDeviceSyncV2` gates every new event and kind; a fake old own device proves it keeps the old level.
15. Not touched. File sources are ranked by measured bytes (`BlockSourceSet`), not by claims.
16. Bulk is sealed at the send after the limiter turn (inherited path, point 2). Pacing precedes building.
17. Every ask has an attempt cap (history 3, files 3 per source) and backoff; a failing device does not block others (per-device queues); a full queue or budget never fails inbound processing; permanent failures show an error.
18. Absent prefs = today; tombstones start empty; caps apply to new data; deletes only by explicit action; contacts `off` for existing users; no message, contact or file is removed by a migration.
19. Section 9: typed prefs and ledger, no decode per item.
20. Service, ledger and budgets take an injected `now`; tests build envelopes and timestamps from the same fixed clock (the M29 `fixtureEpoch` pattern), never `DateTime.now()`.

### 11. Failure cases

- **A device offline for weeks.** Past `ownDeviceTouchDays` it is unconfirmed (today's rule): nothing is applied, queued bulk is not kept, events expire after 14 days. On `confirmOwnDevice` the parked envelopes are applied, then the touch sends `prefs` and `dgs`; only differing days inside the window are paged. What fell outside the window is not fetched unless the user raises it ("Sync older history", up to `all`); Saved is always `all`. Lost `sent` events are repaired by the ledger, not by the queue.
- **Two devices change the same setting.** Per key last-writer-wins on `(clock ms, deviceId)`; the clock is clamped to now + 5 min; ties go to the higher device id; the loser shows today's "changed from your other device" notice. Prefs are single-writer (each device owns its own). Message edits: later `editedAt` wins; reactions use the existing per `(device, emoji)` clock; a delete beats an edit; contact rename: later `rev`, and archive state follows `rev`. Keys never overwrite.
- **A revoked device.** Its next envelope fails the list check; `forget` clears everything for it; its source is `remove`d from running `BlockSourceSet`s (not blamed); a partial file already verified stays; unverified partials from it are re-fetched from other sources. It keeps what it synced.
- **Restart mid-sync.** Queued events are in the vault. Cursors resume from the last finished day or page (P3); asks in flight are asked again (3 tries); file partials resume from the `PartialTransfer` journal; the pump state is rebuilt on the first touch (the in-memory "announced to" set is empty, so `prefs` and `dgs` go again).
- **Quota or budget exhausted.** History budget: the sender answers `history_wait` with the seconds until the allowance frees (the existing handler clamps to 10 s - 1 h and asks again); progress says "waiting for the daily allowance". File budget: the queue holds and one deadline timer wakes it. Storage reserve (`storageReserveEnabled`): the file stays details-only, marked blocked, retried through the existing `waitingForStorage` path. Relay or carrier limits: a limiter refusal delays (pitfall 5). Conditions that stop bulk (battery, cold, metered) pause it and show why; resuming is event-driven.
- **A partial file.** Each block is verified under the file key and the whole file by hash (existing). A source that vanishes is removed and the others continue; with none left the wanted entry waits for the next `have_qb`; a hash mismatch deletes the partial and retries up to 3 times, then shows an error.
- **A lost or reordered sync event** (relay drop, carrier loss): repaired by the next digest exchange (on any touch after a quiet gap, and on the cold wake in P3).
- **A deletion storm from a compromised device:** capped at 50 per hour, parked beyond that, visible.

### 12. Tests and sabotage checks

Fakes first, in their own commit: the in-test fakes (`_InProcessIrohNetwork` with `blockedPairs`, `_FakeCarrierNetwork`, `_FakeRelayClient`, `_MutablePower`, mc test lines 548, 1591, 1761, 36959) are looser than reality where M33 depends on them. `_FakeCarrierNetwork` has no loss, reordering, frame-size cap or rate limit (only `holdFrom`); add seeded loss and reorder, a frame cap (a 48 KiB page against a mail or Matrix limit) and a per-address rate budget with slow-down answers. The relay fake needs lease expiry and redelivery for sync envelopes. The ratchet fake (`fake_ratchet_engine.dart`) must keep Olm's 5 chains / 40 skipped keys; a test pins that. New: a metered / cold / battery switchboard over `_MutablePower` and the network cost class, and a helper `linkedDevices(n)` built on the existing `threeDevices()` (mc test line 23762) with a chain topology (C reaches only A; A and B only over a carrier).

Unit tests (pure): policy table (every row of section 7, sabotage: remove cold or metered rule), `scopeFor` intersection and the temporary-profile clamp, prefs round trip and unknown names, ledger add/remove/rev, day buckets and XOR hash (order independence), budget and pacer with a fixed clock, per-key LWW, tombstone cap and byte cap.

Controller tests (strict fakes):
1. Paused holds live events and bulk; resume flushes. Steady stays under 256 KB/s (pacer) including block serving; low battery stops bulk; cold mode never wakes a route for bulk; metered sends no file bytes. **S:** remove the serving check.
2. Fast needs confirmation each time, ends on drain, 6 h, restart and a metered switch; the offer appears once.
3. `prefs` narrows the sender: a target with `contacts off` gets no contact event; unknown prefs get the safe scope; a lying target is clamped by its cert class (temporary profile test). **S:** read the target's claim instead of the clamp.
4. State convergence: an edit, a reaction and an "all devices" delete made on A reach B and C; a restart does not bring the deleted message back; the 51st delete in an hour is parked. **S:** tombstone not persisted; cap removed.
5. Contacts: a contact added on A appears on B without routes; a different key for a known contact is flagged, not replaced; a removed contact is archived, not erased.
6. Settings: two devices change different keys at once and both survive; same key converges to the later clock; a clock in the future is clamped. **S:** one bundle clock.
7. Backlog: a device offline 3 days fetches only the differing days; a mismatch costs pages proportional to the difference (count frames); a lost `sent` event on the lossy carrier is repaired; a restart mid-sync resumes at the cursor; budget exhaustion answers `history_wait` and resumes. **S:** drop the ledger update hook; drop the cursor save.
8. Three own devices on fake paths: file pieces arrive from both sources, the policy caps paths, a source dropping loses nothing, a bad block drops the source, a revoked source stops mid-file, a partial file resumes, a files-off device serves and fetches nothing. **S:** remove `maxPaths`; remove the revoke `forget`.
9. Security: every new event from a contact, from a device not in the signed list, or from an unconfirmed device is ignored or parked; `have_qb` over 64 ids or over the rate is cut; a flood of `mut` stays within the cap; a v2 event never goes to an old device. **S:** remove the gate hook; remove the capability gate.
10. Old own device: a fake that understands only today's events keeps syncing messages, Saved, history, 3 settings.
11. Group parity: `group:` chats follow the same categories and budgets; groups before M29 through the mirror; after M29 (once merged) sibling file providers and history pulls obey the policy.
12. Vault bytes: the snapshot with a full tombstone list, cursors and a 500-event queue stays under the cap; migration test: an old vault loads with today's behaviour and no change on disk.
13. Pitfall tests: no timer left after dispose and after `forget`; state maps empty after vault reset.

Every test with an S is sabotage-checked (break, see it fail, restore) and logged. The Rust side is untouched, so there are no Rust sabotage branches. Full suite once at the end under the lock.

### 13. Lab checks (maintainer)

"Lab check needed" after the first green debug run of P0, P1, P3 and P4:
- Linux (A), phone 1 (B, linked), phone 2 (C): 2000 messages and 200 files on A; link B and C; watch progress and steady against the 256 KB/s cap; battery on the phones over one hour with a deliberately absent third device (expect no extra wakeups).
- Phone on mobile data: nothing heavy; text only.
- Kill the app mid-sync on B: resume without duplicates or loss; delete on A, restart B, no reappearance.
- C reaches only A (LAN), A to B over a Nostr carrier: edits, reactions, deletes and a 5 MB file cross the chain; counts of frames per day bucket on a mismatch.
- Revoke B during a fast sync: A stops serving within about 5 s.
- Fast offer dialog with a 1 GB backlog on Wi-Fi and mains; metered switch drops to steady.

### 14. Open questions for the maintainer

1. **Delete semantics.** Is "Delete on all my devices" as an explicit action, capped at 50 per hour, right? Should applied deletes also keep a 7-day trash (the message and file bytes hidden, undo) so a compromised device cannot destroy history? The note leaves the trash out.
2. **Contacts default.** Existing users start with contacts `off` and a one-time card; new links default to `full`. Is that right, or should existing devices that already share contacts through the link start on?
3. **Defaults and numbers.** Files in `full` = `recent`, 30 days, <= 100 MiB per file; daily budgets 32 MiB history and 1 GiB files in steady, 8 MiB history on metered; `all` = <= 5000 per chat. Are these the right starting points?
4. **Saved on `contactsOnly` and `independent`.** The note keeps Saved as its own setting, default `off` in those two presets. Should Saved stay `all` in `contactsOnly`?
5. **Settings keys.** M33 ships the per-key mechanism with the 3 existing keys. Which others should join now (notification rules, quiet hours, language, folders, auto-download rules), and which belong to M45 / M63?
6. **A new kind `account_sync_bulk`** (class `history`) so slow carriers and refusal rules apply to pages. The alternative is an event-type hint to `_deliverToContact`, a bigger hook in a hot function. Is the new kind acceptable?
7. **Verification flag.** Should "contact verified" (safety number) sync? The note says no: verification stays per device (a synced "verified on another device" hint only). Confirm.
8. **Group files before M29.** Sync of group attachments stays off until M29 merges. Acceptable, or is a stopgap wanted?
9. **Scheduler generalisation (M27a).** M33 reuses `BlockSourceSet` for own-device files and leaves `GroupFileScheduler` alone. Should M33 wait for or fold in the M27a unification?
10. **Inherited pre-encryption** (point 2 of section 10): should P0 fix `_enqueueAndDeliverEnvelope` for accountSync (encrypt after the limiter turn), or leave it for the delivery owner?

## Handoff

Design note round only (2026-11-07): the note above is ready for the Opus design review. No code, no tests run, nothing built. Implement only after the review passes and the open questions in section 14 are answered. Pitfalls 1-20 are checked in section 10 against the design, not yet against code.

## Progress log

- 2026-11-07: read PLAN_AGENTS.md, this file, the maintainer's plan sections (M33, M29e parts B and C, Group 1 items 2 and 3, D1, D2, D4, M65, the M50 side answer), PLAN_M29.md (design sections 7-9 and handoff) and PLAN_M27.md (handoff). Inventoried own-device sync in `messenger_controller.dart`, `transfer/`, `models.dart`, `energy_policy.dart`, `cold_mode.dart`, `devices_panel.dart` and the tests at base d794362 (evidence in section 1). Found that `OwnDeviceSyncPreferences` and the `prefs` event do not exist, edits/deletes/reactions do not sync between own devices, `_locallyDeletedMessageIds` is memory only, and the speed policy is enforced for history pages only. Wrote the design note; no code changed. An API session limit interrupted the first pass; resumed from the link grant onward.
