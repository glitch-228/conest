import 'dart:convert';
import 'dart:typed_data';

import 'metadata_limits.dart';

/// Structural PDF scanning keeps page content out of metadata rewriting.
/// Every write preserves its byte count, including embedded JPEG APP1s.
abstract final class PdfMetadataSanitizer {
  static const maxInflatedBytes = 8 * 1024 * 1024;

  static ({Uint8List bytes, bool partial}) clean(Uint8List data) {
    final parser = _PdfParser(latin1.decode(data))..parse();
    final ordinaryReferences = parser.ordinaryReferences();
    final out = Uint8List.fromList(data);
    var changed = false;
    var partial = false;
    var inflated = 0;
    var unknownObjectStreams = false;
    void blank(int start, int end, [int fill = 0x20]) {
      for (var at = start; at < end; at++) {
        if (out[at] != fill) {
          changed = true;
        }
        out[at] = fill;
      }
    }

    void blankValue(_PdfValue value, [int depth = 0]) {
      if (depth > 64) {
        throw const FormatException('PDF value depth cap.');
      }
      if (value.kind == 'string') {
        blank(value.start + 1, value.end - 1);
      } else if (value.kind == 'hex') {
        blank(value.start + 1, value.end - 1, 0x30);
      } else if (value.kind == 'dict') {
        for (final entry in value.fields.entries) {
          final item = entry.value;
          if (const {'number', 'name', 'keyword'}.contains(item.kind)) {
            // Custom Info values may use names or numbers for locations.
            // Remove that whole pair, keeping the dictionary well formed.
            blank(value.keys[entry.key]!.start, item.end);
          } else {
            blankValue(item, depth + 1);
          }
        }
      } else if (value.kind == 'array') {
        for (final item in value.items) {
          blankValue(item, depth + 1);
        }
      } else if (value.kind == 'number' || value.kind == 'keyword') {
        blank(value.start, value.end);
        out[value.start] = 0x30;
        changed = true;
      } else if (value.kind == 'name') {
        blank(value.start, value.end);
        if (value.end - value.start >= 2) {
          out[value.start] = 0x2f;
          out[value.start + 1] = 0x5f;
        } else {
          out[value.start] = 0x30;
        }
        changed = true;
      } else if (value.kind == 'ref') {
        // Referenced Info strings cannot safely be distinguished from
        // shared page objects. Require explicit consent for that layout.
        partial = true;
      }
    }

    for (final (_, object) in parser.revisions) {
      final stream = object.stream;
      if (stream == null) {
        continue;
      }
      final dictionary = object.value;
      for (final key in ['Length', 'Type', 'Filter', 'DecodeParms']) {
        parser.requireStableStreamReferences(dictionary.fields[key]);
      }
      final declaredLength = parser.resolve(dictionary.fields['Length']);
      if (declaredLength?.kind != 'number' ||
          int.tryParse(declaredLength!.text) != stream.$2 - stream.$1) {
        throw const FormatException('Bad PDF stream length.');
      }
      final rawType = dictionary.fields['Type'];
      final resolvedType = parser.resolve(rawType);
      if (rawType != null && resolvedType?.kind != 'name') {
        throw const FormatException('Unresolved PDF stream type.');
      }
      final type = resolvedType?.text;
      List<_PdfValue?> filters() {
        final raw = dictionary.fields['Filter'];
        final filter = parser.resolve(raw);
        if (raw != null && filter == null) {
          throw const FormatException('Unresolved PDF stream filter.');
        }
        final values = filter?.kind == 'array' ? filter!.items : [filter];
        if (values.length > 8) {
          throw const FormatException('PDF filter count cap.');
        }
        final resolved = values.map(parser.resolve).toList();
        if (raw != null && resolved.any((value) => value?.kind != 'name')) {
          throw const FormatException('Unsupported PDF filter value.');
        }
        return resolved;
      }

      if (type == 'Metadata') {
        // Blanking compressed bytes with spaces would corrupt the stream.
        // Turn it into an empty unfiltered stream of the same length.
        for (final key in ['Filter', 'DecodeParms']) {
          final value = dictionary.fields[key];
          final name = dictionary.keys[key];
          if (value != null && name != null) {
            blank(name.start, value.end);
          }
        }
        blank(stream.$1, stream.$2);
      } else if (type == 'ObjStm') {
        final filter = dictionary.fields['Filter'];
        final filterValues = filters();
        Uint8List? decoded;
        final payload = Uint8List.sublistView(data, stream.$1, stream.$2);
        if (filter == null) {
          decoded = payload;
        } else if (filterValues.length == 1 &&
            const {'FlateDecode', 'Fl'}.contains(filterValues.single?.text) &&
            dictionary.fields['DecodeParms'] == null) {
          decoded = inflateMetadata(payload, maxInflatedBytes - inflated);
        } else {
          partial = true;
          unknownObjectStreams = true;
        }
        if (decoded != null) {
          inflated += decoded.length;
          if (inflated > maxInflatedBytes) {
            throw const FormatException('PDF inflate cap.');
          }
          final text = latin1.decode(decoded);
          if (text.contains('%')) {
            unknownObjectStreams = true;
          }
          // Compressed page/resource objects can share an Info dictionary.
          // Over-approximate references before deciding whether it is safe
          // to blank Info; a false positive only requests extra consent.
          for (final match in RegExp(
            r'(?<![0-9A-Za-z])([+-]?\d+)[\x00\x09\x0a\x0c\x0d\x20]+([+-]?\d+)[\x00\x09\x0a\x0c\x0d\x20]+R\b',
          ).allMatches(text)) {
            ordinaryReferences.add(_objectId(match[1]!, match[2]!));
            if (ordinaryReferences.length > 250000) {
              throw const FormatException('PDF reference count cap.');
            }
          }
          // Decode escaped PDF names too (/Auth#6fr).
          var nameCount = 0;
          var sensitive = false;
          for (final match in RegExp(r'/([^\s<>\[\]()/%]+)').allMatches(text)) {
            final name = match.group(1)!;
            if (++nameCount > 500000 || name.length > 4096) {
              throw const FormatException('PDF inflated name cap.');
            }
            if (_metadataKeys.contains(_decodeName(name))) {
              sensitive = true;
              break;
            }
          }
          if (sensitive ||
              text.contains('xmpmeta') ||
              text.contains('<?xpacket')) {
            partial = true;
          }
        }
      } else {
        final filterValues = filters();
        if (filterValues.length == 1 &&
            filterValues.single?.text == 'DCTDecode') {
          _blankJpeg(data, stream.$1, stream.$2, blank);
        } else if (filterValues.any((value) => value?.text == 'DCTDecode')) {
          partial = true;
        }
      }
    }
    for (final trailer in parser.trailers) {
      if (trailer.fields.containsKey('Encrypt')) {
        throw const FormatException('Encrypted PDF metadata unsupported.');
      }
      final info = trailer.fields['Info'];
      if (info == null) {
        continue;
      }
      final value = parser.infoAtTrailer[trailer];
      if (unknownObjectStreams ||
          parser.aliasedInfoTrailers.contains(trailer) ||
          info.kind == 'ref' && ordinaryReferences.contains(info.text) ||
          value?.fields['Type'] != null &&
              value!.fields['Type']!.text != 'Info') {
        // A dictionary shared with a page/font/resource is not safe to edit.
        partial = true;
        continue;
      }
      if (value == null) {
        // The Info dictionary may itself be in a compressed object stream.
        partial = true;
      } else {
        if (value.kind != 'dict') {
          throw const FormatException('Bad PDF Info reference.');
        }
        blankValue(value);
      }
    }
    return (bytes: changed ? out : data, partial: partial);
  }

