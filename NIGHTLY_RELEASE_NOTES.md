## Conest 0.3.11 nightly (October 3, second build)

This nightly turns Conest into a Matrix client as well: your Matrix rooms
and direct chats appear next to your Conest chats, and you can talk to
anyone on Matrix, including people who do not use Conest.

### Matrix client (experimental)

- **Sign in** under **Settings → Connectivity → Matrix**:
  - with a Matrix user and password; or
  - with **Sign in with browser**, for accounts that use Google, GitHub or
    another provider, and for matrix.org accounts. The browser opens your
    server's own sign-in page and returns to Conest when you are done.
- **Your rooms in the chat list.**
  - Matrix rooms and direct chats appear with a **Matrix** badge, unread
    counts and the latest message.
  - Invites show at the end of the list; you can join or decline them.
  - Start a direct chat from the menu with **New Matrix chat** and a Matrix
    ID.
- **In a room:**
  - send, reply, edit and delete messages, and react;
  - tap your own reaction again to take it back;
  - scroll back through older history;
  - send files and images, view images, and download files.
- **End-to-end encryption:**
  - Encrypted rooms work like in other Matrix apps.
  - **Set up recovery** creates a recovery key. It is shown once; keep it
    safe. With it, **Enter recovery key** on a new device unlocks your
    earlier encrypted messages.
  - **Verify with another session** compares emojis with Element or another
    Matrix app. Requests from your other sessions show up in Conest too.
- **Signing out:**
  - Signing out removes this device from your account.
  - If the server cannot be reached, Conest asks before signing out on
    this device only.
  - If you remove the device from another Matrix app, Conest notices and
    signs out.
- **The Matrix fallback for Conest contacts** now uses the same sign-in:
  - Conest messages to contacts who also signed in travel through
    Matrix when LAN and Iroh cannot reach them.
  - These messages stay end-to-end encrypted by Conest.
- **Not yet available:**
  - choosing a Matrix-only or Conest-only app mode;
  - chat-list filters;
  - showing the route each message took;
  - offering to send to an unreachable Conest contact as a plain Matrix
    message.

  These come next, together with spaces, room search, Matrix calls and
  notifications later on.

### Qualification

- The remote debug workflow passed:
  - focused Flutter verification;
  - the Matrix client and the Matrix fallback against a real Synapse
    homeserver: sign-in, sync, direct chats both ways, replies, edits,
    reactions, deletes, files, recovery, restore and sign-out;
  - native tests;
  - the Linux, Android and Windows debug builds.
- The full local test suite passed.
- An independent review of the Matrix client was done and its findings
  fixed.
- Not yet tested on real devices:
  - Matrix sign-in, including through the browser on Android;
  - rooms, media, recovery and verification with Element;
  - everything still pending from earlier nightlies.

This nightly is prerelease software; keep important data backed up and
report failures with the build identifier and a debug snapshot.
