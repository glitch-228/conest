import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'nostr/event.dart';
import 'nostr/nip17.dart';
import 'nostr/nip19.dart';
import 'nostr/relay.dart';
import 'nostr/secp256k1.dart';
import 'nostr_carrier.dart' show defaultNostrRelays;

/// The saved setup for Nostr private messages (NIP-17): this account's
/// Nostr key, the relays it reads them from, and how far it has read.
class NostrDirectConfig {
  const NostrDirectConfig({
    required this.secretKey,
    required this.relays,
    this.since,
    this.enabled = true,
  });

  /// A new key, reading from the default relays.
  factory NostrDirectConfig.create() => NostrDirectConfig(
    secretKey: hexEncode(Secp256k1.generateSecretKey()),
    relays: [for (final relay in defaultNostrRelays) Uri.parse(relay)],
  );

  /// Hex; never shared, and never the Conest carrier's key.
  final String secretKey;
  final List<Uri> relays;

  /// Newest gift-wrap time read.
  final int? since;

  /// Off keeps the key (the npub people know) for when it comes back on.
  final bool enabled;

  Uint8List get secretKeyBytes => hexDecode(secretKey)!;
  String get publicKey => hexEncode(Secp256k1.publicKey(secretKeyBytes));

  NostrDirectConfig copyWith({List<Uri>? relays, int? since, bool? enabled}) =>
      NostrDirectConfig(
        secretKey: secretKey,
        relays: relays ?? this.relays,
        since: since ?? this.since,
        enabled: enabled ?? this.enabled,
      );

  Map<String, Object?> toJson() => {
    'secretKey': secretKey,
    'relays': [for (final relay in relays) relay.toString()],
    if (since != null) 'since': since,
    if (!enabled) 'off': true,
  };

  static NostrDirectConfig? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final secret = json['secretKey'];
    final relays = json['relays'];
    if (secret is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(secret) ||
        relays is! List) {
      return null;
    }
    return NostrDirectConfig(
      secretKey: secret,
      relays: [
        for (final relay in relays)
          if (relay is String)
            if (Uri.tryParse(relay) case final uri? when uri.scheme == 'wss')
              uri,
      ],
      since: json['since'] as int?,
      enabled: json['off'] != true,
    );
  }
}

/// Nostr private messages (NIP-17) with anyone on Nostr: reads gift wraps
/// for this account's key from its relays, publishes its list of relays
/// (kind 10050) so others know where to write, and sends to each
/// recipient's listed relays.
class NostrDirectService {
  NostrDirectService({
    required Uint8List secretKey,
    required this.relays,
    required this.onMessage,
    int? since,
    this.onCursor,
    this.onStatusChanged,
    NostrSocketConnector? connector,
    DateTime Function()? now,
    this.indexers = defaultNostrIndexers,
  }) : _secretKey = secretKey,
       publicKey = hexEncode(Secp256k1.publicKey(secretKey)),
       _connector = connector,
       _now = now ?? DateTime.now {
    _cursor = since ?? _seconds(_now());
  }

  /// Relays that collect relay lists, where others look for ours.
  static const List<String> defaultNostrIndexers = ['wss://purplepag.es'];

  final Uint8List _secretKey;
  final String publicKey;
  final List<Uri> relays;
  final List<String> indexers;
  final void Function(NostrDirectMessage message) onMessage;
  final void Function(int since)? onCursor;
  final void Function()? onStatusChanged;
  final NostrSocketConnector? _connector;
  final DateTime Function() _now;

  final Map<String, NostrRelay> _readers = {};
  final Map<String, NostrRelay> _writers = {};
  final LinkedHashSet<String> _seen = LinkedHashSet();
  final Map<String, (List<Uri>, DateTime)> _relayLists = {};
  late int _cursor;
  bool _started = false;
  Timer? _idleTimer;
  int _unwrapMinute = 0;
  int _unwrapsThisMinute = 0;

