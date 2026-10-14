# M36: Group voice calls and noise suppression

First read `/home/glitch/Documents/conest/PLAN_AGENTS.md` in full (the shared rules); everything there applies here.

- Worktree: `/home/glitch/Documents/conest/.worktrees/agent-m36`
- Branch: `agent/m36-group-calls`
- Size: large. Dart (call protocol, UI) and Rust (audio). Security-relevant (call keys, media encryption), so a reviewer pass is required.

## What the user asked for

Discord-style group voice calls, with no server, and noise suppression "similar to Discord". The user's decisions, which you must not change:
- **Topology:** a mesh (everyone sends to everyone) for small calls, up to about 5 people. Above that, or when links are poor, one elected member forwards everyone's frames (a forwarder).
- **Other networks:** Matrix calls, and calls on other supported networks, should work too. If the mesh is unstable, the call can switch to Matrix and back during the call, automatically or by a vote of the participants. Where possible, both run at once and cover for each other when one drops. This is configurable, and by default only on unmetered networks and mains power.
- **Later:** high-tier Conest relays act as forwarders (M28, not this milestone).

## Background: what exists

**1:1 voice calls** (experimental, behind `CONEST_EXPERIMENTAL_VOICE_CALLS`):
- **Signalling:** `lib/src/voice_call_service.dart`.
  - `VoiceCallSignal` (actions invite, accept, busy and so on) goes over normal encrypted envelopes, kind `voice_call_signal`.
  - `VoiceCallService` is the state machine; `VoiceCallMediaEngine` is the audio interface.
- **In the controller** (`lib/src/messenger_controller.dart`):
  - `_sendVoiceCallSignal` (~1400) and `_handleVoiceCallSignal` (~17368);
  - `_sendVoiceCallAudioFrame` (~1450): ChaCha20-Poly1305 per frame, an 8-byte random nonce prefix plus a sequence number, at most 3 frames in flight, frames of at most 1100 bytes;
  - `_handleVoiceCallDatagram` (~1626), with replay windows (`_VoiceMediaReplayWindow`).
  - Media goes over Iroh datagrams (`IrohCallMediaAdapter`, `IrohMediaDatagram`), and only to a contact with a pinned Iroh identity.
- **Audio** (`native/conest_native/src/audio.rs`, ~1000 lines; FFI in `ffi.rs`; Dart in `lib/src/voice_audio_ffi.dart`):
  - Opus at 48 kHz mono, an adaptive jitter buffer, and WebRTC AEC3 echo cancellation through the `sonora` crate (desktop).
  - **Desktop** uses cpal.
  - **Android** captures and plays in `android/app/src/main/kotlin/dev/conest/conest/VoiceCallAudioEngine.kt` (AudioRecord/AudioTrack), handing PCM to the Rust Opus workers through JNI.
- There is no noise suppression, and the audio path handles exactly one remote stream.

**Groups:**
- Conest groups fan each message out to every member over that member's pairwise encrypted session. Members can include people who are not your contacts ("group-only members").
- Code to read:
  - `lib/src/group_*.dart`;
  - the group sections of the controller (search `group_message`, `GroupRecord`, `_publishGroupFile`);
  - the Iroh group tests in `test/messenger_controller_test.dart` (search "Iroh group-only"), which show how group-only members are reached.

**Matrix:**
- `lib/src/matrix_native.dart` and `native/conest_native/src/matrix.rs` (matrix-sdk 0.19);
- the Matrix room UI in `lib/src/ui/matrix_*`;
- notes in `/home/glitch/Documents/conest/notes/MATRIX-CLIENT.md`.

## Scope, in order

Commit and push after each phase, with the tests green.

**Phase A: noise suppression for every call** (1:1 and group)
- **Desktop:** if `sonora` exposes WebRTC's noise suppressor, enable it in the same processing chain as AEC3. Otherwise add `nnnoiseless` (pure-Rust RNNoise) after echo cancellation.
- **Android:**
  - attach the platform `NoiseSuppressor` and `AcousticEchoCanceler` to the AudioRecord session where `isAvailable()`;
  - also run the Rust suppressor when the platform one is missing.
- **Setting:** "Noise suppression", on by default, with a toggle in the call screen that applies immediately. Stored as a new optional setting.
- **Rust test:** a synthetic noise-only input is reduced by at least about 10 dB, and a synthetic voiced signal keeps most of its energy.

