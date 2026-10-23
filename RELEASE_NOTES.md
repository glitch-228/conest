# Conest v0.4.1

Your other devices now get the messages your contacts send, show your
groups, and catch up on older chats after linking. Calls no longer fall
behind and stutter after a bad moment on the network. Links are cleaned
of tracking and can show previews. Everything tested in the 0.4.1
nightlies is included.

New to Conest, or not sure which routes to turn on? Read the user guide:
https://github.com/glitch-228/conest/tree/main/docs

## Before you update

- Update all of your linked devices together: what is new between your
  own devices needs this version on each of them.
- Contacts on v0.4.0 keep working as before.
- If you run your own relay, update it too (install-relay.sh, or let its
  supervisor update it). It then shares its space and speed fairly
  between the people using it.

## Several devices on one account

- Messages your contacts send reach all of your devices, even when a
  contact can only reach one of them: that device passes them on.
- Your groups show on all of your devices. A device that is not a member
  itself writes in the group through the one that is.
- A device linked later catches up on your chats, a few at a time and
  newest first, as already-read history.
- The device you created your account on can link and remove others
  right away, without waiting a day.
- Settings > Connectivity > "What goes over the internet": everything,
  messages and files up to 1 MB, or messages only (files then wait for
  your local network). Advanced mode can choose per transport, and per
  contact in the contact's connection settings.

## Calls

- After a moment of lost or late sound, a call catches up again instead
  of falling further behind and stuttering for the rest of the call.
- Group calls no longer make a phone sluggish for the whole call, which
  delayed everything else on it too.
- Linux: a call no longer silences other apps. The call's audio output
  list now offers only outputs that go through your sound server
  (PipeWire or PulseAudio), not a sound card's own devices, which a call
  took over for itself. Choose a specific output in your system's sound
  settings.
- Windows: call tones, voice messages and videos play (the player was
  missing from the Windows download).

## Links

- When you paste or type a link, Conest removes the parts that tell a
  site who shared it (such as YouTube's ?si= or utm_) and shows "Link
  cleaned" with Undo. Links you open are cleaned the same way; messages
  themselves are not changed.
- Links to posts on X, Instagram, Reddit, TikTok, Bluesky and similar
  sites go through a service that lets apps show a preview. If one does
  not work, "Open original link" in the message menu opens the post on
  its own site.
- Link previews: a link shows the site's title, a short description and
  a small picture. In chats with your contacts and in your groups they
  come by themselves; elsewhere you tap "Show link preview" first,
  because fetching one shows the site your IP address.
- Settings > Privacy > "Link previews": each receiver fetches them (the
  default), they are sent with the message (people you write to never
  contact the site), both, or off. With Tor set up, previews are fetched
  through Tor.

## Fixes

- Email: Conest checks that a mail server really passes messages
  through before using it. If a server it picked stops doing so, your
  account moves to one that works, and your contacts learn the new
  address by themselves.
- Relays: when many messages go out at once, a relay that starts
  refusing them is given a moment, and the rest go another way
  meanwhile, instead of nothing being sent for a while.
- A contact you removed can be added again when only Iroh connects
  you; the request used to be dropped.
- With LAN turned off, files no longer get stuck because parts of them
  were still sent over the local network.
- Photos: "Send original as file" in the photo editor sends a photo
  exactly as it is, without downscaling.
- Android: a file that cannot be sent no longer disappears when you
  press Send; it stays above the message box with the reason.
- A relay that cannot be reached yet no longer says "Relay has no
  verified identity pin".

## Not tested on real devices yet

- Link previews and clean links on Android and Windows.
- Groups shown through another of your devices, and catching up on
  older chats after linking, over a day or more.
- Calls on Linux systems that use PulseAudio rather than PipeWire, or
  neither.

Please report problems with your build version and the crash or debug
details from Settings.

## Known limits

- Group calls are still experimental (off by default): with three or
  more people, often only some of them hear each other.
- Android: on some phones (seen on Xiaomi), Conest loses its connection
  a few minutes after you leave the app, unless a call is in progress.
  Keep it open when you expect messages.
- Email can stall on networks that block or throttle mail servers; other
  routes keep working.
- Several devices: files and voice messages do not sync between your
  devices yet.
- Radios and the Bluetooth mesh carry messages only, never files.