  /// Gift wraps opened per minute: each costs two key agreements and a
  /// signature check, and anyone can send them.
  static const int _maxUnwrapsPerMinute = 600;
  static const Duration _writerIdle = Duration(minutes: 5);

  /// Gift wraps are dated up to two days back; reading starts that much
  /// earlier, and an hour more for clocks.
  static final int _lookBack =
      Nip17.timestampJitter.inSeconds + const Duration(hours: 1).inSeconds;
  static const int _maxSeen = 8192;
  static const int _maxContentChars = 128 * 1024;

  /// `npub` of this account.
  String get npub => Nip19.npub(publicKey);

  /// `nprofile` of this account: the key and where to write to it.
  String get nprofile => Nip19.nprofile(publicKey, relays);

  /// Whether the relays serve this account's messages.
  bool get reading => _readers.values.any((relay) => relay.reading);

  void start() {
    if (_started) return;
    _started = true;
    for (final url in relays) {
      _readers.putIfAbsent(
        url.toString(),
        () => NostrRelay(
          url: url,
          authKey: () => _secretKey,
          connector: _connector,
          filter: () => {
            'kinds': [NostrKind.giftWrap],
            '#p': [publicKey],
            'since': _cursor - _lookBack,
          },
          onEvent: _receive,
          onStateChanged: onStatusChanged,
        )..start(),
      );
    }
    unawaited(_publishRelayList().catchError((Object _) {}));
    _idleTimer ??= Timer.periodic(const Duration(minutes: 1), (_) {
      if (!_listPublished) {
        unawaited(_publishRelayList().catchError((Object _) {}));
      }
      final cutoff = DateTime.now().subtract(_writerIdle);
      for (final entry in _writers.entries.toList()) {
        if (entry.value.lastUsed.isBefore(cutoff)) {
          _writers.remove(entry.key);
          unawaited(entry.value.stop());
        }
      }
    });
  }

  Future<void> stop() async {
    _started = false;
    _idleTimer?.cancel();
    _idleTimer = null;
    _drainTimer?.cancel();
    _drainTimer = null;
    _backlog.clear();
    final all = [..._readers.values, ..._writers.values];
    _readers.clear();
    _writers.clear();
    await Future.wait([for (final relay in all) relay.stop()]);
  }

  void _receive(NostrEvent wrap) {
    if (wrap.kind != NostrKind.giftWrap ||
        wrap.tag('p') != publicKey ||
        wrap.content.length > _maxContentChars ||
        _seen.contains(wrap.id)) {
      return;
    }
    final minute = _now().millisecondsSinceEpoch ~/ 60000;
    if (minute != _unwrapMinute) {
      _unwrapMinute = minute;
      _unwrapsThisMinute = 0;
    }
    // A copy that did not open before (junk) costs nothing again.
    if (_failed.contains(wrap.id)) return;
    // Over budget: it waits, and is opened when the minute allows.
    if (_unwrapsThisMinute >= _maxUnwrapsPerMinute) {
      if (!_backlog.any((queued) => queued.id == wrap.id)) {
        _backlog.add(wrap);
        if (_backlog.length > _maxBacklog) _backlog.removeAt(0);
      }
      _drainTimer ??= Timer(
        Duration(seconds: 61 - _now().second),
        _drainBacklog,
      );
      return;
    }
    _unwrapsThisMinute++;
    final message = Nip17.unwrap(wrap, _secretKey);
    if (message == null) {
      _failed.add(wrap.id);
      if (_failed.length > _maxSeen) _failed.remove(_failed.first);
      return;
    }
    // Seen only once read: a junk copy under the same id cannot hide it.
    _seen.add(wrap.id);
    if (_seen.length > _maxSeen) _seen.remove(_seen.first);
    if (wrap.createdAt > _cursor && wrap.createdAt <= _seconds(_now()) + 600) {
      _cursor = wrap.createdAt;
      onCursor?.call(_cursor);
    }
    onMessage(message);
  }

  final LinkedHashSet<String> _failed = LinkedHashSet();
  final List<NostrEvent> _backlog = [];
  static const int _maxBacklog = 5000;
  Timer? _drainTimer;

