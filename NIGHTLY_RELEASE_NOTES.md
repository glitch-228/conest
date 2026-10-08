## Conest 0.3.12 nightly (October 8, second build)

This nightly finishes Conest's side of bitchat, the Bluetooth messenger
on iPhone and Android: you can now chat with bitchat users nearby, and
lend them your internet for bitchat's location channels. Everything from
this morning's 0.3.12 nightly is included.

### Before you update

- All of this needs the Bluetooth mesh (Settings → Connectivity →
  Bluetooth mesh), which works on Android only for now.
- Without the new settings nothing changes: this phone stays invisible to
  bitchat users, as before.

### bitchat chats (new)

- Settings → Connectivity → Bluetooth mesh → **bitchat chats** shows the
  mesh chat (what everyone in Bluetooth range writes) and private chats
  with bitchat users nearby. You can always read the mesh chat.
- **Reachable by bitchat users** lets bitchat users see this phone and
  write to it:
  - they see a name you choose, or "anon" and four digits;
  - private messages both ways, with delivered and read marks;
  - you can write in the mesh chat; long text goes as several messages
    (up to about 450 characters in all);
  - the identity they see is separate from your Conest identity and is
    new every week, or when you tap **New identity**. A name you choose
    yourself stays the same, so people can tell it is still you.
- Messages in the mesh chat are signed by their authors and checked, so
  nobody can write under someone else's name. They are not encrypted:
  everyone nearby can read them. Private chats are encrypted between the
  two phones.
- Strangers writing too much are cut off, and the mesh chat keeps only
  the last 200 messages of the past week.

### Share internet with bitchat users (new)

- With **Share internet with bitchat users** on (it needs "Reachable by
  bitchat users"), bitchat phones nearby that have no internet can use
  bitchat's location channels through yours: their messages go to the
  relays, and new messages in those channels come back to them.
- Only those public, signed channel messages pass, a few a minute per
  phone. Your phone connects to the relays of the areas the phones nearby
  use, so those relays see your internet address.

### Groups

- Members of a group who are not each other's contacts now reach each
  other over the Bluetooth mesh too.

### Not tested on devices yet

- Chatting with the bitchat iOS and Android apps, and the gateway with an
  iPhone in airplane mode.
