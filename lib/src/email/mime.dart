/// A small MIME (RFC 2045–2047, 2231) reader and writer for chat mail:
/// headers, nested multiparts, base64 and quoted-printable bodies, and
/// encoded words in headers.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

/// Header fields in their order, names compared without case.
class MimeHeaders {
  const MimeHeaders(this.fields);

  /// Name (as written) and unfolded value, encoded words left as they are.
  final List<(String, String)> fields;

  /// The first field named [name], decoded.
  String? operator [](String name) {
    final lower = name.toLowerCase();
    for (final (key, value) in fields) {
      if (key.toLowerCase() == lower) return decodeMimeWords(value);
    }
    return null;
  }

  /// Every field named [name], undecoded.
  List<String> raw(String name) {
    final lower = name.toLowerCase();
    return [
      for (final (key, value) in fields)
        if (key.toLowerCase() == lower) value,
    ];
  }

  /// Reads a header block (no blank line).
  static MimeHeaders parse(String block) {
    final fields = <(String, String)>[];
    String? name;
    final value = StringBuffer();
    void flush() {
      final current = name;
      if (current != null) fields.add((current, value.toString().trim()));
      name = null;
      value.clear();
    }

    for (final line in block.split(RegExp(r'\r?\n'))) {
      if (line.startsWith(' ') || line.startsWith('\t')) {
        if (name != null) value.write(' ${line.trim()}');
        continue;
      }
      flush();
      final colon = line.indexOf(':');
      if (colon <= 0) continue;
      name = line.substring(0, colon).trim();
      value.write(line.substring(colon + 1));
    }
    flush();
    // Raw 8-bit UTF-8 in headers (common despite RFC 5322) reads as UTF-8.
    return MimeHeaders([
      for (final (key, value) in fields) (key, _utf8OrLatin1(value)),
    ]);
  }
}

/// A MIME entity: a leaf with its decoded body, or a multipart.
class MimeEntity {
  MimeEntity._(
    this.headers,
    this.mimeType,
    this.parameters,
    this.body,
    this.parts,
    this.raw,
  );

  final MimeHeaders headers;

  /// Lower case, `text/plain` when missing.
  final String mimeType;

  /// Content-Type parameters, lower-case names.
  final Map<String, String> parameters;

  /// The decoded body of a leaf (empty for a multipart).
  final Uint8List body;
  final List<MimeEntity> parts;

  /// The entity's bytes as received, headers included.
  final Uint8List raw;

  bool get isMultipart => mimeType.startsWith('multipart/');

  /// The body as text in its charset (UTF-8 unless it says otherwise).
  String get text {
    final charset = (parameters['charset'] ?? 'utf-8').toLowerCase();
    if (charset == 'iso-8859-1' ||
        charset == 'latin1' ||
        charset == 'us-ascii') {
      return latin1.decode(body);
    }
    return utf8.decode(body, allowMalformed: true);
  }

  /// Content-Disposition's type (`attachment`, `inline`), if any.
  String? get disposition =>
      headers['content-disposition']?.split(';').first.trim().toLowerCase();

  /// The file name from Content-Disposition or Content-Type.
  String? get fileName {
    final disposition = headers.raw('content-disposition').firstOrNull;
    final name = disposition == null
        ? null
        : parseMimeParameters(disposition).$2['filename'];
    return name ?? parameters['name'];
  }

  /// Most nested multiparts read, and most parts in all.
  static const int maxDepth = 8;
  static const int maxParts = 200;

  /// Reads a message or body part. Throws [FormatException] when it is not
  /// MIME at all; damaged parts read as best they can.
  static MimeEntity parse(Uint8List data) {
    var budget = maxParts;
    return _parse(data, 0, () => budget-- > 0);
  }

  static MimeEntity _parse(Uint8List data, int depth, bool Function() take) {
    if (!take()) throw const FormatException('Too many MIME parts.');
    final text = latin1.decode(data);
    if (text.startsWith('\r\n') || text.startsWith('\n')) {
      // No headers: the part starts with its blank line.
      return _entity(
        data,
        const MimeHeaders([]),
        text.substring(text.startsWith('\r\n') ? 2 : 1),
        depth,
        take,
      );
    }
    var split = text.indexOf('\r\n\r\n');
    var bodyStart = split + 4;
    final lf = text.indexOf('\n\n');
    if (split < 0 || (lf >= 0 && lf < split)) {
      split = lf;
      bodyStart = lf + 2;
    }
    return _entity(
      data,
      MimeHeaders.parse(split < 0 ? text : text.substring(0, split)),
      split < 0 ? '' : text.substring(bodyStart),
      depth,
      take,
    );
  }

