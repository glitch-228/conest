import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'carrier.dart';
import 'nostr/event.dart';
import 'nostr/nip44.dart';
import 'nostr/relay.dart';
import 'nostr/secp256k1.dart';
import 'transport_models.dart';

/// Relays a new Nostr carrier starts with: public relays that accept and
/// store gift-wrapped events and serve them without signing in, run by
/// different operators. (relay.damus.io asks readers of gift wraps to sign
/// in and, as of October 2026, refuses every sign-in.)
const List<String> defaultNostrRelays = [
  'wss://nos.lol',
  'wss://relay.primal.net',
  'wss://nostr.mom',
];

/// Relays that shut down, and the default each saved setup moves to.
const Map<String, String> _retiredNostrRelays = {
  'wss://relay.0xchat.com': 'wss://relay.primal.net',
};

/// [relays] with shut-down relays replaced (or dropped where the
/// replacement is already listed).
List<String> replaceRetiredNostrRelays(List<String> relays) {
  final result = <String>[];
  for (final relay in relays) {
    final replacement = _retiredNostrRelays[relay] ?? relay;
    if (!result.contains(replacement)) result.add(replacement);
  }
  return result;
}

/// Most relays an address may list.
const int maxNostrAddressRelays = 4;

/// Gift wraps expire on relays that honour NIP-40 after this long.
const Duration nostrCarrierExpiry = Duration(days: 7);

/// Version byte inside the encrypted content.
const int _contentVersion = 1;

/// A device's address on Nostr: its carrier public key and the relays it
/// reads from.
class NostrAddress {
  const NostrAddress({required this.publicKey, required this.relays});

  /// Lower-case hex x-only public key.
  final String publicKey;
  final List<Uri> relays;

  String encode() => '$publicKey|${relays.join(',')}';

  /// Parses a contact's address. Relays on this machine are refused unless
  /// [allowLoopback], so a contact cannot point Conest at local services.
  static NostrAddress? tryParse(String value, {bool allowLoopback = false}) {
    final split = value.indexOf('|');
    if (split != 64) return null;
    final key = value.substring(0, 64);
    final keyBytes = hexDecode(key);
    if (key != key.toLowerCase() ||
        keyBytes == null ||
        !Secp256k1.isValidPublicKey(keyBytes)) {
      return null;
    }
    final relays = <Uri>[];
    for (final raw in value.substring(split + 1).split(',')) {
      final relay = parseNostrRelayUrl(raw, allowLoopback: allowLoopback);
      if (relay == null) return null;
      relays.add(relay);
    }
    if (relays.isEmpty || relays.length > maxNostrAddressRelays) return null;
    return NostrAddress(publicKey: key, relays: relays);
  }
}

/// A relay URL Conest will connect to: `wss://`, or with [allowLoopback]
/// also `ws://` on this machine (for a local relay).
Uri? parseNostrRelayUrl(String raw, {bool allowLoopback = true}) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty || trimmed.length > 256 || trimmed.contains(',')) {
    return null;
  }
  final uri = Uri.tryParse(trimmed);
  if (uri == null ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment) {
    return null;
  }
  final loopback =
      uri.host == 'localhost' ||
      uri.host == '::1' ||
      uri.host == '[::1]' ||
      uri.host.startsWith('127.');
  if (loopback && !allowLoopback) return null;
  if (uri.scheme != 'wss' && !(uri.scheme == 'ws' && loopback)) return null;
  return uri;
}

/// Whether [address] is a well-formed Nostr carrier address from a contact.
bool isValidNostrAddress(String address) =>
    NostrAddress.tryParse(address) != null;

/// The Nostr side of the carrier: reads gift wraps addressed to this
/// device's carrier key from its own relays, and publishes frames to the
/// relays a contact listed.
///
/// Each frame travels as one kind-1059 event signed by a throwaway key, so
/// relays see the recipient's key, sizes and timing but not the sender. The
/// content is NIP-44 encrypted to the recipient and holds the sender's
/// carrier key (the hint that picks the contact) and the frame, which the
/// carrier seal authenticates.
class NostrCarrierChannel implements ManagedCarrierChannel {
  NostrCarrierChannel({
    required Uint8List secretKey,
    required List<Uri> relays,
    required this.onFrame,
    int? since,
    this.onCursor,
    this.onStatusChanged,
    NostrSocketConnector? connector,
    DateTime Function()? now,
    this.allowLoopbackRelays = false,
  }) : _secretKey = secretKey,
       _publicKey = hexEncode(Secp256k1.publicKey(secretKey)),
       _relayUrls = List.unmodifiable(relays.take(maxNostrAddressRelays)),
       _connector = connector,
       _now = now ?? DateTime.now {
    _cursor = since ?? _seconds(_now());
  }

