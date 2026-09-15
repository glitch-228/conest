import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:conest/src/group_file_manifest.dart';
import 'package:conest/src/group_file_scheduler.dart';
import 'package:conest/src/group_file_store.dart';
import 'package:conest/src/group_file_download.dart';

void main() {
  test(
    'download replaces corrupt provider and resumes durable pieces',
    () async {
      final root = await Directory.systemTemp.createTemp('group-download-');
      try {
        final bytes = Uint8List.fromList([1, 2, 3]);
        final hash = sha256.convert(bytes).toString();
        final description = GroupFileManifest(
          fileName: 'data',
          mimeType: 'application/octet-stream',
          sizeBytes: 3,
          fileHash: hash,
          pieceHashes: [hash],
        );
        final requested = <String>[];
        final download = GroupFileDownload(
          store: GroupFileStore(root: root, manifest: description),
          allowed: (_, _) => true,
          authorize: (_) async => true,
          fetch: (request) async {
            requested.add(request.peer);
            return request.peer == 'bad' ? Uint8List(3) : bytes;
          },
        );
        download.scheduler.updateProvider('bad', [0], lan: true);
        download.scheduler.updateProvider('good', [0], lan: false);
        await download.resume();
        expect(requested, ['bad', 'good']);
        expect(download.state, GroupFileDownloadState.complete);
        expect(download.verifiedBytes, 3);
        final restarted = GroupFileDownload(
          store: GroupFileStore(root: root, manifest: description),
          allowed: (_, _) => true,
          authorize: (_) async => true,
          fetch: (_) async => throw StateError('Already cached'),
        );
        await restarted.resume();
        expect(restarted.state, GroupFileDownloadState.complete);
        expect(await restarted.completedFile!.readAsBytes(), bytes);
      } finally {
        await root.delete(recursive: true);
      }
    },
  );

  test(
    'in-flight removal prevents storage and leaves a waiting download',
    () async {
      final root = await Directory.systemTemp.createTemp('group-revocation-');
      try {
        final bytes = Uint8List.fromList([1]);
        final hash = sha256.convert(bytes).toString();
        final store = GroupFileStore(
          root: root,
          manifest: GroupFileManifest(
            fileName: 'data',
            mimeType: 'application/octet-stream',
            sizeBytes: 1,
            fileHash: hash,
            pieceHashes: [hash],
          ),
        );
        var authorized = true;
        final download = GroupFileDownload(
          store: store,
          allowed: (_, _) => true,
          authorize: (_) async => authorized,
          fetch: (_) async {
            authorized = false;
            return bytes;
          },
        );
        download.scheduler.updateProvider('peer', [0], lan: true);
        await download.resume();
        expect(download.state, GroupFileDownloadState.waiting);
        expect(download.verifiedBytes, 0);
        expect(await store.recover(), isEmpty);
      } finally {
        await root.delete(recursive: true);
      }
    },
  );

  test(
    'partial cache recovers verified bytes, rejects corruption and assembles',
    () async {
      final root = await Directory.systemTemp.createTemp('group-pieces-');
      try {
        final bytes = Uint8List.fromList([1, 2, 3, 4]);
        final hash = sha256.convert(bytes).toString();
        final description = GroupFileManifest(
          fileName: 'file.bin',
          mimeType: 'application/octet-stream',
          sizeBytes: bytes.length,
          fileHash: hash,
          pieceHashes: [hash],
        );
        final store = GroupFileStore(root: root, manifest: description);
        expect(await store.recover(), isEmpty);
        await expectLater(
          store.writePiece(0, Uint8List(4)),
          throwsFormatException,
        );
        await store.writePiece(0, bytes);
        final restarted = GroupFileStore(root: root, manifest: description);
        expect(await restarted.recover(), {0});
        expect(await restarted.readPiece(0), bytes);
        expect(await (await restarted.assemble()).readAsBytes(), bytes);
        await File(
          '${store.directory.path}/0.piece',
        ).writeAsBytes([4, 3, 2, 1]);
        expect(await restarted.recover(), isEmpty);
        expect(await restarted.readPiece(0), isNull);
        await expectLater(restarted.assemble(), throwsStateError);
        await restarted.writePiece(0, bytes);
        expect(await restarted.recover(), {0});
        final inconsistent = GroupFileStore(
          root: root,
          manifest: GroupFileManifest(
            fileName: 'file.bin',
            mimeType: 'application/octet-stream',
            sizeBytes: 4,
            fileHash: 'a' * 64,
            pieceHashes: [hash],
          ),
        );
        await inconsistent.writePiece(0, bytes);
        await expectLater(inconsistent.assemble(), throwsFormatException);
        expect(
          await File('${inconsistent.directory.path}/complete').exists(),
          isFalse,
        );
      } finally {
        await root.delete(recursive: true);
      }
    },
  );

  GroupFileManifest manifest(int size) => GroupFileManifest(
    fileName: 'file.bin',
    mimeType: 'application/octet-stream',
    sizeBytes: size,
    fileHash: 'a' * 64,
    pieceHashes: List.filled(
      (size + GroupFileManifest.pieceSize - 1) ~/ GroupFileManifest.pieceSize,
      'b' * 64,
    ),
  );

  test(
    'one-pass file hashing verifies pieces and detects changed content',
    () async {
      final root = await Directory.systemTemp.createTemp('group-file-');
      try {
        final bytes = Uint8List(GroupFileManifest.pieceSize + 7)..[0] = 42;
        final file = await File('${root.path}/data').writeAsBytes(bytes);
        final result = await hashGroupFile(
          path: file.path,
          fileName: 'data.bin',
          mimeType: 'application/octet-stream',
        );
        expect(result.fileHash, sha256.convert(bytes).toString());
        expect(result.pieceHashes.length, 2);
        expect(
          result.verifyPiece(1, bytes.sublist(GroupFileManifest.pieceSize)),
          isTrue,
        );
        expect(result.verifyPiece(1, List.filled(7, 1)), isFalse);
        expect(
          GroupFileManifest.fromPayload(result.toPayload()).fileHash,
          result.fileHash,
        );
      } finally {
        await root.delete(recursive: true);
      }
    },
  );

  test('strict online auto-download boundary and unsafe manifests', () {
    expect(
      manifest(15 * 1024 * 1024 - 1).automaticallyDownload(lan: false),
      isTrue,
    );
    expect(
      manifest(15 * 1024 * 1024).automaticallyDownload(lan: false),
      isFalse,
    );
    expect(
      manifest(GroupFileManifest.maxSize).automaticallyDownload(lan: true),
      isTrue,
    );
    expect(
      () => GroupFileManifest.fromPayload({
        ...manifest(1).toPayload(),
        'fileName': '../file',
      }),
      throwsFormatException,
    );
    expect(
      () => manifest(GroupFileManifest.maxSize + 1),
      throwsFormatException,
    );
  });

  test('bounded scarce-first reservations and unique durable progress', () {
    final scheduler = GroupFileScheduler(
      manifest(8 * GroupFileManifest.pieceSize),
    );
    scheduler.updateProvider('a', [0, 1, 2, 3, 4, 5, 6, 7], lan: true);
    scheduler.updateProvider('b', [1, 2, 3, 4, 5, 6, 7], lan: true);
    scheduler.updateProvider('c', [1, 2, 3, 4, 5, 6, 7], lan: true);
    scheduler.updateProvider('d', [1, 2, 3, 4, 5, 6, 7], lan: true);
    final requests = scheduler.reserve(
      DateTime.utc(2026),
      allowed: (_, _) => true,
    );
    expect(requests.length, 4);
    expect(requests.first.piece, 0);
    expect(requests.map((r) => r.peer).toSet().length, lessThanOrEqualTo(3));
    expect(
      scheduler.reserve(DateTime.utc(2026), allowed: (_, _) => true),
      isEmpty,
    );
    expect(scheduler.markDurable(requests.first), isTrue);
    expect(scheduler.markDurable(requests.first), isFalse);
    expect(scheduler.verifiedBytes, GroupFileManifest.pieceSize);
  });

  test(
    'stalls release reservations, late replies cannot complete replacements',
    () {
      final scheduler = GroupFileScheduler(manifest(1));
      scheduler.updateProvider('lan', [0], lan: true);
      scheduler.updateProvider('online', [0], lan: false);
      final now = DateTime.utc(2026);
      final first = scheduler.reserve(now, allowed: (_, _) => true).single;
      expect(first.peer, 'lan');
      final replacement = scheduler
          .reserve(
            now.add(const Duration(seconds: 16)),
            allowed: (_, _) => true,
          )
          .single;
      expect(replacement.peer, 'online');
      expect(scheduler.markDurable(first), isFalse);
      scheduler.removeProvider('online');
      expect(scheduler.reserve(now, allowed: (_, _) => true), isEmpty);
      scheduler.updateProvider('returned', [0], lan: false);
      expect(scheduler.reserve(now, allowed: (_, lan) => lan), isEmpty);
      scheduler.restoreVerified([0, 0]);
      expect(scheduler.complete, isTrue);
      expect(scheduler.verifiedBytes, 1);
    },
  );
}
