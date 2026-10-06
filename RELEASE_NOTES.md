# Conest v0.3.11

This release brings everything tested in the v0.3.11 nightlies:
- forward-secret encryption between updated devices;
- a full Matrix client;
- nine new ways to reach contacts when the usual routes are blocked or
  there is no internet at all: Matrix, Nostr, email, LoRa radios
  (Reticulum, Meshtastic, MeshCore), a Bluetooth mesh with nearby phones,
  and Tor with bridges;
- a new icon.

## Before you update

- **Update both sides.** Forward secrecy and every new route need updated
  devices at both ends. Contacts on v0.3.10 keep the previous encryption and
  keep working over LAN, Iroh and Conest relays.
- **New routes are off until you turn them on**, under **Settings →
  Connectivity**. Both you and a contact need a route on for it to carry
  your messages.
- **Moving back to v0.3.10** switches forward secrecy off for your contacts;
  nothing is lost.

## Privacy

- **Forward secrecy.** Between updated devices, messages, edits, reactions,
  receipts, group updates and call signaling travel in forward-secret
  sessions. They use the Double Ratchet from vodozemac, the audited library
  Matrix uses.
  - If a device's keys are stolen later, traffic recorded earlier cannot be
    decrypted.
  - Sessions start on their own once both devices have updated.
- **Group files** between updated devices use keys that change daily. Each
  call gets its own key.

## Matrix

- **Use Conest as a Matrix client.** Under **Settings → Connectivity → App
  mode**, choose:
  - **Conest**;
  - **Both**: Conest and Matrix chats side by side, with filters;
  - **Matrix**: a plain Matrix client that needs no Conest identity.
- **Sign in** with a password, or through your browser for single sign-on
  accounts (Google, GitHub and others).
- **Verify** your other Matrix sessions with emojis, and set up recovery.
- **Rooms** show their members, replies and quotes. Joins and leaves are
  optional.
- **As a route:** with both of you signed in, Conest messages that LAN and
  Iroh cannot deliver travel through Matrix. They stay end-to-end encrypted
  by Conest, and Conest uses its own Matrix device, so nothing appears in
  your other Matrix apps.

## New ways to reach contacts

Every route below carries messages end-to-end encrypted by Conest. Messages
show a route mark telling how they travelled.

- **Nostr relays:** over the internet. Relays see that someone writes to
  a throwaway key, not who.
- **Email:** through a free chatmail account Conest creates, or your own
  mailbox. Mail is OpenPGP-encrypted; the mail server sees the two
  addresses.
- **Reticulum:** through a node (rnsd), or an RNode radio on USB, Bluetooth
  or Wi-Fi. Works with no internet at all.
- **Meshtastic and MeshCore:** through a radio on USB or Bluetooth. Works
  with no internet; messages only, never files.
- **Bluetooth mesh (Android):** messages hop phone to phone, through bitchat
  users too. Your phone does not show up in bitchat.
- **Tor:** each device gets an onion address. Add obfs4, webtunnel,
  snowflake or plain bridges where Tor is blocked.

Files travel only over routes built for them: LAN, Iroh, Conest relays and
Tor.

## Delivery

- **Route choice:** Conest remembers which routes worked for each contact
  and how fast. A route that just failed waits behind working ones, and the
  faster of similar routes goes first. Tor is tried after faster routes.
- **Moving between networks:** when you and a contact end up on the same
  Wi-Fi, chats move onto it by themselves. Conest tells contacts its new
  local address, and tests local paths while Iroh works.
- **File transfers over Iroh** no longer stall, jump and show "reconnecting"
  over and over.
- **The 100 MB Iroh limit** is respected again.
- **The message box empties as soon as you press Send**, so you can type the
  next message while the last one is on its way.
- **An offline contact** no longer slows everything else down.

## Chats and calls

- **Contact requests:** adding a contact sends a request the other person
  accepts or declines. Messages wait until then.
- **Voice calls**, still marked experimental, open in a full-window call
  screen that you can minimize. Settings can turn them off.

## New icon

- A new Conest icon on every platform. On Android 13 and newer it follows
  your theme colours, and notifications show the Conest mark.

## Not tested on real devices yet

These were tested in automated runs, but not yet between real devices:
- **Radios and the Bluetooth mesh:** Reticulum, Meshtastic and MeshCore
  radios; the Bluetooth mesh between phones and next to the bitchat app.
- **Restricted networks:** Tor and bridges, and public Nostr relays and
  chatmail from a censored network.

Please report problems with your build version and a debug snapshot from
Settings.

## Known limits

- **Tor:** your onion address stays the same until you turn Tor off, and
  your contacts know it.
- **Radios and the Bluetooth mesh** carry messages and small updates only,
  never files.
- **iPhone:** bitchat users on iPhone cannot message Conest users yet. They
  can still relay Conest messages through the mesh.
