import 'dart:convert';
import 'dart:typed_data';

import 'package:conest/src/xmpp/omemo/omemo_crypto.dart';
import 'package:conest/src/xmpp/omemo/omemo_engine.dart';
import 'package:conest/src/xmpp/omemo/omemo_keys.dart';
import 'package:conest/src/xmpp/omemo/omemo_proto.dart';
import 'package:conest/src/xmpp/omemo/omemo_random.dart';
import 'package:conest/src/xmpp/omemo/omemo_ratchet.dart';
import 'package:conest/src/xmpp/omemo/omemo_suite.dart';
import 'package:conest/src/xmpp/omemo/omemo_xml.dart';
import 'package:conest/src/xmpp/omemo/xeddsa.dart';
import 'package:conest/src/xmpp/xmpp_xml.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List hex(String text) {
  final clean = text.replaceAll(RegExp(r'\s'), '');
  return Uint8List.fromList([
    for (var i = 0; i < clean.length; i += 2)
      int.parse(clean.substring(i, i + 2), radix: 16),
  ]);
}

String toHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// A random source that is deterministic per seed, so failures replay.
class CountingRandom implements OmemoRandom {
  CountingRandom(this.seed);
  final int seed;
  int counter = 0;

  @override
  Uint8List bytes(int length) {
    final out = Uint8List(length);
    for (var i = 0; i < length; i++) {
      counter++;
      out[i] = (counter * 2654435761 + seed * 40503 + i * 97) >> 5 & 0xff;
    }
    return out;
  }
}

Future<(OmemoEngine, OmemoEngine)> pair(int seed) async {
  final alice = await OmemoEngine.create(random: CountingRandom(seed));
  final bob = await OmemoEngine.create(random: CountingRandom(seed + 1000));
  return (alice, bob);
}

/// Alice sends [text] to Bob; returns what Bob read.
Future<String> send(
  OmemoEngine from,
  String fromJid,
  OmemoEngine to,
  String toJid,
  OmemoVersion version,
  String text, {
  OmemoBundle? bundle,
}) async {
  final payload = await from.encryptPayload(version, utf8.encode(text));
  final encrypted = await from.encryptKey(
    version: version,
    jid: toJid,
    deviceId: to.deviceId,
    keyMaterial: payload.keyMaterial,
    bundle: bundle,
  );
  final keyMaterial = await to.decryptKey(
    version: version,
    sender: fromJid,
    senderDevice: from.deviceId,
    blob: encrypted.blob,
    keyExchange: encrypted.keyExchange,
  );
  final plain = await to.decryptPayload(
    version,
    payload.ciphertext,
    keyMaterial,
    iv: payload.iv,
  );
  return utf8.decode(plain);
}

