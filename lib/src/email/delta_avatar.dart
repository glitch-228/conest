import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

const maxDeltaAvatarEncodedBytes = 256 * 1024;

/// Validate the actual compressed image before any pixel decoder runs, then
/// keep only a small, static PNG with no ancillary metadata or profiles.
Uint8List? deltaAvatar(String? header) {
  if (header == null ||
      !header.startsWith('base64:') ||
      header.length > maxDeltaAvatarEncodedBytes + 7) {
    return null;
  }
  try {
    var bytes = base64.decode(
      header.substring(7).replaceAll(RegExp(r'\s'), ''),
    );
    if (_prefix(bytes, const [137, 80, 78, 71, 13, 10, 26, 10])) {
      final checked = _checkedPng(bytes);
      if (checked == null) return null;
      bytes = checked;
    } else if (_prefix(bytes, const [255, 216, 255])) {
      if (!_checkedJpeg(bytes)) return null;
      bytes = _stripJpegApps(bytes);
    } else if (_prefix(bytes, ascii.encode('RIFF')) &&
        _prefix(bytes, ascii.encode('WEBP'), 8)) {
      final checked = _staticWebp(bytes);
      if (checked == null) return null;
      bytes = checked;
    } else if (!_prefix(bytes, ascii.encode('GIF8')) &&
        !(_prefix(bytes, ascii.encode('RIFF')) &&
            _prefix(bytes, ascii.encode('WEBP'), 8))) {
      return null;
    }
    final decoder = img.findDecoderForData(bytes);
    final info = decoder?.startDecode(bytes);
    if (info == null ||
        !_small(info.width, info.height) ||
        info.numFrames != 1) {
      return null;
    }
    final decoded = decoder!.decodeFrame(0);
    if (decoded == null || !_small(decoded.width, decoded.height)) return null;
    decoded.exif = img.ExifData();
    decoded.iccProfile = null;
    decoded.textData = null;
    var image = decoded;
    var clean = img.encodePng(image);
    while (base64.encode(clean).length > maxDeltaAvatarEncodedBytes) {
      if (image.width <= 1 && image.height <= 1) return null;
      image = img.copyResize(
        image,
        width: (image.width ~/ 2).clamp(1, 512),
        height: (image.height ~/ 2).clamp(1, 512),
      );
      clean = img.encodePng(image);
    }
    return Uint8List.fromList(clean);
  } catch (_) {
    return null;
  }
}

bool _small(int width, int height) =>
    width > 0 && height > 0 && width <= 512 && height <= 512;

bool _prefix(Uint8List bytes, List<int> prefix, [int offset = 0]) =>
    bytes.length >= offset + prefix.length &&
    prefix.indexed.every((e) => bytes[offset + e.$1] == e.$2);

