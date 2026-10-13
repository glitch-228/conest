/// Removes metadata (EXIF, GPS, XMP, IPTC, comments, authors, recording
/// times) from files before they are sent, without re-encoding: photos keep
/// their pixels, videos their streams.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';

enum SanitizeStatus {
  /// Metadata was found and removed.
  cleaned,

  /// A known type with nothing to remove.
  clean,

  /// A type this does not know: sent as it is.
  unsupported,

  /// Too large to rewrite, or damaged: sent as it is.
  failed,
}

abstract final class MediaSanitizer {
  /// Largest file rewritten in memory (videos are patched in place at any
  /// size).
  static const int maxInMemoryBytes = 64 * 1024 * 1024;

  /// Removes metadata from the file at [path], which must be a private
  /// copy: it is changed in place.
  static Future<SanitizeStatus> sanitizeFile(String path) async {
    final file = File(path);
    final RandomAccessFile handle;
    try {
      handle = await file.open(mode: FileMode.append);
    } on FileSystemException {
      return SanitizeStatus.failed;
    }
    try {
      final length = await handle.length();
      await handle.setPosition(0);
      final head = await handle.read(length < 64 ? length : 64);
      if (_isIsoMedia(head)) {
        return await _IsoMedia(handle, length).clean()
            ? SanitizeStatus.cleaned
            : SanitizeStatus.clean;
      }
      final kind = _kind(head);
      if (kind == null) return SanitizeStatus.unsupported;
      if (length > maxInMemoryBytes) {
        // Too large to rewrite. A plain archive has nothing to remove; an
        // office document does, so the user is asked.
        if (kind == 'zip' && !await _zipLooksLikeDocument(handle, length)) {
          return SanitizeStatus.unsupported;
        }
        return SanitizeStatus.failed;
      }
      await handle.setPosition(0);
      final data = await handle.read(length);
      final cleaned = sanitizeBytes(data);
      if (identical(cleaned, _notApplicable)) {
        return SanitizeStatus.unsupported;
      }
      if (cleaned == null) return SanitizeStatus.failed;
      if (identical(cleaned, data)) return SanitizeStatus.clean;
      await handle.setPosition(0);
      await handle.writeFrom(cleaned);
      await handle.truncate(cleaned.length);
      return SanitizeStatus.cleaned;
    } catch (_) {
      // Damaged or unusual files (and anything this does not foresee)
      // are reported, never thrown: the caller decides what to send.
      return SanitizeStatus.failed;
    } finally {
      await handle.close();
    }
  }

  /// Reads only a large zip's central directory (from the end of the
  /// file): whether it holds an office document's metadata parts. Unsure
  /// (damaged, or a directory too large to read) counts as a document.
  static Future<bool> _zipLooksLikeDocument(
    RandomAccessFile handle,
    int length,
  ) async {
    const endRecordMax = 22 + 0xffff;
    final tailLength = length < endRecordMax ? length : endRecordMax;
    await handle.setPosition(length - tailLength);
    final tail = await handle.read(tailLength);
    var end = -1;
    for (var i = tail.length - 22; i >= 0; i--) {
      if (tail[i] == 0x50 &&
          tail[i + 1] == 0x4b &&
          tail[i + 2] == 0x05 &&
          tail[i + 3] == 0x06) {
        end = i;
        break;
      }
    }
    if (end < 0) return true;
    int u32(List<int> b, int o) =>
        b[o] | b[o + 1] << 8 | b[o + 2] << 16 | b[o + 3] << 24;
    final directorySize = u32(tail, end + 12);
    final directoryOffset = u32(tail, end + 16);
    // Zip64 (0xffffffff) or an implausible directory: assume a document.
    if (directorySize <= 0 ||
        directorySize > 16 * 1024 * 1024 ||
        directoryOffset + directorySize > length) {
      return true;
    }
    await handle.setPosition(directoryOffset);
    final directory = await handle.read(directorySize);
    final names = latin1.decode(directory, allowInvalid: true);
    const markers = [
      'docProps/',
      '[Content_Types].xml',
      'meta.xml',
      'mimetype',
      'word/',
      'xl/',
      'ppt/',
    ];
    return markers.any(names.contains);
  }

