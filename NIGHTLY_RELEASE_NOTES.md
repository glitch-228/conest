## Conest 0.3.12 nightly (October 14, second)

This nightly brings Conest in six languages and lets one account use more
than one device. Everything from the earlier October nightlies (modes,
messages on several routes, Delta Chat, files without metadata) is
included.

### Before you update

- Linking devices only works between devices that both have this nightly.
- Your contacts learn about a new device only once they also run this
  nightly; until then they keep reaching your first device as before.

### Languages (new)

- Settings → Personal → Language: English, Arabic, Persian, Indonesian,
  Russian or Simplified Chinese, or the same as the device. Arabic and
  Persian read right to left.
- The translations were made with AI and may contain mistakes; Settings
  says so under the language. Help improve them on Weblate (see
  TRANSLATING.md).
- So far setup, the modes, the onboarding screen, calls, message details
  and the message menu, the Settings sections and the add-contact and
  new-group dialogs are translated; the rest follows.

### Your account on several devices (new)

- Settings → Devices lists the devices of your account.
- To add one: on the new device open Settings → Devices → Link this
  device to my account; on a device you already use open Settings →
  Devices → Link a device and scan the code. Both devices then show the
  same six digits: check that they match and confirm on both. The new
  device gets your account, name and contacts.
- Your contacts see the new device as you, not as a new contact. Their
  messages reach all your devices, and what you write from any of them
  shows in the same chat on their side.
- Remove a lost device in Settings → Devices; your contacts stop accepting
  anything from it. A device linked less than a day ago cannot add or
  remove others, and your first device cannot be removed yet.
- Not yet: what you sent from one of your devices showing on the others,
  and history syncing between them (next).

### Fixes

- Delta Chat: an internal check that started failing on dates after
  October 13 (tests only; the app was not affected).

### Not tested on devices yet

- Linking a phone to a desktop and back, over the same Wi-Fi and over the
  internet.
- Each language on a phone, including right to left.
