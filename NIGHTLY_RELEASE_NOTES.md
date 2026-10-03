## Conest 0.3.11 nightly (October 3, third build)

This nightly lets you choose what Conest is: a Conest messenger, a Matrix
client, or both. It also shows how every message travelled.

### App modes (experimental)

- Under **Settings → Connectivity → App mode**, pick:
  - **Conest**: Conest chats only. Matrix can still carry Conest
    messages as a fallback.
  - **Both**: Conest and Matrix chats side by side.
  - **Matrix**: Conest as a plain Matrix client.
- **Matrix only** needs no Conest identity. On first launch, choose **Use
  as a Matrix client instead** to skip creating one.
- If you already have a Conest identity, Matrix only switches Conest off on
  this device:
  - Nothing is deleted.
  - Conest stops connecting over LAN, relays and Iroh until you switch
    back.
  - Your contacts' apps keep retrying, and their messages arrive when you
    switch back.
  - Switching is not possible during a call.
- In **Both** mode the chat list has **All chats**, **Conest** and
  **Matrix** filters.

### How each message travelled

- Sent and received messages now carry a coloured mark for the route they
  took:
  - **LAN direct** or **LAN relay** (through another device);
  - **LAN lobby**;
  - **Internet direct**;
  - **Iroh direct** or **Iroh relay**;
  - **Conest relay**;
  - **Matrix** (still encrypted by Conest);
  - **Plain Matrix**.
- The marks show in every layout; the Telegram-style layout uses a dot and a
  short name.
- Older messages show the route they were sent on, where it was recorded.
- **Settings → Connectivity → Message routes** explains each mark.

### Reaching a contact through Matrix

- When a contact cannot be reached over Conest but has linked their Matrix
  account, a message waiting to be sent shows an **@** button and **Send via
  Matrix…** in its menu.
- Conest asks every time before sending. The message goes to your Matrix
  direct chat with them as an ordinary Matrix message. The homeserver can
  read it unless that chat is encrypted.
- Once sent this way, it is marked **Plain Matrix** and is never also sent
  over Conest, so it cannot arrive twice.
- **New Matrix chat** now opens your existing direct chat with that person
  instead of creating another one.

### Qualification

- The remote debug workflow passed:
  - focused Flutter verification;
  - the Matrix client against a real Synapse homeserver;
  - native tests;
  - the Linux, Android and Windows debug builds.
- The full local test suite passed, including new tests:
  - Matrix-only mode keeps Conest off through app lifecycle, network
    changes and relaunches;
  - routes are recorded for messages sent over LAN, relays and Iroh, and
    received over Iroh and Matrix;
  - a plain Matrix send happens once and never repeats over Conest.
- An independent review was done and its findings fixed.
- Not yet tested on real devices:
  - switching modes;
  - the chat filters;
  - the route marks;
  - the Matrix fallback;
  - everything still pending from earlier nightlies.

This nightly is prerelease software; keep important data backed up and
report failures with the build identifier and a debug snapshot.