  /// Whether [path] is of a type whose metadata this removes (judged by
  /// its first bytes; a zip may still turn out not to be a document).
  static Future<bool> handles(String path) async {
    try {
      final handle = await File(path).open();
      try {
        final head = await handle.read(64);
        return _isIsoMedia(head) || _kind(head) != null;
      } finally {
        await handle.close();
      }
    } catch (_) {
      return false;
    }
  }

  /// A zip that is not a document: nothing to remove, nothing failed.
  static final Uint8List _notApplicable = Uint8List(0);

  static String? _kind(List<int> head) {
    bool starts(List<int> magic, [int at = 0]) {
      if (head.length < at + magic.length) return false;
      for (var index = 0; index < magic.length; index++) {
        if (head[at + index] != magic[index]) return false;
      }
      return true;
    }

    if (starts([0xff, 0xd8, 0xff])) return 'jpeg';
    if (starts([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])) return 'png';
    if (starts(ascii.encode('GIF87a')) || starts(ascii.encode('GIF89a'))) {
      return 'gif';
    }
    if (starts(ascii.encode('RIFF')) && starts(ascii.encode('WEBP'), 8)) {
      return 'webp';
    }
    if (starts([0x50, 0x4b, 0x03, 0x04])) return 'zip';
    if (starts(ascii.encode('%PDF-'))) return 'pdf';
    return null;
  }

  static bool _isIsoMedia(List<int> head) {
    if (head.length < 12) return false;
    final type = latin1.decode(head.sublist(4, 8));
    return const {
      'ftyp',
      'moov',
      'mdat',
      'wide',
      'free',
      'skip',
    }.contains(type);
  }

  /// [data] without metadata: the same object when there was none to
  /// remove, null when the type is unknown or the data damaged. Videos
  /// (ISO media) go through [sanitizeFile].
  static Uint8List? sanitizeBytes(Uint8List data) {
    try {
      return switch (_kind(data.length < 64 ? data : data.sublist(0, 64))) {
        'jpeg' => _jpeg(data),
        'png' => _png(data),
        'gif' => _gif(data),
        'webp' => _webp(data),
        'zip' => _zip(data),
        'pdf' => _pdf(data),
        _ => null,
      };
    } catch (_) {
      return null;
    }
  }

  // JPEG: APPn segments other than JFIF, ICC profiles and Adobe colour
  // information go, and so do comments; the orientation stays.

