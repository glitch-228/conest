## Iroh pairing and transfer reliability

- Signed QR/pasted ci6 invites now deliver contact requests over Iroh before
  the sender is a trusted contact. The signed invite must match the
  authenticated endpoint, and the receiver must approve the request.
- Approval returns an encrypted contact confirmation. Codephrase-only
  discovery still requires LAN discovery or a shared Conest relay.
- Fixes stalled replies and transfer acknowledgements on pooled Iroh
  connections. Both dialed and accepted connections now receive streams.
- Isolates connection attempts by peer, bounds stalled streams, and allows
  direct delivery to recover after a previous relayed connection.
- Checks attachment ownership before accepting pause, completion, or cancel
  controls, and rejects attachment-ID collisions across conversations.
- Makes cancellation persist across restart, cleans private transfer files,
  advances the outbound queue, and stops late block retries and fallback.
- Preserves paused state and durable range boundaries when checkpointing
  incoming transfers.

## Debug artifacts

- Adds a separate debug channel and manually triggered Android, Linux, and
  Windows debug artifact workflow. Android debug installs use a separate app
  identity and the label Conest Debug.
- Matching debug builds can run automatic LAN file tests with build
  compatibility checks, hash verification, timing/results, and cleanup.
- Automatic file-test controls are limited to debug artifacts. Debug builds
  do not use the release updater or publish to the nightly release feed.

## Validation

- Flutter suite: 279 tests passed, followed by focused cancellation, pairing,
  transfer, and restart/resume regressions after the final fixes.
- Rust workspace: 56 tests passed; Clippy and Dart/Flutter analysis passed.
- A real 250 MiB native-Iroh controller transfer passed with contact pairing
  forced through Iroh, final file verification, and no Conest relay payloads.
- Direct and relayed Iroh controller simulations cover pairing, two-way
  messages, files, and invalid identity rejection.

## Testing notes

Update both peers to this nightly for the pairing and pooled-connection fixes.
Attachment-v2 compatibility and the 30 MiB default Conest store-forward limit
remain in effect. Public-relay/NAT and physical Android/Windows qualification
were not performed for this change; repeat pause/resume, cancellation, restart,
and network-change checks on your devices.
