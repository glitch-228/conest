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

Status: design note rev 2 (2026-11-07): rev 1 plus the Opus design review (H1-H3, M1-M7, LOWs), the maintainer's answers and the user's decisions, all sections below the Progress log; section 15 says how each finding was checked. Base d794362. Evidence is `file:line` at d794362; `mc` = `lib/src/messenger_controller.dart`, `osp` = `lib/src/transfer/own_device_sync_policy.dart`. M29 is not merged here; where M33 touches groups it builds to M29's design note (PLAN_M29.md sections 8.3, 8.4, 9) and says so.

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
- Sealing: `account_sync` is in `ratchetedEnvelopeKinds` (crypto_service.dart:19) and `_crypto.sealLater` is on once sessions are open (mc:35787), so `encryptPayloadEnvelope` returns a placeholder with a `LazySeal` and the transport seals it at hand-off (`envelope.sealed()`, mc:33666). Pitfall 2 already holds for sync events (rev 1 called it an inherited risk; that was wrong).
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
- **No "verified" mark exists.** Safety numbers are only displayed (main.dart:4402 and others). The nearest state is `pendingVerification` with `confirmContactReplacement` (mc:13429), a key-change confirmation. Q7 therefore needs a new mark (section 5).
- A contact's delete for a message that has not arrived yet is added to the same `_locallyDeletedMessageIds` set (mc:26892).
- Link: the grant carries all accepted contacts once, groups to mirror, the 3 settings, then `_requestHistoryFrom` (mc:37590-37817).

**Cold mode and energy**
- Sync reads no cold mode and no `EnergyBudgetSetting`. `_hasWorkAwaitingAnswer` (mc:30427) counts every recent `pendingAckDeliveries` entry, accountSync included, so events queued for an absent own device keep waking a cold device (backed off). Every send wakes its routes in cold mode (mc:31609).

### 2. What is missing (gaps)