  static Uint8List _jpeg(Uint8List data) {
    final out = BytesBuilder(copy: false)..add([0xff, 0xd8]);
    var removed = false;
    int? orientation;
    var index = 2;
    while (index < data.length) {
      if (data[index] != 0xff) throw const FormatException('Bad JPEG.');
      var marker = data[index + 1];
      while (marker == 0xff) {
        index++;
        marker = data[index + 1];
      }
      if (marker == 0xd9) {
        out.add([0xff, 0xd9]);
        // Whatever follows the end (more pictures, with their own
        // metadata) is dropped.
        if (index + 2 < data.length) removed = true;
        break;
      }
      if (marker == 0x01 || (marker >= 0xd0 && marker <= 0xd7)) {
        out.add([0xff, marker]);
        index += 2;
        continue;
      }
      final length = (data[index + 2] << 8) | data[index + 3];
      final end = index + 2 + length;
      if (length < 2 || end > data.length) {
        throw const FormatException('Bad JPEG segment.');
      }
      final body = Uint8List.sublistView(data, index + 4, end);
      bool startsWith(String text) {
        final bytes = latin1.encode(text);
        if (body.length < bytes.length) return false;
        for (var at = 0; at < bytes.length; at++) {
          if (body[at] != bytes[at]) return false;
        }
        return true;
      }

      final keep = switch (marker) {
        0xe0 => startsWith('JFIF\u0000') || startsWith('JFXX\u0000'),
        0xe2 => startsWith('ICC_PROFILE\u0000'),
        0xee => startsWith('Adobe'),
        0xfe => false,
        >= 0xe1 && <= 0xef => false,
        _ => true,
      };
      if (marker == 0xe1 && startsWith('Exif\u0000\u0000')) {
        orientation ??= _exifOrientation(Uint8List.sublistView(body, 6));
      }
      if (keep) {
        out.add(Uint8List.sublistView(data, index, end));
      } else {
        removed = true;
      }
      index = end;
      if (marker == 0xda) {
        // Entropy-coded data, up to the next marker that is not a restart
        // or a stuffed byte.
        final start = index;
        while (index + 1 < data.length) {
          if (data[index] == 0xff) {
            final next = data[index + 1];
            if (next != 0x00 &&
                !(next >= 0xd0 && next <= 0xd7) &&
                next != 0xff) {
              break;
            }
          }
          index++;
        }
        out.add(Uint8List.sublistView(data, start, index));
        if (index + 1 >= data.length) break;
      }
    }
    if (!removed) return data;
    final cleaned = out.takeBytes();
    if (orientation == null || orientation == 1) return cleaned;
    // A minimal EXIF segment with only the orientation, after SOI and any
    // JFIF segment, so the photo is not shown sideways.
    final exif = <int>[
      ...latin1.encode('Exif\u0000\u0000'),
      ...[0x4d, 0x4d, 0x00, 0x2a, 0x00, 0x00, 0x00, 0x08], // big-endian TIFF
      0x00, 0x01, // one entry
      0x01, 0x12, 0x00, 0x03, 0x00, 0x00, 0x00, 0x01, // Orientation, SHORT
      0x00, orientation, 0x00, 0x00,
      0x00, 0x00, 0x00, 0x00, // no next IFD
    ];
    final segment = [
      0xff,
      0xe1,
      (exif.length + 2) >> 8,
      (exif.length + 2) & 0xff,
      ...exif,
    ];
    var insert = 2;
    if (cleaned.length > 6 && cleaned[2] == 0xff && cleaned[3] == 0xe0) {
      insert = 4 + ((cleaned[4] << 8) | cleaned[5]);
    }
    return Uint8List.fromList([
      ...cleaned.sublist(0, insert),
      ...segment,
      ...cleaned.sublist(insert),
    ]);
  }

  /// The Orientation tag (1–8) of a TIFF/EXIF block, if any.
  static int? _exifOrientation(Uint8List tiff) {
    if (tiff.length < 8) return null;
    final little = tiff[0] == 0x49;
    int read16(int at) => little
        ? tiff[at] | (tiff[at + 1] << 8)
        : (tiff[at] << 8) | tiff[at + 1];
    int read32(int at) => little
        ? read16(at) | (read16(at + 2) << 16)
        : (read16(at) << 16) | read16(at + 2);
    final ifd = read32(4);
    if (ifd + 2 > tiff.length) return null;
    final count = read16(ifd);
    for (var entry = 0; entry < count; entry++) {
      final at = ifd + 2 + entry * 12;
      if (at + 12 > tiff.length) return null;
      if (read16(at) == 0x0112) {
        final value = read16(at + 8);
        return value >= 1 && value <= 8 ? value : null;
      }
    }
    return null;
  }

  // PNG: text, EXIF and time chunks go.

  static Uint8List _png(Uint8List data) {
    final out = BytesBuilder(copy: false)..add(data.sublist(0, 8));
    var removed = false;
    var index = 8;
    while (index + 12 <= data.length) {
      final length = ByteData.sublistView(data, index, index + 4).getUint32(0);
      final type = latin1.decode(data.sublist(index + 4, index + 8));
      final end = index + 12 + length;
      if (end > data.length) throw const FormatException('Bad PNG chunk.');
      if (const {'tEXt', 'zTXt', 'iTXt', 'eXIf', 'tIME'}.contains(type)) {
        removed = true;
      } else {
        out.add(Uint8List.sublistView(data, index, end));
      }
      index = end;
      if (type == 'IEND') break;
    }
    return removed ? out.takeBytes() : data;
  }

  // GIF: comments and application blocks other than looping go.

