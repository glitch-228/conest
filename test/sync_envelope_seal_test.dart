import 'dart:convert';
import 'dart:math';

import 'package:conest/src/crypto_service.dart';
import 'package:conest/src/models.dart';
import 'package:conest/src/ratchet.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_ratchet_engine.dart';

/// Counts how often a session is asked to encrypt.
class _CountingEngine implements RatchetEngine {
  _CountingEngine(this.inner);
  final RatchetEngine inner;
  int encrypts = 0;

  @override
  Map<String, dynamic> call(Map<String, Object?> request) {
    if (request['op'] == 'encrypt') encrypts++;
    return inner.call(request);
  }
}

Future<IdentityRecord> _identity(String name) async {
  final keyPair = await X25519().newKeyPair();
  final publicKey = await keyPair.extractPublicKey();
  final extracted = await keyPair.extract();
  return IdentityRecord(
    accountId: 'acct-$name',
    deviceId: 'dev-$name',
    displayName: name,
    bio: '',
    pairingNonce: 'nonce-$name',
    pairingEpochMs: 0,
    publicKeyBase64: base64Encode(publicKey.bytes),
    privateKeyBase64: base64Encode(extracted.bytes),
    configuredRelays: const [],
    localRelayPort: 0,
    relayModeEnabled: false,
    autoUseContactRelays: false,
    notificationsEnabled: false,
    androidBackgroundRuntimeEnabled: false,
    suppressReadReceipts: false,
    lanAddresses: const [],
    safetyNumber: '0000 0000 0000 0000',
    createdAt: DateTime.utc(2026),
  );
}

ContactRecord _contactFor(IdentityRecord peer) => ContactRecord(
  accountId: peer.accountId,
  deviceId: peer.deviceId,
  alias: peer.displayName,
  displayName: peer.displayName,
  bio: '',
  relayCapable: false,
  publicKeyBase64: peer.publicKeyBase64,
  routeHints: const [],
  safetyNumber: peer.safetyNumber,
  trustedAt: DateTime.utc(2026),
);

void main() {
  test(
    'a sync event is sealed when a transport takes it, not when it is queued',
    () async {
      final aliceId = await _identity('alice');
      final bobId = await _identity('bob');
      final bob = _contactFor(bobId);
      final engine = _CountingEngine(FakeRatchetEngine(random: Random(5)));
      final aliceSessions = RatchetSessions(
        engine: engine,
        store: MemoryRatchetStore(),
      );
      final bobSessions = RatchetSessions(
        engine: FakeRatchetEngine(random: Random(6)),
        store: MemoryRatchetStore(),
      );
      // A confirmed session, as between two linked devices in use.
      final peer = ratchetPeerId(bob);
      await aliceSessions.startSession(peer, await bobSessions.createBundle());
      final first = await aliceSessions.encrypt(peer, utf8.encode('open'));
      await bobSessions.decrypt(
        'alice',
        first,
        peerIdentityKey: await aliceSessions.identityKey(),
      );
      final reply = await bobSessions.encrypt('alice', utf8.encode('ok'));
      await aliceSessions.decrypt(peer, reply);
      final alice = CryptoService(identityProvider: () => aliceId)
        ..ratchet = aliceSessions
        // What the controller sets once its sessions are open.
        ..sealLater = true;
      final before = engine.encrypts;

      final envelope = await alice.encryptPayloadEnvelope(
        kind: 'account_sync',
        messageId: 'sync-1',
        conversationId: 'c',
        senderAccountId: aliceId.accountId,
        senderDeviceId: aliceId.deviceId,
        recipientDeviceId: bobId.deviceId,
        contact: bob,
        plaintext: jsonEncode({
          'events': [
            {'type': 'seen', 'ids': <String>[]},
          ],
        }),
      );

      expect(envelope.lazy, isNotNull, reason: 'it is only a header so far');
      expect(envelope.lazy!.isSealed, isFalse);
      expect(
        engine.encrypts,
        before,
        reason: 'nothing was encrypted while it waits for its turn',
      );
      // Two routes asking for it share one seal, made at that moment.
      final onTheWire = await envelope.sealed();
      await envelope.sealed();
      expect(engine.encrypts, before + 1);
      expect(onTheWire.protocolVersion, 3);
      expect(onTheWire.kind, 'account_sync');
      expect(onTheWire.ciphertextBase64, isNot(startsWith('AAAAAAAA')));
    },
  );

  test('sync events are among the kinds the sessions seal', () {
    expect(ratchetedEnvelopeKinds, contains('account_sync'));
  });
}
