## Conest 0.3.11 nightly (October 4, second build)

This nightly adds the first of five new ways to reach contacts when the usual
routes are blocked: Nostr relays.

### Nostr relays (new)

- Turn it on in **Settings → Connectivity → Nostr relays**. Conest then
  carries messages through public Nostr relays whenever LAN, Iroh and Conest
  relays cannot reach a contact. Both of you need it on.
- Messages stay end-to-end encrypted by Conest. Relays see that someone
  writes to your Nostr key and when, but not who writes or what. Each message
  is signed by a one-time key.
- Conest makes a separate Nostr key for this; it is not linked to your
  identity or to any Nostr account. Your contacts learn it automatically.
- Choose up to four relays to read from (three public relays by default). A
  coloured dot shows whether each one is connected. Relays that ask for a
  sign-in (NIP-42) are supported.
- Messages that came over Nostr carry a purple **Nostr** route mark.
- Files are not sent over Nostr; only messages, receipts and other small
  updates are.

### Under the hood

- A shared carrier layer now serves Matrix and every new route: email,
  LoRa radios, Bluetooth mesh and Tor follow in the next nightlies.
- Transport settings list only routes this build can use. Saved Email and
  Reticulum placeholders reset to their new defaults once.

### Qualification

- The full local test suite passed, including new tests:
  - the official BIP-340 and NIP-44 test vectors;
  - Nostr frames between two devices, an inbox relay that requires sign-in,
    a relay dropping its connections, stored messages read after a restart;
  - two devices talking over Nostr while Conest relays fail, with the route
    mark, and Nostr turned off again;
  - carrier framing limits, address exchange (newer wins, removal), policy
    gating and file chunks kept off message-only carriers.
- The remote debug workflow ran the Nostr carrier against two real relay
  implementations (nostr-rs-relay and strfry).
- Not yet tested on real devices:
  - Nostr on phones and desktops, public relays from restricted networks;
  - everything still pending from earlier nightlies.

This nightly is prerelease software; keep important data backed up and
report failures with the build identifier and a debug snapshot.