**Phase B: native audio for several remote streams**
- In `audio.rs` (with JNI and FFI parity for Android and desktop):
  - one decoder and one jitter buffer per remote participant (participant index → stream);
  - a mixer with clipping protection;
  - per-participant level readings for "speaking" indicators;
  - a cap on remote streams (for example 16).
- The single-stream 1:1 path must behave exactly as before.
- **Rust tests:** mixing and clamping; participants joining and leaving mid-stream; a late or lost frame in one stream does not stall the others.

**Phase C: the group call protocol** (new files under `lib/src/group_call/`)
- **Signals,** sent as group control messages through the existing group fan-out:
  - `start`, `join`, `leave` and `roster` (the participant list with versions);
  - `key` (sent to each participant over their pairwise session, never to the group as a whole);
  - `topology` (mesh or forwarder, and who forwards);
  - `stats` (RTT, loss, power and metered flags, used for the election).
- **Accept a signal only** from an authenticated current member of that group, for the current call id, within rate limits.
- **Call key:**
  - random per call;
  - rotated, with a new epoch, whenever someone joins or leaves, so a member who left cannot decrypt new audio, and a new joiner cannot decrypt old audio;
  - per-sender frame keys derived with HKDF from (call key, epoch, sender device id).
- **Frames:**
  - an authenticated header: call tag, epoch, sender index, sequence;
  - then ChaCha20-Poly1305 ciphertext;
  - a replay window per sender;
  - frames from a stale epoch are dropped after a short grace period;
  - bounded sizes and rates.
- **Capability** `groupVoiceCallsV1`. Members without it are shown as "can't join (update needed)".

**Phase D: topology**
- **Mesh** for up to 5 participants (a configurable constant): each sends its frames to every other participant over Iroh datagrams.
- **Forwarder:**
  - **When:** more than 5 participants, or when the mesh links are poor (loss or RTT thresholds held for a few seconds).
  - **Election:** a deterministic choice from the shared `stats`, so every participant agrees without a vote round. Prefer desktop over phone, mains over battery, unmetered over metered, then lower RTT and loss; break ties by device id.
  - **What it does:** forwards each sender's ciphertext frames unchanged to the others. It needs no extra key; frames stay end-to-end encrypted between the speakers and the listeners.
  - **Re-election:** when the forwarder leaves, goes silent for more than about 1.5 s, or degrades. Switch with no gap in audio where possible: send to both the old and the new forwarder for a short overlap.
- **Unreachable members:** a member reachable only through a non-Iroh route cannot send media directly. Show them "can't reach (no direct route)" rather than failing silently, unless a forwarder can reach them.
- **Policy input:** M25 (EnergyPolicy and route stats) is being written on another branch.
  - Define a small interface (`GroupCallLinkPolicy`: power, metered, measured link quality) with a simple default implementation.
  - For the default, use what exists today: desktop versus mobile, and the call's own ping stats.
  - The maintainer will wire M25 into it later.

**Phase E: UI** (new file `lib/src/ui/group_call_screen.dart`; small hooks in `lib/main.dart`)
- A call button in the group chat header.
- An incoming-call banner and notification: "Alice started a call in <group>". Reuse the 1:1 incoming-call notification path where possible.
- The call screen:
  - participants with speaking indicators and connection quality;
  - mute;
  - push-to-talk (an option; a hold-to-talk button, and on desktop a key);
  - the noise suppression toggle;
  - leave.
- Joining a call that is already running.
- A call summary message in the group chat (started by, duration, participants), like 1:1 call summaries.

**Phase F: Matrix calls, and Conest + Matrix together** (research first, then build if feasible)
- **Research:** write `notes/GROUP-CALLS-MATRIX.md` in your worktree. Note that `notes/` is gitignored, so commit it with `git add -f`, or put it under `docs/`. Cover:
  - MatrixRTC (MSC4143, MSC4195): the `m.call.member` state events;
  - focus discovery (`org.matrix.msc4143.rtc_foci` in `.well-known/matrix/client`);
  - the LiveKit JWT service (from a Matrix OpenID token);
  - Element Call's E2EE key exchange (`io.element.call.encryption_keys` to-device or room events);
  - LiveKit client options in Rust (`livekit` / rust-sdks, which bundles libwebrtc), with their binary size and build cost for Android, Linux and Windows in CI;
  - a recommendation.
