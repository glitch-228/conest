# M37: The Bluetooth mesh on desktops (Linux and Windows)

First read `/home/glitch/Documents/conest/PLAN_AGENTS.md` in full (the shared rules); everything there applies here.

- Worktree: `/home/glitch/Documents/conest/.worktrees/agent-m37`
- Branch: `agent/m37-desktop-bluetooth`
- Size: medium to large. Mostly Rust in `native/conest_native`, plus a Dart link layer and small settings changes. Reviewer pass required: radio input is hostile input.

## What the user asked for

The Bluetooth mesh (bitchat-compatible) should work on desktops and laptops too, including with USB Bluetooth dongles, and not only on Android phones. Then a laptop can be a mesh node and relay for nearby phones.

## Background: what exists

**The mesh protocol** is pure Dart in `lib/src/bitchat/`:
- `packet.dart` (bitchat packets) and `fragment.dart` (fragmentation);
- `noise.dart` (Noise XX), `direct.dart` and `gateway.dart`;
- `mesh.dart` (`BitchatNode`: flooding with TTL, private packets).

**The Bluetooth side** is one interface, `BitchatLinkLayer` in `lib/src/bitchat/mesh.dart`:
- `received`, a stream of (link id, packet);
- `broadcast(packet, except:)` and `sendTo(link, packet)`;
- `problems`, a stream of user-facing reasons, such as Bluetooth being off;
- `linkLimits` (link → largest write);
- `close()`.

**The only implementation** is Android:
- `lib/src/bitchat/android_links.dart` (`AndroidBitchatLinks`, MethodChannel `dev.conest/bitchat` plus an EventChannel), backed by `android/app/src/main/kotlin/dev/conest/conest/BitchatBlePlugin.kt` (~800 lines).
- That plugin is the reference for link behaviour:
  - service UUID `F47B5E2D-4A9E-4C5A-9B3F-8E1D2C3A4B5C`, characteristic `A1B2C3D4-E5F6-4A5B-8C9D-0E1F2A3B4C5D` (write and notify), CCCD;
  - it acts as both central (scan and connect) and peripheral (advertise, GATT server);
  - MTU negotiation;
  - the notification byte stream, where one packet may span several notifications;
  - link ids, duplicate-connection handling, backoff and limits.
- Read it fully before designing the desktop backends.

**Wiring:** `lib/src/bitchat_carrier.dart` takes a `BitchatConnector` (a `Future<BitchatLinkLayer> Function()`). The controller picks `AndroidBitchatLinks.start`:
- `lib/src/messenger_controller.dart` ~3963: the mesh is available only when a connector is injected or the platform is Android;
- ~4021: `connector: _bitchatConnector ?? AndroidBitchatLinks.start`.

**Native code** is in `native/conest_native`, called through hand-written C FFI (`ffi.rs`, with Dart bindings such as `lib/src/iroh_ffi_bridge.dart`). Iroh's bridge polls the native side for inbound data on a timer, with worker isolates. Follow the same pattern, or use a `NativePort` if you can justify it; keep it consistent and bounded.

**Tests** for the mesh use fake link layers: see `test/bitchat_test.dart` and the "Bluetooth mesh carrier" tests in `test/messenger_controller_test.dart`.

## Scope

**1. Rust backends** (`native/conest_native/src/ble/`)
- **A common core,** platform-independent and unit-tested with a mock adapter:
  - the link table;
  - per-link write queues with limits;
  - reassembly of notification streams (one packet may span several notifications, as in the Kotlin plugin);
  - duplicate-connection rules: when two devices connect to each other both ways, keep one link, chosen deterministically, as the Kotlin plugin does;
  - backoff and the scan duty cycle;
  - event output for Dart.
- **Linux:** BlueZ through the `bluer` crate:
  - advertising the service UUID;
  - a GATT server with the characteristic (write and notify);
  - scanning as central, connecting and subscribing.
  - Needs `libdbus-1-dev` in CI: add it to `.github/workflows/rust-tests.yml` and to the Linux job in `debug.yml`.
  - Detect when the adapter or BlueZ cannot act as a peripheral (no advertising support, or permissions) and report it as a "problem" with a clear reason.
- **Windows:** WinRT through the `windows` crate:
  - `BluetoothLEAdvertisementWatcher` for scanning;
  - `GattServiceProvider` with `StartAdvertising` for the peripheral role;
  - `BluetoothLEDevice` / `GattDeviceService` for the central role.
  - Peripheral mode needs a Windows 10/11 adapter that supports it; check `BluetoothAdapter.IsPeripheralRoleSupported` and report when it is missing. Central-only mode still works for connecting to phones.
- **Builds:** gate everything with `cfg(target_os = ...)`. Android and other targets build without these dependencies, so check the `[target.'cfg(...)'.dependencies]` sections in `native/conest_native/Cargo.toml`.
- **USB dongles** work through the OS stack; nothing special is needed. Pick the default adapter, and if several exist, the first powered one. Exposing a choice is optional.

**2. FFI and Dart**
- **C FFI** in `ffi.rs`, all handle-based and bounded:
  - `conest_ble_open`, `conest_ble_poll_events`, `conest_ble_send_to`, `conest_ble_broadcast`, `conest_ble_link_limits`, `conest_ble_status`, `conest_ble_close`;
  - events as JSON or a compact binary format.
