import 'dart:async';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:super_clipboard/super_clipboard.dart';

/// The largest clipboard image read (a 4K screenshot as PNG can pass 8 MiB).
const int maxClipboardImageBytes = 32 * 1024 * 1024;

/// How long one clipboard format may take to read.
const Duration _readTimeout = Duration(seconds: 10);

/// Image formats tried in order. On Windows, a screenshot (Win+Shift+S)
/// is a bitmap the clipboard library offers as PNG; TIFF and BMP come
/// last and are turned into PNG.
const List<FileFormat> _imageFormats = [
  Formats.png,
  Formats.jpeg,
  Formats.gif,
  Formats.webp,
  Formats.tiff,
  Formats.bmp,
];

/// An image on the clipboard, read as a paste does: its bytes, and PNG
/// for formats converted on the way. [log] gets each step: the formats
/// offered, what was read, and why not.
Future<Uint8List?> readClipboardImage(
  DataReader reader, {
  required void Function(String line) log,
}) async {
  log('Clipboard offers: ${reader.platformFormats.join(', ')}');
  for (final format in _imageFormats) {
    if (!reader.canProvide(format)) continue;
    final bytes = await _readFile(reader, format, log);
    if (bytes == null || bytes.isEmpty) continue;
    if (format == Formats.tiff || format == Formats.bmp) {
      final decoded = img.decodeImage(bytes);
      if (decoded == null) {
        log('Clipboard $format could not be decoded.');
        continue;
      }
      return img.encodePng(decoded);
    }
    log('Clipboard image read as $format: ${bytes.length} bytes.');
    return bytes;
  }
  return null;
}

Future<Uint8List?> _readFile(
  DataReader reader,
  FileFormat format,
  void Function(String line) log,
) async {
  final completer = Completer<Uint8List?>();
  void finish(Uint8List? bytes) {
    if (!completer.isCompleted) completer.complete(bytes);
  }

  final progress = reader.getFile(
    format,
    (file) async {
      try {
        final builder = BytesBuilder(copy: false);
        var total = 0;
        await for (final chunk in file.getStream()) {
          total += chunk.length;
          if (total > maxClipboardImageBytes) {
            log('Clipboard $format is larger than the paste limit.');
            finish(null);
            return;
          }
          builder.add(chunk);
        }
        finish(builder.takeBytes());
      } catch (error) {
        log('Reading clipboard $format failed: $error');
        finish(null);
      }
    },
    onError: (error) {
      log('Clipboard $format could not be read: $error');
      finish(null);
    },
  );
  // No file for this format: the read would never call back.
  if (progress == null) {
    log('Clipboard has no file for $format.');
    return null;
  }
  return completer.future.timeout(
    _readTimeout,
    onTimeout: () {
      log('Reading clipboard $format timed out.');
      return null;
    },
  );
}