- **Build only if it is feasible within this milestone** (Rust builds in CI only; a binary size increase under about 25 MB per platform):
  - join a Matrix room's call from Conest's Matrix room screen;
  - for a Conest group that has a linked Matrix room (if that concept exists; otherwise skip), switching between the Conest call and the Matrix call during the call:
    - automatically, when the mesh is unstable for more than N seconds;
    - or by a vote: any participant proposes, a majority accepts within 10 s;
  - "both at once" (a setting, by default only on unmetered networks and mains power): send on both paths and play the better stream per participant.
- **If it is not feasible,** stop at the design note, and put the blocking facts in the handoff. The maintainer will decide.

## Out of scope

- Video.
- Screen sharing.
- Conest relays as forwarders (M28).
- Telegram and Discord calls (M30, M31).

## Tests

- **Fake call network** (`test/support/fake_call_network.dart`): N participants with a fake datagram network (latency, loss, drops) and a fake media engine.
- **Calls:**
  - a 3-person mesh call: everyone hears everyone (frames decrypted and attributed to the right sender);
  - a 7-person call elects one forwarder, and all participants agree on which one;
  - the forwarder drops: a new one takes over within about 2 s, with no permanent loss;
  - a mesh with bad links switches to a forwarder.
- **Keys:**
  - when someone leaves, the key rotates, and that member cannot decrypt frames sent afterwards;
  - a new joiner cannot decrypt frames from before they joined.
- **Refused or dropped:**
  - signals from a non-member, from a removed member, or for the wrong call;
  - replayed frames;
  - frames from a stale epoch after the grace period;
  - oversized and over-rate frames.
- **Group-only member:** a member who is not a contact can join (group parity).
- **1:1 calls** behave as before (the existing tests stay green).
- **Noise suppression:** the Rust test above, plus a Dart test that the toggle reaches the engine.

## Device checks to list

- Calls with 3, 6 and 10 participants across Android, Linux and Windows.
- A forwarder leaving mid-call.
- Noise suppression with a fan or keyboard noise, on and off.
- Push-to-talk.
- If Phase F was built: a mixed Matrix room call with Element.

## Progress log

- Started from 3929653 in the assigned clean worktree. Shared rules read in full.
- Phase A: use Sonora 0.2's existing WebRTC noise suppressor (High, ~18 dB target) in the AEC3 chain; no RNNoise dependency is needed. Move Sonora to the common Android/desktop dependency section for the Android software fallback. Optional persisted setting defaults on. Android attaches NS/AEC to the AudioRecord session and reports the active NS effect to Rust; each capture checks the toggle.
- Sandbox network denial caused the initial GitHub authentication failure. Authentication works with the authorized network escalation. SDK cache access also requires escalation. No local Rust/Gradle/app builds.
- Phase A Dart checks: 37 existing/new tests pass; analysis has only the 25 pre-existing diagnostics. Sabotage: removed the preference application after media open; the new test failed (empty engine calls instead of [false]); restored it. Cargo metadata resolved without compiling.

- Phase A full Flutter suite: 909 passed, 18 skipped, only the explicitly documented native-Iroh local failure. New diagnostics: none.

- Phase A Rust CI 38448979012 is green, including synthetic noise attenuation (>10 dB) and voiced-energy preservation. Cross-platform debug build 38449547803 is running.
- Phase B: separate Opus decoder, jitter buffer, bounded PCM and level per participant (16 max), with final-sum clamping and independent playout. Legacy stream-zero FFI remains. Android and desktop use the same FFI receive/mixer API and Android JNI renders the mixed PCM. Tests cover clipping, join/leave, and a gap/flood in one stream while another plays. CI-only negative checks disable NS, clamping, and leave cleanup and require behavioral test failures (never compile errors).
- Protocol decision for Phase C: add Ed25519 sender signatures to the required call-key/HKDF/ChaCha scheme. A shared call key alone cannot authenticate a speaker against a malicious participating forwarder. Header + tag + signature still fits Iroh's 1200-byte bound; group Opus payload is capped at 1096 bytes to reserve its audio-sequence field.

