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
- Polls created before members exchanged feature support are visible and
  votable again, including polls and votes from members who have left.
- A scheduled group file with text now still sends when some members run an
  older build: the text follows as a separate message instead of the scheduled
  item failing.
- Messages from members removed by an older build are no longer dropped from
  history sync. When the group owner opens the group, their device signs the
  removed member's last valid message once; earlier history becomes available
  to every member again, and anything signed after it stays rejected.
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
- Desktop calls now use WebRTC's AEC3 echo canceller, which finds the
  speaker-to-microphone delay itself and keeps your voice during double-talk.
  Android keeps using the phone's built-in echo canceller.
- Muting a call now sends silence; previously a faint echo of the other person
  could leak through.
- On Android, switching to speakerphone right after a call starts now works,
  and ending a call while audio is still starting no longer leaves the
  microphone held.
- Voice messages keep their last moment of audio and report a valid length to
  strict players.
- Fixes races around microphone startup, recorder disposal, overlapping call
  setup, and late audio controls after hangup.

### Reliability and qualification

- A slow voice frame no longer interrupts file transfers or messages sent
  during a call.
- Contacts on newer builds that advertise features this build does not know
  keep their profile and route updates instead of being ignored.
- Scheduled delivery now rereads the current persisted item before dispatch,
  avoiding stale content or sending an item after it was rescheduled.
- Group partition tests require disconnected peers to be unreachable in both
  directions and synchronize missing signed-history predecessors before voting.
- The remote debug workflow for this source passed in full: focused Flutter
  verification, native Opus/AEC3 and voice-recording tests, native group
  transport qualification, and the Linux, Android, and Windows debug builds.
  A native Iroh test confirms adding a contact works over a direct connection
  with LAN and every relay disabled.
- Physical Android/Linux/Windows testing remains necessary for group-history
  partitions, folder interactions, scheduled wake behavior, file-transfer
  recovery, voice recording/playback, and call routes/audio. Calls remain
  disabled by default pending those checks.

Update both peers to matching builds for group history, poll, and attachment
compatibility. This nightly is prerelease software; keep important data backed
up and report failures with the build identifier and debug snapshot.
