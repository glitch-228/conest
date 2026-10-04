## Conest 0.3.11 nightly (October 4)

This nightly fixes what testers found in the Matrix client and makes Conest
move between networks more smoothly.

### Moving between networks

- When you and a contact end up on the same Wi-Fi, chats now move onto it
  by themselves, usually within seconds:
  - Conest tells your contacts its new local address whenever it changes,
    and checks again a few seconds after the network switches.
  - It tests local paths in the background even while Iroh works, and
    sends waiting messages again as soon as a path works.
- **Check Paths** no longer fails with "Failed to create server socket
  … shared flag". Conest could start its local relay twice at the same
  moment; it now starts once, and a busy port no longer stops sending over
  Iroh or relays.
- Conest now tells other devices up to three local addresses. Virtual
  network bridges (virtual machines, containers, WireGuard) and Android
  mobile data are never offered as local addresses.
- After a network change, Iroh is told to look for new paths, and old local
  path results are forgotten.
- A contact who is offline no longer slows everything else down:
  - Automatic retries pause redialing them for a short while after a
    failed attempt; anything heard from them, or a network change, ends
    the pause.
  - Messages already stored on a relay are re-sent less and less often.
  - Group messages go to members in parallel.
- A late delivery receipt no longer shows a contact as online.

### Calls

- Voice calls are now included in stable builds, still marked
  experimental.

### Matrix client

- Group rooms show their real member count instead of 0, and the chat list
  shows each room's latest message instead of "Matrix chat".
- A message that starts with a quote ("> …") is shown in full; only real
  replies hide the quoted original.
- **Show joins, leaves and profile changes** (in the Matrix settings) shows
  them collapsed into one line, as other Matrix apps do. Off by default.
- Emoji verification with Element no longer gets stuck when both sides
  start the comparison at the same moment.
- If a server refuses to sign Conest out (for example one that manages
  sessions on its own account page), Conest says so instead of "Server not
  reached".
- **New Matrix chat** reuses an existing direct chat only if the other
  person is still in it.

### Qualification

- The full local test suite passed, including new tests:
  - a contact who joins your network later is reached over LAN, even while
    Iroh works;
  - overlapping local relay starts;
  - Matrix quotes, membership lines and the emoji verification start.
- The remote debug workflow passed: focused Flutter verification, the
  Matrix client against a real Synapse homeserver, native tests, and the
  Linux, Android and Windows debug builds.
- Not yet tested on real devices:
  - moving between networks with a contact;
  - the Matrix fixes, including verification with Element;
  - calls in a stable build;
  - everything still pending from earlier nightlies.

This nightly is prerelease software; keep important data backed up and
report failures with the build identifier and a debug snapshot.