- Phase B Rust CI 38450195864 is green: workspace tests 80 passed, 2 ignored; all three Rust sabotage checks passed. No local native builds.
- Phase C: new group_call modules and a controller part keep the two shared files to hooks. Append-only groupVoiceCallsV1; group_call_signal is an authenticated group control and ratcheted envelope kind. Call keys require protocol v3 with an established pairwise session and are never queued persistently. Roster/epoch authority starts with the initiator and moves deterministically on leave. Frame format: marker 0x36, 8-byte call tag, u32 epoch, u8 sender index, u32 sequence, ChaCha ciphertext + MAC, Ed25519 signature. At most 1200 bytes, replay bitmap per sender, 250 ms old-key grace, 100 frames/s per sender, 32 decrypt jobs and 3 sends in flight.
- Phase C tests: 46 protocol/1:1 regressions green, strengthened key tests cover an attacker deriving with public epoch/roster metadata, and leave/rejoin works. Actual controller/Iroh test proves group-only Bob and Carol receive ratcheted call keys and attributable audio without becoming contacts. Found and fixed an existing synthetic-group-contact omission of application capabilities/version.
- Phase C sabotage: bypassed sender signature verification, replay checks, old-epoch expiry, rates, membership authorization; reused call keys across admissions; removed group-only capability propagation. Every corresponding behavioral test failed, then code was restored (tool/m36_dart_sabotage.py). Analysis has no new errors/warnings.

- Phase D: deterministic elections from coordinator-published stats snapshots, verified by recomputation; desktop/mains/unmetered/RTT/loss/id preferences, degraded candidates excluded if healthy alternatives exist. Mesh limit is injectable (default 5); poor links must persist 3 seconds. Ciphertext forwarding is unchanged, retains signatures and replay protection, and overlap sends use old/new forwarders for 600 ms. A silent forwarder/leader is removed after 1.5 seconds and remaining participants elect a new leader and rotate keys. Ping/pong frames measure call-path RTT; audio sequence gaps estimate loss. M25 can replace GroupCallLinkPolicy.
- Phase D bounds: coalesced ticks and at most 32 pending control jobs, coordinator burst budget 48/s (allows 16-member roster/key fan-out), 12/s other controls, at most 3 real datagram jobs per destination and 16 destinations. Failed/hung sends keep their slots until native completion; no timeout releases an unlimited backlog. Roster replacements prune per-peer stats/replay-related state; historical participant ids capped at 128.
- Phase D tests: 7 participants agree and everyone hears every sender; forwarding preserves ciphertext/signature; a dropped forwarder/leader recovers within 2 seconds and audio stays working; 3-second poor mesh switches; RTT responds to latency/loss; deterministic preference/tie tests. All 15 protocol/topology tests green. Sabotage removes each forwarding/election/takeover/poor-link behavior and the matching test fails (12 total Dart negative checks, all pass).
- Initial debug run 38449547803: Android, Linux and all live-carrier jobs green; Windows still running at this checkpoint.

- Independent reviewer m36_security_review started on 3929653...556916c. Confirmed findings being fixed before final handoff: P1 reverse-direction microphone teardown race; P1 one-sided coordinator outage never reconciles; P1 serialized slow controls delay mute/PTT/leave; P1 empty group ticks publish Android idle during 1:1; P2 cross-group bare-call-id tombstone collision; P2 lost leave + rejoin resets audio counters without resetting retained native jitter. Regression tests and final re-review pending.

- Phase A debug CI 38449547803 completed green on Android/Linux/Windows and all real-carrier qualifications.
- Phase E: group header buttons in both layouts, incoming/return banner, shared notification path, participant levels/quality/update/no-route status, mute, pointer/Space push-to-talk, immediate saved NS, Leave, and chronological persisted call summaries. Widget tests cover pointer cancel/key release/disposal, Leave, levels/routes, noise and summaries.
- Independent review confirmed 13 lifecycle/protocol findings in two passes. Fixed immediate privacy gates and post-encryption checks, bounded real-completion control dispatch, term/domain binding and deterministic partition reconciliation, authenticated discovery beacons, observer expiry without local authority, atomic key validation, original-starter rejoin, group-scoped tombstones, admission generations/audio counters, late 1:1 ownership, aggregate group teardown across replacements, Android owner foreground state, and post-decrypt admission checks. Added controlled negative network/sign/verify/close tests; 14 recovery, 3 ownership and controller integration tests pass.
- Phase E sabotage: 18 initial review/UI mutations each produced a behavioral failure and were restored; the receive-race check also passed (19 review/UI negative checks total). No compiler failure counts as proof.


