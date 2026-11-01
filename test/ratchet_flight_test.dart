import 'dart:async';

import 'package:conest/src/ratchet_flight.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'an envelope waiting to be sent holds newer ones back past the window',
    () async {
      final gate = RatchetFlightGate(
        window: 3,
        holdMax: const Duration(seconds: 5),
      );
      await gate.enter('p', 'old');
      await gate.enter('p', 'n1');
      gate.leave('p', 'n1');
      await gate.enter('p', 'n2');
      gate.leave('p', 'n2');
      var fourth = false;
      unawaited(gate.enter('p', 'n3').then((_) => fourth = true));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(fourth, isFalse, reason: 'the fourth got ahead of the oldest');
      gate.leave('p', 'old');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(fourth, isTrue);
      gate.close();
    },
  );

  test(
    'other peers are not held, and order is first come first served',
    () async {
      final gate = RatchetFlightGate(
        window: 1,
        holdMax: const Duration(seconds: 5),
      );
      await gate.enter('a', 'x');
      final order = <String>[];
      unawaited(gate.enter('a', 'y').then((_) => order.add('y')));
      unawaited(gate.enter('a', 'z').then((_) => order.add('z')));
      await gate.enter('b', 'other');
      gate.leave('a', 'x');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(order, ['y']);
      gate.leave('a', 'y');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(order, ['y', 'z']);
      gate.close();
    },
  );

  test(
    'one that is never handed over stops holding the rest after a while',
    () async {
      final gate = RatchetFlightGate(
        window: 1,
        holdMax: const Duration(milliseconds: 80),
      );
      await gate.enter('p', 'lost');
      var next = false;
      unawaited(gate.enter('p', 'next').then((_) => next = true));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(next, isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(next, isTrue, reason: 'a lost envelope stopped the peer for good');
      gate.close();
    },
  );

  test(
    'a change of direction waits for an unsent envelope of the old chain',
    () async {
      final gate = RatchetFlightGate(holdMax: const Duration(seconds: 5));
      await gate.enter('p', 'old');
      await gate.enter('p', 'same-chain');
      gate.noteReceived('p');
      var newer = false;
      unawaited(gate.enter('p', 'new-chain').then((_) => newer = true));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(newer, isFalse, reason: 'a new chain went ahead of the old one');
      gate.leave('p', 'old');
      gate.leave('p', 'same-chain');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(newer, isTrue);
      expect(gate.turnsOf('p'), 1);
      gate.close();
    },
  );
}
