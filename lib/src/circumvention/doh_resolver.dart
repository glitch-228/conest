import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// Sends one DNS-over-HTTPS query (RFC 8484, `application/dns-message`)
/// to [endpoint] and returns the answer's bytes.
typedef DohTransport =
    Future<List<int>> Function(Uri endpoint, List<int> query, Duration timeout);

/// Looks names up with the system resolver.
typedef SystemLookup = Future<List<InternetAddress>> Function(String host);

/// Resolvers reached by address (no lookup needed to find them), each
/// with a certificate for that address.
final List<Uri> defaultDohEndpoints = [
  Uri.parse('https://1.1.1.1/dns-query'),
  Uri.parse('https://8.8.8.8/dns-query'),
  Uri.parse('https://9.9.9.9/dns-query'),
];

/// Names looked up over DNS over HTTPS, so a censor's resolver cannot
/// answer them wrongly (or at all): a few well-known resolvers asked in
/// parallel, the first good answer taken; the system resolver when none
/// answers. A system answer that looks poisoned (an address no public
/// name has) is not trusted while DoH is on.
class DohResolver {
  DohResolver({
    List<Uri>? endpoints,
    DohTransport? transport,
    SystemLookup? systemLookup,
    this.timeout = const Duration(seconds: 4),
    this.cacheFor = const Duration(minutes: 10),
  }) : endpoints = endpoints ?? defaultDohEndpoints,
       _transport = transport ?? _httpTransport,
       _systemLookup = systemLookup ?? InternetAddress.lookup;

  final List<Uri> endpoints;
  final DohTransport _transport;
  final SystemLookup _systemLookup;
  final Duration timeout;
  final Duration cacheFor;
  final Map<String, ({List<InternetAddress> addresses, DateTime until})>
  _cache = {};
  final Random _random = Random.secure();

  static const int _maxCache = 256;

  /// The addresses of [host] (an address itself is returned as it is).
  Future<List<InternetAddress>> resolve(String host) async {
    final literal = InternetAddress.tryParse(host);
    if (literal != null) return [literal];
    final name = host.toLowerCase();
    final cached = _cache[name];
    if (cached != null && DateTime.now().isBefore(cached.until)) {
      return cached.addresses;
    }
    var addresses = await _overHttps(name);
    if (addresses.isEmpty) {
      final system = await _systemLookup(name);
      addresses = system.where((address) => !looksPoisoned(address)).toList();
      if (addresses.isEmpty) {
        throw SocketException('No usable address for $host.');
      }
    }
    if (_cache.length >= _maxCache) _cache.remove(_cache.keys.first);
    _cache[name] = (addresses: addresses, until: DateTime.now().add(cacheFor));
    return addresses;
  }

  /// Asks every resolver at once (A and AAAA); the first non-empty,
  /// unpoisoned answer wins. Empty when none gives one in time.
  Future<List<InternetAddress>> _overHttps(String name) async {
    final done = Completer<List<InternetAddress>>();
    var pending = endpoints.length * 2;
    void finished(List<InternetAddress> answer) {
      pending--;
      final usable = answer.where((address) => !looksPoisoned(address));
      if (!done.isCompleted && usable.isNotEmpty) {
        done.complete(usable.toList());
      } else if (pending == 0 && !done.isCompleted) {
        done.complete(const []);
      }
    }

    for (final endpoint in endpoints) {
      for (final type in const [1, 28]) {
        final id = _random.nextInt(0x10000);
        unawaited(
          _transport(
            endpoint,
            encodeDnsQuery(name, type, id: id),
            timeout,
          ).then(
            (bytes) => finished(decodeDnsAnswer(bytes, id: id, type: type)),
            onError: (Object _) => finished(const []),
          ),
        );
      }
    }
    if (endpoints.isEmpty) return const [];
    return done.future.timeout(timeout, onTimeout: () => const []);
  }

