import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../nostr/event.dart';

/// bitchat's packet type for a Nostr event carried over the mesh.
const int bitchatNostrCarrierType = 0x28;

/// bitchat's announce capability bit for "shares its internet" (gateway).
const int bitchatGatewayCapability = 1 << 2;

/// bitchat's geohash chat: ephemeral events with a `g` tag.
const int bitchatGeohashEventKind = 20000;

/// Which way a carried event goes.
enum BitchatCarrierDirection {
  /// A phone without internet asks a gateway to publish its event
  /// (addressed to the gateway).
  toGateway(0x01),

  /// A gateway passes on an event from the relays (to everyone nearby).
  fromGateway(0x02);

  const BitchatCarrierDirection(this.code);
  final int code;
}

/// A complete, signed Nostr event carried over the mesh (bitchat's
/// NostrCarrierPacket): TLVs with 2-byte lengths for the direction, the
/// geohash and the event JSON.
class BitchatNostrCarrier {
  const BitchatNostrCarrier({
    required this.direction,
    required this.geohash,
    required this.eventJson,
  });

  static const int maxEventJsonBytes = 16 * 1024;
  static const int maxGeohashLength = 12;

  final BitchatCarrierDirection direction;
  final String geohash;
  final Uint8List eventJson;

  /// The carried event; its signature still has to be checked.
  NostrEvent? event() {
    try {
      return NostrEvent.fromJson(jsonDecode(utf8.decode(eventJson)));
    } on FormatException {
      return null;
    }
  }

  Uint8List encode() {
    final out = BytesBuilder(copy: false);
    void tlv(int type, List<int> value) {
      out
        ..addByte(type)
        ..addByte(value.length >> 8 & 0xff)
        ..addByte(value.length & 0xff)
        ..add(value);
    }

    tlv(0x01, [direction.code]);
    tlv(0x02, utf8.encode(geohash));
    tlv(0x03, eventJson);
    return out.takeBytes();
  }

  /// Null when malformed, of a direction Conest does not handle, or too
  /// large. Unknown TLVs are skipped, as bitchat does.
  static BitchatNostrCarrier? decode(Uint8List data) {
    BitchatCarrierDirection? direction;
    String? geohash;
    Uint8List? eventJson;
    var offset = 0;
    while (offset + 3 <= data.length) {
      final type = data[offset];
      final length = data[offset + 1] << 8 | data[offset + 2];
      offset += 3;
      if (offset + length > data.length) return null;
      final value = Uint8List.sublistView(data, offset, offset + length);
      offset += length;
      switch (type) {
        case 0x01:
          if (value.length != 1) return null;
          direction = BitchatCarrierDirection.values
              .where((candidate) => candidate.code == value[0])
              .firstOrNull;
          if (direction == null) return null;
        case 0x02:
          try {
            geohash = utf8.decode(value);
          } on FormatException {
            return null;
          }
        case 0x03:
          eventJson = Uint8List.fromList(value);
      }
    }
    if (offset != data.length ||
        direction == null ||
        geohash == null ||
        eventJson == null ||
        eventJson.isEmpty ||
        eventJson.length > maxEventJsonBytes ||
        !isValidGeohash(geohash)) {
      return null;
    }
    return BitchatNostrCarrier(
      direction: direction,
      geohash: geohash,
      eventJson: eventJson,
    );
  }
}

const String _geohashAlphabet = '0123456789bcdefghjkmnpqrstuvwxyz';

bool isValidGeohash(String geohash) =>
    geohash.isNotEmpty &&
    geohash.length <= BitchatNostrCarrier.maxGeohashLength &&
    geohash.split('').every(_geohashAlphabet.contains);

/// The centre of [geohash]'s cell.
(double, double) geohashCenter(String geohash) {
  var latMin = -90.0, latMax = 90.0, lonMin = -180.0, lonMax = 180.0;
  var even = true;
  for (final char in geohash.split('')) {
    final bits = _geohashAlphabet.indexOf(char);
    for (var bit = 4; bit >= 0; bit--) {
      final on = bits >> bit & 1 == 1;
      if (even) {
        final mid = (lonMin + lonMax) / 2;
        on ? lonMin = mid : lonMax = mid;
      } else {
        final mid = (latMin + latMax) / 2;
        on ? latMin = mid : latMax = mid;
      }
      even = !even;
    }
  }
  return ((latMin + latMax) / 2, (lonMin + lonMax) / 2);
}

