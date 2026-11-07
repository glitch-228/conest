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

Revised 2026-11-06 after the Opus review and the maintainer's answers (both are at the end of this file). Section 11 lists how each finding was handled.

### 0. Verified facts, and corrections to "Today"

Checked in the code, the Dart SDK 3.12.1 sources, Iroh 1.0.3 and netwatch 0.19.1 (cargo registry). Line numbers in "Today" are stale (`messenger_controller.dart` is now 44.8k lines); the functions exist as described unless noted.

1. **169.254 is dead code today.** `discoverLanAddresses` calls `NetworkInterface.list` without `includeLinkLocal: true`, and Dart then drops every address whose `isLinkLocal` is true (`socket_patch.dart`). No 169.254 or fe80 address is ever collected.
2. **IPv4 tethering subnets already pass the interface filter.** `isIgnoredLanInterfaceName` does not match `usb0`, `rndis0`, `ncm0`, `enx<mac>`, `enp0s20f0u2`, `Ethernet 3`, `Remote NDIS based Internet Sharing Device` (read against the fragment list; a test will lock it; Windows and Android names unverified). So with DHCP from the phone the address is already collected. Missing: an event when the cable appears, finding the peer on it, and Iroh hints.
3. **All LAN listeners are IPv4 only:** local relay `ServerSocket` and `RawDatagramSocket`, the LAN-direct `HttpServer`, and the beacon socket all bind `anyIPv4`.
4. **The beacon sends periodically only during a pairing session** (`_isPairingSessionActive`). The listener is always up, and a `pairing_ping` is always answered, by a unicast `pairing_route` **to the ping's source address and port** (`_handlePairingBeaconDatagram`, sent from the long-lived socket). The existing discovery ping is sent from that same socket (bound to 7668), so its replies come back to 7668. A ping from any other socket gets its reply on that socket's port (H2).
5. **The beacon carries `deviceId` and `relayPort`, not the Iroh or LAN-direct port.** Rediscovery routes scan /24 neighbours, which is useless on 169.254/16; `_directedBroadcastAddress` assumes /24.
6. **Dart cannot do IPv6 link-local UDP.** `RawDatagramSocket` send and bind ignore scope ids (a scoped send went nowhere; bind on a scoped address fails EINVAL), `multicastInterface` throws, and received sources carry no zone. Scoped TCP works (`Socket.connect(InternetAddress('fe80::x%3'))`; a bare `fe80::x` fails EINVAL). A zone is host-local and must never cross the wire. Raw TCP to this host's own fe80 was reset (host firewall), so there is no local loopback test: CI veth or the lab.
7. **Iroh already sends to a scoped link-local address** (`iroh/src/socket/transports/ip.rs` matches the destination scope id) **but never publishes one**: netwatch leaves out fe80 and keeps 169.254 only when the device has no other address. Offline, hints are the only way in. Rust parses `[fe80::1%3]:p` (numeric scope only; `%usb0` fails). `send_to_with_hints` returns an error on the **first** hint it cannot parse (`api.rs` loop with `?`).
8. **Iroh keeps app-supplied paths** (`paths.insert_multiple(addrs, Source::App)`, `remote_state.rs`) while its per-peer actor lives, 60 s after it goes idle (`ACTOR_MAX_IDLE_TIMEOUT`). `send_datagram` warms through `EndpointAddr::new(id)` with **no hints** (`warm_datagram_connection`), so an offline call whose peer has no pooled connection never connects.
9. **Iroh's ports are random per start** (one v4 and one v6 socket, port 0). Stored `directInternetRouteHints` go stale at every restart. `NativeInboundEnvelope` carries `sender_endpoint_id`, bytes and path only: no source address.
10. **Interface changes:** `connectivity_plus` reports the default network, so a cable that is not the default route, or tethering started on the phone (host side), may raise nothing. netwatch monitors by itself on Linux (netlink) and Windows but is a no-op on Android.
11. **Route data is written to the vault in five places**, all through `_rememberLanRoutesForContact` (route selection ~2227, `checkContactRoutes` ~10866, a LAN delivery ~31909, the LAN probe ~32560) and `_rememberLanRoutesForGroupMember` (~29789, writes the group member profile). Route health itself is runtime only (not persisted). Today's beacon can already persist a 169.254 source into `contact.routeHints` (APIPA networks), so old vaults may hold some.
12. **LAN-direct files:** `_localLanDirectHintPayload` returns `{}` when the device has no RFC1918 address, and `_cachePeerLanDirectFromPayload` returns on an empty address list. A pure link-local cable therefore never learns the peer's LAN-direct port. The LAN-direct HTTP port is the relay port when `attachmentHttpPort` is set (`attachmentIngressPort`).

### 1. Approach

A cable is a LAN whose peer is learned, not configured. (a) See the link appear and go (events, no polling). (b) Find the contact on it with the beacon we have. (c) Prove it with one authenticated probe. (d) Keep what we learned in a **runtime-only `LinkTable`** (never persisted, never sent) and use only **confirmed** entries for the LAN transport, LAN-direct files and fresh Iroh hints. Link-local addresses and zone ids never enter the vault, `identity.lanAddresses`, invites, route updates or group profiles.

### 2. Phases

**P1a (Dart, a small Rust monitor, Kotlin events): IPv4**: 169.254, tethering subnets, DHCP-less Windows (APIPA), and I1 hints. Ships first.
**P1b (Rust beacon, Dart v6 sockets): IPv6 link-local** for zero-config Linux to Linux. After P1a's lab (maintainer decision 1); section 3.7 is a sketch to be finalised then.
**P2, P3:** section 8.

### 3. P1 in detail