  static Future<List<int>> _httpTransport(
    Uri endpoint,
    List<int> query,
    Duration timeout,
  ) async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final request = await client.postUrl(endpoint).timeout(timeout);
      request.headers
        ..set(HttpHeaders.contentTypeHeader, 'application/dns-message')
        ..set(HttpHeaders.acceptHeader, 'application/dns-message');
      request.add(query);
      final response = await request.close().timeout(timeout);
      if (response.statusCode != 200) {
        throw HttpException('DoH answered ${response.statusCode}');
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(timeout)) {
        bytes.add(chunk);
        if (bytes.length > 4096) throw const FormatException('DoH too long');
      }
      return bytes.takeBytes();
    } finally {
      client.close(force: true);
    }
  }
}

/// Whether [address] is not one a public name has: what DNS censors answer
/// for names they block (unspecified, loopback, private, link-local, and
/// known sinkholes).
bool looksPoisoned(InternetAddress address) {
  final bytes = address.rawAddress;
  if (bytes.every((byte) => byte == 0)) return true;
  if (address.isLoopback || address.isLinkLocal || address.isMulticast) {
    return true;
  }
  if (address.type == InternetAddressType.IPv4) {
    if (bytes[0] == 10 ||
        bytes[0] == 127 ||
        (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] < 32) ||
        (bytes[0] == 192 && bytes[1] == 168) ||
        (bytes[0] == 100 && bytes[1] >= 64 && bytes[1] < 128)) {
      return true;
    }
    return false;
  }
  // IPv6 unique local.
  return (bytes[0] & 0xfe) == 0xfc;
}

/// A DNS query for [name] (type 1: A, 28: AAAA), recursion desired.
Uint8List encodeDnsQuery(String name, int type, {required int id}) {
  final out = BytesBuilder()
    ..add([id >> 8, id & 0xff, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0]);
  for (final label in name.split('.')) {
    if (label.isEmpty) continue;
    final bytes = label.codeUnits;
    if (bytes.length > 63 || bytes.any((unit) => unit > 127)) {
      throw ArgumentError('Not a DNS name: $name');
    }
    out
      ..addByte(bytes.length)
      ..add(bytes);
  }
  out.add([0, type >> 8, type & 0xff, 0, 1]);
  return out.takeBytes();
}

/// The addresses of [type] in a DNS answer to query [id] (empty when it is
/// not one, or is malformed).
List<InternetAddress> decodeDnsAnswer(
  List<int> bytes, {
  required int id,
  required int type,
}) {
  if (bytes.length < 12 || bytes.length > 4096) return const [];
  if (((bytes[0] << 8) | bytes[1]) != id) return const [];
  if (bytes[2] & 0x80 == 0) return const []; // Not a response.
  if (bytes[3] & 0x0f != 0) return const []; // An error code.
  final questions = (bytes[4] << 8) | bytes[5];
  final answers = (bytes[6] << 8) | bytes[7];
  var offset = 12;
  int? skipName(int at) {
    var position = at;
    for (var steps = 0; steps < 128; steps++) {
      if (position >= bytes.length) return null;
      final length = bytes[position];
      if (length == 0) return position + 1;
      if (length & 0xc0 == 0xc0) return position + 2;
      position += length + 1;
    }
    return null;
  }

  for (var index = 0; index < questions; index++) {
    final end = skipName(offset);
    if (end == null) return const [];
    offset = end + 4;
  }
  final found = <InternetAddress>[];
  for (var index = 0; index < answers && index < 64; index++) {
    final end = skipName(offset);
    if (end == null || end + 10 > bytes.length) return found;
    final recordType = (bytes[end] << 8) | bytes[end + 1];
    final length = (bytes[end + 8] << 8) | bytes[end + 9];
    final data = end + 10;
    if (data + length > bytes.length) return found;
    if (recordType == type &&
        ((type == 1 && length == 4) || (type == 28 && length == 16))) {
      found.add(
        InternetAddress.fromRawAddress(
          Uint8List.fromList(bytes.sublist(data, data + length)),
        ),
      );
    }
    offset = data + length;
  }
  return found;
}
