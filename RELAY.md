# Running a Conest relay

A Conest relay keeps end-to-end encrypted envelopes for devices that are
not online at the same time. It never sees what is inside them. This page
is for operators; `tool/install_relay.sh` installs the relay and its
supervisor (which keeps it updated from signed releases).

## Ports and protocols

- **7667, TCP, UDP and HTTP** (the default): the original JSON protocol
  (v1), and v2 sessions on the same TCP port. A v2 session is one
  long-lived connection encrypted with Noise
  (`Noise_NK_25519_ChaChaPoly_SHA256`) against the relay's session key,
  which the relay's identity signs. Inside a session the network sees
  neither mailbox ids nor tokens, many requests share the connection, and
  new messages are pushed to the device instead of long polls.
- **443 (or any port), TLS** (optional): the relay looks like an ordinary
  web site. See below.

## Configuration

Flags, environment variables, or a `relay.conf` file next to the database
(the supervisor keeps it in its data directory; `--config PATH` names
another). Each line of the file is a flag without its dashes:

```
# relay.conf
tier1 = open
registration = invite
tls-bind = 0.0.0.0:443
tls-cert = /etc/letsencrypt/live/relay.example.org/fullchain.pem
tls-key = /etc/letsencrypt/live/relay.example.org/privkey.pem
decoy-proxy = 127.0.0.1:8080
```

Flags on the command line win over the file. Without a file, an updated
relay behaves as before: v1 as it was, sessions on 7667, registration
closed, no TLS.

## Who may use the relay

- `tier1`: who may leave messages. `open` (anyone; the default),
  `registered` (accounts registered on this relay), or `off`.
- `registration`: how accounts register. `open`, `invite` (an invite code
  from the operator), `password` (`registration-password`, at least 8
  characters; or `CONEST_RELAY_REGISTRATION_PASSWORD`), or `closed` (the
  default). Registration also opens the larger features (files, call
  media) that later versions add.
- `account-quota-bytes`: what one account may store a minute.
- `token-days`: how long a registration lasts before the app renews it.

The app shows each relay's policy (tap the relay in Settings → Connectivity)
and asks for the invite code or password when needed. Registration only
happens inside an encrypted session.

Invites, accounts and quotas:

```
conest_relay_supervisor invite create --uses 5 --expires-days 30
conest_relay_supervisor invite list
conest_relay_supervisor account list
conest_relay_supervisor account remove ACCOUNT_KEY
conest_relay_supervisor quota set ACCOUNT_KEY BYTES_PER_MINUTE
```

(or `conest_relay admin --database-path PATH ...` directly). A running
relay sees new invites at once, removed accounts and new quotas at its
next start.

## Mailbox owners

A device claims its mailbox the first time it uses a relay that keeps
owners (every relay from this version). After that only that device can
read or acknowledge its mail there; anyone can still leave mail. Claims are
limited per address and day (`mailbox-claims-per-day`, default 64) and
lapse after `owner-idle-days` (60) unused. Someone who knows a device id
could claim it first on a relay that device has not used yet; the device
then cannot fetch there (what is taken stays end-to-end encrypted).

### Contacts vouch

A relay cannot tell who really holds a device id, so the first claim wins
(as above). What a stranger can do with that is squat: claim a mailbox
before its device does. To make that visible, a device claims its mailbox
with its own long-term signing key (the key every contact has from its
invite, and nothing derived), and anyone may ask who owns a mailbox
(`{"action":"mailbox_owner","recipient_device_id":"..."}`; the answer's
`owner` is the key, or absent). Before the app leaves a contact's message
on a relay that keeps owners, it asks, and a mailbox owned by any key other
than the contact's signing key means that relay is not used for that
contact. A squatter can still make a relay useless for a contact, but
cannot read their mail, and the sender moves on to another route. Old
devices that never claim stay unclaimed with the old behaviour. Residual:
someone holding the device's signing key can claim; the cost of using the
signing key is that colluding relays can link one device's mailboxes.

## TLS on 443 with a decoy site

```
tls-bind = 0.0.0.0:443
tls-cert = /path/fullchain.pem
tls-key = /path/privkey.pem
ws-path = <8..64 letters, digits, - or _>     (optional)
decoy-dir = /var/www/site                     (or)
decoy-proxy = 127.0.0.1:8080
```

- **Certificate**: any certificate works. With a domain, use a real one
  (Let's Encrypt through certbot, acme.sh or your web server's ACME
  client); renewals need a restart of the relay to be read. A self-signed
  certificate also works, because the app checks the relay's identity
  inside: it skips the usual certificate check only for a relay whose
  identity it has pinned.
- **The secret path**: a WebSocket upgrade on it carries the relay's
  traffic. Without `ws-path` the relay makes one at its first start, keeps
  it in its database, and prints it. Treat it as a secret: it is what lets
  the app in.
- **The decoy**: everything else (a browser, a scanner, a request to the
  secret path without the WebSocket upgrade) gets an ordinary web site:
  - `decoy-proxy HOST:PORT`: requests go to a real site (a local nginx or
    any plain-HTTP server) as they came, and its answers come back as they
    are. This is the most convincing.
  - `decoy-dir DIR`: static files from a directory.
  - neither: a web server's default welcome page.
- **In the app**, the relay's hidden address is
  `wss://relay.example.org/<secret path>` (add it like any relay address,
  after the relay is known by its 7667 address or a relay link, so its
  identity is pinned).

The installer does this for you when it is given a domain with a
certificate (`install_relay.sh --domain relay.example.org`, or it asks): it
copies the certificate where the relay may read it (and refreshes it on
Let's Encrypt renewals), writes the settings above into `relay.conf` with a
made-up secret path and `public-host`, opens 443, and prints a relay link
that carries the hidden address (`&wss=`). Relays that learn their own
hidden address (`public-host`) tell it to clients inside encrypted sessions,
and the app then prefers it; old clients can use it too, since the same
channel also carries the original protocol.

The relay must be able to bind 443: run it as root through the supervisor's
service, or give the binary the capability
(`setcap cap_net_bind_service=+ep conest_relay`).

## Borrowed handshake (play a real website)

An alternative to the decoy on 443, for networks that only let through
traffic that looks like a visit to a well-known site:

```
borrow-bind = 0.0.0.0:443
borrow-site = www.example.com:443      (a real HTTPS site to play)
borrow-sni = www.example.com           (optional; default: the site's host)
public-host = relay.example.org        (so sessions can tell clients)
```

(Not together with `tls-bind` on the same port.) The relay forwards every
connection to the real site, record by record: a browser, a scanner or a
censor's probe gets that site's real certificate and pages. A Conest client
that has pinned the relay's identity does the real handshake with the SNI
set to the site, then adds one record only the relay recognises (an HMAC
over the site's ServerHello random, keyed from a key agreement with the
relay's identity key), and from there the relay's protocols run in records
that look like TLS application data (ChaCha20-Poly1305, random padding).
Clients learn the address inside an encrypted session and prefer it.

Limits: the relay's IP address is not the site's (a censor that checks IP
against SNI sees it), and the client's TLS hello is its library's, not a
browser's. Pick a site that is large and popular in the censor's country.

## Rolling back

`--legacy-threads` runs the old one-thread-per-connection server (v1 only:
no sessions, no TLS). The supervisor's `rollback` restores the previous
binary.
