import 'dart:io';
import 'dart:typed_data';
import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:conest/src/attachment_file_io.dart';
import 'package:conest/src/staged_attachment.dart';

void main() {
  test(
    'background spool and hash preserve exact bytes and report progress',
    () async {
      final root = await Directory.systemTemp.createTemp('conest-file-worker-');
      addTearDown(() => root.delete(recursive: true));
      final bytes = Uint8List.fromList(
        List<int>.generate(4 * 1024 * 1024 + 3, (i) => i % 251),
      );
      final target = File('${root.path}/copy.bin');
      final progress = <int>[];
      final digest = await copyAndHashAttachment(
        StagedAttachment(
          id: 'source',
          fileName: 'source.bin',
          mimeType: 'application/octet-stream',
          sizeBytes: bytes.length,
          bytes: bytes,
        ),
        target.path,
        onProgress: progress.add,
      );
      expect(await target.readAsBytes(), bytes);
      expect(digest.sizeBytes, bytes.length);
      expect(
        digest.sha256Base64,
        base64Encode(crypto.sha256.convert(bytes).bytes),
      );
      expect(progress, contains(bytes.length));
      expect(await hashAttachmentFile(target.path), digest);
    },
  );

  test('background spool rejects a changing source size', () async {
    final root = await Directory.systemTemp.createTemp('conest-file-worker-');
    addTearDown(() => root.delete(recursive: true));
    final source = File('${root.path}/source.bin');
    await source.writeAsBytes([1, 2, 3]);
    await expectLater(
      copyAndHashAttachment(
        StagedAttachment(
          id: 'source',
          fileName: 'source.bin',
          mimeType: 'application/octet-stream',
          sizeBytes: 4,
          filePath: source.path,
        ),
        '${root.path}/copy.bin',
      ),
      throwsFormatException,
    );
  });
}
