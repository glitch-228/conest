## Conest 0.3.12 nightly (October 8, third build)

This nightly brings chats from other networks into one chat list, and
adds private messages with anyone on Nostr. Everything from the earlier
October 8 nightlies is included.

### Before you update

- Nothing changes until you turn something on: Conest chats stay as they
  are.

### Chats from other networks in one list (new)

- Matrix chats, Nostr chats and bitchat chats (the mesh chat and private
  chats with bitchat users nearby) now sit in the chat list beside your
  Conest chats, each marked with its network.
- Each network gets a filter chip above the list. Settings → Connectivity
  → **Chats from other networks** hides a network's chats from the list
  (they stay in that network's settings).

### Nostr private messages (new)

- Settings → Connectivity → **Nostr private messages** lets you chat with
  anyone on Nostr in apps that use private messages (NIP-17), such as
  0xchat and Amethyst, one to one or in small groups with a title.
- It uses a Nostr account of its own: your Conest contacts and your
  Conest Nostr route are not linked to it. Copy your address (npub, with
  your relays) to give it to people; start a chat with someone's npub, or
  several for a group.
- Messages are end-to-end encrypted, and relays see neither who wrote
  nor when, but there is no forward secrecy.
- Chats from strangers are requests: few, kept short, and the oldest go
  first, until you reply. A deleted chat stays deleted.
- Someone whose app has not published where it reads private messages
  cannot be written to yet; Conest says so instead of sending into the
  void. A profile you paste with relays (nprofile) is used for them.
- Files sent from other apps show as a note (open them in that app).
- Not available in Matrix-only mode.

### Not tested on devices yet

- Nostr private messages with 0xchat, Amethyst and Damus.