/// A relay bitchat lists with where it is.
class BitchatGeoRelay {
  const BitchatGeoRelay(this.host, this.lat, this.lon);
  final String host;
  final double lat;
  final double lon;
}

/// bitchat's list of relays by location: a geohash channel lives on the
/// relays nearest its cell, so publishers and subscribers agree on them.
class BitchatGeoRelays {
  BitchatGeoRelays(this.relays);

  final List<BitchatGeoRelay> relays;

  /// Where bitchat publishes the list.
  static final Uri source = Uri.parse(
    'https://raw.githubusercontent.com/permissionlesstech/bitchat/refs/'
    'heads/main/relays/online_relays_gps.csv',
  );

  /// Parses bitchat's CSV ("Relay URL,Latitude,Longitude") as bitchat
  /// checks it: one bad or conflicting row rejects the whole list; at least
  /// [minimumEntries] relays; and, given a [baseline], at least half of it
  /// still there. Null otherwise.
  static BitchatGeoRelays? parse(
    String csv, {
    int minimumEntries = 50,
    BitchatGeoRelays? baseline,
  }) {
    if (csv.isEmpty || csv.length > 512 * 1024 || csv.startsWith('\ufeff')) {
      return null;
    }
    final lines = const LineSplitter()
        .convert(csv)
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
    if (lines.isEmpty || lines.length - 1 > 5000) return null;
    final header = lines.first
        .split(',')
        .map((part) => part.trim().toLowerCase())
        .join(',');
    if (header != 'relay url,latitude,longitude' &&
        header != 'relay url,lat,lon') {
      return null;
    }
    final byHost = <String, BitchatGeoRelay>{};
    for (final line in lines.skip(1)) {
      final parts = line.split(',').map((part) => part.trim()).toList();
      if (parts.length != 3) return null;
      final host = _host(parts[0]);
      final lat = double.tryParse(parts[1]);
      final lon = double.tryParse(parts[2]);
      if (host == null ||
          lat == null ||
          lon == null ||
          !lat.isFinite ||
          !lon.isFinite ||
          lat.abs() > 90 ||
          lon.abs() > 180) {
        return null;
      }
      final existing = byHost[host];
      // One relay cannot be in two places: no row order decides.
      if (existing != null && (existing.lat != lat || existing.lon != lon)) {
        return null;
      }
      byHost[host] = BitchatGeoRelay(host, lat, lon);
    }
    if (byHost.length < minimumEntries) return null;
    if (baseline != null) {
      final kept = baseline.relays.where((relay) {
        final entry = byHost[relay.host];
        return entry != null &&
            entry.lat == relay.lat &&
            entry.lon == relay.lon;
      }).length;
      if (kept < (baseline.relays.length / 2).ceil()) return null;
    }
    return BitchatGeoRelays(byHost.values.toList());
  }

  /// A relay's host (and port, unless 443), as bitchat accepts it: a
  /// public DNS name only (no IP address, no local or internal name).
  static String? _host(String raw) {
    if (raw.isEmpty ||
        raw.codeUnits.any((unit) => unit < 0x21 || unit > 0x7e)) {
      return null;
    }
    final candidate = raw.contains('://') ? raw : 'wss://$raw';
    final uri = Uri.tryParse(candidate);
    if (uri == null ||
        (uri.scheme != 'wss' && uri.scheme != 'https') ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/')) {
      return null;
    }
    final host = uri.host.toLowerCase();
    if (host.isEmpty ||
        host.length > 253 ||
        host.endsWith('.') ||
        host == 'localhost' ||
        host.endsWith('.localhost') ||
        host.endsWith('.local') ||
        host.endsWith('.internal')) {
      return null;
    }
    final labels = host.split('.');
    final label = RegExp(r'^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$');
    if (labels.length < 2 ||
        // An address in any of the forms resolvers take (such as
        // 0x7f.1), as the URL standard's "ends in a number" rule finds it.
        RegExp(r'^(0x[0-9a-f]*|[0-9]+)$').hasMatch(labels.last) ||
        !labels.every(label.hasMatch)) {
      return null;
    }
    if (uri.hasPort && uri.port != 443) {
      if (uri.port < 1 || uri.port > 65535) return null;
      return '$host:${uri.port}';
    }
    return host;
  }

