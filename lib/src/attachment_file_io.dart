import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart' as crypto;

import 'native_attachment_crypto.dart';
import 'staged_attachment.dart';

typedef AttachmentFileDigest = ({int sizeBytes, String sha256Base64});

// Keep isolate entry closures in these small top-level functions so they
// cannot capture a controller, platform channel, or UI progress callback.
Future<AttachmentFileDigest> hashAttachmentFile(String path) =>
    Isolate.run(() => _hashFile(path));

Future<AttachmentFileDigest> _hashFile(String path) async {
  final native = NativeAttachmentCrypto.tryCreate()?.hashFile(path);
  if (native != null) return native;
  final file = File(path);
  final size = await file.length();
  final digest = await crypto.sha256.bind(file.openRead()).first;
  return (sizeBytes: size, sha256Base64: base64Encode(digest.bytes));
}

Future<AttachmentFileDigest> copyAndHashAttachment(
  StagedAttachment source,
  String destination, {
  void Function(int)? onProgress,
}) async {
  final progress = ReceivePort();
  final subscription = progress.listen(
    (bytes) => onProgress?.call(bytes as int),
  );
  try {
    return await _launchCopy(source, destination, progress.sendPort);
  } finally {
    await subscription.cancel();
    progress.close();
  }
}

Future<AttachmentFileDigest> _launchCopy(
  StagedAttachment source,
  String destination,
  SendPort progress,
) => Isolate.run(() => _copyAndHash(source, destination, progress));

Future<AttachmentFileDigest> _copyAndHash(
  StagedAttachment source,
  String destination,
  SendPort progress,
) async {
  final output = await File(destination).open(mode: FileMode.writeOnly);
  var written = 0;
  final clock = Stopwatch()..start();
  var lastReport = 0;
  try {
    await for (final chunk in source.openRead()) {
      written += chunk.length;
      if (written > source.sizeBytes) {
        throw const FormatException('Attachment source grew while copying.');
      }
      await output.writeFrom(chunk);
      if (clock.elapsedMilliseconds - lastReport >= 100 ||
          written == source.sizeBytes) {
        progress.send(written);
        lastReport = clock.elapsedMilliseconds;
      }
    }
    if (written != source.sizeBytes) {
      throw const FormatException(
        'Attachment source size changed while copying.',
      );
    }
    await output.flush();
  } finally {
    await output.close();
  }
  return _hashFile(destination);
}