**3.1 Interfaces and the link table (new `lib/src/net/link_interfaces.dart`, `link_table.dart`).**
- `typedef InterfaceLister = Future<List<LinkInterface>> Function()`; `LinkInterface {name, index, kind, v4, v6LinkLocal}`. The real lister calls `NetworkInterface.list(includeLoopback: false, includeLinkLocal: true)` and skips `isIgnoredLanInterfaceName`. `kind` (cable / wifi / other) is a pure function of the name and only decides labels and which links get a ping; the ignore list stays the only filter.
- `discoverLanAddresses`, `isLanDiscoveryAddress` and `identity.lanAddresses` are unchanged. Link-local addresses live only in `LinkTable`, a controller field cleared on dispose and vault reset, with an injected clock.
- **Entry:** `{deviceId, ifIndex, ifName, address, relayPort, seenAt, confirmedAt?}`. Created only for a `deviceId` that is a contact or a member of a group we belong to (pitfall 9), from a beacon or ping whose source matches a listed interface subnet.
- **Bounds and anti-forgery (M1).**
  - At most 2 unconfirmed entries per (device, link); at most 2 confirmed.
  - An unconfirmed entry expires after 60 s.
  - A confirmed entry is pinned: only a newer confirmed one, the link going away, or its route failing evicts it. Unconfirmed entries never evict it.
  - One deviceId per source address: the first claim wins, and a confirmed address cannot be claimed by another id.
  - Total 16 links x 8 entries.
