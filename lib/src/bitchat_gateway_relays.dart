import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'bitchat/gateway.dart';
import 'nostr/event.dart';
import 'nostr/relay.dart';

/// The Nostr side of the bitchat gateway: connections to the relays bitchat
/// uses for each geohash cell, to publish what phones nearby hand over, and
/// subscriptions for the cells those phones use.
class BitchatGatewayRelays {
  BitchatGatewayRelays({
    required this.directory,
    required this.onEvent,
    NostrSocketConnector? connector,
    DateTime Function()? now,
  }) : _connector = connector,
       _now = now ?? DateTime.now;

  /// Where each cell's relays are; replaced when a fresher list arrives.
  BitchatGeoRelays directory;

  /// A geohash chat event from a relay for one of the followed cells.
  final void Function(NostrEvent event, String geohash) onEvent;

  final NostrSocketConnector? _connector;
  final DateTime Function() _now;

  /// A throwaway key, only for relays that ask to sign in.
  final Uint8List _authKey = Uint8List.fromList(
    List.generate(32, (_) => Random.secure().nextInt(256)),
  );

  final Map<String, NostrRelay> _publishers = {};
  final List<DateTime> _newPublisherTimes = [];
  final Map<String, (NostrRelay, Set<String>)> _readers = {};
  DateTime? _lastPublished;
  DateTime? _lastFailed;
  bool _closed = false;

  /// Publishing goes to this many of a cell's nearest relays, as bitchat
  /// does; reading from fewer is enough to see the cell.
  static const int publishRelays = 5;
  static const int readRelays = 2;
  static const int maxPublishers = 20;

  /// New relay connections a minute for publishing: deposits to cells all
  /// over the map cannot make this phone connect to every relay listed.
  static const int newPublishersPerMinute = 10;

  /// A publishing connection unused this long is closed.
  static const Duration idleAfter = Duration(minutes: 5);

  /// Whether relays seem reachable: unless the last publish reached none
  /// and no connection is up since.
  bool get connected {
    final failed = _lastFailed;
    if (failed == null) return true;
    final published = _lastPublished;
    if (published != null && published.isAfter(failed)) return true;
    return [
      ..._publishers.values,
      for (final (relay, _) in _readers.values) relay,
    ].any((relay) => relay.state == NostrRelayState.connected);
  }

  /// Publishes [event] to [geohash]'s relays; true when any took it.
  Future<bool> publish(NostrEvent event, String geohash) async {
    if (_closed) return false;
    var accepted = false;
    await Future.wait([
      for (final url in directory.closest(geohash, count: publishRelays))
        if (_publisher(url) case final relay?)
          () async {
            try {
              await relay.publish(event);
              accepted = true;
            } catch (_) {
              // That relay is out of reach; the others may take it.
            }
          }(),
    ]);
    accepted ? _lastPublished = _now() : _lastFailed = _now();
    return accepted;
  }

  /// The connection to [url], opened if the minute's allowance permits.
  NostrRelay? _publisher(Uri url) {
    final key = url.toString();
    final existing = _publishers[key];
    if (existing != null) return existing;
    final now = _now();
    _newPublisherTimes.removeWhere(
      (at) =>
          now.difference(at) >= const Duration(minutes: 1) || at.isAfter(now),
    );
    if (_newPublisherTimes.length >= newPublishersPerMinute) return null;
    _newPublisherTimes.add(now);
    if (_publishers.length >= maxPublishers) {
      final oldest = _publishers.entries.reduce(
        (a, b) => a.value.lastUsed.isBefore(b.value.lastUsed) ? a : b,
      );
      _publishers.remove(oldest.key);
      unawaited(oldest.value.stop());
    }
    final relay = NostrRelay(
      url: url,
      authKey: () => _authKey,
      connector: _connector,
    )..start();
    _publishers[key] = relay;
    return relay;
  }

  /// Follows [cells]: each cell's nearest relays are subscribed to its
  /// geohash chat; relays no longer needed are closed.
  void follow(Set<String> cells) {
    if (_closed) return;
    final wanted = <String, Set<String>>{};
    for (final cell in cells) {
      for (final url in directory.closest(cell, count: readRelays)) {
        wanted.putIfAbsent(url.toString(), () => {}).add(cell);
      }
    }
    for (final url in _readers.keys.toList()) {
      final (relay, following) = _readers[url]!;
      final next = wanted[url];
      if (next == null || !_sameSet(next, following)) {
        _readers.remove(url);
        unawaited(relay.stop());
      }
    }
    for (final MapEntry(key: url, value: following) in wanted.entries) {
      if (_readers.containsKey(url)) continue;
      final relay = NostrRelay(
        url: Uri.parse(url),
        authKey: () => _authKey,
        connector: _connector,
        filter: () => {
          'kinds': [bitchatGeohashEventKind],
          '#g': following.toList()..sort(),
          // Read on every (re)connect: only what is new.
          'since': _now().millisecondsSinceEpoch ~/ 1000 - 60,
        },
        onEvent: (event) {
          final cell = event.tag('g');
          if (cell != null && following.contains(cell)) onEvent(event, cell);
        },
      )..start();
      _readers[url] = (relay, following);
    }
  }

  /// Closes publishing connections unused for [idleAfter].
  void prune() {
    // The relay keeps its own (wall clock) time of last use.
    final now = DateTime.now();
    for (final MapEntry(key: url, value: relay)
        in _publishers.entries.toList()) {
      if (now.difference(relay.lastUsed) > idleAfter) {
        _publishers.remove(url);
        unawaited(relay.stop());
      }
    }
  }

  /// The cells followed right now.
  Set<String> get followed => {
    for (final (_, cells) in _readers.values) ...cells,
  };

  Future<void> close() async {
    _closed = true;
    final relays = [
      ..._publishers.values,
      for (final (relay, _) in _readers.values) relay,
    ];
    _publishers.clear();
    _readers.clear();
    await Future.wait([for (final relay in relays) relay.stop()]);
  }

  static bool _sameSet(Set<String> a, Set<String> b) =>
      a.length == b.length && a.containsAll(b);
}
