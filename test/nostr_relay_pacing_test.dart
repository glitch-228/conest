import 'dart:async';

import 'package:conest/src/nostr/event.dart';
import 'package:conest/src/nostr/relay.dart';
import 'package:conest/src/nostr/secp256k1.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_nostr_relay.dart';

/// Records when each event leaves for the relay.
class _TimedSocket implements NostrSocket {
  _TimedSocket(this._inner, this.sentAt);

  final NostrSocket _inner;
  final List<DateTime> sentAt;

  @override
  Stream<String> get messages => _inner.messages;

  @override
  void send(String message) {
    if (message.startsWith('["EVENT"')) sentAt.add(DateTime.now());
    _inner.send(message);
  }

  @override
  Future<void> close() => _inner.close();
}

NostrEvent _event(int index) => NostrEvent.sign(
  secretKey: Secp256k1.generateSecretKey(),
  kind: NostrKind.giftWrap,
  tags: const [],
  content: 'event $index',
  createdAt: 1700000000 + index,
);

void main() {
  test('a burst of events leaves a relay one by one', () async {
    final relays = FakeNostrRelays()..relay('wss://pace.example');
    final sentAt = <DateTime>[];
    final relay = NostrRelay(
      url: Uri.parse('wss://pace.example'),
      authKey: Secp256k1.generateSecretKey,
      connector: (url) async => _TimedSocket(await relays.connect(url), sentAt),
      publishSpacing: const Duration(milliseconds: 80),
    )..start();
    addTearDown(relay.stop);
    await Future.wait([for (var i = 0; i < 6; i++) relay.publish(_event(i))]);
    expect(sentAt, hasLength(6));
    // Turns are scheduled from one clock: the last event leaves five gaps
    // after the first, whatever the jitter between two of them.
    expect(
      sentAt.last.difference(sentAt.first),
      greaterThanOrEqualTo(const Duration(milliseconds: 5 * 80 - 150)),
    );
  });

  test('a relay that pushes back gets longer gaps, then recovers', () async {
    final relays = FakeNostrRelays();
    final fake = relays.relay('wss://pace.example');
    final sentAt = <DateTime>[];
    final relay = NostrRelay(
      url: Uri.parse('wss://pace.example'),
      authKey: Secp256k1.generateSecretKey,
      connector: (url) async => _TimedSocket(await relays.connect(url), sentAt),
      publishSpacing: const Duration(milliseconds: 40),
    )..start();
    addTearDown(relay.stop);
    fake.rejectWith = 'rate-limited: slow down';
    await expectLater(relay.publish(_event(0)), throwsA(isA<Object>()));
    fake.rejectWith = null;
    await relay.publish(_event(1));
    await relay.publish(_event(2));
    expect(
      sentAt[2].difference(sentAt[1]),
      greaterThanOrEqualTo(const Duration(milliseconds: 55)),
      reason: 'after a rate limit the gap doubles',
    );
  });

  test('events that cannot leave in time are refused, not queued', () async {
    final relays = FakeNostrRelays()..relay('wss://pace.example');
    final relay = NostrRelay(
      url: Uri.parse('wss://pace.example'),
      authKey: Secp256k1.generateSecretKey,
      connector: relays.connect,
      publishTimeout: const Duration(milliseconds: 300),
      publishSpacing: const Duration(milliseconds: 100),
    )..start();
    addTearDown(relay.stop);
    final results = await Future.wait([
      for (var i = 0; i < 8; i++)
        relay
            .publish(_event(i))
            .then<Object?>((_) => 'sent', onError: (Object e) => e),
    ]);
    final refused = results.whereType<NostrRelayException>().toList();
    expect(refused, isNotEmpty);
    expect(refused.every((error) => error.rateLimited), isTrue);
    expect(results.where((r) => r == 'sent'), isNotEmpty);
  });
}
