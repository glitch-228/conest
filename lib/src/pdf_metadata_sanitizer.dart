import 'dart:convert';
import 'dart:typed_data';

import 'metadata_limits.dart';

/// Structural PDF scanning keeps page content out of metadata rewriting.
/// Every write preserves its byte count, including embedded JPEG APP1s.
abstract final class PdfMetadataSanitizer {
  static const maxInflatedBytes = 8 * 1024 * 1024;

  static ({Uint8List bytes, bool partial}) clean(Uint8List data) {
    final parser = _PdfParser(latin1.decode(data))..parse();
    final out = Uint8List.fromList(data);
    var changed = false;
    var partial = false;
    var inflated = 0;
    void blank(int start, int end, [int fill = 0x20]) {
      for (var at = start; at < end; at++) {
        if (out[at] != fill) changed = true;
        out[at] = fill;
      }
    }

    void blankValue(_PdfValue value, [int depth = 0]) {
      if (depth > 64) throw const FormatException('PDF value depth cap.');
      if (value.kind == 'string') {
        blank(value.start + 1, value.end - 1);
      } else if (value.kind == 'hex') {
        blank(value.start + 1, value.end - 1, 0x30);
      } else if (value.kind == 'array' || value.kind == 'dict') {
        for (final item in value.items) {
          blankValue(item, depth + 1);
        }
      } else if (value.kind == 'ref') {
        // Referenced Info strings cannot safely be distinguished from
        // shared page objects. Require explicit consent for that layout.
        partial = true;
      }
    }

    for (final trailer in parser.trailers) {
      final info = trailer.fields['Info'];
      if (info == null) continue;
      final value = parser.resolve(info);
      if (value?.kind != 'dict') {
        throw const FormatException('Bad PDF Info reference.');
      }
      blankValue(value!);
    }
    for (final object in parser.objects.values) {
      final stream = object.stream;
      if (stream == null) continue;
      final dictionary = object.value;
      final declaredLength = parser.resolve(dictionary.fields['Length']);
      if (declaredLength?.kind != 'number' ||
          int.tryParse(declaredLength!.text) != stream.$2 - stream.$1) {
        throw const FormatException('Bad PDF stream length.');
      }
      final type = dictionary.fields['Type']?.text;
      if (type == 'Metadata') {
        // Blanking compressed bytes with spaces would corrupt the stream.
        // Turn it into an empty unfiltered stream of the same length.
        for (final key in ['Filter', 'DecodeParms']) {
          final value = dictionary.fields[key];
          final name = dictionary.keys[key];
          if (value != null && name != null) blank(name.start, value.end);
        }
        blank(stream.$1, stream.$2);
      } else if (type == 'ObjStm') {
        final filter = dictionary.fields['Filter'];
        final filters = filter?.kind == 'array' ? filter!.items : [filter];
        Uint8List? decoded;
        final payload = Uint8List.sublistView(data, stream.$1, stream.$2);
        if (filter == null) {
          decoded = payload;
        } else if (filters.length == 1 &&
            const {'FlateDecode', 'Fl'}.contains(filters.single?.text) &&
            dictionary.fields['DecodeParms'] == null) {
          decoded = inflateMetadata(payload, maxInflatedBytes - inflated);
        } else {
          partial = true;
        }
        if (decoded != null) {
          inflated += decoded.length;
          if (inflated > maxInflatedBytes) {
            throw const FormatException('PDF inflate cap.');
          }
          final text = latin1.decode(decoded);
          // Decode escaped PDF names too (/Auth#6fr).
          final names = RegExp(r'/([^\s<>\[\]()/%]+)').allMatches(text);
          if (names.any((match) => _metadataKeys.contains(
                  _decodeName(match.group(1)!))) ||
              text.contains('xmpmeta') || text.contains('<?xpacket')) {
            partial = true;
          }
        }
      } else {
        final filter = dictionary.fields['Filter'];
        final filters = filter?.kind == 'array' ? filter!.items : [filter];
        if (filters.length == 1 && filters.single?.text == 'DCTDecode') {
          _blankJpeg(data, stream.$1, stream.$2, blank);
        } else if (filters.any((value) => value?.text == 'DCTDecode')) {
          partial = true;
        }
      }
    }
    return (bytes: changed ? out : data, partial: partial);
  }

  static const _metadataKeys = {
    'Author', 'Creator', 'Producer', 'Title', 'Subject', 'Keywords',
    'CreationDate', 'ModDate',
  };

  static void _blankJpeg(Uint8List data, int start, int end,
      void Function(int, int, [int]) blank) {
    if (end - start < 4 || data[start] != 0xff || data[start + 1] != 0xd8) {
      throw const FormatException('Bad PDF JPEG.');
    }
    var at = start + 2;
    while (at < end) {
      if (at + 1 >= end || data[at] != 0xff) {
        throw const FormatException('Bad PDF JPEG marker.');
      }
      while (at + 1 < end && data[at + 1] == 0xff) { at++; }
      final marker = data[at + 1];
      if (marker == 0xd9) return;
      if (marker == 1 || marker >= 0xd0 && marker <= 0xd7) {
        at += 2;
        continue;
      }
      if (at + 4 > end) throw const FormatException('Short PDF JPEG.');
      final size = data[at + 2] * 256 + data[at + 3];
      final next = at + 2 + size;
      if (size < 2 || next > end) throw const FormatException('Bad JPEG size.');
      if (marker == 0xe1) blank(at + 4, next, 0);
      at = next;
      if (marker == 0xda) {
        while (at + 1 < end) {
          if (data[at] == 0xff && data[at + 1] != 0 &&
              data[at + 1] != 0xff &&
              !(data[at + 1] >= 0xd0 && data[at + 1] <= 0xd7)) break;
          at++;
        }
      }
    }
    throw const FormatException('PDF JPEG end missing.');
  }
}

