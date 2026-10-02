## Conest 0.3.11 nightly

This nightly adds forward secrecy between updated devices and brings in the
contact-request, call-screen and voice-composer work from stable v0.3.10.

### Forward secrecy (experimental)

- Between two devices running this nightly or newer, messages, edits,
  reactions, receipts, group updates and call signaling now travel in
  forward-secret sessions. They use the Double Ratchet from vodozemac, the
  audited library Matrix uses. If a device's keys are stolen later, traffic
  recorded earlier cannot be decrypted, and new messages become private again
  after the next exchange.
- Sessions start on their own once both devices have updated. Nothing to set
  up.
- Contacts on older builds, including stable v0.3.10, keep the previous
  encryption and keep working. A device that moves back to a stable build
  switches the feature off for its contacts.
- Group files between updated devices use keys that change daily and are
  deleted after three days. Each call gets its own key.
- Limits:
  - Messages already stored on your device are protected by its encrypted
    vault, as before; forward secrecy covers traffic in transit.
  - Contact-encrypted Beam transfers still use the long-term key.

### Contacts and chats

- Adding a contact now sends a request that the other person accepts or
  declines. Messages you write before that wait and are sent once it is
  accepted. You can retry or cancel a pending request.
- Tap a message for its actions, long-press to select, and double-tap to
  reply (or to edit your own message).

### Voice

- Calls open in a full-window call screen that you can minimize to a bar
  and return to.
- Settings has a switch to turn experimental calls off on this device.
- The voice recorder sits inline in the composer, with the preview's
  position and volume sliders.
- Ending a call while its audio was still starting no longer leaves the
  microphone in use.

### Qualification

- The remote debug workflow for this source passed: focused Flutter
  verification, native ratchet tests against the real library, native
  Opus/AEC3 and recording tests, and the Linux, Android and Windows debug
  builds. The full local test suite passed.
- An independent review of the forward-secrecy code was done before release
  and its findings were fixed.
- Not yet tested on real devices: forward secrecy between two phones or
  computers, a nightly paired with a stable device, calls and group files
  after updating, and Android and Windows in general.

Update both devices to get forward secrecy and the new contact requests. This
nightly is prerelease software; keep important data backed up and report
failures with the build identifier and a debug snapshot.
