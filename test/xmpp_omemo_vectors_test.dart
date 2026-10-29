import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:conest/src/xmpp/omemo/omemo_engine.dart';
import 'package:conest/src/xmpp/omemo/omemo_keys.dart';
import 'package:conest/src/xmpp/omemo/omemo_random.dart';
import 'package:conest/src/xmpp/omemo/omemo_suite.dart';
import 'package:flutter_test/flutter_test.dart';

/// Replays the transcripts the reference libraries produced
/// (tool/omemo_vectors/gen_vectors.py, from python-oldmemo and
/// python-twomemo): our implementation must read every message the
/// reference wrote and, given the same random draws, write the same bytes.
///
/// XEdDSA signing in the vectors comes from the pure-Python shim in
/// tool/omemo_vectors/shim, not from libxeddsa.
Uint8List unhex(String text) => Uint8List.fromList([
  for (var i = 0; i < text.length; i += 2)
    int.parse(text.substring(i, i + 2), radix: 16),
]);

Uint8List unb64(String text) => Uint8List.fromList(base64.decode(text));

void main() {
  final file = File('test/fixtures/omemo_vectors.json');
  final present = file.existsSync();
  final fixture = present
      ? jsonDecode(file.readAsStringSync()) as Map<String, Object?>
      : <String, Object?>{};

  for (final version in OmemoVersion.values) {
    final name = version == OmemoVersion.legacy ? 'oldmemo' : 'twomemo';
    test(
      'the $name reference transcript replays byte for byte',
      () async {
        final data = fixture[name]! as Map<String, Object?>;
        final alice = data['alice']! as Map<String, Object?>;
        final bob = data['bob']! as Map<String, Object?>;
        final draws = data['draws']! as Map<String, Object?>;
        ScriptedOmemoRandom script(String actor) => ScriptedOmemoRandom([
          for (final draw in (draws[actor] as List? ?? const []))
            unhex((draw as Map)['hex'] as String),
        ]);
        final aliceRandom = script('alice');
        final bobRandom = script('bob');

        Map<String, Object?> keysJson(OmemoSignedPreKey spk, Map prekeys) => {
          'spk': spk.toJson(),
          'old': null,
          'pks': prekeys,
          'nextPk': 1000,
          'nextSpk': 1000,
        };
        final bundleJson = data['bundle']! as Map<String, Object?>;
        final spkPub = unb64(bundleJson['signedPreKey']! as String);
        final bobSpk = OmemoSignedPreKey(
          id: bob['signedPreKeyId']! as int,
          priv: unhex(bob['signedPreKeyPriv']! as String),
          pub: version == OmemoVersion.legacy ? spkPub.sublist(1) : spkPub,
          signature: unb64(bundleJson['signedPreKeySignature']! as String),
          createdAt: 0,
        );
        Future<OmemoEngine> engineFor(
          Map<String, Object?> who,
          Map prekeys,
          OmemoRandom random,
        ) async {
          final spk = who == bob
              ? bobSpk
              : OmemoSignedPreKey(
                  id: 1,
                  priv: Uint8List(32)..[0] = 1,
                  pub: Uint8List(32),
                  signature: Uint8List(64),
                  createdAt: 0,
                );
          final stored = keysJson(spk, prekeys);
          final engine = await OmemoEngine.restore(
            {
              'deviceId': who['deviceId'],
              'seed': base64.encode(unhex(who['identitySeed']! as String)),
              'keys': {for (final v in OmemoVersion.values) v.name: stored},
              'sessions': <String, Object?>{},
              'devices': <String, Object?>{},
            },
            random: random,
            now: () => 0,
          );
          return engine!;
        }

        final bobPreKeys = {
          for (final entry
              in (bob['preKeyPrivs']! as Map<String, Object?>).entries)
            entry.key: base64.encode(unhex(entry.value! as String)),
        };
        final aliceEngine = await engineFor(alice, {}, aliceRandom);
        final bobEngine = await engineFor(bob, bobPreKeys, bobRandom);

        // The reference's bundle for Bob, as Alice would fetch it.
        final preKeys = <int, Uint8List>{
          for (final entry
              in (bundleJson['preKeys']! as Map<String, Object?>).entries)
            int.parse(entry.key): version == OmemoVersion.legacy
                ? unb64(entry.value! as String).sublist(1)
                : unb64(entry.value! as String),
        };
        final identity = unb64(bundleJson['identityKey']! as String);
        final signature = unb64(bundleJson['signedPreKeySignature']! as String);
        final OmemoBundle bundle = version == OmemoVersion.legacy
            ? OmemoBundle.legacy(
                identityMontgomery: identity.sublist(1),
                signedPreKeyId: bundleJson['signedPreKeyId']! as int,
                signedPreKey: bobSpk.pub,
                signedPreKeySignature: signature,
                preKeys: preKeys,
              )
            : OmemoBundle.omemo2(
                identityEdwards: identity,
                signedPreKeyId: bundleJson['signedPreKeyId']! as int,
                signedPreKey: bobSpk.pub,
                signedPreKeySignature: signature,
                preKeys: preKeys,
              )!;
        expect(
          await bundle.verify(),
          isTrue,
          reason: 'the reference bundle must verify',
        );

        final messages = data['messages']! as List;
        for (final event in data['events']! as List) {
          final op = (event as Map)['op'] as String;
          final index = event['msg'] as int;
          final message = messages[index] as Map<String, Object?>;
          final fromAlice = message['from'] == 'alice';
          final sender = fromAlice ? aliceEngine : bobEngine;
          final receiver = fromAlice ? bobEngine : aliceEngine;
          final senderJid = (fromAlice ? alice : bob)['jid']! as String;
          final receiverJid = (fromAlice ? bob : alice)['jid']! as String;
          if (op == 'send') {
            final payload = await sender.encryptPayload(
              version,
              utf8.encode(message['plaintext']! as String),
            );
            final key = await sender.encryptKey(
              version: version,
              jid: receiverJid,
              deviceId: receiver.deviceId,
              keyMaterial: payload.keyMaterial,
              bundle: fromAlice ? bundle : null,
            );
            expect(key.keyExchange, message['kex'], reason: 'message $index');
            expect(
              base64.encode(key.blob),
              message['key'],
              reason: 'key blob of message $index',
            );
            expect(
              base64.encode(payload.ciphertext),
              message['payload'],
              reason: 'payload of message $index',
            );
            if (version == OmemoVersion.legacy) {
              expect(base64.encode(payload.iv!), message['iv']);
            }
          } else {
            final material = await receiver.decryptKey(
              version: version,
              sender: senderJid,
              senderDevice: sender.deviceId,
              blob: unb64(message['key']! as String),
              keyExchange: message['kex']! as bool,
            );
            final plain = await receiver.decryptPayload(
              version,
              unb64(message['payload']! as String),
              material,
              iv: version == OmemoVersion.legacy
                  ? unb64(message['iv']! as String)
                  : null,
            );
            expect(
              utf8.decode(plain),
              message['plaintext'],
              reason: 'message $index',
            );
          }
        }
        expect(aliceRandom.remaining, 0, reason: 'unused draws for Alice');
        expect(bobRandom.remaining, 0, reason: 'unused draws for Bob');
      },
      skip: present
          ? false
          : 'test/fixtures/omemo_vectors.json is missing: run '
                'tool/omemo_vectors/gen_vectors.py (see its header)',
    );
  }
}
