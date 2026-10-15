import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'support/fake_call_network.dart';

void main() {
  test(
    'admitted listener replaces a dead coordinator while its rotated key is pending',
    () async {
      final net = FakeCallNetwork();
      for (final id in ['p0', 'p1', 'p2']) {
        await net.add(id);
      }
      addTearDown(net.dispose);
      await net.connect(net.peers.keys);
      final survivor = net.peers['p1']!;
      net.droppedSignals.add(('p0', 'p1', 'key'));
      await net.peers['p2']!.service.leave();
      await net.flush();
      expect(survivor.service.active!.connected, false);
      expect(
        survivor.service.active!.participants.any((p) => p.deviceId == 'p1'),
        true,
      );
      net.dropped.add('p0');
      await net.advance(const Duration(seconds: 2));
      expect(survivor.service.active!.coordinator, 'p1');
      expect(survivor.service.active!.connected, true);
      await net.peers['p2']!.service.join('group');
      await net.flush();
      await survivor.service.sendAudio(Uint8List.fromList([9]));
      await net.flush();
      expect(net.peers['p2']!.media.played.single.$3, [9]);
    },
  );
}
