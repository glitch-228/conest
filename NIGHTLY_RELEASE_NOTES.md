## Conest 0.3.10 nightly

This nightly builds on signed group history, Iroh group messaging, and the
Courier chat layout. It adds the first usable versions of chat folders,
scheduled messages, group polls, voice messages, and experimental direct voice
calls.

### Chat and groups

- Create, rename, reorder, and delete local chat folders; filter folders with
  chat search and switch to Search all chats. Folder settings stay encrypted on
  this device. Folder memberships do not sync between devices.
- Schedule direct and group text messages and attachments. Edit, reschedule,
  send now, and cancel them from the scheduled list. Files are staged in private
  app storage. Due messages send when Conest is running and reconnects; delivery
  is not guaranteed while the app is stopped.
- Create single or multiple choice group polls with visible voter identities.
  Members can change or retract votes; the creator can close a poll with a
  signed vote checkpoint. Offline votes outside that checkpoint remain visible
  as unconfirmed.
- Group history and attachments continue to use signed events and verified
  transfers. Synchronization and multi-provider recovery still need physical
  partition and network qualification.

### Voice

- Record, preview, discard, send, and play Ogg/Opus voice messages in direct and
  group chats, including seeking and playback speed controls.
- Adds opt-in one-to-one voice calls over encrypted Iroh datagrams with Opus
  audio, ringing, mute, reconnect handling, and call summaries. Calls remain
  experimental and are disabled by default. Enable only for testing on trusted
  devices; audio quality, route changes, background lifecycle, and battery use
  have not been physically qualified.
- Fixes races around microphone startup, recorder disposal, overlapping call
  setup, and late audio controls after hangup.

### Reliability and qualification

- Scheduled delivery now rereads the current persisted item before dispatch,
  avoiding stale content or sending an item after it was rescheduled.
- Group partition tests require disconnected peers to be unreachable in both
  directions and synchronize missing signed-history predecessors before voting.
- The remote debug workflow for this source passed its focused Flutter
  verification. Linux, Android, and Windows debug artifact jobs must complete
  successfully before this release is considered build-qualified.
- Physical Android/Linux/Windows testing remains necessary for group-history
  partitions, folder interactions, scheduled wake behavior, file-transfer
  recovery, voice recording/playback, and call routes/audio. Calls remain
  disabled by default pending those checks.

Update both peers to matching builds for group history, poll, and attachment
compatibility. This nightly is prerelease software; keep important data backed
up and report failures with the build identifier and debug snapshot.
