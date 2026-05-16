# Conest v0.3.0

The v0.3 line focuses on relay maturity and group-sync correctness. Highlights since v0.2.0:

## Trusted groups
- Owners can now transfer ownership to an active member (the previous owner is demoted to admin) or delete the group for everyone via a single "Delete group…" action.
- Non-owners who leave a group keep it visible as **You left** until they explicitly remove it from their list — matching mainstream messenger UX.
- Member adds, removes, role changes, ownership transfers, and dissolves all share a single signed-by-owner `group_membership` envelope path.

## Group sync reliability
- Membership envelopes and read receipts are now retried persistently until acknowledged by the targeted recipient — fixing the "different devices see different members" sync gap that could occur on flaky networks.
- Group membership updates carry a `group_membership_ack` response so the sender knows when to drop a queued retry.
- Read/delivered receipts get the same enqueue-then-deliver-with-backoff treatment; entries survive process restarts via the vault.

## Relay maturity
- Relays now carry a persistent Ed25519 identity key. The desktop and mobile apps pin the key on first contact and warn (with an in-settings "Relay identity changed" banner) on mismatch. Tap **Trust new key** to accept a legitimate operator rotation after verifying out of band.
- Every relay response is signed; clients verify per request using a fresh 16-byte nonce.
- Per-IP rate limit gains a soft-ban backoff: after N consecutive rate-limit violations a peer is temporarily denied even when the per-minute window resets.
- New per-mailbox bytes-per-minute throughput cap (default 10 MB / minute) blocks single-mailbox abuse before file transfers arrive in v0.3.1.
- Conest ships with a bundled, signed default-relay list. The default endpoint is pre-flighted on first boot and shown in settings as **default relay 1** — opaque to users so operator addresses can rotate freely.

## Update prompt
- Stable releases (this one!) bake a signed `releaseNotes` field into `RELEASE-MANIFEST.json`. The in-app update dialog renders these as a scrollable "What's new" section before installing.
- A GitHub-API fallback fetches the release body when the signed notes are absent — present on stable builds only.

## For relay operators
- Persist the relay identity by setting `CONEST_RELAY_IDENTITY_SEED_PATH` (default `./conest_relay_identity.seed`) or passing the base64 seed directly via `CONEST_RELAY_IDENTITY_SEED`. The first start writes the seed automatically.
- New env vars / CLI flags: `CONEST_RELAY_MAX_BYTES_PER_MAILBOX_PER_MINUTE` (`--max-bytes-per-mailbox-per-minute`, default 10 485 760), `CONEST_RELAY_SOFT_BAN_THRESHOLD` (`--soft-ban-threshold`, default 5), `CONEST_RELAY_SOFT_BAN_SECONDS` (`--soft-ban-seconds`, default 300).
- Existing relays continue to work with v0.2 clients; clients that don't send a `nonce` get unsigned responses (legacy compatibility).

## What's next (v0.3.x)
- v0.3.1: 1-to-1 small file / image attachments over direct + LAN routes.
- v0.3.2: torrent-like group attachment delivery with content-addressed chunks.

Thanks for testing the v0.3 nightlies that fed into this release.