  static MimeEntity _entity(
    Uint8List data,
    MimeHeaders headers,
    String bodyText,
    int depth,
    bool Function() take,
  ) {
    final (type, parameters) = parseMimeParameters(
      headers.raw('content-type').firstOrNull ?? 'text/plain',
    );
    final mimeType = type.isEmpty ? 'text/plain' : type;
    final boundary = parameters['boundary'];
    if (mimeType.startsWith('multipart/') &&
        boundary != null &&
        boundary.isNotEmpty &&
        depth < maxDepth) {
      return MimeEntity._(headers, mimeType, parameters, Uint8List(0), [
        for (final part in _splitParts(bodyText, boundary))
          _parse(latin1.encode(part), depth + 1, take),
      ], data);
    }
    final encoding = (headers['content-transfer-encoding'] ?? '')
        .trim()
        .toLowerCase();
    final Uint8List body = switch (encoding) {
      'base64' => _decodeBase64(bodyText),
      'quoted-printable' => decodeQuotedPrintable(bodyText),
      _ => latin1.encode(bodyText),
    };
    return MimeEntity._(headers, mimeType, parameters, body, const [], data);
  }

  static List<String> _splitParts(String body, String boundary) {
    final delimiter = '--$boundary';
    final parts = <String>[];
    // Delimiters start a line; the line break before one belongs to it.
    var index = body.startsWith(delimiter)
        ? 0
        : _delimiterAt(body, delimiter, 0);
    if (index < 0) return parts;
    while (true) {
      final lineEnd = body.indexOf('\n', index);
      final afterDelimiter = body.substring(
        index + delimiter.length,
        min(index + delimiter.length + 2, body.length),
      );
      if (afterDelimiter == '--' || lineEnd < 0) break;
      final start = lineEnd + 1;
      final next = _delimiterAt(body, delimiter, start);
      if (next < 0) {
        parts.add(body.substring(start)); // unterminated: keep what came
        break;
      }
      var end = next;
      // Drop the CRLF or LF that is part of the next delimiter.
      if (end > start && body[end - 1] == '\n') end--;
      if (end > start && body[end - 1] == '\r') end--;
      parts.add(body.substring(start, max(start, end)));
      index = next;
    }
    return parts;
  }

  /// The index of the next `--boundary` at a line start, from [from]; a
  /// longer boundary that starts with this one does not count.
  static int _delimiterAt(String body, String delimiter, int from) {
    var search = from;
    while (true) {
      final found = body.indexOf(delimiter, search);
      if (found < 0) return -1;
      final end = found + delimiter.length;
      final next = end < body.length ? body[end] : '\n';
      if ((found == 0 || body[found - 1] == '\n') &&
          (next == '-' ||
              next == '\r' ||
              next == '\n' ||
              next == ' ' ||
              next == '\t')) {
        return found;
      }
      search = found + 1;
    }
  }
}

/// A Content-Type or Content-Disposition value: its lower-case first token,
/// and its parameters (RFC 2231 extended and continued ones joined).
(String, Map<String, String>) parseMimeParameters(String value) {
  final pieces = _splitOutsideQuotes(value, ';');
  final type = pieces.isEmpty ? '' : pieces.first.trim().toLowerCase();
  final plain = <String, String>{};
  final extended = <String, Map<int, (String, bool)>>{};
  for (final piece in pieces.skip(1)) {
    final equals = piece.indexOf('=');
    if (equals <= 0) continue;
    var name = piece.substring(0, equals).trim().toLowerCase();
    var raw = piece.substring(equals + 1).trim();
    if (raw.length >= 2 && raw.startsWith('"') && raw.endsWith('"')) {
      raw = raw
          .substring(1, raw.length - 1)
          .replaceAllMapped(RegExp(r'\\(.)'), (match) => match.group(1)!);
    }
    final star = RegExp(r'^([^*]+)\*(?:(\d+)\*?)?$').firstMatch(name);
    if (star != null && name.contains('*')) {
      final encoded = name.endsWith('*');
      final base = star.group(1)!;
      final index = int.tryParse(star.group(2) ?? '') ?? 0;
      (extended[base] ??= {})[index] = (raw, encoded);
      continue;
    }
    name = name.trim();
    plain[name] = decodeMimeWords(raw);
  }
  for (final MapEntry(key: name, value: sections) in extended.entries) {
    final ordered = sections.keys.toList()..sort();
    var charset = 'utf-8';
    final bytes = <int>[];
    for (final index in ordered) {
      var (text, encoded) = sections[index]!;
      if (index == ordered.first && encoded) {
        final first = text.indexOf("'");
        final second = first < 0 ? -1 : text.indexOf("'", first + 1);
        if (second > 0) {
          charset = text.substring(0, first).toLowerCase();
          text = text.substring(second + 1);
        }
      }
      if (encoded) {
        bytes.addAll(_percentDecode(text));
      } else {
        bytes.addAll(latin1.encode(text));
      }
    }
    plain[name] = charset == 'utf-8' || charset == 'us-ascii' || charset.isEmpty
        ? utf8.decode(bytes, allowMalformed: true)
        : latin1.decode(bytes);
  }
  return (type, plain);
}

