part of 'messenger_controller_test.dart';

/// Own-device sync, phase P0 (M33): the policy is enforced on every path,
/// and the fakes the later phases lean on are as strict as the real thing.
void _ownDeviceSyncP0ControllerTests() {
  group('strict fakes for own-device sync', () {
    Uint8List frame(int length) => Uint8List(length);

    test('the carrier fake refuses a frame over its size limit', () {
      final network = _FakeCarrierNetwork()..maxFrameBytes = 100;
      network.deliver('a', 'b', frame(100));
      expect(network.frames, hasLength(1));
      expect(
        () => network.deliver('a', 'b', frame(101)),
        throwsA(isA<_CarrierRefused>()),
      );
      expect(network.frames, hasLength(1), reason: 'nothing was accepted');
      expect(network.refusedOversize, 1);
    });

    test('the carrier fake accepts and loses the frames it is told to', () {
      final network = _FakeCarrierNetwork()..loseFrames.addAll({2, 3});
      for (var i = 0; i < 4; i++) {
        network.deliver('a', 'b', frame(i + 1));
      }
      expect(network.frames, hasLength(4), reason: 'all four were accepted');
      expect(network.lost, 2);
      expect(network.delivered.map((f) => f.$3.length), [1, 4]);
    });

    test('the carrier fake hands frames over last to first when told to', () {
      final network = _FakeCarrierNetwork()..reorderEvery = 3;
      for (var i = 1; i <= 4; i++) {
        network.deliver('a', 'b', frame(i));
      }
      // The first three came out reversed; the fourth is still held back.
      expect(network.delivered.map((f) => f.$3.length), [3, 2, 1]);
      network.flushReordered();
      expect(network.delivered.map((f) => f.$3.length), [3, 2, 1, 4]);
    });

    test('the carrier fake slows a sender down and says when to retry', () {
      var now = DateTime.utc(2026, 11, 7, 12);
      final network = _FakeCarrierNetwork()
        ..rateLimitFrames = 2
        ..rateLimitWindow = const Duration(minutes: 1)
        ..clock = () => now;
      network.deliver('a', 'b', frame(1));
      now = now.add(const Duration(seconds: 20));
      network.deliver('a', 'b', frame(1));
      // Another sender has its own budget.
      network.deliver('c', 'b', frame(1));
      _CarrierRefused? refused;
      try {
        network.deliver('a', 'b', frame(1));
      } on _CarrierRefused catch (error) {
        refused = error;
      }
      expect(refused, isNotNull);
      expect(refused!.retryAfter, const Duration(seconds: 40));
      expect(network.refusedRate, 1);
      now = now.add(const Duration(seconds: 41));
      network.deliver('a', 'b', frame(1));
      expect(network.frames, hasLength(4));
    });

    test('the defaults leave every frame as it was', () {
      final network = _FakeCarrierNetwork();
      for (var i = 0; i < 5; i++) {
        network.deliver('a', 'b', frame(1000 + i));
      }
      expect(network.frames, hasLength(5));
      expect(network.delivered, hasLength(5));
      expect(network.lost + network.refusedOversize + network.refusedRate, 0);
    });
  });
}