  /// Accept contacts' relays on this machine (local test relays only).
  final bool allowLoopbackRelays;
  final Uint8List _secretKey;
  final String _publicKey;
  final List<Uri> _relayUrls;
  final NostrSocketConnector? _connector;
  final DateTime Function() _now;

  /// A frame from the contact whose carrier key is [senderPublicKey].
  final void Function(String senderPublicKey, Uint8List frame) onFrame;

  /// The newest event time seen, to resume reading from after a restart.
  final void Function(int since)? onCursor;
  final void Function()? onStatusChanged;

  final Map<String, NostrRelay> _own = {};
  final Map<String, NostrRelay> _outbound = {};
  final LinkedHashSet<String> _seen = LinkedHashSet();
  static const int _maxSeen = 4096;

  /// Stored events are asked for from this long before the cursor, to
  /// absorb senders' clock skew; duplicates are dropped.
  static const Duration _cursorSlack = Duration(hours: 1);
  static const Duration _outboundIdle = Duration(minutes: 5);
  late int _cursor;
  Timer? _idleTimer;
  bool _started = false;

  String get publicKey => _publicKey;
  List<Uri> get relays => _relayUrls;

  @override
  String? get localAddress =>
      NostrAddress(publicKey: _publicKey, relays: _relayUrls).encode();

  @override
  String get routeLabel => _relayUrls.length == 1
      ? _relayUrls.single.host
      : '${_relayUrls.first.host} +${_relayUrls.length - 1}';

  /// Connection state of each relay this device reads from, its last
  /// problem, and whether it is serving this device's messages.
  Map<Uri, (NostrRelayState, String?, bool)> get relayStates => {
    for (final url in _relayUrls)
      if (_own[url.toString()] case final relay?)
        url: (relay.state, relay.lastError, relay.reading)
      else
        url: (NostrRelayState.disconnected, null, false),
  };

  @override
  void start() {
    if (_started) return;
    _started = true;
    // Frames dropped while stopped come again from the relays' stored
    // events; nothing is skipped as already seen.
    _seen.clear();
    _budgets.clear();
    for (final url in _relayUrls) {
      final relay = _own.putIfAbsent(
        url.toString(),
        () => NostrRelay(
          url: url,
          authKey: () => _secretKey,
          connector: _connector,
          filter: () => {
            'kinds': [NostrKind.giftWrap],
            '#p': [_publicKey],
            'since': _cursor - _cursorSlack.inSeconds,
          },
          onEvent: (event) => _receive(url, event),
          onStateChanged: onStatusChanged,
        ),
      );
      relay.start();
    }
    _idleTimer ??= Timer.periodic(
      const Duration(minutes: 1),
      (_) => _closeIdle(),
    );
  }

  @override
  Future<void> stop() async {
    _started = false;
    _idleTimer?.cancel();
    _idleTimer = null;
    final relays = [..._own.values, ..._outbound.values];
    _own.clear();
    _outbound.clear();
    await Future.wait(relays.map((relay) => relay.stop()));
  }

  @override
  Future<void> sendFrame(String address, Uint8List frame) async {
    if (!_started) throw StateError('The Nostr carrier is stopped.');
    final to = NostrAddress.tryParse(
      address,
      allowLoopback: allowLoopbackRelays,
    );
    if (to == null) throw ArgumentError('Not a Nostr carrier address.');
    final ephemeral = Secp256k1.generateSecretKey();
    final plaintext = Uint8List.fromList([
      _contentVersion,
      ...hexDecode(_publicKey)!,
      ...frame,
    ]);
    final content = Nip44.encrypt(
      plaintext,
      Nip44.conversationKey(ephemeral, hexDecode(to.publicKey)!),
    );
    final createdAt = _seconds(_now());
    final event = NostrEvent.sign(
      secretKey: ephemeral,
      kind: NostrKind.giftWrap,
      tags: [
        ['p', to.publicKey],
        ['expiration', '${createdAt + nostrCarrierExpiry.inSeconds}'],
      ],
      content: content,
      createdAt: createdAt,
    );
    final errors = <Object>[];
    var stored = 0;
    await Future.wait(
      to.relays.map((url) async {
        try {
          await _relayFor(url).publish(event);
          stored++;
        } catch (error) {
          errors.add(error);
        }
      }),
    );
    if (stored == 0) {
      final rateLimited = errors.whereType<NostrRelayException>().any(
        (error) => error.rateLimited,
      );
      throw StateError(
        rateLimited
            ? 'Nostr relays asked to slow down.'
            : 'No Nostr relay stored the message: ${errors.join('; ')}',
      );
    }
  }

