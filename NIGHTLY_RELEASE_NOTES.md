## Conest 0.3.11 nightly (October 3)

This nightly adds Matrix as a fallback route: when LAN and Iroh cannot reach
a contact, messages can travel through a Matrix account instead.

### Matrix fallback (experimental)

- Sign in under **Settings → Connectivity → Matrix fallback** with any Matrix
  account, for example `@name:matrix.org` and its password. You can leave the
  homeserver blank; it is found from the user id.
- Conest uses its own Matrix device, so its traffic never appears in Element
  or your other Matrix apps.
- When both you and a contact have signed in, messages that LAN and Iroh
  cannot deliver go through Matrix instead of waiting. They stay end-to-end
  encrypted by Conest. The homeserver sees which accounts talk and when, but
  never the content or the type of message.
- Messages wait on the homeserver while your device is offline and arrive
  when it comes back.
- Files still travel over LAN or Iroh only.
- Signing out, turning Online off, or setting Matrix to Off under Transport
  policy stops the route. Your contacts are told.
- Not yet supported:
  - sign-in for accounts without a password (single sign-on);
  - reaching people who do not use Conest. Both are planned next.

### Forward secrecy

- Group members who are not each other's contacts now set up their secure
  session more reliably. Previously a session could take up to ten minutes to
  start, or not start at all, when the group and the members' details arrived
  in an unlucky order.

### Qualification

- The remote debug workflow passed: focused Flutter verification, the Matrix
  route against a real Synapse homeserver, native ratchet tests, and the
  Linux, Android and Windows debug builds. The full local test suite passed.
- An independent review of the Matrix code was done and its findings fixed.
- Not yet tested on real devices: Matrix sign-in, delivery between two
  devices over Matrix, background syncing on Android, and everything still
  pending from the October 2 nightly (forward secrecy, contact requests,
  calls).

Update both devices to use the Matrix fallback. This nightly is prerelease
software; keep important data backed up and report failures with the build
identifier and a debug snapshot.
