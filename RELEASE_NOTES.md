# Conest v0.3.10

The first stable release since v0.3.2. It brings everything tested in the
v0.3.3–v0.3.10 nightlies: files and media, Iroh connections, signed group
history, a Telegram-style chat layout, chat folders, scheduled messages, group
polls and voice messages.

## Before you update

- **Update both sides.** Files, group history, polls and voice messages need
  matching versions on every device in the conversation. Older peers can
  still exchange text.
- **Bundled Conest relays are retired.** Previously bundled relay routes are
  removed on upgrade. Relays you added yourself stay. Without one, Conest uses
  LAN and Iroh, which needs no setup.
- **Unfinished file transfers from v0.3.2 are canceled** with "Canceled by
  transfer upgrade—resend." Completed files and message history are kept, and
  your original files are never deleted.

## Connections

- Messages and files travel over LAN when possible, otherwise over Iroh:
  direct when the network allows, through Iroh relays when it does not.
- Add contacts with signed QR or pasted invites, or with Conest Beam nearby.
  Codephrase-only discovery still needs the same LAN or a shared Conest relay.
- Adding a contact sends a request that the other person must accept.
  Messages you write before then wait and send once it is accepted. A pending
  request shows its status and can be retried or canceled, and a contact you
  remove cannot reappear through a late acceptance.
- Delivery receipts mean the recipient's device really got the message, not
  just that the network accepted it.

## Files and media

- Send photos, videos and files in direct and group chats, with captions,
  albums, a gallery picker and a crop/rotate editor. Save single files or a
  whole selection to your device.
- Transfers are verified block by block, survive app restarts and network
  changes, and can be paused, resumed or canceled. The Transfers screen shows
  progress, speed and route, and can cancel or clear everything at once.
- Large files are supported up to 2 GiB. Over Iroh, files above 100 MiB are
  off by default; change this in Settings. Online automatic downloads stop at
  15 MiB, and larger files wait for you to accept.
- Conest keeps 10% of your storage free by default. You can turn this off, or
  use **Download anyway** for a single file.

## Groups

- Group messages are signed and kept in an encrypted, shareable history.
  Members who join or come back online catch up automatically, and the owner
  decides whether new members see earlier history.
- Group members do not need to be each other's contacts; the group itself
  authorizes them.
- Group files download from any member who has them and keep going when one
  member goes offline.
- Create single or multiple choice polls. Votes show who voted, can be
  changed or withdrawn, and the creator can close the poll with a signed
  final tally.

## Chats

- The new Courier layout is the default, with a resizable sidebar on desktop
  and full-screen chats on phones. Your colors and brightness are kept, and
  the older layouts remain in Settings.
- Search chats and messages, including older group history, and jump to
  results.
- Drafts are saved per chat. Pin, mute and archive chats, and group them into
  folders.
- Tap a message for its actions, long-press to select several, double-tap to
  reply, or double-tap your own message to edit it. Swipe to reply, forward,
  react, edit and delete.
- Schedule text and files for later. Scheduled messages can be edited,
  rescheduled, sent now or canceled. They send while Conest is running;
  delivery is not guaranteed while the app is closed.
- Record, preview and send voice messages, with seeking, playback speed and
  volume controls.

## Not in this release

- **Voice calls** stay in nightly builds while audio quality and background
  behavior are tested on real devices. Stable builds do not show the call
  button.
- Folders stay on this device and do not sync between your devices.

Thanks to everyone who tested the nightlies. Please report problems with your
build version and a debug snapshot from Settings.
