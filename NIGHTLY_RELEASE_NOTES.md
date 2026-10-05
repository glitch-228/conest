## Conest 0.3.11 nightly (October 4, third build)

This nightly adds the second new way to reach contacts when the usual
routes are blocked: email, in the style of Delta Chat.

### Email (new)

- Turn it on in **Settings → Connectivity → Email**. By default Conest
  creates a fresh account on a chatmail server (nine.testrun.org) with a
  random name and password; no sign-up and no phone number. You can enter
  another chatmail server, or use your own mail account (IMAP and SMTP,
  for example with an app password).
- When LAN, Iroh and Conest relays cannot reach a contact, messages go as
  encrypted email. Both of you need email turned on.
- Messages stay end-to-end encrypted by Conest, and each mail is also
  OpenPGP-encrypted as chatmail servers require. The mail servers see the
  two addresses and when you write, not what.
- New mail arrives within seconds (IMAP IDLE), also on servers without it
  (checked every minute).
- Your own mailbox is safe: Conest never downloads or touches your other
  mail, starts after the newest mail at setup, and removes only its own
  carrier mail once read.
- Messages that came by email carry a grey **Email** route mark.
- Files are not sent by email; only messages, receipts and other small
  updates are.

### Fixes

- A test of the forward-secret sessions and a native Iroh test no longer
  fail on slow build machines.

### Qualification

- The full local test suite passed, including new tests:
  - AES against the FIPS-197 vectors; OpenPGP messages read and written by
    GnuPG;
  - two devices talking by email while Conest relays fail, with the route
    mark, after a restart, and with email turned off again;
  - a local mail server that refuses unencrypted mail like chatmail; other
    mail never fetched; mail from before setup never read; reconnects;
    servers without IDLE.
- The remote debug workflow ran the email carrier against a real mail
  server (GreenMail).
- An independent review of the email carrier was done and its findings
  fixed.
- Not yet tested on real devices:
  - email with nine.testrun.org and with Gmail/Outlook, on phones in the
    background;
  - Nostr from the previous nightly, and everything still pending from
    earlier nightlies.

This nightly is prerelease software; keep important data backed up and
report failures with the build identifier and a debug snapshot.
