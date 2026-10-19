## Conest 0.3.12 nightly (October 19)

Conest now works far better on networks that block things: new
contacts can be added over the Bluetooth mesh or Reticulum alone, email
and Nostr pick servers that work where you are, and a new setup step
helps you set up ways to reach people beyond your own network. Messages
are no longer lost when a secure session has to be renewed.
Everything from the earlier October nightlies is included.

### Fixes

- No more lost messages after a delay: a message held up on the way
  (for example by a relay) could arrive too late to be decrypted and
  was lost. It is now sent again at once on a fresh secure session.
- Linux: Conest no longer makes the system's Bluetooth service crash
  while it looks for nearby phones (a bug in BlueZ 5.87), which also
  dropped headphones and other Bluetooth devices every few seconds.
  If you use the Bluetooth mesh on Linux, please update.
- Email: a mail server connection that stalls is given up on quickly,
  failed connections are closed at once (servers stopped refusing new
  ones), and sending works with servers that reject the old greeting.
- Nostr: a message counts as sent as soon as one relay stored it, so a
  slow relay no longer holds every message up.
- Reticulum: the connection status shows whether the node is actually
  connected, and a restarted connection is announced so contacts can
  reach this device again straight away.
- Relays: an address a network answers with 0.0.0.0 is skipped.
- Albums: single files can be selected, and albums and files have a
  right-click menu again.
- Android: ending a transfer from the notification while Conest is in
  the background no longer crashes it.

### New

- Contacts can be added over the Bluetooth mesh alone, and over
  Reticulum alone, without any internet route. Requests over the mesh
  go to an inbox only people with your invite can find; it changes every
  week.
- A setup step after choosing how much of Conest to show: it checks
  which ways to reach people beyond this network work here (Iroh,
  relays, Nostr, email), offers the ones that work, and recommends at
  least three. If none is set up, the chat list says that only devices
  on this network can reach you.
- Email (chatmail): a new account goes to whichever of 20 public
  chatmail servers answers fastest where you are, also on port 443 when
  mail ports are blocked. Leave the server empty to choose
  automatically.
- Nostr: a new setup uses the relays (of eight checked ones) that answer
  fastest where you are.
- Tor: when Tor looks blocked, its settings say so and show how to get
  your own bridges from the Tor Project (website, Telegram bot, email),
  since the public ones are often blocked too.
- Add a group member as a contact, from the group's member list.

### Tested on devices

Android, Linux and Windows added each other and exchanged messages and
group messages over each of these alone: Conest relay, Iroh, Nostr,
Matrix, Reticulum and the Bluetooth mesh.

### Not tested on devices yet

- Email on networks that block or throttle mail servers: setting up an
  account can still fail there, and delivery can stall.
- The new setup step on phones, and in every language.
