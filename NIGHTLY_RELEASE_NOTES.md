## Conest 0.3.12 nightly (October 13, second)

This nightly can send each message on several routes at once, and fixes
messages that went only one way. Everything from the first October 13
nightly (Delta Chat, files without metadata) is included.

### Before you update

- Messages go on several routes only to contacts who have this nightly
  too. With everyone else, Conest sends as before.

### Messages on several routes (new)

- On mains power and an unmetered network, a message goes out on every
  route at once, for example LAN, Iroh and a relay. Your contact sees it
  once, whichever copy arrives first.
- On battery, Conest sends on the best route first and adds another every
  few seconds until the message is delivered. In battery saver it uses one
  route at a time, as before.
- Message details (in the message menu, now in groups too) list every
  route a message took or arrived by, with times. In a group they show each
  member, the routes that reached them and when they read it. For files,
  they show how much came over each route.
- Message bubbles show a dot for each route: filled when the message
  arrived that way, hollow while it is still on its way.
- In a contact's profile, Test Routes sends a small test over each route
  and times the answer. Routes that do not answer are used last.
- On mains power Conest also watches a second relay, so a message left on
  either one arrives quickly.
- Meshtastic: message details show when the other device's radio
  confirmed the message, and copies still going out by radio stop once the
  message has arrived another way.

### Fixes

- Messages that went only one way (seen between Windows and a phone's
  hotspot): a route that takes messages but never brings back a receipt
  now gives way to another after about 8 seconds.
- Windows: Settings → Connectivity → Let devices on this network reach this
  PC adds a Windows Firewall rule for Conest (Windows asks first).
- Invites always include an internet route when one is on, and say so when
  none is.
- Android: Conest is in the share menu (files, photos, text). Images can be
  pasted into a chat, including images and GIFs from the keyboard.
- The gallery no longer shows hidden folders, or folders marked to stay out
  of galleries.
- Scrollbars in chats keep their size while you scroll.
- Using the window now counts as reading the chat, which should fix
  messages not being marked read on Linux.
- Photos in Saved messages are kept exactly as they are.
- Meshtastic: messages to Meshtastic app users now show as delivered when
  the other radio confirms them (those confirmations were being missed).

### Not tested on devices yet

- The share menu and pasting on Android.
- The Windows Firewall rule.
- Messages on several routes between phones on battery.
- Read marks on Linux.
