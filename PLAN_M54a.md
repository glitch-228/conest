# M54a: USB and wire, plus I1 (Iroh without internet)

Read `/home/glitch/Documents/conest/PLAN_AGENTS.md` in full before anything else. It holds the shared rules: Lanes, Design note first, Known pitfalls, Strict fakes, and "Transports and networks follow one design".

- **Worktree:** `/home/glitch/Documents/conest/.worktrees/agent-m54a`
- **Branch:** `agent/m54a-usb-wire`
- **Base:** `integration/g7-g8` (f389855). It becomes `feature/matrix-client` once its gate passes; merge it into your branch when the main session says so.
- **Lanes:**
  - **Careful:** discovery, the LAN transport, Iroh dial hints, any new link or wire format, and capabilities.
  - **Fast:** the settings page and its texts. These may go to `canary` separately once the core is merged.
- **Start with the design note** in this file. It covers the approach, the invariants checked against Known pitfalls 1–20, the failure cases, and the tests with their strict fakes. Then stop and report. Implement only after the design review passes.
- **Background (read only):** the maintainer's plan `/home/glitch/.claude/plans/velvet-seeking-walrus.md`. The relevant sections are:
  - "M54a. USB and wire (first of M54)" under "Update 2026-11-01";
  - "I1. Iroh over LAN and direct cables with no internet" under "Update 2026-11-04".

## Goal

Two of the user's own devices, or two contacts' devices, talk at full speed over a cable, with no router and no internet:
- **messages, files and calls**;
- **cables:** a direct Ethernet cable between PCs, USB tethering between a phone and a PC, and later a USB data link without tethering;
- **paths:** both our LAN transport and Iroh work over the cable.

## Phases (the design note may refine them)

1. **P1: link-local LAN and USB tethering, with I1** (careful lane):
   - **Discovery and the LAN transport on link-local interfaces:**
     - addresses on 169.254/16 and on IPv6 fe80::/10 (with the zone or scope id) are included;
     - this works with no DHCP and no default route.
   - **Tethering:** Android USB tethering (rndis, ncm or usb interfaces) is treated as a LAN.
   - **I1:** Iroh dials carry fresh addresses learned from our LAN beacon and route updates:
     - link-local addresses included;
     - newest first, at most 8;
     - refreshed on network changes.
   - **No mDNS by default.** `iroh-mdns-address-lookup` broadcasts the stable endpoint id, which can be used to track the device.
2. **P2: Android Open Accessory (AOA)** for phone↔PC without tethering:
   - **Phone side:** `UsbAccessory` in Kotlin, which needs no root.
   - **PC side:** libusb through the Rust `rusb` crate in `conest_native`. Check the licence fit with MPL-2.0 and dynamic linking. Note the Windows driver question (WinUSB).
   - **Framing:** reuse `lib/src/radio/byte_link.dart`.
   - **Feasibility first:** if the Windows driver story is too heavy, the design note proposes Linux-only first, or deferring P2. Say so plainly.
3. **P3: USB serial byte link (CDC-ACM)**, using the same framing. Its value is lower (PC↔PC serial adapters, a phone over OTG to a serial device). The note may defer it.

## Today (facts to verify, not trust)

**LAN discovery** (`lib/src/local_relay_node.dart`):
- `discoverLanAddresses()` (~1080) collects IPv4 only.
- `isLanDiscoveryAddress` (~1144) accepts 10/8, 192.168/16, 172.16/12 and 169.254/16.
- `isIgnoredLanInterfaceName` (~1106) drops virtual and VPN interfaces. Check whether the tethering interface names on Linux, Windows and Android pass that filter.
- IPv6 link-local is not collected at all.

**Invite address ranking** (`messenger_controller.dart` ~33490, `_lanInviteAddressPriority`): 169.254 is ranked last.

**Iroh dial hints:**
- `_transportPeerForContact` (`messenger_controller.dart` ~30981) passes only `contact.directInternetRouteHints` with protocol udp. These are the Iroh-advertised direct addresses, which go stale offline or after DHCP changes.
- LAN route hints (`lanRouteHints`, models.dart ~2374) are not used for Iroh.
- `api.rs` `send_to_with_hints` (~203–240) takes up to 8 addresses.
- `iroh_ffi_bridge.dart` ~223.

**Without internet, Iroh has no relay and no discovery,** so hints are its only way in.

## Must follow

- **"Transports and networks follow one design"** (PLAN_AGENTS.md), including its own settings page (M59 spec). For P1 this is a "Cable and USB" page that:
  - lists detected wired links and their state;
  - offers "Open tethering settings" on Android (apps cannot turn tethering on);
  - gives short help text.
- **Censored-network gate:** not applicable, since these are local links. Say so in the note.
- **Group parity:** groups use the cable path to members on the cable.
- **Own-device sharing modes:** say what applies.
- **Performance is a release rule:**
  - native data path for files;
  - no polling where interface-change events exist, with a bounded fallback only where the OS has none;
  - measure throughput over a real cable in the lab later.
