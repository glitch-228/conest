## Conest 0.4.3 nightly (October 30)

Everything in the October 29 nightly is included.

### Your devices

- Linking a device that already has chats now shows both sides first, then lets you merge or replace:
  - **Merge:** one chat per contact. This device keeps its own names for contacts.
  - **Replace:** this device's old chats are kept in "This device's old chats" (Settings > Devices). From there you can open their files, export them, or delete them.
- A device that belongs to another account asks before leaving it.
- A contact whose keys differ between your devices is marked "keys differ: verify".
- Settings > Devices: choose how fast your devices sync, and whether they share settings.

### Fixes

- Received files and unfinished downloads no longer disappear after a restart when two copies of Conest run on the same computer.
- Bluetooth no longer fails with "No implementation found" after Conest was opened from a notification.
- XMPP setup tries many more public servers, also on port 443. It can show a CAPTCHA, and says what each server answered.
- On Linux, Settings > Voice lists your real speakers and microphones.
- The chat filters scroll with the mouse on desktop.
- Selected text in your own messages is visible on desktop.
- No more "new messages" mark with nothing new under it.
- A reset now removes all session data.
- On a local network where messages only got through one way, two devices could fail to start an encrypted session. They now keep trying over every route.
- Nostr: group membership changes now reach members, and messages are paced, so public relays no longer turn them away.
- A file that cannot arrive over the routes you have no longer asks again and again. It says so, and continues when a suitable route appears.

### Please check

- Link a phone that already has chats to another of your devices: try Merge, then Replace, and open an old chat's file.
- Settings > Voice on Linux: pick a headset and call.
- XMPP setup on a network that blocks some servers.
