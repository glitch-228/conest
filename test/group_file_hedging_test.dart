import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:conest/src/group_file_download.dart';
import 'package:conest/src/group_file_manifest.dart';
import 'package:conest/src/group_file_scheduler.dart';
import 'package:conest/src/group_file_store.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

GroupFileManifest _manifest(int pieces) => GroupFileManifest(
  fileName: 'file.bin',
  mimeType: 'application/octet-stream',
  sizeBytes: pieces * GroupFileManifest.pieceSize,
  fileHash: 'a' * 64,
  pieceHashes: List.filled(pieces, 'b' * 64),
);

void main() {
  final t0 = DateTime.utc(2026);
  bool allowAll(String _, bool _) => true;

  test('a measured slow provider is passed over for a fast one', () {
    final scheduler = GroupFileScheduler(_manifest(4));
    scheduler.updateProvider('a', [0, 1, 2, 3], lan: false);
    scheduler.updateProvider('b', [0, 1, 2, 3], lan: false);
    // Learn: a is slow, b is fast, each on one piece.
    final probe = scheduler.reserve(t0, allowed: allowAll);
    final onA = probe.firstWhere((r) => r.peer == 'a');
    final onB = probe.firstWhere((r) => r.peer == 'b');
    scheduler.markDurable(onA, now: t0.add(const Duration(seconds: 40)));
    scheduler.markDurable(onB, now: t0.add(const Duration(seconds: 1)));
    for (final rest in probe.where((r) => r != onA && r != onB)) {
      scheduler.failed(rest);
    }
    expect(scheduler.speedOf('b'), greaterThan(scheduler.speedOf('a')));
    final next = scheduler.reserve(
      t0.add(const Duration(minutes: 5)),
      allowed: allowAll,
    );
    expect(next, isNotEmpty);
    expect(next.first.peer, 'b');
  });

  test('a late piece is also asked of another provider; first one wins', () {
    final scheduler = GroupFileScheduler(_manifest(1));
    scheduler.updateProvider('a', [0], lan: false);
    scheduler.updateProvider('b', [0], lan: false);
    final primary = scheduler.reserve(t0, allowed: allowAll).single;
    expect(primary.peer, 'a');
    final hedge = scheduler.hedge(primary, t0, allowed: allowAll);
    expect(hedge, isNotNull);
    expect(hedge!.peer, 'b');
    expect(scheduler.hedge(primary, t0, allowed: allowAll), isNull);
    expect(scheduler.markDurable(hedge), isTrue);
    // The slower request is no longer wanted.
    expect(scheduler.isCurrent(primary), isFalse);
    expect(scheduler.markDurable(primary), isFalse);
    expect(scheduler.complete, isTrue);
  });

  test('a failed primary hands its piece to the hedge', () {
    final scheduler = GroupFileScheduler(_manifest(1));
    scheduler.updateProvider('a', [0], lan: false);
    scheduler.updateProvider('b', [0], lan: false);
    final primary = scheduler.reserve(t0, allowed: allowAll).single;
    final hedge = scheduler.hedge(primary, t0, allowed: allowAll)!;
    scheduler.failed(primary);
    expect(scheduler.isCurrent(hedge), isTrue);
    expect(scheduler.markDurable(hedge), isTrue);
  });

  test('hedging stays within its budget', () {
    final scheduler = GroupFileScheduler(_manifest(8));
    for (final peer in ['a', 'b', 'c']) {
      scheduler.updateProvider(peer, [0, 1, 2, 3, 4, 5, 6, 7], lan: false);
    }
    final first = scheduler.reserve(t0, allowed: allowAll);
    // The first hedge is free, a second one over the share is refused.
    expect(scheduler.hedge(first[0], t0, allowed: allowAll), isNotNull);
    expect(scheduler.hedge(first[1], t0, allowed: allowAll), isNull);
  });

  test('a hedge needs a different provider that has the piece', () {
    final scheduler = GroupFileScheduler(_manifest(1));
    scheduler.updateProvider('a', [0], lan: false);
    final primary = scheduler.reserve(t0, allowed: allowAll).single;
    expect(scheduler.hedge(primary, t0, allowed: allowAll), isNull);
    scheduler.updateProvider('b', [0], lan: false);
    expect(scheduler.hedge(primary, t0, allowed: (p, _) => p == 'a'), isNull);
  });

  test('a download finishes through the second provider when the first '
      'is stuck, and waits for the stuck request before it ends', () async {
    final root = await Directory.systemTemp.createTemp('group-hedge-');
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
      final stuck = Completer<Uint8List>();
      final requested = <String>[];
      final download = GroupFileDownload(
        store: GroupFileStore(root: root, manifest: description),
        allowed: (_, _) => true,
        authorize: (_) async => true,
        hedgeMinDelay: const Duration(milliseconds: 50),
        fetch: (request) {
          requested.add(request.peer);
          return request.peer == 'a' ? stuck.future : Future.value(bytes);
        },
      );
      download.scheduler.updateProvider('a', [0], lan: false);
      download.scheduler.updateProvider('b', [0], lan: false);
      var ended = false;
      final running = download.resume().whenComplete(() => ended = true);
      for (
        var i = 0;
        i < 200 && download.state != GroupFileDownloadState.complete;
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(requested, ['a', 'b']);
      expect(download.scheduler.complete, isTrue);
      expect(download.state, GroupFileDownloadState.complete);
      // The stuck request is still out: the session is not over.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(ended, isFalse);
      stuck.complete(Uint8List(3));
      await running;
      expect(ended, isTrue);
      expect(await download.completedFile!.readAsBytes(), bytes);
    } finally {
      await root.delete(recursive: true);
    }
  });
}