  static Uint8List _gif(Uint8List data) {
    final out = BytesBuilder(copy: false);
    var index = 13;
    if (data[10] & 0x80 != 0) index += 3 * (1 << ((data[10] & 7) + 1));
    out.add(data.sublist(0, index));
    var removed = false;
    int blocksEnd(int at) {
      while (data[at] != 0) {
        at += data[at] + 1;
      }
      return at + 1;
    }

    while (index < data.length) {
      final introducer = data[index];
      if (introducer == 0x3b) {
        out.addByte(0x3b);
        break;
      }
      if (introducer == 0x21) {
        final label = data[index + 1];
        final end = blocksEnd(index + 2);
        var keep = label != 0xfe;
        if (label == 0xff) {
          final id = latin1.decode(
            data.sublist(index + 3, index + 3 + data[index + 2]),
          );
          keep = id == 'NETSCAPE2.0' || id == 'ANIMEXTS1.0';
        }
        if (keep) {
          out.add(Uint8List.sublistView(data, index, end));
        } else {
          removed = true;
        }
        index = end;
      } else if (introducer == 0x2c) {
        var at = index + 10;
        final packed = data[index + 9];
        if (packed & 0x80 != 0) at += 3 * (1 << ((packed & 7) + 1));
        final end = blocksEnd(at + 1);
        out.add(Uint8List.sublistView(data, index, end));
        index = end;
      } else {
        throw const FormatException('Bad GIF block.');
      }
    }
    return removed ? out.takeBytes() : data;
  }

  // WebP: the EXIF and XMP chunks go, and VP8X stops naming them.

  static Uint8List _webp(Uint8List data) {
    final chunks = <Uint8List>[];
    var removed = false;
    var index = 12;
    while (index + 8 <= data.length) {
      final type = latin1.decode(data.sublist(index, index + 4));
      final length = ByteData.sublistView(
        data,
        index + 4,
        index + 8,
      ).getUint32(0, Endian.little);
      final end = index + 8 + length + (length & 1);
      if (index + 8 + length > data.length) {
        throw const FormatException('Bad WebP chunk.');
      }
      if (type == 'EXIF' || type == 'XMP ') {
        removed = true;
      } else {
        final chunk = Uint8List.fromList(
          data.sublist(index, end > data.length ? data.length : end),
        );
        if (type == 'VP8X' && chunk.length > 8) chunk[8] &= ~0x0c;
        chunks.add(chunk);
      }
      index = end;
    }
    if (!removed) return data;
    final size = 4 + chunks.fold<int>(0, (sum, chunk) => sum + chunk.length);
    final header = Uint8List(12)
      ..setAll(0, latin1.encode('RIFF'))
      ..setAll(8, latin1.encode('WEBP'));
    ByteData.sublistView(header).setUint32(4, size, Endian.little);
    return Uint8List.fromList([
      ...header,
      for (final chunk in chunks) ...chunk,
    ]);
  }

  // Office (OOXML) and OpenDocument files: author, company and dates go.

  static Uint8List? _zip(Uint8List data) {
    final archive = ZipDecoder().decodeBytes(data);
    final names = {for (final file in archive.files) file.name};
    final office = names.contains('[Content_Types].xml');
    final open = names.contains('mimetype') && names.contains('meta.xml');
    if (!office && !open) return _notApplicable;
    var removed = false;
    final cleaned = Archive();
    for (final file in archive.files) {
      if (!file.isFile) {
        cleaned.addFile(file);
        continue;
      }
      final content = file.readBytes() ?? Uint8List(0);
      String? replaced;
      final text = file.name.endsWith('.xml')
          ? utf8.decode(content, allowMalformed: true)
          : null;
      if (office && file.name == 'docProps/core.xml' && text != null) {
        replaced = text.replaceAllMapped(
          RegExp(
            r'<((?:dc|cp|dcterms):(?:creator|lastModifiedBy|created|modified|title|subject|description|keywords|identifier|category|contentStatus|lastPrinted))\b[^>]*?(?:/>|>.*?</\1>)',
            dotAll: true,
          ),
          (_) => '',
        );
      } else if (office && file.name == 'docProps/app.xml' && text != null) {
        replaced = text.replaceAllMapped(
          RegExp(
            r'<(Company|Manager|HyperlinkBase|Template)\b[^>]*?(?:/>|>.*?</\1>)',
            dotAll: true,
          ),
          (_) => '',
        );
      } else if (office && file.name == 'docProps/custom.xml' && text != null) {
        replaced = text.replaceAll(
          RegExp(r'<property\b.*?</property>', dotAll: true),
          '',
        );
      } else if (open && file.name == 'meta.xml' && text != null) {
        replaced = text.replaceAllMapped(
          RegExp(r'(<office:meta\b[^>]*>).*?(</office:meta>)', dotAll: true),
          (match) => '${match.group(1)}${match.group(2)}',
        );
      }
      if (replaced != null && replaced != text) {
        removed = true;
        final bytes = utf8.encode(replaced);
        cleaned.addFile(ArchiveFile.bytes(file.name, bytes));
      } else {
        final copy = file.name == 'mimetype'
            ? ArchiveFile.noCompress(file.name, content.length, content)
            : ArchiveFile.bytes(file.name, content);
        cleaned.addFile(copy);
      }
    }
    if (!removed) return data;
    return ZipEncoder().encodeBytes(cleaned);
  }

