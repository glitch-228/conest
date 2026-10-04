import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'openpgp.dart';

/// Version byte at the start of the decrypted mail content.
const int carrierMailVersion = 1;

/// Largest mail fetched; bigger ones are not carrier mail.
const int maxCarrierMailBytes = 2 * 1024 * 1024;

/// Builds and reads the mail that carries one frame: PGP/MIME (RFC 3156)
/// with the frame inside an OpenPGP password message, as chatmail servers
/// require. The password is the recipient's mailbox key from its address.
abstract final class CarrierMail {
  /// The RFC 5322 message, CRLF line endings.
  static String build({
    required String from,
    required String to,
    required List<int> mailboxKey,
    required Uint8List frame,
    required DateTime date,
    Random? random,
  }) {
    final source = random ?? Random.secure();
    String token(int length) => List.generate(
      length,
      (_) => 'abcdefghijklmnopqrstuvwxyz0123456789'[source.nextInt(36)],
    ).join();
    final domain = from.substring(from.lastIndexOf('@') + 1);
    final boundary = 'cc-${token(24)}';
    final armored = OpenPgpArmor.encode(
      OpenPgpSymmetric.encrypt(
        Uint8List.fromList([carrierMailVersion, ...frame]),
        mailboxKey,
        random: random,
      ),
    );
    return [
      'From: <$from>',
      'To: <$to>',
      'Subject: [...]',
      'Date: ${_rfc5322Date(date)}',
      'Message-ID: <${token(20)}@$domain>',
      'MIME-Version: 1.0',
      'Content-Type: multipart/encrypted; '
          'protocol="application/pgp-encrypted"; boundary="$boundary"',
      '',
      '--$boundary',
      'Content-Type: application/pgp-encrypted',
      'Content-Description: PGP/MIME version identification',
      '',
      'Version: 1',
      '',
      '--$boundary',
      'Content-Type: application/octet-stream; name="encrypted.asc"',
      'Content-Description: OpenPGP encrypted message',
      'Content-Disposition: inline; filename="encrypted.asc"',
      '',
      armored.trimRight(),
      '',
      '--$boundary--',
      '',
    ].join('\r\n');
  }

  /// Reads a fetched mail: the sender's address and the frame, or null when
  /// it is not carrier mail for [mailboxKey].
  static ({String from, Uint8List frame})? read(
    Uint8List raw,
    List<int> mailboxKey,
  ) {
    if (raw.length > maxCarrierMailBytes) return null;
    final text = latin1.decode(raw);
    final headerEnd = text.indexOf('\r\n\r\n');
    final split = headerEnd >= 0 ? headerEnd : text.indexOf('\n\n');
    if (split < 0) return null;
    final headers = _headers(text.substring(0, split));
    final from = parseMailAddress(headers['from']);
    final type = headers['content-type'] ?? '';
    if (from == null || !type.toLowerCase().startsWith('multipart/encrypted')) {
      return null;
    }
    final begin = text.indexOf('-----BEGIN PGP MESSAGE-----');
    final end = text.indexOf('-----END PGP MESSAGE-----');
    if (begin < 0 || end < begin) return null;
    try {
      final clear = OpenPgpSymmetric.decrypt(
        OpenPgpArmor.decode(
          text.substring(begin, end + '-----END PGP MESSAGE-----'.length),
        ),
        mailboxKey,
      );
      if (clear.length < 2 || clear[0] != carrierMailVersion) return null;
      return (from: from, frame: Uint8List.sublistView(clear, 1));
    } on FormatException {
      return null;
    }
  }

  /// Unfolded headers by lower-case name (the first of each).
  static Map<String, String> _headers(String block) {
    final result = <String, String>{};
    String? name;
    final value = StringBuffer();
    void flush() {
      final current = name;
      if (current != null) {
        result.putIfAbsent(current, () => value.toString().trim());
      }
      value.clear();
    }

    for (final line in block.split(RegExp(r'\r?\n'))) {
      if (line.startsWith(' ') || line.startsWith('\t')) {
        value.write(' ${line.trim()}');
        continue;
      }
      flush();
      final colon = line.indexOf(':');
      if (colon <= 0) {
        name = null;
        continue;
      }
      name = line.substring(0, colon).trim().toLowerCase();
      value.write(line.substring(colon + 1));
    }
    flush();
    return result;
  }

  static String _rfc5322Date(DateTime time) {
    final utc = time.toUtc();
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    String two(int value) => value.toString().padLeft(2, '0');
    return '${days[utc.weekday - 1]}, ${utc.day} ${months[utc.month - 1]} '
        '${utc.year} ${two(utc.hour)}:${two(utc.minute)}:${two(utc.second)} '
        '+0000';
  }
}

/// The bare, lower-cased address in a header such as `Name <a@b.c>`; null
/// when there is none or it is implausible.
String? parseMailAddress(String? header) {
  if (header == null) return null;
  // The last angle address: a display name may hold another one.
  final angle = RegExp(r'<([^<>\s]+)>').allMatches(header).lastOrNull;
  final candidate = (angle?.group(1) ?? header).trim().toLowerCase();
  return isPlausibleMailAddress(candidate) ? candidate : null;
}

/// A single `local@domain` address without spaces, quotes or brackets.
bool isPlausibleMailAddress(String address) =>
    address.length <= 254 &&
    RegExp(
      r'^[a-z0-9.!#$%&*+/=?^_`{}~-]{1,64}@[a-z0-9-]+(\.[a-z0-9-]+)+$',
    ).hasMatch(address);
