## Conest 0.4.1 nightly (October 20)

The first nightly after the stable v0.4.0. Everything in v0.4.0 is
included.

### New

- Clean links: when you paste or type a link, Conest removes the parts
  that tell a site who shared it (such as YouTube's ?si= or utm_), and
  shows "Link cleaned" with Undo above the message box. Links you open
  from messages are cleaned the same way; the message itself is not
  changed. This uses the ClearURLs rules, bundled with the app: nothing
  is downloaded.
- Links that show previews: links to posts on X, Instagram, Reddit,
  TikTok, Bluesky and similar sites go through a service that lets other
  apps show a preview (x.com becomes fixupx.com, for example). The
  services come from the embed-fixer list. If one does not work, "Open
  original link" in the message menu opens the post on its own site,
  and that service is skipped for a day.
- Both are in Settings > Privacy, under "Links you send and open", and
  can be turned off.
- Photos: the editor that opens when you pick a single photo has a new
  "Send original as file" button. It sends the photo exactly as it is,
  without downscaling or compression, as a file. (Send still sends a
  smaller copy, as before.)

### Fixes

- Android: a file that could not be sent (too large for the route, or
  no longer readable) no longer disappears when you press Send. It stays
  above the message box, and the reason is shown.
- A relay that cannot be reached yet no longer reports "Relay has no
  verified identity pin".

### Please check

- Pasting and typing links on all three devices, Undo, and the two
  switches in Settings > Privacy.
- Sending a photo with "Send original as file" on Android, to a contact
  and in a group.
- Sending large files on Android: if one cannot go, it should stay above
  the message box with a reason.