void main() {
  group('primitives', () {
    test('X25519 matches RFC 7748', () async {
      final scalar = hex(
        'a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4',
      );
      final u = hex(
        'e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c',
      );
      expect(
        toHex(await OmemoCrypto.x25519(scalar, u)),
        'c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552',
      );
    });

    test('HKDF matches RFC 5869 case 1', () async {
      final out = await OmemoCrypto.hkdf(
        hex('0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b'),
        salt: hex('000102030405060708090a0b0c'),
        info: hex('f0f1f2f3f4f5f6f7f8f9'),
        length: 42,
      );
      expect(
        toHex(out),
        '3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf'
        '34007208d5b887185865',
      );
    });

    test('Ed25519 matches RFC 8032 test 1', () async {
      final seed = hex(
        '9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60',
      );
      expect(
        toHex(await OmemoCrypto.ed25519Public(seed)),
        'd75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a',
      );
      final signature = await OmemoCrypto.ed25519Sign(seed, const []);
      expect(
        toHex(signature),
        'e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e06522490155'
        '5fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b',
      );
      expect(
        await ed25519Verify(
          await OmemoCrypto.ed25519Public(seed),
          const [],
          signature,
        ),
        isTrue,
      );
    });

    test('the Curve25519 base point maps to the Ed25519 base point', () {
      final nine = Uint8List(32)..[0] = 9;
      expect(
        toHex(montgomeryToEdwards(nine)!),
        '5866666666666666666666666666666666666666666666666666666666666666',
      );
      expect(
        toHex(
          edwardsToMontgomery(
            hex(
              '5866666666666666666666666666666666666666666666666666666666666666',
            ),
          )!,
        ),
        toHex(nine),
      );
    });

    test('the identity seed gives the same point in both forms', () async {
      final identity = await OmemoIdentity.fromSeed(
        hex('9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60'),
      );
      expect(
        toHex(edwardsToMontgomery(identity.edwards)!),
        toHex(identity.montgomery),
      );
    });

    test('XEdDSA signs for the Curve25519 key and verifies', () async {
      final identity = await OmemoIdentity.fromSeed(Uint8List(32)..[0] = 7);
      final random = CountingRandom(1);
      final message = utf8.encode('signed pre key');
      final signature = xeddsaSign(identity.scalar, message, random.bytes(64));
      expect(
        await xeddsaVerify(identity.montgomery, message, signature),
        isTrue,
      );
      expect(
        await xeddsaVerify(
          identity.montgomery,
          utf8.encode('other'),
          signature,
        ),
        isFalse,
      );
      final other = await OmemoIdentity.fromSeed(Uint8List(32)..[0] = 8);
      expect(await xeddsaVerify(other.montgomery, message, signature), isFalse);
    });

    test('protobuf codec round trips and refuses garbage', () {
      final bytes =
          (ProtoWriter()
                ..uint(1, 4294967295)
                ..bytes(2, [1, 2, 3]))
              .toBytes();
      final reader = ProtoReader.parse(bytes);
      expect(reader.requiredUint(1), 4294967295);
      expect(reader.requiredBytes(2), [1, 2, 3]);
      expect(
        () => ProtoReader.parse([0x12, 0x05, 1]),
        throwsA(isA<OmemoProtoException>()),
      );
      expect(
        () => ProtoReader.parse([0x08]),
        throwsA(isA<OmemoProtoException>()),
      );
      expect(
        () => ProtoReader.parse(Uint8List(70000)),
        throwsA(isA<OmemoProtoException>()),
      );
    });
  });

  group('stanzas', () {
    for (final version in OmemoVersion.values) {
      test(
        '${version.name} bundles survive the wire and still verify',
        () async {
          final engine = await OmemoEngine.create(random: CountingRandom(21));
          final bundle = await engine.ownBundle(version);
          final xml = OmemoXml.bundle(bundle).toXml();
          final parsed = OmemoXml.parseBundle(version, parseXmppElement(xml))!;
          expect(parsed.signedPreKeyId, bundle.signedPreKeyId);
          expect(toHex(parsed.signedPreKey), toHex(bundle.signedPreKey));
          expect(
            toHex(parsed.identityMontgomery),
            toHex(bundle.identityMontgomery),
          );
          expect(parsed.preKeys.length, bundle.preKeys.length);
          expect(await parsed.verify(), isTrue);
        },
      );

      test('${version.name} bundles with wrong sizes are refused', () async {
        final engine = await OmemoEngine.create(random: CountingRandom(22));
        final element = parseXmppElement(
          OmemoXml.bundle(await engine.ownBundle(version)).toXml(),
        );
        final key = version == OmemoVersion.legacy ? 'identityKey' : 'ik';
        element.child(key)!.text = base64.encode(List.filled(5, 1));
        expect(OmemoXml.parseBundle(version, element), isNull);
        element.child(key)!.text = '!!! not base64 !!!';
        expect(OmemoXml.parseBundle(version, element), isNull);
      });

      test('${version.name} device lists are bounded and cleaned', () {
        final root = XmppElement(
          version == OmemoVersion.legacy ? 'list' : 'devices',
          xmlns: version.namespace,
          children: [
            for (var i = 0; i < 500; i++)
              XmppElement('device', attributes: {'id': '${i + 1}'}),
            XmppElement('device', attributes: {'id': 'abc'}),
            XmppElement('device', attributes: {'id': '-4'}),
          ],
        );
        final ids = OmemoXml.parseDeviceList(version, root)!;
        expect(ids.length, OmemoXml.maxDevices);
        expect(ids.every((id) => id > 0), isTrue);
        expect(
          OmemoXml.parseDeviceList(
            version == OmemoVersion.legacy
                ? OmemoVersion.v2
                : OmemoVersion.legacy,
            root,
          ),
          isNull,
        );
      });
    }

    test('the envelope names the sender and the conversation', () {
      final xml = OmemoXml.envelope(
        content: [XmppElement('body', text: 'hi <there> & you')],
        to: 'bob@example.org',
        from: 'alice@example.org',
        at: DateTime.utc(2026, 10, 26),
        padding: 'abc',
      );
      final ok = OmemoXml.parseEnvelope(
        xml,
        from: 'alice@example.org',
        to: 'bob@example.org',
      )!;
      expect(ok.content.single.text, 'hi <there> & you');
      expect(ok.at, DateTime.utc(2026, 10, 26));
      // Moved to another conversation or claimed by another sender.
      expect(
        OmemoXml.parseEnvelope(
          xml,
          from: 'alice@example.org',
          to: 'carol@example.org',
        ),
        isNull,
      );
      expect(
        OmemoXml.parseEnvelope(
          xml,
          from: 'mallory@example.org',
          to: 'bob@example.org',
        ),
        isNull,
      );
      expect(
        OmemoXml.parseEnvelope('<x/>', from: 'a@b.c', to: 'd@e.f'),
        isNull,
      );
      expect(
        OmemoXml.parseEnvelope('not xml at all <<', from: 'a@b.c', to: 'd@e.f'),
        isNull,
      );
    });

    test('an oversized payload or key element is ignored', () {
      final big = base64.encode(List.filled(OmemoXml.maxPayloadBytes + 10, 7));
      final element = XmppElement(
        'encrypted',
        xmlns: OmemoVersion.v2.namespace,
        children: [
          XmppElement(
            'header',
            attributes: {'sid': '5'},
            children: [
              XmppElement(
                'keys',
                attributes: {'jid': 'me@example.org'},
                children: [
                  XmppElement('key', attributes: {'rid': '9'}, text: 'AAAA'),
                ],
              ),
            ],
          ),
          XmppElement('payload', text: big),
        ],
      );
      expect(
        OmemoXml.parseEncrypted(
          element,
          ownJid: 'me@example.org',
          ownDevice: 9,
        ),
        isNull,
      );
    });
  });

  for (final version in OmemoVersion.values) {
    group('${version.name} sessions', () {
      const aliceJid = 'alice@example.org';
      const bobJid = 'bob@example.org';

      test('a bundle verifies and a forged one does not', () async {
        final (alice, _) = await pair(1);
        final bundle = await alice.ownBundle(version);
        expect(await bundle.verify(), isTrue);
        final forged = OmemoBundle(
          version: version,
          identityMontgomery: bundle.identityMontgomery,
          identityEdwards: bundle.identityEdwards,
          signedPreKeyId: bundle.signedPreKeyId,
          signedPreKey: Uint8List.fromList(bundle.signedPreKey)..[0] ^= 1,
          signedPreKeySignature: bundle.signedPreKeySignature,
          preKeys: bundle.preKeys,
        );
        expect(await forged.verify(), isFalse);
      });

      test('first message, reply, and a long conversation', () async {
        final (alice, bob) = await pair(2);
        final bundle = await bob.ownBundle(version);
        expect(
          await send(
            alice,
            aliceJid,
            bob,
            bobJid,
            version,
            'hello bob',
            bundle: bundle,
          ),
          'hello bob',
        );
        // Alice's second message still carries the key exchange.
        final second = await alice.encryptPayload(version, utf8.encode('two'));
        final secondKey = await alice.encryptKey(
          version: version,
          jid: bobJid,
          deviceId: bob.deviceId,
          keyMaterial: second.keyMaterial,
        );
        expect(secondKey.keyExchange, isTrue);
        await bob.decryptKey(
          version: version,
          sender: aliceJid,
          senderDevice: alice.deviceId,
          blob: secondKey.blob,
          keyExchange: true,
        );
        expect(
          await send(bob, bobJid, alice, aliceJid, version, 'hi alice'),
          'hi alice',
        );
        for (var round = 0; round < 6; round++) {
          expect(
            await send(alice, aliceJid, bob, bobJid, version, 'a$round'),
            'a$round',
          );
          expect(
            await send(bob, bobJid, alice, aliceJid, version, 'b$round'),
            'b$round',
          );
          expect(
            await send(bob, bobJid, alice, aliceJid, version, 'b$round again'),
            'b$round again',
          );
        }
      });

      test('after the answer no key exchange is sent', () async {
        final (alice, bob) = await pair(3);
        final bundle = await bob.ownBundle(version);
        await send(
          alice,
          aliceJid,
          bob,
          bobJid,
          version,
          'one',
          bundle: bundle,
        );
        await send(bob, bobJid, alice, aliceJid, version, 'two');
        final payload = await alice.encryptPayload(version, utf8.encode('x'));
        final key = await alice.encryptKey(
          version: version,
          jid: bobJid,
          deviceId: bob.deviceId,
          keyMaterial: payload.keyMaterial,
        );
        expect(key.keyExchange, isFalse);
      });

      test('out of order messages are read, replays are refused', () async {
        final (alice, bob) = await pair(4);
        final bundle = await bob.ownBundle(version);
        await send(
          alice,
          aliceJid,
          bob,
          bobJid,
          version,
          'start',
          bundle: bundle,
        );
        await send(bob, bobJid, alice, aliceJid, version, 'ack');
        final messages = <(OmemoPayload, OmemoEncryptedKey)>[];
        for (var index = 0; index < 4; index++) {
          final payload = await alice.encryptPayload(
            version,
            utf8.encode('m$index'),
          );
          messages.add((
            payload,
            await alice.encryptKey(
              version: version,
              jid: bobJid,
              deviceId: bob.deviceId,
              keyMaterial: payload.keyMaterial,
            ),
          ));
        }
        Future<String> read((OmemoPayload, OmemoEncryptedKey) message) async {
          final keyMaterial = await bob.decryptKey(
            version: version,
            sender: aliceJid,
            senderDevice: alice.deviceId,
            blob: message.$2.blob,
            keyExchange: message.$2.keyExchange,
          );
          return utf8.decode(
            await bob.decryptPayload(
              version,
              message.$1.ciphertext,
              keyMaterial,
              iv: message.$1.iv,
            ),
          );
        }

        expect(await read(messages[3]), 'm3');
        expect(await read(messages[1]), 'm1');
        expect(await read(messages[0]), 'm0');
        expect(await read(messages[2]), 'm2');
        await expectLater(
          read(messages[2]),
          throwsA(isA<OmemoDecryptException>()),
        );
      });

      test('a tampered message fails and changes nothing', () async {
        final (alice, bob) = await pair(5);
        final bundle = await bob.ownBundle(version);
        await send(
          alice,
          aliceJid,
          bob,
          bobJid,
          version,
          'start',
          bundle: bundle,
        );
        await send(bob, bobJid, alice, aliceJid, version, 'ack');
        final payload = await alice.encryptPayload(
          version,
          utf8.encode('secret'),
        );
        final key = await alice.encryptKey(
          version: version,
          jid: bobJid,
          deviceId: bob.deviceId,
          keyMaterial: payload.keyMaterial,
        );
        for (final position in [0, key.blob.length ~/ 2, key.blob.length - 1]) {
          final broken = Uint8List.fromList(key.blob)..[position] ^= 0x40;
          await expectLater(
            bob.decryptKey(
              version: version,
              sender: aliceJid,
              senderDevice: alice.deviceId,
              blob: broken,
              keyExchange: false,
            ),
            throwsA(anything),
            reason: 'byte $position',
          );
        }
        // The real message still reads afterwards.
        final material = await bob.decryptKey(
          version: version,
          sender: aliceJid,
          senderDevice: alice.deviceId,
          blob: key.blob,
          keyExchange: false,
        );
        expect(
          utf8.decode(
            await bob.decryptPayload(
              version,
              payload.ciphertext,
              material,
              iv: payload.iv,
            ),
          ),
          'secret',
        );
      });

      test('a payload with a wrong key or tag is refused', () async {
        final (alice, _) = await pair(6);
        final payload = await alice.encryptPayload(
          version,
          utf8.encode('text'),
        );
        final broken = Uint8List.fromList(payload.keyMaterial)
          ..[payload.keyMaterial.length - 1] ^= 1;
        await expectLater(
          alice.decryptPayload(
            version,
            payload.ciphertext,
            broken,
            iv: payload.iv,
          ),
          throwsA(isA<OmemoDecryptException>()),
        );
        final tooFar = Uint8List.fromList(payload.ciphertext)..[0] ^= 1;
        await expectLater(
          alice.decryptPayload(
            version,
            tooFar,
            payload.keyMaterial,
            iv: payload.iv,
          ),
          throwsA(isA<OmemoDecryptException>()),
        );
      });

      test(
        'a key exchange cannot be replayed once the pre key is spent',
        () async {
          final (alice, bob) = await pair(7);
          final bundle = await bob.ownBundle(version);
          final payload = await alice.encryptPayload(
            version,
            utf8.encode('first'),
          );
          final key = await alice.encryptKey(
            version: version,
            jid: bobJid,
            deviceId: bob.deviceId,
            keyMaterial: payload.keyMaterial,
            bundle: bundle,
          );
          Future<Uint8List> deliver(OmemoEngine to) => to.decryptKey(
            version: version,
            sender: aliceJid,
            senderDevice: alice.deviceId,
            blob: key.blob,
            keyExchange: true,
          );
          await deliver(bob);
          // The same key exchange again is the same session: fine, but a
          // second Bob that never had the pre key (or has spent it) refuses.
          final restored = await OmemoEngine.restore(
            jsonDecode(jsonEncode(bob.toJson())) as Map<String, Object?>,
          );
          expect(restored, isNotNull);
          restored!.sessions.clear();
          await expectLater(
            deliver(restored),
            throwsA(isA<OmemoKeyAgreementException>()),
          );
        },
      );

      test('a changed identity key for a known device is refused', () async {
        final (alice, bob) = await pair(8);
        final bundle = await bob.ownBundle(version);
        await send(
          alice,
          aliceJid,
          bob,
          bobJid,
          version,
          'first',
          bundle: bundle,
        );
        // Another device claims Bob's device id with its own keys.
        final impostor = await OmemoEngine.create(random: CountingRandom(99));
        alice.sessions.clear();
        final fake = await impostor.ownBundle(version);
        final payload = await alice.encryptPayload(version, utf8.encode('x'));
        await expectLater(
          alice.encryptKey(
            version: version,
            jid: bobJid,
            deviceId: bob.deviceId,
            keyMaterial: payload.keyMaterial,
            bundle: fake,
          ),
          throwsA(isA<OmemoIdentityChanged>()),
        );
      });

      test('distrusted devices get nothing', () async {
        final (alice, bob) = await pair(9);
        final bundle = await bob.ownBundle(version);
        await send(
          alice,
          aliceJid,
          bob,
          bobJid,
          version,
          'first',
          bundle: bundle,
        );
        alice.setTrust(bobJid, bob.deviceId, OmemoTrust.distrusted);
        final payload = await alice.encryptPayload(version, utf8.encode('x'));
        await expectLater(
          alice.encryptKey(
            version: version,
            jid: bobJid,
            deviceId: bob.deviceId,
            keyMaterial: payload.keyMaterial,
          ),
          throwsA(isA<OmemoKeyAgreementException>()),
        );
      });

      test('state survives saving and loading', () async {
        final (alice, bob) = await pair(10);
        final bundle = await bob.ownBundle(version);
        await send(
          alice,
          aliceJid,
          bob,
          bobJid,
          version,
          'one',
          bundle: bundle,
        );
        await send(bob, bobJid, alice, aliceJid, version, 'two');
        final aliceBack = (await OmemoEngine.restore(
          jsonDecode(jsonEncode(alice.toJson())) as Map<String, Object?>,
          random: CountingRandom(70),
        ))!;
        final bobBack = (await OmemoEngine.restore(
          jsonDecode(jsonEncode(bob.toJson())) as Map<String, Object?>,
          random: CountingRandom(71),
        ))!;
        expect(aliceBack.deviceId, alice.deviceId);
        expect(aliceBack.fingerprint, alice.fingerprint);
        expect(
          await send(
            aliceBack,
            aliceJid,
            bobBack,
            bobJid,
            version,
            'after restart',
          ),
          'after restart',
        );
        expect(
          await send(bobBack, bobJid, aliceBack, aliceJid, version, 'and back'),
          'and back',
        );
      });

      test('two sessions started at once settle', () async {
        final (alice, bob) = await pair(11);
        final aliceBundle = await alice.ownBundle(version);
        final bobBundle = await bob.ownBundle(version);
        final pa = await alice.encryptPayload(
          version,
          utf8.encode('from alice'),
        );
        final ka = await alice.encryptKey(
          version: version,
          jid: bobJid,
          deviceId: bob.deviceId,
          keyMaterial: pa.keyMaterial,
          bundle: bobBundle,
        );
        final pb = await bob.encryptPayload(version, utf8.encode('from bob'));
        final kb = await bob.encryptKey(
          version: version,
          jid: aliceJid,
          deviceId: alice.deviceId,
          keyMaterial: pb.keyMaterial,
          bundle: aliceBundle,
        );
        final readA = await bob.decryptKey(
          version: version,
          sender: aliceJid,
          senderDevice: alice.deviceId,
          blob: ka.blob,
          keyExchange: true,
        );
        final readB = await alice.decryptKey(
          version: version,
          sender: bobJid,
          senderDevice: bob.deviceId,
          blob: kb.blob,
          keyExchange: true,
        );
        expect(readA, pa.keyMaterial);
        expect(readB, pb.keyMaterial);
        // Both now have two sessions; messages still flow either way.
        expect(
          await send(alice, aliceJid, bob, bobJid, version, 'next from alice'),
          'next from alice',
        );
        expect(
          await send(bob, bobJid, alice, aliceJid, version, 'next from bob'),
          'next from bob',
        );
        expect(
          await send(alice, aliceJid, bob, bobJid, version, 'and again'),
          'and again',
        );
      });

      test('skipping too many messages is refused', () async {
        final (alice, bob) = await pair(12);
        final bundle = await bob.ownBundle(version);
        await send(
          alice,
          aliceJid,
          bob,
          bobJid,
          version,
          'start',
          bundle: bundle,
        );
        await send(bob, bobJid, alice, aliceJid, version, 'ack');
        late OmemoEncryptedKey last;
        for (
          var index = 0;
          index < OmemoRatchet.maxSkipPerMessage + 5;
          index++
        ) {
          last = await alice.encryptKey(
            version: version,
            jid: bobJid,
            deviceId: bob.deviceId,
            keyMaterial: Uint8List(version.suite.payloadKeyLength + 16),
          );
        }
        await expectLater(
          bob.decryptKey(
            version: version,
            sender: aliceJid,
            senderDevice: alice.deviceId,
            blob: last.blob,
            keyExchange: false,
          ),
          throwsA(isA<OmemoDecryptException>()),
        );
      });

      test('pre keys are spent and refilled', () async {
        final (alice, bob) = await pair(13);
        final before = bob.keys[version]!.preKeys.length;
        final bundle = await bob.ownBundle(version);
        await send(alice, aliceJid, bob, bobJid, version, 'x', bundle: bundle);
        expect(bob.keys[version]!.preKeys.length, before - 1);
        for (var index = 0; index < 90; index++) {
          bob.keys[version]!.preKeys.remove(
            bob.keys[version]!.preKeys.keys.first,
          );
        }
        expect(await bob.maintainKeys(), isTrue);
        expect(bob.keys[version]!.preKeys.length, OmemoSuiteKeys.targetPreKeys);
      });
    });
  }

  test('both versions share one identity and fingerprint', () async {
    final engine = await OmemoEngine.create(random: CountingRandom(5));
    final legacy = await engine.ownBundle(OmemoVersion.legacy);
    final v2 = await engine.ownBundle(OmemoVersion.v2);
    expect(toHex(legacy.identityMontgomery), toHex(v2.identityMontgomery));
    expect(
      engine.fingerprint,
      matches(RegExp(r'^([0-9a-f]{8} ){7}[0-9a-f]{8}$')),
    );
  });

  test('the fingerprint of a device does not depend on the version', () async {
    final (alice, bob) = await pair(14);
    final legacyBundle = await bob.ownBundle(OmemoVersion.legacy);
    await send(
      alice,
      'a@x',
      bob,
      'b@x',
      OmemoVersion.legacy,
      'hi',
      bundle: legacyBundle,
    );
    final v2Bundle = await bob.ownBundle(OmemoVersion.v2);
    await send(
      alice,
      'a@x',
      bob,
      'b@x',
      OmemoVersion.v2,
      'hi',
      bundle: v2Bundle,
    );
    expect(alice.devicesOf('b@x').length, 1);
    expect(
      alice.deviceRecord('b@x', bob.deviceId)!.fingerprint,
      bob.fingerprint,
    );
  });
}
