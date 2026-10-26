import 'dart:io';

import 'package:conest/src/xmpp/xmpp_carrier.dart';
import 'package:conest/src/xmpp/xmpp_chat_client.dart';
import 'package:conest/src/xmpp/xmpp_chats.dart';
import 'package:conest/src/xmpp/xmpp_session.dart';
import 'package:conest/src/xmpp/xmpp_xml.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_xmpp_server.dart';

Future<void> _until(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 10),
  String? reason,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out${reason == null ? '' : ': $reason'}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

class _Client {
  _Client(this.server, String local, {String resource = 'chat'}) {
    server.passwords.putIfAbsent(local, () => 'pw-$local');
    session = XmppSession(
      jid: '$local@${server.domain}',
      password: server.passwords[local]!,
      resource: resource,
      endpoints: xmppEndpointCandidates(server.domain),
      connector: server.connect,
    );
    client = XmppChatClient(
      session: session,
      ownsSession: true,
      chats: () => chats,
      save: (next) => chats = next,
      sendReadMarkers: () => markers,
      httpPut: (url, headers, file) async => puts.add((url, headers)),
    );
  }

  final FakeXmppServer server;
  late final XmppSession session;
  late final XmppChatClient client;
  XmppChats chats = const XmppChats();
  bool markers = true;
  final List<(Uri, Map<String, String>)> puts = [];

  String get jid => session.jid;

  Future<void> start() async {
    client.start();
    await _until(() => session.state == XmppSessionState.connected);
    // Setup after connecting (roster, carbons, history) settles.
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }

  XmppChat? chat(String jid) => chats.chats[jid];
  List<XmppChatMessage> messages(String jid) => chat(jid)?.messages ?? const [];
}

