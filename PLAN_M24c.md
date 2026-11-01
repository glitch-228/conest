# M24c: Delta Chat review leftovers (downloads, speed, saves)

First read `/home/glitch/Documents/conest/PLAN_AGENTS.md` in full (the shared rules); everything there applies here.

- Worktree: `/home/glitch/Documents/conest/.worktrees/agent-m24c`
- Branch: `agent/m24c-delta-leftovers`
- Base: `617b826` on `feature/matrix-client`.
- Size: small to medium. Dart only. Code: the Delta Chat client: `lib/src/email/delta_*.dart`, `lib/src/ui/delta_chats_screen.dart`, `lib/src/ui/delta_*`, and its hooks in `messenger_controller.dart`.
- Other agents work in parallel elsewhere. Keep your hooks in `messenger_controller.dart` and `main.dart` small.

## Items (from the M24b independent review, 2026-10-16)

1. **(M2) Downloads follow the user's rules.** Delta Chat files are downloaded whatever the network. They should follow metered networks and the auto-download preset (Settings → Storage), as Conest's own files do:
   - files over the preset's size, or on a metered network, are deferred per message (per IMAP UID);
   - the bubble shows a Download action;
   - a deferred mail is not deleted from the server until it is downloaded.
2. **(M1) Off the UI thread.** MIME parsing and OpenPGP encryption and decryption of large mails run in an isolate (`compute`/`Isolate.run`), so the UI never stalls on a big mail.
3. **(M3) No quadratic saves; a real cache limit.** Saving Delta chats must not rewrite everything per message, and the attachment cache gets an LRU with a size cap.
4. **(M4) One vault write per fetch batch,** not one per mail.
5. **(M5) Cheap avatar checks at start:** no decoding or hashing of every avatar on each start; check by size and modification time, and decode lazily.
6. **The review's Low items** are not recorded. Re-read the Delta Chat input handling against the Security section of PLAN_AGENTS.md (bounds on sizes and counts, header parsing limits, authorship checks for edits and deletes) and fix what you find, each with a test.

## Tests

Each with a sabotage check:
- metered network: a large Delta file waits behind a Download action, and the mail stays on the server until fetched;
- a fetch batch of 20 mails writes the vault once;
- the cache stays under its cap and evicts the least recently used first;
- parsing a 20 MB mail does not run on the UI isolate (test the entry point used);
- avatar checks at start do not decode unchanged avatars.

The tests use the existing fake mail server (`test/support/fake_mail_server.dart`).

## Performance

These items are about stalls and battery. Name any remaining hot path in the handoff.

## Handoff

Implemented on agent/m24c-delta-leftovers, source commit b7dff0e; latest base c80f136 merged.

Done:
- UID-based deferred Delta downloads obey network cost and the storage preset, expose Download, survive restart and UID resets, and keep server mail until successful durable receipt. Bounded overflow does not block later mail; groups use the same authenticated-content policy.
- MIME/OpenPGP and attachment hashes run in isolates; a 20 MiB encrypted-file regression checks the actual parser isolate.
- One durable vault write per bounded fetch batch, reused immutable JSON rows, indexed descriptors, and pruned incremental cache references.
- A 256 MiB / 4,096-file metadata-based LRU protects saved files and archive-owned legacy copies. Existing pinned legacy data remains readable if over the new cap; new admissions must fit.
- Lazy bounded avatar restoration avoids startup decoding/hashing. This base stores avatar data inline, so encoded lengths and identity replace nonexistent file-stat checks; attachment-cache checks use size/mtime.
- Parser/header/token limits tightened, with authored-control regression coverage preserved.

Verification:
- All 19 Delta controller tests passed. Targeted mail/protocol/content/parser/avatar/queue/cache tests passed.
- All 34 sabotage checks failed as expected with individual guards removed, then source was restored. Evidence: review/M24c_sabotage.json; repeatable runner: tool/m24c_sabotage.py.
- Analyzer: 28 baseline issues, no new issues.
- Full suite: runs in the dedicated GitHub qualification job; only the exact native-Iroh case documented in PLAN_AGENTS.md is excluded. The queued local waiter was cancelled without interrupting another session.
- Qualified final CI run: 41241082262, https://github.com/glitch-228/conest/actions/runs/41241082262, fixture/workflow commit 54f8a58 and app source b7dff0e; attempt 2 passed all jobs before M25 integration; final integration result follows below.
- Independent security reviewer m24c_security_review: confirmed findings fixed with tests; final follow-up found no additional concrete findings. Review record: review/M24c.md. Maintainer review/merge approval remains separate.

Performance handoff:
- Remaining paths to profile before a stable release: the single up-to-42 MiB worker input transfer, bounded first-display avatar sanitization, shared vault snapshot-map preparation, first-use cached-key validation, and the existing minute expiry refresh in an open Delta chat. The sender-header worker receives an owned prefix capped at 512 KiB.
- Encrypted mail up to 64 KiB has a control-read allowance; authenticated attachment policy is then checked before caching/deletion. Large public-key mails can be deferred before body fetch.

