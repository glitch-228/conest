# Reaching people

Conest has no central server. Each message travels over one of several
routes, and Conest picks the ones that work between you and each
contact. Both of you need a route turned on for it to be used.

## The routes

On by default:

- **LAN**: devices on the same Wi-Fi or network reach each other
  directly.
- **Iroh**: direct internet connections, or through Iroh's public relays
  when a direct connection is not possible.
- **Conest relays** you add (Settings > Relays): servers that hold
  messages for you while you are offline.

Turned on in Settings > Connectivity (or offered when you set up):

- **Nostr**: public Nostr relays carry your messages, encrypted.
- **Email**: a free chatmail account, created for you, or your own
  mailbox.
- **Matrix**: through a Matrix account you sign in to.
- **Tor**: onion services, for networks that watch or block traffic. See
  [Tor bridges](tor-bridges.md).
- **Bluetooth mesh**: phones and computers nearby, with no internet at
  all (Android, Linux and Windows).
- **Reticulum, Meshtastic, MeshCore**: LoRa radios, for long distances
  without the internet.

Every route carries messages end-to-end encrypted by Conest: the relay,
mail server or radio network only sees encrypted data.

## Which to turn on

Turn on at least one way over the internet, and preferably three
different ones: networks often block some routes and not others, and
Conest uses whichever still works. The setup step and the banner above
the chat list tell you when only devices on your own network can reach
you.

Files travel over LAN, Iroh, Conest relays and Tor. Nostr, email,
Matrix, radios and the Bluetooth mesh carry messages only.

Some routes cost more battery or data than others: email checks a
mailbox, and Tor keeps a circuit open.

## On networks that block things

Conest is built to keep working where networks are censored or
unreliable:

- New email accounts go to whichever of 20 public chatmail servers
  answers fastest where you are, also over port 443 when mail ports are
  blocked.
- New Nostr setups use the relays that answer fastest where you are.
- When Tor is blocked, its settings say so and show how to get your own
  bridges.
- A message waits and is retried over another route if the first one
  fails, and a contact you share can carry messages for someone you
  cannot reach yourself (if you both allow it).
- The Bluetooth mesh and radios work with no internet at all.

What a network blocks can change by the minute. If something stops
working, turning on one more route usually helps.

## Seeing how a message travelled

In Advanced mode each message shows small route dots, and Message info
lists every route it went over and when it arrived.