  /// The [count] relays nearest [geohash]'s centre (ties by host, as
  /// bitchat breaks them), as wss URLs.
  List<Uri> closest(String geohash, {int count = 5}) {
    final (lat, lon) = geohashCenter(geohash);
    final sorted =
        [
          for (final relay in relays)
            (relay, _haversineKm(lat, lon, relay.lat, relay.lon)),
        ]..sort((a, b) {
          final byDistance = a.$2.compareTo(b.$2);
          return byDistance != 0 ? byDistance : a.$1.host.compareTo(b.$1.host);
        });
    return [
      for (final (relay, _) in sorted.take(count))
        Uri.parse('wss://${relay.host}'),
    ];
  }

  static double _haversineKm(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    const radius = 6371.0;
    double rad(double degrees) => degrees * pi / 180;
    final dLat = rad(lat2 - lat1);
    final dLon = rad(lon2 - lon1);
    final a =
        sin(dLat / 2) * sin(dLat / 2) +
        cos(rad(lat1)) * cos(rad(lat2)) * sin(dLon / 2) * sin(dLon / 2);
    return 2 * radius * asin(sqrt(min(1, a)));
  }
}

/// Bounded set of ids, oldest dropped first.
class _RecentIds {
  _RecentIds(this.capacity);
  final int capacity;
  final LinkedHashSet<String> _ids = LinkedHashSet();

  bool contains(String id) => _ids.contains(id);

  void remove(String id) => _ids.remove(id);

  /// False when already there.
  bool add(String id) {
    if (!_ids.add(id)) return false;
    if (_ids.length > capacity) _ids.remove(_ids.first);
    return true;
  }
}