  static const _metadataKeys = {
    'Author',
    'Creator',
    'Producer',
    'Title',
    'Subject',
    'Keywords',
    'CreationDate',
    'ModDate',
  };

  static void _blankJpeg(
    Uint8List data,
    int start,
    int end,
    void Function(int, int, [int]) blank,
  ) {
    if (end - start < 4 || data[start] != 0xff || data[start + 1] != 0xd8) {
      throw const FormatException('Bad PDF JPEG.');
    }
    var at = start + 2;
    while (at < end) {
      if (at + 1 >= end || data[at] != 0xff) {
        throw const FormatException('Bad PDF JPEG marker.');
      }
      while (at + 1 < end && data[at + 1] == 0xff) {
        at++;
      }
      final marker = data[at + 1];
      if (marker == 0xd9) {
        return;
      }
      if (marker == 1 || marker >= 0xd0 && marker <= 0xd7) {
        at += 2;
        continue;
      }
      if (at + 4 > end) {
        throw const FormatException('Short PDF JPEG.');
      }
      final size = data[at + 2] * 256 + data[at + 3];
      final next = at + 2 + size;
      if (size < 2 || next > end) {
        throw const FormatException('Bad JPEG size.');
      }
      if (marker == 0xe1) {
        blank(at + 4, next, 0);
      }
      at = next;
      if (marker == 0xda) {
        while (at + 1 < end) {
          if (data[at] == 0xff &&
              data[at + 1] != 0 &&
              data[at + 1] != 0xff &&
              !(data[at + 1] >= 0xd0 && data[at + 1] <= 0xd7)) {
            break;
          }
          at++;
        }
      }
    }
    throw const FormatException('PDF JPEG end missing.');
  }
}

