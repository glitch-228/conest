## Conest 0.4.1 nightly (October 21)

Everything in the October 20 nightly is included.

### New

- Link previews: a link in a message shows the site's title, a short
  description and a small picture under it, and a tap opens the link.
  In chats with your contacts and in your groups they come by
  themselves; in other chats you tap "Show link preview" first, because
  fetching one shows the site your IP address. In battery saver or
  when roaming they always wait for a tap.
- How previews are made is up to you, in Settings > Privacy > "Link
  previews":
  - "Each receiver fetches them" (the default);
  - "Sent with the message", so the people you write to never contact
    the site; their app shows it as "preview from the sender";
  - "Both";
  - "Off".
  While writing, "Send without the preview" removes the one about to
  be sent.
- "Fetch previews through Tor" (on by default once Tor is set up):
  sites see a Tor exit instead of your address. While Tor is not
  connected, no previews are fetched.

### Fixes

- Email: on networks that block or stall some mail servers, Conest no
  longer picks a server that only seems to work. When setting up email
  it checks that a server really passes messages through. If Conest
  picked your server and it stops passing them later, your account
  moves to another one that does, and your contacts learn the new
  address by themselves.
- Relays: when many messages are sent at once from several devices on
  one network, a relay could start refusing them, and then nothing was
  sent for a while, files included. Conest now waits a moment before
  asking that relay again, and sends the rest another way meanwhile.
  Relays running this version also allow more before refusing.
- With LAN turned off, parts of a file could still be sent over the
  local network and were then thrown away on arrival, so the file did
  not finish. They now go another way.

### Please check

- Link previews in a chat with a contact, in a group, and in a chat
  with someone who is not a contact (it should wait for a tap).
- Each preview setting, and "Fetch previews through Tor" with Tor on.
- Email on your usual networks, especially where it did not work
  before.
- Sending files with LAN turned off in Settings.
