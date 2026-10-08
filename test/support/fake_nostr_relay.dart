import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:conest/src/nostr/event.dart';
import 'package:conest/src/nostr/relay.dart';

/// In-memory Nostr relays reached through [connect]: they store events,
/// answer subscriptions (kinds, #p, since), and can require NIP-42
/// authentication before serving gift wraps, as inbox relays do.
class FakeNostrRelays {
  final Map<String, FakeNostrRelay> _relays = {};

  FakeNostrRelay relay(
    String url, {
    bool requireAuth = false,
    String authRefusal = 'auth-required: gift wraps need AUTH',
  }) => _relays.putIfAbsent(
    url,
    () => FakeNostrRelay(url, requireAuth, authRefusal: authRefusal),
  );

  /// Connections open to all relays right now.
  int get openConnections => _relays.values.fold(
    0,
    (sum, relay) => sum + relay.openConnections,
  );

  /// Relays not created with [relay] refuse connections.
  Future<NostrSocket> connect(Uri url) async {
    final relay = _relays[url.toString()];
    if (relay == null || relay.down) {
      throw const SocketExceptionLike('connection refused');
    }
    return relay._open();
  }
}

class SocketExceptionLike implements Exception {
  const SocketExceptionLike(this.message);
  final String message;
  @override
  String toString() => message;
}

class FakeNostrRelay {
  FakeNostrRelay(
    this.url,
    this.requireAuth, {
    this.authRefusal = 'auth-required: gift wraps need AUTH',
  });

  final String url;
  final bool requireAuth;

  /// What a subscription is CLOSED with before signing in; strfry-based
  /// relays such as relay.damus.io start it with "ERROR: ".
  final String authRefusal;
  bool down = false;

  /// Closes every subscription with this message when set.
  String? closeSubscriptionsWith;

  /// Refuses every sign-in, as a misconfigured relay does.
  bool refuseAuth = false;

  /// Rejects published events with this message when set.
  String? rejectWith;
  final List<NostrEvent> stored = [];

  /// Public keys that signed in (NIP-42) to this relay.
  final List<String> authedPubkeys = [];
  final List<_Connection> _connections = [];

  NostrSocket _open() {
    final connection = _Connection(this);
    _connections.add(connection);
    if (requireAuth) connection._challenge();
    return connection;
  }

  /// Connections open right now.
  int get openConnections => _connections.length;

  /// [event] published by someone else: stored and sent to subscribers.
  void inject(NostrEvent event) {
    if (stored.any((existing) => existing.id == event.id)) return;
    stored.add(event);
    for (final connection in _connections) {
      connection._deliver(event);
    }
  }

  /// Drops every connection, as a relay restart would.
  Future<void> dropConnections() async {
    for (final connection in List.of(_connections)) {
      await connection._incoming.close();
    }
    _connections.clear();
  }

  void _publish(_Connection from, NostrEvent event) {
    if (!event.isValid) {
      from._reply(['OK', event.id, false, 'invalid: bad signature']);
      return;
    }
    final reject = rejectWith;
    if (reject != null) {
      from._reply(['OK', event.id, false, reject]);
      return;
    }
    if (!stored.any((existing) => existing.id == event.id)) {
      stored.add(event);
      for (final connection in _connections) {
        connection._deliver(event);
      }
    }
    from._reply(['OK', event.id, true, '']);
  }
}

class _Connection implements NostrSocket {
  _Connection(this._relay);

  final FakeNostrRelay _relay;
  final _incoming = StreamController<String>();
  final Map<String, Map<String, dynamic>> _subscriptions = {};
  String? _pendingChallenge;
  String? _authedPubkey;

  @override
  Stream<String> get messages => _incoming.stream;

  @override
  Future<void> close() async {
    _relay._connections.remove(this);
    if (!_incoming.isClosed) await _incoming.close();
  }

  void _reply(List<Object?> message) {
    if (!_incoming.isClosed) _incoming.add(jsonEncode(message));
  }

  void _challenge() {
    _pendingChallenge = '${Random().nextInt(1 << 30)}';
    scheduleMicrotask(() => _reply(['AUTH', _pendingChallenge]));
  }

  @override
  void send(String raw) {
    scheduleMicrotask(() => _handle(raw));
  }

  void _handle(String raw) {
    final message = jsonDecode(raw) as List<dynamic>;
    switch (message) {
      case ['EVENT', final Map<String, dynamic> json]:
        final event = NostrEvent.fromJson(json);
        if (event != null) _relay._publish(this, event);
      case ['REQ', final String id, final Map<String, dynamic> filter]:
        final kinds = (filter['kinds'] as List?)?.cast<int>();
        if (_relay.requireAuth &&
            (kinds?.contains(NostrKind.giftWrap) ?? true) &&
            _authedPubkey == null) {
          _reply(['CLOSED', id, _relay.authRefusal]);
          return;
        }
        if (_relay.closeSubscriptionsWith case final reason?) {
          _reply(['CLOSED', id, reason]);
          return;
        }
        _subscriptions[id] = filter;
        for (final event in _relay.stored) {
          if (_matches(filter, event)) _reply(['EVENT', id, event.toJson()]);
        }
        _reply(['EOSE', id]);
      case ['CLOSE', final String id]:
        _subscriptions.remove(id);
      case ['AUTH', final Map<String, dynamic> json]:
        final event = NostrEvent.fromJson(json);
        final ok =
            !_relay.refuseAuth &&
            event != null &&
            event.isValid &&
            event.kind == NostrKind.clientAuth &&
            event.tag('challenge') == _pendingChallenge &&
            event.tag('relay') == _relay.url;
        if (ok) {
          _authedPubkey = event.pubkey;
          _relay.authedPubkeys.add(event.pubkey);
        }
        _reply(['OK', event?.id ?? '', ok, ok ? '' : 'auth failed']);
    }
  }

  void _deliver(NostrEvent event) {
    for (final MapEntry(key: id, value: filter) in _subscriptions.entries) {
      if (_matches(filter, event)) _reply(['EVENT', id, event.toJson()]);
    }
  }

  bool _matches(Map<String, dynamic> filter, NostrEvent event) {
    final kinds = (filter['kinds'] as List?)?.cast<int>();
    if (kinds != null && !kinds.contains(event.kind)) return false;
    final since = filter['since'] as int?;
    if (since != null && event.createdAt < since) return false;
    final p = (filter['#p'] as List?)?.cast<String>();
    if (p != null && !p.contains(event.tag('p'))) return false;
    final g = (filter['#g'] as List?)?.cast<String>();
    if (g != null && !g.contains(event.tag('g'))) return false;
    // Inbox relays serve gift wraps only to their recipient.
    if (_relay.requireAuth &&
        event.kind == NostrKind.giftWrap &&
        event.tag('p') != _authedPubkey) {
      return false;
    }
    return true;
  }
}