  // PDF: the document information strings and uncompressed XMP are
  // blanked in place, so every offset in the file stays right.

  static Uint8List _pdf(Uint8List data) {
    final text = latin1.decode(data);
    final out = Uint8List.fromList(data);
    var removed = false;
    void blank(int start, int end, int fill) {
      for (var at = start; at < end; at++) {
        if (out[at] != fill) removed = true;
        out[at] = fill;
      }
    }

    final keys = RegExp(
      r'/(Author|Creator|Producer|Title|Subject|Keywords|CreationDate|ModDate)\s*([(<])',
    );
    for (final match in keys.allMatches(text)) {
      final open = match.end - 1;
      if (text[open] == '<') {
        final close = text.indexOf('>', open);
        if (close < 0) continue;
        blank(open + 1, close, 0x30);
        continue;
      }
      // A literal string: nested parentheses and escapes.
      var depth = 0;
      var at = open;
      for (; at < text.length; at++) {
        final char = text[at];
        if (char == '\\') {
          at++;
        } else if (char == '(') {
          depth++;
        } else if (char == ')') {
          depth--;
          if (depth == 0) break;
        }
      }
      if (at >= text.length) continue;
      blank(open + 1, at, 0x20);
    }
    final xmp = RegExp(r'<x:xmpmeta\b.*?</x:xmpmeta>', dotAll: true);
    for (final match in xmp.allMatches(text)) {
      blank(match.start, match.end, 0x20);
    }
    return removed ? out : data;
  }
}

/// ISO base media files (MP4, MOV, HEIC, AVIF), patched in place: metadata
/// boxes become `free` boxes of the same size, recording times are zeroed,
/// and HEIF Exif and XMP items are blanked.
class _IsoMedia {
  _IsoMedia(this.file, this.length);

  final RandomAccessFile file;
  final int length;
  var _changed = false;

  Future<bool> clean() async {
    await _walk(0, length, top: true);
    return _changed;
  }

  Future<Uint8List> _read(int at, int count) async {
    await file.setPosition(at);
    return file.read(count);
  }

  Future<void> _write(int at, List<int> bytes) async {
    await file.setPosition(at);
    await file.writeFrom(bytes);
    _changed = true;
  }

  Future<void> _zero(int start, int end) async {
    const chunk = 64 * 1024;
    for (var at = start; at < end; at += chunk) {
      final count = end - at < chunk ? end - at : chunk;
      final current = await _read(at, count);
      if (current.any((byte) => byte != 0)) await _write(at, Uint8List(count));
    }
  }

  /// Boxes in [start, end): (type, box start, content start, box end).
  Future<List<(String, int, int, int)>> _boxes(int start, int end) async {
    final boxes = <(String, int, int, int)>[];
    var at = start;
    while (at + 8 <= end && boxes.length < 10000) {
      final header = await _read(at, 16);
      if (header.length < 8) break;
      var size = ByteData.sublistView(header, 0, 4).getUint32(0);
      final type = latin1.decode(header.sublist(4, 8));
      var content = at + 8;
      if (size == 1) {
        if (header.length < 16) break;
        size = ByteData.sublistView(header, 8, 16).getUint64(0);
        content = at + 16;
      } else if (size == 0) {
        size = end - at;
      }
      if (size < content - at || at + size > end) break;
      boxes.add((type, at, content, at + size));
      at += size;
    }
    return boxes;
  }