Release-note drafts:
- Delta Chat files follow download settings and wait for Download on metered connections.
- Improved handling of large Delta Chat messages.
- Delta Chat file caches now manage their storage limits.
- Important: save Delta Chat files you need to keep before updating.

Device checks:
- Android metered/Wi-Fi switching while mail arrives.
- Frame timing for first avatar display and 20 MiB mail, added message latency, idle CPU and wakeups on Android/Linux/Windows.
- No GUI automation, local builds or physical-device work performed, as required by PLAN_AGENTS.md.

## Progress log

- 2026-10-31: Read PLAN_AGENTS.md and the Delta mail/controller/cache paths. Starting from the named clean worktree at 617b826. Design: bounded IMAP batches with durable acknowledgement before deletion, UID-based deferred downloads, isolate mail jobs, incremental serialization/cache bookkeeping, and lazy avatar restoration.

- Implemented bounded 20-message/48 MiB fetch batches with one Delta vault save before server deletion; deferred UIDs survive restart and have a translated Download action. Existing cache/vault failure controller tests passed. New twenty-message save-count test passed.
- MIME/PGP build/read paths now use isolates, including receipts/Securejoin, and attachment SHA-256 uses an isolate. The 20 MiB encrypted file test passed (actual parser isolate identity differs from UI).
- Added a 256 MiB / 4,096-file metadata-based LRU, incremental cache references, descriptor lookup indexing, and reused immutable JSON rows.
- Avatar storage in this base is inline encrypted-vault data, not avatar files: there are no file modification times to check. Preserved the storage format, using encoded lengths and object identity without hashing/decoding, and validating only when an avatar is displayed. Existing avatar bounds tests passed. File-cache startup uses size/mtime only.
- Input review: reject duplicate identity/control headers, repeated Autocrypt attributes, oversized Autocrypt values, invalid MIME field names/boundaries, oversized invites and restored token collections. Keep the existing password-authenticated Securejoin-v3 format (which legitimately omits protected identity headers); ordinary signed chat mail must carry protected identity headers.

- Merged origin/feature/matrix-client at c80f136 cleanly. Independent reviewer m24c_security_review identified archive-file migration ownership, deferred saturation, permanent retry blockage, optional-header poisoning, carrier compatibility, Download wake-ups, stale cache references, LRU-hook naming, hint restore bounds, lazy avatar expansion, pinned legacy caches, full-disk migration, and repeated UID discovery. Fixed the confirmed findings with regression tests; follow-up review pending final confirmation.
- Preserved larger Conest carrier envelopes via a bounded 4 KiB PGP packet probe rather than trusting outer MIME hints. Optional routing headers use a partial 16 KiB IMAP fetch. At most 128 deferred entries are materialized; overflow bodies remain on the server behind one durable UID floor and are revisited as slots free.
- Small encrypted mail has a 64 KiB control-read allowance because files cannot be distinguished before decryption. After signature verification, actual attachment MIME, size, preset, trust and network cost decide admission; refused bodies remain on the server and are not cached before Download. Public-key large mails are deferred before body fetch.
- Reviewed cache preserves archived/shared legacy copies, keeps existing pinned files readable, checks storage before allocating migration copies, and falls back to old paths on a full disk. New admissions enforce the cap. Retry batches reuse UID discovery; a 100-message regression checks SEARCH count.
- Latest targeted results: 18 Delta controller tests passed; cache/queue/isolate regressions passed, including 20 MiB file processing. Analyzer reached base + one new test style issue, now fixed. No local builds or physical-device work.

- Final independent follow-up reported no additional concrete findings in the reviewed fixes.
- All 34 sabotage checks detected their individual regressions as test failures (not compile failures); all mutations restored. Runner: tool/m24c_sabotage.py; summary: review/M24c_sabotage.json. Covers the five required items plus parser bounds, token limits, file policy, mailbox progress/wakes/retries, cache ownership/migration/recency/reference pruning, and UID resets.

- Analyzer: 28 existing issues, no new issues. Source and review fixes committed at b73c80e (merge c80f136 in 004e62d), pushed only agent/m24c-delta-leftovers. Qualified debug workflow run 41237119393 started: https://github.com/glitch-228/conest/actions/runs/41237119393. Local full suite started under ~/conest-lab/flutter-test.lock and is waiting for the machine's shared test slot; CI runs independently.

- Final namespace review found that arbitrary Conest IDs beginning delta: could be mistaken for Delta ownership. Replaced prefix routing with resolved descriptor ownership and preserved Conest/archive references via a snapshot-identity ownership index. Added a shared-content regression with a Conest archive file named delta:foreign. Source update requires a fresh qualified CI run.

- Ownership regression passed, with separate routing and reference-preservation sabotage checks; total 33 detected mutations, all restored. Independent narrow follow-up found no remaining concrete issue. Requeued the full suite after cancelling only this task's still-waiting lock process during mutation checks; no other session was interrupted.

