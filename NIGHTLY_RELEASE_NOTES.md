## Conest 0.3.12 nightly (October 13)

This nightly lets you chat with Delta Chat users through your email
account, one to one and in groups. Everything from the October 8
nightlies is included.

### Before you update

- Nothing changes until you turn Delta Chat on. Ordinary mail in your
  inbox is never touched.

### Delta Chat (new)

- With an email account set up (Settings → Connectivity → Email, for
  example a chatmail server), turn on **Delta Chat** just below it.
- Your Delta Chat invite is a QR code or a link: a Delta Chat user scans
  or opens it, and you are both verified, as in Delta Chat itself. To
  reach a Delta Chat user, paste their invite link in Delta Chat chats →
  Join with an invite (this works for their group invites too).
- Chats one to one and in groups, with read receipts both ways. In a
  group you can see and change the members, share the group's invite, or
  leave.
- Delta Chat chats sit in the chat list with a filter of their own.
- Messages are end-to-end encrypted with OpenPGP, as Delta Chat does,
  without forward secrecy; the mail servers see who writes to whom and
  when.
- Chats from people you have not chatted with are requests until you
  reply.
- Files, voice messages and reactions sent from Delta Chat show as a short
  note for now; such mail stays on the server, so you can open it in Delta
  Chat or another mail app.

### Files you send (new)

- Location, camera, author and date details are now removed from photos,
  videos, PDFs and office documents before they are sent, one to one and
  in groups. Photos are not re-compressed and keep their orientation.
  Your own files are not changed. Turn it off in Settings → Personal if
  you want to send files as they are.
- Settings → Personal → **Send files under random names** replaces file
  names with random letters (the type, such as .jpg, stays).

### Other fixes

- Release builds no longer fail when the Tor project's code server is
  down.

### Not tested on devices yet

- Delta Chat with the Delta Chat apps (Android, iOS, desktop): invites both
  ways, messages, read marks and groups.
- Metadata removal on photos and videos from real phones.