/// image's PNG decoder inflates IDAT into an unbounded buffer. Validate exact
/// scanline size using a streaming sink first, and strip ancillary chunks.
Uint8List? _checkedPng(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  final idat = BytesBuilder(copy: false);
  final clean = BytesBuilder(copy: false)
    ..add(Uint8List.sublistView(bytes, 0, 8));
  var offset = 8;
  var chunks = 0;
  var expected = 0;
  var header = false;
  var end = false;
  while (offset + 12 <= bytes.length) {
    if (++chunks > 128) return null;
    final length = data.getUint32(offset);
    if (length > bytes.length - offset - 12) return null;
    final type = ascii.decode(
      Uint8List.sublistView(bytes, offset + 4, offset + 8),
    );
    final start = offset + 8;
    final after = start + length + 4;
    if (!header && type != 'IHDR') return null;
    if (type == 'IHDR') {
      if (header || length != 13) return null;
      header = true;
      final width = data.getUint32(start);
      final height = data.getUint32(start + 4);
      final bits = bytes[start + 8];
      final color = bytes[start + 9];
      final channels = const {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[color];
      final validBits = switch (color) {
        0 => const [1, 2, 4, 8, 16],
        3 => const [1, 2, 4, 8],
        2 || 4 || 6 => const [8, 16],
        _ => const <int>[],
      };
      if (!_small(width, height) ||
          channels == null ||
          !validBits.contains(bits) ||
          bytes[start + 10] != 0 ||
          bytes[start + 11] != 0 ||
          bytes[start + 12] > 1) {
        return null;
      }
      int pass(int x, int y, int dx, int dy) {
        if (width <= x || height <= y) return 0;
        final w = (width - x + dx - 1) ~/ dx;
        final h = (height - y + dy - 1) ~/ dy;
        return (((w * channels * bits + 7) ~/ 8) + 1) * h;
      }

      expected = bytes[start + 12] == 0
          ? pass(0, 0, 1, 1)
          : pass(0, 0, 8, 8) +
                pass(4, 0, 8, 8) +
                pass(0, 4, 4, 8) +
                pass(2, 0, 4, 4) +
                pass(0, 2, 2, 4) +
                pass(1, 0, 2, 2) +
                pass(0, 1, 1, 2);
    } else if (const {'acTL', 'fcTL', 'fdAT'}.contains(type)) {
      return null;
    } else if (type == 'IDAT') {
      idat.add(Uint8List.sublistView(bytes, start, start + length));
    } else if (type == 'IEND') {
      if (length != 0 || idat.length == 0) return null;
      end = true;
    } else if (type == 'PLTE') {
      if (length == 0 || length > 768 || length % 3 != 0) return null;
    } else if (type == 'tRNS') {
      if (length > 256) return null;
    } else if (type.isEmpty || type.codeUnitAt(0) & 0x20 == 0) {
      return null; // unknown critical chunk
    }
    if (const {'IHDR', 'PLTE', 'tRNS', 'IDAT', 'IEND'}.contains(type)) {
      if (_crc(Uint8List.sublistView(bytes, offset + 4, start + length)) !=
          data.getUint32(start + length)) {
        return null;
      }
      clean.add(Uint8List.sublistView(bytes, offset, after));
    }
    offset = after;
    if (end) break;
  }
  if (!end || offset != bytes.length || expected <= 0) return null;
  final sink = _AvatarInflationSink(expected);
  final inflate = ZLibDecoder().startChunkedConversion(sink);
  final compressed = idat.takeBytes();
  for (var i = 0; i < compressed.length; i += 1024) {
    inflate.add(
      Uint8List.sublistView(
        compressed,
        i,
        (i + 1024).clamp(0, compressed.length),
      ),
    );
  }
  inflate.close();
  return clean.takeBytes();
}

class _AvatarInflationSink implements Sink<List<int>> {
  _AvatarInflationSink(this.expected);
  final int expected;
  int count = 0;
  @override
  void add(List<int> bytes) {
    count += bytes.length;
    if (count > expected) {
      throw const FormatException('Avatar inflation exceeds canvas.');
    }
  }

  @override
  void close() {
    if (count != expected) {
      throw const FormatException('Truncated avatar pixels.');
    }
  }
}

int _crc(Uint8List bytes) {
  var crc = 0xffffffff;
  for (final byte in bytes) {
    crc ^= byte;
    for (var i = 0; i < 8; i++) {
      crc = crc & 1 == 0 ? crc >> 1 : (crc >> 1) ^ 0xedb88320;
    }
  }
  return (crc ^ 0xffffffff) & 0xffffffff;
}

/// JPEG readInfo also prepares coefficient buffers. Inspect every frame and
/// sampling factor before calling it, including markers after an entropy scan.
bool _checkedJpeg(Uint8List bytes) {
  var offset = 2;
  var frames = 0;
  var scans = 0;
  var markers = 0;
  var entropy = false;
  while (offset < bytes.length) {
    if (bytes[offset++] != 255) {
      if (!entropy) return false;
      continue;
    }
    while (offset < bytes.length && bytes[offset] == 255) {
      offset++;
    }
    if (offset >= bytes.length) return false;
    final marker = bytes[offset++];
    if (marker == 0 || marker >= 0xd0 && marker <= 0xd7) {
      if (!entropy) return false;
      continue;
    }
    if (++markers > 1024) return false;
    if (marker == 0xd9) return frames == 1 && scans > 0;
    if (marker == 0xd8 || offset + 2 > bytes.length) return false;
    final length = (bytes[offset] << 8) | bytes[offset + 1];
    if (length < 2 || offset + length > bytes.length) return false;
    if (marker >= 0xc0 &&
        marker <= 0xcf &&
        !const {0xc4, 0xc8, 0xcc}.contains(marker)) {
      if (!const {0xc0, 0xc1, 0xc2}.contains(marker) ||
          ++frames != 1 ||
          length < 8) {
        return false;
      }
      final height = (bytes[offset + 3] << 8) | bytes[offset + 4];
      final width = (bytes[offset + 5] << 8) | bytes[offset + 6];
      final components = bytes[offset + 7];
      if (!_small(width, height) ||
          bytes[offset + 2] != 8 ||
          components < 1 ||
          components > 4 ||
          length != 8 + components * 3) {
        return false;
      }
      for (var c = 0; c < components; c++) {
        final sampling = bytes[offset + 9 + c * 3];
        if (sampling >> 4 < 1 ||
            sampling >> 4 > 4 ||
            sampling & 15 < 1 ||
            sampling & 15 > 4) {
          return false;
        }
      }
    }
    if (marker == 0xda) {
      scans++;
      entropy = true;
    }
    offset += length;
  }
  return false;
}

Uint8List? _staticWebp(Uint8List bytes) {
  if (bytes.length < 12) return null;
  final data = ByteData.sublistView(bytes);
  if (data.getUint32(4, Endian.little) + 8 != bytes.length) return null;
  var offset = 12;
  var chunks = 0;
  var image = false;
  var extended = false;
  final clean = BytesBuilder(copy: false)..add(ascii.encode('WEBP'));
  while (offset + 8 <= bytes.length) {
    if (++chunks > 128) return null;
    final type = ascii.decode(Uint8List.sublistView(bytes, offset, offset + 4));
    final size = data.getUint32(offset + 4, Endian.little);
    if (size > bytes.length - offset - 8) return null;
    if (type == 'ANIM' || type == 'ANMF') return null;
    if (type == 'VP8X') {
      if (extended || size != 10 || bytes[offset + 8] & 2 != 0) return null;
      extended = true;
    }
    if (type == 'VP8 ' || type == 'VP8L') {
      if (image) return null;
      image = true;
    }
    if (const {'VP8X', 'ALPH', 'VP8 ', 'VP8L'}.contains(type)) {
      final chunk = Uint8List.fromList(
        bytes.sublist(offset, offset + 8 + size + (size & 1)),
      );
      if (type == 'VP8X') chunk[8] &= 0x10;
      clean.add(chunk);
    }
    offset += 8 + size + (size & 1);
  }
  if (!image || offset != bytes.length) return null;
  final body = clean.takeBytes();
  final riff = Uint8List(body.length + 8);
  riff.setRange(0, 4, ascii.encode('RIFF'));
  ByteData.sublistView(riff).setUint32(4, body.length, Endian.little);
  riff.setRange(8, riff.length, body);
  return riff;
}

Uint8List _stripJpegApps(Uint8List bytes) {
  final clean = BytesBuilder(copy: false);
  var segment = 0;
  var offset = 2;
  while (offset < bytes.length) {
    if (bytes[offset++] != 255) continue;
    final markerStart = offset - 1;
    while (offset < bytes.length && bytes[offset] == 255) {
      offset++;
    }
    if (offset >= bytes.length) break;
    final marker = bytes[offset++];
    if (marker == 0 || marker >= 0xd0 && marker <= 0xd7) continue;
    if (marker == 0xd9) break;
    final length = (bytes[offset] << 8) | bytes[offset + 1];
    final next = offset + length;
    if ((marker >= 0xe0 && marker <= 0xef && marker != 0xee) ||
        marker == 0xfe) {
      clean.add(Uint8List.sublistView(bytes, segment, markerStart));
      segment = next;
    }
    offset = next;
  }
  clean.add(Uint8List.sublistView(bytes, segment));
  return clean.takeBytes();
}
