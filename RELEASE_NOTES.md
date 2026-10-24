# Conest v0.4.2

Conest now keeps receiving when it is not on your screen: on Android in
the background, on Linux and Windows from the tray. Notifications open
their chat, can be answered without opening Conest, and show only what
you choose.

New to Conest, or not sure which routes to turn on? Read the user guide:
https://github.com/glitch-228/conest/tree/main/docs

## Before you update

- Contacts on v0.4.1 and v0.4.0 keep working as before.
- Android: Conest now runs in the background by default, with a quiet
  notification saying it is receiving messages. You can turn this off in
  Settings. On first start it asks to be left out of battery
  optimisation; without that, Android may stop it after a while.
- Linux and Windows: closing the window now keeps Conest running in the
  tray. Use Quit in the tray icon's menu to end it, or turn this off in
  Settings.

## Receiving in the background

- Android: receiving in the background is on by default in every build,
  and comes back by itself after Conest updates or the phone restarts.
- Android: Conest asks once to be left out of battery optimisation, and
  shows steps for phones whose own battery manager stops apps (such as
  Xiaomi). Settings can ask again.
- Linux and Windows: Conest has a tray icon. Closing the window keeps it
  running there; the icon brings the window back, and its menu quits.
  On Linux this needs a tray (KDE and most desktops; GNOME with the
  AppIndicator extension); without one, closing quits as before.
- Linux and Windows: Settings > "Start Conest when you log in" (off by
  default) starts it hidden in the tray, ready to receive.
- Linux and Windows: starting Conest again while it runs brings the
  running one forward.

## Notifications

- Linux and Windows now show message notifications, except while the
  Conest window has the focus (one open behind other windows still
  notifies).
- Tapping or clicking a notification opens its chat, on every platform.
- Android: Reply and "Mark as read" right in the notification (the
  phone needs to be unlocked for them).
- Read a chat on one of your devices and its notification goes away on
  the others.
- Settings > "Show in notifications": the name and the message, the name
  only, or nothing (just "New message"), for shared screens and locked
  phones.

## Calls

- When the audio device changes during a call (a headset unplugged, or
  another default chosen), the call moves to the current device instead
  of ending.

## Fixes

- A route you switch off for a while (such as Nostr or the Bluetooth
  mesh) is now paused, not forgotten: your contacts keep its address, so
  switching it back on reaches them again, even when it is the only
  route left.
- A group invitation no longer waits about ten seconds when it was sent
  right after adding a contact.
- Opening a Matrix room no longer stops notification taps, transfer
  controls and scheduled messages from working until Conest restarts.
- Conest uses less of the computer's processor while nothing is
  happening (on Linux about a third of what it used).

## Not tested on real devices yet

- Coming back by itself after the phone restarts (after an update it was
  tested).
- Reply and "Mark as read" from an Android notification.
- The tray, start at login and notifications on Windows.

Please report problems with your build version and the crash or debug
details from Settings.

## Known limits

- Group calls are still experimental (off by default): with three or
  more people, often only some of them hear each other.
- Xiaomi and some other phones: Conest comes back by itself after an
  update or a restart only with Autostart allowed for it (Settings > Apps
  > Conest > Autostart). The battery prompt shows the steps.
- Some phones turn Wi-Fi off while they sleep; messages then arrive when
  the phone wakes or reaches a network again.
- Email can stall on networks that block or throttle mail servers; other
  routes keep working.
- Several devices: files and voice messages do not sync between your
  devices yet.
- Radios and the Bluetooth mesh carry messages only, never files.
