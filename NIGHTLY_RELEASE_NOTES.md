## Conest 0.3.10 nightly

### Group chat history and membership

- Group events are now signed and covered by an encrypted, peer-carried
  history journal, with authenticated group membership history and admission
  boundaries.
- Adds durable group catch-up with bounded, resumable exchanges: joining or
  reconnecting members fetch authorized group history automatically on
  startup reconnect and when a chat is opened, and catch-up resumes on fresh
  connections.
- Group owners can control history visibility for members, and admission
  checkpoints are captured so later-joined members receive only the history
  they are authorized to read.
- Authorized older group history pages are now exposed in chat, so members
  can scroll back into history fetched before they joined.

### Groups over Iroh and relay changes

- Group messaging now works over Iroh with peers who are not individual
  contacts.
- Bundled Conest relay servers are retired: previously bundled routes are
  removed on upgrade. Explicitly configured relays and Iroh
  discovery/fallback remain available.

### Everyday chat interface

- Begins the Telegram-style interface: Courier layout is the default for new
  installations; existing preference files migrate once, retaining brightness,
  decoration intensity, and the older home-layout choice.
- Replaces the decorative search with a working, editable and clearable
  search across contact/group names and currently loaded message previews.
  Full journal search and result highlighting remain outstanding.
- Courier chat-list rows now show a compact reachability mark (colored dot
  plus online/seen-recently/known/unknown label) for contact conversations,
  matching the reachability chip in the chat header.
- Direct, group, and LAN-lobby composers keep separate encrypted text
  drafts. Drafts persist locally in the encrypted vault, are never sent as
  network events, and are cleared when the message is sent.

### Validation

- CI green at this nightly's commit: Flutter 348 tests passed, 6 skipped;
  analysis and formatting clean; Rust workspace 56 tests passed with clippy
  and rustfmt gates.
- Search widget/screenshot review, group history physical-network
  qualification, and draft lifecycle flush qualification remain outstanding.

Update both peers to this nightly to use matching group history and
admission behavior. With the bundled relays retired, devices that relied on
the previously bundled Conest relay should add an explicit relay or keep
Iroh discovery enabled.
