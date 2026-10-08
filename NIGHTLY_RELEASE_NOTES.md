## Conest 0.3.12 nightly (October 8)

This nightly fixes what testers reported after 0.3.11: adding and removing
contacts now recovers from lost messages, albums no longer hang at 100%, and
the photo picker shows your whole library. It also adds Saved messages,
contacts that can be added over Nostr, email, Matrix or Tor, and makes group
chats work like direct chats in all of this.

### Before you update

- Contacts on 0.3.11 keep working. A few fixes need both sides on this
  nightly: answering a repeated contact request, adding each other over a
  carrier, and group file receipts.
- Group members still on 0.3.11 learn other members' new routes only when
  the member list changes, as before.
- Invites now carry your routes for blocked networks (see below). For
  someone still on 0.3.11, turn on **Legacy invite** on the invite screen.

### Contacts

- **Lost messages no longer break adding or removing contacts:**
  - an acceptance that never arrived is given again when the request
    repeats, and a message from the other side counts as acceptance;
  - a decline or a removal that never arrived is repeated when the other
    side writes again;
  - you can add someone again after removing them, or after they removed
    you; the chat history is kept;
  - two people adding each other at the same time are both accepted.
- **Routes you turn on later reach your contacts:** when you enable Nostr,
  email, Tor or another route, contacts that were offline learn it the next
  time you are in touch.
- **Extended invites:** with Nostr, email, Matrix or Tor on, your invite
  (QR code, text and Beam) also lists those addresses, signed. Someone with
  only that network in common (no relay, no shared Wi-Fi) can add you and
  chat. A long invite is shown as Beam (an animated QR) first; the
  codephrase works as before.
- On email and Tor the sender of a request cannot be verified by the
  network; as with any request, the signed invite decides who it is.

### Saved messages

- A chat with yourself, pinned at the top of every chat list: notes,
  files, photos and voice notes, kept only on this device.
- **Forward** any message or file into it (it is first in the forward
  list), including group messages and group files.

### Groups

- A contact who removed you, or who has not accepted you yet, still
  reaches you in groups you share.
- **Group files:**
  - the sender sees who has the file: each member's device confirms when
    it has it;
  - files you already have open straight away after a restart, even when
    nobody else is online;
  - downloaded photos show a preview;
  - group files can be forwarded.
- Members who are not each other's contacts can reach each other over
  Nostr and Tor too. Email and Matrix addresses name you, so they are
  shared with group members only if you turn on Settings → Connectivity
  → **Share email and Matrix addresses with group members**.
- When a member turns on a new route or changes a setting, the other
  members learn it (before, only a change to the member list did that).
- Two members who meet in a group can add each other as contacts over a
  carrier, even when the group already knows a route to them.
- Your own group messages show the route that carried them.

### Files and photos

- **Albums no longer hang at 100%** with a pause button after the other
  side has them. A lost "received" notice is sent again, and older
  versions are recognised too.
- **Photo picker:**
  - scrolls through your whole library (it stopped at 60 items before);
  - lets you switch albums;
  - shows thumbnails faster;
  - prepares the photos you send in parallel, with a counter;
  - on Android 14, when you shared only some photos, offers "Select more" or
    "Allow all";
  - also opens in group chats.
- Files on slow Iroh routes move in 1 MiB blocks, so progress is smoother.

### Passing messages on through a contact

- When you cannot reach someone but a mutual contact can, that contact can
  carry your messages on, if they turned on **Carry their messages** for you
  in your contact's connectivity settings. They see only that a message for
  that person passed through, never what it says.

### Networks

- **Nostr:** relays that ask to sign in are now read correctly. A relay
  turns green only while it actually delivers your messages. Damus
  currently refuses every sign-in on its side, and its row says so.
  relay.0xchat.com no longer exists: new setups use nos.lol,
  relay.primal.net and nostr.mom, and setups that listed 0xchat move to
  relay.primal.net.
- **Email:** turning email on retries when the network drops the
  connection.
- **Tor:** bridge lines must start with their type ("obfs4 …", webtunnel,
  snowflake, meek_lite) or be a plain address and fingerprint; a wrong line
  is refused with its number.
- Network errors are shown in plain words instead of raw socket messages.

### Security

- Retried messages reuse the first encrypted copy, and an identical late
  copy is acknowledged without being decrypted again. Before, a duplicate
  arriving after a restart could reset the forward-secret session.

### Updates

- Settings → **Receive unstable updates** decides whether a stable install
  is offered nightlies; a nightly can always move back to stable.

### Not tested on devices yet

- Pairing and chatting over Nostr, email and Tor alone; contact recovery
  between phones; the photo picker on Android 14 and Android 10; group
  receipts and previews on real phones.