String _objectId(String number, String generation) {
  final id = int.tryParse(number), gen = int.tryParse(generation);
  if (number.length > 20 ||
      generation.length > 20 ||
      id == null ||
      gen == null ||
      id <= 0 ||
      id > 0x7fffffff ||
      gen < 0 ||
      gen > 65535) {
    throw const FormatException('PDF object ID cap.');
  }
  return '$id $gen';
}

String _decodeName(String text) => text.replaceAllMapped(
  RegExp('#[0-9a-fA-F]{2}'),
  (match) => String.fromCharCode(int.parse(match[0]!.substring(1), radix: 16)),
);

class _PdfValue {
  _PdfValue(
    this.kind,
    this.start,
    this.end,
    this.text, {
    this.items = const [],
    this.fields = const {},
    this.keys = const {},
  });
  final String kind, text;
  final int start, end;
  final List<_PdfValue> items;
  final Map<String, _PdfValue> fields, keys;
}

class _PdfObject {
  _PdfObject(this.value, this.stream);
  final _PdfValue value;
  final (int, int)? stream;
}

class _PdfParser {
  _PdfParser(this.text);
  final String text;
  final objects = <String, _PdfObject>{};
  final trailers = <_PdfValue>[];
  final revisions = <(String, _PdfObject)>[];
  final infoAtTrailer = <_PdfValue, _PdfValue?>{};
  final changedIds = <String>{};
  final aliasedInfoTrailers = <_PdfValue>{};
  var at = 0;
  var tokens = 0;

  _PdfValue? resolve(_PdfValue? value) {
    final seen = <String>{};
    while (value?.kind == 'ref') {
      if (!seen.add(value!.text) || seen.length > 64) {
        throw const FormatException('PDF reference cap or cycle.');
      }
      value = objects[value.text]?.value;
    }
    return value;
  }

  Set<String> ordinaryReferences() {
    final references = <String>{};
    final seen = <_PdfValue>{};
    void walk(_PdfValue value) {
      if (!seen.add(value)) {
        return;
      }
      if (value.kind == 'ref') {
        references.add(value.text);
      }
      for (final item in value.items) {
        walk(item);
      }
    }

    for (final (_, object) in revisions) {
      if (object.value.fields['Type']?.text == 'XRef') {
        for (final entry in object.value.fields.entries) {
          if (entry.key != 'Info') {
            walk(entry.value);
          }
        }
      } else {
        walk(object.value);
      }
    }
    return references;
  }

  void requireStableStreamReferences(_PdfValue? value) {
    final seen = <_PdfValue>{};
    var steps = 0;
    void walk(_PdfValue? value, int depth) {
      if (value == null || !seen.add(value)) {
        return;
      }
      if (depth > 64 || ++steps > 256) {
        throw const FormatException('PDF parameter traversal cap.');
      }
      if (value.kind == 'ref') {
        if (changedIds.contains(value.text)) {
          throw const FormatException(
            'Changed indirect PDF stream parameters.',
          );
        }
        walk(objects[value.text]?.value, depth + 1);
      } else if (value.kind == 'array') {
        if (value.items.length > 8) {
          throw const FormatException('PDF parameter cap.');
        }
        for (final item in value.items) {
          walk(item, depth + 1);
        }
      }
    }

    walk(value, 0);
  }

  void _trailer(_PdfValue dictionary) {
    trailers.add(dictionary);
    final info = dictionary.fields['Info'];
    if (info?.kind == 'ref' && objects[info!.text]?.value.kind == 'ref') {
      aliasedInfoTrailers.add(dictionary);
    }
    infoAtTrailer[dictionary] = resolve(info);
  }

  void parse() {
    while (at < text.length) {
      _space();
      if (at >= text.length) {
        break;
      }
      final value = _value();
      if (value.text == 'trailer') {
        final dictionary = _value();
        if (dictionary.kind != 'dict') {
          throw const FormatException('Bad trailer.');
        }
        _trailer(dictionary);
      } else if (value.kind == 'number') {
        final saved = at;
        _space();
        final objectHeader = RegExp(
          r'([+-]?\d+)\s+obj\b',
        ).matchAsPrefix(text, at);
        if (objectHeader == null) {
          at = saved;
          continue;
        }
        final generation = objectHeader[1]!;
        at = objectHeader.end;
        final content = _value(1);
        _space();
        (int, int)? stream;
        if (text.startsWith('stream', at)) {
          if (content.kind != 'dict') {
            throw const FormatException('Bad stream.');
          }
          at += 6;
          if (text.startsWith('\r\n', at)) {
            at += 2;
          } else if (text.startsWith('\n', at) || text.startsWith('\r', at)) {
            at++;
          } else {
            throw const FormatException('Bad stream separator.');
          }
          final start = at;
          final length = resolve(content.fields['Length']);
          if (length?.kind == 'number') {
            final count = int.tryParse(length!.text);
            if (count == null || count < 0 || start + count > text.length) {
              throw const FormatException('Bad stream size.');
            }
            at = start + count;
            stream = (start, at);
            _space();
          } else {
            // Forward length reference: scan provisionally, then require
            // exact agreement with the resolved Length before any writes.
            final stop = text.indexOf('endstream', at);
            if (stop < 0) {
              throw const FormatException('Stream end missing.');
            }
            var end = stop;
            if (end > start && text[end - 1] == '\n') {
              end--;
            }
            if (end > start && text[end - 1] == '\r') {
              end--;
            }
            stream = (start, end);
            at = stop;
          }
          if (_value().text != 'endstream') {
            throw const FormatException('Bad stream end.');
          }
        }
        if (_value().text != 'endobj') {
          throw const FormatException('Bad object end.');
        }
        final id = _objectId(value.text, generation);
        // Incremental updates can legitimately replace an object. Retain
        // all earlier Info/metadata objects as well as the latest lookup.
        if (revisions.length >= 50000) {
          throw const FormatException('PDF object cap.');
        }
        if (objects.containsKey(id)) {
          changedIds.add(id);
        }
        final object = _PdfObject(content, stream);
        objects[id] = object;
        revisions.add((id, object));
        if (content.fields['Type']?.text == 'XRef') {
          _trailer(content);
        }
      }
    }
  }