- **Dart:** `lib/src/bitchat/desktop_links.dart`, a `DesktopBitchatLinks implements BitchatLinkLayer`, with `start()` like the Android one.
- **Controller:** at ~3963 and ~4021, use `DesktopBitchatLinks.start` on Linux and Windows (`Platform.isLinux || Platform.isWindows`), and keep Android as it is. Keep this hook small.
- **Settings:** the Bluetooth mesh section in Settings → Connectivity, currently Android-only, appears on desktop too. It shows the adapter state and any "problem", such as "This Bluetooth adapter cannot advertise: nearby phones can't find this computer, but it can still connect to them."
- **Groups:** Conest groups over the mesh already work through the carrier. Make sure nothing in the desktop path breaks group fan-out (group parity).

**3. Limits**
- A maximum number of links (for example 8).
- Per-link queue bytes.
- A maximum packet size accepted from a link, before reassembly and after.
- The events buffered for Dart are bounded, dropping the oldest with a counter.
- No unbounded growth when a peer floods notifications.

## Out of scope

- macOS and iOS.
- Bluetooth Classic.
- Changing the mesh protocol.

## Tests

- **Rust (CI):**
  - the core's link table, duplicate-connection resolution, reassembly across notifications (packets split at every boundary), queue limits, flood resistance and event buffer bounds, all against a mock adapter;
  - platform code that cannot run in CI (no Bluetooth hardware) must at least compile on its target: `debug.yml` builds Linux and Windows.
- **Dart:**
  - `DesktopBitchatLinks` against a fake native event source (inject the FFI behind a small interface): events become `received`, `problems` and `linkLimits`, and send calls reach the native side;
  - the carrier on desktop uses the desktop connector (a controller test with an injected fake).
- **Sabotage checks** for each.

## Device checks to list

- A Linux laptop ↔ an Android phone running Conest: messages both ways, and a group message relayed through the laptop between two phones that are out of range of each other.
- A Windows desktop with a USB dongle ↔ a phone.
- An adapter without peripheral support shows the warning and still connects as central.
- A bitchat iOS/Android app sees the desktop node, if public announcing is on.

## Progress log

(append here)

- 2026-10-15: Read the shared rules, Android plugin and Dart packet/link/carrier implementations. Work is isolated in `agent/m37-desktop-bluetooth`. Merged current base `28f0d50` before implementation. No local native builds.
- Added a bounded Rust link core and BlueZ/WinRT backends. Decisions: use OS default/first powered adapter; use a dedicated native runtime, short bounded FFI polls and an isolate for close; retain central mode when peripheral support is absent; use fresh numeric link generations to reject callbacks from replaced connections. Bluetooth packets keep their existing wire format and Dart authentication.
- Limits: eight links including setup, 64 queued writes/16 KiB per link, 512-byte writes, 4096-byte incoming chunks/packets, per-link chunk/byte/packet rate limits, 256 events with oldest-drop counters, 32 events per poll, bounded backoff and Windows callback queues. Link snapshots accompany every poll to recover from dropped events.
- Added six CI sabotage mutations covering write bytes, duplicate resolution, stream reassembly, packet sizes, flood rate and event buffering. Rust-tests already installs libdbus; added it to the Linux debug build too. Platform compile/results pending.
- Linux native code compiled and workspace tests passed in Rust CI `38723764197`. The run stopped in the packet-size sabotage check because a second redundant size guard still protected it; corrected the mutation to remove both guards for that invariant. The first three Rust negative checks detected their mutations.
- Added the Dart FFI source, desktop links with bounded polling and paused-listener drops, OS connector selection, controller hooks and desktop adapter/warning text in Connectivity. No `lib/main.dart` change is needed: its existing panel was already gated inside the panel by `bitchatAvailable`.
- Dart bridge tests: 9 passed. All nine Dart sabotage checks passed, including disabling forwarding and observing the non-contact group test fail. The existing group parity test now sends between out-of-range phones through `DesktopBitchatLinks` backed by the native-source fake. Local analyzer baseline warnings are outside M37 code.
- The first push was rejected by automatic review as an unverified destination. Verified the configured remote against Cargo's repository URL and authenticated ADMIN ownership; the plan-authorized retry to the isolated agent branch succeeded.
- Independent reviewer found three P2 availability/correctness issues: early Windows writes before subscriber-cache refresh, early notifications before CCCD completion, and per-peer inspection errors resetting all neighbours. Fixed them and moved the callback policies into a platform-independent mock-adapter module with three regression tests and corresponding CI sabotage checks. Reviewer rechecked the direct fixes; final helper refactor re-review pending.
- Debug `38724947316` passed Bluetooth tests/sabotage and general Dart verification. Its Tor and Matrix native builds exposed two more Linux jobs needing libdbus headers. Added libdbus to those jobs, regular CI and the Linux release build dependencies too (no release workflow was run). Linux/Windows/Android builds in the first debug run are still being inspected.

## Handoff

- Branch and final commit:
- Debug run id and result; Rust tests run id:
- What changed:
- Draft release-note lines:
- Device checks:
- Review summary:
- Known gaps:
- Hooks added in lib/main.dart and lib/src/messenger_controller.dart:
