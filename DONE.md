# Done Functionality

This file lists the functionality currently implemented in the Conest prototype.

## App And Platforms
- Flutter app shell for Linux, Windows-capable desktop builds, and Android.
- Linux debug build output through `flutter build linux --debug`.
- Android debug APK output through `flutter build apk --debug`.
- Responsive desktop/mobile layout with sidebar on wide screens and single-panel navigation on small screens.
- Android system back button returns from an open chat to the main/contact menu instead of closing the app.
- App relaunch opens the main/contact menu instead of auto-opening the first contact or a dialog.
- Desktop startup checks for an existing running Conest instance and shows an "already running" screen instead of starting a second relay/vault runtime.
- Android message notifications can be enabled from settings.
- Android foreground background-runtime service can be toggled from settings with a warning that blocked battery/background access can make notifications late or unavailable.
- QR scanner support is available on Android builds.
- Release builds hide the debug menu entry.

## Identity And Local Storage
- Local account/device identity creation with separate `accountId` and `deviceId`.
- Device display name management.
- Device description/bio management.
- Safety number generation for the local identity.
- Encrypted vault storage for identity, contacts, conversations, seen envelopes, relay settings, LAN routes, and profile metadata.
- Vault reset flow that clears identity, contacts, messages, settings, and encryption material.
- Backward-compatible JSON loading for older vault data that does not contain newer bio fields.

## Pairing And Contact Addition
- Contact invites encode account id, device id, display name, bio, public key, and route hints.
- Contact invites include a pairing nonce so the visible codephrase can be rotated immediately.
- Contact invites include a relay-capable flag so direct LAN paths and relay candidacy are separate.
- QR invite generation.
- QR-only contact add flow.
- Manual payload paste contact add flow.
- Codephrase-only contact discovery and add flow.
- Dynamic rotating codephrase derived from the invite payload.
- Manual "rotate codephrase now" action on the invite screen resets the visible 30-second timer.
- Pairing announcements are reusable during their TTL instead of being consumed by the first discovery fetch.
- Codephrase discovery over configured internet relays.
- Codephrase discovery over nearby LAN route scans with LAN-grade route timeouts.
- Codephrase discovery can use LAN UDP pairing beacons to find nearby devices without relying only on guessed `/24` scans.
- Codephrase entry accepts hyphenated, spaced, or punctuation-free forms.
- Invite screen republishes the visible codephrase when it changes.
- Pairing announcements are stored through loopback and detected LAN addresses so debug checks can distinguish local-only from LAN-reachable pairing.
- LAN route discovery filters common Docker, WSL, Hyper-V, VM, VPN, and bridge interfaces so peers do not advertise unusable local-only adapter addresses.
- Relay-disabled devices can still advertise direct LAN paths for pairing and messaging while avoiding relay-capable advertisement.
- Optional QR/payload plus codephrase verification.
- Automatic reciprocal contact exchange after one side adds the other.
- Manual fallback prompt when reciprocal exchange cannot be delivered.
- Abort path for one-sided contact additions.

## Contacts And Profiles
- Trusted contact list with alias, display name, account id, device id, bio, public key, route hints, safety number, and trusted timestamp.
- Contact profile screen.
- Editable local contact alias.
- Editable local contact description/bio.
- Contact profile displays device/account/safety/trust metadata.
- Contact profile displays route hints and route health results.
- Contact profile path check measures availability and latency.
- Path check results are sorted by best usable direct/LAN paths first, then relay fallback, then unavailable paths.
- Path checks request a route-info exchange so both sides can learn changed LAN, relay, and relay-capable status.
- Contact removal from the profile screen.
- Best-effort reciprocal contact removal notice so the removed contact disappears on the other side when reachable.
- Incoming reciprocal removal handling.
- Incoming contact exchange updates existing contact profile and route hints.

## Messaging
- 1:1 text chat.
- LAN free-for-all lobby chat that does not require adding contacts.
- LAN lobby messages are marked untrusted and signed with an ephemeral LAN session key.
- LAN lobby delivery uses nearby LAN-discovered routes only and does not fall back to internet relays.
- Local encrypted message history.
- Outbound message state tracking: pending, LAN/local accepted, relay accepted, delivered, failed.
- Inbound duplicate suppression through seen envelope ids.
- Encrypted message envelopes using per-contact shared secret derivation.
- Message acknowledgements.
- Sender-side delivered state update when acknowledgements arrive.
- Pending outbound messages remain queued instead of failing immediately.
- Pending outbound retry runs during route polling.
- Pending outbound messages can be canceled before retry; cancel removes the local pending message and prevents later retry.
- Messages can be deleted from the local conversation.
- Sent outbound messages send an encrypted delete envelope so the peer can remove the received copy when reachable.
- Incoming encrypted delete envelopes remove the corresponding received message and tombstone it against duplicate relay fetches.
- Outbound messages can be edited locally; pending edits change the queued body, and accepted-message edits are sent to the peer as encrypted edit envelopes when a route is available.
- Incoming encrypted edit envelopes update the displayed body and mark the message as edited.
- Incoming LAN/direct envelopes stored in the local relay are push-processed immediately instead of waiting for the slow full route poll.
- A fast local inbox poll backs up the push path to reduce LAN receive latency.

## Routing And Delivery
- Peer route model supports LAN and relay routes.
- Peer route model includes an explicit transport protocol, currently TCP or UDP.
- Peer route model reserves direct-internet routes, ranked after LAN and before relay fallback.
- Route hints are deduplicated.
- Per-route availability checks.
- Per-route latency measurement.
- Contact delivery ranks routes by availability, direct/LAN preference, and latency.
- Relay delivery can recognize same-relay aliases by relay instance id and include faster configured aliases for a contact's advertised relay.
- Direct/LAN route is tried before relay fallback when available.
- If the best direct route fails after health check, other available routes are tried before giving up.
- Relay fallback is used when direct/LAN delivery is unavailable or fails.
- Offline/temporarily unreachable sends stay pending for future retry.
- Polling checks route health before fetching.
- Polling fetches queued envelopes from local and relay routes.
- Network summary reports LAN node status, LAN addresses, relay routes, and relay health.

## Relay And LAN Runtime
- Built-in local relay node for app-integrated TCP/UDP relay/LAN queue behavior.
- Standalone Rust relay app/package that speaks the current Flutter TCP/UDP JSON relay protocol.
- Standalone relay supports TCP and UDP health, encrypted envelope store/fetch, pairing announcement reuse, TTL cleanup, mailbox queue caps, fetch caps, envelope size caps, and basic per-IP rate limiting.
- Standalone relay health returns a relay instance id; `--relay-id` / `CONEST_RELAY_ID` can make that id stable across restarts.
- Desktop devices enable relay mode by default for new identities.
- Android devices keep relay mode disabled by default for new identities.
- Relay mode can be enabled/disabled in settings.
- Local relay port can be changed in settings.
- Configured internet relay list can be added to and removed from settings.
- Bare relay hosts add TCP and UDP route variants; `tcp://host:port` and `udp://host:port` can be used to force one protocol.
- Optional auto-use of relay-capable routes learned from contacts.
- Auto-use contacts as relays is enabled by default for new identities.
- Relay availability check button in settings.
- Relay availability checks configured internet relays, contact relays, local relay loopback, and LAN addresses.
- Relay availability and debug diagnostics group different endpoints that report the same relay instance id.
- Relay debug loopback, pairing reuse, and availability checks include trusted contact relay endpoints and cached same-relay aliases even when automatic contact relay use is disabled.
- Bare relay hosts are auto-detected when added from onboarding/settings: TCP and UDP are probed, and only answering protocols are saved.
- Explicit `tcp://host:port` or `udp://host:port` relay entries can still be forced when a tunnel is expected to work later or cannot be probed locally.
- Existing configured relay hosts can rediscover newly working TCP/UDP sibling routes during relay availability/debug checks, while stopped protocols remain separate unavailable routes instead of blocking working ones.
- Startup no longer blocks on best-effort relay pairing announcements; slower relay checks run after the app is ready.
- LAN pairing beacon listener advertises TCP and UDP local pairing routes and responds to nearby pairing discovery pings.
- LAN pairing beacons from already-trusted contacts are used to rediscover new direct paths after network changes.
- Trusted contacts can exchange `route_update` envelopes to refresh route hints without re-pairing.
- LAN lobby broadcasts use UDP-discovered nearby routes plus local relay-style mailboxes.
- Relay capability report explains local relay status and current limitations.
- Public inbound reachability is explicitly marked as requiring a remote client or relay route to confirm.

## Settings
- Relay management settings.
- Relay availability checks.
- Relay mode management.
- Auto-use contacts as relays setting.
- Local relay port setting.
- Identity display name setting.
- Identity bio setting.
- Identity/account/device/safety display.
- Full identity reset.

## Debug Menu
- Debug menu entry is shown only in debug builds.
- Debug menu displays build mode, platform, scanner availability, identity, bio, relay state, pairing beacon state, cached beacon routes, LAN addresses, configured relays, last relay status, contacts, message counts, pending outbound count, seen envelope count, and cached contact route health.
- Debug test runner button.
- Debug info copy button for bug reports and error reports.
- Contact profile path checks can be copied with full route state, latency, relay instance id, and error details.
- Debug test runner checks identity, encrypted vault write, invite codec, current codephrase generation, pairing announcement LAN loopback, LAN beacon listener, LAN address discovery, local relay runtime, relay protocol rediscovery, notification/background settings, route protocol coverage, relay alias grouping, internet relay availability, contact route availability, two-device readiness, debug peer probes, debug probe acknowledgements, relay-forced probe sends, relay store/fetch loopback, message action state, and message queue state.
- Debug test runner checks that configured internet relays keep pairing announcements reusable across repeated discovery fetches.
- Debug test runner sends two-way debug message probes and tracks two-way debug replies from remote debug builds.
- Debug test runner waits briefly and polls locally after sending debug probes so fast remote replies are counted in the same run when possible.
- Debug probe envelopes are answered by other debug builds when they poll.
- With one device, the runner performs local checks.
- With at least two devices that are in each other's contacts, the runner can probe peer routes and peer debug responsiveness.
- With three or more reachable devices/routes, the runner can additionally force relay-path probes and test relay store/fetch behavior.

## Tests
- Invite payload round-trip test.
- Reserved attachment and transfer model round-trip test.
- Dynamic codephrase test.
- QR/payload-only contact add coverage.
- Codephrase-only contact discovery coverage.
- Automatic reciprocal contact exchange coverage.
- Manual fallback when reciprocal exchange fails.
- Reciprocal contact removal coverage.
- Contact profile bio and route health sorting coverage.
- Route rediscovery and path-check route update exchange coverage.
- LAN lobby send/receive without trusted contacts coverage.
- LAN-first send coverage.
- Unavailable LAN fallback to relay coverage.
- Direct-store failure fallback to relay coverage.
- Same-relay alias delivery coverage where a contact advertises one relay endpoint and the sender uses a faster configured alias for the same relay instance.
- Fully unavailable route leaves message pending coverage.
- Pending cancel deletes the queued local message coverage.
- Sent message delete local plus remote copy coverage.
- Debug self-test coverage.
- UDP relay client/local relay loopback coverage.
- Standalone relay package tests for reusable pairing announcements, consumed message queues, fetch limit clamping, queue caps, mailbox id validation, and UDP datagram request handling.
- Relay settings and identity reset coverage.

## Current Prototype Boundaries
- Trusted direct messaging is text-only.
- Groups are not implemented yet.
- Multi-device identity enrollment is not implemented yet.
- Attachment, image, file, and transfer protocol types are reserved, but actual file/image transfer is not implemented yet.
- Voice and video are not implemented yet.
- Signed default relay lists and relay federation are not complete yet.
- Public internet reachability of a device acting as a relay cannot be proven locally without a remote client or external probe.
- The current crypto is a prototype shared-secret envelope layer, not a full audited X3DH plus Double Ratchet implementation.