List<String> _splitOutsideQuotes(String value, String separator) {
  final pieces = <String>[];
  final current = StringBuffer();
  var quoted = false;
  for (var index = 0; index < value.length; index++) {
    final char = value[index];
    if (char == '\\' && quoted && index + 1 < value.length) {
      current
        ..write(char)
        ..write(value[++index]);
      continue;
    }
    if (char == '"') quoted = !quoted;
    if (char == separator && !quoted) {
      pieces.add(current.toString());
      current.clear();
    } else {
      current.write(char);
    }
  }
  pieces.add(current.toString());
  return pieces;
}

List<int> _percentDecode(String text) {
  final out = <int>[];
  for (var index = 0; index < text.length; index++) {
    final char = text.codeUnitAt(index);
    if (char == 0x25 && index + 2 < text.length) {
      final value = int.tryParse(
        text.substring(index + 1, index + 3),
        radix: 16,
      );
      if (value != null) {
        out.add(value);
        index += 2;
        continue;
      }
    }
    out.add(char & 0xff);
  }
  return out;
}

/// Decodes RFC 2047 encoded words (`=?utf-8?b?...?=`) in a header value.
String decodeMimeWords(String value) {
  final pattern = RegExp(r'=\?([^?\s]+)\?([bBqQ])\?([^?\s]*)\?=');
  if (!pattern.hasMatch(value)) return value;
  // Whitespace between two encoded words is dropped.
  final joined = value.replaceAllMapped(
    RegExp(r'(\?=)\s+(=\?)'),
    (match) => '${match.group(1)}${match.group(2)}',
  );
  return joined.replaceAllMapped(pattern, (match) {
    final charset = match.group(1)!.toLowerCase().split('*').first;
    final encoding = match.group(2)!.toLowerCase();
    final payload = match.group(3)!;
    final List<int> bytes;
    if (encoding == 'b') {
      bytes = _decodeBase64(payload);
    } else {
      bytes = decodeQuotedPrintable(payload.replaceAll('_', ' '), header: true);
    }
    return charset == 'utf-8' || charset == 'us-ascii'
        ? utf8.decode(bytes, allowMalformed: true)
        : latin1.decode(bytes);
  });
}

/// An RFC 2047 word for [text] when it is not plain ASCII.
String encodeMimeWord(String text) {
  final plain = text.codeUnits.every(
    (unit) => unit >= 0x20 && unit < 0x7f && unit != 0x3d && unit != 0x3f,
  );
  if (plain && !text.contains('"')) return text;
  return '=?utf-8?b?${base64.encode(utf8.encode(text))}?=';
}

/// Decodes quoted-printable text (soft line breaks joined).
Uint8List decodeQuotedPrintable(String text, {bool header = false}) {
  final out = BytesBuilder(copy: false);
  for (var index = 0; index < text.length; index++) {
    final unit = text.codeUnitAt(index);
    if (unit == 0x3d) {
      if (index + 1 < text.length && text[index + 1] == '\n') {
        index += 1;
        continue;
      }
      if (index + 2 < text.length &&
          text.substring(index + 1, index + 3) == '\r\n') {
        index += 2;
        continue;
      }
      if (index + 2 < text.length) {
        final value = int.tryParse(
          text.substring(index + 1, index + 3),
          radix: 16,
        );
        if (value != null) {
          out.addByte(value);
          index += 2;
          continue;
        }
      }
    }
    out.addByte(unit & 0xff);
  }
  return out.takeBytes();
}

Uint8List _decodeBase64(String text) {
  final clean = text.replaceAll(RegExp(r'[^A-Za-z0-9+/]'), '');
  final usable = clean.length - clean.length % 4;
  final remainder = clean.length % 4;
  var padded = clean.substring(0, usable);
  if (remainder >= 2) {
    padded += clean.substring(usable) + '=' * (4 - remainder);
  }
  try {
    return base64.decode(padded);
  } on FormatException {
    return Uint8List(0);
  }
}

String _utf8OrLatin1(String value) {
  if (!value.codeUnits.any((unit) => unit > 0x7f)) return value;
  try {
    return utf8.decode(latin1.encode(value));
  } on FormatException {
    return value;
  }
}

/// Base64 in lines of 76 characters, CRLF-separated.
String base64Lines(List<int> data) {
  final encoded = base64.encode(data);
  return [
    for (var offset = 0; offset < encoded.length; offset += 76)
      encoded.substring(offset, min(offset + 76, encoded.length)),
  ].join('\r\n');
}

/// `Name: value`, folded at spaces so no line is longer than 78
/// characters where it can be helped.
String foldedHeader(String name, String value) {
  final words = value.split(' ');
  final lines = <String>[];
  var line = StringBuffer('$name:');
  for (final word in words) {
    if (line.length + 1 + word.length > 78 && line.length > name.length + 1) {
      lines.add(line.toString());
      line = StringBuffer();
    }
    line
      ..write(' ')
      ..write(word);
  }
  lines.add(line.toString());
  return lines.join('\r\n');
}

/// A random MIME boundary.
String mimeBoundary(Random random) {
  const alphabet =
      'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
  return List.generate(
    28,
    (_) => alphabet[random.nextInt(alphabet.length)],
  ).join();
}
