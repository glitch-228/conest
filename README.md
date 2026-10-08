# Conest

Conest is a serverless messenger for Linux, Windows and Android. Contacts
reach each other directly over the local network or the internet, and fall
back to whatever still works when that fails: relays, Matrix, Nostr, email,
Tor, LoRa radios or a Bluetooth mesh of nearby phones. Every route carries
messages end-to-end encrypted by Conest.

It can also be used as a Matrix client, alongside Conest chats or instead
of them.

## Features

**Messaging**
- Direct chats and invite-only groups of up to 16 people: text, replies,
  edits, reactions, read receipts, scheduled messages, voice messages and
  files with albums and captions.
- Saved messages: a chat with yourself for notes, files and forwards,
  kept only on this device.
- Voice calls between Conest devices (experimental, off by default).
- Every message shows a route mark telling how it travelled.

**Privacy and security**
- Forward secrecy between updated devices: messages and controls travel in
  Double Ratchet sessions (vodozemac, the library Matrix uses), so keys
  stolen later cannot decrypt recorded traffic. Group files use keys that
  change daily; each call gets its own key.
- Contacts are added from a signed invite (QR code, pasted text, or a
  rotating codephrase) and must accept the request. Adding is recoverable:
  a lost acceptance, decline or removal is repeated, and removed contacts
  can be added again.
- An encrypted local vault, unlocked by the device, a key file or a
  passphrase; a portable "ghost" storage mode is available.

**Routes** (Settings → Connectivity)
- On by default: LAN, Iroh QUIC (direct, or through Iroh relays) and
  Conest relays you configure.
- Opt-in, for when the usual routes are blocked or there is no internet:
  - Matrix (with a signed-in Matrix account),
  - Nostr relays (gift-wrapped events),
  - email (a free chatmail account or your own mailbox, OpenPGP),
  - Tor onion services, with obfs4, webtunnel, snowflake or meek bridges,
  - LoRa radios: Reticulum, Meshtastic and MeshCore,
  - a Bluetooth mesh with nearby phones (bitchat-compatible).
- Both sides need a route on for it to be used. Routes enabled later reach
  existing contacts automatically.
- Routes are ranked per contact by what works and how fast; a contact can
  carry messages for another contact you cannot reach yourself.
- Files go over LAN, Iroh, Conest relays and Tor; the other routes carry
  messages only.

**Files**
- Resumable, hash-verified transfers up to 2 GiB with pause, retry,
  keep-offline and a managed cache; a 30 MiB cap for relay routes.
- Conest Beam: animated-QR transfer of files and invites between screens,
  with no network at all.

**Matrix**
- App modes: Conest, Both (Conest and Matrix chats with filters) or Matrix
  only (no Conest identity needed).
- Password or browser (single sign-on) sign-in, emoji verification,
  recovery, rooms with replies, edits, reactions, files and invites.

**bitchat users nearby** (Android, with the Bluetooth mesh on)
- Read bitchat's mesh chat; with "Reachable by bitchat users", chat
  privately with bitchat users on iPhone and Android and write in the mesh
  chat, under a separate identity that changes weekly.
- "Share internet with bitchat users" lets phones nearby without internet
  use bitchat's location channels through yours.

**Updates**
- Signed in-app updates on a stable or nightly channel ("Receive unstable
  updates" in Settings); a nightly device can always move back to stable.

## What Is Not Complete Yet

- Several devices on one account (planned: per-device keys under an account
  key, linking through Matrix or a QR code, optional sync).
- Talking to other apps' users: Nostr NIP-17, Matrix DMs with Element,
  Delta Chat, Telegram and Discord are planned; bitchat chats move into the
  main chat list with the network modes.
- Sending one message over several routes at once, and files over several
  routes in parallel.
- Relay protocol v2 with registration for large files and call relaying.
- Background notifications on Android and a background runtime on by
  default; Linux Bluetooth mesh.
- Beam receive sessions do not survive an app restart.
- Device testing of the newer routes (Tor bridges, radios, Bluetooth mesh,
  email) and of 2 GiB transfers on every platform is ongoing.

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

1. Choose where Conest stores its data and how the vault unlocks.
2. Create your device (a display name is enough), or pick "Use as a Matrix
   client instead".
3. Open **My invite** to show a QR code, the invite text and the current
   codephrase.
4. Add a contact by scanning their QR code, pasting their invite or typing
   their current codephrase; they accept the request on their side.
5. Optionally turn on more routes under **Settings → Connectivity**.

A signed QR code or pasted invite is enough to add a contact over the
internet (Iroh) with no relay and no shared network. A codephrase needs the
same LAN or a shared Conest relay to find the invite.

## Rust Workspace

- `native/conest_native`: the app's native library: Iroh endpoint and file
  transfer, voice-call audio, Matrix (matrix-sdk), Tor (Arti), the Beam
  camera decoder, and a stable C ABI for Dart.
- `native/conest_relay`: TCP/UDP/HTTP JSON relay with queued offline delivery.
- `native/conest_relay_supervisor`: Linux/Windows service wrapper for durable,
  signed relay updates and health-gated rollback.
- `native/conest_updater`: desktop helper that swaps a staged update bundle
  into the install directory and relaunches the app.

Linux and Windows CMake builds compile and bundle `conest_native` (and the
lyrebird pluggable-transport client for Tor bridges). Android's Gradle build
invokes `cargo ndk` and packages the generated JNI libraries.

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
