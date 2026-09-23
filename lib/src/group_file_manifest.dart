import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';

import 'group_history_event.dart';
import 'feature_models.dart';

/// Content description carried by an author-signed attachment history event.
/// Membership/signature authorization remains the history replica's job.
class GroupFileManifest {
  GroupFileManifest({
    required this.fileName,
    required this.mimeType,
    required this.sizeBytes,
    required this.fileHash,
    required List<String> pieceHashes,
    this.caption = '',
    this.voiceMetadata,
  }) : pieceHashes = List.unmodifiable(pieceHashes) {
    if (fileName.isEmpty ||
        fileName.length > 255 ||
        fileName.contains(RegExp(r'[/\\\x00-\x1f]')) ||
        mimeType.isEmpty ||
        mimeType.length > 128 ||
        caption.length > 4096 ||
        (caption.isNotEmpty && caption.trim().isEmpty) ||
        sizeBytes <= 0 ||
        sizeBytes > maxSize ||
        this.pieceHashes.length != (sizeBytes + pieceSize - 1) ~/ pieceSize ||
        !_hash(fileHash) ||
        !this.pieceHashes.every(_hash) ||
        (voiceMetadata != null &&
            (voiceMetadata!.durationMs <= 0 ||
                voiceMetadata!.durationMs > 10 * 60 * 1000 ||
                voiceMetadata!.codec != 'opus' ||
                voiceMetadata!.container != 'ogg' ||
                !mimeType.toLowerCase().contains('ogg')))) {
      throw const FormatException('Invalid group file manifest.');
    }
  }

  static const pieceSize = 4 * 1024 * 1024;
  static const maxSize = 2 * 1024 * 1024 * 1024;
  static const onlineAutoDownloadLimit = 15 * 1024 * 1024;
  final String fileName;
  final String mimeType;
  final String caption;
  final int sizeBytes;
  final String fileHash;
  final List<String> pieceHashes;
  final VoiceMessageMetadata? voiceMetadata;

  static bool _hash(String value) => RegExp(r'^[0-9a-f]{64}$').hasMatch(value);

  int lengthOf(int index) {
    RangeError.checkValidIndex(index, pieceHashes);
    final remaining = sizeBytes - index * pieceSize;
    return remaining < pieceSize ? remaining : pieceSize;
  }

  bool verifyPiece(int index, List<int> bytes) =>
      bytes.length == lengthOf(index) &&
      sha256.convert(bytes).toString() == pieceHashes[index];

  bool automaticallyDownload({required bool lan}) =>
      lan || sizeBytes < onlineAutoDownloadLimit;

  Map<String, Object?> toPayload() => {
    'version': caption.isEmpty ? 1 : 2,
    'fileName': fileName,
    'mimeType': mimeType,
    if (caption.isNotEmpty) 'caption': caption,
    'sizeBytes': sizeBytes,
    'pieceSize': pieceSize,
    'fileHash': fileHash,
    'pieceHashes': pieceHashes,
    if (voiceMetadata != null) 'voiceMetadata': voiceMetadata!.toJson(),
  };

  factory GroupFileManifest.fromEvent(GroupHistoryEvent event) {
    if (event.kind != GroupEventKind.attachment) {
      throw const FormatException('Expected an attachment event.');
    }
    return GroupFileManifest.fromPayload(event.payload);
  }

  factory GroupFileManifest.fromPayload(Map<String, Object?> payload) {
    try {
      final hasOperationId = payload.containsKey('scheduledOperationId');
      final operationId = payload['scheduledOperationId'];
      final hasCaption = payload.containsKey('caption');
      final rawCaption = payload['caption'];
      final hasVoiceMetadata = payload.containsKey('voiceMetadata');
      final rawVoiceMetadata = payload['voiceMetadata'];
      if (hasVoiceMetadata && rawVoiceMetadata is! Map) {
        throw const FormatException('Invalid group voice metadata.');
      }
      final allowedKeys = <String>{
        'version',
        'fileName',
        'mimeType',
        if (hasCaption) 'caption',
        'sizeBytes',
        'pieceSize',
        'fileHash',
        'pieceHashes',
        if (hasOperationId) 'scheduledOperationId',
        if (hasVoiceMetadata) 'voiceMetadata',
      };
      if (payload.keys.toSet().difference(allowedKeys).isNotEmpty ||
          payload.length != allowedKeys.length ||
          (hasCaption &&
              (rawCaption is! String ||
                  rawCaption.isEmpty ||
                  rawCaption.trim().isEmpty)) ||
          (hasOperationId &&
              (operationId is! String ||
                  operationId.isEmpty ||
                  operationId.length > 160)) ||
          (payload['version'] != 1 && payload['version'] != 2) ||
          (hasCaption != (payload['version'] == 2)) ||
          payload['pieceSize'] != pieceSize) {
        throw const FormatException('Unsupported group file manifest.');
      }
      return GroupFileManifest(
        fileName: payload['fileName'] as String,
        mimeType: payload['mimeType'] as String,
        caption: hasCaption ? rawCaption as String : '',
        sizeBytes: payload['sizeBytes'] as int,
        fileHash: payload['fileHash'] as String,
        pieceHashes: (payload['pieceHashes'] as List).cast<String>(),
        voiceMetadata: hasVoiceMetadata
            ? VoiceMessageMetadata.fromJson(
                (rawVoiceMetadata as Map).cast<String, dynamic>(),
              )
            : null,
      );
    } on TypeError {
      throw const FormatException('Invalid group file manifest fields.');
    }
  }
}

/// Hash the app-owned staged copy, off the UI isolate. Memory is bounded to one
/// piece; the whole-file digest consumes those same bytes in the same pass.
Future<GroupFileManifest> hashGroupFile({
  required String path,
  required String fileName,
  required String mimeType,
  String caption = '',
  VoiceMessageMetadata? voiceMetadata,
}) {
  final metadataPayload = voiceMetadata?.toJson();
  return Isolate.run(() async {
    final file = await File(path).open();
    try {
      final size = await file.length();
      if (size <= 0 || size > GroupFileManifest.maxSize) {
        throw const FormatException(
          'Group files must be between 1 byte and 2 GiB.',
        );
      }
      final result = _DigestSink();
      final whole = sha256.startChunkedConversion(result);
      final pieces = <String>[];
      var remaining = size;
      while (remaining > 0) {
        final count = remaining < GroupFileManifest.pieceSize
            ? remaining
            : GroupFileManifest.pieceSize;
        final bytes = await file.read(count);
        if (bytes.length != count) {
          throw const FormatException('Group file changed while hashing.');
        }
        whole.add(bytes);
        pieces.add(sha256.convert(bytes).toString());
        remaining -= count;
      }
      if (await file.length() != size) {
        throw const FormatException('Group file changed while hashing.');
      }
      whole.close();
      return GroupFileManifest(
        fileName: fileName,
        mimeType: mimeType,
        caption: caption,
        sizeBytes: size,
        fileHash: result.value!.toString(),
        pieceHashes: pieces,
        voiceMetadata: metadataPayload == null
            ? null
            : VoiceMessageMetadata.fromJson(
                Map<String, dynamic>.from(metadataPayload),
              ),
      );
    } finally {
      await file.close();
    }
  });
}

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}
