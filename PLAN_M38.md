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

Round 1: design note only, no code. Base 04d70fb, 2026-11-07. Evidence is `file:line` on the base. Everything
here is hop-local (app to relay, or app to its own network): no peer behaviour changes, so no contact-level
`ApplicationCapability` is needed (pitfall 14 does not apply). Relay features are announced by the relay inside
signed health (`stats.v2`) and are operator opt-in; an app that finds nothing announced behaves as today.

### 1. Inventory: what M26/G2 already built (M38 A-D)

The stealth core exists. The plan's "Reality-like" mode is there as a ShadowTLS-v2-style borrowed handshake.
What is missing is reach (first contact), probe fidelity, hiding the old port, and choosing automatically
without always paying; not a new transport.

Relay (`native/conest_relay/src`)
- `OuterLayer` takes a `TcpStream` (outer.rs:42); layers `PlainLayer` (:51, unused) and `TlsLayer` (:72).
  `serve_outer` (:661) applies the relay cap (1024, config.rs:49) and the per-address slot, silently closes
  over-cap connections (:679) and sets `trust_forwarded_for=false` (:690).
- TLS on 443: rustls, operator cert, ALPN `http/1.1` only (:146). WebSocket upgrade on a secret path
  (:241-283). Everything else, including the secret path without upgrade, gets the decoy: built-in nginx page,
  `decoy-dir`, or `decoy-proxy` to a real plain-HTTP server (:559, `Server: nginx` :625). A self-signed cert is
  trusted by the client only if the relay identity signed its hash (`tls_cert_info` :731).
