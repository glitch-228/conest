# M36: MatrixRTC feasibility and Conest fallback design

Research checkpoint: 2026-10-13. Phase F stops at this design note. No LiveKit dependency, Matrix call button, automatic migration, vote, or dual-path option has been shipped by M36. The Conest group-call implementation is independent of Matrix.

## Recommendation and blocking facts

Build a separate, CI-only, voice-only LiveKit prototype before enabling MatrixRTC in Conest. Its acceptance gate is less than approximately 25 MB **additional shipped binary size on each supported platform**, working encrypted audio with Element, and shared microphone ownership with existing calls. That gate has not been demonstrated. The archive measurements below are download/build costs, not measurements of final binary growth.

Local inspection found Matrix messaging, verification and sync in `native/conest_native/src/matrix.rs` / `lib/src/matrix_native.dart`, but no native MatrixRTC media engine or call API. `GroupRecord` has no linked Matrix-room concept. Joining Matrix calls requires new signalling, encrypted to-device key APIs, a LiveKit/audio adapter and platform lifecycle integration; changing the existing Matrix carrier alone cannot supply these. Therefore the linked-group bridge is skipped under the explicit condition in PLAN_M36, and Matrix call support is deferred for the maintainer's decision.

## Membership and discovery: deployed formats versus current drafts

Do not implement only the milestone's `m.call.member` description. Deployed Element compatibility uses legacy session membership, including unstable `org.matrix.msc3401.call.member`, device/call IDs, expiry and preferred foci. Current MSC4143 instead describes `m.rtc.slot` state plus `m.rtc.member` sticky membership events with a fresh random member ID on every join. A compatibility adapter must track each event family independently and negotiate the format supported by the homeserver and other clients. [MSC4143 draft](https://github.com/matrix-org/matrix-spec-proposals/blob/toger5/matrixRTC/proposals/4143-matrix-rtc.md), [SDK membership compatibility](https://github.com/matrix-org/matrix-js-sdk/blob/develop/src/matrixrtc/CallMembership.ts).

The deployed discovery field in `/.well-known/matrix/client` is `org.matrix.msc4143.rtc_foci`, containing `type: livekit` and `livekit_service_url`. Current Element also documents the authenticated unstable `/rtc/transports` endpoint. Its legacy backend selection uses the initiating member's preferred focus. Handle endpoint discovery first and the well-known compatibility fallback explicitly; absence means calls are unavailable. [Element Call transport discovery](https://github.com/element-hq/element-call/blob/main/README.md), [authorization-service well-known configuration](https://github.com/element-hq/lk-jwt-service/blob/main/README.md).