  void _drainBacklog() {
    _drainTimer = null;
    if (!_started) return;
    final waiting = List.of(_backlog);
    _backlog.clear();
    for (final wrap in waiting) {
      _receive(wrap);
    }
  }

  /// Publishes this account's DM relay list where others look for it, on
  /// connections of its own: the ones that carry messages never send
  /// anything signed by the account.
  Future<void> _publishRelayList() async {
    final list = Nip17.dmRelayList(_secretKey, relays, _now());
    var published = false;
    await Future.wait([
      for (final url in {
        ...relays.map((relay) => relay.toString()),
        ...indexers,
      })
        () async {
          final relay = NostrRelay(
            url: Uri.parse(url),
            authKey: () => Secp256k1.generateSecretKey(),
            connector: _connector,
          )..start();
          try {
            await relay.publish(list);
            published = true;
          } catch (_) {
            // Another relay may have it.
          } finally {
            await relay.stop();
          }
        }(),
    ]);
    _listPublished = published;
  }

  /// Whether the last lookups reached any relay at all.
  bool _reachedAny = false;

  /// Whether the relay list reached a relay; tried again until it has.
  bool _listPublished = false;

  /// Sends [content] to [recipients] (public keys, hex); [hints] are relays
  /// the user knows for some of them (from an nprofile). Every recipient
  /// gets a copy at their listed relays, and this account one at its own.
  /// Throws when a recipient's copy reached no relay.
  Future<NostrDirectMessage> send(
    List<String> recipients,
    String content, {
    String? subject,
    Map<String, List<Uri>> hints = const {},
  }) async {
    if (!_started) throw StateError('Nostr messages are off.');
    final wraps = Nip17.wrap(
      secretKey: _secretKey,
      recipients: recipients,
      content: content,
      subject: subject,
      now: _now(),
    );
    // Where everyone reads first: nothing goes out if someone cannot be
    // reached at all.
    final targets = {
      for (final recipient in {...recipients}..remove(publicKey))
        recipient: await relaysOf(
          recipient,
          hints: hints[recipient] ?? const [],
        ),
    };
    Future<bool> publish(NostrEvent wrap, List<Uri> to) async {
      var stored = false;
      await Future.wait([
        for (final url in to)
          if (_writer(url) case final writer?)
            writer
                .publish(wrap)
                .then((_) => stored = true)
                .catchError((Object _) => stored),
      ]);
      return stored;
    }

    final failed = <String>[];
    await Future.wait([
      for (final (recipient, wrap) in wraps)
        if (recipient != publicKey)
          publish(wrap, targets[recipient]!).then((stored) {
            if (!stored) failed.add(recipient);
          }),
    ]);
    if (!_started) throw StateError('Nostr messages were turned off.');
    final delivered = targets.length - failed.length;
    final own = wraps.firstWhere((entry) => entry.$1 == publicKey).$2;
    // Our own copy (for our other devices, and the chat after a restart)
    // only once someone got theirs.
    if (delivered > 0 || targets.isEmpty) await publish(own, relays);
    if (failed.isNotEmpty) {
      throw StateError(
        '${delivered > 0 ? 'Sent, but no' : 'No'} relay took the message for '
        '${failed.map((key) => Nip19.npub(key).substring(0, 12)).join(', ')}.',
      );
    }
    return Nip17.unwrap(own, _secretKey)!;
  }

