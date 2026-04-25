# Conest

Conest is a phased secure text-exchange app. This repository now contains the first working `v0.1` implementation cut:

- Flutter client for Linux, Windows, and Android.
- QR invite export plus Android QR scanning and a full-screen QR view.
- QR-import-only and codephrase-only contact pairing.
- Encrypted local vault for identity, contacts, and message history.
- LAN-first direct text delivery with TCP/UDP route variants, relay fallback, and queued offline delivery.
- Rust workspace with protocol types, crypto helpers, and a standalone relay binary.

## What Is Implemented Now

- One account on one device.
- Direct text conversations only.
- Compact `ci5` invite payloads with ranked LAN and relay route hints.
- Route hints carry both route kind and protocol, currently `tcp`, `udp`, `http`, or `https`.
- Rotating pairing code derived from the payload in 120-second windows.
- Desktop-style relay behavior enabled by default through the app's local LAN node.
- X25519-derived shared secret encryption per direct conversation.
- Nearby pairing and messaging that try LAN routes first, then continue through internet relay routes when available.
- Codephrase discovery over LAN beacons, bounded nearby LAN scans, or the configured shared relay.
- Relay polling, outbound queueing, duplicate suppression, and ack-based delivery state updates.
- Protocol shapes reserved for groups, LAN routes, attachments, and multi-device enrollment.

## What Is Not Complete Yet

- Direct hole punching and libp2p route selection.
- Desktop tray persistence and Android foreground service lifecycle.
- Group chat, file/image transfer, automatic LAN discovery beyond current interface enumeration, and multi-device identity sync.
- Production-hardening items such as signed relay lists, relay federation, audited abuse controls, secure key rotation, and a Double Ratchet implementation.

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

Useful environment variables mirror the CLI flags: `CONEST_RELAY_BIND`, `CONEST_RELAY_ID`, `CONEST_RELAY_TTL_SECONDS`, `CONEST_RELAY_MAX_QUEUE_PER_MAILBOX`, `CONEST_RELAY_MAX_FETCH_LIMIT`, `CONEST_RELAY_MAX_ENVELOPE_BYTES`, `CONEST_RELAY_MAX_LINE_BYTES`, and `CONEST_RELAY_MAX_REQUESTS_PER_MINUTE`.

Use a stable `--relay-id` or `CONEST_RELAY_ID` on public relays. Clients use that id to recognize that a LAN IP and a public domain are different endpoints for the same relay, then keep both routes while preferring the fastest available endpoint.

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

- `native/conest_core`: shared protocol types plus bootstrap/invite/encryption helpers.
- `native/conest_relay`: TCP/UDP JSON relay with queued offline delivery.

## Tests

```bash
cargo test
flutter test
```

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
  dart run tool/release_manifest.dart v0.1.0
```

Minimal manifest shape:

```json
{
  "version": 1,
  "tagName": "v0.1.0",
  "assets": [
    {
      "name": "conest-linux-x64-v0.1.0.zip",
      "sha256": "64 lowercase hex characters",
      "sizeBytes": 123
    }
  ]
}
```
