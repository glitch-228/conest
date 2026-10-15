## Conest 0.3.12 nightly (October 15, second)

Safer linked devices, your devices helping each other stay connected,
and tools for testing on real devices. Everything from the earlier
October nightlies (group calls, file privacy, your devices in step,
languages) is included.

### Your devices (better)

- A device of yours that has not been in touch with your others for a
  week stops syncing until you confirm it is still yours: Settings →
  Devices shows it with "Still mine" and Remove. Choose after how many
  days (3 to 30). Nothing sent meanwhile is lost: it arrives once you
  confirm the device on both sides.
- Conest tells you once when one of your devices has gone quiet.
- If a contact's other devices stop counting one of their devices as
  theirs (for example a lost phone), messages from that device say "Not
  recently confirmed" in their details, and Conest tells you once.

### Staying connected (new)

- Your devices carry messages for each other: if your laptop cannot
  reach a contact but your phone can, it goes through the phone.
- After the network changes (another Wi-Fi, mobile data, a VPN), and
  every half hour on mains power, Conest quietly re-checks the routes to
  the people you talk to most. Not in battery saver.
- In the background Conest checks in half as often on battery and a
  quarter as often in battery saver; an open chat or a transfer is not
  slowed down.
- Settings → Connectivity → Connections (Advanced mode) shows which
  devices reach which: both ways, only one way, or failing. Devices share
  only links to devices the other side already knows (people in a shared
  group).

### For testing (debug and nightly builds)

- Settings → Updates → Error history keeps what went wrong across
  restarts, to copy or save for a bug report. Stable builds do not keep
  it.
- Debug builds can test every route with a contact in both directions,
  and run these tests on their own when started for it (for testing
  devices over a cable or the network).

### Not tested on devices yet

- A phone off for a week and confirmed again, on both sides.
- A contact's phone their other devices lost touch with.
- The automatic tests on Android, Linux and Windows.
- A message carried by your phone for your laptop.
- The Connections screen with a group of three or more.
