import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

/// What a TLS ClientHello shows a network (M38 P0): the parts that make a
/// client recognisable, as JA3 and JA4 fingerprints are built from them.
/// Parsed from the first TLS record a client sends; used to capture what
/// the app's own TLS library puts on the wire, so a change of Dart SDK that
/// changes it is noticed (`test/dart_client_hello_test.dart`).
class ClientHelloInfo {
  const ClientHelloInfo({
    required this.legacyVersion,
    required this.cipherSuites,
    required this.extensions,
    required this.serverName,
    required this.supportedGroups,
    required this.pointFormats,
    required this.signatureAlgorithms,
    required this.alpn,
    required this.supportedVersions,
    required this.keyShareGroups,
  });

  /// The version in the hello's header (0x0303 for TLS 1.2 and 1.3).
  final int legacyVersion;
  final List<int> cipherSuites;

  /// Extension types, in the order sent.
  final List<int> extensions;
  final String? serverName;
  final List<int> supportedGroups;
  final List<int> pointFormats;
  final List<int> signatureAlgorithms;
  final List<String> alpn;
  final List<int> supportedVersions;
  final List<int> keyShareGroups;

  /// Whether [value] is a GREASE value (RFC 8701): browsers add these at
  /// random, and fingerprints leave them out.
  static bool isGrease(int value) =>
      (value & 0x0f0f) == 0x0a0a && ((value >> 8) == (value & 0xff));
}

class ClientHelloFormatException implements Exception {
  const ClientHelloFormatException(this.message);
  final String message;
  @override
  String toString() => 'Not a ClientHello: $message';
}

/// Parses the ClientHello in the TLS record [bytes] (a handshake record,
/// type 0x16, holding a whole ClientHello).
ClientHelloInfo parseClientHello(List<int> bytes) {
  final data = Uint8List.fromList(bytes);
  var offset = 0;
  int need(int count) {
    if (offset + count > data.length) {
      throw const ClientHelloFormatException('truncated');
    }
    final start = offset;
    offset += count;
    return start;
  }

  int u8() => data[need(1)];
  int u16() {
    final at = need(2);
    return (data[at] << 8) | data[at + 1];
  }

  if (u8() != 0x16) throw const ClientHelloFormatException('not a handshake');
  u16(); // The record's version.
  final recordLength = u16();
  if (offset + recordLength > data.length) {
    throw const ClientHelloFormatException('record is cut');
  }
  if (u8() != 1) throw const ClientHelloFormatException('not a ClientHello');
  need(3); // The handshake length.
  final legacyVersion = u16();
  need(32); // The random.
  need(u8()); // The session id.
  final cipherBytes = u16();
  final suites = <int>[];
  final cipherEnd = offset + cipherBytes;
  if (cipherEnd > data.length) {
    throw const ClientHelloFormatException('ciphers are cut');
  }
  while (offset < cipherEnd) {
    suites.add(u16());
  }
  need(u8()); // The compression methods.
  final extensionsLength = u16();
  final end = offset + extensionsLength;
  if (end > data.length) {
    throw const ClientHelloFormatException('extensions are cut');
  }
  final types = <int>[];
  String? serverName;
  var groups = <int>[];
  var formats = <int>[];
  var signatures = <int>[];
  final alpn = <String>[];
  var versions = <int>[];
  var shares = <int>[];
  while (offset < end) {
    final type = u16();
    final length = u16();
    final bodyStart = need(length);
    types.add(type);
    final body = Uint8List.sublistView(data, bodyStart, bodyStart + length);
    int at(int index) => (body[index] << 8) | body[index + 1];
    switch (type) {
      case 0:
        if (length >= 5 && body[2] == 0) {
          final nameLength = at(3);
          if (5 + nameLength <= length) {
            serverName = utf8.decode(
              body.sublist(5, 5 + nameLength),
              allowMalformed: true,
            );
          }
        }
      case 10:
        if (length >= 2) {
          groups = [for (var i = 2; i + 1 < length; i += 2) at(i)];
        }
      case 11:
        if (length >= 1) formats = body.sublist(1).toList();
      case 13:
        if (length >= 2) {
          signatures = [for (var i = 2; i + 1 < length; i += 2) at(i)];
        }
      case 16:
        if (length >= 2) {
          var index = 2;
          while (index < length) {
            final size = body[index];
            if (index + 1 + size > length) break;
            alpn.add(latin1.decode(body.sublist(index + 1, index + 1 + size)));
            index += 1 + size;
          }
        }
      case 43:
        if (length >= 1) {
          versions = [for (var i = 1; i + 1 < length; i += 2) at(i)];
        }
      case 51:
        if (length >= 2) {
          var index = 2;
          shares = [];
          while (index + 4 <= length) {
            shares.add(at(index));
            final size = at(index + 2);
            index += 4 + size;
          }
        }
    }
  }
  return ClientHelloInfo(
    legacyVersion: legacyVersion,
    cipherSuites: suites,
    extensions: types,
    serverName: serverName,
    supportedGroups: groups,
    pointFormats: formats,
    signatureAlgorithms: signatures,
    alpn: alpn,
    supportedVersions: versions,
    keyShareGroups: shares,
  );
}