- **Rust:** builds and tests run only in CI (`rust-tests.yml`). Add a Rust test where two endpoints with relays disabled connect by provided direct and link-local addresses.
- **Strict fakes:**
  - a fake interface list, for link-local only, IPv6 with zone, tethering names, and changes;
  - a fake Iroh bridge that records the hints;
  - each new behaviour sabotage-checked.

## Lab (later, by the main session)

- **Phone 1 ↔ Linux over USB tethering**, with Wi-Fi off on the phone and the internet blocked: messages, a 100 MB file, and a call, over LAN and over Iroh.
- **Linux ↔ Windows over a direct Ethernet cable,** if available. Otherwise link-local on a switch with DHCP off.

## Design note

### 0. Verified facts, and corrections to "Today"

Checked in the code and in the Dart/Iroh sources (the Dart SDK 3.12.1 in `~/.local/share/flutter-sdk`, Iroh 1.0.3 and netwatch 0.19.1 in `~/.cargo/registry`). Line numbers in "Today" are stale (`messenger_controller.dart` is now 44.8k lines); the functions exist as described unless noted.

1. **169.254 is dead code today.** `isLanDiscoveryAddress` accepts 169.254, but `NetworkInterface.list` is called without `includeLinkLocal: true`, and Dart then drops every address whose `isLinkLocal` is true (`socket_patch.dart`: `if (!includeLinkLocal && address.isLinkLocal) return map`). So no 169.254 or fe80 address is ever collected. Fix: ask for link-local, and keep the result out of `identity.lanAddresses` (see 3.1).
2. **IPv4 tethering subnets already pass the filter.** `isIgnoredLanInterfaceName` does not match `usb0`, `rndis0`, `ncm0`, `enx<mac>`, `enp0s20f0u2`, `Ethernet 3`, `Remote NDIS based Internet Sharing Device` (read against the fragment list; to be locked by a test, unverified on Windows and Android). So with DHCP from the phone (192.168.x.0/24), the address is already collected. What is missing is everything around it: no event when the cable appears, no discovery of the peer on it, no Iroh hint (3.2).
3. **All LAN listeners are IPv4 only:** local relay `ServerSocket`/`RawDatagramSocket` and the LAN-direct `HttpServer` bind `anyIPv4`; the pairing beacon socket is `anyIPv4` too. No IPv6 listener exists.
4. **The beacon runs only during a pairing session** (`_isPairingSessionActive`) for its periodic send. The listener is always up (started at init). A `pairing_ping` is answered always, by a unicast `pairing_route` to the asker, whatever the session state. We use that.
5. **The beacon carries `deviceId` and `relayPort`, not the Iroh port.** The rediscovery routes scan /24 neighbours (`_nearbyHostSegments`), which is useless on 169.254/16. `_directedBroadcastAddress` always assumes /24 (`a.b.c.255`).
6. **Dart cannot do IPv6 link-local UDP.** `RawDatagramSocket.send/bind` ignore the scope id (the VM passes none; a send to `fe80::..%3` went nowhere, bind on a scoped address fails with EINVAL), `multicastInterface` throws `UnimplementedError`, and a datagram's source address carries no zone (dual-stack v4 sources show as `::ffff:a.b.c.d`). TCP is fine: `Socket.connect(InternetAddress('fe80::x%3'), port)` and `ServerSocket.bind(anyIPv6, p, v6Only: true)` work; a bare `fe80::x` fails with EINVAL. `InternetAddress.tryParse('fe80::1%name')` resolves the name on the local host (null if absent) and `%<number>` is accepted; so a zone is host-local and must never cross the wire. Raw TCP to this host's own fe80 got reset here (host firewall), so there is no local loopback test for fe80: CI veth or the lab.
7. **Iroh already supports sending to a scoped link-local address** (`iroh/src/socket/transports/ip.rs` matches the destination's scope id), but **never publishes one**: netwatch's `LocalAddresses` leaves out IPv6 fe80 and keeps 169.254 only when the device has no other address. So with no internet and no relay, hints are the only way in, as the plan says. The Rust parser accepts a numeric scope: `[fe80::1%3]:1234` parses as `SocketAddr`; a zone *name* (`%usb0`) does not. Dart's `_irohSocketAddressForRoute` builds `[${address.address}]:port` from the parsed string, so it must normalise to the numeric index.
8. **Calls would not use the hints.** `send_datagram` dials through `warm_datagram_connection` with `EndpointAddr::new(id)` and no hints. Offline, a call whose peer has no pooled connection never connects. The Rust side must remember the last hints per peer (3.2).
9. **Iroh's port is random per start** (bound with port 0; one IPv4 and one IPv6 socket, two ports). Stored `directInternetRouteHints` therefore go stale at every restart, even on the same cable.
10. **Interface changes:** `main.dart` forwards `connectivity_plus` events to `onConnectivityChanged`, which refreshes LAN addresses, tells Iroh (`networkChanged`) and sends route updates. connectivity_plus reports the default network, so plugging a cable that is not the default route, or starting tethering on the phone (the phone's own default network does not change), may raise nothing. Iroh's netwatch monitors by itself on Linux (netlink) and Windows (IP-change notifications) but is a no-op on Android ("Android doesn't allow us to do this").

### 1. Approach in one paragraph

A cable is a LAN whose peer address is learned, not configured. The work is: (a) see the link appear and go (events, no polling); (b) find the contact on it with the beacon we already have; (c) remember what we saw in a **runtime-only table** (never persisted, never sent); (d) use it for the LAN transport and as fresh Iroh hints. Nothing about the cable enters invites, route updates, the vault or `identity.lanAddresses`.

### 2. Phases

**P1a (Dart + a tiny Rust trigger + Kotlin events): IPv4 on cables and tethering, with I1.** Covers phone USB tethering to a PC (DHCP from the phone), Windows APIPA (169.254), Linux with an IPv4 on the cable.
**P1b (Rust beacon + Dart v6 sockets): IPv6 link-local.** Zero-config Linux to Linux (no DHCP, no APIPA, so no IPv4 at all). Separate step with its own lab check, because it is the most platform-sensitive part. If the review prefers, P1b can ship a nightly later than P1a.
**P2 and P3:** see section 8.

### 3. P1 in detail

**3.1 Interfaces and the link table (new `lib/src/net/link_interfaces.dart`, `link_table.dart`).**
- `typedef InterfaceLister = Future<List<LinkInterface>> Function();` `LinkInterface {name, index, kind, v4: List<String>, v6LinkLocal: List<String> (bare, no zone)}`. The real lister calls `NetworkInterface.list(includeLoopback: false, includeLinkLocal: true)` (all families) and skips `isIgnoredLanInterfaceName`.
- `kind` is a pure function of the name: `cable` (`usb\d*`, `rndis`, `ncm`, `enx`, `enp*u*`, `eth\d` on Android, "Ethernet…" on Windows), `wifi` (`wlan`, `wlp`, `Wi-Fi`, `ap\d`), `other`. `kind` only decides labels and which interfaces get a v6 beacon; the ignore list stays the only filter. An interface joins the table when it is up and has a v4 address (private or 169.254) or an fe80 address.
- `discoverLanAddresses()` and `isLanDiscoveryAddress` stay as they are (same signature, same results, so `identity.lanAddresses`, invites, route updates and every existing test are untouched). The 169.254 and fe80 addresses live only in `LinkTable`, which the controller owns (field + clear on dispose and vault reset).
- A scoped v6 host is written `fe80::x%<ifindex>` (numeric, from `LinkInterface.index`), never the name: it parses on the three platforms, and it is what Rust wants. The zone is local to this process run: `LinkTable.observe` stores `(deviceId, address, ifIndex, ifName)` and drops the entry when that interface or index disappears. Wire input that contains `%` in a host is rejected (`isValidPeerEndpointHost` allows `%` today, so a contact could plant `fe80::1%eth0`; add the rule in `PeerEndpoint.normalized` for hosts that parse as v6 link-local, and in `isValidLanDirectHost`, which already compares `address.address != host`).
- Discovery on a new link (event-driven): for each new cable-class link with a v4 address, a short-lived `RawDatagramSocket` bound to that interface's own IPv4 (so the broadcast leaves on that link) sends the existing sealed `pairing_ping` to the directed broadcast guesses (`169.254.255.255` for 169.254; `a.b.c.255` otherwise) and `255.255.255.255`, then closes after 5 s. The peer's always-on listener answers with a unicast `pairing_route` to the ping's source address and port (the existing handler), which our long-lived listener receives. `_handlePairingBeaconDatagram` then calls `LinkTable.observe` for a known contact (or a member of a group we are in) instead of, for 169.254 and fe80 sources, `_rememberContactLanRouteFromBeacon` (which persists to `contact.routeHints` and must not for link-scoped addresses; RFC 1918 sources keep today's behaviour).
- Unknown-link fallback without a timer: a beacon from a v4 source that matches no listed interface subnet triggers one re-list (at most one per 10 s).
- The new link sends nothing to contacts by itself. Once the contact answered, the existing `_refreshAndAdvertiseLanDirectRoutes` path runs as for any network change (route update over the best route, now including the cable).

**3.2 LAN transport on the cable.**
- `_candidateRoutesForContact` (the single place delivery, probing and ranking read) gets one added spread: `..._linkRoutesForContact(contact)`, placed before `_lanRediscoveryRoutesForContact`. It returns runtime `PeerEndpoint(kind: lan, host, port: relayPort)` (tcp, and udp for v4 only) from `LinkTable`, newest first, max 4. Route health is runtime already (`RouteHealthTracker` is not persisted), so these never reach the vault. `_lanRediscoveryRoutesForContact` skips prefixes in 169.254/16 (no /24 scanning there).
- P1b: a second `ServerSocket.bind(anyIPv6, relayPort, v6Only: true)` next to the v4 one in `LocalRelayNode.start`, and the same for the LAN-direct `HttpServer`, so IPv4 behaviour and the IPv4 rate-limit keys are unchanged (no dual-stack, no `::ffff:` sources). If the v6 bind fails (no IPv6, port taken), log and continue without it. Outbound: raw `Socket.connect(scopedAddress)`; the LAN-direct HttpClient gets a `connectionFactory` (as `link_preview.dart` does) that maps a scoped host to `Socket.startConnect(scoped)`. The UDP LAN route has no v6 variant (Dart cannot send scoped UDP): v6 cable routes are TCP only.

**3.3 P1b: IPv6 link-local discovery (new `native/conest_native/src/link.rs`, FFI `conest_link_*`).**
- Rust owns the v6 beacon socket because only Rust can set `IPV6_MULTICAST_IF` and read/write scope ids (`socket2`, already in the tree through tokio; add as a direct dependency, MIT/Apache). One UDP socket on `[::]:7668` (`IPV6_V6ONLY`, `SO_REUSEADDR`), joined to `ff02::1` per cable-class interface index. Send: the same sealed ping bytes (built by Dart `LanBeaconCodec`) to `[ff02::1%idx]:7668` through a per-interface send socket with `IPV6_MULTICAST_IF=idx`. Receive: `(bytes, src fe80, scope id, ifindex)` for datagrams of at most 1024 bytes, queued (cap 64, oldest dropped) and fetched by a Dart poll worker in a helper isolate with the existing `conest_*_poll` pattern, started only while at least one cable-class link with fe80 exists. Replies are unicast to `[src%scope]:port` from Rust. Dart gets the sealed payload and the zone it must use; the zone is the interface index of the receiving socket, never read from the packet.
- Hostile-input limits: 50 opens a second (the existing window), one reply per source per second.

**3.4 Detecting interface changes without polling.**
- **Linux and Windows:** a new `LinkMonitor` in `link.rs` wraps `netwatch::netmon::Monitor` (netlink / `NotifyUnicastIpAddressChange`; MIT/Apache, version 0.19, already in the lock because of Iroh, so no new compile). Any state change, link-local included, updates its watchable (250 ms debounce built in). FFI: `conest_link_monitor_start() -> handle`, `conest_link_monitor_wait(handle, timeout_ms) -> generation` (blocks in a helper isolate up to 60 s; returns early on a change), `_stop`. Zero wakeups while nothing changes except the timeout, which only re-checks the stop flag. On a generation change Dart calls `onLinksChanged()`.
- **Android:** a Kotlin `LinkMonitor` (new file, registered like `RadioLinkPlugin`) sends events over a method channel from: `ConnectivityManager.registerNetworkCallback` (all transports; covers a USB Ethernet dongle on the phone), a registered receiver for `android.hardware.usb.action.USB_STATE` (extras `connected`, `rndis`, `ncm`: this is what announces USB tethering when the phone is the host) and `android.net.conn.TETHER_STATE_CHANGED`. Both broadcasts are not documented API and may vanish or be restricted on a newer Android; the receiver is registered only while Conest runs, and a registration error is caught and logged.
- **Bounded fallback, Android only:** while the app is in the foreground, LAN is on and the Cable page or a transfer is open, and the broadcasts have raised nothing, one `getifaddrs` look every 30 s (a call that lists at most 20 interfaces; cancelled on dispose, background, LAN off, cold mode). No fallback anywhere else, and none when events work (the first received event disables it for the run).
- All sources feed one debounced (500 ms) `LinkWatcher.changed` stream. The existing `connectivity_plus` path also calls it, so it is a superset. `onLinksChanged`: re-list; diff against the table; for each new cable-class link send the ping (3.1); for each vanished link drop its entries and call `iroh.networkChanged()` (this also clears the pooled Iroh connections); do **not** call the heavy `onConnectivityChanged` for a link that is not the default network (it clears route health and requeues transfers).

**3.5 I1: Iroh hints from fresh data (new `lib/src/net/iroh_hint_book.dart`).**
- `IrohHintBook` (controller field, bounded 64 peers x 8 entries, cleared on dispose and vault reset): `note(deviceId, host, scope, source, at)`, `notePorts(deviceId, v4Port, v6Port)`, `dropLink(ifIndex)`, `hintsFor(deviceId, persisted, now)`.
- Sources: the beacon (new optional fields `irohPort4`, `irohPort6`, see 4), the LAN route-update exchange (new optional `irohPorts` in the encrypted payload, or the ports of the contact's stored `directInternetRouteHints`, per family), and any inbound LAN/Iroh envelope from that peer (its source address, fresh by construction).
- `hintsFor` returns at most 8 strings, built as: (1) fresh entries seen in the last 10 minutes whose interface is still in `LinkTable`, newest first, at most 5, each `host:port` with the family's port (an entry without a known port is skipped, never guessed); (2) `contact.directInternetRouteHints` (today's list, order kept) minus duplicates, to fill up to 8. Link-local v6 is written `[fe80::x%idx]:port`. No fresh data means exactly today's behaviour.
- Hook: `_transportPeerForContact` swaps its `directAddresses` expression for `_irohHintBook.hintsFor(...)`. One line in the big file; the new code is in the new files. Dial fallback is unchanged (`_irohDirectHintAttemptTimeout` 12 s, then a hint-less attempt, so stale hints cost at most 12 s on top of the other routes, which run independently).
- Refresh: `onLinksChanged` (3.4) and `onConnectivityChanged` both call `dropLink`/`pruneForLinks`; a new route update with ports replaces the ports; a TTL expiry is checked at read time (no timer).
- **Rust side** (`api.rs`): `NativeTransport` keeps a bounded `hint_cache: HashMap<EndpointId, (Instant, Vec<SocketAddr>)>` (64 entries, 8 addresses, 10 minutes, read at use), filled by `send_to_with_hints` and used by `connection_for` and by `warm_datagram_connection`, so a call dials with the hints of the envelope that preceded it. `network_change` and `close` clear it. `send_to_with_hints` keeps its 8 limit and now accepts a numeric scope id (`[fe80::1%3]:p` already parses with `SocketAddr::from_str`; the test pins it, the zone name is refused with a clear error).
- No mDNS, as decided. Iroh authenticates the endpoint id in the handshake, so a hint to a wrong or hostile address can only fail; it cannot impersonate.

### 4. Wire and compatibility

- **No new capability.** Everything we add works with peers on the old build: the beacon and the ping/reply are unchanged on the wire. New fields are optional and ignored by old apps (JSON maps read by key): beacon `pairing_route` gets `irohPort4`, `irohPort6` (ints 1..65535); the route-update payload gets `irohPorts: {v4, v6}`. Missing fields: ports come from the stored `directInternetRouteHints` per family; if neither exists the entry is unusable and Iroh dials as today (the LAN transport still works over the cable).
- Old peer next to a new one on a cable: the new side finds it through the ping/reply (old apps answer pings), uses LAN, and uses Iroh only with ports it can derive. Pitfall 14 does not apply: nothing relies on the peer's new behaviour.
- Link-local and zone ids never leave the device: not in invites (`_inviteRouteHintsForIdentity` reads `identity.lanAddresses`, unchanged), not in `senderLanAddresses` (reads the same list), not in `contact.routeHints`, not in the vault, not in group membership profiles, not in logs beyond the interface name. This is also the privacy answer: an fe80 address can embed the MAC (EUI-64) and a 169.254 is per-link, and neither means anything off the link.

### 5. Invariants against Known pitfalls 1-20

1. Inbound path: the ping reply and the route-update reply are queued with `unawaited` as today; a beacon handler only mutates the table (sync). Met.
2. Seal at transport turn: no envelope handling changes; hints are a dial parameter only. Met.
3. No polling or timers: events (netlink, Windows notifications, Android callbacks); one Android foreground fallback (30 s, bounded, off once events work); ping sockets close after 5 s; every timer is cancelled on dispose, LAN off and cold mode. The Rust wait is a blocking call, not a loop. Test with fakeAsync: zero pending timers after dispose.
4. Relay lease: not touched.
5. Limiter refusal: not touched.
6. New state cleared on dispose and vault reset: `LinkTable`, `IrohHintBook`, ping sockets, the v6 beacon queue, Rust `hint_cache`, monitor handle, subscriptions. Tests for dispose and reset.
7. Hold conditions: none added.
8. Store is not delivery: not touched.
9. Authorisation before side effects: a beacon updates the table only for a known contact or group member deviceId; unknown ids are ignored before any state change (including the re-list trigger, which is rate-limited).
10. Counters: the "unknown source re-list" counter counts every beacon path (v4 listener and the v6 Rust queue); test both.
11. No synchronous recursion: `onLinksChanged` schedules through the debounce, never calls itself.
12. Bounded memory: table 16 links x 4 addresses; hint book 64 peers x 8; Rust queue 64; hint cache 64 x 8; all expire at read time.
13. Vault bytes: nothing stored (runtime only). The optional `cableLinksEnabled` pref is one bool.
14. Capability: not needed (4).
15. "Works means delivered": cable routes rank by the existing route health (receipts), not by "seen in a beacon". A beacon only makes a candidate.
16. Seal at the last queue: not touched.
17. A failing head: a dead cable route fails like any LAN route (existing backoff, rotation); route health is cleared for a vanished link.
18. Migrations: none; no stored data changes.
19. No parsing in hot paths: classification and parsing happen at link-change time and beacon time, results cached; `hintsFor` is a sort of at most 8 prebuilt strings, no JSON, never in a build method; the Cable page reads a cached snapshot.
20. No date bombs: `LinkTable` and `IrohHintBook` take an injected clock; tests use only that clock for every timestamp.

### 6. Failure cases

- **Stale hints:** TTL 10 min, dropped when the interface goes, ports replaced on every update; a stale one costs at most the 12 s hinted attempt, then the hint-less retry.
- **Zone id differs per host:** each side builds its own zone from its own interface index; the wire never carries one; a `%` in wire input is rejected. Test: A sees the peer on index 3, B sees A on index 7, both connect.
- **Two cables (or cable plus Wi-Fi, or two phones):** entries are kept per `(device, interface)`; hints newest first, at most 5 fresh; the LAN candidate list takes up to 4. Both interfaces get a ping. Unplugging one drops only its entries; Iroh's pooled connections are cleared and redial on the remaining one.
- **Cable unplugged mid-transfer:** `iroh.networkChanged()` clears the pool; the file layer's existing resume (ranges are idempotent) continues on the next route; LAN-only transfers go to `waitingForLan` through the existing check once `_hasUsableLargeDirectTransport` is false. No new transfer logic.
- **Tethering on while Wi-Fi is also on:** both stay; the cable route is a candidate beside the Wi-Fi LAN route; Iroh gets both fresh hints and QUIC picks the best path. The `noteNetwork` history is not told about the cable (it is not the default network), so a cable does not rewrite network history.
- **Link-local leaking to contacts:** by construction it cannot (4); test asserts that encoded invites and route updates contain no `169.254`, `fe80` or `%` while a cable is up.
- **Hostile LAN neighbour forging a beacon for a contact's deviceId:** it gets a candidate route that fails the end-to-end authentication, and an Iroh hint that fails the handshake. Same exposure as today's persisted beacon routes, now runtime only.
- **IPv6 unavailable (disabled in the kernel):** the v6 bind and the Rust socket fail, are logged, and P1a keeps working.
- **Phone app in the background:** unchanged: Android may block sockets; the foreground service already handles LAN.
- **Windows firewall prompt:** the first listener on a new network profile (the cable is often "Unidentified network", public) may be blocked; the Cable page says so in one line. Lab item.

### 7. Settings page "Cable and USB" (fast lane, behind `canaryFeatures`, built to the M59 page spec)

New `lib/src/ui/cable_links_panel.dart`, one entry in the Connectivity list; no logic in `main.dart` beyond that entry.
- **Top:** switch "Use cable and USB links" (default on; `cableLinksEnabled`, optional bool in the connectivity prefs). Off: no ping, no table, no hints, no v6 socket.
- **List of detected links** (from a cached snapshot, updated by the watcher): name, kind ("USB tethering", "Ethernet cable", "Wi-Fi"), state ("Contacts reachable: Anna, Ben" / "No contact found yet" / "Waiting for an address"), the IPv4 only (fe80 never shown).
- **Android:** button "Open tethering settings" (intent `android.settings.TETHER_SETTINGS`, falling back to wireless settings; apps cannot switch tethering on).
- **Help (three lines, plain):** "Plug in a cable or turn on USB tethering. Conest finds your contacts on it by itself, with no router and no internet." / "On Linux with no router, give both ends 'Link-local only' in the network settings." / "Windows may ask to allow Conest on this network: choose yes."
- Not applicable: the censored-network gate (local links); accounts and budgets (no account; energy: the fallback timer follows the energy policy and is off in cold mode). Strings go into the six ARBs. Instances/budgets: none needed. Shared chat view: not a chat network. Files: through the existing LAN and Iroh paths (`route_striper` sees them as routes). Tiers (M59): the cable is a LAN-class route; the tier is "LAN only" with no cost class.
- **Group parity:** the table and hint book are keyed by deviceId and read wherever a `TransportPeer` or a LAN endpoint is built, so group sends and group file downloads (`_groupLanDirectEndpoint`, `_transportPeerForContact`) use the cable for members on it. Members who are not contacts are accepted into the table when their deviceId is in a group we belong to; to be checked in the implementation that the group-only member path builds its peer through the same function (if it does not, it gets the same one-line hook).
- **Own devices (M45):** merge/relay/replace need nothing here. Link data is per device and never shared (zone ids and addresses mean nothing elsewhere). An own device on the cable is simply a contact-like peer reached on the cable.

### 8. P2 and P3: recommendation

**P2 (Android Open Accessory): do not start it in this milestone; if wanted, Linux-only as a separate later milestone behind canary; defer Windows.**
- Gain is small: AOA is a USB 2.0 bulk pipe (about 25-35 MB/s in practice), the same order as USB tethering. Its value is "no tethering switch and no IP stack", not speed.
- The Android half is easy (Kotlin `UsbAccessory`, an accessory filter and one permission dialog per attach, no root).
- The PC half is the cost. libusb must first send the AOA control requests (get protocol 51, send strings 52, start 53) to the phone while it is in MTP/ADB/charging mode, then talk to it re-enumerated as VID 18d1 PID 2d00/2d01. On Windows both steps need the device bound to WinUSB/libusbK: the accessory PID has no inbox driver and does not publish Microsoft OS descriptors, and the phone's first mode is owned by the MTP/ADB driver. That means Zadig or a signed driver package with admin rights, per phone model. This is not an acceptable first-run experience. On Linux it needs a udev rule (`uaccess`) and works otherwise.
- Licences: `rusb` is MIT; libusb is LGPL-2.1+. Linking libusb dynamically (system `libusb-1.0.so.0` on Linux; a `libusb-1.0.dll` shipped beside the app on Windows) is compatible with MPL-2.0 for `conest_native`. Do not enable `rusb`'s `vendored` feature in shipped builds (static LGPL).
- Tethering already gives a driverless USB path on Windows (RNDIS is inbox but being phased out; NCM is inbox on Windows 11 only, and Pixel 6 and later phones use NCM; to be confirmed in the lab), which is what P1 uses. Revisit AOA only if tethering proves unreliable in the lab.
**P3 (CDC-ACM serial link): defer.** `ByteLink` is a stream for radio protocols; a Conest peer link on it would need a new session layer (identity handshake, framing with checksums, retransmit, flow control) plus a transport adapter, for a niche (PC to PC serial adapters, phone OTG to serial). Linux has `UnixSerialLink` already; Android would need a USB serial library (usb-serial-for-android, MIT). Decide after P1 is in the lab; M64 uses the IP path first.

### 9. Tests and strict fakes

**Make the fakes strict first (own commit):** (1) a `FakeInterfaceLister` with the real Dart semantics (drops `isLinkLocal` addresses unless `includeLinkLocal` is true, which is exactly the bug that hid 169.254), zone names resolved only for interfaces that exist, `%name` parse failing for unknown names; (2) a `FakeBeaconNetwork` with the real limits: datagrams over 1024 bytes dropped, no scope on IPv6 UDP send from Dart, receive addresses without zone, v4 as `::ffff:` on dual-stack, unicast reply goes to the ping's source; (3) a recording Iroh bridge (`test/support/recording_iroh_bridge.dart`, built from `_InProcessIrohBridge`) that stores every `directAddresses` argument and rejects more than 8 and any `%name` zone, like the Rust side.
**Dart tests (new files, plus a small block in `messenger_controller_test.dart`):**
- `link_interfaces_test.dart`: classification table (usb0, rndis0, ncm0, enx..., enp0s20f0u2, Ethernet 3, vs docker0, tun, wg0, rmnet); 169.254 and fe80 collected; scoped host uses the numeric index; `discoverLanAddresses` results unchanged for the existing cases.
- `link_watcher_test.dart` (fakeAsync): coalescing of a burst; new link triggers one ping; vanished link drops entries; dispose leaves no timers; the Android fallback runs only while foreground and stops after the first event.
- `iroh_hint_book_test.dart`: order newest first; 5 fresh + persisted fill to 8; cap on peers; TTL by injected clock; prune on link removal; per-family ports; entry without port skipped; reset clears.
- Controller tests: no internet and relay off, a beacon from a contact on 169.254 yields hint[0] = `169.254.x.y:port` on the next send; link removal removes it; two cables give both; cable plus Wi-Fi keeps both; unknown deviceId ignored; out-of-range port ignored; a ping is answered; invites and route updates contain no link-local or `%`; `contact.routeHints` and the vault snapshot contain none; group member on the cable uses it; a late call dial uses the cached hints (fake bridge).
**Rust tests (CI only):**
- hinted dial from a fresh sender with relay disabled (no prior connection, no discovery) succeeds using only the hint;
- `send_datagram` after the pooled connection is evicted warms with the cached hints; the cache is bounded (65th evicts), expires (paused tokio time), and `network_change` clears it;
- numeric scope id parses; a zone name is refused;
- **link-local connect:** an `#[ignore]`d test run by a new step in `rust-tests.yml` after `sudo ip link add cn0 type dummy; ip link set cn0 up; ip addr add 169.254.77.1/16 dev cn0`, with the interface name in `CONEST_TEST_LL_IFACE`: two endpoints with relays off connect by `[fe80::x%idx]:port` and by `169.254.77.1:port`. This is the test the plan asks for; it also answers whether Iroh's default `[::]` socket sends to a scoped destination (the source says yes);
- `LinkMonitor` unit test with an injected change source: `wait` returns on a change and on timeout, stop ends the wait.
**Sabotage checks (each recorded in the log):** drop `includeLinkLocal`; persist a link-local route into `contact.routeHints`; remove the `%` rejection; remove the 8 cap; remove the TTL; skip `dropLink`; skip clearing on dispose; Rust: strip the scope id before parsing; stop filling or reading the hint cache. The Rust ones run on `sabotage/m54a-*` branches in CI.
**Lab check needed** (main session, after the first green debug run): phone 1 to Linux over USB tethering with Wi-Fi off and internet blocked (message, 100 MB file, call, over LAN and over Iroh); Linux to Windows direct cable (APIPA) and Linux to Linux (fe80 only, P1b); unplug mid-transfer; tethering plus Wi-Fi; Windows firewall prompt; Android receiver broadcasts on the lab phones' Android versions; measured throughput.

### 10. Open questions for the maintainer

1. **Scope of P1b (IPv6 link-local):** include it now as the second step (my recommendation, since Linux to Linux needs it and the plan lists fe80), or ship P1a first and decide after its lab?
2. **169.254 and `identity.lanAddresses`:** I keep link-local out of that list and out of everything sent to contacts (the plan item "169.254 included" is met by the runtime link table instead). Agree? The alternative (put them in `lanAddresses`) leaks them into invites and persists them, and I advise against it.
3. **Second netwatch monitor:** a small `LinkMonitor` in `conest_native` duplicates what Iroh runs internally (one extra netlink socket). Accept, or prefer exposing Iroh's own state through an Iroh patch? I advise accepting.
4. **Android receivers** for `USB_STATE` and `TETHER_STATE_CHANGED` are undocumented; fine for a first version with the foreground fallback, or do you want a lab result on the target Android versions before relying on them?
5. **P2:** confirm "Linux-only later, Windows deferred", and P3 deferred.
6. **CI sudo step:** the link-local Rust test needs `sudo ip link add ... type dummy` on the GitHub runner. OK to add it to `rust-tests.yml`?

## Handoff

(to be written by the agent)

## Progress log

- 2026-11-04: design note written (no code). Checked the Today facts against the code, the Dart SDK 3.12.1 sources, Iroh 1.0.3 and netwatch 0.19.1; two spikes in the scratchpad (not in the repo) confirmed that Dart UDP ignores IPv6 scope ids and that `includeLinkLocal` hides 169.254. Corrections are in section 0. Decision: keep link-local out of `identity.lanAddresses` and out of everything sent to contacts, use a runtime link table. Waiting for the design review.

## Maintainer's answers to the design note's open questions (2026-11-05)

1. **IPv4 first:** ship P1a (IPv4: 169.254, tethering subnets, I1 hints) first. P1b (IPv6 link-local) comes after P1a's lab.
2. **Link-local addresses stay local:** 169.254 and fe80 addresses never go into `identity.lanAddresses` or anything sent to contacts. They live in the runtime table only.
3. **Second netwatch monitor:** a second monitor in `conest_native` is fine.
4. **Android broadcasts:** rely on them, with the bounded foreground fallback. Verify them in the lab.
5. **P2 and P3:** P2 (AOA) comes later, Linux only, with Windows deferred. P3 (serial) is deferred.
6. **Rust link-local test:** a CI-only dummy-interface step in `rust-tests.yml` is fine.

Implementation waits for the Opus design review. Its findings will be appended here.

## Design review (Opus, 2026-11-05): revise first

The review's verdict was "revise first". Both HIGH findings need small changes to the note, not a redesign. Fold all the items below into the Design note.

### HIGH

**H1. Link routes are saved into `contact.routeHints` and the vault, which breaks decision 2.**
- **Cause:** link routes added to `_candidateRoutesForContact` are written by `_rememberLanRoutesForContact` (~34228) through four paths:
  - route selection (~2227);
  - `checkContactRoutes` (~10866);
  - a LAN delivery (~31909);
  - the LAN probe (~32560).
- **Effect:** 169.254 addresses, and fe80 addresses with their zone, outlive the cable in the vault.
- **Fix:**
  - reject link-local addresses and any host containing `%` in `_rememberLanRoutesForContact` (one choke point), and keep the planned divert in `_rememberContactLanRouteFromBeacon`;
  - put the same rule in `prunePeerEndpointsByKind`;
  - test: deliver over the cable first, then assert that no such host is in the vault.

**H2. The cable ping's reply goes to the ping socket's ephemeral port, not to 7668.**
- **Cause:** the handler at ~20786 replies to `datagram.address:datagram.port`. Old peers do the same and can't be changed.
- **Fix:**
  - the ping socket listens for its 5 s lifetime and feeds `_onPairingBeaconDatagram`, with the same 50/s limiter and counters;
  - `FakeBeaconNetwork` models a separate port per socket, so this case is caught.

### MEDIUM

**M1. Forged beacons can crowd out the real entry** (a denial of service on shared segments).
- Once an entry for a (device, link) is confirmed by an authenticated success (a receipt over that route, or an Iroh connection), pin it. Unconfirmed entries never evict it.
- At most 2 unconfirmed entries per (device, link).
- At most one deviceId per source address.

**M2. Drop the inbound-source hint source:**
- Iroh: `NativeInboundEnvelope` carries no source address.
- LAN: note the source only after the envelope decrypts with sender == deviceId, and only if it was not forwarded or stored. A forwarder's or depositor's address must never be mapped to the original sender.

**M3. The LAN-direct file path never gets a link-local endpoint**, because `senderLanAddresses` excludes link-local and `_groupLanDirectEndpoint` reads only `lanRouteHints`.
- Build a runtime `LanDirectEndpoint` from the LinkTable host plus the peer's advertised LAN-direct port. Use it for 1:1 files and group files (group parity).
- If that is not feasible, state that link-local files go over Iroh, and measure it in the lab.

**M4. The Android fallback is switched off as soon as it starts.**
- `registerNetworkCallback` calls `onAvailable` at once, and tethering with the phone as host raises no callback.
- Only a `USB_STATE` or `TETHER_STATE_CHANGED` event switches the fallback off.
- Also observe a known contact's ping source (the host only).

### LOW

- **Fact 8:** Iroh keeps app-supplied paths until its actor has been idle for 60 s.
  - Don't clear the Rust hint cache on every `network_change`. Overwrite or prune it instead.
- **Hint order:**
  - fresh hints may take only 8 minus the number of stored hints (at least 4 fresh);
  - stored hints go up to 4 (`maxDirectInternet`).
- **A bad hint:** `send_to_with_hints` gives up on the first hint it can't parse.
  - The Dart side drops entries it can't normalise.
  - The recording fake fails the whole send in that case.
- **`LinkMonitor` stop and dispose:**
  - `stop` signals the waiter at once (condvar);
  - the handle is freed only after the blocking wait returns (shared ownership);
  - test: dispose while a wait is running.
- **First contact over a cable:** when a contact or group member is added, send a ping on the cable links already present.
- **Privacy:** state in the note that `irohPort4`/`irohPort6` go out in the cleartext beacon unless quiet LAN is on, and that cable pings broadcast the deviceId. This is the same exposure as the existing `checkContactRoutes` pings.
