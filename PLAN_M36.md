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

## Handoff

- Branch and final commit:
- Debug run id and result; Rust tests run id:
- Phases completed (A–F), and the Phase F decision:
- What changed (wire formats, capability, settings):
- Draft release-note lines:
- Device checks:
- Review summary:
- Known gaps:
- Hooks added in lib/main.dart and lib/src/messenger_controller.dart:
