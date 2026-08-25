# Conest

Conest is a phased secure messenger and transfer app. The repository contains:

- Flutter client for Linux, Windows, and Android.
- Signed `ci6` invites plus backward-compatible `ci5` import.
- QR-import-only and codephrase-only contact pairing.
- Encrypted local vault for identity, contacts, and message history.
- A shared transport policy/orchestration layer over encrypted LAN delivery,
  authenticated Iroh QUIC, visible Iroh relay fallback, and Conest's offline relay.
- Resumable, hash-verified attachment transfer with route-boundary migration.
- Conest Beam optical transfer for public files, contact-encrypted files, and
  contact invites.
- Invite-only trusted groups with pairwise encrypted text fanout.
- Rust workspace with the native transport/camera library, standalone relay,
  and desktop updater.

## What Is Implemented Now

- One account on one device.
- Direct text conversations and invite-only trusted groups up to 16 members.
- Signed compact `ci6` invite payloads carrying Ed25519/X25519 keys, pinned
  Iroh endpoint identity, capabilities, and bounded route hints; `ci5` remains
  accepted for migration.
- Route hints carry both route kind and protocol, currently `tcp`, `udp`, `http`, or `https`.
- Rotating pairing code derived from the payload in 120-second windows.
- Desktop-style relay behavior enabled by default through the app's local LAN node.
- X25519-derived shared secret encryption per direct conversation.
- Nearby pairing and messaging that try LAN routes first, then continue through internet relay routes when available.
- Codephrase discovery over LAN beacons, bounded nearby LAN scans, or the configured shared relay.
- Relay polling, outbound queueing, duplicate suppression, and ack-based delivery state updates.
- Global and per-contact automatic/preferred/disabled/ask-before-use transport
  policy, with the actual path shown on messages and transfers.
- Visible Iroh relay fallback with global/contact opt-outs and an optional
  persisted list of up to eight custom HTTPS relay URLs (blank uses N0).
- Persistent, verified attachment ranges, pause/cancel, restart recovery, and a
  30 MiB default store-forward relay cap. Larger files require LAN or direct
  Iroh and pause instead of silently consuming relay capacity.
- Attachment protocol v2 manifests, 128 KiB authenticated blocks, exact
  durable-byte progress, resumable private partial files, foreground Android
  transfer controls, and a content-addressed managed cache. The protocol and
  storage guards accept 1:1 attachments up to 2 GiB.
- Preparing/queued/waiting/reconnecting/verifying transfer bubbles, a global
  Transfers screen, batch/album staging and reordering, media/file presentation
  modes, priority controls, retry, keep-offline, save, and cache eviction.
- SQLite-WAL relay mailboxes with deduplication, TTL/quota enforcement, and
  lease/ack fetching so unacknowledged deliveries survive relay restarts.
- A Linux/Windows relay supervisor with signed channel-aware updates,
  maintenance-window application, identity/database continuity checks, and
  automatic rollback after a failed health gate.
- Conest Beam v1 systematic LT fountain frames with CRC32C, a signed manifest,
  final SHA-256 verification, a 64 MiB limit, and explicit acceptance for
  public/untrusted imports.
- Android camera scanning and a Linux/Windows native scanner based on Nokhwa
  and RXing, with manual frame input retained as a backend fallback.
- Native compact-envelope, expiry/replay protection, and bounded trusted
  courier queue primitives for the Reticulum-inspired mode.

## What Is Not Complete Yet

- Multi-provider group attachment swarming and multi-device identity sync.
- Delta Chat account integration and explicit fingerprint-verified contact
  linking.
- Full LocalSend v2 compatibility (the existing LAN HTTP path is Conest's
  encrypted transfer path, not a LocalSend trust domain).
- Optional official RNS/LXMF interoperability sidecar and its redistribution,
  Android-runtime, and all-platform qualification work.
- Production enablement of courier forwarding, which remains off by default
  until queue persistence, quota UI, and adversarial tests are complete.
- Beam receive-session persistence across an application restart. Completed
  files are verified and saved privately, but an interrupted optical scan must
  currently be restarted.
- Physical camera qualification across the supported Linux/Windows backends;
  manual Beam frame entry remains available when native capture is absent.
- Forced-Iroh-relay/offline integration qualification and native cancellation
  of an already-open QUIC stream; controller cancellation already stops later
  verified ranges from being issued.
- Moving the remaining Dart attachment orchestration onto the native Rust
  transfer primitives and replacing the current LAN block envelopes with a
  fully binary long-lived session.
- Platform media transcoding/EXIF stripping, verified-range streaming proxy
  playback, and seek-driven range prioritization.
- Repeated physical 2 GiB/device certification on Android, Linux, and Windows;
  the automated boundary tests do not substitute for that release gate.

## Run The Relay

```bash
cargo run -p conest_relay -- 0.0.0.0:7667
```

If you omit the address, the relay listens on `0.0.0.0:7667`.

For a public host/domain, build the standalone binary:

```bash
cargo build --release -p conest_relay
./target/release/conest_relay 0.0.0.0:7667 \
  --relay-id my-public-relay-1 \
  --ttl-seconds 604800 \
  --max-queue-per-mailbox 512 \
  --max-fetch-limit 128 \
  --max-envelope-bytes 262144 \
  --max-requests-per-minute 240
```

Open TCP and/or UDP port `7667` on the host firewall or provider security group. The same relay port also accepts HTTP requests, so HTTP tunnels such as LocalTunnel can forward to it. If the host is UDP-only, add it in the app as `udp://your-domain:7667`; for LocalTunnel-style URLs, add the relay as `https://your-subdomain.loca.lt`.

LocalTunnel/ngrok caveat: tunneled relays only work while the tunnel client is alive on the host. When the tunnel process exits or the host reboots, clients pointed at the tunnel URL stop being able to reach that relay. Run the tunnel under a supervisor (systemd, pm2, etc.) for any deployment that must outlive a single shell session. When clients reach the relay through a shared tunnel, every request appears to originate from the tunnel's IP, so the relay's per-IP rate limit becomes shared across all tunneled clients unless the relay is configured to trust `X-Forwarded-For` (see below).

The relay speaks the same JSON protocol as the app over TCP newline-delimited requests, UDP single-datagram requests, and HTTP/HTTPS POST requests:

- `health` checks availability and returns basic queue stats.
- `store` accepts encrypted envelopes for a recipient mailbox.
- `fetch` returns queued envelopes and consumes normal messages.
- `pairing_announcement` envelopes are reusable during TTL and deduped by sender device, so multiple clients can discover the same codephrase.

UDP is intended for v0.1 text/control envelopes. Large attachment chunks are a later protocol phase and will need chunking instead of one datagram.

Manual checks:

```bash
# TCP newline JSON
printf '{"action":"health"}\n' | nc -w 3 127.0.0.1 7667

# HTTP on the same local relay port
curl -sS http://127.0.0.1:7667/health

# LocalTunnel forwards HTTPS externally to the local HTTP relay endpoint
curl -sS -H 'bypass-tunnel-reminder: true' https://your-subdomain.loca.lt/health
```

Useful environment variables mirror the CLI flags: `CONEST_RELAY_BIND`, `CONEST_RELAY_ID`, `CONEST_RELAY_TTL_SECONDS`, `CONEST_RELAY_MAX_QUEUE_PER_MAILBOX`, `CONEST_RELAY_MAX_FETCH_LIMIT`, `CONEST_RELAY_MAX_ENVELOPE_BYTES`, `CONEST_RELAY_MAX_LINE_BYTES`, and `CONEST_RELAY_MAX_REQUESTS_PER_MINUTE`. Set `CONEST_RELAY_TRUST_FORWARDED_FOR=1` (or pass `--trust-forwarded-for`) when the relay sits behind a trusted reverse proxy or HTTP tunnel so that the leftmost `X-Forwarded-For` address is used for per-IP rate limiting instead of the connecting peer. Do not enable this on a directly-reachable public relay.

Use a stable `--relay-id` or `CONEST_RELAY_ID` on public relays. Clients use that id to recognize that a LAN IP and a public domain are different endpoints for the same relay, then keep both routes while preferring the fastest available endpoint.

For durable storage, provide stable paths outside the versioned binary bundle:

```bash
./target/release/conest_relay 0.0.0.0:7667 \
  --identity-seed-path /var/lib/conest-relay/relay-identity.seed \
  --database-path /var/lib/conest-relay/relay.sqlite3
```

The optional supervisor installs a system service and preserves those paths
while updating only the relay binary. The manifest URL must point directly to
the signed `RELEASE-MANIFEST.json`; its signature must be available beside it.

```bash
cargo build --release -p conest_relay_supervisor
sudo ./target/release/conest_relay_supervisor install \
  --data-dir /var/lib/conest-relay \
  --bundle-dir /opt/conest-relay \
  --bind 0.0.0.0:7667 \
  --channel nightly \
  --manifest-url https://example.invalid/nightly/RELEASE-MANIFEST.json \
  --release-public-key '<base64-ed25519-public-key>'
```

The same executable supports `uninstall`, `start`, `stop`, `status`,
`update-now`, `rollback`, and `serve`. Install the matching `conest_relay`
binary in the bundle directory before starting the service.

## Run The App

```bash
flutter pub get
flutter run -d linux
```

On first launch:

1. Create a device with a local LAN port and, optionally, an internet relay host or URL.
2. Open `My invite` to show a QR, payload, and current codephrase.
3. Add the contact by scanning the QR, pasting the payload, or entering only the current codephrase.
4. Nearby delivery will try LAN routes first and fall back to the internet relay when needed.

## Rust Workspace

- `native/conest_relay`: TCP/UDP/HTTP JSON relay with queued offline delivery.
- `native/conest_native`: persistent Iroh endpoint, stable C ABI / FRB API, and
  Linux/Windows Beam camera decoder.
- `native/conest_updater`: desktop helper that swaps a staged update bundle into the running app's install directory and relaunches the app.
- `native/conest_relay_supervisor`: Linux/Windows service wrapper for durable,
  signed relay updates and health-gated rollback.

Linux and Windows CMake builds compile and bundle `conest_native`. Android's
Gradle build invokes `cargo ndk` and packages the generated JNI libraries.

## Tests

```bash
cargo test
flutter test
```

## Android Toolchain

Use JDK 17 for local Android Gradle builds. This matches CI and avoids the
current Gradle/Kotlin crash when the launcher JVM is OpenJDK 26. A repo-level
`.java-version` is included for Java version managers.

## Release Signing

Stable Android builds must be signed with a real release key. The Gradle release
build fails unless these Gradle properties or environment variables are set:

- `conest.android.storeFile` / `CONEST_ANDROID_KEYSTORE`
- `conest.android.storePassword` / `CONEST_ANDROID_KEYSTORE_PASSWORD`
- `conest.android.keyAlias` / `CONEST_ANDROID_KEY_ALIAS`
- `conest.android.keyPassword` / `CONEST_ANDROID_KEY_PASSWORD`

Release update metadata must include `RELEASE-MANIFEST.json` and
`RELEASE-MANIFEST.ed25519.sig`. The signature is base64-encoded Ed25519 over
the exact manifest bytes. Build app artifacts with
`--dart-define=CONEST_RELEASE_MANIFEST_PUBLIC_KEY=<base64-public-key>` so the
updater can verify release assets before trusting checksums.

After placing release assets in `dist/`, generate metadata with:

```bash
CONEST_RELEASE_MANIFEST_PRIVATE_KEY=<base64-32-byte-seed> \
  dart run tool/release_manifest.dart v0.2.0-nightly.20260425.1
```

Minimal rollout-compatible signed manifest shape (v1 discriminator with
additive relay metadata):

```json
{
  "version": 1,
  "tagName": "v0.2.0-nightly.20260425.1",
  "releaseVersion": "0.2.0-nightly.20260425.1",
  "channel": "nightly",
  "minimumSupervisorVersion": "0.1.0",
  "assets": [
    {
      "name": "conest-linux-x64-v0.2.0-nightly.20260425.1.zip",
      "sha256": "64 lowercase hex characters",
      "sizeBytes": 123,
      "role": "app",
      "platform": "linux",
      "architecture": "x86_64"
    }
  ]
}
```
