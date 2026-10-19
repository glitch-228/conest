# Troubleshooting

## Messages do not arrive

- Check that both of you have a route in common turned on (Settings >
  Connectivity). If only LAN is on, people outside your network cannot
  reach you; the banner above the chat list says so.
- Turn on one more way over the internet: Nostr and email are a tap
  each. See [Reaching people](reaching-people.md).
- A message that could not go is retried, over another route if one
  works. The tick marks show its state: sent, delivered, read.

## "Conest closed unexpectedly last time"

Conest says so on the next start after it closed without finishing: a
crash, or the system ending it. Tap Details to see what happened, and
Copy to put it in a bug report. Nothing is sent anywhere unless you do.

## Bluetooth mesh on Linux

Conest's Bluetooth mesh works with BlueZ. Older Conest versions made
BlueZ 5.87 crash while they looked for nearby devices, which also
dropped headphones and other Bluetooth devices; update Conest if that
happens.

## Email

Some networks block or slow down mail servers. Conest picks a server
that answers where you are, but delivery can still stall on such
networks; another route (Nostr, Tor, a Conest relay) helps then. A mail
server that refuses more connections is left alone for ten minutes.

## Tor does not connect

Tor is blocked on many networks. Add your own bridges: see
[Tor bridges](tor-bridges.md).

## Windows: devices nearby cannot reach this computer

Windows Firewall may be blocking them. Open Settings > Connectivity and
use "Let devices on this network reach this PC"; Windows asks you to
confirm.
