## Conest 0.3.11 nightly (October 5)

This nightly adds LoRa radio meshes as ways to reach contacts with no
internet at all: Reticulum, Meshtastic and MeshCore.

One firmware cannot listen to all three networks at once (a LoRa chip hears
one frequency and setting at a time, and the three differ), so Conest
talks to each radio's own firmware; you can attach several radios.

### Reticulum (new)

- Turn it on in **Settings → Connectivity → Reticulum** and choose how to
  reach a Reticulum network:
  - **Node (rnsd):** a computer or Raspberry Pi running rnsd with a TCP
    server interface (port 4242 by default), for example the one your RNode
    is attached to;
  - **RNode on USB:** the radio plugged into this computer (Linux, macOS)
    or phone (Android asks to allow the USB device);
  - **RNode on Bluetooth** (Android): scan for the radio and pick it;
  - **RNode on Wi-Fi:** a radio that offers its serial protocol over the
    network.
- For an RNode, set the same frequency, bandwidth and spreading factor as
  the Reticulum network you join (presets for EU 869.525 MHz and
  US 914.875 MHz). In the EU, Conest asks the radio to keep to the legal
  airtime limit.
- When no other route reaches a contact who also has Reticulum on, messages
  travel over Reticulum, through other Reticulum nodes if needed. They stay
  end-to-end encrypted by Conest and again by Reticulum.
- Conest keeps a Reticulum identity of its own, separate from your Conest
  identity, and a random destination name: the network does not see that
  you use Conest. Your contacts learn your Reticulum address automatically.
- A node on the internet follows the **Online** switch; a radio or a node
  on your own network keeps working with Online off.
- Over a radio, only messages and small updates go (up to 4 KiB each,
  paced for airtime); files never do.
- Messages that came over Reticulum carry a teal **Reticulum** route mark.
- Not yet: the compact message form for slow LoRa settings, and Bluetooth
  radios on desktop.

### Meshtastic (new)

- **Settings → Connectivity → Meshtastic:** attach your Meshtastic radio by
  USB, or reach one on your network (its TCP API, port 4403).
- Conest sends its messages as direct messages on a private application
  port, which current Meshtastic firmware encrypts with the two radios'
  keys; inside, they stay end-to-end encrypted by Conest. Your Meshtastic
  apps do not show them.
- Contacts learn your radio's node number automatically. Messages that came
  this way carry a green **Meshtastic** route mark.
- Not yet: Meshtastic radios over Bluetooth.

### MeshCore (new)

- **Settings → Connectivity → MeshCore:** attach your MeshCore companion
  radio by USB, or on Android over Bluetooth.
- Conest adds your contacts' radios to your radio's contact list (named
  "Conest …"), since MeshCore radios only accept messages from contacts.
  Messages travel as MeshCore's encrypted command data, which the radio does
  not show on its screen.
- Messages that came this way carry a yellow-green **MeshCore** route mark.

### All radios

- Over LoRa only messages and small updates go (up to 4 KiB each), paced
  for airtime; files never do. Long messages take a while on slow settings.

### Qualification

- The full local test suite passed, including new tests:
  - Reticulum framing, packets, encryption, announces (freshness, replays),
    path requests and answers, overlapping sends;
  - the RNode protocol against simulated radios (detection, settings, other
    channels unheard);
  - two devices talking over a Reticulum network, after a restart, and
    with Reticulum turned off again;
  - the Meshtastic client protocol (protobuf, framing among debug text,
    configuration handshake) and two devices talking over a simulated mesh;
  - the MeshCore companion protocol, radios refusing unknown senders until
    Conest adds the contact, and two devices talking over a simulated mesh.
- Interoperability with the official Reticulum (Python RNS 1.5.6): announces
  and encrypted packets both ways, and two Conest devices reaching each other
  through a Python transport node; also in the remote debug workflow.
- The Meshtastic client against the real firmware (meshtasticd 2.7.26 in
  simulation) in the remote debug workflow.
- Independent reviews of the Reticulum, Meshtastic, MeshCore and Android
  radio code were done and their findings fixed.
- Not yet tested on real devices:
  - Reticulum through a real node and over RNode radios on USB and
    Bluetooth; Meshtastic and MeshCore radios;
  - Nostr and email from the previous nightlies, and everything still
    pending from earlier nightlies.

This nightly is prerelease software; keep important data backed up and
report failures with the build identifier and a debug snapshot.
