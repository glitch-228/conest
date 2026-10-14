/// Removes metadata (EXIF, GPS, XMP, IPTC, comments, authors, recording
/// times) from files before they are sent, without re-encoding: photos keep
/// their pixels, videos their streams.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'iso_media_sanitizer.dart';
import 'office_metadata_sanitizer.dart';
import 'pdf_metadata_sanitizer.dart';

enum SanitizeStatus {
  /// Metadata was found and removed.
  cleaned,

  /// A known type with nothing to remove.
  clean,

  /// A type this does not know: sent as it is.
  unsupported,

  /// Too large to rewrite, or damaged: sent as it is.
  failed,

  /// Some details cannot be removed safely; sending still needs consent.
  partial,
}

abstract final class MediaSanitizer {
  /// Largest file rewritten in memory (videos are patched in place at any
  /// size).
  static const int maxInMemoryBytes = 64 * 1024 * 1024;

  /// Removes metadata from the file at [path], which must be a private
  /// copy: it is changed in place.
  static Future<SanitizeStatus> sanitizeFile(String path) async {
    try {
      return await Isolate.run(() => _sanitizeFileWorker(path));
    } catch (_) {
      return SanitizeStatus.failed;
    }
  }

  static Future<SanitizeStatus> _sanitizeFileWorker(String path) async {
    RandomAccessFile? handle;
    try {
      if (!await File(path).exists()) return SanitizeStatus.failed;
      handle = await File(path).open(mode: FileMode.append);
      final length = await handle.length();
      await handle.setPosition(0);
      final head = await handle.read(length < 64 ? length : 64);
      if (_isIsoMedia(head)) {
        return await IsoMediaSanitizer(handle, length).clean()
            ? SanitizeStatus.cleaned : SanitizeStatus.clean;
      }
      final kind = _kind(head);
      if (kind == null) return SanitizeStatus.unsupported;
      if (length > maxInMemoryBytes) {
        return kind == 'zip' && !await OfficeMetadataSanitizer.isDocumentFile(handle, length)
            ? SanitizeStatus.unsupported : SanitizeStatus.failed;
      }
      await handle.setPosition(0);
      final data = await handle.read(length);
      if (data.length != length) return SanitizeStatus.failed;
      final result = sanitizeBytesWithStatus(data);
      if (!identical(result.bytes, data)) {
        await handle.setPosition(0);
        await handle.writeFrom(result.bytes);
        await handle.truncate(result.bytes.length);
      }
      return result.status;
    } catch (_) {
      return SanitizeStatus.failed;
    } finally {
      // Closing is part of the no-throw contract too.
      try { await handle?.close(); } catch (_) {}
    }
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
    final result = sanitizeBytesWithStatus(data);
    if (result.status == SanitizeStatus.failed) return null;
    if (result.status == SanitizeStatus.unsupported) {
      return _kind(data) == 'zip' ? _notApplicable : null;
    }
    return result.bytes;
  }

  /// Like [sanitizeBytes], with consent information for partly cleaned PDFs.
  static ({Uint8List bytes, SanitizeStatus status}) sanitizeBytesWithStatus(
    Uint8List data,
  ) {
    try {
      final kind = _kind(data);
      if (kind == null) return (bytes: data, status: SanitizeStatus.unsupported);
      if (data.length > maxInMemoryBytes) {
        return (bytes: data, status: SanitizeStatus.failed);
      }
      if (kind == 'pdf') {
        final result = PdfMetadataSanitizer.clean(data);
        return (bytes: result.bytes, status: result.partial
            ? SanitizeStatus.partial : identical(result.bytes, data)
            ? SanitizeStatus.clean : SanitizeStatus.cleaned);
      }
      final cleaned = switch (kind) {
        'jpeg' => _jpeg(data),
        'png' => _png(data),
        'gif' => _gif(data),
        'webp' => _webp(data),
        'zip' => OfficeMetadataSanitizer.clean(data, (image) {
          if (!const {'jpeg', 'png', 'gif', 'webp'}.contains(_kind(image))) {
            return null;
          }
          final cleaned = sanitizeBytes(image);
          if (cleaned == null) throw const FormatException('Damaged embedded image.');
          return cleaned;
        }),
        _ => null,
      };
      return (bytes: cleaned ?? data, status: cleaned == null
          ? SanitizeStatus.unsupported : identical(cleaned, data)
          ? SanitizeStatus.clean : SanitizeStatus.cleaned);
    } catch (_) {
      return (bytes: data, status: SanitizeStatus.failed);
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
        0xe0 => startsWith('JFIF\u0000'),
        0xe2 => startsWith('ICC_PROFILE\u0000'),
        0xee => startsWith('Adobe'),
        0xfe => false,
        >= 0xe1 && <= 0xef => false,
        _ => true,
      };
      if (marker == 0xe1 && startsWith('Exif\u0000\u0000')) {
        orientation ??= _exifOrientation(Uint8List.sublistView(body, 6));
      }
      if (marker == 0xe0 && startsWith('JFIF\u0000')) {
        if (body.length < 14 || body.length != 14 + 3 * body[12] * body[13]) {
          throw const FormatException('Bad JFIF thumbnail.');
        }
        if (body[12] != 0 || body[13] != 0) {
          final segment = Uint8List(18)..setAll(0, data.sublist(index, index + 18));
          segment[2] = 0;
          segment[3] = 16;
          segment[16] = segment[17] = 0;
          out.add(segment);
          removed = true;
          index = end;
          continue;
        }
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
      if (const {'tEXt', 'zTXt', 'iTXt', 'eXIf', 'tIME', 'caBX'}.contains(type)) {
        removed = true;
      } else {
        out.add(Uint8List.sublistView(data, index, end));
      }
      index = end;
      if (type == 'IEND') {
        if (length != 0) throw const FormatException('Bad PNG end.');
        if (index < data.length) removed = true;
        return removed ? out.takeBytes() : data;
      }
    }
    throw const FormatException('PNG end missing.');
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

}
