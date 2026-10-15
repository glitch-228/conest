import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:conest/src/group_call/group_call_crypto.dart';
import 'package:conest/src/group_call/group_call_models.dart';
import 'support/fake_call_network.dart';

void main() {
  test(
    'cipher drops early capture while its initial tag is being prepared',
    () async {
      final net = FakeCallNetwork();
      final signer = await net.add('p0');
      await net.add('p1');
      addTearDown(net.dispose);
      final cipher = GroupCallCipher(
        groupId: 'group',
        callId: 'call',
        localDeviceId: 'p0',
        sign: signer.service.sign,
        verify: signer.service.verify,
        now: () => net.time,
      );
      addTearDown(cipher.close);
      final key = GroupCallCipher.randomKey();
      final roster = [
        const GroupCallParticipant('p0', 0),
        const GroupCallParticipant('p1', 1),
      ];
      final preparing = cipher.install(1, key, roster);
      await expectLater(
        cipher.encrypt(Uint8List.fromList([1])),
        completion(isNull),
      );
      await preparing;
      final frame = await cipher.encrypt(Uint8List.fromList([2]));
      expect(frame, isNotNull);
      expect((await cipher.decrypt(frame!))!.payload, [2]);
    },
  );
}