  void _space() {
    while (at < text.length) {
      if (text[at] == '%') {
        while (at < text.length && text[at] != '\r' && text[at] != '\n') {
          at++;
        }
      } else if (const [
        '\x00',
        '\t',
        '\n',
        '\f',
        '\r',
        ' ',
      ].contains(text[at])) {
        at++;
      } else {
        break;
      }
    }
  }

  static bool _delimiter(int code) =>
      code == 0 ||
      code == 9 ||
      code == 10 ||
      code == 12 ||
      code == 13 ||
      code == 32 ||
      code == 60 ||
      code == 62 ||
      code == 91 ||
      code == 93 ||
      code == 40 ||
      code == 41 ||
      code == 47 ||
      code == 37;

  _PdfValue _value([int depth = 0]) {
    if (depth > 64 || ++tokens > 500000) {
      throw const FormatException('PDF parser cap.');
    }
    _space();
    final start = at;
    if (at >= text.length) {
      throw const FormatException('PDF value missing.');
    }
    final char = text[at++];
    if (char == '(') {
      var nesting = 1;
      while (at < text.length && nesting > 0) {
        final next = text[at++];
        if (next == '\\') {
          at++;
        } else if (next == '(') {
          nesting++;
        } else if (next == ')') {
          nesting--;
        }
      }
      if (nesting != 0 || at > text.length) {
        throw const FormatException('Bad PDF string.');
      }
      return _PdfValue('string', start, at, '');
    }
    if (char == '<' && !text.startsWith('<', at)) {
      final end = text.indexOf('>', at);
      if (end < 0) {
        throw const FormatException('Bad PDF hex string.');
      }
      at = end + 1;
      return _PdfValue('hex', start, at, '');
    }
    if (char == '[' || char == '<' && text.startsWith('<', at)) {
      final dict = char == '<';
      if (dict) {
        at++;
      }
      final close = dict ? '>>' : ']';
      final items = <_PdfValue>[];
      final fields = <String, _PdfValue>{};
      final keys = <String, _PdfValue>{};
      while (true) {
        _space();
        if (text.startsWith(close, at)) {
          at += close.length;
          break;
        }
        final value = _value(depth + 1);
        if (dict) {
          if (value.kind != 'name' || fields.containsKey(value.text)) {
            throw const FormatException('Ambiguous PDF dictionary.');
          }
          final item = _value(depth + 1);
          fields[value.text] = item;
          keys[value.text] = value;
          items.add(item);
        } else {
          items.add(value);
        }
      }
      return _PdfValue(
        dict ? 'dict' : 'array',
        start,
        at,
        '',
        items: items,
        fields: fields,
        keys: keys,
      );
    }
    while (at < text.length && !_delimiter(text.codeUnitAt(at))) {
      if (at - start >= 4096) {
        throw const FormatException('PDF token length cap.');
      }
      at++;
    }
    final raw = text.substring(char == '/' ? start + 1 : start, at);
    final kind = char == '/'
        ? 'name'
        : num.tryParse(raw) != null
        ? 'number'
        : 'keyword';
    if (kind == 'number' && depth > 0) {
      final saved = at;
      _space();
      final match = RegExp(r'([+-]?\d+)\s+R\b').matchAsPrefix(text, at);
      if (match != null) {
        at = match.end;
        return _PdfValue('ref', start, at, _objectId(raw, match[1]!));
      }
      at = saved;
    }
    return _PdfValue(kind, start, at, kind == 'name' ? _decodeName(raw) : raw);
  }
}
