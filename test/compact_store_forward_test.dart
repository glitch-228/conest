import 'dart:typed_data';

import 'package:conest/src/compact_store_forward.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime.utc(2026, 8, 15, 12);

  CompactStoreForwardEnvelope envelope({String id = 'message-1'}) =>
      CompactStoreForwardEnvelope(
        messageId: id,
        senderDeviceId: 'alice',
        recipientDeviceId: 'bob',
        createdAt: now,
        expiresAt: now.add(const Duration(hours: 1)),
        payload: Uint8List.fromList([1, 2, 3, 4]),
      );

  test('compact envelope round trips and detects corruption', () {
    final encoded = envelope().encode();
    final decoded = CompactStoreForwardEnvelope.decode(encoded);
    expect(decoded.messageId, 'message-1');
    expect(decoded.payload, [1, 2, 3, 4]);

    encoded[encoded.length - 5] ^= 1;
    expect(
      () => CompactStoreForwardEnvelope.decode(encoded),
      throwsFormatException,
    );
  });

  test('replay window rejects duplicates and expired data', () {
    final window = CompactReplayWindow();
    expect(window.register(envelope(), now), isTrue);
    expect(window.register(envelope(), now), isFalse);
    expect(
      window.register(envelope(id: 'late'), now.add(const Duration(hours: 2))),
      isFalse,
    );
  });

  test('courier is opt-in, trusted-only, quota bounded, and hop bounded', () {
    final queue = BoundedCourierQueue(
      maximumItems: 1,
      maximumBytes: 4096,
      trustedPeerDeviceIds: {'bob'},
    );
    expect(
      () => queue.enqueue(
        envelope: envelope(),
        sourcePeerDeviceId: 'alice',
        sourceIsLocal: true,
        now: now,
      ),
      throwsStateError,
    );
    queue.enabled = true;
    queue.enqueue(
      envelope: envelope(),
      sourcePeerDeviceId: 'alice',
      sourceIsLocal: true,
      now: now,
    );
    expect(queue.items.single.envelope.hopCount, 1);
    expect(
      () => queue.enqueue(
        envelope: envelope(id: 'message-2'),
        sourcePeerDeviceId: 'alice',
        sourceIsLocal: true,
        now: now,
      ),
      throwsStateError,
    );
  });
}
