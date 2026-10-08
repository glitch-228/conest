## Conest 0.3.12 nightly (October 8, fourth build)

This nightly finishes chats with other apps' users: people on the
Meshtastic and MeshCore apps, and verifying people on Matrix (as Element
X does). Everything from the earlier October 8 nightlies is included.

### Before you update

- Nothing changes until you turn something on.

### Meshtastic and MeshCore app users (new)

- With your radio set up (Settings → Connectivity), turn on **Messages
  with Meshtastic app users** or **Messages with MeshCore app users** to
  read and write the apps' own messages through it:
  - direct messages with a node (Meshtastic) or with the radio's contacts
    (MeshCore), marked delivered when the other radio confirms, or not
    delivered when it could not read the message;
  - the radio's channels, as group chats.
- They appear in the chat list, each with its filter.
- These messages are protected only as the radios protect them, not with
  Conest's encryption. On a channel anyone with the channel key can read
  and can write under any name; Meshtastic direct messages that arrived
  without the radios' own keys are marked "sender not verified".
- Saving the radio settings again keeps the setting.

### Matrix: verifying people (new)

- In a direct chat, the shield button verifies the other person by
  comparing emojis, as in Element; verified chats show a badge.
- Requests from other people are accepted only from someone you have a
  direct chat with, one at a time.
- A direct chat says what the homeservers can see, and says so plainly
  when it is not encrypted.

### Not tested on devices yet

- Meshtastic and MeshCore app messages with real radios and the official
  apps; verifying an Element X user.
