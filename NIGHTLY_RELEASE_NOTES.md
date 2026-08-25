## File and media system v2 testing preview

- Adds attachment-protocol-v2 manifests, 128 KiB authenticated blocks,
  durable range journals, exact progress/speed/ETA snapshots, restart resume,
  priority controls, and a content-addressed managed cache.
- Adds Preparing, Queued, Waiting, Reconnecting, Verifying, Failed, and
  Complete transfer UX; a global Transfers screen; multi-file/album staging;
  media/file presentation modes; and improved save/view/retry controls.
- Keeps the transfer route order LAN, Iroh direct, visible Iroh relay, then the
  Conest offline relay. Conest relay storage remains capped at 30 MiB per
  attachment, and large Iroh-relay use requires consent unless the configured
  relay is marked bulk-capable.
- Moves Conest relay queues into SQLite WAL storage with quotas, deduplication,
  expiry, and lease/ack delivery. Adds a signed-update relay supervisor for
  Linux and Windows with maintenance windows and health-gated rollback.

### Attachment compatibility and migration

On first launch, every incomplete legacy attachment transfer is canceled with
“Canceled by transfer upgrade—resend.” Completed attachments and message
history are preserved, and original user files are never deleted. Both peers
must run an attachment-v2 build to exchange files; older peers can still text.

### Preview limits

This nightly is for interoperability and large-file testing, not the final v2
acceptance build. Native Rust block/journal primitives are included, while the
remaining Dart transfer orchestration and LAN binary-session migration are
still being completed. Platform transcoding, verified-range streaming/seek,
group multi-provider transfer, physical 2 GiB certification, and Windows
device soak testing remain release gates.
