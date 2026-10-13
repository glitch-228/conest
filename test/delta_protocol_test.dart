import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:conest/src/delta_chats.dart';
import 'package:conest/src/delta_protocol.dart';
import 'package:conest/src/email/delta_mail.dart';
import 'package:conest/src/email/pgp.dart';
import 'package:flutter_test/flutter_test.dart';

class Party {
  Party(this.protocol);

  final DeltaProtocol protocol;
  DeltaChats chats = const DeltaChats();

  String get fingerprint => protocol.fingerprint;
  String get addr => protocol.self;

  void apply(DeltaStep step) => chats = step.chats;
}

void main() {
  late Party alice;
  late Party bob;
  late Party carol;
  late Map<String, Party> byAddr;
  var clock = DateTime.utc(2026, 10, 13, 9);

  Future<Party> party(String name, int seed) async {
    final addr = '$name@example.org';
    return Party(
      DeltaProtocol(
        key: await PgpSecretKey.generate('<$addr>'),
        self: addr,
        selfName: name,
        tokens: DeltaTokens.create(Random(seed)),
        now: () => clock = clock.add(const Duration(seconds: 1)),
        random: Random(seed),
      ),
    );
  }

  /// Delivers [mails] and every answer, until nothing is left. Returns
  /// how many mails were delivered.
  Future<int> deliver(
    List<DeltaOutgoingMail> mails, {
    String Function(String mail)? tamper,
  }) async {
    final queue = [...mails];
    var delivered = 0;
    while (queue.isNotEmpty) {
      final mail = queue.removeAt(0);
      for (final to in mail.to) {
        final recipient = byAddr[to];
        if (recipient == null) continue;
        delivered++;
        final text = tamper == null ? mail.mail : tamper(mail.mail);
        final step = await recipient.protocol.receive(
          recipient.chats,
          Uint8List.fromList(utf8.encode(text)),
        );
        recipient.apply(step);
        queue.addAll(step.mails);
      }
    }
    return delivered;
  }

  Future<void> send(Party from, String chatKey, String text) async {
    final step = await from.protocol.send(from.chats, chatKey, text);
    from.apply(step);
    await deliver(step.mails);
  }

  Future<void> introduce(Party joiner, Party inviter) async {
    final invite = DeltaInvite.parse(inviter.protocol.invite.toLink())!;
    final step = await joiner.protocol.join(joiner.chats, invite);
    joiner.apply(step);
    await deliver(step.mails);
  }

  setUp(() async {
    alice = await party('alice', 1);
    bob = await party('bob', 2);
    carol = await party('carol', 3);
    byAddr = {
      for (final party in [alice, bob, carol]) party.addr: party,
    };
  });

  test('invite links read back, and Delta Chat\'s own form reads', () {
    final link = alice.protocol.invite.toLink();
    final parsed = DeltaInvite.parse(link)!;
    expect(parsed.fingerprint, alice.fingerprint);
    expect(parsed.addr, 'alice@example.org');
    expect(parsed.name, 'alice');
    expect(parsed.invitenumber, alice.protocol.tokens.invitenumber);
    expect(parsed.auth, alice.protocol.tokens.auth);

    final delta = DeltaInvite.parse(
      'https://i.delta.chat/#${'AB' * 20}&v=3&x=grp_ID-1&i=inv-1&s=auth_1'
      '&a=dora%40nine.testrun.org&n=Dora+D&g=Team+%C3%A9',
    )!;
    expect(delta.groupId, 'grp_ID-1');
    expect(delta.groupName, 'Team é');
    expect(delta.name, 'Dora D');
    expect(delta.invitenumber, 'inv-1');
    final openpgp = DeltaInvite.parse(
      'OPENPGP4FPR:${'cd' * 20}#a=e%40x.org&n=E&i=1&s=2',
    )!;
    expect(openpgp.fingerprint, 'CD' * 20);
    expect(
      DeltaInvite.parse('https://i.delta.chat/#short&a=x@y.org&s=1'),
      isNull,
    );
  });

  test(
    'Securejoin verifies both sides, then they chat with receipts',
    () async {
      await introduce(bob, alice);

      expect(alice.chats.peers[bob.fingerprint]?.verified, isTrue);
      expect(bob.chats.peers[alice.fingerprint]?.verified, isTrue);
      expect(alice.chats.chats[bob.fingerprint]?.kept, isTrue);
      expect(bob.chats.chats[alice.fingerprint]?.kept, isTrue);
      expect(bob.chats.joins, isEmpty);

      await send(bob, alice.fingerprint, 'Hi Alice');
      final atAlice = alice.chats.chats[bob.fingerprint]!.messages.single;
      expect(atAlice.text, 'Hi Alice');
      expect(atAlice.author, bob.fingerprint);
      expect(atAlice.wantsReceipt, isTrue);
      expect(alice.chats.chats[bob.fingerprint]!.unread, 1);

      await send(alice, bob.fingerprint, 'Hi Bob');
      expect(bob.chats.chats[alice.fingerprint]!.messages.last.text, 'Hi Bob');

      // Alice reads: Bob's message shows read.
      final read = await alice.protocol.markRead(alice.chats, bob.fingerprint);
      alice.apply(read);
      expect(read.mails, hasLength(1));
      await deliver(read.mails);
      final bobsOwn = bob.chats.chats[alice.fingerprint]!.messages.firstWhere(
        (message) => message.outgoing,
      );
      expect(bobsOwn.state, DeltaMessageState.read);
      expect(alice.chats.chats[bob.fingerprint]!.unread, 0);
    },
  );

  test('a wrong auth code gets nowhere', () async {
    final real = DeltaInvite.parse(alice.protocol.invite.toLink())!;
    final forged = DeltaInvite(
      fingerprint: real.fingerprint,
      addr: real.addr,
      invitenumber: real.invitenumber,
      auth: 'guessed',
    );
    final step = await bob.protocol.join(bob.chats, forged);
    bob.apply(step);
    await deliver(step.mails);
    expect(alice.chats.peers[bob.fingerprint]?.verified ?? false, isFalse);
    expect(alice.chats.chats, isEmpty);
  });

  test(
    'an answer signed by another key than the invite\'s is ignored',
    () async {
      // Mallory intercepts and answers as alice@ with her own key.
      final mallory = await party('mallory', 9);
      final invite = DeltaInvite.parse(alice.protocol.invite.toLink())!;
      final step = await bob.protocol.join(bob.chats, invite);
      bob.apply(step);
      final malloryAsAlice = DeltaProtocol(
        key: mallory.protocol.key,
        self: 'alice@example.org',
        tokens: alice.protocol.tokens,
      );
      final answer = await malloryAsAlice.receive(
        const DeltaChats(),
        Uint8List.fromList(utf8.encode(step.mails.single.mail)),
      );
      expect(answer.mails, hasLength(1), reason: 'mallory answers');
      final atBob = await bob.protocol.receive(
        bob.chats,
        Uint8List.fromList(utf8.encode(answer.mails.single.mail)),
      );
      expect(atBob.mails, isEmpty, reason: 'no proof goes to mallory');
      expect(atBob.chats.peers[alice.fingerprint]?.verified ?? false, isFalse);
    },
  );

  test('a proof without the inviter\'s key gossiped is ignored', () async {
    final invite = DeltaInvite.parse(alice.protocol.invite.toLink())!;
    final joining = await bob.protocol.join(bob.chats, invite);
    bob.apply(joining);
    final atAlice = await alice.protocol.receive(
      alice.chats,
      Uint8List.fromList(utf8.encode(joining.mails.single.mail)),
    );
    alice.apply(atAlice);
    final atBob = await bob.protocol.receive(
      bob.chats,
      Uint8List.fromList(utf8.encode(atAlice.mails.single.mail)),
    );
    bob.apply(atBob);

    // The same proof, as if forwarded: no gossip of Alice's key.
    final forwarded = await DeltaMail.build(
      key: bob.protocol.key,
      from: bob.addr,
      to: [(addr: alice.addr, key: alice.protocol.key.publicKey)],
      text: 'Secure-Join: vc-request-with-auth',
      messageId: 'Mr.forwarded@example.org',
      date: clock,
      extraHeaders: [
        ('Secure-Join', 'vc-request-with-auth'),
        ('Secure-Join-Auth', invite.auth),
        ('Secure-Join-Fingerprint', bob.fingerprint),
      ],
    );
    final refused = await alice.protocol.receive(
      alice.chats,
      Uint8List.fromList(utf8.encode(forwarded)),
    );
    expect(refused.mails, isEmpty);
    expect(refused.chats.peers[bob.fingerprint]?.verified ?? false, isFalse);

    // Bob's own proof carries the gossip and goes through.
    await deliver(atBob.mails);
    expect(alice.chats.peers[bob.fingerprint]?.verified, isTrue);
  });

  test(
    'groups: created, joined by invite, written in, members removed',
    () async {
      await introduce(bob, alice);

      final created = await alice.protocol.createGroup(alice.chats, 'Team', [
        bob.fingerprint,
      ]);
      alice.apply(created);
      final groupKey = created.chatKey!;
      await deliver(created.mails);
      final atBob = bob.chats.chats[groupKey]!;
      expect(atBob.name, 'Team');
      expect(atBob.members, [alice.fingerprint]);
      expect(atBob.kept, isTrue, reason: 'from a verified contact');

      // Carol joins with the group's invite.
      final groupInvite = alice.protocol.groupInvite(
        alice.chats.chats[groupKey]!,
      );
      final joining = await carol.protocol.join(
        carol.chats,
        DeltaInvite.parse(groupInvite.toLink())!,
      );
      carol.apply(joining);
      await deliver(joining.mails);
      expect(
        alice.chats.chats[groupKey]!.members,
        unorderedEquals([bob.fingerprint, carol.fingerprint]),
      );
      final atCarol = carol.chats.chats[groupKey]!;
      expect(atCarol.left, isFalse);
      expect(atCarol.kept, isTrue);
      expect(
        atCarol.members,
        unorderedEquals([alice.fingerprint, bob.fingerprint]),
      );
      expect(
        bob.chats.chats[groupKey]!.members,
        unorderedEquals([alice.fingerprint, carol.fingerprint]),
      );
      expect(carol.chats.joins, isEmpty);
      // Bob learned Carol's key from the gossip and can write to her.
      expect(bob.chats.peers[carol.fingerprint]?.key, isNotNull);

      await send(carol, groupKey, 'Hello team');
      expect(alice.chats.chats[groupKey]!.messages.last.text, 'Hello team');
      expect(bob.chats.chats[groupKey]!.messages.last.text, 'Hello team');
      expect(
        bob.chats.chats[groupKey]!.messages.last.author,
        carol.fingerprint,
      );

      // Alice removes Bob: he hears of it, and is out.
      final removed = await alice.protocol.removeMember(
        alice.chats,
        groupKey,
        bob.fingerprint,
      );
      alice.apply(removed);
      await deliver(removed.mails);
      expect(bob.chats.chats[groupKey]!.left, isTrue);
      expect(carol.chats.chats[groupKey]!.members, [alice.fingerprint]);
      await expectLater(
        bob.protocol.send(bob.chats, groupKey, 'still here?'),
        throwsStateError,
      );

      // A message from Bob that still claims the group changes nothing.
      final forged =
          await DeltaProtocol(
            key: bob.protocol.key,
            self: bob.addr,
            tokens: bob.protocol.tokens,
          ).send(
            bob.chats.withChat(
              bob.chats.chats[groupKey]!.copyWith(
                left: false,
                members: [alice.fingerprint, carol.fingerprint],
              ),
            ),
            groupKey,
            'I re-add myself',
          );
      await deliver(forged.mails);
      expect(alice.chats.chats[groupKey]!.members, [carol.fingerprint]);
      expect(
        alice.chats.chats[groupKey]!.messages.map((message) => message.text),
        isNot(contains('I re-add myself')),
      );

      // Carol leaves.
      final left = await carol.protocol.removeMember(
        carol.chats,
        groupKey,
        carol.fingerprint,
      );
      carol.apply(left);
      await deliver(left.mails);
      expect(carol.chats.chats[groupKey]!.left, isTrue);
      expect(alice.chats.chats[groupKey]!.members, isEmpty);
    },
  );

  test('strangers\' messages are requests, apart by key', () async {
    // Carol learns Alice's key from a group with her, then writes alone.
    await introduce(bob, alice);
    await introduce(carol, bob);
    final group = await bob.protocol.createGroup(bob.chats, 'Mixed', [
      alice.fingerprint,
      carol.fingerprint,
    ]);
    bob.apply(group);
    await deliver(group.mails);
    expect(carol.chats.peers[alice.fingerprint]?.key, isNotNull);
    final direct = carol.chats.withChat(
      DeltaChat(key: alice.fingerprint, members: [alice.fingerprint]),
    );
    final step = await carol.protocol.send(direct, alice.fingerprint, 'hey');
    await deliver(step.mails);
    final request = alice.chats.chats[carol.fingerprint]!;
    expect(request.kept, isFalse);
    expect(request.messages.single.text, 'hey');

    // Reading a request sends no receipt.
    final read = await alice.protocol.markRead(alice.chats, carol.fingerprint);
    expect(read.mails, isEmpty);
  });
}
