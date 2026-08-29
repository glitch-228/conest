## High-throughput attachment transport nightly

- Moves direct attachment data from 128 KiB JSON/base64 envelopes to 4 MiB
  authenticated binary blocks while preserving per-block XChaCha20-Poly1305
  encryption, hashes, exact durable progress, and resumable range journals.
- Reuses LAN HTTP connections and allows a bounded 16 MiB transfer window so
  secure local transfers can use the network efficiently without buffering an
  entire file in Flutter memory.
- Pools pinned Iroh QUIC connections and four persistent send workers instead
  of opening an isolate, connection, and stream for every block. Binary Iroh
  ranges are capability-gated for attachment-v2 peers.
- Adds signed direct Iroh address hints to `ci6` invitations and contact
  bindings while retaining endpoint-ID pinning and end-to-end application
  encryption.
- Fixes the incoming Download action, serializes receiver file writes and
  finalization, and restores accepted transfers after restart so completed
  ranges remain reusable.
- Keeps the route order LAN, Iroh direct, visible Iroh relay, then Conest
  offline store-forward. Direct LAN/Iroh ranges bypass the 30 MiB Conest relay
  payload path; the Conest relay itself remains capped at 30 MiB.

### Attachment compatibility and migration

On first launch, every incomplete legacy attachment transfer is canceled with
“Canceled by transfer upgrade—resend.” Completed attachments and message
history are preserved, and original user files are never deleted. Both peers
must run an attachment-v2 build to exchange files; older peers can still text.

### Validation performed

- The real HTTP LAN harness completed exact-hash transfers at 5, 15, 30, 125,
  1000, and 2000 MiB with bounded memory.
- A 250 MiB direct-Iroh controller transfer completed over the pooled native
  path with an exact cache result and no Conest attachment-chunk fallback.
- Focused restart/resume, LAN protocol, transport, native block-crypto, Rust
  workspace, Clippy, and Dart analysis checks pass.

### Device testing focus

- Update both peers; this build's binary range capability is required on both
  sides for the new fast path.
- Re-test Android and Linux in both directions, especially Download approval,
  pause/resume, app restart, Wi-Fi loss/recovery, and 125 MiB or larger files.
- Confirm the visible route remains LAN or direct Iroh and durable progress is
  not lost when the route changes.

### Remaining preview limits

This nightly is for interoperability and throughput testing, not the final v2
acceptance build. The automated large-file runs use local test transports;
physical Android/Linux/Windows 2 GiB certification is still required.
Platform transcoding, verified-range media streaming/seek, group
multi-provider transfer, and Windows device soak testing remain release gates.
