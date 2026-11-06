# G9: gate regressions on build 308 (integration/g7-g8)

First read `/home/glitch/Documents/conest/PLAN_AGENTS.md` in full. It holds the shared rules, including Lanes, Known pitfalls 1–20 and Strict fakes.

- **Worktree:** `/home/glitch/Documents/conest/.worktrees/agent-g9`
- **Branch:** `agent/g9-gate-308`
- **Base:** `integration/g7-g8` (f389855), which contains G7, G8, canary and the lab fixes.
- **Lane:** careful (delivery, retries, limiters). Find the root cause first, using evidence from the reports. Then write a failing test with a strict fake, then the fix, then a sabotage check.
- **Never touch devices or lab scripts.** Lab reports are read only.

## The gate result (2026-11-04, build 308, against the October 30 pass)

Report folders are in `~/conest-lab/device-lab-reports/`. To summarize one:

```
python3 tool/device_lab/summarize.py <dir>
```

Each folder has `android.json`, `linux.json` and `windows.json` debug reports, plus `linux.log`. The baseline is `~/conest-lab/gate/quick-last-pass.json`.

| Run | Folder | Result |
|---|---|---|
| all-normal, all-reverse, relay, Nostr, calls | 20261104T182952Z, T183742Z, T184416Z, T185128Z, T192109Z | ok |
| **matrix-normal-burst** | **20261104T190000Z** | Every text eventually arrives, but **message p50 54.5 s, p95 116.6 s, against a 30 s deadline**. The last pass met it. Android handling p95 2234 ms (was 768). |
| **deltaChat-normal-burst** (email) | **20261104T190411Z** | Texts confirmed 136/180 (was 180/180), received 207 (was 240). The chatmail server answered "SMTP … Too much mail from …". |
| iroh-normal-burst | 20261104T184833Z | Files 14/30 (was 15/34). Same share; probably noise. Only look at it if items 1 and 2 are done. |

## 1. Matrix messages are slow (primary)

**Evidence:** the Matrix-only run logs, per device:
- about 40× `direct_message to lab-… found no route: Bad state: No eligible transport route.`;
- about 30× `Group catch-up waiting: TimeoutException`;
- a few `Rate limit: wouldWait`.

The carrier was ready the whole run.

**Suspects** (check each against the code and logs; do not assume):
- **G7's store rule:** `_storedOn` / `excludeRouteKeys` / `_storeRefresh`, 30 min. Matrix is a store-and-forward carrier. If a retry excludes the only route (Matrix), the send finds no eligible route and waits until something else moves it. Check whether "only stores left" correctly counts as handed off for a single-carrier contact, and whether the first send (not the retry) is affected.
- **G8's lazy seal and turn tokens** on carriers.
- **Receipt batching** (`ReceiptSendQueue`, `batchedAcksV1`). The text arrives fast but the ack comes late, and the deadline measures delivered-ack time.
- **The limiter's `maxWait`** for the Matrix account (`lib/src/matrix_carrier.dart` ~348).

**Where the delay comes from:** reconstruct the timeline of a few slow messages from the reports, using `sentAt`, `handedOffAt`, `deliveredAt` and the receiver's `receivedAt`. Report whether the delay is in sending, in the carrier, or in the ack.

**Also:** Android handling p95 went up 3×. Find which handler. The report's `activity` section and `performance` may help.

## 2. Email burst under the server's limit

The chatmail server refuses with "Too much mail". G8 set our email budget to a burst of 20, then 50 per minute. Check:
- whether acks, group copies, `group_history` and `route_update` all count against the same budget;
- whether a server refusal (SMTP 4xx/5xx "Too much mail") is treated like a "slow down": back off and retry later, never counted as a route failure, never dropped;
- whether anything is lost after a refusal, compared with merely being late. The run lingers 600 s, so anything still missing at the end is a loss or a stuck retry.

Fix by root cause. If the server's real limit is lower than our budget, lower the default and make it adapt when the server refuses.

## Tests

Use strict fakes:
- a Matrix fake that stores messages;
- an SMTP fake that refuses with "Too much mail" after N messages per minute.

Each test is sabotage-checked. Run the focused tests, then the full suite under:

```
timeout 90m flock ~/conest-lab/flutter-test.lock
```

with a unique log, then `cp ~/conest-lab/pubspec.lock.mine pubspec.lock`. Push the branch and run `gh workflow run debug.yml --ref agent/g9-gate-308`.