Current MSC4195 has a newer multi-SFU design: members publish on their homeserver's transport and subscribe on other publishers' transports. It describes `m.livekit`, `transports.published` membership, and homeserver `/rtc/livekit/get_token` APIs with room-membership authorization. This differs from the deployed single-focus/OpenID flow; pin the interoperability target and fixtures rather than treating these drafts as one stable wire format. [MSC4195 draft](https://github.com/hughns/matrix-spec-proposals/blob/hughns/matrixrtc-livekit/proposals/4195-matrixrtc-livekit.md).

## Authorization and media encryption

In the deployed flow, obtain a Matrix OpenID token for the signed-in account, submit it to the discovered MatrixRTC authorization service, and receive the SFU WebSocket URL and short-lived LiveKit JWT. The client must never contain a LiveKit server signing secret. `lk-jwt-service` exposes legacy `/sfu/get`, newer `/get_token`, and optional delayed-leave delegation; deployment modes differ in room-membership checks. [Service API and deployment modes](https://github.com/element-hq/lk-jwt-service/blob/main/README.md).

JWT authorization is separate from media E2EE. Element uses sender media keys associated with Matrix user, device and call membership. Current JS code creates a to-device transport which calls `encryptAndSendToDevice` for the call-key event, rejects keys received in clear, and checks the room ID. The event name is `io.element.call.encryption_keys`; legacy clients have also used encrypted room events. Interop must cover both key transports and match actual Element key indexes, membership identities, rotation and frame encryption. Fail closed when device ownership or encrypted key delivery cannot be established. [Current key transport](https://github.com/matrix-org/matrix-js-sdk/blob/develop/src/matrixrtc/ToDeviceKeyTransport.ts), [RTC session encryption setup](https://github.com/matrix-org/matrix-js-sdk/blob/develop/src/matrixrtc/MatrixRTCSession.ts), [event identifier](https://github.com/matrix-org/matrix-js-sdk/blob/develop/src/@types/event.ts).

Restrict discovered authorization URLs to trusted HTTPS endpoints, validate certificates, bound HTTP responses, and prevent token-bearing redirects to a different origin. Never send a Matrix bearer/OpenID token to an arbitrary focus supplied by a room member. Keep OpenID tokens, JWTs and media keys out of logs and persisted call summaries. The future adapter must verify current Matrix-room participation and the sender device, independently of a claimed Conest identity.

## Rust client and CI cost

`livekit` is the Rust real-time client; `livekit-api` alone provides server APIs/token generation and cannot receive audio. Rust SDK media goes through `libwebrtc` C++ and `webrtc-sys`. Adding Rust LiveKit does not reuse the existing Iroh/Opus transport as a WebRTC client. [SDK crates and platform support](https://github.com/livekit/rust-sdks/blob/main/README.md), [C++ wrapper/link build](https://github.com/livekit/rust-sdks/blob/main/webrtc-sys/build.rs).

The upstream build helper currently selects the prebuilt tag `webrtc-89d790b`, caches platform archives, and supports a custom libwebrtc directory via `LK_CUSTOM_WEBRTC`. It defaults to release libwebrtc even for a Rust debug build. GitHub release metadata was queried on 2026-10-13, without downloading or compiling these binaries:

| Target | Prebuilt compressed download | Additional CI integration | Shipped size increase / added build time |
| --- | ---: | --- | --- |
| Android arm64 | 161,607,117 bytes (161.6 MB) | NDK C++ toolchain, retained WebRTC JNI symbols, native-library packaging and audio ownership | Not measured |
| Android x86_64 | 163,312,888 bytes (163.3 MB) | Separate ABI archive/cache and emulator qualification | Not measured |
| Linux x86_64 | 156,139,058 bytes (156.1 MB) | C++ wrappers, GLib/JPEG dependencies and compatible Clang/libc++ | Not measured |
| Windows x86_64 | 114,396,365 bytes (114.4 MB) | MSVC-compatible C++ linkage, libwebrtc archive/cache and Windows audio teardown | Not measured |

Sources: [prebuilt selection, cache and Android JNI handling](https://github.com/livekit/rust-sdks/blob/main/webrtc-sys/build/src/lib.rs), [release assets and sizes](https://api.github.com/repos/livekit/rust-sdks/releases/tags/webrtc-89d790b).

Upstream's current Linux instructions require Clang 21 or newer for the packaged hermetic libc++, beyond Ubuntu 24's default Clang 18. A custom libwebrtc build introduces GN/Ninja/depot_tools and platform-specific toolchains; selecting voice-only tracks does not itself establish a voice-only binary. Prefer pinned prebuilt artifacts for the first prototype and separately measure whether a custom build is necessary. [Linux build requirements](https://github.com/livekit/rust-sdks/blob/main/README.md), [Windows libwebrtc build script](https://github.com/livekit/rust-sdks/blob/main/webrtc-sys/libwebrtc/build_windows.cmd).

CI should build baseline and prototype from the same source revision/profile/toolchains and record stripped `.so`/`.dll` size differences, APK ABI contents/compressed download size, cold/warm build time and cache space. Reject the prototype if **any** target exceeds the milestone's approximately 25 MB growth budget. The measured 114–163 MB archives do not prove that threshold will fail; final linking/stripping and JNI symbol retention need measurement. No local Rust, Gradle or Flutter application builds were performed for this research.

## Future combined-call design

This is a proposal, not an implemented setting or protocol:

1. Add an explicit signed link between a Conest group and a Matrix room, plus per-device consent linking the Conest installation key to a verified Matrix user/device key. Require both memberships. Keep Conest call keys and Matrix media keys independent; avoid a trusted audio bridge that decrypts for other members.
2. One audio owner captures and suppresses noise once, then feeds the Conest Opus and LiveKit adapters. Both receive paths map to the same authenticated speaker. A bounded arbiter chooses one playout source using RTT/loss/jitter and deduplicates overlap; it never mixes two copies of the same speaker. Mute, PTT release and leave gate both transmit paths immediately.
3. Configure automatic fallback after poor Conest links persist for an initial N=5 seconds, with healthy return held longer (initially 15 seconds) to avoid oscillation. Before moving, require verified Matrix readiness for all affected members. Use a bounded transition ID tied to call ID, authority term and roster version; missing Matrix capability or authorization keeps the Conest path running.
4. A participant may propose a transition. One authenticated vote per current admitted device, majority within 10 seconds, fixed roster/version, bounded proposal rate, and no quorum reuse after membership changes. Show the destination and authorization state before applying a result.
5. “Both at once” is an optional preference. Default eligibility requires **known unmetered network and known mains power**; unknown, metered or battery state disables simultaneous sending. Wire the actual M25 policy provider here. The M36 desktop election heuristic is insufficient evidence for this power/network permission.
6. Warm the replacement path and overlap briefly before retiring the old one. If either path fails, retain the working path; if device trust or membership fails, stop that path and wipe its keys. Keep a single microphone lease across service replacements and app background/foreground transitions.

Qualification must include native CI on Android/Linux/Windows, encrypted mixed calls with Element Web and Element X, legacy/current discovery fixtures, removed-device keys, expired/replayed votes, an SFU outage, asymmetric Iroh recovery, duplicate-stream playout, PTT while either network send hangs, and metered/battery/unknown-policy changes. These are outstanding Phase F requirements for a later milestone.
