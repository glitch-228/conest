import 'dart:convert';
import 'dart:io';

import 'package:conest/src/xmpp/omemo/omemo_engine.dart';
import 'package:conest/src/xmpp/omemo/omemo_suite.dart';
import 'package:conest/src/xmpp/omemo/omemo_xml.dart';
import 'package:conest/src/xmpp/xmpp_carrier.dart';
import 'package:conest/src/xmpp/xmpp_chat_client.dart';
import 'package:conest/src/xmpp/xmpp_chats.dart';
import 'package:conest/src/xmpp/xmpp_omemo.dart';
import 'package:conest/src/xmpp/xmpp_session.dart';
import 'package:conest/src/xmpp/xmpp_xml.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_xmpp_server.dart';

Future<void> _until(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 15),
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

class _Person {
  _Person(
    this.server,
    String local, {
    String resource = 'chat',
    bool withOmemo = true,
    bool legacy = false,
  }) {
    server.passwords.putIfAbsent(local, () => 'pw-$local');
    session = XmppSession(
      jid: '$local@${server.domain}',
      password: server.passwords[local]!,
      resource: resource,
      endpoints: xmppEndpointCandidates(server.domain),
      connector: server.connect,
    );
    if (withOmemo) {
      omemo = XmppOmemo(
        session: session,
        load: () => omemoState,
        save: (state) =>
            omemoState = jsonDecode(jsonEncode(state)) as Map<String, Object?>,
        legacyEnabled: legacy,
      );
    }
    client = XmppChatClient(
      session: session,
      ownsSession: true,
      chats: () => chats,
      save: (next) => chats = next,
      sendReadMarkers: () => true,
      omemo: omemo,
    );
  }

  final FakeXmppServer server;
  late final XmppSession session;
  late final XmppChatClient client;
  XmppOmemo? omemo;
  Map<String, Object?>? omemoState;
  XmppChats chats = const XmppChats();

  String get jid => session.jid;