- **G1** No `syncMode`, no categories, no separate Saved setting (Saved is always "all"; windows are constants).
- **G2** No `prefs` event: a sender cannot know the receiver's scope.
- **G3** The speed policy is not enforced everywhere. The pacer covers history pages only. `maxPaths` and `shouldOfferFast` have no caller. Live events, `have` answers and block serving ignore it. Steady runs on metered networks.
- **G4** No cold-mode or energy input; the queue wakes cold devices (see above).
- **G5** Edits, deletes and reactions made on one device reach only the contact (`editMessage` mc:18315, `deleteMessage` mc:18266, `toggleMessageReaction` mc:18369). Digests hash ids only; import skips known ids.
- **G6** Local deletes are forgotten: `_locallyDeletedMessageIds` (mc:1115) is memory only and unbounded (a contact's early deletes also land in it, mc:26892), so after a restart a history page brings a deleted message back.
- **G7** No contact sync after the link; settings are 3 keys with one clock.
- **G8** No backlog accounting: no progress, no fast offer, no daily byte budget, cursors lost on restart, and every digest mismatch re-sends the whole window.
- **G9** Digest cost: whole sort per recompute, invalidated by every upsert.
- **G10** Files: the fetch decision follows the preset; no inventory exchange for the backlog (`have` only on arrival or when a transfer starts); `have_q` answers are unlimited (M27 review L1); serving is unpaced.
- **G11** Queue bytes: only `rx` has a byte cap; `sent` may be 64 KiB x 500 per device inside the vault (pitfall 13).
- **G12** Group parity waits on M29 (own devices as members, group file providers).
- **G13** No per-device cleanup on revocation for the reach, history, serving and file-index maps.
- **G14** No hook for "this device gets only a recent window" (M65).
- **G15** No "verified" mark to sync (Q7).

### 3. Approach and phases

New code in `lib/src/sync/` (pure: `sync_prefs.dart`, `sync_policy.dart`, `sync_ledger.dart`, `sync_budget.dart`, tests beside) and `lib/src/own_device_sync_controller.dart`, a `part of` the controller with an `extension` (the M29 `group_accounts_controller.dart` pattern). State fields live in the controller class and are cleared by one `_clearOwnDeviceSyncState()` on dispose, vault reset and `forget(deviceId)`. Hooks in the two big files are 1-15 lines. With no own devices every hook returns first, so single-device users pay nothing.

Principle: **push for live, pull for backlog.** Live changes use the queue. A backlog never goes through the queue (`_enqueuePendingAckDelivery` copies the list per call, mc:28321); the receiver pulls it by digest, ranged pages and file fetches inside its own budgets.

| Phase | Content | Lane |
|---|---|---|
| P0 | Enforce what exists, no wire change. A strict-fake commit first. One permission check at every sync path: live events held when paused; block serving to own devices gated and paced per target without waiting on the inbound path; `maxPaths` caps sources; cold mode, foreground and mains as inputs; accountSync entries never keep a cold device awake; per-device cleanup on revocation; `fastConfirmed` becomes `fastUntil`; a test pins that sync envelopes are sealed at hand-off | Careful (delivery) |
| P1 | `OwnDeviceSyncPrefs` (syncMode, categories, Saved), `prefs`, `scopeFor(target)`, the M65 hook | Careful (wire, storage) |
| P2 | State: `mut` (edit, react, delete), tombstones with watermarks, `contact` / `contact_rm`, `verify`, per-key `settings2` (HLC) | Careful (wire, storage, trust) |
| P3 | Ledger with day and month buckets, `dgs` / `dgb`, ranged `history_req2` / `history_page2` that also update known messages, persisted cursors, daily budgets, progress, the fast offer, sync-queue byte cap | Careful (wire, perf, storage) |
| P4 | File backlog: `have_qb`, wanted-files queue driven by the files and media categories (not the preset), answer limits; group files after M29 | Careful (delivery, trust) |
| P5 | Settings -> Devices UI: syncMode, categories, Saved, speed, progress line, "Sync 1.2 GB now?", per-device sync state, the verified mark and its action, the delete choice, texts in 6 ARBs | **Fast** (canary, behind `canaryFeatures`) |

Order: P0, P1, then P2 and P3 (either order, both need P1), then P4 (needs P1 and P3). P5 follows each careful phase. **A capability is advertised only by a build that implements every event it names** (section 4), so P1 and P2 reach a nightly together. P0 to P4 are independent of M29 except the group parts of P3 and P4 (section 8). One Opus review round after P2 and one after P4. Each careful phase ends with a green debug run and "lab check needed" (section 13).

### 4. Wire and capabilities

- **One capability per wire step, appended in this order** (feature_models.dart:5, 91; 26 values today, cap 64; each is advertised only when the build implements all of its events, and senders fall back to the old events for a target without it, pitfall 14):
  - `ownDeviceSyncV2`: `prefs`, `mut`, `contact`, `contact_rm`, `verify`, `settings2` (P1 + P2);
  - `ownDeviceSyncBulkV1`: the kind `account_sync_bulk` and its events (P3);
  - `ownDeviceFilesV2`: `have_qb` (P4).
  `sharedSettingsV1` stays reserved for M45. Why separate: a P3 build must not send a new kind to a P1/P2 build. An old build drops an unknown kind **before decrypt** (the v3 shape check, mc:21978), so each dropped bulk envelope skips an Olm message key (40 per chain) and a burst breaks the chain (pitfall 2). Test: a P1/P2 build against a P3 build.
- **Small live events in `account_sync`**, an existing kind, so an unknown event type is ignored after decrypt (no `default` case, mc:40726-41060):
  - `prefs`: `{v, at, mode, cats:{category:amount}, windowDays, mobileData}` (<= 400 bytes), on change, on the first touch after start, and with `dgs`.
  - `mut`: `{chat, id, op: edit|react|del, rev, ...}`. `edit` carries `body` (<= 64 KiB) and an HLC; `react` carries `emoji`, `active`, HLC; `del` is only the explicit all-devices delete.
  - `contact` `{rev, c:{deviceId, accountId, alias, displayName, publicKey, signingKey, irohEndpointId?, accountKey?}}`, `contact_rm` `{deviceId, rev}`, `verify` `{contact, keyHash, on|off, at}`.
  - `settings2`: `{k: [value, hlc, deviceId]}`, <= 16 keys per event, more keys in more events; the old 3-key `settings` bundle maps onto `settings2` keys, and the old event is still sent to targets without `ownDeviceSyncV2`.
  - `dgs`: `{chats:{chat:[count, root, newestMs]}, contacts:[count, root], settings: hash of the clocks}`; `have_qb`: `{ids:[<= 64]}`.
  - **`dgs` is attached to an outgoing envelope** after N events or 30 min of steady contact (a counter and a timestamp, no timer), not only after 5 min of quiet (the quiet-only repair at mc:38497 never fires on a busy link, M4).
- **Bulk in a new kind `account_sync_bulk`** (maintainer: yes), class `history` (so refusal rules and the carrier rule "history only on request" keep pages off slow routes), added to the two kind sets (crypto_service.dart:19, mc:359 region). Events: `dgb` (buckets of one chat), `history_req2` (`{chat, fromDay, toDay, cursor}`), `history_page2` (messages with `rev`), `contacts_page`. **Bulk envelopes to one target go over one route, the one the request came on** (single-route fanout; `maxPaths` applies to file blocks only), so copies cannot burn Olm's 5 receiving chains (M6).
- Old own devices keep today's level; a v2 device accepts old `history_page` and v1 `digest` from them but drops what its own prefs say is off. Every new field is optional with a default; every list is bounded (events per envelope <= 32, page <= 48 KiB, ids <= 64, keys <= 16, chats <= 256).

### 5. Trust

- The gate is unchanged and runs first for every new event (mc:40694-40716): own device, confirmed, in the signed list, right account and conversation id. New handlers sit **after** it, inside the existing `try`, and check in this order: authorize -> the receiver's own prefs and permission -> bounds and shape -> effects (pitfall 9). Batched ids (`seen`, `have_qb`, `mut` lists) are checked one by one before any cache update.
- **Only confirmed, unrevoked own devices.** An unconfirmed device keeps today's rule (parked, nothing applied; queued bulk is not kept). A revoked device fails the list check on its next envelope; `forget(deviceId)` runs when the list changes (a tail hook in `_reconcileOwnDevices`) and clears prefs, budgets, cursors, reach, serving states, file-index entries, parked envelopes and queued entries (G13).
- **Scope today = my send prefs AND the target's declared prefs AND the permission now** (default for unknown prefs: the safe scope). **This protects nothing against a thief:** `DeviceCert` (account_model.dart:280) has no class or expiry, and every own device holds the account private key, so a stolen device can claim any prefs. Revocation is the only cut-off. The M65 temporary profile adds protection only if temporary devices **never receive the account key** and the profile is signed by a non-temporary device other than the target; until M65 defines that, `profileOf` returns `normal` and the clamp is a hook. Receivers re-check their own prefs and never trust a sender to scope.
- **A compromised, not yet revoked own device can:** read everything within its scope; inject fake `sent` / `rx` for existing accepted chats (already possible; shown as "via your device" (`MessageRoute.viaOwnDevice`)); send `mut`, `contact` and `verify` events (capped below); sign device lists (it holds the account key; unchanged). **It cannot:** make a contact's message authentic (no contact signature is involved), add a contact with route hints or replace a pinned contact key (keys that differ are flagged `accountKeysDiffer`, as in the link flow; the whitelist has no routes), widen its own scope, exceed budgets, or delete more than the cap below.
- **Deletions are the destructive case.** The user chooses each time: "Delete on this device" (local, as today) or "Delete on all my devices" (sends `del`; user decision Q1, no trash). Receivers apply at most **50 per hour and 200 per day** per sending device; the rest is parked and the user sees "Your other device deleted many messages: apply?". Applied deletes write a persisted tombstone (section 6). Saved is never deleted by a `del` from a device whose Saved category is not `all`.
- **Edits and rewriting (H2).** `mut edit` applies only to `outbound` messages, as `editMessage` does (mc:18325). Own devices never change the body of a contact-authored message: contact content arrives as new messages (`rx`, pages), shown `viaOwnDevice`, and a message already known is not rewritten by an own device (a contact's edit reaches a device from the contact or not at all). Caps per sending device: edits 100 per hour / 500 per day, contact events 20 per hour / 100 per day, reactions 200 per hour / 1000 per day; over the cap is parked like deletes. All caps are constants in one file.
- **Verified (Q7).** A mark does not exist yet, so M33 adds it: `ContactRecord.verifications`, a list of `{byDeviceId, keyHash, at}` (the contact's current key fingerprint, as `_keyFingerprint` at mc:37900). A contact **shows verified only if** some attestation matches its current `keyHash` **and** its author is this device or a device in the current signed list that is not revoked. That is derived, never stored as a flag: (a) revoking a device makes its attestations stop counting on every device at once, with nothing to reset and nothing a revoked device can leave behind; (b) a key change makes the hashes differ, so the mark clears on every device without an event; (c) the UI says "verified on <names>". `verify` carries only the sender's own attestation, accepted only from the sender about itself, never relayed (so nobody vouches for another device); "remove my verification" clears only the sender's own. `contact` events never carry attestations. A compromised device can attest until revoked; revoking removes its marks. P2 adds the model and event; the action ("I compared the safety numbers") is P5.
- **A revoked device keeps what it already synced** (cannot be unsent); the Devices UI must say so when revoking. It receives nothing new from this account's devices, and contacts stop sending to it as soon as they apply the new list (existing behaviour).
- Contact sync takes **public data only**: no routes, no sessions, no private keys. The new device builds its own Olm session with each contact (contacts learn the device from the signed account statement, which exists). Contacts the user removed, or that are pending, declined or hidden never leave the device (the `_linkableContacts` rule, mc:37866).

### 6. Storage and migration (append-only)

- `GlobalConnectivityPreferences.ownDeviceSync` (appended, JSON key `ownDeviceSync`, omitted at default): `{mode, cats, windowDays, mobileData}`. Enums are persisted by name; unknown names load as the default. New enums: `OwnDeviceSyncMode {full, contactsOnly, independent, custom}`, `SyncCategory {messages, media, files, contacts, settings, saved}`, `SyncAmount {off, recent, all}`; all append-only.
- **Absent field = today's behaviour** (grandfather, pitfall 18): loads as `custom` with messages `recent` (30 days, 500 per chat), media and files `off` (details only), saved `all`, settings = `shareSettings`, and **contacts `all`** (user decision Q2: contacts, including adds, removes and renames, sync on every linked device, existing ones included, with no card asking first). A fresh link defaults to `full`. Saved follows the mode (Q4): it is `all` in `full` and `off` in `contactsOnly` and `independent` unless turned on separately; an absent field keeps today's `all`.
- `GlobalConnectivityPreferences.settingsClocks` (appended): key -> clock ms, for `settings2`. `settingsChangedAt` is still written on every shared change so old devices keep working.
- **`rev` (H1)** is the hash (first 8 bytes of SHA-256) of the converged state of a message: body and `editedAt`, the deleted flag, and the sorted reactions with their clocks. It is derived, never stored. The ledger hashes `(id, rev)`.
- **Tombstones** (`AppSnapshot.deletedMessages`, appended, optional): `{id, chat, createdAtMs, rev, kind}` for the user's own deletes only (`kind` = hidden for a local delete, deleted for an all-devices delete), <= 4096 entries and <= 256 KiB. They are kept **at least as long as the largest window in use plus 30 days** (a local delete must outlive the window it could be re-imported through), Saved and `all` chats until the cap. When the cap forces the oldest out, a per-chat watermark `clearedBefore` (the newest `createdAt` dropped in that chat, <= 256 chats) replaces them: older messages of that chat that this device does not hold are not imported (documented trade-off, only for chats with thousands of deletions). Seeds `_locallyDeletedMessageIds` at load so no `contains` call site changes; the add sites for the user's deletes (mc:42944 `_deleteMessage`, applied `del`) also write the record. **A contact's early deletes (mc:26892) stay in the in-memory set and get their own cap (1024, 30 days), so a delete flood from a contact cannot push the user's tombstones out.** Fixes G6.
- **Verifications** (`ContactRecord.verifications`, appended, omitted when empty): <= 8 per contact, one per own device.
- **Cursors** (`AppSnapshot.syncCursors`, appended): per (own device, chat) the last finished day and page cursor, <= 64 KiB, oldest dropped (a drop only costs a re-ask). Added in P3.
- **Sync queue byte cap**, per device, 4 MiB across all accountSync entries, oldest folding-eligible first. Ships in P3 with the digest that repairs a drop. A vault that already holds more keeps it (the cap applies to new entries only).
- Digest ledgers, prefs of other devices, budgets, progress and the wanted-file queue are derived, in memory, rebuilt on first touch. Nothing derived is migrated. No existing message, contact or file is rewritten or deleted by any migration.

### 7. The policy layer

**Categories and amounts.** `messages` (text of 1:1 and group chats, with edits, reactions, deletes), `media` (photos, voice, video inside chats), `files` (other attachments), `contacts`, `settings`, `saved`. `SyncAmount`: `off` / `recent` (window 7, 30 or 90 days, <= 500 per chat) / `all` (no window; <= 5000 per chat, the Saved cap today). For `media` and `files`: `off` = details only (today), `recent` = bytes fetched automatically inside the window, per file <= 100 MiB, `all` = every file in scope without the per-file cap. Presets fill the categories: **full** (messages `recent`, media `recent`, files `recent`, contacts `all`, settings per `shareSettings`, saved `all`), **contactsOnly** (contacts `all`, settings per `shareSettings`, the rest `off`, saved `off` unless turned on), **independent** (everything `off`, saved `off` unless turned on). Editing any category switches the mode to `custom`. **Saved is its own entry**, so it can be `all` while contacts are `off`. The mode applies in both directions: a device that is `independent` neither sends nor imports.

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

**`scopeFor(ContactRecord target)`** returns per category the amount, window, per-chat cap, `bulkAllowed`, `bytesPerSecond`, `maxPaths`, `dailyBytes`. It is the **one place** that answers "what may this device send to that device now". **M65 hook:** `DeviceSyncProfile profileOf(DeviceCert)` returns `normal` today. A future `temporary` profile (from an appended `expiresAt` on the cert) clamps every category to `recent`, window <= 7 days, media and files to `off`, contacts and settings to `off`, saved to the recent window, and forbids bulk over metered or cold. The sender applies the clamp, but it only holds if the temporary device never gets the account key and the profile is signed by another, non-temporary device (section 5); until then it is a hook with no protective effect.

**Enforcement points (all call the same service):** live-event queueing (an `off` category is dropped at queue time, so the queue cannot grow; a `paused` or `held` condition keeps the event; a policy refusal is a hold, never a route failure), history page building, bucket and contact pages, `have` / `have_qb` answers, `_serveAttachmentChunkRequest` for own devices (pacer per target, bounded to 16 devices), and the wanted-file queue.

**Settings that weaken protection** (app lock, read receipts, link previews, a privacy toggle) arrive as a proposal and are applied only after the receiving device's user confirms; the others apply at once with the existing notice. **Clocks are an HLC:** a write takes `max(wall, last seen + 1)`; ties go to the higher device id (edits use the same rule); a clock more than 5 minutes ahead of this device's is **rejected**, not clamped.

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

- **Ledger, incremental.** Per chat: `Map<dayIndex, (count, xorHash)>`, hash = XOR of 64-bit per-id hashes of `(id, rev)`, so add and remove are O(1) and order-free. Built lazily per chat on first request (one pass over that chat), kept current by dirty hooks in the four mutators (`_upsertMessage` mc:42450, `_upsertGroupMessage`, `_deleteMessage`, `_updateMessageBody` / reactions). The day index is the UTC day of the message's own `createdAt`. Beyond the 90-day day buckets (`all`), **month buckets** cover older history (M5), so a month that differs is paged, not rescanned. It replaces the whole-sort `_chatDigests` for v2 targets (G9). The XOR hash is a convergence hint between trusted devices only; a collision delays a repair, never authorizes anything.
- **Cost is proportional to the difference.** `dgs` sends one root per chat; a mismatch asks `dgb` (<= 90 buckets); only differing days are paged (`history_req2`). Today any mismatch re-sends the whole window.
- **Bounded per event.** <= 32 events per envelope; one page <= 48 KiB; <= 4 chats and 1 page in flight per chat per target; the pump does one step per event; no rescan on a change (dirty chats only); the wanted-file queue holds <= 512 entries, refilled one chat page at a time when below 16.
- **No JSON in hot paths.** Prefs are parsed once into a typed object per device; the ledger holds ints; digests are built from the ledger without decoding messages. A page is decoded once to be sent. New events do not use the O(queue) fold scan (mc:38962, a risk the lab should time with 500 queued events); if it shows, an index is a later round. A live `mut` costs a whole-list copy (mc:28321) and a vault save; the lab times 500 queued events.
- **Idle cost: zero.** No timers; no own devices means a dormant service; cold devices get no extra wake.
- **Before a release (measure, do not guess):** ledger build time for 50 chats x 5000 messages; vault save size with tombstones and cursors; frame times while a 1 GB backlog syncs on a phone; idle wakeups with one own device absent (expect none added); CPU of a fast sync.

### 10. Invariants against Known pitfalls 1-20

1. Inbound: new handlers only mutate memory and schedule; answers (`dgb`, `have`, pages, `contacts_page`) go to the queue, the pacer or `_afterProcessing`; file starts use `unawaited`. No send is awaited on the inbound path.
2. The queue stores plaintext; sync envelopes are lazy-sealed (`LazySeal`, section 1) and sealed by the transport at hand-off after the limiter turn; a P0 test pins it against the strict ratchet fake. A page is built **after** the pacer releases it. Bulk envelopes go over one route (section 4).
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
16. Bulk is lazy-sealed at the send (point 2). Pacing precedes building.
17. Every ask has an attempt cap (history 3, files 3 per source) and backoff; a failing device does not block others (per-device queues); a full queue or budget never fails inbound processing; permanent failures show an error.
18. Absent prefs = today; tombstones start empty; caps apply to new data; deletes only by explicit action; contacts `off` for existing users; no message, contact or file is removed by a migration.
19. Section 9: typed prefs and ledger, no decode per item.
20. Service, ledger and budgets take an injected `now`; tests build envelopes and timestamps from the same fixed clock (the M29 `fixtureEpoch` pattern), never `DateTime.now()`.

### 11. Failure cases

- **A device offline for weeks.** Past `ownDeviceTouchDays` it is unconfirmed (today's rule): nothing is applied, queued bulk is not kept, events expire after 14 days. On `confirmOwnDevice` the parked envelopes are applied, then the touch sends `prefs` and `dgs`; only differing days inside the window are paged. What fell outside the window is not fetched unless the user raises it ("Sync older history", up to `all`); Saved is always `all`. Lost `sent` events are repaired by the ledger, not by the queue.
- **Two devices change the same setting.** Per key last-writer-wins on `(HLC, deviceId)`; a clock far in the future is rejected; ties go to the higher device id; the loser shows today's "changed from your other device" notice. Prefs are single-writer (each device owns its own). Message edits: later `editedAt` wins; reactions use the existing per `(device, emoji)` clock; a delete beats an edit; contact rename: later `rev`, and archive state follows `rev`. Keys never overwrite.
- **A revoked device.** Its next envelope fails the list check; `forget` clears everything for it; its source is `remove`d from running `BlockSourceSet`s (not blamed); a partial file already verified stays; unverified partials from it are re-fetched from other sources. It keeps what it synced.
- **Restart mid-sync.** Queued events are in the vault. Cursors resume from the last finished day or page (P3); asks in flight are asked again (3 tries); file partials resume from the `PartialTransfer` journal; the pump state is rebuilt on the first touch (the in-memory "announced to" set is empty, so `prefs` and `dgs` go again).
- **Quota or budget exhausted.** History budget: the sender answers `history_wait` with the seconds until the allowance frees (the existing handler clamps to 10 s - 1 h and asks again); progress says "waiting for the daily allowance". File budget: the queue holds and one deadline timer wakes it. Storage reserve (`storageReserveEnabled`): the file stays details-only, marked blocked, retried through the existing `waitingForStorage` path. Relay or carrier limits: a limiter refusal delays (pitfall 5). Conditions that stop bulk (battery, cold, metered) pause it and show why; resuming is event-driven.
- **A partial file.** Each block is verified under the file key and the whole file by hash (existing). A source that vanishes is removed and the others continue; with none left the wanted entry waits for the next `have_qb`; a hash mismatch deletes the partial and retries up to 3 times, then shows an error.
- **A lost or reordered sync event** (relay drop, carrier loss): repaired by the next digest exchange (on any touch after a quiet gap, and on the cold wake in P3).
- **A deletion storm from a compromised device:** capped at 50 per hour and 200 per day, parked beyond that, visible. A lost `del` is repaired by the ledger: the deleted `rev` is terminal and pages carry it, so the second sync touch after a local delete sends 0 page frames.
- **A revoked device had verified contacts.** Its attestations stop counting at once (section 5); nothing to reset.

### 12. Tests and sabotage checks

Fakes first, in their own commit: the in-test fakes (`_InProcessIrohNetwork` with `blockedPairs`, `_FakeCarrierNetwork`, `_FakeRelayClient`, `_MutablePower`, mc test lines 548, 1591, 1761, 36959) are looser than reality where M33 depends on them. `_FakeCarrierNetwork` has no loss, reordering, frame-size cap or rate limit (only `holdFrom`); add seeded loss and reorder, a frame cap (a 48 KiB page against a mail or Matrix limit) and a per-address rate budget with slow-down answers. The relay fake needs lease expiry and redelivery for sync envelopes. The ratchet fake (`fake_ratchet_engine.dart`) must keep Olm's 5 chains / 40 skipped keys; a test pins that. New: a metered / cold / battery switchboard over `_MutablePower` and the network cost class, and a helper `linkedDevices(n)` built on the existing `threeDevices()` (mc test line 23762) with a chain topology (C reaches only A; A and B only over a carrier).

Unit tests (pure): policy table (every row of section 7, sabotage: remove cold or metered rule), `scopeFor` intersection and the temporary-profile clamp, prefs round trip and unknown names, ledger add/remove/rev, day buckets and XOR hash (order independence), budget and pacer with a fixed clock, per-key LWW, tombstone cap and byte cap.

Controller tests (strict fakes):
1. Paused holds live events and bulk; resume flushes. Steady stays under 256 KB/s (pacer) including block serving; low battery stops bulk; cold mode never wakes a route for bulk; metered sends no file bytes. **S:** remove the serving check.
2. Fast needs confirmation each time, ends on drain, 6 h, restart and a metered switch; the offer appears once.
3. `prefs` narrows the sender: a target with `contacts off` gets no contact event; unknown prefs get the safe scope; the sender never sends beyond the target's declared prefs or its own; a unit test shows `profileOf` returning `normal` and the clamp applying once a profile is given. **S:** ignore the target's prefs.
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
14. Review additions: after a local delete the second touch sends 0 page frames; a contact's delete flood does not push out the user's tombstones; an edit to a contact-authored message from an own device is refused; a P1/P2 build against a P3 build exchanges no `account_sync_bulk`; bulk pages go over one route under the strict ratchet fake (5 chains, 40 skipped keys); "my reaction" is any own device id and a toggle clears all of them (reactions are keyed by device id, mc:18387); a revoked device's verifications stop counting, a key change clears the mark everywhere; a protection-weakening setting waits for confirmation; a future HLC is rejected.

Every test with an S is sabotage-checked (break, see it fail, restore) and logged. The Rust side is untouched, so there are no Rust sabotage branches. Full suite once at the end under the lock.

### 13. Lab checks (maintainer)

"Lab check needed" after the first green debug run of P0, P1, P3 and P4:
- Linux (A), phone 1 (B, linked), phone 2 (C): 2000 messages and 200 files on A; link B and C; watch progress and steady against the 256 KB/s cap; battery on the phones over one hour with a deliberately absent third device (expect no extra wakeups).
- Phone on mobile data: nothing heavy; text only.
- Kill the app mid-sync on B: resume without duplicates or loss; delete on A, restart B, no reappearance.
- C reaches only A (LAN), A to B over a Nostr carrier: edits, reactions, deletes and a 5 MB file cross the chain; counts of frames per day bucket on a mismatch.
- Revoke B during a fast sync: A stops serving within about 5 s.
- Fast offer dialog with a 1 GB backlog on Wi-Fi and mains; metered switch drops to steady.

### 14. Questions: resolved, and what remains

Resolved by the maintainer: Q5 only Conest's app settings sync (appearance, privacy, notifications, voice, composer; transports are M45, system settings M63); Q6 `account_sync_bulk` yes; Q8 group attachments wait for the M29 merge; Q9 reuse `BlockSourceSet`, do not wait for M27a; Q10 sync events are sealed at hand-off (already true, section 1; P0 pins it with a test). Resolved by the user: Q1 delete choice each time (50/h, 200/day, no trash); Q2 contacts sync everywhere without a card; Q3 numbers stand, configurable; Q4 Saved follows the mode; Q7 verified syncs, designed in section 5.

Remaining for the maintainer:
1. **Verified needs a new feature** (section 5): a "Mark as verified" action beside the safety number. OK to add it in P5, or should it be its own milestone?
2. **Per-chat `clearedBefore` watermark** (section 6) can hide never-held old messages of a chat after thousands of deletions. Acceptable, or raise the tombstone cap further?
3. **Contacts `all` for existing users** touches the privacy boundary of the link flow's "bring this device's data into the account": a contact removed on one device is archived (not erased) on the others, with an undo in the contact list. Confirm archive-not-erase.

### 15. Review findings: how each was checked

- **H1 confirmed.** The digest skips deleted messages (`!message.deleted`, mc:39235) and a local delete removes the record (mc:42938), so the other device keeps paging it; a contact's early deletes share the set (mc:26892). Fixed in section 6 (`rev`, terminal deleted rev, hidden tombstones, watermark, separate early-delete cap).
- **H2 confirmed.** `editMessage` refuses non-outbound (mc:18325); rev 1 had no such rule for `mut`. Fixed in section 5.
- **H3 confirmed.** An old build drops an unknown v3 kind before decrypt (mc:21978). Fixed in section 4.
- **M1 confirmed.** `DeviceCert` has no class or expiry (account_model.dart:280). Section 5 reworded; test 3 below is about declared prefs only.
- **M2 confirmed.** The reaction toggle checks only `me.deviceId` (mc:18387-18395). The M29 notes (E6) make reactions belong to the account **in groups**; 1:1 stays keyed by device id, so P2 defines "mine" as all own device ids.
- **M3 confirmed.** The old bundle has one wall-clock timestamp (`settingsChangedAt`) and clamps a future time (mc:39166); fixed in section 7.
- **M4 confirmed.** The repair is sent only after 5 minutes of quiet (mc:38497-38512); fixed in section 4.
- **M5 confirmed.** The 90-day window has no digest beyond it; month buckets added.
- **M6 confirmed in principle.** Today a history page may be copied over several routes by the energy fanout; bulk now goes over one route. Tested with the strict ratchet fake in P3.
- **M7 and the LOWs confirmed.** `_hasWorkAwaitingAnswer` (mc:30427) counts accountSync entries; P0 stops that. The UTC day, the 3-key mapping, batching, the live-`mut` cost and the extra tests are in sections 4, 9 and 12.
- **Not corrected by the review but wrong in rev 1:** the "inherited pre-encryption risk" (see section 1, `LazySeal`).

## Handoff

### Design note (2026-11-07)

Rev 2 is above (sections 0-15), reviewed once by Opus; this round folded in its findings, the maintainer's answers and the user's decisions.

### P0: the speed policy on every path (2026-11-07, base d794362, branch `agent/m33-own-device-sync`)

**Commits** (each ends with the Co-Authored-By line)
- ff45aeb the strict carrier fake (own commit, first)
- 076d4ef the pure policy (live / bulk / files, cold mode) and the serve gate
- 0e18a92 the controller side: held live events, gated and paced block serving, kept requests, `maxPaths`, `fastUntil`, cold wake, cleanup on removal, reset and dispose
- 61a41ee "not now" still goes while paused
- 410a994 test for a removed device as a source of a running fetch
- design note commits: 7a009bd, 9af72f1

**What changed for users** (no wire change, no capability)
- Paused now holds what changes: sent messages, read marks and the like wait and are sent when you resume (before, only history and files were gated). The answer "not now" to a history request still goes.
- File bytes between own devices stop on mobile data; while the device is in cold mode (Automatic on a phone, or a laptop on battery) and the app is in the background, history pages, "do you have it" answers and file blocks wait until the app opens or the device charges on an unmetered network. History requests get `history_wait`; block requests are kept (<= 64, 10 min) and served as soon as conditions allow, not left to the other device's retry (30 s to 10 min).
- Blocks served to another own device are spaced to the steady cap (256 KB/s per device) with no wait on the inbound path; fast has no cap. Steady uses at most two sources for a file (the sender counts as one), fast more.
- A confirmed fast sync lasts six hours (`fastUntil`, memory only); after that it is steady until asked again.
- Events queued for an absent own device no longer keep a cold device waking.
- Removing an own device clears what was kept for it (queue, reach, file index, serving, kept requests, running fetch sources). A vault reset now clears all own-device sync state (before it cleared only the parked envelopes) and dispose cancels the new timers.

**Files:** `lib/src/transfer/own_device_sync_policy.dart` (`SyncTraffic`, `permitFor`, `SyncConditions.cold/foreground`, `SyncPermission.hold`), `lib/src/transfer/own_device_serve_gate.dart` (new), `lib/src/own_device_sync_controller.dart` (new, `part of` the controller, an extension), `lib/src/transfer/block_sources.dart` (`holds`, `clear`), small hooks in `messenger_controller.dart` (fields, `_syncConditions`, `_syncToOwnDevices`, the retry pass, `_hasWorkAwaitingAnswer`, `_serveAttachmentChunkRequest`, `_useOwnDeviceAsSource`, `_reconcileOwnDevices`, `setOwnDeviceSyncSpeed`, `setAppForegroundState`, `onConnectivityChanged`, `syncColdMode`, dispose, reset). `fmt_mine` was not run on the big file; long lines wrapped by hand.

**Differences from the design note** (decided while building; reasons in the progress log)
1. Block requests turned away by the policy are kept and resumed (added): the requester's own retry is too slow, and sync would otherwise look broken after a pause.
2. The gate's `maxWait` is 3 minutes and deferrals are bounded per device (8) and in all (64), because refusing a block "too far ahead" made large blocks (4 MiB at 256 KB/s = 16 s each) fail.
3. `history_wait` is exempt from the pause hold.
4. The explicit resume call in `setOwnDeviceSyncSpeed` was dropped: `updateGlobalConnectivity` already calls `syncColdMode`, whose tail resumes kept requests (a sabotage showed the extra call was dead).
5. Q10: sync envelopes were already lazy-sealed; pinned by a test instead of changed.
6. The single shared `SyncPacer` is gone; history pages use the per-device gate.

**Tests** (all new; the suite is below)
- `test/messenger_controller_test.dart` group "strict fakes for own-device sync" (5): carrier frame cap, loss, reordering, per-sender rate with a retry hint, defaults unchanged.
- `test/own_device_sync_policy_test.dart` (12 new): the policy table (paused, battery, saver, cold, metered, fast), the old `permit` equals bulk, the serve gate (denied spends nothing, pacing per device, no cap, too far ahead, bounds).
- `test/sync_envelope_seal_test.dart` (2): a sync event is sealed when a transport takes it, shared by copies; `account_sync` is a session kind.
- Controller group "own-device sync obeys the policy on every path (M33 P0)" in `test/own_device_sync_p0_cases.dart` (17): paused holds and flushes; "not now" still goes; conditions reach the permission (mobile, cold in the background, charging); fast lasts six hours; a cold device is not kept awake; a paused device serves no blocks and serves after resuming; steady spaces blocks, fast does not (9 MiB, three blocks); kept requests are served on resuming and on three triggers (app opened, network not metered, plugged in); dispose cancels timers; removal clears everything kept; reset clears it; steady uses as many sources as its paths allow and fast more; a removed device stops being a source of a running fetch.

**Sabotage checks** (each: break, see the test fail, restore): cold rule, files on metered, paused live hold, a denied permission spending, no max wait (policy tests); sealed at queue time, `account_sync` not a session kind (seal test); frame cap, reordering (fake tests); live events not held, retry pass sending held events, no flush on resume, cold and foreground not inputs, fast never expiring, sync entries waking a cold device, serving ignoring the policy, no pacing, refused request not kept, no resume on app open / network change / power change, `maxPaths` ignored (twice), nothing forgotten on removal and each of its parts (reach, file index, kept requests, timers, queued events), removed device staying a source, reset keeping state, dispose keeping timers, "not now" held while paused. Not sabotage-covered: the duplicate guard on resume (`_handleAttachmentChunkRequest` instead of the bare serve; the probe still passed) and the per-device and total bounds on deferred blocks (the gate's own device bound is tested).

**Pitfalls 1-20 for P0**
1. The inbound path awaits nothing new: a refused block is kept and returned from, a paced one is deferred by a timer, resumes are `unawaited`. (The serve itself awaits its own sends as before.)
2. Pinned by the seal test; waiting requests hold plaintext requests, blocks are read and sealed when served.
3. New timers: deferred blocks only (<= 64), cancelled on dispose, reset and removal; none poll or reschedule.
4. n/a.
5. A policy refusal returns before any route or limiter is touched; it cools nothing.
6. `_clearOwnDeviceSyncState` on dispose and reset (a gap found: reset cleared one map), `_forgetOwnDevices` per device.
7. Kept requests expire after 10 min; fast after 6 h; nothing holds a transport.
8. n/a. 9. Parking and deferral happen only after `_ownDeviceServingState` has authorised the requester and the file; resumes re-run it.
10. Pacing is charged in one place (the serve function, every route) and for history pages through the same gate.
11. Resume goes through an async handler that awaits before it reaches the gate; no synchronous recursion.
12. Kept <= 64, deferred <= 8 per device and 64 in all, gate <= 16 devices.
13. Nothing new is stored in the vault. 14. No wire change; old devices see no difference (an old requester is refused as a new one is).
15, 16. n/a. 17. A refusal blocks nothing; held events keep the existing per-device cap (500); kept and deferred work is bounded.
18. No migration; the held events and queue are untouched. 19. `_liveSyncHeld` builds a small value per sync event and per retry pass; nothing is decoded.
20. Policy and gate tests use fixed dates; controller tests use the controller's injected clock; the pacing test uses real timers for its waits only.

**Behaviour changes to confirm** (they follow section 7, but they are visible): a phone in Automatic (cold) in the background no longer serves history or file blocks to its other devices until opened or charging on Wi-Fi; paused now also holds live events.

**Not done in P0 (by design or found):** the relay fake's lease expiry and redelivery (needed from P3); a "Sync now" action (P5); a progress line (P3/P5); the history-page pacing timer is still not cancelled on dispose (it checks `_disposed`; existing); M27's open item that a compromised own device can serve AEAD-valid blocks (needs per-block hashes, a wire change).

**Performance risk:** none measured; per sync event and per served block the added work is O(1) (a small condition value, one gate lookup); the deferral scan is over <= 64 entries; `_forgetOwnDevices` runs only when a device is removed and is O(queue). The lab should still time 500 queued events with live `mut` later (P2).

**Release-note line (draft):** Syncing between your own devices now follows Paused, mobile data and battery: while paused, changes wait and are sent when you resume; files between your devices are not sent over mobile data; and a device in power-saving mode in the background syncs history and files only when you open the app or it charges on Wi-Fi.

**Lab check needed** (delivery and energy):
1. Phone in the background (cold, on battery), laptop asks for a file: nothing until the phone is opened or charging on Wi-Fi; then it arrives without waiting minutes.
2. Phone on mobile data: no file bytes between the phone and the laptop; messages still sync.
3. Pause the laptop, send messages and read some on the phone, resume: they arrive.
4. A 100 MB file between laptop and phone in steady: about 256 KB/s, phone battery and CPU while it runs; fast after confirming.
5. Revoke a device during a transfer: it stops being asked.
6. A cold phone with an absent own device: idle wakeups not above the last build's.

**Device checks:** the five lab items above need real phones; nothing else.

**Full suite and CI** (head 410a994)
- Full `flutter test` under the lock (`flock lock timeout 90m`, log `m33-p0-full-suite.log` in the worktree, not committed): 2386 passed, 24 skipped, 2 failed. The failures: the known local-only "native Iroh direct contact adding works without LAN or any relay", and "a lab burst sends twenty to each chat and group, and files, timed" (a timing failure under load: a 64 KiB file between two contacts stalled; it passes alone 4 of 4 times and together with the other lab tests, involves no own device, and other agents' full runs show different timing flakes each time).
- `flutter analyze`: 28 issues, the base's.
- `debug.yml`: run 42407501125 on 0e18a92 green; run 42460377499 on the head 410a994 green (all jobs).
- `cp ~/conest-lab/pubspec.lock.mine pubspec.lock` was done after the suite; `git status` is clean apart from this file.

**Blocked:** nothing. (Found, not mine: the shared test lock was held for a long time by another session's run, and a `flutter_tester` orphan (pid 1441880) has been using a full core for 10 hours; I did not touch either.)

### P0 review fixes (2026-11-08; Opus review of P0; commits e6c8bd5, e12631c)

Each finding was checked against the code first; all were confirmed.

**HIGH confirmed and fixed** (a pause lost group mirror events, and long pauses lost held events):
- `_syncToOwnDevices` dropped every "bulky" event while paused, `group_message` and `tgx` among them (before M29 the mirror's only way). Now only a device out of touch gets all bulk dropped; a pause drops just `history_page`, `have` and `have_q`.
- Held events lived from their creation, so the first retry pass after a pause of over 14 days threw them away. `_resumeOwnDeviceSync` gives held events a new lifetime from the resume (their envelope time becomes the resume time).
- The digest ran only after 5 minutes of quiet and `_sendSyncStatusTo` returned early while paused, so a device that touched during the pause had used its trigger. Resuming now sends every own device the status. The 500-per-device cap is unchanged (a busy pause drops the oldest; the status repairs what the 7-day, 200-id digest window covers).
- Tests: group message and bridge kept, pages and answers dropped; an event held over 14 days (the clock moved 15 days with the phone heard from) is sent on resume; a message a full queue dropped is asked for again after resuming.

**MEDIUM 1 and 2 confirmed and fixed:**
- The pace was charged before checks that could send nothing, and a deferral that could not be kept kept the charge. Admission now sits just before the block is read; a request already waiting is let go before it; `OwnDeviceServeGate.refund` gives back what a refused deferral spent.
- The gate, `fastUntil` and the kept requests trusted the wall clock. The gate clears its debts when the clock goes back; `fastUntil` ends if it is further off than six hours; kept requests use `isFresh` (a time ahead of now is not fresh). (A cap at `now + maxWait`, as the review suggested, made "too far ahead" impossible, so the backwards jump is detected instead.)

**LOWs fixed:** a deferred block goes through `_handleAttachmentChunkRequest`'s duplicate guard; history pages waiting for their pace are tracked, cancelled with the device and on dispose, and rechecked when they fire (a refusal then sends `history_wait`); a file whose only source was the removed device is shown as failed with a message.

**Found on the way (not in the review):** a send that finishes moves its file from the spool to the cache, and the own-device serving state found a moment before pointed at the old path: the read failed silently and the other device waited half a minute or more. A flaky P0 test (one run in six) showed it. The serve now looks the file up again once; a test makes the path stale on purpose.

**Sabotage checks:** gate refund, clock set back, `isFresh`; pause dropping group messages; held events expiring; no status on resume; duplicate spending pace (precheck and refund removed together; each alone is covered by the other); page timers untracked; removed source's file left waiting; fast stretched by a clock set back; no second lookup of a moved file.

### P1a: what each own device wants to sync, settings key by key, a status with the events (2026-11-08, commit 255c623)

**The split.** P1 is cut in two. **P1a (this round, done):** `ownDeviceSyncV2` as a capability value, the prefs model and `prefs` event with scope enforcement on every path, `settings2` with a hybrid clock and confirmation of protection-lowering settings, `dgs` and the status attached to events (review M4), the requesting-side file rule (review M3). **P1b (next round, not started):** `mut` (edit, react, all-devices delete) with the persisted tombstones, the `clearedBefore` watermark and the caps; `contact` / `contact_rm` with archive-not-erase; `verify` attestations. The capability is **not advertised** (`_advertiseOwnDeviceSyncV2` is false) until P1b is done, because a capability is advertised only by a build that implements every event it names; the tests switch it on per controller (`ownDeviceSyncV2ForTesting`). The `prefs`, `settings2` and `dgs` code is therefore inert in a build from this branch until P1b flips the flag, apart from what applies to every own device (below).

**What P1a does for users once on**
- `OwnDeviceSyncPrefs` in `GlobalConnectivityPreferences` (JSON `ownDeviceSync`, omitted at the default): a mode (full, contacts only, independent, custom), an amount per category (messages, media, files, contacts, settings, Saved: off, recent, all), a window of 7, 30 or 90 days, mobile data for media and files. A vault without it reads as what the app did before. Saved is its own category and follows the mode (user decision Q4). `setOwnDeviceSyncPrefs` stores it, tells the other devices, and asks them for what newly counts.
- Scope: for each category the smaller of what both devices want; a device that has not said gets what the app did before. It is enforced when an event is queued, when one arrives (a device drops what it does not want), when a contact's message would be passed on, and when history is served (the category and the window). `prefs` from a contact or an unconfirmed device is ignored by the existing gate.
- Shared settings travel per key (`settings2`: value, milliseconds, device id) with a hybrid clock; a clock more than five minutes ahead is refused; ties go to the higher device id; two devices changing different settings at once both stay (the old whole-bundle event lost one). Older devices still get the old bundle. A setting that lowers protection (the read-receipts switch turned off) from another device waits for the user (`pendingSharedSettings`, `confirmSharedSetting`, `dismissSharedSetting`).
- A status (`dgs`: chats held, a hash of the settings' clocks) goes with the events after 50 of them or half an hour, without a timer; a device that sees the clocks differ sends its settings, so a lost event is repaired. Older devices get the v1 digest and reach.
- File bytes from another own device wait for the user on a metered network or when cold in the background (review M3), including as extra sources.

**Applies to every own device even without the capability:** the status with the events (v1 digest and reach for older devices), and the file rule on the requesting side.

**Files:** `lib/src/sync/sync_prefs.dart`, `lib/src/sync/hybrid_clock.dart`, `lib/src/own_device_prefs_controller.dart`, `lib/src/own_device_settings_controller.dart` (parts of the controller), `GlobalConnectivityPreferences` (fields `ownDeviceSyncChoice`, `settingsClocks`), `ApplicationCapability.ownDeviceSyncV2`; small hooks in `messenger_controller.dart` (queue filter, arrival check, rx pass-on, history scope, status, settings tell, capability list).

**Tests** (all new): `test/sync_prefs_test.dart` (16: presets, legacy, JSON, scope, window, event categories, the vault), `test/hybrid_clock_test.dart` (4), group "own devices say what they want to sync (M33 P1)" in `test/own_device_sync_p1_cases.dart` (18).

**Sabotage checks:** queue ignoring scope, arrival ignoring own prefs, rx pass-on ignoring scope, history ignoring the category and the window (each of the two guards alone is covered by the other; both removed fails), prefs sent to a build that does not know them, file bytes by themselves on mobile data; clock `next`, tie, future clock; older write replacing a newer, a weaker setting applied unasked, no repair from the status, no status with events, no status for time alone, `settings2` never sent, the older device getting no bundle. The first-word announcement of prefs I wrote at first proved redundant (the reply to a received `prefs` and the status send cover it), so it was removed.

**Pitfalls for P1a:** 1 nothing awaits a send inbound (`_takeStatus` and the prefs reply only queue); 2 queue holds plaintext; 3 no timer added; 5 a scope refusal drops or holds, never touches a route; 6 `_ownDevicePrefs`, announced, pending settings, repair and status counters cleared on dispose, reset and removal; 9 the gate comes first, then my prefs, then bounds (`settings2`: shareSettings, key whitelist, value shape, clock); 10 the status counter is charged in one place (`_noteSyncEventSent`); 12 prefs and counters are bounded to 16 devices, `settings2` to 16 keys, pending to 16; 13 `settingsClocks` is at most 32 short strings; 14 `prefs`, `settings2` and `dgs` go only to devices that advertise `ownDeviceSyncV2` (the old events otherwise); 17 nothing blocks; 18 an absent field is today's behaviour; 19 prefs parsed once per event; 20 the clock tests use injected clocks.

**Not in P1a, on purpose:** `mut`, contacts, verified, tombstones, the `clearedBefore` watermark (P1b); settings categories beyond the four keys (appearance, notifications, voice and composer live in other stores: more keys later); the review's "turn `_CarrierRefused.retryAfter` into a type production can obey" and switching the strict carrier fake on in controller tests (needs a carrier-only chain of own devices; before P3).

## Progress log

- 2026-11-07/08 (P0): wrote the tests before the code each time (the pure policy and gate tests were red on compile first; the controller tests referenced hooks that did not exist). Order: fakes (ff45aeb), pure policy and gate (076d4ef), controller side (0e18a92), follow-ups (61a41ee, 410a994). Sabotage checks as listed in the Handoff; two sabotages passed at first and led to changes: (a) "no flush on resume" did not fail because the test polled the laptop too, so the test now polls only the phone with a 4 s limit; (b) the explicit resume call in `setOwnDeviceSyncSpeed` could not be made to matter (`updateGlobalConnectivity` reaches `syncColdMode`), so it was removed.
- Decisions made on the way: block requests turned away by the policy are kept and resumed (the requester's own retry is `transferRetryDelay`: 30 s, and up to 10 min for 4 MiB blocks); the gate no longer refuses a block that is far ahead of the pace (large blocks at 256 KB/s are 16 s each), it defers, bounded per device (8) and in all (64); `history_wait` is exempt from the pause hold, or the other device asks blindly and gives up after three tries; sources are counted with the sender for `maxPaths`; `OwnDeviceFileIndex` got `holds` and `clear`.
- Findings: `resetIdentity` cleared only `_parkedOwnSync` of all own-device sync state (pitfall 6); `account_sync` was already lazy-sealed (Q10 asked for it; now pinned); `timeout 90m flock ...` counts the waiting for the lock, so the suite was started as `flock lock timeout 90m flutter test` (same protection against a hung run); the previous session's suite was cut off at 26 min (2242 passed, only the Iroh failure) and was run again from scratch.
- Suite and CI: see the Handoff ("Full suite and CI").

- 2026-11-07: read PLAN_AGENTS.md, this file, the maintainer's plan sections (M33, M29e parts B and C, Group 1 items 2 and 3, D1, D2, D4, M65, the M50 side answer), PLAN_M29.md (design sections 7-9 and handoff) and PLAN_M27.md (handoff). Inventoried own-device sync in `messenger_controller.dart`, `transfer/`, `models.dart`, `energy_policy.dart`, `cold_mode.dart`, `devices_panel.dart` and the tests at base d794362 (evidence in section 1). Found that `OwnDeviceSyncPreferences` and the `prefs` event do not exist, edits/deletes/reactions do not sync between own devices, `_locallyDeletedMessageIds` is memory only, and the speed policy is enforced for history pages only. Wrote the design note; no code changed. An API session limit interrupted the first pass; resumed from the link grant onward.

- 2026-11-07 (rev 2): pulled the maintainer's answers, the user's decisions and the Opus design review; checked every finding against the code (section 15; all confirmed, none wrong). Two corrections to my own rev 1: sync envelopes are already lazy-sealed (`sealLater` + `LazySeal`), so Q10 needs a pinning test, not a new mechanism; and no "verified" mark exists at the base, so Q7 adds one (derived from attestations by listed, unrevoked own devices). Revised sections 0-15; no code yet.

## Maintainer's answers to the technical open questions (2026-11-07)

- **Q5:** only Conest's own app settings sync in M33: appearance, privacy, notifications, voice and composer. Transport settings belong to M45. System settings (Wi-Fi and similar) belong to M63.
- **Q6:** yes, add a new `account_sync_bulk` kind.
- **Q8:** yes. Group attachment sync waits for the M29 merge, so merge M29 into this branch when the main session says so.
- **Q9:** don't wait for M27a. Reuse `BlockSourceSet`.
- **Q10:** yes, P0 fixes it for sync events. Seal them at hand-off, using G8's `LazySeal` pattern, and don't encrypt before the limiter.
- **Product questions:** Q1, Q2, Q3, Q4 and Q7 go to the user. Until they answer, use the note's proposed defaults and keep them configurable.

## User decisions (2026-11-07, product questions)

- **Q1 Deletes:** the user chooses each time, "Delete on this device" or "Delete on all my devices". All-devices deletes are capped at 50 an hour and 200 a day (review M7). No 7-day trash.
- **Q2 Contacts:** contacts (adds, removes and renames) sync on every linked device, existing ones included, with no card asking first.
- **Q4 Saved:** Saved follows the mode. In "contacts only" and "independent" it does not sync unless turned on separately.
- **Q7 Verified:** "verified" syncs between own devices.
  - Design it so that a device revoked later cannot leave contacts marked verified. Reset the verifications it set, or keep them per device and show which device verified each contact.
  - If a contact's keys change, the mark clears on every device.
- **Q3 Numbers:** the note's starting values stand, all configurable.

## Design review (Opus, 2026-11-07): revise first

The inventory checks out. The architecture is sound: push for live changes, pull for the backlog, the trust gate first, the policy table, no new polling, and strict fakes first. Fold the items below into the Design note before any code.

### HIGH

**H1. Deletes don't converge, and deleted messages come back.**
- **Where:** §6, §9, §11.
- **Why:**
  - The ledger hashes the messages a device holds, and the digest leaves deleted ones out, so a local delete makes one day differ forever and it gets re-paged on every touch.
  - A lost `del` is never repaired.
  - Tombstones last 60 days while windows reach 90, and `all` has no window.
  - Contact-early deletes (mc:26892) can push the user's own tombstones out of the 2048-entry cap.
  - `rev` is undefined.
- **Fix:**
  - `rev` is the hash of the converged state: body or `editedAt`, the deleted flag, and the sorted reactions with their clocks.
  - Tombstoned ids stay in the ledger:
    - a local-only delete becomes a hidden entry;
    - an all-devices delete becomes a terminal deleted `rev` that pages carry.
  - Own tombstones live at least as long as the largest window, plus a per-chat "cleared before T" watermark.
  - Contact-early deletes are stored separately, with their own cap.

**H2. An own device can rewrite or flood messages without limit.**
- **Where:** §4, §5.
- **Fix:**
  - `mut edit` applies only to `outbound` messages (as `editMessage` already does, mc:18325).
  - Contact-authored content that arrives from an own device is shown as `viaOwnDevice`, and its previous body is kept.
  - Edits and contact adds are capped per device per hour and per day. Anything over the cap is parked, like deletes.

**H3. One capability covers phases that ship separately.**
- **Where:** §3, §4.
- **Why:** a P3 device would send bulk messages and `history_req2` to a P1/P2 device, which drops them. Envelopes dropped undecrypted can use up Olm's skipped keys (pitfall 2).
- **Fix:** one capability per wire step, appended in order:
  - `ownDeviceSyncV2`: `prefs`, `mut`, `contact`, `settings2`;
  - `ownDeviceSyncBulkV1`: P3;
  - `ownDeviceFilesV2`: `have_qb`.
  
  Senders fall back to the v1 events for a target that lacks a step's capability.
- **Test:** a P1 build against a P3 build.

### MEDIUM

- **M1. Scope taken from the target's certificate protects nothing yet.** `DeviceCert` has no class or expiry, and every device holds the account private key. So today scope = my prefs ∧ the target's prefs. Write that the M65 temporary profile works only if temporary devices never get the account key and the profile is signed by a non-temporary device that is not the target. Reword test 3 to match.
- **M2. Reactions are stored per device id** (mc:18387–18395). "My reaction" must mean any of my own device ids, and a toggle clears them all. Check this against M29's account identity.
- **M3. Settings clocks.**
  - Use an HLC: max(wall, last seen + 1), with ties going to the higher device id.
  - Reject future clocks instead of clamping them.
  - Use the same tiebreak for edits.
  - A synced setting that weakens protection (app lock, receipts, link previews) is applied only after the receiving device confirms it.
- **M4. Repair only after 5 min of quiet** (mc:38497).
  - Attach `dgs` to an outgoing envelope after N events or 30 min of steady contact, with no new timer.
  - Add a hash of the settings clocks to `dgs`.
- **M5. Ledger vs `all`.** History older than 90 days has no digest. Add coarse month buckets beyond 90 days, or a one-time sweep driven by a cursor.
- **M6. Pages on several routes vs Olm's 5 receiving chains.** Bulk envelopes to a target go over one route, the one the request came on. Use `maxPaths` only for file blocks. Add a test with the strict ratchet fake.
- **M7. Delete cap.** Add a daily cap of 200 (see Q1).

### LOW

- `_hasWorkAwaitingAnswer` (mc:30433): accountSync entries never count.
- The day index comes from the message's own `createdAt` in UTC.
- Map the old 3-key settings bundle onto `settings2`. Batch more than 16 keys across several events.
- Time it: a live `mut` costs a whole-list copy (mc:28321) and a full vault save. Lab check with 500 queued events.
- More tests:
  - after a local delete, the second sync touch sends 0 page frames;
  - a contact's delete flood does not push out own tombstones;
  - an edit to a contact-authored message is refused or marked.

Per the lane rule this is the one design review round. After the revision, implement P0 without another design review.

## Maintainer (2026-11-08): P0 decisions and section 14

- **P0 "Decisions to confirm":** all accepted.
  - The cold-mode phone holds history and files.
  - Pause also holds live events.
  - Refused block requests are parked.
  - The gate defers instead of refusing.
  - `history_wait` is exempt from the pause hold.
  - The explicit resume call is dropped.
- **Section 14:**
  - **"Mark as verified":** yes, an explicit action on the contact's safety-number screen. It writes an attestation that syncs (Q7).
  - **Per-chat `clearedBefore` watermark:** yes, as review H1 asks.
  - **A contact removed on another device:** archive it, don't erase it. The contact leaves the list, and its chat and history are kept under archived contacts. Erasing stays a local, explicit action.
- **Next:** P1 starts after the Opus code review of P0.

## Code review of P0 (Opus, 2026-11-08): fix first

### HIGH (data loss)

**A pause drops group mirror events, and long pauses expire held events with no repair afterwards.**
- **Where:** `messenger_controller.dart` ~39085: `if (held || isOwnDeviceUnconfirmed(device)) { if (bulky) continue; …`.
- **What goes wrong:**
  - `bulky` includes `group_message` and `tgx`, so a pause drops group mirror events. Before M29 they are the only way a mirrored device sees groups.
  - Held `sent` and `rx` events skip expiry only while paused (~28544). On the first pass after resume, anything older than 14 days is cleared without being sent.
  - The 500-per-device cap drops events during a long, busy pause.
  - The digest covers only 7 days and 200 ids per chat (~39303). It runs only after 5 min of quiet.
  - `_sendSyncStatusTo` returns early while paused (~39331), yet `inTouchAt` is still updated (~38545), so reconnecting during a pause uses up the trigger.
- **Fix:**
  - The bulky drop applies only to unconfirmed devices. While paused, keep `group_message` and `tgx`; still drop `history_page`, `have` and `have_q`.
  - Paused-held entries don't expire: count their lifetime from resume.
  - On resume, send `_sendSyncStatusTo` to every own device.
  - Raise the cap to cover a busy pause, or replace overflow with a "digest needed" flag.
- **Tests:** a pause of several days with group traffic, then resume, delivers everything. Held 1:1 events older than 14 days at resume are still sent.

### MEDIUM (fix now: 1 and 2; in P1: 3 and 4)

1. **The pace is charged before a block can be deferred or served.**
   - **Where:** ~23251; `own_device_sync_controller.dart` ~55.
   - **Fix:** run the duplicate, bound and `requiresLan` checks before `admit`, or give the time back when nothing is served.
2. **The gate, `fastUntil` and the parking lifetime use the wall clock.**
   - **Where:** `own_device_serve_gate.dart` ~34–45.
   - **Fix:** use a monotonic `Stopwatch`, or cap `_freeAt` at now + `maxWait`.
3. **The requesting side ignores the file rules:**
   - `_useOwnDeviceAsSource` (~39908) and `_fetchFileFromOwnDevice` (~40709, 40930, 41000) use the bulk permission, which allows metered networks;
   - use the files permission there too.
4. **The strict carrier fake is never switched on in the controller tests.**
   - Run "paused holds and flushes" and "steady spaces blocks" with loss and reordering on.
   - Turn `_CarrierRefused.retryAfter` into a type production code can obey.
   - Needed before P3.

### LOW

- A deferred serve skips the `_servingAttachmentBlocks` guard (`own_device_sync_controller.dart` ~67), so a block can be sent twice.
- History pages are sent from an untracked timer (~40541). Track it, and recheck the pause when it fires.
- `_forgetOwnDevices`: a fetch whose main peer was the removed device stops silently (~24896). Fail it visibly, or move it to another source (pitfall 17).