extension ClientHelloFingerprints on ClientHelloInfo {
  /// A summary line for logs and fixtures.
  String get summary =>
      'ja3=$ja3 ja4=$ja4 ciphers=${cipherSuites.length} '
      'extensions=${extensions.length} sni=${serverName != null} '
      'alpn=${alpn.join(',')}';

  List<int> _plain(List<int> values) => [
    for (final value in values)
      if (!ClientHelloInfo.isGrease(value)) value,
  ];

  /// The JA3 string: version, ciphers, extensions, groups and point formats
  /// (GREASE left out), as decimal lists.
  String get ja3String => [
    '$legacyVersion',
    _plain(cipherSuites).join('-'),
    _plain(extensions).join('-'),
    _plain(supportedGroups).join('-'),
    pointFormats.join('-'),
  ].join(',');

  /// The JA3 hash (MD5 of [ja3String]).
  String get ja3 => crypto.md5.convert(utf8.encode(ja3String)).toString();

  String _hex4(int value) => value.toRadixString(16).padLeft(4, '0');

  /// The JA4 fingerprint (TCP): `t`, the TLS version, `d` or `i` for a hello
  /// with or without a server name, the counts of ciphers and extensions, the
  /// first and last character of the first ALPN value; then the first 12
  /// hex digits of the SHA-256 of the sorted ciphers, and of the sorted
  /// extensions (server name and ALPN left out) with the signature
  /// algorithms in the order sent.
  String get ja4 {
    final ciphers = _plain(cipherSuites);
    final extensionTypes = _plain(extensions);
    final newest = _plain(
      supportedVersions,
    ).fold<int>(0, (a, b) => a > b ? a : b);
    final version = newest == 0x0304
        ? '13'
        : newest == 0x0303
        ? '12'
        : newest == 0x0302
        ? '11'
        : newest == 0x0301
        ? '10'
        : legacyVersion == 0x0303
        ? '12'
        : '00';
    final first = alpn.isEmpty || alpn.first.isEmpty ? null : alpn.first;
    final alpnPart = first == null
        ? '00'
        : '${first[0]}${first[first.length - 1]}';
    final head =
        't$version${serverName != null ? 'd' : 'i'}'
        '${ciphers.length.clamp(0, 99).toString().padLeft(2, '0')}'
        '${extensionTypes.length.clamp(0, 99).toString().padLeft(2, '0')}'
        '$alpnPart';
    String twelve(String text) =>
        crypto.sha256.convert(utf8.encode(text)).toString().substring(0, 12);
    final sortedCiphers = ([...ciphers]..sort()).map(_hex4).join(',');
    final sortedExtensions = ([
      for (final type in extensionTypes)
        if (type != 0 && type != 16) type,
    ]..sort()).map(_hex4).join(',');
    final signatures = _plain(signatureAlgorithms).map(_hex4).join(',');
    final tail = signatures.isEmpty
        ? sortedExtensions
        : '${sortedExtensions}_$signatures';
    return '${head}_${twelve(sortedCiphers)}_${twelve(tail)}';
  }
}