void main() {
  late FakeXmppServer server;
  final clients = <_Client>[];
  setUp(() {
    server = FakeXmppServer();
    clients.clear();
  });
  tearDown(() async {
    for (final client in clients) {
      await client.client.stop();
    }
  });
  Future<_Client> person(String name, {String resource = 'chat'}) async {
    final client = _Client(server, name, resource: resource);
    clients.add(client);
    await client.start();
    return client;
  }

  test('a stranger\'s first message is a request until accepted', () async {
    final alice = await person('alice');
    final bob = await person('bob');
    bob.client.startChat(alice.jid);
    await bob.client.sendText(alice.jid, 'hello');
    await _until(() => alice.messages(bob.jid).isNotEmpty);
    expect(alice.chat(bob.jid)!.request, isTrue);
    // No delivery receipt goes to a stranger.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(bob.messages(alice.jid).single.state, XmppMessageState.sent);
    alice.client.acceptRequest(bob.jid);
    expect(alice.chat(bob.jid)!.request, isFalse);
    await bob.client.sendText(alice.jid, 'again');
    await _until(
      () => bob.messages(alice.jid).last.state == XmppMessageState.delivered,
      reason: 'a delivery receipt',
    );
    alice.client.markRead(bob.jid);
    await _until(
      () => bob.messages(alice.jid).last.state == XmppMessageState.read,
      reason: 'a read marker',
    );
    expect(alice.chat(bob.jid)!.unread, 0);
  });

  test('read markers follow the read-receipt setting', () async {
    final alice = await person('alice');
    final bob = await person('bob');
    alice.markers = false;
    alice.client.startChat(bob.jid);
    bob.client.startChat(alice.jid);
    await bob.client.sendText(alice.jid, 'hi');
    await _until(
      () => bob.messages(alice.jid).single.state == XmppMessageState.delivered,
    );
    alice.client.markRead(bob.jid);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(bob.messages(alice.jid).single.state, XmppMessageState.delivered);
    expect(
      server.received.where(
        (e) => e.child('displayed', XmppNs.markers) != null,
      ),
      isEmpty,
    );
  });

  test('only the sender corrects or retracts a message', () async {
    final alice = await person('alice');
    final bob = await person('bob');
    final mallory = await person('mallory');
    alice.client.startChat(bob.jid);
    alice.client.startChat(mallory.jid);
    bob.client.startChat(alice.jid);
    final id = await bob.client.sendText(alice.jid, 'original');
    await _until(() => alice.messages(bob.jid).isNotEmpty);
    // Mallory names Bob's message id in a correction and a retraction.
    for (final child in [
      XmppElement('replace', xmlns: XmppNs.correction, attributes: {'id': id}),
      XmppElement('retract', xmlns: XmppNs.retract, attributes: {'id': id}),
    ]) {
      server.inject(
        XmppElement(
          'message',
          attributes: {
            'from': '${mallory.jid}/x',
            'to': '${alice.jid}/chat',
            'type': 'chat',
            'id': 'm1',
          },
          children: [
            XmppElement('body', text: 'forged'),
            child,
          ],
        ),
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(alice.messages(bob.jid).single.text, 'original');
    expect(alice.messages(bob.jid).single.retracted, isFalse);
    // Bob's own correction and retraction count.
    await bob.client.correct(alice.jid, id, 'fixed');
    await _until(() => alice.messages(bob.jid).single.text == 'fixed');
    expect(alice.messages(bob.jid).single.editedAt, isNotNull);
    await bob.client.retract(alice.jid, id);
    await _until(() => alice.messages(bob.jid).single.retracted);
    // Someone else's message cannot be corrected here either.
    await expectLater(alice.client.correct(bob.jid, id, 'x'), throwsStateError);
  });

  test('replies and reactions', () async {
    final alice = await person('alice');
    final bob = await person('bob');
    alice.client.startChat(bob.jid);
    bob.client.startChat(alice.jid);
    final id = await bob.client.sendText(alice.jid, 'question?');
    await _until(() => alice.messages(bob.jid).isNotEmpty);
    await alice.client.sendText(bob.jid, 'answer', replyTo: id);
    await _until(() => bob.messages(alice.jid).length == 2);
    final answer = bob.messages(alice.jid).last;
    expect(answer.replyTo, id);
    expect(answer.replySnippet, 'question?');
    await alice.client.react(bob.jid, id, {'👍'});
    await _until(() => bob.messages(alice.jid).first.reactions.isNotEmpty);
    expect(bob.messages(alice.jid).first.reactions['👍'], {alice.jid});
    // A new set replaces the old one.
    await alice.client.react(bob.jid, id, {'🎉'});
    await _until(
      () => bob.messages(alice.jid).first.reactions.keys.single == '🎉',
    );
  });

  test(
    'copies of the account\'s other clients come in; forged ones do not',
    () async {
      final alice = await person('alice');
      final other = await person('alice', resource: 'phone');
      final bob = await person('bob');
      bob.client.startChat(alice.jid);
      alice.client.startChat(bob.jid);
      other.client.startChat(bob.jid);
      await other.client.sendText(bob.jid, 'from my phone');
      await _until(() => alice.messages(bob.jid).isNotEmpty);
      expect(alice.messages(bob.jid).single.outgoing, isTrue);
      expect(alice.messages(bob.jid).single.text, 'from my phone');
      // Bob pretends to send a carbon of a message "Alice" wrote to Carol.
      server.inject(
        XmppElement(
          'message',
          attributes: {'from': bob.jid, 'to': '${alice.jid}/chat'},
          children: [
            XmppElement(
              'sent',
              xmlns: XmppNs.carbons,
              children: [
                XmppElement(
                  'forwarded',
                  xmlns: XmppNs.forward,
                  children: [
                    XmppElement(
                      'message',
                      attributes: {
                        'from': '${alice.jid}/x',
                        'to': 'carol@xmpp.test',
                        'type': 'chat',
                        'id': 'f1',
                      },
                      children: [XmppElement('body', text: 'forged')],
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(alice.chat('carol@xmpp.test'), isNull);
    },
  );

  test(
    'history comes from the archive, and only from queries made here',
    () async {
      final bob = await person('bob');
      final alice = await person('alice');
      bob.client.startChat(alice.jid);
      alice.client.startChat(bob.jid);
      await bob.client.sendText(alice.jid, 'one');
      await _until(() => alice.messages(bob.jid).isNotEmpty);
      // Alice's app is reinstalled: nothing local, the archive has it.
      await alice.client.stop();
      clients.remove(alice);
      final again = _Client(server, 'alice');
      clients.add(again);
      await again.start();
      await _until(() => again.messages(bob.jid).isNotEmpty);
      expect(again.messages(bob.jid).single.text, 'one');
      // A result for a query nobody made is ignored.
      server.inject(
        XmppElement(
          'message',
          attributes: {'from': again.jid, 'to': '${again.jid}/chat'},
          children: [
            XmppElement(
              'result',
              xmlns: XmppNs.mam,
              attributes: {'queryid': 'nope', 'id': 'z'},
              children: [
                XmppElement(
                  'forwarded',
                  xmlns: XmppNs.forward,
                  children: [
                    XmppElement(
                      'message',
                      attributes: {
                        'from': 'eve@xmpp.test/x',
                        'to': again.jid,
                        'type': 'chat',
                        'id': 'e1',
                      },
                      children: [XmppElement('body', text: 'planted')],
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(again.chat('eve@xmpp.test'), isNull);
    },
  );

  test('group chats: messages, reactions, read markers and history', () async {
    final alice = await person('alice');
    final bob = await person('bob');
    const room = 'den@conference.xmpp.test';
    alice.client.joinRoom('xmpp:$room?join', nick: 'Alice');
    bob.client.joinRoom(room, nick: 'Bob');
    await _until(() => server.rooms[room]?.occupants.length == 2);
    final id = await alice.client.sendText(room, 'hi room');
    await _until(() => bob.messages(room).isNotEmpty);
    expect(bob.messages(room).single.from, 'Alice');
    expect(bob.chat(room)!.room, isTrue);
    // Alice's own copy came back with the room's id.
    await _until(() => alice.messages(room).single.stanzaId != null);
    expect(alice.messages(room).single.id, id);
    expect(alice.messages(room).single.outgoing, isTrue);
    await bob.client.react(room, bob.messages(room).single.id, {'❤'});
    await _until(() => alice.messages(room).single.reactions.isNotEmpty);
    expect(alice.messages(room).single.reactions['❤'], {'Bob'});
    bob.client.markRead(room);
    await _until(
      () => server.received.any(
        (e) =>
            e.child('displayed', XmppNs.markers)?.attr('id') ==
            alice.messages(room).single.stanzaId,
      ),
    );
    // Bob cannot correct or retract Alice's message in the room.
    server.inject(
      XmppElement(
        'message',
        attributes: {
          'from': '$room/Bob',
          'to': '${alice.jid}/chat',
          'type': 'groupchat',
          'id': 'c1',
        },
        children: [
          XmppElement('body', text: 'forged'),
          XmppElement(
            'replace',
            xmlns: XmppNs.correction,
            attributes: {'id': id},
          ),
        ],
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(alice.messages(room).single.text, 'hi room');
    // Carol joins later and gets the history from the room's archive.
    final carol = await person('carol');
    carol.client.joinRoom(room, nick: 'Carol');
    await _until(() => carol.messages(room).isNotEmpty);
    expect(carol.messages(room).single.text, 'hi room');
  });

  test('a group chat invitation waits for the user', () async {
    final alice = await person('alice');
    server.inject(
      XmppElement(
        'message',
        attributes: {
          'from': 'bob@xmpp.test/x',
          'to': '${alice.jid}/chat',
          'id': 'i1',
        },
        children: [
          XmppElement(
            'x',
            xmlns: 'jabber:x:conference',
            attributes: {'jid': 'den@conference.xmpp.test'},
          ),
        ],
      ),
    );
    await _until(() => alice.chat('den@conference.xmpp.test') != null);
    expect(alice.chat('den@conference.xmpp.test')!.request, isTrue);
    expect(server.rooms, isEmpty);
    alice.client.acceptRequest('den@conference.xmpp.test');
    await _until(() => server.rooms['den@conference.xmpp.test'] != null);
  });

  test(
    'blocking drops the chat and the server holds their messages back',
    () async {
      final alice = await person('alice');
      final bob = await person('bob');
      bob.client.startChat(alice.jid);
      await bob.client.sendText(alice.jid, 'spam');
      await _until(() => alice.chat(bob.jid) != null);
      await alice.client.block(bob.jid);
      expect(alice.chat(bob.jid), isNull);
      expect(server.blocklists[alice.jid], {bob.jid});
      await bob.client.sendText(alice.jid, 'more spam');
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(alice.chat(bob.jid), isNull);
    },
  );

  test('files go through HTTP upload with only allowed headers', () async {
    final alice = await person('alice');
    final bob = await person('bob');
    alice.client.startChat(bob.jid);
    bob.client.startChat(alice.jid);
    await _until(() => alice.client.canSendFiles);
    final dir = await Directory.systemTemp.createTemp('xmpp_upload');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/photo.jpg')..writeAsBytesSync([1, 2, 3]);
    await alice.client.sendFile(bob.jid, file, contentType: 'image/jpeg');
    final (url, headers) = alice.puts.single;
    expect(url.toString(), 'https://upload.xmpp.test/put/0');
    expect(headers, {'Authorization': 'Basic token0'});
    await _until(() => bob.messages(alice.jid).isNotEmpty);
    expect(
      bob.messages(alice.jid).single.fileUrl,
      'https://upload.xmpp.test/get/0/photo.jpg',
    );
  });

  test('xmpp: links are read', () {
    expect(
      parseXmppUri('xmpp:den@conference.example.org?join')?.jid,
      'den@conference.example.org',
    );
    expect(
      parseXmppUri('xmpp:den@conference.example.org?join')?.action,
      'join',
    );
    expect(parseXmppUri('xmpp:alice@example.org')?.action, isNull);
    expect(parseXmppUri('https://example.org'), isNull);
  });

  test('the model is bounded and survives a round trip', () {
    var chats = const XmppChats();
    for (var i = 0; i < XmppChats.maxMessagesPerChat + 20; i++) {
      chats = chats.addMessage(
        'a@b.c',
        XmppChatMessage(
          id: 'm$i',
          from: 'a@b.c',
          text: 'x' * (i == 0 ? XmppChats.maxTextChars + 5 : 3),
          at: DateTime.utc(2026, 1, 1).add(Duration(seconds: i)),
          outgoing: false,
        ),
      );
    }
    expect(chats.chats['a@b.c']!.messages.length, XmppChats.maxMessagesPerChat);
    // The same message twice is kept once.
    final again = chats.addMessage(
      'a@b.c',
      chats.chats['a@b.c']!.messages.last,
    );
    expect(again.chats['a@b.c']!.messages.length, XmppChats.maxMessagesPerChat);
    final copy = XmppChats.fromJson(chats.toJson());
    expect(copy.chats['a@b.c']!.messages.length, XmppChats.maxMessagesPerChat);
    expect(copy.chats['a@b.c']!.unread, chats.chats['a@b.c']!.unread);
    expect(boundedXmppText('y' * 20000).length, XmppChats.maxTextChars + 1);
  });
}