- Phase E checkpoint: 73 focused new/existing call tests pass; all 12 protocol/topology and 19 recovery/UI sabotage checks pass. Analysis has the same 25 pre-existing diagnostics, no new issues. Separate reviewer confirmed all 13 findings resolved and no new confirmed findings in restored E source. Qualified debug workflow now runs the group, ownership, UI and actual controller regressions.

- Phase F research complete: notes/GROUP-CALLS-MATRIX.md documents legacy/current MatrixRTC, focus discovery, OpenID/JWT authorization, encrypted media-key transport and a future migration/vote/dual-path design. Upstream prebuilt libwebrtc archives are 114–163 MB compressed; this is build/download cost, not final binary growth. The <25 MB shipped-size gate is unmeasured; MatrixRTC media/to-device APIs and linked-group room mapping are absent. Stop at the design note as explicitly permitted; no Matrix-call UI or transport settings are advertised.

- Oct 14 continuation: a partial full-suite run exposed group-only startup failure under load. Reproduced a pending admission being terminally closed by the 1.5 s liveness timeout before its first key. Initial admission now retries while awaiting an authenticated roster. Also reproduced initial-tag preparation throwing on early microphone frames; cipher drops them until ready. Both regressions failed on old code and with the guards sabotaged, then passed after restoration. Full-suite checkpoint: 979 passed, 18 skipped, only the documented local native-Iroh failure; logs persist under ignored .buildlog/ so they survive interruption.
- Oct 14 reviewer caught an over-broad first fix: an admitted member awaiting a rotated key still needs to replace a silent coordinator. Liveness authority now depends on local membership in the authenticated roster, independently of media/key readiness. The new dropped-key/coordinator-outage regression failed with the connected-only guard, and passes with admission-based authority; media privacy gates remain unchanged. Three startup/key-recovery sabotage checks pass and restore cleanly (22 recovery/UI negative checks total).
- Oct 14 restored focused validation: 76 group, recovery, crypto, ownership, widget, NS, feature-model and existing 1:1 sound tests pass.
- Merged latest base 8347c27 (user modes, call list, translations) without conflicts as 28bbc65. Separate reviewer confirmed the previous privacy/ownership review still applies and the UI/persisted-field hooks remain intact. Analysis: 26 inherited diagnostics, no new M36 issues. Full merged run: 994 passed, 18 skipped, native-Iroh exception plus an intermittent group-only key-startup failure; qualification paused for that failure.
- Group-only startup reproduced once in 10 isolated runs. Reviewer identified a P1 in the existing ratchet cache: unlocked status/bulk-key reads can finish after a durable write and overwrite its newer send state. Three controlled-store regressions reproduced actual send-counter reuse (expected 1, received 0), covering hasSession, confirmedAt and receivedBulkKey. All three reads now share the existing per-peer lock with writes; no private peer operation re-enters them. Restored ratchet checks: 15 passed, 1 native-only skip; write-before-send and failed-write behavior remain intact.
- Further repetitions identified a separate discovery deadline issue: the 5 s integration deadline coincided with the 5 s recovery beacon. State diagnostics showed the caller still connected and observers awaiting discovery, rather than terminal admission loss. Discovery now has a 10 s test deadline for one beacon retry; all 15 repetitions passed. Other short transport waits retain their existing deadline.
- Reviewer confirmed a P1 in existing group-only routing: pairwise ratchet bundle/hello envelopes were rejected because they are outside the group conversation. An actual-controller starter-leave regression reproduced a survivor permanently missing its new key. Narrow routing now authenticates the canonical pairwise conversation, current shared-group identity/account, recipient, pinned Iroh endpoint or carrier identity, and route policy. No private-message access is granted. Real Iroh and Nostr-control/Iroh-media handoffs both pass; former noncontacts remain noncontacts. Bootstrap input is capped at 64 KiB, 32/s and 16 actual jobs.
- Reviewer caught a P2 in an initial pre-validation draft: decrypting before deduplication could turn duplicate or cache-evicted hello copies into ratchet resets. Removed preflight decryption and use the existing seen/in-flight dispatch. Ratchet control parse errors receive generic log text. A held real disk-write duplicate plus replay after 257 real encrypted messages now passes, followed by audible startup/handoff. An additional controller test passes invalid account/conversation/pin/size checks, plaintext-log privacy, and real-write queue/rate caps. Reviewer confirmed the final restored shape resolves all findings and no confirmed new findings remain; sabotage and final validation still pending.