/// Sharing this phone's internet with bitchat users nearby, for bitchat's
/// geohash chat only (public, signed by its authors): events from phones
/// without internet go to the relays (uplink), and events from the relays
/// for the cells those phones use come back over Bluetooth (downlink).
///
/// Follows bitchat's GatewayService: every event is checked (kind, cell
/// tag, age, Schnorr signature) before it is published or passed on;
/// events learned from the mesh are never published or passed on again;
/// each event goes up and comes down at most once; deposits are limited
/// per phone and Bluetooth airtime per minute.
class BitchatGateway {
  BitchatGateway({
    required this.publish,
    required this.broadcast,
    required this.relaysConnected,
    this.onCellsChanged,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// A phone nearby used a cell not followed before.
  final void Function()? onCellsChanged;

  /// Publishes [event] to the relays of [geohash]'s cell; false when no
  /// relay took it (it then waits for the next [flushQueued]).
  final Future<bool> Function(NostrEvent event, String geohash) publish;

  /// Sends a `fromGateway` carrier payload to everyone nearby.
  final Future<void> Function(Uint8List payload) broadcast;

  /// Whether any relay connection works.
  final bool Function() relaysConnected;

  final DateTime Function() _now;

  static const int maxQueued = 20;
  static const int maxQueuedPerDepositor = 5;
  static const int depositsPerMinutePerDepositor = 10;
  static const int depositsPerMinute = 30;
  static const int newCellsPerHour = 6;
  static const int newCellsPerHourPerDepositor = 2;

  /// A cell used this recently is not pushed out for a new one.
  static const Duration cellBusyFor = Duration(minutes: 10);
  static const int downlinksPerMinute = 30;
  static const int maxPendingDownlinks = 30;
  static const Duration maxEventAge = Duration(minutes: 15);

  /// How long a cell a nearby phone used stays subscribed.
  static const Duration cellKeptFor = Duration(hours: 1);
  static const int maxCells = 4;

  final _RecentIds _fromMesh = _RecentIds(512);
  final _RecentIds _published = _RecentIds(512);
  final _RecentIds _rebroadcast = _RecentIds(512);
  final List<(String, String, NostrEvent)> _queued = [];
  final Map<String, List<DateTime>> _deposits = {};
  final List<DateTime> _downlinkTimes = [];
  final List<(NostrEvent, String)> _pending = [];
  final Map<String, DateTime> _cells = {};

  /// Cells nearby phones used in the last hour: what to subscribe to.
  Set<String> get cells {
    final cutoff = _now().subtract(cellKeptFor);
    _cells.removeWhere((_, at) => at.isBefore(cutoff));
    return _cells.keys.toSet();
  }

  int get queued => _queued.length;

  /// A carrier packet; [directedToUs] for one addressed to this phone.
  Future<void> handleCarrier(
    Uint8List payload, {
    required String from,
    required bool directedToUs,
  }) async {
    final carrier = BitchatNostrCarrier.decode(payload);
    if (carrier == null) return;
    switch (carrier.direction) {
      case BitchatCarrierDirection.toGateway:
        if (directedToUs) await _uplink(carrier, from);
      case BitchatCarrierDirection.fromGateway:
        // Another gateway's: remembered so it is never sent up or down
        // again from here. Its id must match its content (one hash); the
        // signature is not checked here, since anyone may pass on a real
        // event they overheard anyway.
        if (!directedToUs) {
          final event = _structurallyValid(carrier);
          if (event != null && _idMatches(event)) _fromMesh.add(event.id);
        }
    }
  }

  Future<void> _uplink(BitchatNostrCarrier carrier, String depositor) async {
    final event = _structurallyValid(carrier);
    if (event == null ||
        _fromMesh.contains(event.id) ||
        _published.contains(event.id) ||
        _queued.any((item) => item.$3.id == event.id)) {
      return;
    }
    // The rate tokens before the costly signature check.
    if (!_allowDeposit(depositor)) return;
    if (!event.isValid) return;
    // Only for cells this gateway carries: deposits for cells all over the
    // map cannot make it contact every relay listed.
    if (!_noteCell(carrier.geohash, depositor)) return;
    if (!relaysConnected() || !await _publish(event, carrier.geohash)) {
      _enqueue(depositor, carrier.geohash, event);
    }
  }

  void _enqueue(String depositor, String geohash, NostrEvent event) {
    if (_queued.any((item) => item.$3.id == event.id)) return;
    final fromDepositor = _queued.where((item) => item.$1 == depositor).length;
    if (fromDepositor >= maxQueuedPerDepositor) return;
    if (_queued.length >= maxQueued) _queued.removeAt(0);
    _queued.add((depositor, geohash, event));
  }

  /// Publishes what waited for the relays.
  Future<void> flushQueued() async {
    if (!relaysConnected() || _queued.isEmpty) return;
    final items = List.of(_queued);
    _queued.clear();
    for (final (depositor, geohash, event) in items) {
      if (_published.contains(event.id) || !_fresh(event)) continue;
      if (!await _publish(event, geohash)) _enqueue(depositor, geohash, event);
    }
  }

  Future<bool> _publish(NostrEvent event, String geohash) async {
    _published.add(event.id);
    if (await publish(event, geohash)) return true;
    _published.remove(event.id);
    return false;
  }

  /// Follows [geohash] for downlinks: a few new cells an hour at most, so
  /// made-up deposits cannot make this phone subscribe all over the map.
  /// Whether [geohash] is carried: a cell already followed, or a new one
  /// within the hour's allowance (overall and per phone). A cell in use in
  /// the last few minutes is never pushed out for a new one.
  bool _noteCell(String geohash, String depositor) {
    final now = _now();
    if (_cells.containsKey(geohash)) {
      _cells[geohash] = now;
      return true;
    }
    final hourAgo = now.subtract(const Duration(hours: 1));
    _newCellTimes.removeWhere(
      (entry) => entry.$1.isBefore(hourAgo) || entry.$1.isAfter(now),
    );
    if (_newCellTimes.length >= newCellsPerHour ||
        _newCellTimes.where((entry) => entry.$2 == depositor).length >=
            newCellsPerHourPerDepositor) {
      return false;
    }
    if (_cells.length >= maxCells) {
      final oldest = _cells.entries.reduce(
        (a, b) => a.value.isBefore(b.value) ? a : b,
      );
      if (now.difference(oldest.value) < cellBusyFor) return false;
      _cells.remove(oldest.key);
    }
    _newCellTimes.add((now, depositor));
    _cells[geohash] = now;
    onCellsChanged?.call();
    return true;
  }

  final List<(DateTime, String)> _newCellTimes = [];
  final List<DateTime> _allDeposits = [];

  bool _allowDeposit(String depositor) {
    final cutoff = _now().subtract(const Duration(minutes: 1));
    _allDeposits.removeWhere((at) => at.isBefore(cutoff));
    if (_allDeposits.length >= depositsPerMinute) return false;
    final times = (_deposits[depositor] ?? [])
      ..removeWhere((at) => at.isBefore(cutoff));
    if (times.length >= depositsPerMinutePerDepositor) {
      _deposits[depositor] = times;
      return false;
    }
    _deposits[depositor] = times..add(_now());
    _allDeposits.add(_now());
    if (_deposits.length > 512) {
      _deposits.removeWhere(
        (_, list) => list.every((at) => at.isBefore(cutoff)),
      );
    }
    return true;
  }

  /// An event from the relays for [geohash]: passed on to phones nearby
  /// once, within the airtime budget.
  Future<void> relayEvent(NostrEvent event, String geohash) async {
    if (event.kind != bitchatGeohashEventKind ||
        !_fresh(event) ||
        !_hasCell(event, geohash) ||
        _fromMesh.contains(event.id) ||
        _published.contains(event.id) ||
        _rebroadcast.contains(event.id) ||
        _pending.any((item) => item.$1.id == event.id)) {
      return;
    }
    _pending.add((event, geohash));
    if (_pending.length > maxPendingDownlinks) _pending.removeAt(0);
    await drainDownlinks();
  }

  /// Sends what waits, as far as the airtime budget allows; call again
  /// later for the rest.
  Future<void> drainDownlinks() async {
    // One drain at a time, so two arriving together share one budget.
    if (_draining) return;
    _draining = true;
    try {
      await _drain();
    } finally {
      _draining = false;
    }
  }

  bool _draining = false;

  Future<void> _drain() async {
    final cutoff = _now().subtract(const Duration(minutes: 1));
    _downlinkTimes.removeWhere((at) => at.isBefore(cutoff));
    while (_pending.isNotEmpty && _downlinkTimes.length < downlinksPerMinute) {
      final (event, geohash) = _pending.removeAt(0);
      if (!_fresh(event) ||
          _rebroadcast.contains(event.id) ||
          _fromMesh.contains(event.id)) {
        continue;
      }
      final json = utf8.encode(jsonEncode(event.toJson()));
      if (json.length > BitchatNostrCarrier.maxEventJsonBytes) continue;
      // Checked only now, at most the budget's worth a minute.
      if (!event.isValid) continue;
      // Counted before sending, so nothing slips past while it goes out.
      _rebroadcast.add(event.id);
      _downlinkTimes.add(_now());
      try {
        await broadcast(
          BitchatNostrCarrier(
            direction: BitchatCarrierDirection.fromGateway,
            geohash: geohash,
            eventJson: Uint8List.fromList(json),
          ).encode(),
        );
      } catch (_) {
        // The mesh is down for now; the rest still goes when it can.
      }
    }
    // Over budget with more waiting: send it once the minute frees up, so a
    // channel gone quiet does not strand it.
    if (_pending.isNotEmpty && _drainTimer == null && !_closed) {
      final oldest = _downlinkTimes.isEmpty
          ? _now()
          : _downlinkTimes.reduce((a, b) => a.isBefore(b) ? a : b);
      final wait =
          const Duration(minutes: 1, seconds: 1) - _now().difference(oldest);
      _drainTimer = Timer(wait.isNegative ? Duration.zero : wait, () {
        _drainTimer = null;
        unawaited(drainDownlinks().catchError((Object _) {}));
      });
    }
  }

  Timer? _drainTimer;
  bool _closed = false;

  /// Stops the drain timer; the gateway is not used again.
  void close() {
    _closed = true;
    _drainTimer?.cancel();
    _drainTimer = null;
    _pending.clear();
    _queued.clear();
  }

  int get pendingDownlinks => _pending.length;

  NostrEvent? _structurallyValid(BitchatNostrCarrier carrier) {
    final event = carrier.event();
    if (event == null ||
        event.kind != bitchatGeohashEventKind ||
        !_hasCell(event, carrier.geohash) ||
        !_fresh(event)) {
      return null;
    }
    return event;
  }

  static bool _idMatches(NostrEvent event) =>
      NostrEvent.eventId(
        pubkey: event.pubkey,
        createdAt: event.createdAt,
        kind: event.kind,
        tags: event.tags,
        content: event.content,
      ) ==
      event.id;

  static bool _hasCell(NostrEvent event, String geohash) => event.tags.any(
    (tag) => tag.length >= 2 && tag[0] == 'g' && tag[1] == geohash,
  );

  bool _fresh(NostrEvent event) =>
      (_now().millisecondsSinceEpoch ~/ 1000 - event.createdAt).abs() <=
      maxEventAge.inSeconds;
}