  Future<void> start() async {
    client.start();
    await _until(() => session.state == XmppSessionState.connected);
    if (omemo != null) {
      await _until(
        () => omemo!.engine != null && server.pep[jid] != null,
        reason: 'OMEMO keys published',
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }

  XmppChat? chat(String jid) => chats.chats[jid];
  List<XmppChatMessage> messages(String jid) => chat(jid)?.messages ?? const [];
}

void main() {
  late FakeXmppServer server;
  final people = <_Person>[];
  setUp(() {
    server = FakeXmppServer();
    people.clear();
  });
  tearDown(() async {
    for (final person in people) {
      await person.client.stop();
    }
  });
  Future<_Person> person(
    String name, {
    String resource = 'chat',
    bool withOmemo = true,
    bool legacy = false,
  }) async {
    final p = _Person(
      server,
      name,
      resource: resource,
      withOmemo: withOmemo,
      legacy: legacy,
    );
    people.add(p);
    await p.start();
    return p;
  }

  String everythingSent() =>
      server.received.map((stanza) => stanza.toXml()).join('\n');

  test(
    'OMEMO 2 messages reach the contact and never cross the wire as text',
    () async {
      final alice = await person('alice');
      final bob = await person('bob');
      alice.client.startChat(bob.jid);
      bob.client.startChat(alice.jid);
      await alice.client.sendText(bob.jid, 'top secret plan');
      await _until(() => bob.messages(alice.jid).isNotEmpty);
      final received = bob.messages(alice.jid).single;
      expect(received.text, 'top secret plan');
      expect(received.security, XmppSecurity.omemo2);
      expect(alice.messages(bob.jid).single.security, XmppSecurity.omemo2);
      await bob.client.sendText(alice.jid, 'agreed, second secret');
      await _until(() => alice.messages(bob.jid).length == 2);
      expect(alice.messages(bob.jid).last.text, 'agreed, second secret');
      expect(alice.messages(bob.jid).last.security, XmppSecurity.omemo2);
      final wire = everythingSent();
      expect(wire, isNot(contains('top secret plan')));
      expect(wire, isNot(contains('second secret')));
      expect(wire, contains('urn:xmpp:omemo:2'));
    },
  );

  test('the device list and bundle are published with open access', () async {
    final alice = await person('alice');
    final node = server.pep[alice.jid]!;
    expect(node.keys, contains('urn:xmpp:omemo:2:devices'));
    expect(node.keys, contains('urn:xmpp:omemo:2:bundles'));
    expect(
      server.pepPublishes.every((publish) => publish.$4),
      isTrue,
      reason: 'publish options sent',
    );
    final list = OmemoXml.parseDeviceList(
      OmemoVersion.v2,
      node['urn:xmpp:omemo:2:devices']!['current']!,
    );
    expect(list, [alice.omemo!.engine!.deviceId]);
    final bundle = OmemoXml.parseBundle(
      OmemoVersion.v2,
      node['urn:xmpp:omemo:2:bundles']!['${alice.omemo!.engine!.deviceId}']!,
    );
    expect(bundle, isNotNull);
    expect(await bundle!.verify(), isTrue);
    // Legacy is off: nothing published for it.
    expect(node.keys.where((key) => key.startsWith('eu.siacs')), isEmpty);
  });

  test('a server that refuses publish options still gets the keys', () async {
    server.pepRejectOptions = true;
    final alice = await person('alice');
    expect(server.pep[alice.jid]!.keys, contains('urn:xmpp:omemo:2:devices'));
  });

  test('a contact without OMEMO gets plain text in auto mode only', () async {
    final alice = await person('alice');
    final bob = await person('bob', withOmemo: false);
    alice.client.startChat(bob.jid);
    bob.client.startChat(alice.jid);
    await alice.client.sendText(bob.jid, 'plain hello');
    await _until(() => bob.messages(alice.jid).isNotEmpty);
    expect(bob.messages(alice.jid).single.security, XmppSecurity.plain);
    expect(alice.messages(bob.jid).single.security, XmppSecurity.plain);
    // "Always encrypt" refuses.
    alice.client.setEncryption(bob.jid, XmppChatEncryption.on);
    await expectLater(
      alice.client.sendText(bob.jid, 'must not leak'),
      throwsA(isA<StateError>()),
    );
    expect(everythingSent(), isNot(contains('must not leak')));
    expect(alice.messages(bob.jid).last.state, XmppMessageState.failed);
  });

  test(
    'a contact whose keys cannot be read gets nothing, not plain text',
    () async {
      final alice = await person('alice');
      final bob = await person('bob');
      alice.client.startChat(bob.jid);
      server.pepUnreadable.add(bob.jid);
      await expectLater(
        alice.client.sendText(bob.jid, 'do not downgrade'),
        throwsA(isA<OmemoLookupFailed>()),
      );
      expect(everythingSent(), isNot(contains('do not downgrade')));
      expect(alice.messages(bob.jid).single.state, XmppMessageState.failed);
      // The user can choose to send in the clear.
      server.pepUnreadable.clear();
      alice.client.setEncryption(bob.jid, XmppChatEncryption.off);
      await alice.client.sendText(bob.jid, 'clear on purpose');
      expect(everythingSent(), contains('clear on purpose'));
    },
  );

  test(
    'legacy OMEMO is used only when enabled and the contact has no v2',
    () async {
      final alice = await person('alice', legacy: true);
      final bob = await person('bob', legacy: true);
      alice.client.startChat(bob.jid);
      bob.client.startChat(alice.jid);
      // Both versions are published; v2 wins.
      await alice.client.sendText(bob.jid, 'first');
      await _until(() => bob.messages(alice.jid).isNotEmpty);
      expect(bob.messages(alice.jid).single.security, XmppSecurity.omemo2);
      // A contact that only has legacy devices gets legacy, marked as such.
      server.pep[bob.jid]!.remove('urn:xmpp:omemo:2:devices');
      alice.omemo!.forgetLookups();
      await alice.client.sendText(bob.jid, 'only legacy secret');
      await _until(() => bob.messages(alice.jid).length == 2);
      final legacy = bob.messages(alice.jid).last;
      expect(legacy.text, 'only legacy secret');
      expect(legacy.security, XmppSecurity.legacyOmemo);
      expect(everythingSent(), isNot(contains('only legacy secret')));
      expect(everythingSent(), contains('eu.siacs.conversations.axolotl'));
    },
  );

  test('legacy OMEMO messages are not read while it is off', () async {
    final alice = await person('alice', legacy: true);
    // Bobby appears to alice as a legacy-only contact.
    final bobLegacy = await person('bobby', legacy: true);
    server.pep[bobLegacy.jid]!.remove('urn:xmpp:omemo:2:devices');
    alice.client.startChat(bobLegacy.jid);
    await alice.client.sendText(bobLegacy.jid, 'legacy text');
    await _until(
      () => bobLegacy.messages(alice.jid).isNotEmpty,
      reason: 'first legacy message',
    );
    expect(bobLegacy.messages(alice.jid).single.text, 'legacy text');
    bobLegacy.omemo!.legacyEnabled = false;
    await alice.client.sendText(bobLegacy.jid, 'second legacy text');
    await _until(
      () => bobLegacy.messages(alice.jid).length == 2,
      reason: 'unreadable placeholder',
    );
    final shown = bobLegacy.messages(alice.jid).last;
    expect(shown.security, XmppSecurity.unreadable);
    expect(shown.text, '');
  });

  test('a message not meant for this device is shown as unreadable', () async {
    final alice = await person('alice');
    final bob = await person('bob');
    alice.client.startChat(bob.jid);
    await alice.client.sendText(bob.jid, 'for the first device');
    await _until(() => bob.messages(alice.jid).isNotEmpty);
    // The same stanza sent to a bob who has another device id.
    final carol = await person('carol');
    final stanza = server.received
        .where((s) => s.child('encrypted', OmemoVersion.v2.namespace) != null)
        .last;
    server.inject(
      XmppElement(
        'message',
        attributes: {
          'from': alice.jid,
          'to': carol.jid,
          'type': 'chat',
          'id': 'misdirected',
        },
        children: [...stanza.children],
      ),
    );
    await _until(() => carol.messages(alice.jid).isNotEmpty);
    final shown = carol.messages(alice.jid).single;
    expect(shown.security, XmppSecurity.unreadable);
    expect(shown.securityNote, isNotNull);
  });

  test('a replayed encrypted message does not appear twice', () async {
    final alice = await person('alice');
    final bob = await person('bob');
    alice.client.startChat(bob.jid);
    await alice.client.sendText(bob.jid, 'once');
    await _until(() => bob.messages(alice.jid).isNotEmpty);
    final stanza = server.received
        .where((s) => s.child('encrypted', OmemoVersion.v2.namespace) != null)
        .last;
    server.inject(
      XmppElement(
        'message',
        attributes: {
          'from': alice.jid,
          'to': bob.jid,
          'type': 'chat',
          'id': stanza.attr('id')!,
        },
        children: [...stanza.children],
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(bob.messages(alice.jid), hasLength(1));
  });

  test(
    'an encrypted message is corrected only by an encrypted correction',
    () async {
      final alice = await person('alice');
      final bob = await person('bob');
      alice.client.startChat(bob.jid);
      bob.client.startChat(alice.jid);
      final id = await alice.client.sendText(bob.jid, 'original words');
      await _until(() => bob.messages(alice.jid).isNotEmpty);
      // A server (or anyone able to forge the sender) sends a plain edit.
      server.inject(
        XmppElement(
          'message',
          attributes: {
            'from': alice.jid,
            'to': bob.jid,
            'type': 'chat',
            'id': 'forged',
          },
          children: [
            XmppElement('body', text: 'forged words'),
            XmppElement(
              'replace',
              xmlns: XmppNs.correction,
              attributes: {'id': id},
            ),
          ],
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(bob.messages(alice.jid).single.text, 'original words');
      // The real, encrypted correction is accepted.
      await alice.client.correct(bob.jid, id, 'corrected words');
      await _until(
        () => bob.messages(alice.jid).single.text == 'corrected words',
      );
      expect(bob.messages(alice.jid).single.security, XmppSecurity.omemo2);
      expect(everythingSent(), isNot(contains('corrected words')));
    },
  );

  test('files are not sent in the clear to an encrypted chat', () async {
    final alice = await person('alice');
    final bob = await person('bob');
    alice.client.startChat(bob.jid);
    await expectLater(
      alice.client.sendFile(bob.jid, File('does-not-matter.bin')),
      throwsA(isA<StateError>()),
    );
    expect(server.uploads, isEmpty);
  });

  test('a changed key for a known device is refused, not trusted', () async {
    final alice = await person('alice');
    final bob = await person('bob');
    alice.client.startChat(bob.jid);
    await alice.client.sendText(bob.jid, 'hello');
    await _until(() => bob.messages(alice.jid).isNotEmpty);
    // An attacker replaces Bob's bundle with their own under the same id.
    final impostor = await OmemoEngine.create();
    final deviceId = bob.omemo!.engine!.deviceId;
    server.pep[bob.jid]!['urn:xmpp:omemo:2:bundles']!['$deviceId'] =
        OmemoXml.bundle(await impostor.ownBundle(OmemoVersion.v2));
    // Without a session the new bundle would be used: simulate a new
    // install of Alice's that remembers the key.
    alice.omemo!.engine!.sessions.clear();
    alice.omemo!.forgetLookups();
    await expectLater(
      alice.client.sendText(bob.jid, 'to the impostor'),
      throwsA(isA<OmemoNoRecipients>()),
    );
    expect(alice.omemo!.skippedDevices.single.$3, contains('changed'));
    expect(everythingSent(), isNot(contains('to the impostor')));
  });

  test(
    'a device the user distrusts gets nothing and its messages are marked',
    () async {
      final alice = await person('alice');
      final bob = await person('bob');
      alice.client.startChat(bob.jid);
      bob.client.startChat(alice.jid);
      await alice.client.sendText(bob.jid, 'hello');
      await _until(() => bob.messages(alice.jid).isNotEmpty);
      await bob.client.sendText(alice.jid, 'hello back');
      await _until(() => alice.messages(bob.jid).length == 2);
      final bobDevice = bob.omemo!.engine!.deviceId;
      alice.omemo!.engine!.setTrust(bob.jid, bobDevice, OmemoTrust.distrusted);
      await expectLater(
        alice.client.sendText(bob.jid, 'no more'),
        throwsA(isA<OmemoNoRecipients>()),
      );
      // Messages from it are still shown, with a warning mark.
      await bob.client.sendText(alice.jid, 'still talking');
      await _until(() => alice.messages(bob.jid).length == 4);
      expect(alice.messages(bob.jid).last.security, XmppSecurity.untrusted);
    },
  );

  test(
    'every device of the contact and of the own account gets a copy',
    () async {
      final alice1 = await person('alice', resource: 'phone');
      final alice2 = await person('alice', resource: 'laptop');
      final bob = await person('bob');
      alice1.client.startChat(bob.jid);
      bob.client.startChat(alice1.jid);
      // Both of Alice's devices see each other in the device list.
      await alice1.omemo!.setUp();
      await alice2.omemo!.setUp();
      await alice1.client.sendText(bob.jid, 'from the phone');
      await _until(() => bob.messages(alice1.jid).isNotEmpty);
      await _until(
        () => alice2.messages(bob.jid).isNotEmpty,
        reason: 'the laptop reads the copy of the phone\'s message',
      );
      final copy = alice2.messages(bob.jid).single;
      expect(copy.text, 'from the phone');
      expect(copy.outgoing, isTrue);
      expect(copy.security, XmppSecurity.omemo2);
      // And a reply from Bob reaches both devices.
      await bob.client.sendText(alice1.jid, 'reply to both');
      await _until(() => alice1.messages(bob.jid).length == 2);
      await _until(() => alice2.messages(bob.jid).length == 2);
      expect(alice2.messages(bob.jid).last.text, 'reply to both');
    },
  );

  test(
    'the engine state is saved and the conversation continues after a restart',
    () async {
      final alice = await person('alice');
      final bob = await person('bob');
      alice.client.startChat(bob.jid);
      bob.client.startChat(alice.jid);
      await alice.client.sendText(bob.jid, 'before');
      await _until(() => bob.messages(alice.jid).isNotEmpty);
      await bob.client.sendText(alice.jid, 'ack');
      await _until(() => alice.messages(bob.jid).length == 2);
      expect(alice.omemoState, isNotNull);
      final saved = alice.omemoState;
      await alice.client.stop();
      final again = _Person(server, 'alice', resource: 'chat2')
        ..omemoState = saved
        ..chats = alice.chats;
      people.add(again);
      await again.start();
      expect(again.omemo!.engine!.deviceId, alice.omemo!.engine!.deviceId);
      await again.client.sendText(bob.jid, 'after restart');
      await _until(() => bob.messages(alice.jid).length == 3);
      expect(bob.messages(alice.jid).last.text, 'after restart');
      expect(bob.messages(alice.jid).last.security, XmppSecurity.omemo2);
    },
  );
}
