## Conest 0.3.12 nightly (October 17)

Read marks fixed, no crash goes unnoticed, much less battery used by
group calls, Conest in five more languages, and the Bluetooth mesh on
desktops. Everything from the earlier October nightlies is included.

### Fixes

- Messages are marked read again on Windows, Android and Linux, also
  when scrolling to older ones, for albums and files, and for contacts
  whose clock is off. Group members each get their read receipt.
- Group calls no longer keep the device awake: nothing runs for them
  without a call, and members outside a call are not woken by it.
  Playback no longer slowly crackles (it ran about 5% slow, 1:1 calls
  too).
- A Delta Chat message that can never be saved (for example with the
  device short of space) is no longer downloaded again and again; it is
  left on the mail server and the rest of the mail arrives.
- Signed PDFs and Office files are sent untouched (asking first), so
  their signature stays valid. Agreeing to send a partly cleaned file now
  sends the cleaned copy. Canon raw photos and 360° videos are no longer
  damaged by metadata removal.
- Matrix emoji verification shows the emoji names in every language.
- A forwarded voice message arrives as a voice message, not as a file.

### New

- Forwarding: select several messages and forward them together, or
  forward a whole album from its menu (it arrives as one album).
  Messages from Matrix rooms can be forwarded into Conest chats and
  groups too.
- Crash reports: if Conest closes unexpectedly, the next start says so
  and shows what happened, to copy into a bug report. Nothing is sent
  anywhere.
- Translations into Arabic, Persian, Indonesian, Russian and Simplified
  Chinese for the rest of the app, with right-to-left layouts. They are
  AI-assisted: corrections are welcome.
- Bluetooth mesh on Linux and Windows desktops and laptops (built-in
  adapters and USB dongles), with phones and other desktops.
- Network history: Settings > Connectivity > Connections lists the
  networks this device has been on and how each route fared there. A
  relay a network keeps blocking is tried last on that network.
- Run your own relay: install-relay.sh (with this release's files) set
  up on a Linux server with "sh install-relay.sh" asks before each step,
  can install automatic signed updates, and prints a link to add the
  relay in Conest (Settings > Relays), which pins its key.

### Not tested on devices yet

- Desktop Bluetooth mesh with phones, two phones on one laptop, and USB
  dongles.
- Right-to-left layouts and each language on phones.
- The relay installer on a fresh server (stable and nightly channels).
