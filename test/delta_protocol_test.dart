import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:conest/src/delta_chats.dart';
import 'package:conest/src/delta_protocol.dart';
import 'package:conest/src/email/delta_mail.dart';
import 'package:conest/src/email/mime.dart';
import 'package:conest/src/email/openpgp.dart';
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

/// [invite] as a classic or a v3 one.
DeltaInvite version(DeltaInvite invite, bool v3) => DeltaInvite(
  fingerprint: invite.fingerprint,
  addr: invite.addr,
  auth: invite.auth,
  name: invite.name,
  invitenumber: invite.invitenumber,
  groupId: invite.groupId,
  groupName: invite.groupName,
  v3: v3,
);

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
        key: await PgpSecretKey.generate('<$addr>', created: clock),
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

  Future<void> introduce(Party joiner, Party inviter, {bool v3 = true}) async {
    final invite = version(
      DeltaInvite.parse(inviter.protocol.invite.toLink())!,
      v3,
    );
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

  for (final v3 in [true, false]) {
    group(v3 ? 'Securejoin v3' : 'classic Securejoin', () {
      test(
        'Securejoin verifies both sides, then they chat with receipts',
        () async {
          await introduce(bob, alice, v3: v3);

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
          expect(
            bob.chats.chats[alice.fingerprint]!.messages.last.text,
            'Hi Bob',
          );

          // Alice reads: Bob's message shows read.
          final read = await alice.protocol.markRead(
            alice.chats,
            bob.fingerprint,
          );
          alice.apply(read);
          expect(read.mails, hasLength(1));
          await deliver(read.mails);
          final bobsOwn = bob.chats.chats[alice.fingerprint]!.messages
              .firstWhere((message) => message.outgoing);
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
          v3: v3,
        );
        final step = await bob.protocol.join(bob.chats, forged);
        bob.apply(step);
        await deliver(step.mails);
        expect(alice.chats.peers[bob.fingerprint]?.verified ?? false, isFalse);
        expect(alice.chats.chats, isEmpty);
      });

      test('a proof without the inviter\'s key gossiped is ignored', () async {
        final invite = version(
          DeltaInvite.parse(alice.protocol.invite.toLink())!,
          v3,
        );
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
        expect(
          refused.chats.peers[bob.fingerprint]?.verified ?? false,
          isFalse,
        );

        // Bob's own proof carries the gossip and goes through.
        await deliver(atBob.mails);
        expect(alice.chats.peers[bob.fingerprint]?.verified, isTrue);
      });
    });
  }

  test(
    'an answer signed by another key than the invite\'s is ignored',
    () async {
      // Mallory intercepts and answers as alice@ with her own key.
      final mallory = await party('mallory', 9);
      final invite = version(
        DeltaInvite.parse(alice.protocol.invite.toLink())!,
        false,
      );
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

  test('v3: an answer by another key, even with the invite\'s secret, '
      'is ignored', () async {
    final mallory = await party('mallory', 9);
    final invite = DeltaInvite.parse(alice.protocol.invite.toLink())!;
    expect(invite.v3, isTrue);
    final step = await bob.protocol.join(bob.chats, invite);
    bob.apply(step);
    // Mallory saw the invite: she knows the secret, not Alice's key.
    final forged = await DeltaMail.buildSecureJoinV3(
      key: mallory.protocol.key,
      from: alice.addr,
      to: bob.addr,
      step: 'vc-pubkey',
      auth: invite.auth,
      password: 'securejoin/${invite.fingerprint}/${invite.auth}',
      attachKey: true,
      messageId: 'Mr.mallory@example.org',
      date: clock,
    );
    final atBob = await bob.protocol.receive(
      bob.chats,
      Uint8List.fromList(utf8.encode(forged)),
    );
    expect(atBob.mails, isEmpty);
    expect(atBob.chats.peers[alice.fingerprint]?.verified ?? false, isFalse);

    // Nor does a chat message sent with that secret land anywhere.
    final secret = 'securejoin/${invite.fingerprint}/${invite.auth}';
    final inner =
        'Content-Type: text/plain; charset="utf-8"; protected-headers="v1"\r\n'
        'From: <${mallory.addr}>\r\n'
        'Message-ID: <Mr.mallory2@example.org>\r\n'
        'Chat-Version: 1.0\r\n'
        '${foldedHeader('Autocrypt', AutocryptHeader(addr: mallory.addr, keydata: mallory.protocol.key.publicKey.bytes, mutual: true).encode())}\r\n'
        '\r\nhello from the secret\r\n';
    final encrypted = await Pgp.encryptWithPassword(
      Uint8List.fromList(utf8.encode(inner)),
      utf8.encode(secret),
      signer: mallory.protocol.key,
    );
    final chatMail =
        'From: <${mallory.addr}>\r\n'
        'Message-ID: <Mr.mallory2@example.org>\r\n'
        'Content-Type: multipart/encrypted; protocol="application/pgp-encrypted"; boundary="x"\r\n'
        '\r\n--x\r\nContent-Type: application/pgp-encrypted\r\n\r\nVersion: 1\r\n'
        '--x\r\nContent-Type: application/octet-stream\r\n\r\n'
        '${OpenPgpArmor.encode(encrypted)}\r\n--x--\r\n';
    final stillNothing = await bob.protocol.receive(
      atBob.chats,
      Uint8List.fromList(utf8.encode(chatMail)),
    );
    expect(stillNothing.consumed, isFalse);
    expect(stillNothing.chats.chats.keys, [alice.fingerprint]);
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

  group('review findings', () {
    late Party mallory;

    setUp(() async {
      mallory = await party('mallory', 9);
      byAddr[mallory.addr] = mallory;
    });

    Future<DeltaStep> receiveAs(Party party, String mail) async {
      final step = await party.protocol.receive(
        party.chats,
        Uint8List.fromList(utf8.encode(mail)),
      );
      party.apply(step);
      return step;
    }

    test('gossip never moves a known person to another address', () async {
      await introduce(bob, alice);
      final aliceKey = alice.protocol.key.publicKey;
      final gossiping = await DeltaMail.build(
        key: mallory.protocol.key,
        from: mallory.addr,
        to: [
          (addr: bob.addr, key: bob.protocol.key.publicKey),
          (addr: 'evil@attacker.org', key: aliceKey),
        ],
        gossip: [(addr: 'evil@attacker.org', key: aliceKey)],
        text: 'hi',
        messageId: 'Mr.gossip@example.org',
        date: clock,
      );
      await receiveAs(bob, gossiping);
      expect(bob.chats.peers[alice.fingerprint]!.addr, alice.addr);
      expect(bob.chats.peers[alice.fingerprint]!.verified, isTrue);

      // Nor does an unsigned request carrying Alice's key.
      final request = DeltaMail.buildRequest(
        key: alice.protocol.key,
        from: mallory.addr,
        to: bob.addr,
        step: 'vc-request',
        invitenumber: bob.protocol.tokens.invitenumber,
        messageId: 'Mr.request@example.org',
        date: clock,
      ).replaceAll('addr=${alice.addr}', 'addr=${mallory.addr}');
      await receiveAs(bob, request);
      expect(bob.chats.peers[alice.fingerprint]!.addr, alice.addr);
    });

    test('names cannot inject headers into mail sent later', () async {
      await introduce(bob, mallory);
      final evil = 'Team\r\nX-Injected: yes';
      final mail = await DeltaMail.build(
        key: mallory.protocol.key,
        from: mallory.addr,
        to: [(addr: bob.addr, key: bob.protocol.key.publicKey)],
        text: 'join us',
        messageId: 'Mr.inject@example.org',
        date: clock,
        extraHeaders: [
          ('Chat-Group-ID', 'group1'),
          ('Chat-Group-Name', encodeMimeWord(evil)),
        ],
      );
      await receiveAs(bob, mail);
      final chat = bob.chats.chats['g:group1']!;
      expect(chat.name, isNot(contains('\n')));
      final sent = await bob.protocol.send(bob.chats, chat.key, 'hello');
      final read = await DeltaMail.read(
        Uint8List.fromList(utf8.encode(sent.mails.single.mail)),
        mallory.protocol.key,
      );
      expect(read!.header('x-injected'), isNull);
      expect(read.header('chat-group-name'), isNot(contains('\n')));
    });

    test('a replayed old group mail does not undo a removal', () async {
      await introduce(bob, alice);
      await introduce(carol, alice);
      final created = await alice.protocol.createGroup(alice.chats, 'Team', [
        bob.fingerprint,
        carol.fingerprint,
      ]);
      alice.apply(created);
      await deliver(created.mails);
      final groupKey = created.chatKey!;
      final removed = await alice.protocol.removeMember(
        alice.chats,
        groupKey,
        carol.fingerprint,
      );
      alice.apply(removed);
      await deliver(removed.mails);
      expect(bob.chats.chats[groupKey]!.members, [alice.fingerprint]);
      // Carol re-sends Alice's first mail to Bob.
      await receiveAs(bob, created.mails.single.mail);
      expect(bob.chats.chats[groupKey]!.members, [alice.fingerprint]);
    });

    test('a signed message written to someone else is not taken', () async {
      await introduce(bob, alice);
      final forwarded = await DeltaMail.build(
        key: alice.protocol.key,
        from: alice.addr,
        // Written to Mallory; Bob holds a copy encrypted to him.
        to: [(addr: mallory.addr, key: bob.protocol.key.publicKey)],
        text: 'for Mallory only',
        messageId: 'Mr.forwarded@example.org',
        date: clock,
      );
      final step = await receiveAs(bob, forwarded);
      expect(step.consumed, isFalse);
      expect(bob.chats.chats[alice.fingerprint]!.messages, isEmpty);
    });

    test('joining with a key known already verifies the inviter', () async {
      await introduce(bob, carol);
      await introduce(alice, carol);
      final group = await carol.protocol.createGroup(carol.chats, 'Shared', [
        alice.fingerprint,
        bob.fingerprint,
      ]);
      carol.apply(group);
      await deliver(group.mails);
      expect(bob.chats.peers[alice.fingerprint]?.key, isNotNull);
      expect(bob.chats.peers[alice.fingerprint]?.verified, isFalse);
      await introduce(bob, alice);
      expect(bob.chats.peers[alice.fingerprint]?.verified, isTrue);
      expect(alice.chats.peers[bob.fingerprint]?.verified, isTrue);
    });

    test('malformed signatures are refused, not thrown', () async {
      final packets = OpenPgpSymmetric.readPackets(
        alice.protocol.key.publicKey.bytes,
      );
      final patched = Uint8List.fromList([
        for (final (tag, body) in packets)
          ...OpenPgpSymmetric.packet(
            tag,
            tag == 2
                ? (Uint8List.fromList(body)
                    ..[4] = 0xff
                    ..[5] = 0xf0)
                : body,
          ),
      ]);
      await expectLater(PgpPublicKey.parse(patched), throwsFormatException);
    });

    test('encrypted mail that is not a chat message is left alone', () async {
      await introduce(bob, alice);
      final mail = await DeltaMail.build(
        key: alice.protocol.key,
        from: alice.addr,
        to: [(addr: bob.addr, key: bob.protocol.key.publicKey)],
        text: 'from a mail app',
        messageId: 'Mr.plain@example.org',
        date: clock,
      );
      // As an Autocrypt mail app would write it: no Chat-Version inside.
      final inner = await Pgp.decrypt(
        OpenPgpArmor.decode(
          mail.substring(
            mail.indexOf('-----BEGIN'),
            mail.indexOf('-----END') + 25,
          ),
        ),
        bob.protocol.key,
      );
      final stripped = utf8
          .decode(inner.data)
          .replaceAll('Chat-Version: 1.0\r\n', '');
      final reencrypted = await Pgp.encrypt(
        Uint8List.fromList(utf8.encode(stripped)),
        [bob.protocol.key.publicKey],
        signer: alice.protocol.key,
        now: clock,
      );
      final armored = OpenPgpArmor.encode(reencrypted);
      final rebuilt = mail
          .replaceRange(
            mail.indexOf('-----BEGIN'),
            mail.indexOf('-----END') + 25,
            armored.trimRight(),
          )
          .replaceAll('Chat-Version: 1.0\r\n', '');
      final step = await receiveAs(bob, rebuilt);
      expect(step.consumed, isFalse);
      expect(bob.chats.chats[alice.fingerprint]!.messages, isEmpty);
    });

    test(
      'a group made up before joining is replaced by the inviter\'s',
      () async {
        await introduce(bob, alice);
        final created = await alice.protocol.createGroup(
          alice.chats,
          'Real',
          const [],
        );
        alice.apply(created);
        final groupKey = created.chatKey!;
        final invite = alice.protocol.groupInvite(alice.chats.chats[groupKey]!);
        // Mallory knows the group id from the link and gets in first.
        final early = await DeltaMail.build(
          key: mallory.protocol.key,
          from: mallory.addr,
          to: [(addr: bob.addr, key: bob.protocol.key.publicKey)],
          text: 'welcome',
          messageId: 'Mr.early@example.org',
          date: clock,
          extraHeaders: [
            ('Chat-Group-ID', invite.groupId!),
            ('Chat-Group-Name', 'Fake'),
          ],
        );
        await receiveAs(bob, early);
        expect(bob.chats.chats[groupKey]!.members, [mallory.fingerprint]);
        final joining = await bob.protocol.join(
          bob.chats,
          DeltaInvite.parse(invite.toLink())!,
        );
        bob.apply(joining);
        await deliver(joining.mails);
        final chat = bob.chats.chats[groupKey]!;
        expect(chat.left, isFalse);
        expect(chat.members, [alice.fingerprint]);
        expect(chat.name, 'Real');
      },
    );

    /// A Securejoin v3 mail shaped as Delta Chat core writes it
    /// (`symm_encrypted_securejoin_message`): hidden recipients, only the
    /// Securejoin headers inside, Autocrypt and a signature on vc-pubkey.
    Future<String> deltaV3(
      Party from, {
      required String step,
      required String auth,
      required String secret,
    }) async {
      final sign = step == 'vc-pubkey';
      final inner = [
        'Content-Type: text/plain; charset="utf-8"; protected-headers="v1"; '
            'hp="cipher"',
        'To: "hidden-recipients": ;',
        'Date: Tue, 13 Oct 2026 09:00:00 +0000',
        'Subject: Secure-Join',
        'Secure-Join: $step',
        'Secure-Join-Auth: $auth',
        if (sign)
          foldedHeader(
            'Autocrypt',
            AutocryptHeader(
              addr: from.addr,
              keydata: from.protocol.key.publicKey.bytes,
              mutual: true,
            ).encode(),
          ),
        '',
        'Secure-Join',
        '',
      ].join('\r\n');
      final encrypted = await Pgp.encryptWithPassword(
        Uint8List.fromList(utf8.encode(inner)),
        utf8.encode(secret),
        signer: sign ? from.protocol.key : null,
        now: clock,
      );
      return wrap(from.addr, 'Mr.v3.$step@example.org', encrypted);
    }

    test('v3 as Delta Chat writes it works on both sides', () async {
      // Delta Chat (on Mallory's device here) asks Alice for her key.
      final auth = alice.protocol.tokens.auth;
      final request = await deltaV3(
        mallory,
        step: 'vc-request-pubkey',
        auth: auth,
        secret: 'securejoin/${alice.fingerprint}/$auth',
      );
      final answered = await receiveAs(alice, request);
      expect(answered.mails, hasLength(1));
      expect(answered.mails.single.to, [mallory.addr]);

      // And Alice, as Delta Chat would, answers Bob who joined her invite.
      final invite = DeltaInvite.parse(alice.protocol.invite.toLink())!;
      final joining = await bob.protocol.join(bob.chats, invite);
      bob.apply(joining);
      final pubkey = await deltaV3(
        alice,
        step: 'vc-pubkey',
        auth: invite.auth,
        secret: 'securejoin/${alice.fingerprint}/${invite.auth}',
      );
      final proof = await receiveAs(bob, pubkey);
      expect(proof.mails, hasLength(1), reason: 'vc-request-with-auth');
      expect(bob.chats.peers[alice.fingerprint]?.verified, isTrue);
      await deliver(proof.mails);
      expect(alice.chats.peers[bob.fingerprint]?.verified, isTrue);
    });

    test('group mail with files stays on the server', () async {
      await introduce(bob, alice);
      final created = await alice.protocol.createGroup(alice.chats, 'Files', [
        bob.fingerprint,
      ]);
      alice.apply(created);
      await deliver(created.mails);
      final groupId = alice.chats.chats[created.chatKey!]!.groupId!;
      final inner = [
        'Content-Type: multipart/mixed; boundary="m"; protected-headers="v1"',
        'From: <${alice.addr}>',
        'To: <${bob.addr}>',
        'Message-ID: <Mr.file@example.org>',
        'Chat-Version: 1.0',
        'Chat-Group-ID: $groupId',
        'Chat-Group-Name: Files',
        foldedHeader(
          'Autocrypt',
          AutocryptHeader(
            addr: alice.addr,
            keydata: alice.protocol.key.publicKey.bytes,
            mutual: true,
          ).encode(),
        ),
        '',
        '--m',
        'Content-Type: text/plain; charset="utf-8"',
        '',
        'see attached',
        '--m',
        'Content-Type: image/jpeg',
        'Content-Disposition: attachment; filename="p.jpg"',
        'Content-Transfer-Encoding: base64',
        '',
        'AAAA',
        '--m--',
        '',
      ].join('\r\n');
      final encrypted = await Pgp.encrypt(
        Uint8List.fromList(utf8.encode(inner)),
        [bob.protocol.key.publicKey],
        signer: alice.protocol.key,
        now: clock,
      );
      final step = await receiveAs(
        bob,
        wrap(alice.addr, 'Mr.file@example.org', encrypted),
      );
      expect(step.consumed, isFalse);
      expect(
        bob.chats.chats[created.chatKey!]!.messages.map((m) => m.text),
        isNot(contains(contains('p.jpg'))),
      );
    });

    test('a contact\'s made-up group is replaced when joining', () async {
      await introduce(bob, alice);
      await introduce(bob, mallory);
      final created = await alice.protocol.createGroup(
        alice.chats,
        'Real',
        const [],
      );
      alice.apply(created);
      final invite = alice.protocol.groupInvite(
        alice.chats.chats[created.chatKey!]!,
      );
      final fake = await DeltaMail.build(
        key: mallory.protocol.key,
        from: mallory.addr,
        to: [(addr: bob.addr, key: bob.protocol.key.publicKey)],
        text: 'welcome',
        messageId: 'Mr.fake@example.org',
        date: clock,
        extraHeaders: [
          ('Chat-Group-ID', invite.groupId!),
          ('Chat-Group-Name', 'Fake'),
        ],
      );
      await receiveAs(bob, fake);
      expect(bob.chats.chats[created.chatKey!]!.kept, isTrue);
      final joining = await bob.protocol.join(
        bob.chats,
        DeltaInvite.parse(invite.toLink())!,
      );
      bob.apply(joining);
      await deliver(joining.mails);
      expect(bob.chats.chats[created.chatKey!]!.members, [alice.fingerprint]);
      expect(bob.chats.chats[created.chatKey!]!.name, 'Real');
    });
    test('requests without the invite do not use up answers', () async {
      for (var index = 0; index < 40; index++) {
        await receiveAs(
          alice,
          DeltaMail.buildRequest(
            key: mallory.protocol.key,
            from: mallory.addr,
            to: alice.addr,
            step: 'vc-request',
            invitenumber: 'guess$index',
            messageId: 'Mr.spam$index@example.org',
            date: clock,
          ),
        );
      }
      await introduce(bob, alice, v3: false);
      expect(alice.chats.peers[bob.fingerprint]?.verified, isTrue);
    });

    test('keys that do not read are not read again for every mail', () async {
      // 300 peers at Mallory's address with keys that check out but are
      // not theirs: each costs signature checks, once.
      final key = mallory.protocol.key.publicKey.bytes;
      var chats = bob.chats;
      for (var index = 0; index < 300; index++) {
        chats = chats.withPeer(
          DeltaPeer(
            fingerprint: index.toRadixString(16).padLeft(40, '0').toUpperCase(),
            addr: mallory.addr,
            key: key,
          ),
        );
      }
      bob.chats = chats;
      final plain =
          'From: <${mallory.addr}>\r\nTo: <${bob.addr}>\r\n'
          'Message-ID: <Mr.plain@example.org>\r\n'
          'Content-Type: multipart/encrypted; boundary=x\r\n\r\n'
          '--x\r\n\r\nnothing\r\n--x--\r\n';
      final mail = await DeltaMail.build(
        key: mallory.protocol.key,
        from: mallory.addr,
        to: [(addr: bob.addr, key: bob.protocol.key.publicKey)],
        text: 'hi',
        messageId: 'Mr.first@example.org',
        date: clock,
      );
      await receiveAs(bob, mail);
      final watch = Stopwatch()..start();
      for (var index = 0; index < 10; index++) {
        await receiveAs(bob, plain);
        await receiveAs(bob, mail.replaceAll('Mr.first', 'Mr.again$index'));
      }
      expect(watch.elapsedMilliseconds, lessThan(1500));
    });
  });
}

/// [encrypted] as PGP/MIME mail from [from].
String wrap(String from, String messageId, Uint8List encrypted) =>
    'From: <$from>\r\n'
    'To: "hidden-recipients": ;\r\n'
    'Subject: [...]\r\n'
    'Date: Tue, 13 Oct 2026 09:00:00 +0000\r\n'
    'Message-ID: <$messageId>\r\n'
    'Chat-Version: 1.0\r\n'
    'MIME-Version: 1.0\r\n'
    'Content-Type: multipart/encrypted; '
    'protocol="application/pgp-encrypted"; boundary="b"\r\n'
    '\r\n--b\r\nContent-Type: application/pgp-encrypted\r\n\r\n'
    'Version: 1\r\n'
    '--b\r\nContent-Type: application/octet-stream\r\n\r\n'
    '${OpenPgpArmor.encode(encrypted)}\r\n--b--\r\n';
