## Conest 0.4.0 nightly (October 20, second)

The release candidate for the stable v0.4.0: please try it, above all
on Windows and Linux. Everything from the earlier nightlies is included.

### Fixed since this morning's nightly

- Links open on the first click or tap, at once.
- On computers, dragging over a message with the mouse selects its text
  again, and holding the space beside a message selects it: the mouse no
  longer swipes a message to reply (a finger or a trackpad still does).
- Android: the back button in Settings goes from a page back to the list
  of pages, instead of closing Settings.
- Updating from an older version no longer shows "Conest closed
  unexpectedly" on the next start.
- Email, Nostr, Tor, Reticulum and the Bluetooth mesh: their switch now
  pauses and resumes, keeping your address there (it used to forget it).
  "Remove" forgets it, after asking. Email shows the account in use and
  can change it (your own account) or move to another server.

### On computers

- Enter sends and Shift+Enter starts a new line (Settings > Personal
  can switch it back; then Ctrl+Enter sends).
- A click on a message is for selecting its text and opening its links.
  The message menu opens on a right click, also on the text, and offers
  to copy the text you selected.
- Holding the space beside a message selects it; holding the message
  itself no longer does.
- Ctrl+V pastes into the open chat wherever you clicked in it.
- Windows: pasting a screenshot (Win+Shift+S) or another copied image
  works again.

### Fixes

- Group files reach members that only a relay or Tor reaches, as files
  in one-to-one chats always did (both sides need this nightly).
- A message whose delivery or reading was confirmed is not sent again
  over other routes.
- Removing someone from a group no longer leaves your earlier messages
  waiting for them.
- LAN: when another app (often a second Conest on the same computer)
  holds Conest's LAN port, Conest moves to a free one and tells your
  contacts, instead of having their messages and files go to that app.
- Relays: slow connections get more time, and messages held on a relay
  come back sooner after a lost connection.
- Updating no longer shows "Conest closed unexpectedly" on the next
  start, and saves what was pending first.
- Email setup tries every chatmail server it knows on networks that
  block some of them.

### New

- Links in messages are underlined and open in your browser. An address
  that uses letters from other alphabets (and may imitate a site you
  know) asks first.
- A user guide (getting started, choosing routes, blocked networks, Tor
  bridges, several devices, troubleshooting), linked from setup and from
  Settings > Personal.
- Settings are split into pages: a sidebar on wide windows, a list on
  phones.

### Please check

- This build was not started on a test phone before release (none was
  connected); the morning's nightly was, and nothing Android-specific
  changed since.

- Pasting a screenshot on Windows, and Enter, clicks and right clicks
  on Windows and Linux.
- Sending a group file to a member on another network.
- Calls and voice messages.

### Known limits

- Email can stall on networks that block or throttle mail servers.