- Recovery review confirmed missed-roster leader history and delayed old-admission key gaps. Five deterministic regressions failed on old source. Bounded authenticated join intent history stays separate from roster/media/summary membership; keys bind the recipient nonce before any authority or cipher change; joins use monotonic issue times and reject delayed conflicting tokens. Connected members send 2 s term/version/installed-key repair joins; a healthy matching tuple sends no key and rotates nothing. Restored protocol/recovery tests: 36 passed; all six controller scenarios passed together. Independent reviewer confirmed the restored protocol fixes and current-roster-only token fallback resolve the findings with no new confirmed issues. Six new sabotage mutations passed; the complete negative suite is being rerun after strengthening the historical-leader assertion to precede any repair join.

- Restored final Dart sabotage: all 42 recovery/UI/controller/cache/admission mutations and all 12 protocol/topology mutations produced behavioural test failures, never compilation-only failures; every mutation restored. Logs: .buildlog/m36-final-recovery-sabotage.log and .buildlog/m36-final-protocol-sabotage.log. Qualified debug includes the new admission and ratchet regressions.

- Final base merge 2024a89 completed without conflicts as fdf7aca. Merged full-suite checkpoint: 1028 passed, 18 skipped, native-Iroh exception plus two single-datagram handoff assumptions and a 30 s timeout in the 257-real-write cache regression. Controller audio probes now emit finite fresh capture frames until audible, and the durable-I/O regression has an explicit 2 min timeout; deterministic protocol deadlines are unchanged. Analysis after integration: 28 inherited diagnostics (26 info, 2 warnings), no new M36 errors/warnings.
- Merge review confirmed a P1: signed account revocation removed a linked contact but stale group profiles could still authorize call keys and bootstrap. Central group-peer resolution now checks revocation before either contact/profile fallback, using the trusted device account and both contact-anchor and local account lists. An account may not ban an unrelated installation by naming its ID in a signed list. Real linked-phone tests reproduce the original failure, verify own/learned revocation, roster/key rotation, blocked key send/bootstrap/media, survivor audio, and unrelated-account isolation. All five revocation sabotage checks passed and restored (59 Dart negative checks total). Independent reviewer confirmed the fix and account scopes, no new confirmed findings.

- Restored integration checkpoint: all eight controller cases passed together in 47 s, including both revocation sources/scopes, group-only Iroh/Nostr handoff, cache eviction/duplicates, bounded bootstrap and hardware ownership. All five revocation sabotage checks passed again with the final advancing-clock fixture. Latest fetched base remains 2024a89.

- Full b43a79c run still exposed fake-media timing interference: real durable signalling I/O delayed the only control heartbeat beyond the production failure detector, while FakeCallMedia emits no regular capture heartbeat. Stopped that superseded failed run precisely (its process and descendants only). Integration now drives an injected protocol clock through the actual tick/retry path, independently of durable disk I/O; real envelopes, authentication, deduplication and rate/resource checks remain. All deterministic FakeCallNetwork timing/deadline tests are unchanged. Restored eight-controller run passed in 61 s; affected negative checks and final full-suite rerun follow. No production timing or security guards changed.

- With independent protocol time restored, all 11 affected controller-bootstrap/duplicate/privacy/resource sabotage checks passed again with behavioural failures; code restored. Integration-only clock changes preserve every production guard and all FakeCallNetwork deadlines. Final complete suite and analysis are restarting on the committed branch.

- The next full run passed every Iroh/Nostr/cache/resource controller case under load; only the two revocation fixtures still used the earlier faster clock driver and timed out in initial four-member admission. Aligned their clock cadence and retry allowance with the successful controller harness, adding bounded state-only diagnostics. Both standalone signed-revocation scenarios pass again; production code is unchanged.