  Future<void> _walk(int start, int end, {bool top = false}) async {
    for (final (type, boxStart, content, boxEnd) in await _boxes(start, end)) {
      switch (type) {
        case 'moov' || 'trak' || 'mdia':
          await _walk(content, boxEnd);
        case 'udta':
          await _free(boxStart, content, boxEnd);
        case 'meta' when top:
          await _heifItems(content, boxEnd);
        case 'meta':
          await _free(boxStart, content, boxEnd);
        case 'mvhd' || 'tkhd' || 'mdhd':
          final version = (await _read(content, 1)).firstOrNull ?? 0;
          await _zero(content + 4, content + 4 + (version == 1 ? 16 : 8));
      }
    }
  }

  /// Turns a box into a `free` box of the same size, its content zeroed.
  Future<void> _free(int boxStart, int content, int boxEnd) async {
    await _write(boxStart + 4, latin1.encode('free'));
    await _zero(content, boxEnd);
  }

  /// HEIF: blanks the Exif and XMP items the top-level meta box lists.
  Future<void> _heifItems(int start, int end) async {
    final children = await _boxes(start + 4, end); // after version/flags
    final metadataItems = <int>{};
    (int, int)? idat;
    Uint8List? iloc;
    for (final (type, _, content, boxEnd) in children) {
      if (type == 'iinf') {
        final body = await _read(content, boxEnd - content);
        final version = body[0];
        final entriesStart = version == 0 ? 6 : 8;
        for (final (entryType, _, entryContent, entryEnd) in await _boxes(
          content + entriesStart,
          boxEnd,
        )) {
          if (entryType != 'infe') continue;
          final entry = await _read(entryContent, entryEnd - entryContent);
          final entryVersion = entry[0];
          if (entryVersion < 2) continue;
          final idSize = entryVersion == 2 ? 2 : 4;
          var at = 4;
          var id = 0;
          for (var index = 0; index < idSize; index++) {
            id = (id << 8) | entry[at++];
          }
          at += 2; // protection index
          final itemType = latin1.decode(entry.sublist(at, at + 4));
          at += 4;
          var xmp = false;
          if (itemType == 'mime') {
            final nameEnd = entry.indexOf(0, at);
            final typeStart = nameEnd + 1;
            final typeEnd = entry.indexOf(0, typeStart);
            if (nameEnd >= 0 && typeEnd > typeStart) {
              xmp = latin1
                  .decode(entry.sublist(typeStart, typeEnd))
                  .contains('rdf+xml');
            }
          }
          if (itemType == 'Exif' || xmp) metadataItems.add(id);
        }
      } else if (type == 'iloc') {
        iloc = await _read(content, boxEnd - content);
      } else if (type == 'idat') {
        idat = (content, boxEnd);
      }
    }
    if (iloc == null || metadataItems.isEmpty) return;
    final body = iloc;
    var at = 0;
    final version = body[at];
    at += 4;
    final offsetSize = body[at] >> 4;
    final lengthSize = body[at] & 15;
    final baseSize = body[at + 1] >> 4;
    final indexSize = version >= 1 ? body[at + 1] & 15 : 0;
    at += 2;
    int readN(int size) {
      var value = 0;
      for (var index = 0; index < size; index++) {
        value = (value << 8) | body[at++];
      }
      return value;
    }

    final count = version < 2 ? readN(2) : readN(4);
    for (var item = 0; item < count; item++) {
      final id = version < 2 ? readN(2) : readN(4);
      var method = 0;
      if (version >= 1) method = readN(2) & 15;
      readN(2); // data reference index
      final base = readN(baseSize);
      final extents = readN(2);
      for (var extent = 0; extent < extents; extent++) {
        if (indexSize > 0) readN(indexSize);
        final offset = readN(offsetSize);
        final extentLength = readN(lengthSize);
        if (!metadataItems.contains(id)) continue;
        final int origin;
        if (method == 0) {
          origin = base + offset;
        } else if (method == 1 && idat != null) {
          origin = idat.$1 + base + offset;
        } else {
          continue;
        }
        final stop = origin + extentLength;
        if (origin >= 0 && stop <= length && extentLength > 0) {
          await _zero(origin, stop);
        }
      }
    }
  }
}