- **Confirmation is one authenticated round trip, the cable probe.** For a new unconfirmed entry the controller sends one `route_update` (`reason: 'cable_probe'`, `requestReply: true`, a fresh `probeId`) over that entry's route only (`_sendRouteUpdate(routes: [entry])`, the existing explicit-route path), unawaited, at most one per entry per 30 s and 4 in flight. The payload is encrypted to the contact, so a forger at that address learns nothing. The matching authenticated reply (`_pendingRouteUpdateProbes`, one added line) calls `LinkTable.confirm`. A new peer answers a `cable_probe` also over every entry it holds for the sender (one added line next to the existing reply), because an offline peer has no other route back. An **old peer** answers over its own routes: that works with DHCP tethering (it has our RFC1918 address) and not on a pure-APIPA cable, where such a peer stays unconfirmed and unused. This is not a regression: old apps could not use link-local at all.
- **Both probe payloads carry** a new optional, encrypted `linkPorts: {iroh4, iroh6, direct, binary}` (ints; Iroh's v4/v6 ports from its status, the LAN-direct ingress port, the binary-block version). Old peers ignore it. Ports are taken only from authenticated payloads, never from beacons.

**3.2 Discovery on a new link (event-driven, with the H2 fix).**
- For each new cable-class link with a v4 address, open a short-lived `RawDatagramSocket` bound to that interface's own IPv4 (so the broadcast leaves on that link; Linux picks the device by the bound source for 255.255.255.255, Windows to be checked in the lab) with broadcast enabled, send the sealed (and, unless quiet LAN, cleartext) `pairing_ping` to `255.255.255.255` and the directed broadcast (`169.254.255.255` on 169.254; `a.b.c.255` otherwise), and keep the socket **listening for 5 s**. The ping carries a new optional `relayPort` (same data the route beacon already carries) so the peer can address us.
- **Replies arrive on this socket's ephemeral port, not on 7668.** Its datagrams are fed to `_onPairingBeaconDatagram` (same 50/s limiter, same `LanBeaconCodec.open`, same counters as the long-lived listener: pitfall 10), then closed.
- `_handlePairingBeaconDatagram` for a link-scoped source (169.254, fe80) calls `LinkTable.observe` instead of `_rememberContactLanRouteFromBeacon`; RFC1918 sources keep today's persisting behaviour. A ping from a known contact with a `relayPort` also creates an entry (and is answered as today).
- A beacon or ping from a known contact whose source matches no listed interface subnet triggers one re-list (at most one per 10 s; counts on every path).
- **First contact over a cable:** adding a contact or a group member sends a ping on the cable links already present (rate limited 1 per 10 s).
- Nothing is sent to contacts by the new link itself. After confirmation the existing `_refreshAndAdvertiseLanDirectRoutes` runs as for any change, and it never names link-local addresses.

**3.3 Nothing link-local reaches the vault (H1).**
- One predicate `isLinkScopedHost(host)`: parses as an IP with `isLinkLocal` (169.254/16, fe80::/10), or contains `%`.
- Applied at: `_rememberLanRoutesForContact` (the single choke point of four callers), `_rememberLanRoutesForGroupMember` (the fifth sink: group member profiles), the beacon divert (3.2), and the wire ingestion of routes: the four `invite.routeHints` sites (~13137, 13328, 13661, 26764) and group profile ingestion. These use a new flag `prunePeerEndpointsByKind(..., dropLinkScoped: true)`. **The flag defaults to false**: `prunePeerEndpointsByKind` also runs on every vault load, and pitfall 18 forbids deleting stored data, so routes already in old vaults are kept (they are ordinary stale LAN hints); only new writes and wire input are filtered. `isValidLanDirectHost` also rejects any `%` (today `fe80::1%3` from a contact passes it).
- A link route is a runtime candidate only: `_candidateRoutesForContact` gets one added spread, `..._linkRoutesForContact(contact)` (confirmed entries, newest first, at most 4, tcp and, for v4, udp). `_lanRediscoveryRoutesForContact` skips 169.254 prefixes. Because the candidates feed the four remember paths, the filter above is what keeps them out of the vault; the test delivers over the cable and then asserts the vault snapshot has no link-local host.

**3.4 Detecting interface changes without polling.**
- **Linux and Windows:** a `LinkMonitor` in new `native/conest_native/src/link.rs` wraps `netwatch::netmon::Monitor` (netlink / Windows IP-change notifications; already in the lock because of Iroh; a second monitor is accepted, decision 3). FFI `conest_link_monitor_start/wait/stop`: `wait(handle, timeout_ms)` blocks in a helper isolate up to 60 s and returns early on a change. `stop` signals the waiter at once (condvar), and the handle is freed only after the blocked wait has returned (shared ownership); a test disposes while a wait is running.
- **Android:** a Kotlin `LinkMonitor` (new file, registered like `RadioLinkPlugin`) sends method-channel events from `ConnectivityManager.registerNetworkCallback`, `android.hardware.usb.action.USB_STATE` (extras `connected`, `rndis`, `ncm`) and `TETHER_STATE_CHANGED`. The two broadcasts are undocumented and may vanish; we rely on them with the fallback below and verify them in the lab (decision 4). The initial sticky delivery at registration is ignored.
- **Bounded fallback, Android only (M4).** `registerNetworkCallback` fires `onAvailable` at once for the existing networks, and tethering with the phone as host raises no network callback. So **only a `USB_STATE` or `TETHER_STATE_CHANGED` event received after registration switches the fallback off**; network callbacks never do. While the app is foreground, LAN is on, and the Cable page or a transfer is open: one interface listing every 30 s (cancelled on dispose, background, LAN off, cold mode). The unlisted-subnet trigger in 3.2 also catches a host-side link. No fallback on other platforms.
- All sources feed one debounced (500 ms) `LinkWatcher.changed` stream; `connectivity_plus` calls it too. On change: re-list, diff, ping new cable links, drop entries of vanished links (also their seeded `_peerLanDirect` endpoints and hint-book entries), and call `iroh.networkChanged()`. The heavy `onConnectivityChanged` (clears route health, requeues transfers) is not called for a link that is not the default network.

**3.5 I1: Iroh hints from fresh data (new `lib/src/net/iroh_hint_book.dart`).**
- `IrohHintBook` is a controller field (64 peers x 8 entries, cleared on dispose and vault reset, injected clock and lookups). `hintsFor(contact)` returns at most 8 strings, built as follows.
  1. `stored` = the first 4 of `contact.directInternetRouteHints` (udp, normalisable; today's order). Four is `maxDirectInternet`.
  2. `fresh`, newest first, de-duplicated against `stored`, at most `8 - stored.length` (so at least 4): **confirmed** `LinkTable` entries (seen within 10 min, link still present), then healthy LAN hosts of the contact (`contact.lanRouteHints` whose route health is `available` and checked within 10 min). Each host is paired with the peer's authenticated `linkPorts` for its family (iroh4 for v4, iroh6 for v6); without `linkPorts`, with the port of a stored hint of that family; with neither, the host is skipped (never guessed).
  3. Result = `fresh + stored`. Entries the Dart side cannot normalise are dropped here, before the call (Rust fails the whole send on the first bad hint).
- No fresh data means exactly today's hints. The hook is one line in `_transportPeerForContact`. The 12 s hinted attempt then hint-less retry in `IrohTransportAdapter.sendEnvelope` is unchanged, so a stale hint costs at most 12 s on that route while other routes run on their own.
- Refresh: `onLinksChanged` and `onConnectivityChanged` prune entries; new `linkPorts` replace the ports; TTL is checked at read time (no timer).
- **Rust (`api.rs`).** `NativeTransport` keeps a bounded `hint_cache: HashMap<EndpointId, (Instant, Vec<SocketAddr>)>` (64 peers, 8 addresses, 10 min, expiry at read). **Every `send_to_with_hints` replaces the peer's entry; an empty list removes it** (the hint-less retry after a failed hinted attempt therefore clears a bad cache). `connection_for` and `warm_datagram_connection` read it, so a call dials with the hints of the envelope that preceded it. **`network_change` does not clear it** (Iroh itself keeps `Source::App` paths for 60 s of idleness, fact 8); `close` does. A numeric scope parses; a zone name is refused with a clear error.
- No mDNS, as decided. Iroh authenticates the endpoint id in the handshake, so a wrong hint can only fail.

**3.6 LAN-direct files on the cable (M3).**
- On `LinkTable.confirm`, if the peer's `linkPorts.direct` is known and no usable cached endpoint on an RFC1918 host exists, seed the existing runtime map: `_peerLanDirect[deviceId] = LanDirectEndpoint(host: entry.address, port: direct, binaryBlockVersion: binary)`. That map is already runtime only, cleared on connectivity change, 30-minute fresh and demoted after failures. 1:1 files read it everywhere, and `_groupLanDirectEndpoint` reads it first, so **group file downloads from contacts on the cable use it too** (group parity). On link removal the endpoints seeded from it are removed, and the existing `waitingForLan` check runs.
- Group members who are not contacts have no 1:1 route update, so their files use Iroh with hints (their profile has `irohEndpointId`; `_groupMemberContact` builds the peer through the same `_transportPeerForContact`).
- The lab measures LAN-direct against Iroh throughput on a real cable; if LAN-direct proves slower, the seeding is switched off and files go over Iroh.

**3.7 P1b sketch: IPv6 link-local (after P1a's lab).** Rust owns one UDP socket on `[::]:7668` (`IPV6_V6ONLY`, `SO_REUSEADDR`) joined to `ff02::1` per cable-class ifindex, sends with `IPV6_MULTICAST_IF` through `socket2`, and returns `(bytes, src, ifindex)` through a bounded queue (64) polled by a helper isolate only while an fe80 cable link exists. The zone is the receiving interface index, never read from the packet. Dart adds v6-only listeners (`ServerSocket.bind(anyIPv6, p, v6Only: true)`, same for the LAN-direct server, failure logged and ignored), scoped `Socket.connect`, and an `HttpClient.connectionFactory` mapping a scoped host to `Socket.startConnect`. v6 cable routes are TCP only. Hosts are written `fe80::x%<ifindex>` (numeric), normalised before they reach Rust.

### 4. Wire and compatibility

- **No new capability.** All additions are optional JSON keys that old peers ignore: ping `relayPort`; encrypted route-update `linkPorts`; `reason: 'cable_probe'` (old peers treat reasons as opaque strings). The beacon reply and ping are otherwise unchanged. Pitfall 14 does not apply: nothing relies on the peer's new behaviour; a peer without `linkPorts` still gets LAN over DHCP and Iroh via stored ports.
- **Old peer on a cable:** found by ping, confirmed only if it can answer our probe over its own routes (3.1). Messages on DHCP tethering work as today.
- **Privacy.** Link-local and zone ids are never sent: not in invites (`_inviteRouteHintsForIdentity` reads `identity.lanAddresses`), `senderLanAddresses`, route updates, group profiles or the vault. A cable ping **broadcasts the deviceId and relayPort on that link, in the clear unless quiet LAN is on** (`_beaconPayloads`), exactly the exposure of the existing `checkContactRoutes` pings; the Iroh ports now travel only inside encrypted payloads, not in any beacon. fe80 addresses can embed a MAC (EUI-64), another reason they stay local. Debug-log lines that print route labels print link routes like LAN routes today.

### 5. Invariants against Known pitfalls 1-20

1. Inbound path: the beacon handler is synchronous (table update); probes and replies are `unawaited`/queued. Met.
2. Seal at transport turn: untouched; hints are a dial parameter. Met.
3. No polling: events (netlink, Windows notifications, Android callbacks); the Android fallback is bounded (30 s, foreground only, off after a USB or tether event); ping sockets close after 5 s; Rust wait is a blocking call, not a loop. Every timer is cancelled on dispose, LAN off, cold mode (fakeAsync test: zero pending after dispose).
4. Relay lease: untouched.
5. Limiter refusal: untouched.
6. New state cleared on dispose and reset: `LinkTable`, `IrohHintBook`, seeded `_peerLanDirect` entries, probe map entries, ping sockets, subscriptions, monitor handle, Rust `hint_cache`.
7. Hold conditions: none added.
8. Store is not delivery: untouched; confirmation is an authenticated reply to our own probe, not a "stored" answer.
9. Authorisation before side effects: entries only for contact or group-member deviceIds; unknown ids change nothing (not even the re-list trigger).
10. Counters on every path: the re-list trigger and the 50/s limiter count the long-lived listener, the ping socket (H2) and, in P1b, the Rust queue; one test per path.
11. No synchronous recursion: `onLinksChanged` goes through the debounce; probes are scheduled, not called back.
12. Bounded memory: table 16x8, 2+2 per (device, link), hint book 64x8, Rust queue 64, Rust cache 64x8, probes 4 in flight.
13. Vault bytes: nothing stored. One optional bool `cableLinksEnabled`.
14. Capability: not needed (4).
15. "Works" means delivered: only confirmed entries become candidates, and cable routes rank by existing route health (receipts).
16. Seal at the last queue: untouched.
17. A failing head: a dead cable route fails like any LAN route (existing backoff and rotation); a failing confirmed entry is evicted.
18. Migrations: none; `dropLinkScoped` defaults to false so vault loads keep stored routes.
19. No parsing in hot paths: classification and parsing at link-change and beacon time, cached; `hintsFor` sorts at most a few prebuilt strings; the Cable page reads a cached snapshot.
20. No date bombs: `LinkTable`, `IrohHintBook` and the watcher take an injected clock, and tests build every timestamp from it.

### 6. Failure cases

- **Stale hints:** TTL 10 min, pruned on link loss, ports replaced on each exchange; at worst one 12 s hinted attempt, then the hint-less retry.
- **Zone id differs per host (P1b):** each side builds its zone from its own index; the wire never carries one; any `%` in wire input is rejected. Test: A sees the peer on index 3, B sees A on index 7.
- **Forged beacons on a shared segment (M1):** an attacker who knows a deviceId can add at most 2 unconfirmed entries per link for it (60 s each), costing us one encrypted probe per 30 s each; it can never evict a pinned confirmed entry, never reach hints, candidates or LAN-direct, and fails the probe.
- **Two cables, or cable plus Wi-Fi, or two phones:** entries per (device, link); both links get a ping; unplugging one drops only its entries and the pool is cleared (`networkChanged`).
- **Cable unplugged mid-transfer:** pool cleared; file ranges are idempotent and resume on the next route; LAN-direct files fall to `waitingForLan` through the existing check once the seeded endpoint is removed.
- **Tethering on while Wi-Fi is on:** both stay; the cable is a candidate beside the Wi-Fi LAN route; Iroh gets both. Network history is not told about a non-default link.
- **Link-local leaking to contacts:** impossible by construction (3.3, 4); a test asserts invites and route updates contain no `169.254`, `fe80` or `%` while a cable is up.
- **Hostile neighbour deposits a forwarded envelope:** the sender's address is never learned from an inbound envelope (M2), so a depositor's address cannot be mapped to the original sender.
- **IPv6 off in the kernel:** P1b parts log and are skipped; P1a is unaffected.
- **Windows firewall prompt** on a new "Unidentified network": the Cable page says so in one line; lab item.
- **Android backgrounded:** unchanged (the foreground service already handles LAN).

### 7. Settings page "Cable and USB" (fast lane, behind `canaryFeatures`, built to the M59 page spec)

New `lib/src/ui/cable_links_panel.dart`; one entry in the Connectivity list; no logic in `main.dart` beyond it.
- **Switch** "Use cable and USB links" (default on; optional bool `cableLinksEnabled`). Off: no ping, table, hints or fallback timer.
- **Detected links** (cached snapshot updated by the watcher): name, kind ("USB tethering", "Ethernet cable", "Wi-Fi"), state ("Contacts reachable: Anna, Ben" / "Looking for contacts" / "Waiting for an address"), IPv4 only (fe80 never shown).
- **Android:** "Open tethering settings" (`android.settings.TETHER_SETTINGS`, falling back to wireless settings; apps cannot turn tethering on).
- **Help (three lines):** "Plug in a cable or turn on USB tethering. Conest finds your contacts on it by itself, with no router and no internet." / "On Linux with no router, set 'Link-local only' on both ends." / "Windows may ask to allow Conest on this network: choose yes."
- Not applicable: the censored-network gate (local links); accounts and budgets (no account; the fallback timer follows the energy policy and is off in cold mode). Strings go into the six ARBs. Shared chat view: not a chat network. Files: through the LAN-direct and Iroh paths (`route_striper` sees routes). Tier (M59): LAN class, no cost class.
- **Group parity:** the table and hint book are keyed by deviceId and read wherever a `TransportPeer` or LAN endpoint is built, so group sends and group file downloads use the cable (3.6 for the file path and its limit for non-contacts).
- **Own devices (M45):** merge, relay and replace need nothing here. Link data is per device and never shared; an own device on the cable is reached like a contact.

### 8. P2 and P3: recommendation (maintainer decision 5)

**P2 (Android Open Accessory): later, Linux only, as its own milestone behind canary; Windows deferred.**
- Gain is small: AOA is a USB 2.0 bulk pipe (about 25-35 MB/s in practice), the same order as USB tethering. Its value is no tethering switch and no IP stack, not speed.
- The Android half is easy (`UsbAccessory`, an accessory filter, one permission dialog per attach, no root).
- The PC half is the cost. libusb must send the AOA control requests (get protocol 51, send strings 52, start 53) to the phone while it is in MTP/ADB/charging mode, then talk to it re-enumerated as 18d1:2d00/2d01. On Windows both steps need the device bound to WinUSB/libusbK: the accessory PID has no inbox driver, and the phone's first mode is owned by the MTP/ADB driver. That means Zadig or a signed driver package with admin rights per phone model, which is not an acceptable first run. On Linux it needs a udev `uaccess` rule and works otherwise.
- Licences: `rusb` is MIT; libusb is LGPL-2.1+. Linking libusb dynamically (system `libusb-1.0.so.0` on Linux, a `libusb-1.0.dll` beside the app on Windows) fits MPL-2.0 for `conest_native`. Do not enable `rusb`'s `vendored` feature in shipped builds.
- Tethering already gives a driverless USB path on Windows (RNDIS is inbox but being phased out; NCM is inbox on Windows 11 only, and Pixel 6 and later use NCM; confirm in the lab). Revisit AOA only if tethering proves unreliable.
**P3 (CDC-ACM serial): deferred.** `ByteLink` is a stream for radio protocols; a Conest peer link on it would need a new session layer (identity handshake, framing with checksums, retransmit, flow control) and a transport adapter, for a niche. Linux has `UnixSerialLink`; Android would need usb-serial-for-android (MIT).

### 9. Tests and strict fakes

**Make the fakes strict first (own commit):**
1. `FakeInterfaceLister` with real Dart semantics: drops `isLinkLocal` unless `includeLinkLocal` is true (the bug that hid 169.254), resolves `%name` only for interfaces that exist.
2. `FakeBeaconNetwork` with real limits and **a separate ephemeral port per socket** (so a reply to a ping goes to the pinging socket, not 7668: catches H2): datagrams over 1024 bytes dropped, no scope on v6 UDP from Dart, unicast reply to the ping's source address and port, v4 as `::ffff:` on dual stack.
3. A recording Iroh bridge (from `_InProcessIrohBridge`) that stores every `directAddresses` argument, rejects more than 8, and **fails the whole send on the first unparsable hint or any `%name` zone**, like the Rust side.
**Dart tests (new files plus a small block in `messenger_controller_test.dart`):**
- `link_interfaces_test.dart`: classification table (usb0, rndis0, ncm0, enx..., enp0s20f0u2, Ethernet 3 against docker0, tun, wg0, rmnet); 169.254 collected; `discoverLanAddresses` unchanged for existing cases.
- `link_table_test.dart`: caps (2+2 per device and link, one device per address, 16x8), pinned confirmed entry survives forged floods, 60 s expiry on the injected clock, confirm only through a matching probe reply, unknown deviceId ignored, reset and dispose clear.
- `link_watcher_test.dart` (fakeAsync): burst coalesced; new link pings once; vanished link drops entries; no timers after dispose; fallback runs only foreground, **stays on after a network-callback event, stops after a USB_STATE event**, sticky initial delivery ignored.
- `iroh_hint_book_test.dart`: order; stored 4 + fresh 4 and stored 2 + fresh 6 both total 8; newest first; fresh de-duplicated against stored; per-family ports; no port means skipped; unnormalisable dropped; TTL; prune on link removal; reset.
- Controller tests: **no internet, relay off, a contact on 169.254: ping answered on the ping socket's port, probe confirmed, next send carries `169.254.x.y:port` first**; link removal removes it; two cables give both; forged beacon never reaches hints or candidates; **delivery over the cable then the vault snapshot, `contact.routeHints` and group profiles contain no link-local host** (H1, all five sinks, plus the beacon divert and wire ingestion with `dropLinkScoped`); an old vault holding a 169.254 route still loads unchanged; invites and route updates contain no `169.254`, `fe80`, `%`; a stored-envelope arrival never touches the table (M2); LAN-direct endpoint seeded on confirmation, removed on unplug, group file download from a contact on the cable uses it; a late call dial uses cached hints (fake bridge); first-contact ping on contact add.
**Rust tests (CI):**
- Hinted dial from a fresh sender with relay disabled succeeds from the hint alone.
- `send_datagram` after eviction warms with the cached hints; the cache is bounded (65th evicts), expires (paused tokio time), **is replaced by every hinted send, an empty list removes it, `network_change` keeps it, `close` clears it**.
- Numeric scope parses; a zone name is refused.
- `LinkMonitor` with an injected change source: `wait` returns on change and on timeout; `stop` ends a running wait at once, and the handle is freed only after it returns.
- **Link-local connect, `#[ignore]`d, run by a new `rust-tests.yml` step** (`sudo ip link add cn0 type dummy`, up, `169.254.77.1/16`, interface name in `CONEST_TEST_LL_IFACE`; decision 6): two endpoints with relays off connect by `169.254.77.1:port` and by `[fe80::x%idx]:port`. It also answers whether Iroh's default `[::]` socket sends to a scoped destination (the source says yes).
**Sabotage checks (each recorded in the log):** drop `includeLinkLocal`; remove the filter in `_rememberLanRoutesForContact`; remove it in `_rememberLanRoutesForGroupMember`; make the ping socket stop listening; let unconfirmed entries evict confirmed ones; let a network callback switch the fallback off; remove the `%` rejection; remove the 8 cap; swap hint order (fresh crowds out stored); remove the TTL; skip `dropLink`; skip clearing on dispose; Rust: strip the scope id; read no hint cache; clear it on `network_change`. The Rust ones run on `sabotage/m54a-*` branches in CI.
**Lab check needed** (main session, after the first green debug run): phone 1 to Linux over USB tethering, Wi-Fi off, internet blocked (message, 100 MB file, call, over LAN-direct and over Iroh, throughput of each); Linux to Windows direct cable (APIPA); unplug mid-transfer; tethering plus Wi-Fi; Windows firewall prompt and 255.255.255.255 on the bound interface; the Android broadcasts and visibility of `rndis0`/`ncm0` addresses on the lab phones' Android versions; then P1b: Linux to Linux (fe80 only).

### 10. Open questions

None are open. The maintainer's six answers are applied: IPv4 first (P1b after P1a's lab), link-local out of everything sent to contacts, second netwatch monitor accepted, Android broadcasts relied on with the fallback and verified in the lab, P2 Linux-only later and P3 deferred, CI dummy-interface step accepted. One consequence to know: on a pure-APIPA cable with an old-build peer, only the new side can find the peer and the old one cannot answer the probe, so the cable is unused for that pair (DHCP tethering works with old peers as today).

### 11. How each review finding was handled

- **H1 (vault leak): confirmed, fixed in 3.3.** The review named four callers; there is a fifth sink, `_rememberLanRoutesForGroupMember`. One divergence: the rule in `prunePeerEndpointsByKind` is a flag that defaults to off, because that function also runs on vault load and pitfall 18 forbids deleting stored routes.
- **H2 (ping reply port): confirmed** (handler replies to the ping's source address and port; my first draft wrongly said the long-lived listener receives it). Fixed in 3.2 and in the fake.
- **M1 (forged entries): confirmed, fixed in 3.1** with the review's three rules, and made enforceable by defining confirmation as an authenticated probe round trip, so unconfirmed entries are never used.
- **M2 (inbound source): confirmed and dropped.** Iroh has no source address; for LAN the source of a stored envelope is the depositor's, and `_handleLanDirectEnvelope` does not carry it. No source is learned from inbound traffic; the probe replaces it.
- **M3 (LAN-direct files): confirmed** (fact 12) **and made feasible** in 3.6 through the authenticated `linkPorts.direct`, seeding the existing runtime `_peerLanDirect`; non-contacts use Iroh.
- **M4 (fallback switched off at once): confirmed**, fixed in 3.4.
- **LOW:** Rust cache not cleared on `network_change` (fact 8 verified, 3.5); hint order and 4-stored rule (3.5); bad hint dropped in Dart and the fake fails the whole send (3.5, 9); `LinkMonitor` stop and dispose (3.4, 9); first-contact ping (3.2); privacy statement for ping and beacons (4). In addition, Iroh ports moved from the cleartext beacon into the encrypted payload, which removes the exposure the review asked me to state.

## Handoff

**P1a is implemented** (IPv4 on cables and USB tethering, with I1). P1b (IPv6 link-local), P2 and P3 are not in this round. Branch `agent/m54a-usb-wire`, merged with `integration/g7-g8` (b2d3eba) first.

### What is done, with commits

- `b7a3ce5` strict test fakes (interface listing that hides link-local unless asked, as Dart does; UDP segment with a port per socket and a broadcast flag).
- `17c5bad` `link_interfaces.dart` (finds 169.254 and tethering interfaces, classifies names, `isLinkScopedHost`) and `link_table.dart` (runtime-only table of contacts seen on a link: unconfirmed until an authenticated probe answer, confirmed entries pinned, bounded).
- `27c5e05` `iroh_hint_book.dart` (at most 8 hints: fresh hosts newest first with the peer's own Iroh port, then at most 4 stored ones; anything Rust would refuse is left out).
- `ababfb5` `link_watcher.dart` (one debounced signal; Android's 30 s fallback only while the cable page is open in the foreground, off for good after a USB_STATE or tether broadcast, never after a network callback).
- `cdded13` `cable_links.dart` (ping on a new cable from its own address, answers on the ping socket's port, probe, confirm, eviction after three failures, hint sources).
- `39afabb` link-scoped routes left out of what is saved or taken in: `prunePeerEndpointsByKind(dropLinkScoped:)` (off for the vault), `GroupRecord.withoutLinkScopedRoutes`, `isValidLanDirectHost` refuses any zone.
- `0e9c800` `cableLinksEnabled` in the connectivity preferences (on by default, written only when off).
- `f550679` switch, eviction, `irohHints`.
- `aeb8e86` the controller wiring (about 130 lines of hooks and one block of small methods in `messenger_controller.dart`): beacon and ping handling, probe sent over one address only, probe answer confirms, answer over every held address, candidate routes first, Iroh hints, LAN-direct endpoint seeded on confirm and removed on unplug, `linkPorts` in the encrypted route update, first-contact ping, reset and dispose, the five vault writers and the wire readers.
- `08c5b42`, `f328cad`, `f57d1ba` native: `link.rs` (monitor core with a generation number, fed by netwatch on Linux and Windows), three `conest_link_monitor_*` FFI functions, the per-peer hint cache in `api.rs` (64 peers, 8 addresses, 10 minutes, replaced by every hinted send, an empty list removes it, kept over `network_change`), and the CI-only link-local connect test with a dummy interface step in `rust-tests.yml`.
- `b0bb987` Dart loop for the native monitor (helper isolate, no polling), Android `LinkEventsPlugin.kt` (network callback, USB_STATE and TETHER_STATE_CHANGED without their sticky delivery, "open tethering settings"), `ACCESS_NETWORK_STATE`.
- `fcbf5eb` the "Cable and USB" page (canary only), six ARBs and the regenerated l10n, one hook each in `main.dart`.

### How it differs from the design note

- Candidate routes: confirmed entries only, at most 3 entries with TCP and UDP each, placed **first** in `_candidateRoutesForContact` (after a confirmed entry its route also gets a health success, so delivery tries it before an Iroh dial that offline would only time out).
- The cable ping carries `relayPort` (optional JSON key); `linkPorts` is an optional encrypted key of the route update. No beacon carries Iroh ports. Old peers ignore both.
- Probes are for contacts only (a probe is a route update, which carries our invite); a group member who is not a contact is not found on the cable. Group members who are contacts use the cable for group sends and group file downloads (they read the same tables). Not done: group-only members.
- The Android fallback runs while the cable page is open (not also "while a transfer is open"): no hook into the transfer code.
- A beacon from a known contact that arrives before the first interface listing is dropped (one re-listing is requested); the next ping or beacon is seen.

### Tests, and sabotage checks

New Dart files: `link_interfaces_test`, `link_table_test`, `iroh_hint_book_test`, `link_watcher_test`, `cable_links_test` (25), `link_scoped_routes_test`, `link_monitor_loop_test`, `link_events_test`, `cable_links_panel_test`, and 17 controller tests in `messenger_controller_test.dart` (group "cable links", with the stricter `_InProcessIrohNetwork`: it records every dial hint and refuses more than 8 or one Rust would not parse). Rust: `link.rs` (7), `api.rs` hint cache (4) and dial tests (3), the FFI smoke test, and the ignored link-local connect test run by the new CI step.

Sabotage checks, each seen to fail the test and restored (Dart): listing without `includeLinkLocal`; unconfirmed evicting confirmed; one device on two addresses; hint order swapped; stored hints uncapped; port TTL; zone names allowed; network callback counting as proof; foreground not checked; fallback timer left on dispose; ping socket closed at once (reply lost); unknown devices accepted; probe throttle; broadcast flag not set; no network change on a vanished link; no pingNow gap; own address accepted; Wi-Fi DHCP beacons accepted; relisting unlimited; failing route evicted after one failure; success not resetting the count; setting ignored; stale or unavailable LAN health counted fresh; link-scoped filter removed from the contact writer, the group-member writer and the beacon; candidate routes dropped; Iroh hints hook off; ports not noted; probe answer not routed; reset not clearing; switch not applied; no ping on a new contact; invite readers not stripping (all four sites); no health after confirm; LAN-direct endpoint not seeded; `dropLinkScoped`, `%` rejection and the group strip in the model test; native-loop: first generation reported, native stop not called, zero not ending the loop, timeout reported as change, double start; panel: Wi-Fi also looking, page-open not cleared, USB names not recognised, switch ignored. Rust sabotages run in CI on `sabotage/m54a-*` branches: see the progress log for the runs.

### Known pitfalls 1-20, checked

1. Inbound path: the beacon handler is synchronous (table update); probes and answers are `unawaited`. Met.
2. Sealing: untouched (hints are a dial parameter; the probe is a normal route update sealed at its turn). Met.
3. No polling: native waits and Android callbacks are events; the only timer loops are the watcher's 30 s Android fallback (page open, foreground, LAN on, off after a USB or tether event), ping sockets (5 s), and a 500 ms debounce; all cancelled on dispose, setting off, cold mode, vault reset. Met.
4. Lease: untouched.
5. Limiter refusal: untouched.
6. Cleared on dispose and reset: table, hint ports, probes, ping sockets, subscriptions, seeded LAN-direct endpoints (reset clears `_peerLanDirect`), the native monitor handle, the Rust hint cache (on close). Tested.
7. No hold conditions added.
8. Confirmation is an authenticated reply to our own probe, not a "stored" answer.
9. Entries only for contacts that can be written to; unknown device ids change nothing (not even a relisting).
10. The relisting trigger and the 50 a second limit are shared by the long-lived listener and the ping socket (the ping socket feeds the same handler).
11. No recursion: link changes go through the debounce.
12. Bounds: 16 links x 8 entries, 2+2 per device and link, 4 probes in flight, 64 hint peers, Rust cache 64 x 8, ports expire after an hour.
13. Nothing is stored; one optional bool in the preferences.
14. No capability needed (optional keys, old peers ignore them).
15. Only confirmed entries become routes; they rank by existing route health.
16. Untouched.
17. A failing confirmed route is evicted after three failures; unconfirmed entries expire after 60 s.
18. `dropLinkScoped` is off for the vault, so stored routes (including a 169.254 one from today's beacon) load unchanged. Tested.
19. Nothing is parsed in a build or per item: names classified at listing, hints built per dial from at most a few strings; the page reads cached views.
20. Tests use injected clocks (`LinkTable`, `IrohHintBook`, `CableLinks`) or a fixed offset.

### Release note (plain text, for the canary)

Contacts on the same cable or USB tethering are now found without a router or internet: plug in a cable, or turn on USB tethering on the phone, and Conest finds your contacts on it by itself. Messages, files and calls use the cable. The new page "Cable and USB" under Settings, Connectivity shows what was found.

### Lab check needed

After the first green debug run: phone 1 to Linux over USB tethering with Wi-Fi off and the internet blocked (a message, a 100 MB file, a call, over LAN-direct and over Iroh, and the throughput of each; if LAN-direct is slower, the seeding in `_onCableLinkConfirmed` is switched off); Linux to Windows over a direct Ethernet cable (APIPA); Linux to Linux with a cable and no DHCP; unplug mid-transfer; tethering and Wi-Fi together; the Windows firewall prompt and whether `255.255.255.255` leaves the bound interface; on the lab phones: do the USB_STATE and TETHER_STATE_CHANGED broadcasts arrive, and are `rndis0` or `ncm0` addresses visible to the app; the old-build peer on DHCP tethering.

### Not done

- P1b (IPv6 link-local), P2 (AOA, Linux first), P3 (serial): per the maintainer's order.
- Group members who are not contacts are not found on the cable.
- The Android fallback does not also run while a transfer is open.
- Not run locally (CI only): all Rust, the Kotlin plugin, the Dart FFI against the real library. All of them built and passed in CI (run ids in the progress log); nothing in CI plugs in a cable, so the real cable path, the Android broadcasts and the real monitor events are the lab's.
- The full suite has two failures that are not from this branch: "native Iroh direct contact adding works without LAN or any relay" (needs the native library) and "the problem report built from a controller holds no message text..." (a date bomb on the base, recorded in PLAN_G9.md).

## Progress log

- 2026-11-04: design note written (no code). Checked the Today facts against the code, the Dart SDK 3.12.1 sources, Iroh 1.0.3 and netwatch 0.19.1; two spikes in the scratchpad (not in the repo) confirmed that Dart UDP ignores IPv6 scope ids and that `includeLinkLocal` hides 169.254. Corrections are in section 0. Decision: keep link-local out of `identity.lanAddresses` and out of everything sent to contacts, use a runtime link table. Waiting for the design review.
- 2026-11-06: design note revised after the Opus review (H1, H2, M1-M4, LOWs; each checked in the code first, all confirmed; divergence: the link-scoped filter in `prunePeerEndpointsByKind` is an opt-in flag, for pitfall 18). Two changes beyond the review: confirmation of a link entry is an authenticated cable-probe round trip (replaces any inbound-source evidence), and Iroh/LAN-direct ports travel in the encrypted route-update payload (`linkPorts`), not in the cleartext beacon. Found a fifth vault sink, `_rememberLanRoutesForGroupMember`. No code. Implementation waits for a free slot.
- 2026-11-07: P1a implemented, test first with strict fakes (commits in the Handoff). Merged `integration/g7-g8` (b2d3eba) first. Checks: `flutter analyze` 28 issues (the baseline); full suite `+2467 ~24 -2`, the two failures being the known native-Iroh one and the problem-report date bomb from PLAN_G9.md.
- Dart sabotage checks (each broken, seen to fail, restored) are listed in the Handoff. Two findings while doing them: a controller test that waited 200 ms after a link-local beacon passed with the filter removed, because a later route update rewrites the contact's routes (fixed: it now looks at once as well); and the first version of the Rust hint-cache test passed with the cache switched off, because Iroh keeps the paths it was given for a minute after a connection (fixed: a fresh sender).
- CI, Rust tests: `42359740404` failed (a typo in a cfg attribute), `42360246767` green (99 + 136 + 12 tests, and the link-local dial through a dummy interface: ok), `42361689605` green on the final native code. Rust sabotage branches (deleted afterwards), run by `gh workflow run rust-tests.yml --ref sabotage/m54a-...`: `42361209598` network_change clears the hints -> `a_dial_without_hints...` failed; `42361213423` stop does not wake the waiter -> `stop_ends_a_running_wait_at_once` failed; `42361207616` hint cache unused -> the first test did not fail (the Iroh memory above), then `42361694579` with the stronger test -> `a_dial_without_hints_uses_what_a_hinted_send_carried` failed; `42361696356` no bound -> `hint_cache_is_bounded...` failed; `42361698410` an empty list keeps the entry -> two tests failed; `42361211610` TTL removed -> `hint_cache_entries_expire_when_read` failed. In the first set a different crate's test (`conest_relay` `a_sealed_udp_request_is_answered_sealed_under_the_cookie_rules`) failed once under five parallel runs: not touched by this branch.
- CI, `debug.yml` on the branch: `42361215350` green (Android APK, Linux and Windows bundles, every carrier job).

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
