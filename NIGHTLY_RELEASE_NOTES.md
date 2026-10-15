## Conest 0.3.12 nightly (October 15, second)

Safer linked devices and tools for testing on real devices. Everything
from the earlier October nightlies (group calls, file privacy, your
devices in step, languages) is included.

### Your devices (better)

- A device of yours that has not been in touch with your others for a
  week stops syncing until you confirm it is still yours: Settings →
  Devices shows it with "Still mine" and Remove. Choose after how many
  days (3 to 30). Nothing sent meanwhile is lost: it arrives once you
  confirm the device on both sides.
- Conest tells you once when one of your devices has gone quiet.
- If a contact's account loses touch with one of their devices (for
  example a lost phone), messages from that device say "Not recently
  confirmed" in their details, and Conest tells you once.

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
