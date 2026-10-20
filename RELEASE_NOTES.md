# Conest v0.4.0

Conest now keeps working on networks that block things, runs on several
devices under one account, sends each message over several routes at
once, holds group calls, and talks to Delta Chat, Nostr, Meshtastic,
MeshCore and bitchat users. It also comes in six languages, with three
modes from simple to advanced. Everything tested in the v0.3.12 nightlies
is included.

New to Conest, or not sure which routes to turn on? Read the user guide:
https://github.com/glitch-228/conest/tree/main/docs

## Before you update

- Update both sides. Most of what is new (several devices, several
  routes per message, group calls, adding contacts over the Bluetooth
  mesh) needs this version on both ends. Contacts on v0.3.11 keep
  working over the routes they had.
- An existing install stays in Advanced mode and keeps its settings.
  New routes stay off until you turn them on.
- Update all of your linked devices together: syncing works only
  between devices on this version.

## Reaching people on blocked networks

- A setup step checks which ways to reach people work on the network
  you are on (relays, Iroh, Nostr, email) and offers to turn them on. At
  least one is needed and three are recommended; until one works, the
  chat list says that only devices on your network can reach you.
- Email picks whichever of 20 public chatmail servers answers fastest
  where you are, also over port 443 when mail ports are blocked.
- Nostr uses the relays that answer fastest where you are.
- Tor says when it looks blocked and shows how to get your own bridges
  from the Tor Project.
- Contacts can be added over the Bluetooth mesh or Reticulum alone, with
  no internet at all.
- When you cannot reach someone but a mutual contact can, that contact
  can carry your messages (if you both allow it). Group messages reach
  members through other members the same way.
- Conest remembers what worked on each network it has been on, and tries
  routes a network blocks last.

## Delivery

- Messages go over several routes at once: on mains power all of them,
  on battery one more every few seconds until one is confirmed. Once a
  message is confirmed, it is not sent again anywhere.
- Message bubbles show a dot for each route a message took, and message
  details (also in groups) list every route, member and time.
- No more lost messages when a secure session has to be renewed, or when
  a relay connection is slow.
- Relays: messages held on a relay come back sooner after a lost
  connection, and slow links get more time.
- Removing someone from a group no longer leaves your earlier messages
  waiting for them.
- Group files reach members that only a relay or Tor reaches, as files
  in one-to-one chats do.
- Read marks work again on Windows, Android and Linux.
- Messages that went only one way (often a firewall) now try another
  route. On Windows, Settings > Connectivity can let devices on your
  network reach this PC.

## Several devices on one account

- Link a phone and a computer under one account (Settings > Devices).
  Contacts reach all of your devices.
- Messages you send, notes in Saved messages and read marks show on all
  of your devices.
- A device linked less than a day ago cannot add or remove others; any
  device can remove a lost one. A device out of touch for a week stops
  syncing until you confirm it.

## Chats and calls

- Group voice calls, with noise suppression for every call (still
  experimental, off by default).
- Saved messages: a chat with yourself for notes, files and forwards.
- Forward several messages at once, whole albums, and voice messages.
- Contact requests and removals survive lost messages, and a removed
  contact can be added again.
- Add a group member as a contact from the group's member list.
- Photos, videos, PDFs and office files lose their location, camera,
  author and date details before sending; file names can be random
  (Settings > Personal).
- Android: Conest is in the share menu, and you can paste images.
- Links in messages are underlined and open in your browser. An address
  that uses letters from other alphabets (and may imitate a site you
  know) asks first.

## On computers

- Enter sends and Shift+Enter starts a new line (Settings > Personal
  can switch it back; then Ctrl+Enter sends).
- A click on a message is for selecting its text and opening its links;
  the message menu opens on a right click, and offers to copy the text
  you selected.
- Holding the space beside a message selects it, as before; holding the
  message itself no longer does.
- Ctrl+V pastes into the open chat wherever you clicked in it.
- Windows: pasting a screenshot (Win+Shift+S) or another copied image
  works again.
- LAN: when another app (often a second Conest) holds this computer's
  LAN port, Conest moves to a free one and tells your contacts.

## Other networks in one chat list

- Delta Chat: chats one to one and in groups through your email account,
  with files, reactions and edits.
- Nostr private messages with users of other Nostr apps.
- Messages with Meshtastic and MeshCore app users through your radio.
- bitchat: read the mesh chat, and, if you choose, chat with bitchat
  users nearby.
- Matrix: verify people in direct chats by emoji.

## Look and feel

- Choose Simple, Standard or Advanced mode (Settings > Personal).
- Arabic, Persian, Indonesian, Russian and Simplified Chinese, made with
  AI; help improve them on Weblate.
- Settings are split into pages: a sidebar on wide windows, a list on
  phones.
- Turning a way to reach people off (email, Nostr, Tor, Reticulum, the
  Bluetooth mesh) pauses it and keeps your address there; "Remove"
  forgets it. Email shows the account in use and can change it.
- Bluetooth mesh on Linux and Windows computers.
- If Conest closes unexpectedly, the next start says so and lets you
  copy the details for a bug report. Nothing is sent anywhere. An update
  restart no longer counts as a crash.
- Run your own relay: install-relay.sh sets one up in a few questions.

## Not tested on real devices yet

- Group calls with more than three people.
- Delta Chat, Nostr, Meshtastic, MeshCore and bitchat chats with the
  other apps.
- Syncing between linked devices over a day or more.

Please report problems with your build version and the crash or debug
details from Settings.

## Known limits

- Email can stall on networks that block or throttle mail servers; other
  routes keep working.
- Several devices: messages received while only one of your devices
  could be reached, files, voice messages, groups and settings do not
  sync between your devices yet.
- Radios and the Bluetooth mesh carry messages only, never files.
