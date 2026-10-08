import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:conest/src/nostr/event.dart';
import 'package:conest/src/nostr/nip17.dart';
import 'package:conest/src/nostr/nip44.dart';
import 'package:conest/src/nostr/secp256k1.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Uint8List key(int seed) =>
      Uint8List.fromList(List.generate(32, (i) => (i * 7 + seed) % 251 + 1));
  final alice = key(1);
  final bob = key(2);
  final carol = key(3);
  String pub(Uint8List secret) => hexEncode(Secp256k1.publicKey(secret));
  final now = DateTime.utc(2026, 10, 8, 12);

  test('a message is wrapped for each recipient and the author', () {
    final wraps = Nip17.wrap(
      secretKey: alice,
      recipients: [pub(bob), pub(carol)],
      content: 'hello both',
      subject: 'Plans',
      now: now,
      random: Random(1),
    );
    expect(wraps.map((w) => w.$1).toSet(), {pub(bob), pub(carol), pub(alice)});
    for (final (recipient, wrap) in wraps) {
      expect(wrap.kind, NostrKind.giftWrap);
      expect(wrap.isValid, isTrue);
      // Relays see neither the author nor when it was written.
      expect(wrap.pubkey, isNot(pub(alice)));
      expect(wrap.tag('p'), recipient);
      expect(
        wrap.createdAt,
        lessThanOrEqualTo(now.millisecondsSinceEpoch ~/ 1000),
      );
    }
    final forBob = wraps.singleWhere((w) => w.$1 == pub(bob)).$2;
    final read = Nip17.unwrap(forBob, bob)!;
    expect(read.content, 'hello both');
    expect(read.author, pub(alice));
    expect(read.recipients, [pub(bob), pub(carol)]);
    expect(read.subject, 'Plans');
    expect(read.participants, {pub(alice), pub(bob), pub(carol)});
    expect(read.createdAt, now.millisecondsSinceEpoch ~/ 1000);
    // Every copy is the same message.
    final forCarol = wraps.singleWhere((w) => w.$1 == pub(carol)).$2;
    expect(Nip17.unwrap(forCarol, carol)!.id, read.id);
    // Not for Carol's key, Bob's copy reads as nothing.
    expect(Nip17.unwrap(forBob, carol), isNull);
  });

  test('a rumor that claims another author is refused', () {
    // Mallory seals a rumor saying Alice wrote it.
    final mallory = key(9);
    final rumor = jsonEncode({
      'id': 'x',
      'pubkey': pub(alice),
      'created_at': 1,
      'kind': Nip17Kind.chatMessage,
      'tags': [
        ['p', pub(bob)],
      ],
      'content': 'it is me, Alice',
    });
    final seal = NostrEvent.sign(
      secretKey: mallory,
      kind: Nip17Kind.seal,
      tags: const [],
      content: Nip44.encrypt(
        Uint8List.fromList(utf8.encode(rumor)),
        Nip44.conversationKey(mallory, hexDecode(pub(bob))!),
      ),
      createdAt: 1,
    );
    final ephemeral = key(10);
    final wrap = NostrEvent.sign(
      secretKey: ephemeral,
      kind: NostrKind.giftWrap,
      tags: [
        ['p', pub(bob)],
      ],
      content: Nip44.encrypt(
        Uint8List.fromList(utf8.encode(jsonEncode(seal.toJson()))),
        Nip44.conversationKey(ephemeral, hexDecode(pub(bob))!),
      ),
      createdAt: 1,
    );
    expect(Nip17.unwrap(wrap, bob), isNull);
  });

  test('DM relay lists are signed and read back', () {
    final list = Nip17.dmRelayList(alice, [
      Uri.parse('wss://inbox.example'),
      Uri.parse('wss://two.example'),
    ], now);
    expect(list.kind, Nip17Kind.dmRelays);
    expect(Nip17.relaysFrom(list).map((u) => u.host), [
      'inbox.example',
      'two.example',
    ]);
  });
}