- Final full Flutter suite on 6b93e00 completed: 1033 passed, 18 skipped, only the explicitly documented local native-Iroh failure. Both revocation and all four group-only controller cases passed inside the full run. Final analysis: 28 inherited diagnostics, no new M36 errors/warnings. Logs: .buildlog/m36-shared-clock-full-tests.log and .buildlog/m36-shared-clock-analysis.log. Source is restored; 59 Dart behavioural negative checks proven. Proceeding to push own branch and qualified debug/Rust CI.

- Pushed only agent/m36-group-calls, qualified head 6b93e00. Full debug workflow (quick_build defaults false): https://github.com/glitch-228/conest/actions/runs/38569923478 . Rust workspace/audio negative checks: https://github.com/glitch-228/conest/actions/runs/38569929942 . Both dispatched successfully; waiting for complete green qualification before final handoff.

- Qualified debug 38569923478: verification gate and all six real carrier jobs (Email, Nostr, Matrix/Synapse, Tor, Reticulum/RNS, Meshtastic) passed; Android/Linux/Windows builds started. Rust 38569929942: workspace tests and all three native audio sabotage checks passed; advisory Clippy still finishing.

- Final Rust run 38569929942 is green on 6b93e00, including workspace tests and all three native audio negative checks. Qualified debug verification and six carrier jobs are green; platform app/native builds are running. Verification success confirmed in job metadata; GitHub defers its full log until the debug run completes.

- Qualified debug 38569923478: Android APK job is green; Linux native Opus/jitter/ratchet checks passed and the bundle build is running; Windows native build continues. All carrier/verification/Rust jobs remain green.

- Qualified debug 38569923478: Linux bundle and native group-transport qualification are green. Android, all six carriers, verification and Rust are green; only Windows remains in progress.

- Final qualified debug 38569923478 is fully green on 6b93e0092b7ff6097b07e51e6e1b01d28f046a3f: all 11 jobs succeeded, including Windows and all three uploaded platform artifacts. Rust 38569929942 is fully green on the same source (80 passed, 2 ignored, 3 native negative checks). Handoff completed below; only this plan changes in the final documentation commit.

## Handoff

