# M38: stealth for heavily censored networks

Read `/home/glitch/Documents/conest/PLAN_AGENTS.md` in full first. It holds the shared rules: Lanes, Design note first, Known pitfalls 1–20, Strict fakes, and "Transports and networks follow one design".

- **Worktree:** `/home/glitch/Documents/conest/.worktrees/agent-m38`
- **Branch:** `agent/m38-stealth`
- **Base:** `integration/g7-g8` (04d70fb).
- **Lanes:**
  - **Careful:** everything on the wire (handshakes, framing, the relay's outer layer, TLS behaviour, probing and fallbacks) and the security of the relay.
  - **Fast:** the settings UI and texts.
- **Start with the design note** in this file. It covers the approach, the invariants checked against Known pitfalls 1–20, the failure cases, and the tests with their strict fakes. Then stop and report. Implement only after the design review passes.

## Background (read only)

The maintainer's plan is `/home/glitch/.claude/plans/velvet-seeking-walrus.md`. The relevant sections:
- **"M38. Stealth transports"**, under "Update 2026-10-13". It lists the five options:
  - TLS 443 with a decoy;
  - a Reality-like handshake;
  - Hysteria2-like QUIC;
  - SSH;
  - Conest's own variant.
- **"Group 2 (agent A): M26, then M38"**, under "Order from v0.4.1". It covers the relay outer layer, client-side anti-DPI (DoH, ClientHello fragmentation, ECH, a browser-like fingerprint), and less obvious signatures (the beacon, the relay's UDP JSON and odd headers).
- **The 2026-10-30 order, Group B item 3:** "M38: stealth … as far as it goes without a significant performance cost … Anything heavy moves to M57 (regional)."
- **The censored-network gate** (memory and plan "Update 2026-10-19"): most transports must work on the lab phone's censored Wi-Fi.

## Today (inventory first, with file:line evidence)

Part of M38 already exists from M26 and G2. Find out exactly what does:
- **Relay v2:** Noise_NK, `native/conest_relay/src/outer.rs` (TLS on 443, a WebSocket on a secret path, a decoy page), and `lib/src/relay_v2/`.
- **Circumvention:** the censorship-circumvention connector (DoH, split greeting) used by email, XMPP and others.
- **The LAN beacon:** encrypted or not, and whether it is "quiet LAN".
- **Relay UDP and v1 JSON on 7667:** what is still in the clear.
- **ECH and fingerprints:** whether any exist.

Then list what is missing against the plan's list.

## Must follow

- **Performance:** no significant cost on the normal path. Stealth switches on automatically only when probes show blocking ("blocked here" in network history), or by the user's choice. Measure the handshake and throughput cost.
- **Rust:** builds and tests run in CI only (`rust-tests.yml`). The relay is security-relevant, so active probes must get the decoy, and nothing must make an open proxy.
- **Licences:** check them before using any crate or idea (for example a uTLS-like fingerprint library). `conest_native` is MPL-2.0.
- **Compatibility:** old relays and old apps keep working. New relay features need operator opt-in, and new behaviour needs a capability.
- **Heavy work goes to M57:** anything with a significant cost or of regional value only. List those items.

## Design note

Revision 2 (2026-11-08), design note only, no code. Base 04d70fb; first written 2026-11-07. It folds in the
maintainer's answers and the Opus review (checked against the code in section 10). Evidence is `file:line` on the
base. Everything is hop-local (app to relay, or app to its own network): no peer behaviour changes, so no
contact-level `ApplicationCapability` is needed (pitfall 14). Relay features are announced by the relay in signed
health (`stats.v2`) and are operator opt-in; an app that finds nothing announced behaves as today.

### 1. Inventory: what M26/G2 already built (M38 A-D)

The stealth core exists; the plan's "Reality-like" mode is a ShadowTLS-v2-style borrowed handshake. What is
missing is reach (first contact), probe fidelity, hiding the old port, and choosing automatically without
always paying; not a new transport.

Relay (`native/conest_relay/src`)
- `OuterLayer` takes a `TcpStream` (outer.rs:42); layers `PlainLayer` (:51, unused), `TlsLayer` (:72).
  `serve_outer` (:661): relay cap 1024 (config.rs:49), per-address slot by TCP peer (:683, 16 per peer,
  config.rs:27), silent close over the cap (:679), `trust_forwarded_for=false` (:690).
- TLS on 443: rustls, ALPN `http/1.1` only (:146); WebSocket upgrade on a secret path (:241-283); everything else
  gets the decoy: built-in nginx page, `decoy-dir`, or `decoy-proxy` (:559, `Server: nginx` :625). A self-signed
  cert is trusted only if the relay identity signed its hash (`tls_cert_info` :731).
- Borrowed handshake (borrowed.rs; main.rs:176-200): forwards record by record to `--borrow-site`; the client does
  the real handshake (SNI = site), then one 0x17 record with an ephemeral X25519 key and an HMAC tag over the
  site's ServerHello random, keyed from DH with the X25519 form of the relay identity (`recognise` :386); then
  ChaCha20-Poly1305 records (<=8 KiB + 0-32 B pad) shaped as 0x17 (`tunnel` :412). Replay fails (tag bound to
  that connection's random); probes and wrong markers reach the site untouched (tests :650-690). Limits:
  relay IP != site IP, ClientHello is the client library's (:43-47, RELAY.md); idle 120 s, total 600 s (:68-71).
- v2: Noise_NK, `CNS2` + version + u16 length in the clear on the plain port (session.rs:1-17, server.rs:31). `PAD`
  frames are accepted by both ends (session.rs:78, 368-461; session.dart:405) but never sent. Sealed UDP
  (udp_sealed.rs); cleartext UDP stays, on the same socket as TCP (main.rs:113-114; legacy.rs:180).
- Port 7667 is always bound and public: v1 JSON, HTTP API with `Access-Control-Allow-Origin: *` (http.rs:278-282),
  cleartext UDP, `CNS2`; no flag moves it (config.rs:434-492). `install_relay.sh` sets up wss + decoy only
  (:34-36, :322-435), never borrowed.

App (`lib/src`)
- `PeerRouteProtocol.wss/.borrowed` (models.dart:89, persisted, append-only). `WebSocketRelayChannel` (secret path
  only after WebPKI or signed-hash cert); `BorrowedTlsChannel` (real handshake by Dart `SecureSocket` through a
  loopback tap, borrowed_tls.dart:172); picked in `_channelTo` (relay_client.dart:1239).
- A relay tells its wss and borrowed addresses inside a trusted session (on a fresh install, a plain 7667 one); the
  app adds them pinned to the same key, wss first, borrowed before the first plain entry
  (messenger_controller.dart:33487, 33528-33564): tried first everywhere, not only when blocked. Relay links carry
  `&wss=` only (relay_link.dart:26, 74); signed default manifests can carry wss (relay_defaults.dart:46); nothing
  carries borrowed.
- `Circumvention` (circumvention.dart): automatic/always/never for private DNS, split greeting, quiet LAN (:7-14).
  `automatic` is a global bool `blockedHere` (:102) from `NetworkHistory.blockedHere` (network_history.dart:388:
  dns/reset/tls/timeout failures (:230) and some other route working (:392)): any blocked route, even Tor alone,
  turns DoH and splitting on for every connector. One choke point (`secureConnect` :149) serves relay, wss,
  borrowed, sessions, email, XMPP, Nostr, the Dart Matrix client.
- DoH: 1.1.1.1, 8.8.8.8, 9.9.9.9 by IP, A+AAAA in parallel, a fresh `HttpClient` per query (doh_resolver.dart:14-18,
  133-138: up to 6 TLS handshakes per name). Split greeting: a loopback proxy (fragmenting_proxy.dart:90) cuts the
  first ClientHello mid-SNI into two TLS records and two TCP segments 10 ms apart (:54, :94). LAN beacon: sealed,
  fixed-label key (lan_beacon_codec.dart:37); cleartext still sent unless quiet LAN is active
  (messenger_controller.dart:20774).
- Tests to reuse: a fake DPI dropping a hello with the SNI in one segment, with a built-in sabotage
  (circumvention_test.dart:135); decoy byte-for-byte (outer.rs:981); prober gets the site (borrowed.rs:650).
- Absent: ECH; any measured or browser-like ClientHello; QUIC and SSH (the trait is TCP-only); circumvention for
  the native Matrix SDK, Iroh (api.rs:110), Discord/Telegram clients, link previews, update and geo fetches.

### 2. Gaps against the plan

- G1 "JSON on 7667 optional, off by default in new installs": no listener switch. G2 First contact: stealth
  addresses are learned in a plain session; borrowed is in no link, default list or installer, so a network that
  blocks 7667 and the relay's name leaves a fresh install with no route. G3 "Only when blocked": hidden/borrowed
  are always first; DoH and splitting go global on any blocked route; no cost has ever been measured.
- G4 Probe fidelity: a rustls server (no h2, own cipher order, so a JARM-style probe differs from nginx); 443 is
  exclusive. G5 Browser-like fingerprint unmeasured. G6 ECH none. G7 QUIC/SSH none. G8 `PAD` never sent, fixed
  heartbeat. G9 Resolver: fixed endpoints, no last-known-good, no keep-alive. G10 Cleartext beacon still sent.
- G11 State debt: the relay maps and `Circumvention.instance` are static, cleared only by a test helper
  (relay_client.dart:463-472), not on vault reset (pitfalls 6, 12), and keyed by `host:port` alone (S0).

### 3. What censors do on the lab phone's kind of network, and what helps

The lab Wi-Fi (memory, 2026-10: DNS sinkholing, TLS stalls, Hetzner-like hosts flaky, Tor filtered) looks like
Russian TSPU behaviour. Sources are numbered at the end.
- SNI blocking over TLS and QUIC v1 (QUIC v2 unblocked as of 2026-04) [1]. Helps: borrowed handshake (a popular
  SNI, not the relay's own name, which also sits in CT logs), DoH, splitting. Russia's ECH block survived
  segmentation or record splitting alone but fell to both [2]; we do both. Iran reportedly stopped falling for
  splitting in 2026-07 [3]: a cheap per-network bet.
- IP/ASN throttling (16 KB per connection to Cloudflare, Hetzner, DigitalOcean, OVH since 2025-06) [4]: host
  elsewhere (docs); rotation is regional (M57). TLS fingerprint blocking [5,6]: chatmail was blocked in Russia by
  its client's fingerprint (notes/TRANSPORTS-CENSORSHIP.md); Dart's hello is shared by every Flutter app, so
  blocking costs collateral (unverified until P0 captures it).
- Active probing [7]: a prober learns something only if our stack differs from the real one: borrowed forwards to
  the real site (strong), the TLS decoy is a rustls stack (weaker, G4). Whitelists (~63k allowed IPs, Yandex.Cloud
  ~20%) [8]: only borrowed with a relay in the site's network can pass; otherwise only allowlisted services
  (email), which is what the multi-route design is for.
- Flow classifiers (TLS-in-TLS, burst shape) [3,5,6]: padding does not beat them; borrowed has no inner TLS. We do
  not chase this. QUIC/UDP: SNI-filtered in Russia and China, dropped under whitelists: a QUIC layer fails where
  TCP/443 stealth fails too.

### 4. Plan: items, phases, cost and benefit

P0 measure; Phase 1 reach and state ownership (careful: relay, links, installer, relay-client state); Phase 2
choice and cost (careful: client); Phase 3 SOCKS and the beacon. Settings UI and texts are fast lane, after each
phase. New code in `lib/src/stealth/` and `native/conest_relay/src/ws_front.rs`. P0 and Phase 1 are implemented
later without a second design review; code reviews check the code against this note.

**P0. Measure first (no behaviour change; the lab is unavailable, so phone numbers wait).**
- ClientHello capture: a test listener parses Dart's hello on Linux, Android, Windows, computes JA3/JA4 and pins
  it in a fixture; an SDK bump that changes it fails a test and a human decides. This is all M38 does about the
  fingerprint (decision 4).
- Layer benchmark (Dart test that prints, over a delaying fake link): time-to-ready, MB/s and CPU per MB for
  plain, wss, borrowed. Borrowed seals every <=8 KiB record in pure-Dart ChaCha20-Poly1305 (pubspec.yaml:12-15)
  on the main isolate, on top of Noise's own pass. Bars (review M6): during a 10 MB blob on the lab phone no frame
  over 16 ms, and borrowed at least 2 MB/s (desktop CI: 10 MB/s). If the phone misses either, sealing (and the
  Noise cipher pass) moves to a worker isolate before S4 ships. Until phone numbers exist, borrowed is last in
  every order and last for blob actions.
- wss-everywhere gate (decision 3): wss is preferred on every network only if P0 shows <=2 RTT extra per pooled
  session and no jank; otherwise only when blocked. Prober corpus: section 7. Baselines go in the progress log; a
  later regression blocks the release.

**S0. State ownership (Phase 1, before links can carry borrowed; review M3).**
- Move `_v2Known`, `_v2Learning`, `_mailboxSecrets`, `_authKeys`, `_tokens`, `_udpCookies`, `_tlsCerts`, `_wssPaths`,
  `_borrowedSites` and `v2Pool` (relay_client.dart:131-144, 375, 1196-1222, 1835) into a `RelayRegistry` owned by the
  controller (a field plus reset and dispose hooks; the static API stays as a thin test default). Key every map
  `identity|host:port`. A re-announced SNI or path for the same identity replaces the entry and the stale route in
  `configuredRelays`. Today the register functions overwrite by `host:port`, so a shared link pinned to another key
  could redirect a real relay's route or make the app send an attacker-chosen SNI toward it. The add-relay
  confirmation shows a link's SNI.

**S1. Reach: bootstrap without 7667 (Phase 1; benefit high, cost low).**
- Relay link gains `&borrowed=borrowed://IP[:port]/sni` (existing route syntax, models.dart:268) and `&plain=none`
  for a relay with no public plain port (today `RelayLink` needs a plain host and adds that route,
  relay_link.dart:39; review L3). Its 512-character cap (:32) rises to 1024, tested with a 253-character SNI and an
  IPv6 literal. Signed default manifests may carry `borrowed` entries (SNI in `path`). `install_relay.sh --borrow
  SITE` writes `borrow-*` and prints the link. The app adopts link addresses pinned to the link key before adding
  them (G2 review M1) and confirms with signed health in the new session.
- IP literal (review M8): `borrowed_info` tells `public_host` (outer.rs:751), a name, so the client would look up
  the relay's own name before the disguised handshake. New `borrow-address` (IPv4 or IPv6 literal) is what the
  relay tells and the link carries; the installer detects and prints it. wss still needs a name.
- RELAY.md gains "host where the censor lets you through and borrow a site from the same network". Compat: unknown
  link parameters are ignored by older apps; old relays: nothing to adopt; no capability. An unpinned borrowed
  route is refused (`_channelTo`). Cost: none at runtime.

**S2. Reach: a relay that can hide its plain ports (Phase 1; benefit high, cost low; closes G1).**
- `plain = public|loopback|off` for TCP 7667 (default `public`). UDP shares the socket (main.rs:113-114), so
  `loopback` alone would drop sealed UDP too (review M2). New `udp-bind` (default: same as `bind`) and
  `udp-cleartext = on|off` (default on). A hidden relay keeps: with `plain=loopback` alone, no public UDP (only a
  fallback route is lost); with `udp-bind=0.0.0.0:7667 udp-cleartext=off`, public UDP answers sealed datagrams
  only and is silent otherwise. Health announces `udp_sealed` only when UDP is public. An open UDP port that
  never answers junk is a weaker tell, not zero.
- The installer's health check (`http://127.0.0.1:7667/health`, install_relay.sh:521) works with `loopback`; outer
  layers call `handle_connection` directly. `off` is manual only. Installer default (decision 2): `public` until
  the next stable ships; then `loopback` when the 443 or borrowed self-test passes; operators may close earlier.
  Apps from before G2 (stable v0.4.2) cannot use a hidden relay (docs say so). New app on an old relay: unchanged.

**S3. Fidelity: the relay behind the operator's web server (Phase 1; benefit high, cost low).**
- `ws-bind = 127.0.0.1:PORT`: a plain-WebSocket layer on the secret path reusing `websocket_bridge` (outer.rs:359).
  nginx or Caddy owns 443, the real cert and ACME, HTTP/2 and the real site, and proxies only `location =
  /<secret>` with `Upgrade`. Config refuses a non-loopback `ws-bind` unless `ws-bind-public` is set.
- Limits (review M1): behind a front every client shares one TCP peer and its 16 slots. `OuterLayer::open` returns
  the stream plus an optional peer key; for this layer `serve_outer` takes only the global permit at accept and the
  per-address slot after the upgrade head names the client. The snippet sets `proxy_set_header X-Forwarded-For
  $remote_addr` (overwrite). The layer accepts the last entry only if it parses as an IP (not `forwarded_peer`'s
  raw-string fallback, limits.rs:~101-112), else one shared "front" key with a tight cap. The global
  `trust_forwarded_for` stays false.
- Errors (review L1): the relay answers anything invalid on the secret path with an empty `404`; the snippet adds
  `proxy_intercept_errors on; error_page 400 404 500 502 504 = @site404;` so the front shows the site's own 404,
  never a 502. The app sees an ordinary `wss://domain/path`. No open proxy; loopback by default.

**S4. Choice: automatic, scoped, remembered, cheap on the normal path (Phase 2).**
- `StealthPlanner` (pure Dart, injected clock, no statics): one relay's endpoints (same pinned key) + the network's
  `RouteOutcome`s + preferences give an ordered plan of {endpoint, delay, split?, DoH?}. (a) What worked here
  recently goes first; (b) else wss first when a pinned hidden address exists and the P0 gate passed, plain next,
  borrowed last (and last for blob actions until the phone bar is met); (c) a second attempt starts 300 ms later,
  at most 2 in parallel, losers closed, only when this network is judged blocking or the last 3 attempts here
  failed; otherwise sequential as today.
- Failures (review H1): a pin or identity mismatch, or garbage in a handshake, fails that endpoint and layer only,
  is recorded as `tampered` for this network (backoff for that layer), and the other layers are still tried: a
  national CA, corporate inspection or a captive portal fails the wss pin while plain still works, and a censor can
  inject garbage on 7667. Only a completed session whose signed health shows a different key stops all layers and
  raises the existing key-change banner.
- Memory (review M5): the network id stays sha(kind|vpn|subnets) for Wi-Fi and Ethernet
  (network_history.dart:256-260); two Wi-Fis on one /24 share memory, which hysteresis bounds. Mobile data uses one
  `mobile|vpn` record whatever the addresses (cellular subnets change on every attach; unmeasured, designed as if
  true). A network with no record starts from a prior: the latest blocked network of the same kind, a hint for the
  first order, never a verdict, dropped after 24 h without a confirming failure. A success in the last 10 min beats
  backoff; backoff only reorders (a backed-off layer is still tried last, once an hour) and a success clears it;
  "blocking" needs the existing 3 blocking failures from >=2 separate attempts in 24 h, and 2 successes clear it.
- Scoped activation: DoH and splitting apply per host (its route is blocked here, or its last connect failed with
  dns/reset/tls/timeout), not globally; a first connect to an unseen host that fails that way retries once with
  DoH + split. A "helped" mark needs two confirmations and expires after 24 h (review L4: a relay-cap close looks
  like a reset, outer.rs:679). Optional additive field on `RouteOutcome` JSON. More split strategies only if the
  lab shows the current one failing; no fake or out-of-order packets (root).
- Compat: none. Cost: the normal path adds no work (tested: one dial, no loopback proxy started); blocked path <=1
  extra attempt per layer per backoff window.

**S5. Resolver resilience (Phase 2; benefit medium, cost low).**
- Endpoints (decision 8): Cloudflare, Google, Quad9, Mullvad, AdGuard, plus a user-set URL. Checked with openssl on
  2026-11-08 (review L2): the certificates of 1.1.1.1, 8.8.8.8, 9.9.9.9 and 94.140.14.14 name their IP; Mullvad's
  194.242.2.2 does not, so it needs SNI `dns.mullvad.net` with an explicit connect address. So S5 adds a small
  HTTP/1.1 DoH client on `SecureSocket` (endpoint = address + optional SNI name), which also gives keep-alive
  control. Quad9 9.9.9.9 and AdGuard 94.140.14.14 filter domains: prefer their unfiltered addresses (9.9.9.10,
  94.140.14.140; verify their certificates at implementation). Endpoints never come from network input or a relay.
- Order: staggered, one endpoint at a time 300 ms apart, A and AAAA on one keep-alive connection. Last-known-good
  (review M4): one global list, <=64 hosts x <=4 addresses, 14 days, <=8 KB in the app store (pitfall 13), so a
  first visit to a censored network has it; used only when DoH and the system lookup both fail, and only for
  connections whose TLS identity is verified or pinned, never for plain TCP to an unpinned host. Sinkhole filter
  stays; no system fallback under "always".

**S6. Shape on stealth routes only (Phase 2; benefit low, cost low; last).** Send `PAD` frames to round small
records up to buckets (256 B steps to 1 KiB) and jitter the heartbeat +-25% with one-shot timers cancelled on
close (pitfall 3). No wire change: every v2 peer already ignores `PAD`. It removes exact-size and fixed-period
tells, not flow classifiers. Cost: small messages grow <=250 B, blobs unchanged; idle wakeups must not rise.

**S7. Phase 3.** S7b Bring your own tunnel (decision 1): outbound SOCKS5 (hostnames sent to the proxy, never
resolved locally) and HTTP CONNECT in `Circumvention`, for users who already run Xray, Hysteria2, `ssh -D` or
Psiphon; this answers "SSH" and "Hysteria2" without embedding them. Native Matrix, Iroh and Tor need their own
proxy settings (Iroh's relay client: unverified). Credentials in the vault, never logged. S7c Beacon sunset
(decision 7): `quietLan` default goes sealed-only in the stable after the first stable that ships the sealed
beacon; cleartext is accepted one more stable. A release-policy step, no new wire.

**To M57 (heavy or regional).**
- Native BoringSSL fingerprint client (decision 4): a Chrome-like hello via `boring` as the loopback tap; revisit
  if P0 shows Dart's hello is rare or unlike browsers. Needs CI builds on Android, Linux, Windows, <=1.5 MB per
  ABI, no symbol clash with aws-lc-sys or the Dart VM's BoringSSL, and a profile-update routine.
- SNI router on 443 (was S7d; review M7): a security-sensitive parser of mostly regional value, tying the borrowed
  IP to the relay's domain through DNS and CT logs.
- Hysteria2-like QUIC (whitelists drop UDP first, QUIC v1 SNI is filtered in Russia and China, Dart has no QUIC,
  so `quinn` in native, a stream FFI and a UDP-capable layer trait; Iroh covers open UDP). SSH layer
  (identifiable, often throttled; S7b covers it). ECH (dart:io has none, rustls only client ECH, Cloudflare's
  static outer SNI is blocked in Russia [2]). Fake/out-of-order packets (root), 16 KB throttle rotation, cover
  traffic against flow classifiers, whitelisted-ASN deployments as code.

Security, all items. No open proxy: borrowed forwards only to the operator's `borrow-site`, `decoy-proxy` only to
the operator's upstream, `ws-bind` carries only the relay's protocols, the SOCKS client is outbound to a proxy the
user typed. Probes get the decoy or the real site. The secret path is a bearer token inside TLS, not rotated
(decision 5; M52). Replay: borrowed tags bind to the site's per-connection random; v2 has Noise; sealed UDP keeps
cookies and budgets. Everything is bounded; no secret path, key or token is logged.
Licences: P0, S0-S6 and S7b add no crate (the SOCKS client is our own ~200 lines). The M57 items would use
`boring`/BoringSSL (Apache-2.0 plus OpenSSL/ISC terms), `quinn` (MIT/Apache-2.0), `russh` (Apache-2.0), from
memory; rustls (Apache-2.0/MIT/ISC) and wreq (Apache-2.0) were read from public pages. Go uTLS is unusable;
impit's patched rustls is unchecked. `conest_native` is MPL-2.0, which takes all of these.

### 5. Invariants against Known pitfalls 1-20

- 1 Connect attempts (plan, race, DoH) run in the transport's connect step, never in inbound processing; the
  planner is pure. 2, 16 Races finish before sealing: the envelope is encrypted after a winner exists and the
  transport's turn is taken; a loser never holds a sealed envelope. 3 Stagger and jitter timers are one-shot,
  cancelled on session close, dispose, vault reset, cold mode. 4 Sessions are leases: a cut mid-fetch leaves
  leases unacknowledged. 5 A relay-cap or limiter refusal is not a layer failure.
- 6, 12 S0 removes the statics and clears the registry on reset and dispose; every map has a cap and expiry (LKG
  <=64 hosts, plan memory <=32 routes per network, DoH cache 256). 7 No hold conditions. 8, 15 Layers are ranked
  by verified signed health and receipts, not connect or TLS success: a decoy answer is a failure. 9 Linked and
  learned addresses are pinned and key-checked first and cannot overwrite another identity's entry (S0).
- 10 Failure counters run on every connect path (poll, long poll, subscribe, UDP, blob, LAN), one test each.
  11 Backoff uses timers, not recursion. 13 Vault growth: the global LKG list (<=8 KB) and an optional strategy
  field per route. 14 Hop-local; relay features announced in signed health. 17 Attempt caps and per-network
  backoff; a dead layer is skipped, never waited on at the head of the send queue; a mismatch fails its own layer
  only (H1). 18 Additive JSON only; `plain` and `udp-cleartext` default to today's behaviour. 19 Parsing at
  connect time; borrowed sealing leaves the main isolate if P0 misses its bar. 20 Planner tests use the injected clock.

### 6. Failure cases

- Stealth-only relay, app has only `host:7667`: `refused` is not a blocking kind (network_history.dart:230); the
  app says the relay needs its link. Wrong or rotated secret path (decoy answered): "path rejected", no retry on it.
- TLS interception (national CA, corporate box, captive portal): a failed wss pin fails that layer only; with a CA
  the device trusts, WebPKI passes and the secret path reaches the interceptor (a bearer token; Noise then fails the
  identity check, the layer is marked `tampered`). Borrowed fails under interception (its tag binds to the site's
  own ServerHello random); plain is Noise-protected. The relay stays reachable (H1).
- Relay or per-address cap: the silent close looks like `reset` (outer.rs:679); scoped activation and the two-
  confirmation rule limit the harm. Borrowed site down: the relay closes silently (borrowed.rs:236), other layers
  carry on, the operator log warns. Site on TLS 1.2, HelloRetryRequest or resumption: untested today, so Phase 1
  adds tests; until then docs say pick a TLS 1.3 site.
- DPI reassembles records, or whitelists IP+SNI: the split fails or borrowed resets after the hello; backoff grows,
  attempts are capped, the screen says what this network lets through and points at email/Nostr. DoH endpoints
  blocked: LKG (pinned or verified TLS only), then system (never under "always"), then a dns error.
- 16 KB throttle: the session dies mid-fetch; leases replay after reconnect. `ws-bind` public by mistake: config
  refuses; non-IP XFF: shared front key; a prober on the secret path behind the front sees the site's own 404.
  Vault reset with channels open: channels close, the registry clears.

### 7. Tests (strict fakes; * marks a sabotage check)

Dart (`flutter test`):
- Fake DPI family extending circumvention_test.dart:135: (a) SNI in one segment (exists); (b) reassembles TCP but
  not TLS records, so only the record split passes *; (c) reassembles records too: the planner moves on, attempts
  capped *; (d) IP+SNI allowlist: borrowed passes only for an allowed pair; (e) cuts after 16 KB per connection:
  clean end, leases replay; (f) fake MITM on wss (wrong cert, and a trusted-CA one) while plain works: relay stays
  reachable, layer marked `tampered`, only a different key in signed health stops all layers *.
- Planner (injected clock, fake channel factory): a healthy network gives one dial and starts no proxy * (sabotage:
  always start); stagger only when blocking is judged, losers closed *; success beats backoff, 2 successes clear,
  a backed-off layer is retried last; two Wi-Fis on one subnet; the `mobile|vpn` key survives an address change; a
  prior expires after 24 h; failure counters per connect path; scoped activation (Tor blocked, Matrix stays plain)
  *; a relay-cap close cannot set "helped" alone *.
- State: maps keyed `identity|host:port`; a link pinned to another key cannot overwrite a real relay's SNI or path
  *; a re-announced SNI replaces the old route; the registry clears on vault reset *.
- Resolver: a fake DoH server counts TLS accepts (1 per N queries) *; an endpoint whose certificate lacks its IP
  needs its SNI; staggered order; LKG global, only for pinned or verified TLS, never plain TCP *. Fake
  SOCKS5/CONNECT server (strict): auth when set, hostname sent as a name and never resolved locally *, truncated,
  slow, wrong-version and over-long replies.
- Links: `&borrowed=` and `&plain=none` parsed, bad forms rejected, pinned before adding *, a 253-character SNI and
  an IPv6 literal fit the cap, an old reader ignores them. Shape: sizes fall into buckets, an old-client fake that
  ignores `PAD` works, idle wakeups do not rise.
Rust (CI only; sabotage runs on `sabotage/m38-<item>` branches as PLAN_AGENTS describes):
- Active prober (new, strict): the existing fake site and decoy as reference versus each listener, for a corpus:
  `GET /`, secret path without upgrade, wrong path, bad upgrade key or version, HTTP/2 preface, hello without SNI,
  wrong SNI, TLS 1.2 only, a truncated hello that stalls, random bytes, `CNS2\x01`, a recorded valid borrowed
  marker replayed on a new connection * (sabotage: bind the tag to nothing; the replay must then succeed and the
  test fail), a recorded valid upgrade replayed. Bytes equal the reference's (Date masked). Review L1: idle-close
  and lifetime versus the site; the relay's re-framing versus the site's TCP segmentation (it writes each record
  separately with TCP_NODELAY, so the site's coalesced first flight leaves as small segments: forward the records
  of one upstream read in one write and assert the write sizes match) *; behind a fake front a non-upgrade or
  bad-key request on the secret path looks like a wrong path, no 502 *.
- `plain=loopback/off`: the public interface refuses TCP; sealed UDP still answers on a public `udp-bind` with
  `udp-cleartext=off` and cleartext datagrams get silence *; the health-check address answers *. `ws-bind` behind a
  fake front: 16 clients through one front are not capped as one peer *, a non-IP XFF uses the shared key,
  non-loopback bind refused *. Borrowed with a TLS 1.2 site and a HelloRetryRequest site; caps unchanged, slots
  released on every exit path.

### 8. Lab checks (the maintainer; lab phone Wi-Fi and Windows, no VPN; the lab is unavailable for now)

- L1 Per layer to the lab relay (plain 7667, wss 443, borrowed 443), each with DoH and split on and off: reached
  or not, and how it failed. L2 Dart's ClientHello from phone and Windows, captured on a laptop hotspot; JA3/JA4
  against Chrome. L3 From an outside network, the prober corpus against the lab relay plus a JARM or
  `ssl-enum-ciphers` run, versus the real site and versus nginx. L4 On the phone: time-to-ready and MB/s per layer,
  the P0 bars, idle wakeups over an hour (`dumpsys batterystats`).
- L5 Old app on a `plain=loopback` relay (expected: cannot connect; the new app works from the link); new app on
  an old relay. L6 If a Hetzner-class host is at hand: bytes until stall (the 16 KB check). L7 The chosen borrowed
  site from the lab phone's network and from the relay host (`openssl s_client -tls1_3`).

### 9. Decisions (maintainer, 2026-11-08) and what is still open

Decided, and folded in above: S7b SOCKS5/CONNECT in Phase 3 (1); plain port open on new installs until the next
stable ships, then `loopback` after the self-test (2); wss everywhere only if P0 shows <=2 RTT and no jank (3);
native fingerprint client to M57 (4); secret-path enumeration accepted, M52 covers rotation (5); beacon
sealed-only one stable after it first ships in a stable (7); DoH adds Quad9, Mullvad, AdGuard (8).
Still open: (a) the user's confirmation of the borrowed site below (6); (b) the date of the next stable, which
flips the installer default; (c) whether one `mobile|vpn` record misleads in practice (then Android MCC/MNC
through a Kotlin channel).

**Borrowed site for the lab relay (proposal; nothing is set until the user confirms).** The lab relay is
177.1.187.103: Frankfurt, AS213520 (Senko Digital). The site should be large and ordinary, speak TLS 1.3 (the
borrowed flow assumes it) and be reachable from China, Russia and Iran. Evidence: OONI web_connectivity,
2026-10-08 to 2026-11-07, share of OK measurements (volunteer samples: a rough guide, silent on how a long idle
connection is treated; I could not probe from those countries myself).
- www.bing.com: RU 92% (n=1699), IR 92% (166), CN 100% (46). www.microsoft.com: RU 96%, IR 86%, CN 96%.
  www.apple.com: RU 97%, IR 95%, CN 89%. github.com: RU 97%, IR 93%, CN 56% (118; 41% anomalies).
- Primary `www.bing.com`: reachable in all three, and blocking it would hurt domestic users (one of the few Western
  search engines usable in mainland China). Akamai (AS20940) serves it from many addresses, so an IP-to-SNI table
  for it is large; from this machine it resolved to Akamai Frankfurt addresses and negotiated TLS 1.3 and h2
  (openssl, 2026-11-08). Alternate `www.microsoft.com` (same family; Outlook and Meet were on Iran's January 2026
  allowlist, notes/TRANSPORTS-CENSORSHIP.md: Microsoft services, not Bing itself). Not `github.com` as primary:
  weak from China in the data, though on Iran's shutdown allowlist. Avoid Cloudflare-fronted sites (throttled in
  Russia [4]), Wikipedia and Google (blocked in China).
- Nearest hosting: the relay is in Frankfurt and Bing resolves there to Akamai Frankfurt edges (same city). No site
  is in the relay's own AS, so the IP-versus-SNI mismatch stays; only a relay inside the site's network (Azure for
  Bing and Microsoft) removes it, an operator choice (docs; M57 for whitelist cases).
- Config: `borrow-bind = 0.0.0.0:443`, `borrow-site = www.bing.com:443`, `borrow-address = <the relay's public
  IPv4>` (S1). The relay resolves the site per connection, so the address it plays can change. Verify the site on
  the relay host with `openssl s_client -tls1_3` first; switching is a config change and a restart, and apps
  replace the old SNI when the relay re-announces it (S0).

### 10. Review round 2026-11-08: findings checked against the code

All findings hold; none was wrong. H1 holds against my own rule (S4 "permanent errors never retry on other
layers"): in today's code a garbled handshake is an ordinary route failure and layers are tried independently, so
only my rule would have darkened the relay (S4, section 6, test (f); added: a trusted national CA leaks the secret
path). M1: slot at accept by TCP peer (outer.rs:683), 16 per peer (config.rs:27), `forwarded_peer` falls back to
the raw string (limits.rs:~101-112): S3. M2: `UdpSocket::bind(&config.bind)` (main.rs:113-114): S2. M3: every
listed map is static and the register functions overwrite by `host:port`: S0, moved to Phase 1. M4: my S5 kept LKG
per network; now global. M5: the id is sha(kind|vpn|subnets) (network_history.dart:256-260); that cellular subnets
change on every attach is plausible but unmeasured: S4. M6: P0 bars. M7: SNI router to M57. M8: `borrowed_info`
tells `public_host` (outer.rs:751): `borrow-address`. L1: the downstream task writes each record separately with
TCP_NODELAY, and a bad request closed behind a front gives a 502. L2: Mullvad's certificate lacks its IP (checked
with openssl); Quad9 and AdGuard default addresses filter. L3: relay_link.dart:32 (cap), :39 (host required). L4:
outer.rs:679. Claims that rest on something I could not run (cellular behaviour, reachability from the three
countries) say so.

Sources (search-result summaries, not read in full; dates and rates as those pages state them; OONI data via
api.ooni.io aggregation):
[1] Heitmann et al., Russia's QUIC SNI censorship, FOCI 2026: https://ntc.party/t/on-russias-early-introduction-of-quic-sni-censorship-foci-2026/25670
[2] Niere et al., TSPU blocks ECH by `cloudflare-ech.com`, FOCI 2025: https://corpus.lantern.io/findings/2025-niere-encrypted__russia-tspu-ech-direct-block/
[3] Lantern corpus, REALITY (Iran 2026-06/07): https://corpus.lantern.io/defenses/reality/
[4] Zona Media, the 16 KB curtain: https://en.zona.media/article/2025/06/19/cloudflare
[5] Xue et al., encapsulated TLS handshakes, USENIX Security 2024: https://www.usenix.org/conference/usenixsecurity24/presentation/xue
[6] GFW Technical Review 11: https://kaiyanfan.github.io/blog/2026/gfw11
[7] ShadowTLS analysis, FOCI 2023: https://petsymposium.org/foci/2023/foci-2023-0002.php
[8] Russian whitelist scan: https://dev.to/gerus_team/russia-built-a-national-firewall-and-we-mapped-every-hole-in-it-93j
Crates: https://docs.rs/crate/wreq/latest, https://docs.rs/crate/rustls/0.23.41/source/src/client/ech.rs

## Handoff

Design note only; no code written. Revision 2 folds in the maintainer's answers and the Opus review (section 10);
the lane allows no second design review. Implementation of P0 and Phase 1 starts when a slot frees. The lab is
unavailable: the lab checks (section 8) and the phone half of P0 wait. Pitfalls 1-20 are checked against the
design in section 5 (none unsatisfiable on paper). Waiting on the user: the borrowed-site choice (section 9).

## Progress log

- 2026-11-07: Read PLAN_M38.md, PLAN_AGENTS.md and the plan's M38, Group 2 and Group B sections. Inventoried
  relay (outer.rs, borrowed.rs, session.rs, udp_sealed.rs, config.rs, install_relay.sh) and app (relay_client,
  relay_v2/*, circumvention/*, network_history, messenger_controller hooks, tests). Searched current censorship
  reports (Russia TSPU, GFW, Iran) for the threat model. Wrote the design note.
- Decisions: the stealth core (TLS decoy, borrowed handshake, sealed UDP and beacon, DoH, split greeting) already
  exists, so M38 is scoped to reach, fidelity, hiding 7667, automatic scoped choice, and measurement; QUIC, SSH,
  ECH and fake-packet splitting go to M57; the fingerprint item is gated on a measurement and a build spike.
- No code, no CI runs this round.
- 2026-11-08: Revision 2 after the maintainer's answers and the Opus review. Checked each finding against the code
  (all hold; H1 holds against my own rule, not against today's code). Added S0 (state ownership, Phase 1),
  hysteresis and a mobile network key, ws-bind slots and error mapping, udp-bind and udp-cleartext, `borrow-address`,
  link `plain=none`, a global last-known-good list, the DoH endpoint list (certificate checks), and the P0 bars.
  Moved S7a and S7d to M57. Wrote the borrowed-site proposal (bing.com first) from OONI data, openssl checks and the
  relay's location (Frankfurt, AS213520); the user confirms before it is set.

## Maintainer's answers and user decisions (2026-11-08)

1. **S7b (SOCKS5/CONNECT bring-your-own-tunnel):** yes, in Phase 3. It is cheap and covers users who already have a proxy or VPN.
2. **Plain port 7667 on new relay installs** (user): it stays open by default until the next stable release ships. After that, the installer default switches to hidden (`loopback`) once 443/borrowed passes its self-test. Operators can close the port earlier.
3. **wss everywhere:** yes, if P0 measures at most 2 RTT extra per pooled session and no jank. Otherwise wss is used only when blocked.
4. **Native BoringSSL fingerprint client:** goes to M57. M38 keeps only the P0 capture of Dart's ClientHello, so the gap is known.
5. **Secret-path enumeration from shared links:** accepted for now. Path rotation and distribution are covered by M52.
6. **Borrowed site** (user):
   - Pick a large, ordinary HTTPS site that is reachable from China, Russia and Iran, such as bing.com or github.com.
   - It should preferably be hosted near the relay's network.
   - The agent proposes the site for the lab relay with a short reachability argument, and the maintainer confirms it before it is set. Keep it a relay config option, not a code constant.
7. **LAN beacon becomes sealed-only:** one stable release after the sealed beacon first ships in a stable.
8. **DoH endpoints:** add Quad9, Mullvad and AdGuard next to Cloudflare and Google, plus the user-set URL (S5).

The lab is unavailable for now. Lab checks L1–L6 wait.

## Design review (Opus, 2026-11-08): revise first

The inventory checks out. There is no open-proxy path in the existing code, and replay of the borrowed marker fails as designed. Fold all of the following into the Design note.

### HIGH

**H1. S4(d) "permanent errors never retry on other layers" makes the relay go dark on networks that intercept TLS.**
- **What goes wrong:** a national CA, corporate inspection or a captive portal fails the wss pin, while plain or borrowed would still work. A censor can also inject garbage on 7667 to produce "bad identity" and kill every layer.
- **Change:**
  - A pin or identity mismatch is permanent for that endpoint and layer only.
  - Record it as tampering seen on this network, and keep trying the other layers.
  - Stop all layers only when signed health inside a completed session shows a different key.
- **Test:** a fake MITM on wss, while plain still works.

### MEDIUM

- **M1. S3 ws-bind.**
  - `serve_outer` takes `connection_slot` by TCP peer at accept (outer.rs ~681–684). Behind nginx every peer is 127.0.0.1, so all clients share 16 slots. For ws-bind, take the slot after parsing the upgrade head.
  - `forwarded_peer` (limits.rs ~101–112) falls back to the raw string. Accept the last XFF entry only if it is an IP; otherwise use one shared "front" key or refuse.
  - The nginx snippet sets `proxy_set_header X-Forwarded-For $remote_addr`, and the inner `trust_forwarded_for` stays false.
- **M2. S2 `plain=loopback` would drop sealed UDP**, because it shares the 7667 socket (main.rs ~113–114). Add a separate `udp-bind`, or a sealed-only public mode with cleartext UDP off. State which UDP features a hidden relay keeps.
- **M3. Static relay maps** in relay_client.dart (~135–144, 375, 1209–1235, 1835):
  - Besides the listed ones, `_v2Known`, `_mailboxSecrets`, `_authKeys`, `_tokens`, `_udpCookies` and `v2Pool` are static too.
  - `_borrowedSites` and `_wssPaths` are keyed by host:port. A shared link pinned to an attacker's key can overwrite a real relay's SNI.
  - Key every map by `identity|host:port`.
  - Move all the statics into a controller-owned instance that is cleared on vault reset.
  - Do this in Phase 1, before links can carry borrowed.
- **M4. S5 last-known-good (LKG) addresses are kept per network,** so the list is empty on a first visit to a censored network. Keep LKG global, with caps, and use it only for TLS-verified or pinned connections.
- **M5. S4 per-network memory:** the network id is sha(kind|vpn|subnets) (network_history.dart ~256–260).
  - Cellular subnets change on every attach, and Wi-Fis that share 192.168.1.0/24 share memory.
  - Backoff beats recency, and a success clears backoff.
  - Use hysteresis: N failures in the window to judge "blocking", M successes to clear it.
  - Define the cellular key, or a prior carried over from the last blocked network.
- **M6. Borrowed mode encrypts in pure Dart on the main isolate** (borrowed_tls.dart ~25, plus the Noise cipher). Set the bar now:
  - no frame over 16 ms during a 10 MB blob on the lab phone;
  - a stated MB/s floor.
  
  If borrowed mode misses the bar, sealing moves to an isolate before S4 ships.
- **M7. S7d moves to M57.** It is a security-sensitive parser on 443, of mostly regional value, and it ties the borrowed IP to the relay's domain through DNS and CT logs.
- **M8. S1:** `borrowed://hostname` costs a DNS lookup of the relay's name before the disguised handshake. The installer prints IP literals (v4 and v6) for borrowed, and the docs say why.

### LOW

- **L1. Prober corpus:**
  - connection lifetime and idle limits versus the real site (borrowed.rs ~68–71: IDLE_LIMIT 120 s, FORWARD_LIMIT 600 s);
  - the relay's re-framing versus the site's own TCP segmentation;
  - a non-upgrade or bad-key request on the secret path behind the S3 front must look like a wrong path (no 502).
- **L2. DoH:**
  - check that Mullvad's and AdGuard's certificates cover their IPs;
  - stagger the endpoints in order, rather than all of them with A+AAAA at once.
- **L3. Links:**
  - `RelayLink` requires a plain host (relay_link.dart ~39), so define how a `plain=loopback` relay's link marks plain as absent;
  - check the 512-character cap with a long SNI.
- **L4. Scoped activation:** a relay-cap close looks like a reset (outer.rs ~679). Require two confirmations before marking that DoH or splitting helped, or let the mark expire.

The lane allows one design review round. After the revision, implement P0 and Phase 1 without another design review.