- Borrowed handshake (borrowed.rs; listener main.rs:176-200): forwards every connection record by record to
  `--borrow-site`. The client does the real handshake (SNI = site), then one 0x17 record: ephemeral X25519 key
  + HMAC tag over the site's ServerHello random, keyed from DH with the X25519 form of the relay identity
  (`recognise` :386). Then the relay cuts the site off and runs ChaCha20-Poly1305 records (<=8 KiB + 0-32 B pad)
  shaped as 0x17 (`tunnel` :412). Replay fails (tag bound to that connection's random); probes and wrong markers
  reach the site untouched (tests :650-690). Documented limits: relay IP != site IP, ClientHello is the client
  library's (:43-47, RELAY.md).
- v2: Noise_NK, `CNS2` + version + u16 length in the clear on the plain port (session.rs:1-17, server.rs:31).
  Frame `PAD` is accepted by both ends (session.rs:78, 368-461; session.dart:405) but never sent; heartbeats
  are periodic. Sealed UDP (udp_sealed.rs, udp_seal.dart, relay_client.dart:1899); cleartext UDP stays (main.rs:1587).
- Port 7667 is always bound and public: v1 JSON, HTTP API with `Access-Control-Allow-Origin: *`
  (http.rs:278-282), cleartext UDP (main.rs:114, 143), `CNS2`. No flag moves it to loopback or off
  (config.rs:434-492). `install_relay.sh` sets up wss + decoy only (:34-36, :322-435), never borrowed.

App (`lib/src`)
- `PeerRouteProtocol.wss/.borrowed` (models.dart:89, persisted, append-only). `WebSocketRelayChannel` (secret
  path only after WebPKI or signed-hash cert); `BorrowedTlsChannel` (real handshake by Dart `SecureSocket`
  through a loopback tap, borrowed_tls.dart:172); picked in `_channelTo` (relay_client.dart:1239).
- Learning: a relay tells its wss and borrowed addresses inside a trusted session (on a fresh install, a plain
  7667 session); the app adds them pinned to the same key, wss first, borrowed before the first plain entry
  (messenger_controller.dart:33487, 33528-33564). So they are tried first everywhere, not only when blocked.
  Relay links carry `&wss=` only (relay_link.dart:26, 74); signed default manifests can carry wss
  (relay_defaults.dart:46). Nothing carries borrowed.
- `Circumvention` (circumvention.dart): automatic/always/never for private DNS, split greeting, quiet LAN
  (:7-14). `automatic` is a global bool `blockedHere` (:102) fed by `_syncCircumvention`
  (messenger_controller.dart:4855) from `NetworkHistory.blockedHere` (network_history.dart:388: failures of
  kind dns/reset/tls/timeout (:230) and some other route working (:392)). Any blocked route, even Tor alone,
  turns DoH and splitting on for every connector. One choke point (`secureConnect` :149) serves relay, wss,
  borrowed, sessions, email, XMPP, Nostr, the Dart Matrix client.
- DoH: 1.1.1.1, 8.8.8.8, 9.9.9.9 by IP, A+AAAA in parallel, a fresh `HttpClient` per query
  (doh_resolver.dart:14-18, 133-138: up to 6 TLS handshakes per uncached name), 10 min cache. Split greeting:
  a loopback proxy (fragmenting_proxy.dart:90) cuts the first ClientHello mid-SNI into two TLS records and two
  TCP segments 10 ms apart (:54, :94).
- LAN beacon: sealed, random size, fixed-label key (lan_beacon_codec.dart:37: hides from pattern matching, not
  from other Conest users); the cleartext `{"app":"conest"..}` is still sent alongside unless quiet LAN is
  active (messenger_controller.dart:20774).
- Existing tests worth reusing: a fake DPI that drops a hello with the SNI in one segment, with a built-in
  sabotage (circumvention_test.dart:135); decoy byte-for-byte (outer.rs:981); prober gets the site (borrowed.rs:650).
- Absent: ECH; any measured or browser-like ClientHello (all app TLS is Dart's; nothing captures or pins it);
  QUIC and SSH (the trait is TCP-only); circumvention for the native Matrix SDK (matrix.rs), Iroh (api.rs:110),
  Discord/Telegram clients (discord_api.dart:73, telegram_bot_api.dart:65), link previews, update and bitchat
  geo fetches (no hook found).

### 2. Gaps against the plan

- G1 "JSON on 7667 optional, off by default in new installs" (plan, item 3): no listener switch exists.
- G2 First contact: stealth addresses are learned in a plain session; borrowed is in no link, default list or
  installer. A network that blocks 7667 and the relay's name leaves a fresh install with no route.
- G3 "Only when blocked": hidden/borrowed are always first; DoH and splitting go global on any blocked route;
  no cost has ever been measured.
- G4 Probe fidelity: a rustls server (no h2, own cipher/extension order, so a JARM-style probe differs from
  nginx), self-signed allowed, 443 exclusive (no sharing with a real site; TLS and borrowed cannot share a port).
- G5 Browser-like fingerprint unmeasured. G6 ECH none. G7 QUIC/SSH none. G8 Shape: `PAD` never sent, fixed
  heartbeat period, borrowed pad 0-32 B. G9 Resolver: fixed endpoints, no last-known-good, no keep-alive.
  G10 Beacon: cleartext still sent, no sunset. G11 Coverage holes above.
- G12 State debt: `_wssPaths`, `_borrowedSites`, `_tlsCerts` (relay_client.dart:1196-1222) and
  `Circumvention.instance` are static, cleared only by a test helper (:463-472), not on vault reset
  (pitfalls 6, 12): secret paths survive a vault reset until the process ends.

### 3. What censors do on the lab phone's kind of network, and what helps

The lab Wi-Fi (memory, 2026-10: DNS sinkholing, TLS stalls, Hetzner-like hosts flaky, Tor filtered) looks like
Russian TSPU behaviour. Sources are numbered at the end.
- SNI blocking over TLS and QUIC v1 (QUIC v2 unblocked as of 2026-04) [1]. Helps: borrowed handshake (a popular
  SNI, not the relay's own name, which also sits in CT logs), DoH, splitting. Russia's ECH block survived
  segmentation or record splitting alone but fell to both [2]; we do both. Iran reportedly stopped falling for
  splitting in 2026-07 [3]: a cheap per-network bet, not a guarantee.
- IP/ASN throttling (16 KB per connection to Cloudflare, Hetzner, DigitalOcean, OVH since 2025-06) [4]: no
  protocol trick helps; host elsewhere (docs). A rotation workaround is regional (M57).
- TLS fingerprint blocking (JA3/JA4) [5,6]: chatmail was blocked in Russia by its client's fingerprint
  (notes/TRANSPORTS-CENSORSHIP.md). Dart's hello is shared by every Flutter app, so blocking costs collateral;
  unverified until P0 captures it.
- Active probing and replay [7]: a prober learns something only if our stack differs from the real one.
  Borrowed forwards to the real site (strong); the TLS decoy is a rustls stack (weaker, G4).
- Whitelists (mobile shutdowns; ~63k allowed IPs, Yandex.Cloud ~20%) [8]: the relay's IP must be allowed and the
  SNI must match its owner. Only borrowed with a relay in that network can pass; otherwise only allowlisted
  services (email) do, which is what the multi-route design is for.
- Flow classifiers (TLS-in-TLS, burst shape; REALITY flows detected at high rates) [3,5,6]: padding does not
  beat them; borrowed has no inner TLS, so the main tell is absent. We do not chase this.
- QUIC/UDP: SNI-filtered in Russia and China, dropped under whitelists. A QUIC layer fails where TCP/443
  stealth fails too; Iroh already covers the open-UDP case.

### 4. Plan: items, phases, cost and benefit

P0 measure; Phase 1 reach (careful: relay, links, installer); Phase 2 choice and cost (careful: client wire
behaviour); Phase 3 conditional. Settings UI and texts are fast lane, after each phase. New code in
`lib/src/stealth/` (planner, SOCKS client) and `native/conest_relay/src/ws_front.rs`; small hooks elsewhere.
Independent security review after Phase 1 (relay) and after Phases 2-3, as the plan asks.

**P0. Measure first (no behaviour change).**
- ClientHello capture: a test listener parses Dart's hello on Linux, Android, Windows, computes JA3/JA4 and pins
  it in a fixture, so an SDK bump that changes it fails a test and a human decides. Compare with Chrome,
  Firefox, rustls (public fingerprint lists; unverified today).
- Layer benchmark (Dart test that prints, over a delaying fake link): time-to-ready (connect to first signed
  health) and MB/s for plain, wss, borrowed, plus CPU per MB. Borrowed seals every <=8 KiB record with
  pure-Dart ChaCha20-Poly1305 (`cryptography` without `cryptography_flutter`, pubspec.yaml:12-15) on the main
  isolate, on top of Noise's own pass: a throughput and jank risk for relay blobs (pitfall 19). DoH: handshakes
  per lookup (now up to 6).
- Prober corpus (Rust test plus a lab script, section 7): its diff against a reference is the G4 list.
- Baselines go in the progress log; a later regression blocks the release (global rule).

**S1. Reach: bootstrap without 7667 (Phase 1; benefit high, cost low).**
- Approach: relay link gains `&borrowed=borrowed://host[:port]/sni` (existing route syntax, models.dart:268);
  signed default manifests may carry `borrowed` entries (SNI in `path`); `install_relay.sh --borrow SITE` writes
  `borrow-*` and prints the link. The app adopts link addresses pinned to the link key before adding them (G2
  review M1) and confirms with signed health inside the new session. The relay logs a rate-limited warning when
  the site is unreachable or resolves outside its own /16 (the IP-vs-SNI tell). RELAY.md gains "host where the
  censor lets you through and borrow a site from the same network" (docs only).
- Compat: an unknown link parameter is ignored by older apps (`RelayLink.tryParse` reads named parameters).
  Old relays: nothing to adopt. No capability. Cost: none at runtime.
- Security: pinned to the link key; an unpinned borrowed route is refused (`_channelTo` throws).

**S2. Reach: a relay that hides its plain port (Phase 1; benefit high, cost low; closes G1).**
- Approach: `plain = public|loopback|off` (default `public`, unchanged). `loopback` binds 7667 TCP and UDP to
  127.0.0.1; the installer's health check (`http://127.0.0.1:7667/health`, install_relay.sh:521) still works,
  and the outer layers call `handle_connection` directly, so they do not need the public port. `off` is manual
  only. The installer offers `loopback` after setting up 443 or borrowed, and only after a local self-test of
  the hidden listener.
- Compat: operator opt-in. Apps from before G2 (stable v0.4.2 has no wss or borrowed) cannot use such a relay;
  RELAY.md and the installer say so. New app on an old relay: unchanged.
- Cost: none. Security: `CNS2`, cleartext v1, the CORS API and cleartext UDP leave the public surface.

**S3. Fidelity: the relay behind the operator's web server (Phase 1; benefit high, cost low).**
- Approach: `ws-bind = 127.0.0.1:PORT`, a plain-WebSocket layer on the secret path reusing `websocket_bridge`
  (outer.rs:359). nginx or Caddy owns 443, the real cert and ACME, HTTP/2 and the real site, and proxies only
  `location = /<secret>` with `Upgrade`. RELAY.md gets a tested snippet that answers non-upgrade requests in
  the front, so the relay's TLS stack is never seen; the relay closes anything that is not a valid upgrade.
  X-Forwarded-For is trusted only from loopback peers on this layer (else all clients share 127.0.0.1's
  per-address limits). Config refuses a non-loopback `ws-bind` unless `ws-bind-public` is also set.
- Compat: the app sees an ordinary `wss://domain/path`; old apps already speak it. Operator opt-in.
- Cost: one local hop on the relay, none on the client. Security: no open proxy (only the relay's own
  protocols behind it), loopback by default, per-address caps still apply through XFF.
- Not doing: HTTP/2 in our own TLS decoy (large; S3 gives the real thing).

**S4. Choice: automatic, scoped, remembered, cheap on the normal path (Phase 2).**
- Approach: `StealthPlanner` (pure Dart, injected clock, no statics). Input: one relay's endpoints (same pinned
  key), the network's `RouteOutcome`s, preferences. Output: an ordered plan of {endpoint, delay, split?, DoH?}.
  Rules: (a) what worked here recently goes first; (b) else wss first when a pinned hidden address exists (no
  `CNS2` on the wire; P0 decides if the cost is fine), plain next, borrowed last unless the others failed or are
  blocked here (two sockets, double AEAD); (c) a second attempt starts 300 ms later, at most 2 in parallel,
  losers closed, only when this network is judged blocking or the last 3 attempts here failed; otherwise
  sequential as today; (d) a failed layer backs off per network (1 min doubling to 1 h); permanent errors (pin
  mismatch, bad identity) never retry on other layers.
- Scoped activation: DoH and splitting apply per host (its route is blocked here, or its last connect failed
  with dns/reset/tls/timeout), not globally; a filtered Tor no longer switches them on for Matrix and email. A
  first connect to an unseen host that fails that way retries once with DoH + split and records whether it
  helped (optional additive field on `RouteOutcome` JSON; <=32 routes per network already bound it).
- Extra split strategies (a random offset inside the SNI, a cut before the SNI extension) only if the lab shows
  the current one failing. No fake or out-of-order packets (zapret-style): they need raw sockets or root.
- Compat: none (hop-local). Cost: normal path adds no work (tested: one dial, no loopback proxy started);
  blocked path <=1 extra attempt per layer per backoff window. Measure: dials per send on a healthy fake
  network; time-to-ready under a fake DPI.
- Debt fixed here: the static maps move to an instance owned by the controller and clear on vault reset (G12).

**S5. Resolver resilience (Phase 2; benefit medium, cost low).**
- Approach: a keep-alive `HttpClient` per DoH endpoint (1 handshake, not up to 6, per name); a last-known-good
  address list per host (<=64 hosts x <=4 addresses, 7 days, in the network record, ~5 KB: pitfall 13), used
  only when DoH and the system lookup both fail (the identity is pinned, so a stale address cannot impersonate);
  a user-set DoH URL and two more built-in endpoints so the list is not Cloudflare/Google only. Endpoints never
  come from network input or from a relay. Sinkhole filter stays; no system fallback under "always".
- Compat: none. Measure: handshakes per lookup, lookups per connect.

**S6. Shape on stealth routes only (Phase 2; benefit low, cost low; last).**
- Approach: send `PAD` frames to round small records up to buckets (256 B steps to 1 KiB) and jitter the
  heartbeat +-25% with one-shot timers cancelled on close (pitfall 3). No wire change: every v2 peer already
  ignores `PAD`. Honest effect: removes exact-size and fixed-period tells, not flow classifiers.
- Cost: small messages grow <=250 B, blobs unchanged. Measure: bytes per message; idle wakeups per hour (must
  not rise; the jittered timer replaces the periodic one).

**S7. Phase 3, conditional.**
- S7a Fingerprint gate, after P0: if Dart's hello is rare or unlike browsers, spike a native TLS client in
  `conest_native` (BoringSSL via `boring`, a Chrome-like profile, offered to Dart as the loopback tap that
  `BorrowedTlsChannel` and wss already use). Adopt only if CI builds Android, Linux, Windows, <=1.5 MB per ABI,
  no symbol clash with aws-lc-sys (matrix-sdk) or the Dart VM's BoringSSL, and a profile-update routine is
  written (Chrome's hello changes each release: ML-KEM key share, extension permutation). Else M57.
- S7b Bring your own tunnel: outbound SOCKS5 (hostnames sent to the proxy, never resolved locally) and HTTP
  CONNECT in `Circumvention`, for users who already run Xray, Hysteria2, `ssh -D` or Psiphon. This answers
  "SSH" and "Hysteria2" without embedding them. Native Matrix, Iroh and Tor need their own proxy settings
  (Iroh's relay client: check, unverified). Credentials in the vault, never logged. Needs a decision (Q1).
- S7c Beacon sunset: `quietLan` default goes sealed-only one stable after the first stable that ships G2;
  cleartext still accepted for one more stable. A release-policy decision, no new wire.
- S7d SNI router on 443 (relay): the borrowed site's SNI to the borrowed layer, the relay's domain to the TLS
  layer, so one IP:443 serves both. It must reassemble a ClientHello split across records or segments (our
  own splitting does exactly that) within a 3 s budget. Optional, after S1-S3 are reviewed.

**To M57 (heavy or regional).**
- Hysteria2-like QUIC: UDP is the first thing whitelists drop and QUIC v1 SNI is filtered in Russia and China;
  Dart has no QUIC, so it needs `quinn` in native, a stream FFI and a UDP-capable layer trait; its win (loss
  tolerance) matters for bulk, not messages. Iroh gives QUIC where UDP works.
- SSH layer: banner and handshake are identifiable and often throttled; S7b covers users who want it.
- ECH: dart:io has none, rustls has client ECH only, Cloudflare is the one wide deployment and its static outer
  SNI is blocked in Russia [2]. Revisit with S7a and a front that supports ECH.
- Fake/out-of-order packets (root), 16 KB throttle rotation, cover traffic against flow classifiers,
  whitelisted-ASN deployments as code. For any UDP layer, `OuterLayer` first needs a transport-neutral accept path.

Security, all items. No open proxy: borrowed forwards only to the operator's `borrow-site`, `decoy-proxy` only to
the operator's upstream, `ws-bind` carries only the relay's protocols, the SOCKS client is outbound to a proxy
the user typed. Probes get the decoy or the real site. The secret path is a bearer token inside TLS and is not
rotated (Q5). Replay: borrowed tags bind to the site's per-connection random; v2 has Noise; sealed UDP keeps its
cookies and budgets; the beacon key is public by design. Everything is bounded; no secret path, key or token is logged.
Licences (check each with `cargo metadata` in CI before adding; only the first two read from public pages):
rustls Apache-2.0/MIT/ISC (client ECH in 0.23); wreq Apache-2.0 (BoringSSL based); `boring`/BoringSSL Apache-2.0
plus OpenSSL/ISC terms, `quinn` MIT/Apache-2.0, `russh` Apache-2.0 (the last three from memory). Go uTLS is
unusable; impit's patched rustls is unchecked, so unusable. P0 and S1-S6 add no crate (the SOCKS client is our
own ~200 lines). `conest_native` is MPL-2.0, which takes all of these; S7a adds BoringSSL notices.

### 5. Invariants against Known pitfalls 1-20

- 1 Connect attempts (plan, race, DoH) run in the transport's connect step, never in inbound processing; the
  planner is pure. 2, 16 Races finish before sealing: the envelope is encrypted only after a winner exists and
  the transport's turn is taken; a losing attempt never holds a sealed envelope.
- 3 Stagger and jitter timers are one-shot, cancelled on session close, dispose, vault reset, cold mode.
- 4 Sessions are leases: a session cut mid-fetch leaves leases unacknowledged; nothing is parked.
- 5 A relay-cap or limiter refusal is not a layer failure; only connect-level errors count.
- 6, 12 No new statics; existing ones move to the controller and clear on reset and dispose (G12); every map has
  a cap and expiry (LKG <=64 hosts, plan memory <=32 routes per network, DoH cache 256).
- 7 No hold conditions. 8, 15 Layers are ranked by verified signed health and receipts, not connect or TLS
  success: a decoy answer is a failure. 9 Linked and learned addresses are pinned and key-checked before they
  are added or ranked. 10 Failure counters run on every connect path (poll, long poll, subscribe, UDP, blob,
  LAN), one test each. 11 Backoff uses timers, not recursion through the planner.
- 13 Vault growth is LKG addresses and an optional strategy field per route, ~5 KB, bounded in bytes.
- 14 Hop-local; relay features announced in signed health; peers need nothing.
- 17 Attempt caps and per-network backoff; a dead layer is skipped, never waited on at the head of the send
  queue; permanent errors stop retries. 18 Additive JSON only, nothing deleted, `plain` defaults to public.
- 19 ClientHello and DoH parsing happen at connect time; if P0 shows AEAD cost, borrowed sealing moves off the
  main isolate or to native. 20 Planner and backoff tests build every timestamp from the injected clock.

### 6. Failure cases

- Stealth-only relay, app has only `host:7667`: `refused` is not a blocking kind (network_history.dart:230); the
  app says the relay needs its link. No loop. Wrong or rotated secret path (decoy answered): route failed "path
  rejected", no retry on it, others tried.
- Relay or per-address cap: the silent close looks like `reset` (outer.rs:679); scoped activation (S4) limits
  the harm to that route's ordering. Borrowed site down: the relay closes silently (borrowed.rs:236), the
  client sees a reset, other layers carry on, the operator log warns. Site on TLS 1.2, HelloRetryRequest or
  resumption: untested today, so Phase 1 adds tests; until then docs say pick a TLS 1.3 site.
- DPI reassembles records, or whitelists IP+SNI: the split fails or borrowed resets after the hello; backoff
  grows, attempts are capped, the screen says what this network lets through and points at email/Nostr.
  DoH endpoints blocked: LKG addresses, then system (never under "always"), then a dns error.
- 16 KB throttle: the session dies mid-fetch; leases replay after reconnect; no loss. `ws-bind` public by
  mistake: config refuses; XFF spoofing: loopback peers only. Vault reset with channels open: channels close,
  maps clear. Old app + new relay (plain public): unchanged.

### 7. Tests (strict fakes; * marks a sabotage check)

Dart (`flutter test`):
- Fake DPI family extending circumvention_test.dart:135: (a) drops a hello with the SNI in one segment (exists);
  (b) reassembles TCP but not TLS records, so only the record split passes *; (c) reassembles records too: the
  planner moves on, attempts capped, no loop *; (d) IP+SNI allowlist: borrowed passes only for an allowed pair;
  (e) cuts after 16 KB per connection: session ends cleanly, leases replay, no stray error.
- Planner (injected clock, fake channel factory): a healthy network gives one dial and starts no proxy *
  (sabotage: always start); stagger only when blocking is judged, losers closed *; backoff and expiry; permanent
  errors do not retry; failure counters per connect path; scoped activation (Tor blocked, Matrix stays plain) *.
- Resolver: a fake DoH server counts TLS accepts (1 per N queries) *; blocked endpoints use LKG; LKG unused
  while DoH answers; caps hold. Fake SOCKS5/CONNECT server (strict): auth when set, hostname sent as a name and
  never resolved locally *, truncated, slow, wrong-version and over-long replies.
- Links and defaults: `&borrowed=` parsed, bad forms rejected, pinned before adding *; an old `RelayLink`
  reader ignores it. Shape: sizes fall into buckets, an old-client fake that ignores `PAD` works, idle wakeups
  do not rise. Static maps cleared on vault reset *.
Rust (CI only; sabotage runs on `sabotage/m38-<item>` branches as PLAN_AGENTS describes):
- Active prober (new, strict): the existing fake site and decoy as reference versus each listener, for a corpus:
  `GET /`, secret path without upgrade, wrong path, bad upgrade key or version, HTTP/2 preface, hello without
  SNI, wrong SNI, TLS 1.2 only, a truncated hello that stalls, random bytes, `CNS2\x01`, a recorded valid
  borrowed marker replayed on a new connection * (sabotage: bind the tag to nothing; the replay must then
  succeed and the test fail), a recorded valid upgrade replayed. Bytes equal the reference's (Date masked).
- `plain=loopback/off`: the public interface refuses TCP and UDP, 443 listeners work, the health-check address
  answers *. `ws-bind` behind a fake front: XFF from loopback only, non-loopback bind refused *, non-upgrade
  closed. Borrowed with a TLS 1.2 fake site and a HelloRetryRequest site. Stealth-listener caps unchanged,
  per-address slots released on every exit path.

### 8. Lab checks (the maintainer; lab phone Wi-Fi and Windows, no VPN)

- L1 Matrix per layer to the lab relay: plain 7667, wss 443, borrowed 443 (needs a site, Q6), each with DoH and
  split on and off: reached or not, and how it failed. L2 Dart's ClientHello from phone and Windows, captured
  on a laptop hotspot; JA3/JA4 against Chrome.
- L3 From an outside network, the prober corpus against the lab relay's public IP plus a JARM or
  `ssl-enum-ciphers` run, versus the real site and versus nginx. L4 On the phone: time-to-ready and MB/s per
  layer; idle wakeups over an hour (`dumpsys batterystats`).
- L5 Old app on a `plain=loopback` relay (expected: cannot connect; the new app works from the link); new app
  on an old relay (unchanged). L6 If a Hetzner-class host is at hand: bytes until stall (the 16 KB check).

### 9. Open questions for the maintainer

1. Is bring-your-own-tunnel (S7b) in M38, or left to OS-level VPN apps and desktop proxies?
2. For new installs, default `plain` to `loopback` when 443 or borrowed was set up and self-tested? This drops
   old-app access to that relay (stable v0.4.2 predates wss and borrowed).
3. Prefer wss everywhere when it exists (no `CNS2` on the wire; one extra RTT per pooled session, to be
   measured), or only when blocked? I propose "everywhere" if P0 shows <=2 RTT and no jank.
4. Native TLS spike (S7a): accept the build cost (CMake, NASM on Windows, NDK, ~1.5 MB per ABI) and a
   Chrome-profile upkeep, or put the fingerprint item straight into M57?
5. Link sharing publishes the secret path, which makes a bridge enumerable by IP. Accept (M52 covers
   distribution), or add path rotation (relay accepts old and new for 7 days, tells the new one in sessions)?
6. Which real site should the lab relay borrow, and which hosting network is it in (177.1.187.103)? The site
   should live in that network or ASN.
7. Beacon sunset (S7c): after which release does the default go sealed-only?
8. Which extra DoH endpoints are acceptable (S5)? A user-set URL is planned either way.

Sources (search-result summaries, not read in full; dates and rates as those pages state them):
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

Design note only (round 1); no code written. Ready for the design review. Implementation starts after the
maintainer says it passed. Nothing here needed a lab run yet; the lab checks are listed in the note, section 8.
Pitfalls 1-20 are checked against the design in section 5 (none unsatisfiable on paper).

## Progress log

- 2026-11-07: Read PLAN_M38.md, PLAN_AGENTS.md and the plan's M38, Group 2 and Group B sections. Inventoried
  relay (outer.rs, borrowed.rs, session.rs, udp_sealed.rs, config.rs, install_relay.sh) and app (relay_client,
  relay_v2/*, circumvention/*, network_history, messenger_controller hooks, tests). Searched current censorship
  reports (Russia TSPU, GFW, Iran) for the threat model. Wrote the design note.
- Decisions: the stealth core (TLS decoy, borrowed handshake, sealed UDP and beacon, DoH, split greeting) already
  exists, so M38 is scoped to reach, fidelity, hiding 7667, automatic scoped choice, and measurement; QUIC, SSH,
  ECH and fake-packet splitting go to M57; the fingerprint item is gated on a measurement and a build spike.
- No code, no CI runs this round.

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