  /// Where [publicKey] reads direct messages: its kind-10050 list, looked
  /// up on [hints], the indexers and our relays. As NIP-17 asks, without
  /// a list nothing is sent, unless the user gave relays for them (in an
  /// nprofile). Remembered for an hour.
  Future<List<Uri>> relaysOf(
    String publicKey, {
    List<Uri> hints = const [],
  }) async {
    final cached = _relayLists[publicKey];
    if (cached != null &&
        _now().difference(cached.$2) < const Duration(hours: 1)) {
      return cached.$1;
    }
    final usableHints = [
      for (final hint in hints)
        if (isPublicNostrRelay(hint)) hint,
    ].take(3).toList();
    final sources = {
      ...usableHints.map((uri) => uri.toString()),
      ...indexers,
      ...relays.map((uri) => uri.toString()),
    }.take(8);
    NostrEvent? newest;
    _reachedAny = false;
    await Future.wait([
      for (final url in sources)
        _lookUp(Uri.parse(url), publicKey).then((found) {
          if (found != null &&
              (newest == null || found.createdAt > newest!.createdAt)) {
            newest = found;
          }
        }),
    ]);
    // Someone's list cannot send this device into its own network.
    final listed = newest == null
        ? const <Uri>[]
        : Nip17.relaysFrom(newest!).where(isPublicNostrRelay).toList();
    if (listed.isEmpty && usableHints.isEmpty) {
      throw StateError(
        _reachedAny
            ? '${Nip19.npub(publicKey).substring(0, 12)}… has no relays for '
                  'private messages yet (their app may not support NIP-17).'
            : 'Could not reach any Nostr relay to find where '
                  '${Nip19.npub(publicKey).substring(0, 12)}… reads.',
      );
    }
    final result = listed.isNotEmpty ? listed : usableHints;
    _relayLists[publicKey] = (result, _now());
    return result;
  }

  /// [publicKey]'s newest valid DM relay list on [url], within a few
  /// seconds. A list must check out before it can count as newest: a
  /// forged one must not push out the real one.
  Future<NostrEvent?> _lookUp(Uri url, String publicKey) async {
    if (!_started) return null;
    NostrEvent? found;
    final relay = NostrRelay(
      url: url,
      authKey: () => Secp256k1.generateSecretKey(),
      connector: _connector,
      filter: () => {
        'kinds': [Nip17Kind.dmRelays],
        'authors': [publicKey],
        'limit': 1,
      },
      onEvent: (event) {
        if (event.pubkey == publicKey &&
            (found == null || event.createdAt > found!.createdAt) &&
            Nip17.relaysFrom(event).isNotEmpty) {
          found = event;
        }
      },
    )..start();
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!relay.reading && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    if (relay.reading) _reachedAny = true;
    await relay.stop();
    return found;
  }

  /// A connection for publishing gift wraps; none once stopped. It signs
  /// in (if asked) with a throwaway key, never the account's.
  NostrRelay? _writer(Uri url) {
    if (!_started) return null;
    return _writers.putIfAbsent(url.toString(), () {
      final throwaway = Secp256k1.generateSecretKey();
      return NostrRelay(
        url: url,
        authKey: () => throwaway,
        connector: _connector,
      )..start();
    });
  }

  static int _seconds(DateTime time) => time.millisecondsSinceEpoch ~/ 1000;
}

/// Whether [relay] may be used for someone's messages: wss, and not this
/// machine or a private network.
bool isPublicNostrRelay(Uri relay) {
  if (relay.scheme != 'wss' || relay.host.isEmpty) return false;
  final host = relay.host.toLowerCase();
  if (host == 'localhost' ||
      host.endsWith('.localhost') ||
      host.endsWith('.local') ||
      host.endsWith('.internal')) {
    return false;
  }
  final address = InternetAddress.tryParse(
    host.replaceAll('[', '').replaceAll(']', ''),
  );
  if (address == null) return true;
  return !(address.isLoopback ||
      address.isLinkLocal ||
      address.isMulticast ||
      _isPrivate(address));
}

bool _isPrivate(InternetAddress address) {
  final bytes = address.rawAddress;
  if (address.type == InternetAddressType.IPv4) {
    return bytes[0] == 10 ||
        bytes[0] == 0 ||
        (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] < 32) ||
        (bytes[0] == 192 && bytes[1] == 168) ||
        (bytes[0] == 100 && bytes[1] >= 64 && bytes[1] < 128);
  }
  return (bytes[0] & 0xfe) == 0xfc;
}