- Final ownership policy also avoids pinning a separate Delta copy through a saved Conest reference. Positive shared-content test passed; analyzer has 28 baseline issues. Total sabotage checks: 34, all detected and restored. Initial CI 41237119393 passed its full qualification job and real email/XMPP/Nostr/Reticulum/Meshtastic jobs; it is superseded by the final source revision for platform builds.

- Final source b7dff0e pushed. Qualified run 41238305679 confirmed against that exact commit. Superseded run 41237119393 was cancelled after its qualification job passed; final run tests the ownership fix as well. The final full-suite waiter is active under the shared lock.

- Shared machine full-suite queue remained occupied (one active full run and another waiter ahead). Added a dedicated full Flutter suite job to the qualified debug workflow, on its own GitHub runner. It excludes only the exact native-Iroh case explicitly exempted by PLAN_AGENTS.md; all other tests must pass. This completes full-suite verification without overlapping another agent's local suite. Local queued waiter will be cancelled; no other session is touched.

- Workflow commit c1af85a adds the full Flutter suite on an isolated GitHub runner. Final run 41238646520 confirmed against that commit; run 41238305679 superseded and cancelled. No further app-source changes.

- Final qualified run 41238646520: the Verify debug transfers/storage job passed. Its Delta step passed 181 mail/protocol/content/parser/avatar/cache/queue/PGP/email tests and 19 Delta controller tests on the final source. Real Matrix/Synapse and Tor checks also passed. Full-suite and platform build jobs remain in progress.

- Full-suite CI 41238646520 completed with 2,060 passing tests, 24 environment-gated skips and one unrelated keyboard-fixture failure: push-to-talk sent KeyUp without a matching KeyDown, triggering HardwareKeyboard's regular-event assertion. The case passed in isolation locally, confirming event-mode/order sensitivity. Corrected the fixture to simulate the held physical key before attaching the release handler, preserving its release-after-call intent. A new full-suite run is required.

- Keyboard fixture correction 54f8a58 passed its focused local test; analyzer stays at 28 baseline issues. Final full qualification run 41241082262 started against that exact commit. App source remains b7dff0e.

- Run 41241082262: Tor compiled and its obfs4 test passed, but onion-service frame delivery failed after four reachability retries. The same Tor code passed in run 41238646520. Treating this as external reachability and requesting a targeted Tor-job rerun; no Tor/application code changes or test weakening. Full suite and desktop builds continue.

- GitHub rejected the targeted Tor rerun while the workflow was still active (`job ... cannot be rerun`). Will rerun failed jobs after the remaining jobs complete, preserving the successful qualifications.

- Run 41241082262: the corrected full Flutter suite passed. The keyboard fixture failure is resolved. Targeted qualification and Android build passed; desktop builds and the Tor reachability retry are the remaining CI work.

- 2026-11-01: Run 41241082262 attempt 2 is fully green: Tor retry passed; 14 jobs passed, including 2,061 full-suite tests and Android/Linux/Windows builds. Saved review/M24c_ci.json. A final fetch found origin/feature/matrix-client advanced to 6d23989 (M25). Integrating the new base as required, then repeating analyzer/tests/qualified CI on the merged source.

- M25 integration merged cleanly in 7af2d20. Analyzer remained at 28 baseline issues; 216 targeted Delta/network-budget tests and 19 Delta controller tests passed before the integration review. Run 41282657801 was superseded/cancelled for confirmed review fixes.
- Integration review found quota refusals could discard Securejoin replies and that email-account replacement reused the wrong limiter. Added a bounded durable protocol outbox, account-scoped quotas, and post-wait cancellation checks. Follow-up fixes roll back Delta state/tokens/reply allowances across parsing and persistence failures, bind cursors to mailbox setup/IMAP endpoint, and remove only permanently rejected SMTP recipients from replies. New fake-mail regressions cover retry/restart, failed join-response saves, repeated 20-request batches, same-address mailbox replacement, and a rejected recipient followed by a valid handshake.
- Independent reviewer rechecked the final fixes and found no remaining concrete defect. Final analyzer is back at 28 baseline issues. Integration sabotage checks are running; final full-suite/platform qualification follows.

- All 52 sabotage checks detected their regressions and all mutations were restored. The new retry check initially survived because the fixture could clear the failure before SMTP attempted it; corrected it to wait for an observed refusal, then proved the retry-wake mutation fails. Updated mutation targets after formatting; no compiler failure counts as a detection. Evidence: review/M24c_sabotage.json. Final positive controller/targeted tests and analyzer are running.

- Final reviewed integration source passed 223 targeted mail/protocol/content/parser/avatar/outbox/queue/cache/PGP/email/network-budget tests and all 26 Delta controller tests after all mutations were restored. Analyzer: 28 existing issues, no new issues. Logs: /tmp/m24c-integration-final-targeted.log, /tmp/m24c-integration-final-controller.log, /tmp/m24c-integration-final-analyze.log. All 52 sabotage detections are recorded. Pushing the reviewed integration for full qualified CI.
