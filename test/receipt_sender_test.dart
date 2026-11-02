import 'dart:async';

import 'package:conest/src/receipt_sender.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a run that hangs stops holding a place after a while', () async {
    final queue = ReceiptSendQueue(
      maxConcurrent: 2,
      stallAfter: const Duration(milliseconds: 50),
    );
    final hung = Completer<void>();
    addTearDown(() {
      if (!hung.isCompleted) hung.complete();
    });
    queue.schedule('dead-1', () => hung.future);
    queue.schedule('dead-2', () => hung.future);
    var ran = false;
    queue.schedule('live', () async => ran = true);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(ran, isFalse, reason: 'both places are taken for now');
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(ran, isTrue, reason: 'the dead routes still held every place');
  });

  test('an urgent run starts at once while every place is taken', () async {
    final queue = ReceiptSendQueue(
      maxConcurrent: 1,
      stallAfter: const Duration(minutes: 5),
    );
    final hung = Completer<void>();
    addTearDown(() {
      if (!hung.isCompleted) hung.complete();
    });
    queue.schedule('bulk', () => hung.future);
    var bulkWaiting = false;
    var urgent = false;
    queue.schedule('other', () async => bulkWaiting = true);
    queue.schedule('call', () async => urgent = true, urgent: true);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(urgent, isTrue, reason: 'the call signal waited behind bulk');
    expect(bulkWaiting, isFalse);
  });

  test('a key scheduled while it runs runs once more, and close drops what '
      'waits', () async {
    final queue = ReceiptSendQueue(maxConcurrent: 1);
    final gate = Completer<void>();
    var runs = 0;
    queue.schedule('a', () async {
      runs++;
      if (runs == 1) await gate.future;
    });
    queue.schedule('a', () async {});
    var waited = false;
    queue.schedule('b', () async => waited = true);
    queue.close();
    gate.complete();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(runs, 1, reason: 'a run was queued again after close');
    expect(waited, isFalse);
    expect(queue.isIdle, isTrue);
  });

  test('the second schedule of a running key runs after it', () async {
    final queue = ReceiptSendQueue(maxConcurrent: 1);
    final gate = Completer<void>();
    final order = <int>[];
    queue.schedule('a', () async {
      order.add(1);
      await gate.future;
    });
    queue.schedule('a', () async => order.add(2));
    gate.complete();
    await queue.whenIdle();
    expect(order, [1, 1]);
  });
}
