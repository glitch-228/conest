import 'package:conest/src/group_file_manifest.dart';
import 'package:conest/src/group_file_scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

GroupFileManifest _manifest(int pieces) => GroupFileManifest(
  fileName: 'file.bin',
  mimeType: 'application/octet-stream',
  sizeBytes: pieces * GroupFileManifest.pieceSize,
  fileHash: 'a' * 64,
  pieceHashes: List.filled(pieces, 'b' * 64),
);

/// Group parity for M27: a group file's pieces already come from every
/// authorized member device that holds them, whoever it belongs to. A
/// device of the account that is a member of the group is such a provider,
/// next to the sender (nothing in the scheduler singles out the sender).
void main() {
  final t0 = DateTime.utc(2026);
  bool allowAll(String _, bool _) => true;

  test('a member device of the same account serves pieces next to the '
      'sender, by measured speed', () {
    final scheduler = GroupFileScheduler(_manifest(6));
    scheduler.updateProvider('sender', [0, 1, 2, 3, 4, 5], lan: false);
    scheduler.updateProvider('my-laptop', [0, 1, 2, 3, 4, 5], lan: false);
    final first = scheduler.reserve(t0, allowed: allowAll);
    expect(first.map((r) => r.peer).toSet(), {'sender', 'my-laptop'});
    final onSender = first.firstWhere((r) => r.peer == 'sender');
    final onLaptop = first.firstWhere((r) => r.peer == 'my-laptop');
    scheduler.markDurable(onSender, now: t0.add(const Duration(seconds: 30)));
    scheduler.markDurable(onLaptop, now: t0.add(const Duration(seconds: 1)));
    expect(
      scheduler.speedOf('my-laptop'),
      greaterThan(scheduler.speedOf('sender')),
    );
  });

  test('the sender gone: the own device alone completes the file', () {
    final scheduler = GroupFileScheduler(_manifest(3));
    scheduler.updateProvider('sender', [0, 1, 2], lan: false);
    scheduler.updateProvider('my-laptop', [0, 1, 2], lan: false);
    scheduler.removeProvider('sender');
    var now = t0;
    while (!scheduler.complete) {
      final batch = scheduler.reserve(now, allowed: allowAll);
      expect(batch, isNotEmpty);
      expect(batch.every((r) => r.peer == 'my-laptop'), isTrue);
      for (final request in batch) {
        now = now.add(const Duration(seconds: 1));
        expect(scheduler.markDurable(request, now: now), isTrue);
      }
    }
  });

  test('a device that is not authorized is not asked, own or not', () {
    final scheduler = GroupFileScheduler(_manifest(2));
    scheduler.updateProvider('my-laptop', [0, 1], lan: false);
    final batch = scheduler.reserve(
      t0,
      allowed: (peer, lan) => peer != 'my-laptop',
    );
    expect(batch, isEmpty);
  });
}
