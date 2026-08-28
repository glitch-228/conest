## File and media system v2 stability nightly

- Fixes Android-to-Linux LAN transfers stalling around 15 MiB by replacing the
  old 120-request and 64 MiB per-minute ceilings with bounded limits sized for
  attachment protocol v2 and its 2 GiB target.
- Reuses LAN keep-alive connections and dispatches encrypted envelopes through
  a bounded asynchronous queue, avoiding connection churn and nested response
  deadlocks during bidirectional transfers.
- Makes concurrent attachment streams share one pinned Iroh QUIC connection
  instead of racing duplicate handshakes.
- Persists relay-delivered transfer state before acknowledging leased rows and
  prevents mailbox quota eviction from deleting active leases.
- Restores manual-download approval and bilateral pause state after restart.
- Retains exact progress, speed, ETA, restart resume, priority controls, the
  global Transfers screen, multi-file staging, and media/file presentation.
- Keeps the route order LAN, Iroh direct, visible Iroh relay, then Conest
  offline store-forward. Conest relay storage remains capped at 30 MiB per
  attachment.

### Attachment compatibility and migration

On first launch, every incomplete legacy attachment transfer is canceled with
“Canceled by transfer upgrade—resend.” Completed attachments and message
history are preserved, and original user files are never deleted. Both peers
must run an attachment-v2 build to exchange files; older peers can still text.

### Testing focus

- Update both peers; attachment-v2 builds are required on both sides.
- Test Android and Linux in both directions with 1 MiB, 16 MiB, 31 MiB, and
  larger direct transfers, plus pause/resume and app restart.
- Test LAN loss and recovery. The route badge and transfer details should show
  every transition without losing verified progress.

### Remaining preview limits

This nightly is for interoperability and large-file testing, not the final v2
acceptance build. Native Rust block/journal primitives are included, while the
remaining Dart transfer orchestration and LAN binary-session migration are
still being completed. Platform transcoding, verified-range streaming/seek,
group multi-provider transfer, physical 2 GiB certification, and Windows
device soak testing remain release gates.
