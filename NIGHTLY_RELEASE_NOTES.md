## Conest 0.3.12 nightly (October 15, third)

Fixes the crash on launch on Android in the previous nightly, and brings
the Delta Chat files work. Everything from the earlier October nightlies
is included.

### Fixes

- Android: the app no longer closes right after starting (it asked for
  its background service in a way Android 12 and later refuse).

### Delta Chat (better)

- Send and receive files, photos, videos and voice messages in Delta Chat
  chats and groups. Large files show a placeholder until they arrive;
  received files can be opened, saved or forwarded.
- React to Delta Chat messages, edit or delete your own, and see chat
  pictures. Group membership stays right when messages arrive out of
  order.
- Delta Chat files follow your metadata-removal and random-name settings.

### Not tested on devices yet

- Delta Chat files, reactions and edits with the Delta Chat apps on
  Android, iOS and desktop, in chats and groups.