String _decodeName(String text) => text.replaceAllMapped(
    RegExp('#[0-9a-fA-F]{2}'),
    (match) => String.fromCharCode(int.parse(match[0]!.substring(1), radix: 16)));

class _PdfValue {
  _PdfValue(this.kind, this.start, this.end, this.text,
      {this.items = const [], this.fields = const {}, this.keys = const {}});
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
  var at = 0;
  var tokens = 0;

  _PdfValue? resolve(_PdfValue? value) => value?.kind == 'ref'
      ? objects[value!.text]?.value : value;

  void parse() {
    while (at < text.length) {
      _space();
      if (at >= text.length) break;
      final value = _value();
      if (value.text == 'trailer') {
        final dictionary = _value();
        if (dictionary.kind != 'dict') throw const FormatException('Bad trailer.');
        trailers.add(dictionary);
      } else if (value.kind == 'number') {
        final saved = at;
        _space();
        final objectHeader = RegExp(r'(\d+)\s+obj\b').matchAsPrefix(text, at);
        if (objectHeader == null) { at = saved; continue; }
        final generation = objectHeader[1]!;
        at = objectHeader.end;
        final content = _value();
        _space();
        (int, int)? stream;
        if (text.startsWith('stream', at)) {
          if (content.kind != 'dict') throw const FormatException('Bad stream.');
          at += 6;
          if (text.startsWith('\r\n', at)) { at += 2; }
          else if (text.startsWith('\n', at) || text.startsWith('\r', at)) { at++; }
          else { throw const FormatException('Bad stream separator.'); }
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
            if (stop < 0) throw const FormatException('Stream end missing.');
            var end = stop;
            if (end > start && text[end - 1] == '\n') end--;
            if (end > start && text[end - 1] == '\r') end--;
            stream = (start, end);
            at = stop;
          }
          if (_value().text != 'endstream') {
            throw const FormatException('Bad stream end.');
          }
        }
        if (_value().text != 'endobj') throw const FormatException('Bad object end.');
        final id = '${value.text} $generation';
        // Incremental updates can legitimately replace an object. Retain
        // all earlier Info/metadata objects as well as the latest lookup.
        if (objects.length > 50000) throw const FormatException('PDF object cap.');
        objects[id] = _PdfObject(content, stream);
        if (content.fields['Type']?.text == 'XRef') trailers.add(content);
      }
    }
  }

  void _space() {
    while (at < text.length) {
      if (text[at] == '%') {
        while (at < text.length && text[at] != '\r' && text[at] != '\n') { at++; }
      } else if (const ['\x00', '\t', '\n', '\f', '\r', ' '].contains(text[at])) {
        at++;
      } else { break; }
    }
  }

  _PdfValue _value([int depth = 0]) {
    if (depth > 64 || ++tokens > 500000) {
      throw const FormatException('PDF parser cap.');
    }
    _space();
    final start = at;
    if (at >= text.length) throw const FormatException('PDF value missing.');
    final char = text[at++];
    if (char == '(') {
      var nesting = 1;
      while (at < text.length && nesting > 0) {
        final next = text[at++];
        if (next == '\\') { at++; }
        else if (next == '(') { nesting++; }
        else if (next == ')') { nesting--; }
      }
      if (nesting != 0 || at > text.length) throw const FormatException('Bad PDF string.');
      return _PdfValue('string', start, at, '');
    }
    if (char == '<' && !text.startsWith('<', at)) {
      final end = text.indexOf('>', at);
      if (end < 0) throw const FormatException('Bad PDF hex string.');
      at = end + 1;
      return _PdfValue('hex', start, at, '');
    }
    if (char == '[' || char == '<' && text.startsWith('<', at)) {
      final dict = char == '<';
      if (dict) at++;
      final close = dict ? '>>' : ']';
      final items = <_PdfValue>[];
      final fields = <String, _PdfValue>{};
      final keys = <String, _PdfValue>{};
      while (true) {
        _space();
        if (text.startsWith(close, at)) { at += close.length; break; }
        final value = _value(depth + 1);
        if (dict) {
          if (value.kind != 'name' || fields.containsKey(value.text)) {
            throw const FormatException('Ambiguous PDF dictionary.');
          }
          final item = _value(depth + 1);
          fields[value.text] = item;
          keys[value.text] = value;
          items.add(item);
        } else { items.add(value); }
      }
      return _PdfValue(dict ? 'dict' : 'array', start, at, '',
          items: items, fields: fields, keys: keys);
    }
    while (at < text.length && !RegExp(r'[\s\x00<>\[\]()/%]').hasMatch(text[at])) { at++; }
    final raw = text.substring(char == '/' ? start + 1 : start, at);
    final kind = char == '/' ? 'name'
        : num.tryParse(raw) != null ? 'number' : 'keyword';
    if (kind == 'number' && depth > 0) {
      final saved = at;
      _space();
      final match = RegExp(r'(\d+)\s+R\b').matchAsPrefix(text, at);
      if (match != null) {
        at = match.end;
        return _PdfValue('ref', start, at, '$raw ${match[1]}');
      }
      at = saved;
    }
    return _PdfValue(kind, start, at, kind == 'name' ? _decodeName(raw) : raw);
  }
}
