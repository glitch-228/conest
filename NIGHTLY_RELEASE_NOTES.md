## Conest 0.4.3 nightly (October 29)

The first nightly after v0.4.2. Everything in v0.4.2 is included.

### Before you update

- Contacts on v0.4.2 and older keep working. Newer features (files over
  two routes at once, files through your own devices, relay sessions)
  are used only with contacts and relays that have them.
- Relays: this version adds a new relay protocol. Older relays still
  work. Relays that update themselves move to it on their next
  maintenance hour.
- On relays running this version, your mailbox belongs to your device,
  and your contacts' apps vouch for it, so nobody else can take it over.
  Contacts still on v0.4.2 or older do not do this yet, so their
  mailboxes on such relays are not protected until they update. Please
  ask your contacts to update.

### Calls

- Group calls stay one call on slow networks. Before, members who
  heard the host late could start a second call of their own, and the
  two never joined again.
- Fixed: in group calls, sound from one member could reach only the
  first other member and nobody after them.
- Sound that arrives too late to play is dropped instead of piling up.

### Voice settings

- New: Settings > Voice, with:
  - your microphone and speaker;
  - microphone and speaker volume;
  - a microphone test with a level meter, and optionally hearing
    yourself;
  - voice activity (with a sensitivity setting) or push-to-talk, in
    one-to-one and group calls;
  - noise suppression, echo cancellation and automatic volume, each on
    or off;
  - call sounds on or off.
- In group calls you can change each person's volume, for you only.

### Notifications

- Quiet hours: pick a start and end time. Notifications still appear,
  without sound or vibration. Calls can still ring.
- Mute a chat or group for 1 hour, 8 hours, 1 day, or until you unmute
  it.
- Groups: mention people with @. A group can notify you for every
  message, only for mentions (a reply to your message counts), or not
  at all.
- Android: groups, calls and file transfers have their own notification
  categories, so each can have its own sound in the phone's settings.
- Android: an incoming call shows full screen, also on the lock screen,
  with Answer and Decline.
- Linux: Reply and Mark as read straight from a notification.

### Files

- A file to a contact can travel over the local network and over Iroh
  at the same time. Each route gets a share that fits its speed. If one
  route stalls, the other takes over.
- Group files are downloaded faster from members who send faster. A
  piece that is late is also asked from someone else.
- Large group files come over the local network without asking first.
  Over Iroh, relays and Tor they still wait for you to accept them.

### Your own devices

- Files you send or receive on one device now show on your other
  devices too. They fetch the file from whichever of your devices has
  it.
- Older history fetched from another of your devices now includes its
  files, which you download when you want them.
- A device that was away catches up faster: your devices compare what
  each has and send only what is missing.

### Relays and censored networks

- Relays now use an encrypted session and send new messages to you as
  soon as they arrive, instead of waiting for Conest to ask.
- A relay can have an address on port 443 that looks like an ordinary
  website. Visitors without the key see that website. Relay owners can
  also hide a relay behind a real site's secure connection.
- Relay owners can require registration, an invite code or a password
  before others use the relay for more than messages.
- New: Settings > Censorship circumvention:
  - private name lookups (DNS over HTTPS);
  - splitting secure-connection greetings, which hides from simple
    filters which server you connect to;
  - quiet nearby-device discovery, which finds devices on your network
    with a scrambled signal instead of a recognisable one.
  "Automatic" turns these on only on networks where Conest is blocked.

### New networks

- XMPP (Jabber):
  - Conest can carry its messages through an XMPP account, either one
    it makes for you on a public server or your own. Your other XMPP
    apps do not see these messages.
  - XMPP chats: chat with people on XMPP apps such as Conversations,
    Dino, Gajim or Monocles, in one-to-one chats and group chats, with
    files, replies, reactions and corrections.
  - OMEMO encryption for XMPP chats, with keys you can verify by QR
    code. Older OMEMO, used by many current apps, is off by default and
    marked experimental.
  - An "XMPP only" mode.
- Telegram: Conest can carry its messages through a Telegram bot you
  make with @BotFather. The Telegram client itself is not in this
  nightly yet.
- Discord:
  - Conest can carry its messages through a Discord bot you make, in a
    private server you share with your contact.
  - Optional: use your own Discord account in Conest, as Vencord and
    Vesktop do. This is against Discord's terms and can get your account
    banned. Conest says so before you turn it on.
  - A "Discord only" mode.
- Conest still encrypts its messages end to end through all of these.
  The network can see who is talking to whom, and when.

### Please check

- A group call with three people on different networks: one call, and
  everyone hears everyone.
- Settings > Voice: switching microphone and speaker, the microphone
  test, push-to-talk.
- Quiet hours, muting for a while, and @mentions in a group.
- Android: an incoming call on a locked phone.
- Linux: replying from a notification.
- A large file to a contact on the same network with Iroh on.
- A file sent on one of your devices showing on another.
- Relays: messages arriving promptly; a relay's port-443 address on a
  censored network.
- XMPP chats with Conversations or Dino, with and without encryption.
- Telegram and Discord bot carriers between two contacts.