  NostrRelay _relayFor(Uri url) {
    // Publishing never reuses a reading connection, even to the same relay:
    // that one may be signed in with the carrier key.
    return _outbound.putIfAbsent(url.toString(), () {
      // Relays that want a sign-in before storing get a one-time key, never
      // the carrier key: a contact's relay must not link this device to the
      // gift wraps it publishes there.
      final throwaway = Secp256k1.generateSecretKey();
      return NostrRelay(
        url: url,
        authKey: () => throwaway,
        connector: _connector,
      )..start();
    });
  }

  void _closeIdle() {
    final cutoff = DateTime.now().subtract(_outboundIdle);
    final idle = _outbound.entries
        .where((entry) => entry.value.lastUsed.isBefore(cutoff))
        .toList(growable: false);
    for (final entry in idle) {
      _outbound.remove(entry.key);
      unawaited(entry.value.stop());
    }
  }

  void _receive(Uri relay, NostrEvent event) {
    if (event.kind != NostrKind.giftWrap ||
        event.tag('p') != _publicKey ||
        event.content.length > _maxContentChars ||
        _seen.contains(event.id)) {
      return;
    }
    // The throwaway signature authenticates nothing (the NIP-44 MAC and
    // the carrier seal do), so it is not checked: each event costs one
    // key agreement, within a per-relay budget, and is seen only once.
    if (!_spend(relay)) return;
    _seen.add(event.id);
    if (_seen.length > _maxSeen) _seen.remove(_seen.first);
    final Uint8List plaintext;
    try {
      plaintext = Nip44.decrypt(
        event.content,
        Nip44.conversationKey(_secretKey, hexDecode(event.pubkey)!),
      );
    } catch (_) {
      return;
    }
    if (plaintext.length <= 33 || plaintext[0] != _contentVersion) return;
    if (event.createdAt > _cursor &&
        event.createdAt <= _seconds(_now()) + 600) {
      _cursor = event.createdAt;
      onCursor?.call(_cursor);
    }
    onFrame(
      hexEncode(Uint8List.sublistView(plaintext, 1, 33)),
      Uint8List.sublistView(plaintext, 33),
    );
  }

  /// Events decrypted per relay per minute; a flood beyond it is dropped
  /// (relays keep the events, so a real burst is read again later).
  static const int _eventsPerMinute = 240;

  /// A frame of the largest size after NIP-44 padding and base64.
  static const int _maxContentChars = 48 * 1024;
  final Map<Uri, (int, int)> _budgets = {};

  bool _spend(Uri relay) {
    final minute = _now().millisecondsSinceEpoch ~/ 60000;
    final (window, used) = _budgets[relay] ?? (minute, 0);
    final count = window == minute ? used : 0;
    if (count >= _eventsPerMinute) return false;
    _budgets[relay] = (minute, count + 1);
    return true;
  }

  static int _seconds(DateTime time) => time.millisecondsSinceEpoch ~/ 1000;
}

/// A Nostr carrier adapter around [channel]'s frames.
CarrierTransportAdapter createNostrCarrierAdapter({
  required CarrierSealer sealer,
  DateTime Function()? now,
  bool allowLoopbackRelays = false,
}) => CarrierTransportAdapter(
  kind: TransportKind.nostr,
  sealer: sealer,
  framing: CarrierFraming.nostr,
  frameSpacing: const Duration(milliseconds: 250),
  isValidAddress: allowLoopbackRelays
      ? (address) => NostrAddress.tryParse(address, allowLoopback: true) != null
      : isValidNostrAddress,
  now: now,
);

/// The saved Nostr carrier: its key, relays and read position.
class NostrCarrierConfig {
  const NostrCarrierConfig({
    required this.secretKeyHex,
    required this.relays,
    this.since,
  });

  final String secretKeyHex;
  final List<String> relays;
  final int? since;

  NostrCarrierConfig copyWith({List<String>? relays, int? since}) =>
      NostrCarrierConfig(
        secretKeyHex: secretKeyHex,
        relays: relays ?? this.relays,
        since: since ?? this.since,
      );

  Map<String, Object?> toJson() => {
    'secretKey': secretKeyHex,
    'relays': relays,
    if (since != null) 'since': since,
  };

  static NostrCarrierConfig? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final key = json['secretKey'];
    final relays = json['relays'];
    final since = json['since'];
    if (key is! String ||
        hexDecode(key)?.length != 32 ||
        relays is! List ||
        (since != null && since is! int)) {
      return null;
    }
    return NostrCarrierConfig(
      secretKeyHex: key,
      relays: [
        for (final relay in relays)
          if (relay is String && parseNostrRelayUrl(relay) != null) relay,
      ],
      since: since as int?,
    );
  }

  @override
  String toString() => jsonEncode({'relays': relays, 'since': since});
}