- Branch and final implementation commit: `agent/m36-group-calls`, qualified commit `6b93e0092b7ff6097b07e51e6e1b01d28f046a3f`. Latest base `2024a89` was merged as `fdf7aca`. The final handoff commit changes only this plan; the qualified application source is unchanged.
- Qualified debug: [38569923478](https://github.com/glitch-228/conest/actions/runs/38569923478), **green**, with `quick_build=false`. All 11 jobs passed: Android, Linux and Windows artifacts, verification, cadence, and all six live carriers (Email, Nostr, Matrix/Synapse, Tor, Reticulum/RNS, Meshtastic). Linux native Opus/jitter/ratchet and group-transport qualifications passed. Uploaded artifacts: `conest-debug-android-arm64-126`, `conest-debug-linux-x64-126`, `conest-debug-windows-x64-126`.
- Rust: [38569929942](https://github.com/glitch-228/conest/actions/runs/38569929942), **green** on the same commit: 80 workspace tests passed, 2 ignored, and all three audio negative checks passed. No local native/application builds were performed.
- Local validation: full Flutter suite **1033 passed, 18 skipped**, with only the explicitly documented local native-Iroh failure. All group-only, revocation, ownership, cache and resource cases passed within that full run. Analysis has 28 inherited diagnostics (26 info, 2 warnings), with no new M36 errors or warnings. All **59 Dart behavioural negative checks** passed with the source restored, plus the 3 Rust checks above. Integration fixtures advance injected protocol time independently of real encrypted disk I/O; deterministic fake-network failure deadlines remain unchanged. Logs are under ignored `.buildlog/`, including `m36-shared-clock-full-tests.log`, `m36-shared-clock-analysis.log`, `m36-ci-verification.log` and `m36-ci-rust.log`.
- Phases A–E are implemented: default-on saved noise suppression for 1:1 and group calls; Sonora High NS with AEC3 on desktop; Android platform NS/AEC plus software NS fallback; bounded independent remote decoding, jitter, PCM, mixing and levels; encrypted group mesh/forwarder calls and failover; group-only member parity; incoming notification/banner, call screen, mute, pointer/Space push-to-talk, live NS toggle, joining running calls, and persisted chronological summaries.
- Phase F is complete as research/design only, as explicitly allowed. [notes/GROUP-CALLS-MATRIX.md](notes/GROUP-CALLS-MATRIX.md) documents current/deployed MatrixRTC, discovery, OpenID/JWT, encrypted key exchange, Rust LiveKit costs, and future migration/voting/dual-path design. Blocking facts: native MatrixRTC media/to-device APIs and a linked-group room model are absent; additional shipped binary growth under 25 MB is unmeasured. The measured 114–163 MB compressed upstream archives are build/download costs, not final binary growth. Matrix media, switching, voting and simultaneous transport settings are deferred for the maintainer's decision; no corresponding UI is advertised.
- Wire/capability/settings: append-only `groupVoiceCallsV1`; authenticated bounded `group_call_signal` controls; individually addressed call keys require established v3 forward-secret pairwise sessions. Keys rotate randomly on admission/removal and bind the recipient's fresh admission nonce. Ordered joins and term/roster/installed-key repair recover missing controls without rotating healthy admissions. HKDF binds call/authority/epoch/sender; ChaCha20-Poly1305 encrypts media and Ed25519 authenticates each speaker. Frames are at most 1200 bytes: marker `0x36`, 8-byte tag, u32 epoch, u8 sender index, u32 sequence, ciphertext/MAC and sender signature; Opus is capped at 1096 bytes. Limits include 16 participants, mesh threshold 5, replay window 64, 250 ms old-key grace, 600 ms forwarder overlap, and about 1.5 s silent-leader/forwarder detection. Optional `voiceNoiseSuppressionEnabled` defaults true; persisted summaries/settings remain backward compatible.
- Review summary: independent reviewer `m36_security_review` reviewed the initial implementation and subsequent recovery, ratchet/bootstrap and base-integration changes. Every confirmed P1/P2 finding was repaired with regressions, including microphone privacy/ownership races, authority and admission recovery, atomic rejected keys, replay/jitter generations, concurrent ratchet reads, reciprocal group-only bootstrap and deduplication, bounded work and private error text. Signed local/learned account revocations now block stale group-profile fallback; unrelated signed revoked IDs cannot ban members of another account. The final restored security source had no confirmed new findings. Maintainer review/merge remains the normal next step.
- Known gaps: group calls use the existing experimental voice-call setting and require Iroh and ratchet availability. M25 still needs to supply the actual power, metering and route policy; the default uses desktop/mobile heuristics and measured call RTT/loss. Media needs an Iroh path even when another carrier carries signalling. High-tier relay forwarding remains M28. Matrix media/interoperability remains the Phase F follow-up above. Physical listening and device checks below were not performed.
- Shared-file hooks: `lib/main.dart` imports the group call screen and inserts the incoming/return banner, header actions in both layouts, chronological summary tile and live 1:1 NS toggle. `lib/src/messenger_controller.dart` adds small fields/lifecycle/media-ownership hooks, group datagram demultiplexing, authenticated group signal dispatch, reciprocal group-only Iroh/carrier ratchet bootstrap, synthetic capability propagation, generic private bootstrap error text, and revocation before group-peer fallback. Protocol/controller/UI implementations live in new group-call files. Desktop FFI and Android JNI expose matching multi-stream and NS controls.

Draft release-note lines:

- Start or join voice calls from a group chat. Small calls connect members directly; larger calls can choose a participant to forward encrypted audio.
- Mute or hold to talk with the button or Space. See who is speaking, connection quality, and a call summary in the chat.
- Noise suppression is on by default for calls and can be changed while talking.

Device checks for the maintainer:

- Calls with 3, 6 and 10 participants across Android, Linux and Windows.
- A forwarder leaving or losing its route during the call, followed by audible recovery.
- Fan/keyboard noise with suppression on/off; Android platform effect availability and software fallback.
- Pointer hold, cancellation and Space press/release; mute and leave while a send is stalled.
- Microphone ownership when moving between group and 1:1 calls, including delayed teardown and Android foreground behaviour.
- Revoking a linked phone during a call: fresh keys exclude it and survivors keep hearing one another.
- Matrix/Element interoperability belongs to the deferred Phase F prototype; no Matrix call transport was built here.
