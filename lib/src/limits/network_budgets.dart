/// What each network lets one account do, as budgets for a
/// [NetworkLimiter]. The numbers stay below the published or observed
/// limits, so a burst is paced before a server has to push back, and a
/// server that does push back ("slow down", `retry_after`) is obeyed exactly
/// on top of these.
library;

import '../transport_models.dart';
import 'network_limiter.dart';
import 'radio_airtime.dart';

abstract final class NetworkBudgets {
  /// Telegram Bot API (core.telegram.org/bots/faq#broadcasting-to-users):
  /// at most about one message a second to one chat, about 30 a second
  /// overall; a 429 carries `retry_after` seconds (FLOOD_WAIT), obeyed
  /// exactly. Frames of one envelope go to one peer, so one a second, with
  /// no burst.
  static const LimiterBudget telegram = LimiterBudget(
    name: 'Telegram',
    gap: Duration(seconds: 1),
    burst: 1,
    maxGap: Duration(seconds: 30),
    maxQueue: 64,
    maxWait: Duration(seconds: 45),
  );

  /// Discord (discord.com/developers/docs/topics/rate-limits): a channel's
  /// message route allows about 5 messages in 5 seconds, 50 requests a
  /// second overall; a 429 carries `retry_after` seconds. One a second
  /// keeps under the route's bucket. (The client polls the REST API; there
  /// is no gateway, so no IDENTIFY limit (1 per 5 s, 1000 a day) to keep.)
  static const LimiterBudget discord = LimiterBudget(
    name: 'Discord',
    gap: Duration(seconds: 1),
    burst: 1,
    maxGap: Duration(seconds: 30),
    maxQueue: 64,
    maxWait: Duration(seconds: 45),
  );

  /// Matrix: synapse's default `rc_message` is 0.2 a second with a burst of
  /// 10, and matrix.org is more generous; the answer to going over is
  /// `M_LIMIT_EXCEEDED` with `retry_after_ms`, obeyed exactly. One a second
  /// with a burst of 10 stays close to that.
  static const LimiterBudget matrix = LimiterBudget(
    name: 'Matrix',
    gap: Duration(seconds: 1),
    burst: 10,
    maxGap: Duration(seconds: 30),
    maxQueue: 64,
    maxWait: Duration(seconds: 45),
  );

  /// Email. Chatmail relays answer "450 Too much mail" above about 60 mails
  /// a minute per account (chatmail's `max_user_send_per_minute`) and cut
  /// the connection of an account that keeps pushing (device lab); ordinary
  /// providers allow some hundreds an hour (Gmail 500 a day, many hosts
  /// 100 to 300 an hour).
  static LimiterBudget email({bool chatmail = false}) => LimiterBudget(
    name: chatmail ? 'Email (chatmail)' : 'Email',
    gap: const Duration(milliseconds: 1200),
    burst: 1,
    maxGap: const Duration(seconds: 30),
    quota: chatmail ? 50 : 150,
    window: chatmail ? const Duration(minutes: 1) : const Duration(hours: 1),
    maxQueue: 64,
    maxWait: const Duration(seconds: 30),
  );

  /// One Nostr relay: public relays drop the connection of a client that
  /// sends a burst (device lab, G6), so events leave 200 ms apart; a relay
  /// that says "rate-limited" gets the gap doubled, up to 8 seconds. The
  /// limiter is per relay.
  static const LimiterBudget nostrRelay = LimiterBudget(
    name: 'Nostr relay',
    gap: Duration(milliseconds: 200),
    burst: 1,
    maxGap: Duration(seconds: 8),
    maxQueue: 64,
    maxWait: Duration(seconds: 15),
  );

  /// XMPP: servers differ (ejabberd and prosody throttle a c2s stream by
  /// bytes per second and answer `policy-violation` or close the stream),
  /// so a short burst and then four stanzas a second.
  static const LimiterBudget xmpp = LimiterBudget(
    name: 'XMPP',
    gap: Duration(milliseconds: 250),
    burst: 5,
    maxGap: Duration(seconds: 30),
    maxQueue: 64,
    maxWait: Duration(seconds: 30),
  );

  /// A Conest relay (v2): the relay itself allows 240 stores and 1200
  /// requests a minute per address and 32 MiB of stores a minute
  /// (`DEFAULT_MAX_STORES_PER_MINUTE` in conest_relay); a refusal names the
  /// wait. 200 stores a minute with a burst of 20 stays under it. Per relay.
  static const LimiterBudget conestRelay = LimiterBudget(
    name: 'Conest relay',
    gap: Duration(milliseconds: 300),
    burst: 20,
    quota: 200,
    window: Duration(minutes: 1),
    maxQueue: 64,
    maxWait: Duration(seconds: 20),
  );

  /// Other store-and-forward carriers (Tor onion mailboxes and the like)
  /// where the network names no limit: a light pacing so a burst does not
  /// look like abuse.
  static const LimiterBudget generic = LimiterBudget(
    name: 'Network',
    gap: Duration(milliseconds: 250),
    burst: 4,
    maxQueue: 64,
    maxWait: Duration(seconds: 30),
  );

  /// The budget of the carrier on [kind]; null for transports that need no
  /// account limit (LAN, Iroh) or limit by airtime (radios, see
  /// `radio_airtime.dart`).
  static LimiterBudget? forKind(
    TransportKind kind, {
    bool chatmail = false,
    bool radio = true,
  }) => switch (kind) {
    TransportKind.telegram => telegram,
    TransportKind.discord => discord,
    TransportKind.matrix => matrix,
    TransportKind.deltaChat => email(chatmail: chatmail),
    TransportKind.xmpp => xmpp,
    TransportKind.conestRelay => conestRelay,
    TransportKind.tor => generic,
    TransportKind.meshtastic ||
    TransportKind.meshCore ||
    TransportKind.reticulum => RadioAirtime.forKind(kind, radio: radio),
    _ => null,
  };
}
