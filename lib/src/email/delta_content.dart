/// Bounded Delta file and avatar metadata. Wire reference: chatmail/core
/// d766641ce27eb5ff52baa72bd5f87d0baf378a18.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../attachment_safety.dart';

abstract final class DeltaLimits {
  static const fileBytes = 21 * 1024 * 1024;
  // File MIME base64 is armored again by PGP/MIME (about 1.88x).
  static const fileMailBytes = 42 * 1024 * 1024;
  static const plaintextBytes = 30 * 1024 * 1024;
  static const attachments = 20;
  static const members = 64;
  static const avatarEncodedBytes = 256 * 1024;
  static const splitBytes = 140000;
  static const pendingLifetime = Duration(days: 7);
}

class DeltaFile {
  const DeltaFile({
    required this.name,
    required this.bytes,
    this.mimeType = 'application/octet-stream',
    this.voice = false,
    this.durationMs = 0,
    this.sticker = false,
  });

  final String name;
  final Uint8List bytes;
  final String mimeType;
  final bool voice;
  final int durationMs;
  final bool sticker;

  String get viewtype => voice
      ? 'Voice'
      : sticker
      ? 'Sticker'
      : mimeType.startsWith('image/')
      ? 'Image'
      : mimeType.startsWith('video/')
      ? 'Video'
      : mimeType.startsWith('audio/')
      ? 'Audio'
      : 'File';
}

class DeltaPendingFile {
  const DeltaPendingFile({
    required this.name,
    required this.size,
    required this.viewtype,
    this.durationMs = 0,
  });

  final String name;
  final int size;
  final String viewtype;
  final int durationMs;

  Map<String, dynamic> toJson() => {
    'size': size,
    'viewtype': viewtype,
    'filename': name,
    if (durationMs > 0) 'duration': durationMs,
  };

  static DeltaPendingFile? parse(String? value) {
    if (value == null || value.length > 4096) return null;
    try {
      return fromJson(jsonDecode(value));
    } on FormatException {
      return null;
    }
  }

  static DeltaPendingFile? fromJson(Object? value) {
    if (value is! Map<String, dynamic>) return null;
    final size = value['size'];
    final name = value['filename'];
    final type = value['viewtype'];
    if (size is! int ||
        size < 0 ||
        size > DeltaLimits.fileBytes ||
        name is! String ||
        type is! String ||
        !const {
          'File',
          'Image',
          'Gif',
          'Sticker',
          'Voice',
          'Audio',
          'Video',
          'Webxdc',
        }.contains(type))
      return null;
    return DeltaPendingFile(
      name: sanitizeAttachmentFileName(name),
      size: size,
      viewtype: type,
      durationMs: deltaDuration(value['duration']),
    );
  }
}

int deltaDuration(Object? value) {
  final number = value is int ? value : int.tryParse('$value');
  return (number ?? 0).clamp(0, const Duration(hours: 24).inMilliseconds);
}

String? deltaMessageId(String? value) {
  if (value == null || value.length > 252) return null;
  final id = value
      .trim()
      .replaceFirst(RegExp(r'^<'), '')
      .replaceFirst(RegExp(r'>$'), '');
  return id.isEmpty ||
          id.length > 250 ||
          RegExp(r'[<>\s\x00-\x1f\x7f]').hasMatch(id)
      ? null
      : id;
}

String deltaReaction(String value) {
  final token = value.trim().split(RegExp(r'[\x09-\x0d ]+')).first;
  return utf8.encode(token).length < 30 &&
          !RegExp(r'[\x00-\x1f\x7f]').hasMatch(token)
      ? token
      : '';
}

/// Actual file signatures choose presentation; declared MIME is never used
/// to authorize image/audio decoding or executable content.
String deltaMimeType(Uint8List bytes) {
  bool starts(List<int> prefix, [int offset = 0]) =>
      bytes.length >= prefix.length + offset &&
      prefix.indexed.every((p) => bytes[p.$1 + offset] == p.$2);
  if (starts([137, 80, 78, 71, 13, 10, 26, 10])) return 'image/png';
  if (starts([255, 216, 255])) return 'image/jpeg';
  if (starts(ascii.encode('GIF8'))) return 'image/gif';
  if (starts(ascii.encode('RIFF')) && starts(ascii.encode('WEBP'), 8)) {
    return 'image/webp';
  }
  if (starts(ascii.encode('OggS'))) return 'audio/ogg';
  if (starts(ascii.encode('RIFF')) && starts(ascii.encode('WAVE'), 8)) {
    return 'audio/wav';
  }
  if (starts(ascii.encode('ID3')) ||
      (bytes.length > 1 && bytes[0] == 255 && bytes[1] & 0xe0 == 0xe0))
    return 'audio/mpeg';
  if (starts(ascii.encode('ftyp'), 4)) return 'video/mp4';
  if (starts(ascii.encode('%PDF-'))) return 'application/pdf';
  return 'application/octet-stream';
}

/// Returns a validated static avatar, or null. Dimensions are checked before
/// allocating decoded pixels, and animation is refused.
Uint8List? deltaAvatar(String? header) {
  if (header == null ||
      !header.startsWith('base64:') ||
      header.length > DeltaLimits.avatarEncodedBytes + 7)
    return null;
  try {
    final bytes = base64.decode(
      header.substring(7).replaceAll(RegExp(r'\s'), ''),
    );
    if (!deltaMimeType(bytes).startsWith('image/')) return null;
    final decoder = img.findDecoderForData(bytes);
    final info = decoder?.startDecode(bytes);
    if (info == null ||
        info.width <= 0 ||
        info.height <= 0 ||
        info.width > 512 ||
        info.height > 512 ||
        info.numFrames != 1)
      return null;
    if (decoder!.decodeFrame(0) == null) return null;
    return bytes;
  } catch (_) {
    return null;
  }
}