## Handoff

### Cause found (Matrix, primary), with the evidence

The delay is in the sender, in the account's own limiter. Not in the carrier, not in the server, not in the receiver.

Evidence (report `20261104T190000Z`, matrix-normal-burst, build 308; compared with `20261104T142055Z`, build 306, p50 4.3 s p95 6.5 s, and `20261030T190634Z`, the last pass, p50 0.5 s):
- Transit (receiver's `arrivedAt` minus the sender's `at`, both clocks NTP-synced) of the first message of each chat: 0.1 to 0.5 s. Then it grows by about 2.5 s per message index: 2.8, 4.7, 9.7, 14.7, 17.8 ... 44.6 s, and stays at 44.6 to 45.3 s for the next ones (the limiter's `maxWait` is 45 s). Android to Linux, DMs 1..20, made 19:01:06 to 19:01:43, arrived after 0.1, 2.8, 4.7, 9.7, 14.7, 17.8, 21.7, 24.7, 28.7, 31.6, 32.6, 36.3, 38.3, 41.3, 43.3, 71.3, 44.6, 44.7, 45.0, 75.1 s.
- No server pushback anywhere in the three devices' logs (no 429, no `M_LIMIT_EXCEEDED`, no `retry_after`). The refusals in the logs are the app's own: `Rate limit: wouldWait (turn in 45 s)` (46 in the first minute, always 45 or 46, i.e. the queue stood at `maxWait`).
- Slow messages, three timelines:
  1. Android to Linux, DM "burst 4": written 19:01:11.878, arrived +9.7 s, receipt back +33.8 s. 9.7 s in the sender's queue, then 24.1 s for the receipt, which waited in the receiver's queue behind its own messages.
  2. Android to Linux, DM "burst 16": written 19:01:36.338. Android logged `direct_message to lab-linux found no route: Rate limit: wouldWait (turn in 45 s)` at 19:01:36.474 (refused at once, queue full), so it waited for the 5 s retry tick and re-entered behind a full queue: arrived +71.3 s, receipt at once.
  3. Android group "burst 17", written 19:01:39.043: both members got it at +98 s, receipts +98.7 and +101.4 s. Group copies went through the same refusals.
- The load: from the reports, each device wrote 80 sends (20 rounds of 2 DMs and 2 group copies) in 33 to 38 s: 2.1 to 2.4 sends a second, plus receipts. The Matrix budget (`NetworkBudgets.matrix`) was gap 1 s, burst 10, one FIFO for messages, group copies, receipts and control. The queue grows by 1 to 1.5 a second, hence the linear growth above.
- Why 306 was fine: commit 60c27f6 ("a burst message is on its way once made") stopped the lab from waiting for each send. In 306 a device made 80 sends over 283 s (0.28 a second; the report took 7 min, not 3.5); in 308 over 33 to 38 s. The budget did not change; the lab now offers more than it carries. So it is not a G7/G8 logic regression, it is a capacity limit that the self-throttled lab hid.
- Synapse applies no rate limit to to-device messages of a custom type (read in its source: `send_device_message` limits only `m.room_key_request` to other users; the `sendToDevice` servlet has no limiter). The old comment ("rc_message 0.2 a second") was about room events. So 1 a second was a guess, not a server limit.

Suspects from the plan, checked:
- G7's store rule (`_storedOn`, `excludeRouteKeys`, 30 min): not a delay. The ~40 `direct_message ... found no route: No eligible transport route` per device are forced retry passes (`retryUnacknowledgedMessagesNow`, a message from the contact flushes the contact) over messages Matrix already stored; the pass correctly leaves them, and logged it as a send error each time. Fixed as noise (quiet), no behaviour change. A first send is not affected (nothing is excluded then).
- G8's lazy seal and turn tokens: not involved (the adapter seals after its turn; the frames are one each).
- Receipt batching: receipts are part of the delay (case 1: 24 s of 34) because they queue in the same FIFO behind messages; with the queue short they do not. Not changed (see Design questions).
- The limiter's `maxWait`: it is the plateau (45 s) and the cause of the 71 to 125 s tail (refused at once, retried on the 5 s tick behind a full queue), but a symptom of the capacity.
- "Group catch-up waiting: TimeoutException after 30 s" (28 a device): group history requests queued in the same limiter and timed out; they follow from the saturation.

Android handling p95 (2234 ms, was 768): no handler regression found. In this run the app was rendering (716 frames, 71% slow, the chat list rebuilt 1163 times in 215 s) while the 306 run had 0 frames and handling p95 352 ms. The same build shows the same on non-Matrix runs (Nostr 2079 ms, Conest relay 3979 ms) and build 305's Matrix run had 5354 ms. It is the debug build on the phone competing with the UI on the main isolate, varying with whether the screen was drawing. I changed nothing for it; the chat-list rebuild rate (5.4 a second on a burst) is a perf item for the UI owner.

### Cause found (email), with the evidence

Report `20261104T190411Z`. Two causes, both in how the account is paced; nothing was dropped.
1. The lab's accounts used the ordinary-provider budget. The lab keeps each device's chatmail account and hands it back with `--debug-email=MAIL,PASSWORD,IMAP,SMTP`; that went through `enableOwnEmailCarrier`, which made a config without `chatmail: true`. `NetworkBudgets.email(chatmail: false)` is gap 1.2 s, burst 10, quota 150 an hour. A device sent about 150 mails in the first 2 minutes (messages, group copies, receipts, offers, history), used the whole hour, and from 19:08:44 every send and receipt was refused with `Rate limit: wouldWait (turn in 3441 s)` (Windows; 3419 at 19:09:01 and 2776 at 19:19:43: a fixed moment, 20:06, when the first mails of the burst age out). The 600 s linger cannot outlast that. I reproduced the exact pattern with `NetworkLimiter` and the non-chatmail budget (45 s refusals for 117 s, then about 3500 s); with the chatmail budget it never goes above about 65 s.
   - This is why 44 of the 180 acks never came (the messages arrived: 207 received) and why Windows' group copies 2 to 9 were never sent (state pending for 13 minutes, nobody received them).
2. The server's own limit: `450 4.7.1 Too much mail from <...>, rate-limited until Instant{...}` (Android, 11 times, at 19:06:37, 19:07:37, 19:08:37 ... one a minute). It was treated as a failing route: `All transport routes failed: SMTP 450`, a route failure mark (`_recordFailure`), back-off and an attempt counted against the message. The channel already doubled its gap (`pushedBack()`), but the registry did not see it as a slow-down. Nothing was dropped: the messages stayed pending and were sent again, late.

Answers to the plan's questions:
- Acks, group copies, `group_history` and `route_update` all go through the same account limiter (every one is a carrier `sendEnvelope`, `channelPacesFrames` takes the turn first): yes, one budget.
- A server refusal: before, a route failure; now a wait (see fixes). Never dropped.
- Late or lost: nothing lost; everything missing at the end was stuck behind the hour's quota (1) or waiting for a retry after a refusal (2).
- The chatmail budget (burst 20, 50 a minute) is under the published 60 a minute and was not changed. The only refusals came on the ordinary budget (burst 10 plus 1.2 s gap is about 60 a minute, with the setup traffic before it). The gap still doubles after a refusal and eases after each mail that goes through (existing behaviour, kept).

### Fixes

1. `NetworkBudgets.matrix`: gap 200 ms (was 1 s), burst 10. Five sends a second, still under any limit seen; a server that does limit answers 429 with `retry_after`, which the limiter obeys exactly. (`lib/src/limits/network_budgets.dart`)
2. A server's slow-down is a wait, not a failing route: `SmtpException` is a `ServerSlowDown` (a temporary refusal that says too much / rate / limit / quota), and the transport registry treats any `ServerSlowDown` (this, Matrix 429, Telegram, Discord) like the limiter's own refusal: no failure mark, no back-off, and the result is `LimiterRefused(wouldWait)` with the server's wait if it named one, so the caller does not count the attempt. (`lib/src/email/smtp.dart`, `lib/src/email_carrier.dart`, `lib/src/transport.dart`)
3. Own email accounts: `enableOwnEmailCarrier(chatmail:)`; an account on one of `defaultChatmailDomains` is a chatmail account even when entered by hand, and an own account is never "picked by the app" (`serverPicked: false`, so it is never moved to another server). The lab file gets an optional fifth field `chatmail` (written after a sign-up, read back); the four-field files the lab already holds work through the domain rule (tarpit.fun and delta.disobey.net are in the list). (`lib/src/messenger_controller.dart`, `lib/src/debug_auto_run.dart`)
4. Noise: a retry pass that leaves out the stores holding a message and finds no other route no longer writes a `send` error (`quietWithoutOtherRoute` in `_deliverToContact`, set by `_deliverRetryPass`'s first call only). Other failures in that pass are still logged.

### Commits

- 5c47a2e Matrix budget, slow-down classification, strict Matrix server, tests
- 8475f25 chatmail own accounts, quiet retry pass, tests
- (handoff commit follows)

### Tests (strict fakes) and sabotage checks

- `test/support/strict_matrix_server.dart` (new): a `MatrixCarrierChannel` that stores frames with the time they came (store and forward), can limit the account (token bucket, `M_LIMIT_EXCEEDED` with a whole-second `retry_after`), counts sends that came before a named wait was over, and treats a repeated transaction id as a retry. Plus `StepClock`.
- `test/matrix_burst_test.dart` (new): the gate's burst from one device (20 rounds, 2 s apart: 2 DMs, 2 group copies, 2 receipts) on a fake clock with the real `NetworkBudgets.matrix`:
  - unlimited server (as Synapse): every send handed off, p50 < 3 s, p95 < 10 s, max < 20 s. Red before (the `wouldWait (turn in 46 s)` refusals of the lab, reproduced exactly).
  - server at 10 a second: no refusals, nothing lost. Red before.
  - server at 2 a second with whole-second `retry_after`: the wait it names is kept (0 sends before it is over), every frame taken once or refused for a retry. Sabotage: `NetworkLimiter.run` no longer calls `pushedBack` on a server slow-down: 38 early sends, red.
- `test/server_slow_down_test.dart` (new): registry given an SMTP "Too much mail" or a Matrix 429: `LimiterRefused`, `onOutcome(false)` never called, the named wait passed on; a full mailbox (452) is still a failing route; one route's slow-down does not hide another's failure. Red before (4 failures), green after.
- `test/messenger_controller_test.dart` (existing file, 3 tests): the lab's kept account stays chatmail and gets the per-minute budget (red before: `chatmail` false); a known chatmail server entered as an own account is chatmail, `serverPicked` false, an ordinary provider keeps the hourly quota (sabotage: domain rule removed, red); a retry pass over a stored message with Matrix-like single carrier writes no `No eligible` send error and does not store it again (red before: 3 errors for 3 passes).
- Budget sabotage: the old gap (1 s) turns the first two burst tests red (that is the "red before"). Transport sabotage: the old `limiterHeld` line turns `server_slow_down_test` red (the "red before").
- Full suite: see Progress log. `flutter analyze`: 28 issues, the baseline.

### Known pitfalls checked

1 (no awaits on inbound): not touched; no new await anywhere on the inbound path. 2 (encrypt at the last queue): not touched. 3 (no timers/polling): none added. 4 (no lease held): not touched. 5 (limiter refusal is not a route failure): this is the fix, extended to a server's own slow-down. 6 and 12 (state cleared, bounded): no new state. 7 (hold expiry): none. 8 (a store is not delivery): the store rule is unchanged; only its log is quieter. 9, 10, 11: not touched. 13 (vault bytes): none. 14 (capability): no wire change. 15 (rank by receipts): a slow-down no longer demotes a route. 16 (seal at the last queue): not touched. 17 (a failing head must not block): a slow-down on the head is now a LimiterRefused, retried without counting an attempt. 18 (migrations never delete): existing accounts and vaults unchanged; the budget change is global and more generous; `serverPicked: false` applies to own accounts set up from now on. 19 (no parsing in hot paths): the SMTP slow-down regex is static and runs on a refusal only. 20 (date bombs): the burst tests use one fake clock for everything; the controller tests use the same clock pattern as their neighbours.
Group parity: the budget and the registry rule apply to every envelope, group copies included (the burst test sends group copies as separate envelopes, as the controller does).

### Lab check needed

Transports and delivery are touched. Please run on the first green debug build:
1. matrix-normal-burst (and reverse): message p95 under 30 s; no `Rate limit: wouldWait` lines; note any 429 or `retry_after` in the logs (the first sign that the lab's homeserver or a public one limits to-device).
2. deltaChat-normal-burst: texts confirmed 180/180 and received 240 by the end of the 600 s linger; no `turn in 3xxx s` anywhere; the `Too much mail` lines, if any, must not be followed by a route marked failing (the report's routes stay `emailCarrier`). The kept accounts in `~/conest-lab/email/` have four fields; the domain rule covers delta.disobey.net and tarpit.fun. If a kept account is on a server outside `defaultChatmailDomains`, append `,chatmail` to its file. Note that a run's mails count in the server's minute and the hour: do not run two email bursts back to back.
3. Android handling p95 on a Matrix or Nostr run with the screen off and on, to tell the UI from the handlers.
4. iroh-normal-burst files (14/30 vs 15/34): not looked at (items 1 and 2 first); the share is the same, as the plan said.

### Release note (plain text)

Messages over Matrix keep up with a burst: the app now allows five sends a second per Matrix account instead of one, so a run of messages and their receipts no longer queues for a minute or more. A server that asks to slow down (Matrix, email) is waited out without marking the route as failing. Email accounts on chatmail servers are paced by the server's per-minute limit even when you entered the account yourself.

### Design questions for the maintainer (not done)

- Receipts queue behind messages in the account's FIFO. Putting them first is easy in the limiter but, with one receipt per message, they could take the whole capacity from messages under a burst; they would need their own coalescing window first. With capacity above the load the queue is short and this does not show.
- A group message to N members is N requests. One `sendToDevice` can carry several users and devices, so a group copy set could be one request (about a third fewer requests on the burst). It needs a coalescing layer in the Matrix adapter that seals at the last queue; not attempted.
- An ordinary provider's hourly quota (150) stops receipts too, for the rest of the hour. Receipts are small; consider reserving a share of the quota for them.
- A send refused with `wouldWait` is retried on the 5 s tick behind whatever queued meanwhile. An event-driven retry at `retryIn - maxWait` would remove that tail; the capacity change makes it rare.
- Android: the chat list rebuilt 5.4 times a second during the burst (`activity.rebuilds`).

### Blocked

Nothing. No separate reviewer agent was run from this session (the changes are budget numbers, error classification, a log condition and a lab flag; no parsing of network data beyond a static regex on a refusal line); the maintainer's review applies.

## Progress log

- Read PLAN_AGENTS.md and this file. Worktree clean at f389855.
- Evidence first, from `~/conest-lab/device-lab-reports/20261104T190000Z` (Matrix), `...T190411Z` (email), compared with 306 (`20261104T142055Z`) and the last pass (`20261030T190634Z`). Scripts only read the reports. Findings are in the Handoff.
- Matrix: transit and receipt delay split per message from `at`, `arrivedAt` and the confirmed trace; offered load counted (2.1 to 2.4 sends a second per device in 308, 0.28 in 306, from commit 60c27f6); no server pushback in any log; Synapse source read through raw GitHub files (devicemessage.py: only `m.room_key_request` is limited; sendtodevice.py: no limiter).
- Email: the 3441 s `wouldWait` is the 150 an hour quota of the ordinary budget; reproduced in a scratch fake-clock simulation of `NetworkLimiter` (scratch file removed; not committed). Why the ordinary budget: kept lab accounts come back through `enableOwnEmailCarrier`, which made `chatmail: false`.
- Decision: raise the Matrix budget (200 ms gap, burst 10) rather than add priority ordering or group fan-out in this round: it is the smallest change that removes the cause, the server limit is not the reason for the old number, and 429 stays obeyed exactly. The other two are in Design questions.
- Decision: the server's slow-down becomes a wait in the registry for every `ServerSlowDown` (not only SMTP), because pitfall 5 applies to all of them; Telegram and Discord already carried the interface and were failing the route on a 429 too.
- Decision: own accounts on a known chatmail server are chatmail (domain list), so the lab's existing four-field files need no edit; fifth field kept for servers outside the list.
- Tests first (red): `matrix_burst_test` (wouldWait turn in 46 s as in the lab), `server_slow_down_test` (4 red), the kept-account test (chatmail false), the quiet retry (3 errors). Then fixes (green).
- The first version of the "server at 2 a second" test passed under sabotage (its sends came in clusters 1 s apart, shorter than the 0.5 s wait). Made the fake's `retry_after` a whole 2 s minimum, like a real header; now the sabotage (no `pushedBack` on a slow-down) gives 38 early sends and goes red.
- `flutter analyze`: 28 issues (baseline). New files formatted with `dart format`; hunks in existing files formatted by hand, checked against `dart format` output on copies (one line wrapped in debug_auto_run.dart); `git diff -w` clean of formatter changes. `fmt_mine.py` not run on the two big files.
- Focused tests green: matrix_burst, server_slow_down, email_carrier, transport, the Email carrier group and the new controller tests.
- Full suite: started under the lab lock, log `~/conest-lab/g9-<epoch>.log`.
