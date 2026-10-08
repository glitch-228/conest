import 'dart:convert';
import 'dart:typed_data';

import 'secp256k1.dart';

/// NIP-19: bech32 names for Nostr keys (`npub`, `nsec`) and profiles with
/// relays (`nprofile`).
abstract final class Nip19 {
  static String npub(String publicKeyHex) =>
      _Bech32.encode('npub', hexDecode(publicKeyHex)!);

  static String nsec(Uint8List secretKey) => _Bech32.encode('nsec', secretKey);

  /// A profile: the key and relays where to find it.
  static String nprofile(String publicKeyHex, List<Uri> relays) {
    final key = hexDecode(publicKeyHex)!;
    return _Bech32.encode('nprofile', [
      0, key.length, ...key, //
      for (final relay in relays)
        if (utf8.encode(relay.toString()) case final bytes
            when bytes.length < 256) ...[
          1,
          bytes.length,
          ...bytes,
        ],
    ]);
  }

  /// The public key (hex) and relays of an `npub`, `nprofile` or a 64-hex
  /// key, with or without "nostr:"; null otherwise.
  static ({String publicKey, List<Uri> relays})? decodeProfile(String input) {
    var text = input.trim();
    if (text.toLowerCase().startsWith('nostr:')) text = text.substring(6);
    if (RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(text)) {
      return (publicKey: text.toLowerCase(), relays: const []);
    }
    final decoded = _Bech32.decode(text);
    if (decoded == null) return null;
    final (prefix, data) = decoded;
    if (prefix == 'npub') {
      if (data.length != 32) return null;
      return (publicKey: hexEncode(data), relays: const []);
    }
    if (prefix != 'nprofile') return null;
    String? key;
    final relays = <Uri>[];
    var offset = 0;
    while (offset + 2 <= data.length) {
      final type = data[offset];
      final length = data[offset + 1];
      offset += 2;
      if (offset + length > data.length) return null;
      final value = data.sublist(offset, offset + length);
      offset += length;
      switch (type) {
        case 0:
          if (length != 32) return null;
          key = hexEncode(value);
        case 1:
          final uri = Uri.tryParse(utf8.decode(value, allowMalformed: true));
          if (uri != null && (uri.scheme == 'wss' || uri.scheme == 'ws')) {
            relays.add(uri);
          }
      }
    }
    if (key == null) return null;
    return (publicKey: key, relays: relays);
  }

  /// The secret key of an `nsec`, or of 64 hex characters; null otherwise.
  static Uint8List? decodeSecret(String input) {
    final text = input.trim();
    if (RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(text)) return hexDecode(text);
    final decoded = _Bech32.decode(text);
    if (decoded == null || decoded.$1 != 'nsec' || decoded.$2.length != 32) {
      return null;
    }
    return decoded.$2;
  }
}

/// Bech32 (BIP-173) with the long strings NIP-19 allows.
abstract final class _Bech32 {
  static const String _charset = 'qpzry9x8gf2tvdw0s3jn54khce6mua7l';
  static const List<int> _generator = [
    0x3b6a57b2,
    0x26508e6d,
    0x1ea119fa,
    0x3d4233dd,
    0x2a1462b3,
  ];

  static int _polymod(List<int> values) {
    var check = 1;
    for (final value in values) {
      final top = check >> 25;
      check = (check & 0x1ffffff) << 5 ^ value;
      for (var bit = 0; bit < 5; bit++) {
        if ((top >> bit) & 1 == 1) check ^= _generator[bit];
      }
    }
    return check;
  }

  static List<int> _expand(String prefix) => [
    for (final unit in prefix.codeUnits) unit >> 5,
    0,
    for (final unit in prefix.codeUnits) unit & 31,
  ];

  static List<int>? _convert(List<int> data, int from, int to, bool pad) {
    var accumulator = 0;
    var bits = 0;
    final out = <int>[];
    final maxValue = (1 << to) - 1;
    for (final value in data) {
      if (value < 0 || value >> from != 0) return null;
      accumulator = accumulator << from | value;
      bits += from;
      while (bits >= to) {
        bits -= to;
        out.add(accumulator >> bits & maxValue);
      }
    }
    if (pad) {
      if (bits > 0) out.add(accumulator << (to - bits) & maxValue);
    } else if (bits >= from || (accumulator << (to - bits) & maxValue) != 0) {
      return null;
    }
    return out;
  }

  static String encode(String prefix, List<int> bytes) {
    final data = _convert(bytes, 8, 5, true)!;
    final polymod =
        _polymod([..._expand(prefix), ...data, 0, 0, 0, 0, 0, 0]) ^ 1;
    final checksum = [for (var i = 0; i < 6; i++) polymod >> 5 * (5 - i) & 31];
    return '${prefix}1${[...data, ...checksum].map((v) => _charset[v]).join()}';
  }

  static (String, Uint8List)? decode(String input) {
    if (input.length > 5000 ||
        (input.toLowerCase() != input && input.toUpperCase() != input)) {
      return null;
    }
    final text = input.toLowerCase();
    final separator = text.lastIndexOf('1');
    if (separator < 1 || separator + 7 > text.length) return null;
    final prefix = text.substring(0, separator);
    final values = <int>[];
    for (final char in text.substring(separator + 1).split('')) {
      final value = _charset.indexOf(char);
      if (value < 0) return null;
      values.add(value);
    }
    if (_polymod([..._expand(prefix), ...values]) != 1) return null;
    final bytes = _convert(values.sublist(0, values.length - 6), 5, 8, false);
    if (bytes == null) return null;
    return (prefix, Uint8List.fromList(bytes));
  }
}
