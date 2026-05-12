# Conest v0.2.0

First stable cut of the v0.2 line. Headline feature is invite-only trusted groups; the rest of the diff against v0.1.0 is hardening picked up along the way.

## Headlines

### Trusted groups (the v0.2 theme per the roadmap)

- Invite-only groups of up to 16 members with pairwise encrypted fanout.
- Owner-governed role model: `owner > admin > moderator > member` with persisted precedence and legacy-vault load.
- Owners can assign or demote admins and moderators and remove any non-owner member.
- Admins can add trusted contacts as plain members and remove members or moderators.
- Moderators are persisted and displayed; their moderation powers stay reserved for future message/file controls.
- Non-owner members can leave.
- Groups can reach members that aren't in your direct contact list through the group member profile.
- Group replies preserve quoted message metadata; per-member accepted/delivered/read state is tracked.

### LAN free-for-all lobby

- A LAN-only "lobby" chat that doesn't require pairing or adding contacts. Messages are signed with an ephemeral LAN session key, marked untrusted, and stay on the local network — no internet relay fallback.

### Reachability indicator is honest now

- The "seen recently" chip used to flip on whenever a route probe succeeded, even with no traffic exchanged. It now only escalates when a real encrypted signal (inbound message, ack, route_update reply, heartbeat reply) was received. Route probes still feed the "known" tier and the diagnostics view but no longer overstate online presence.

### Group leave hides the group

- Leaving a non-owner group (or being removed by the owner) now removes the group from your sidebar/groups list immediately. The conversation record is retained locally so a future re-invite can restore history.

## Hardening that landed along the way

- Codephrase derivation switched from a 32-bit FNV hash to HMAC-SHA-256 (`conest.codephrase.v2`). This is a wire-format break against v0.1 codephrase pairing; QR/manual paste pairing is unaffected.
- UDP relay client probes IPv4 *and* IPv6 — IPv6-only LANs and dual-stack mobile hotspots now reach the relay.
- Single-instance lock no longer truncates the lock file before it knows the lock is yours.
- Desktop update archive extraction rejects symlinks, Windows-style drive letters, UNC roots, and unsupported entry types; release builds without a manifest verification key cleanly report "updates unsupported" instead of failing every check.
- Conest relay accepts query strings on HTTP paths, applies a TCP write timeout, and can be told to trust `X-Forwarded-For` for per-IP rate limiting when sitting behind a tunnel.
- The dead `conest_core` Rust crate (a 600-line parallel reimplementation that nothing called) was removed.

## Tooling

- New GitHub Actions workflows: `ci.yml` (fmt + clippy + cargo test + flutter analyze + flutter test) and `release.yml` (tag-driven build of Linux/Windows desktop bundles, Android APK, standalone relay and updater binaries, plus signed `RELEASE-MANIFEST.json`).
- New `tool/verify_release_manifest.dart` cross-checks a published manifest against the public key end-to-end. The release workflow runs it after signing.

## Run

```bash
flutter pub get
flutter run -d linux
# or
cargo run -p conest_relay -- 0.0.0.0:7667
```

## Verifying a release download

Download `RELEASE-MANIFEST.json` and `RELEASE-MANIFEST.ed25519.sig` from the release page, drop them next to the asset you downloaded, then:

```bash
dart run tool/verify_release_manifest.dart \
  --dist <directory-with-the-asset-and-manifest> \
  --public-key kPecJWlfI1I4ERpAXwxGLl8dPVzllmMEMAJM/nby/fw=
```

## Compatibility

- Stable upgrade path from v0.1 to v0.2 is supported: v0.1 vaults load, contacts persist, and direct messaging keeps working.
- v0.1 ↔ v0.2 pairing by codephrase no longer interoperates (HMAC-SHA-256 codephrase change). QR-payload pairing and manual payload paste pairing still work cross-version.

## Known limitations carried forward

These remain v0.3+ scope per [notes/PLAN.md](notes/PLAN.md):

- Attachments, images, files, voice, and video.
- Ownerless / admin-council group governance.
- Multi-device identity enrollment and live relay sync.
- Signed default-relay lists and relay federation.
- Persistent on-disk relay queue.
- Encrypted vault recovery / Double Ratchet upgrade.
