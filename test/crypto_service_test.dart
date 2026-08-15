import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:conest/src/crypto_service.dart';
import 'package:conest/src/models.dart';

Future<IdentityRecord> _createIdentity({required String displayName}) async {
  final algorithm = X25519();
  final keyPair = await algorithm.newKeyPair();
  final publicKey = await keyPair.extractPublicKey();
  final extracted = await keyPair.extract();
  return IdentityRecord(
    accountId: 'acct-$displayName',
    deviceId: 'dev-$displayName',
    displayName: displayName,
    bio: '',
    pairingNonce: 'nonce-$displayName',
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

ContactRecord _contactFor(IdentityRecord peer, {String? overridePublicKey}) {
  return ContactRecord(
    accountId: peer.accountId,
    deviceId: peer.deviceId,
    alias: peer.displayName,
    displayName: peer.displayName,
    bio: '',
    relayCapable: false,
    publicKeyBase64: overridePublicKey ?? peer.publicKeyBase64,
    routeHints: const [],
    safetyNumber: peer.safetyNumber,
    trustedAt: DateTime.utc(2026),
  );
}

void main() {
  test('encrypt-then-decrypt round-trips a direct message body', () async {
    final alice = await _createIdentity(displayName: 'alice');
    final bob = await _createIdentity(displayName: 'bob');

    final aliceCrypto = CryptoService(identityProvider: () => alice);
    final bobCrypto = CryptoService(identityProvider: () => bob);
    final contactForBob = _contactFor(bob);
    final contactForAlice = _contactFor(alice);

    final envelope = await aliceCrypto.encryptPayloadEnvelope(
      kind: 'direct_message',
      messageId: 'm-1',
      conversationId: aliceCrypto.conversationIdFor(bob.deviceId),
      senderAccountId: alice.accountId,
      senderDeviceId: alice.deviceId,
      recipientDeviceId: bob.deviceId,
      contact: contactForBob,
      plaintext: 'hello bob',
    );

    final plaintext = await bobCrypto.decryptMessage(
      contact: contactForAlice,
      envelope: envelope,
    );
    expect(plaintext, 'hello bob');
  });

  test('v2 AEAD rejects every authenticated-header mutation', () async {
    final alice = await _createIdentity(displayName: 'alice');
    final bob = await _createIdentity(displayName: 'bob');
    final aliceCrypto = CryptoService(identityProvider: () => alice);
    final bobCrypto = CryptoService(identityProvider: () => bob);
    final envelope = await aliceCrypto.encryptPayloadEnvelope(
      kind: 'ack',
      messageId: 'ack-1',
      conversationId: 'conv-1',
      senderAccountId: alice.accountId,
      senderDeviceId: alice.deviceId,
      recipientDeviceId: bob.deviceId,
      contact: _contactFor(bob),
      plaintext: '{"state":"delivered"}',
      createdAt: DateTime.utc(2026, 7, 13, 10),
      acknowledgedMessageId: 'message-1',
    );
    expect(envelope.protocolVersion, 2);
    final mutations = <String, Object?>{
      'protocolVersion': 1,
      'kind': 'read_receipt',
      'messageId': 'ack-2',
      'conversationId': 'conv-2',
      'senderAccountId': 'acct-attacker',
      'senderDeviceId': 'dev-attacker',
      'recipientDeviceId': 'dev-attacker',
      'createdAt': DateTime.utc(2026, 7, 13, 10, 0, 1).toIso8601String(),
      'acknowledgedMessageId': 'message-2',
    };

    for (final mutation in mutations.entries) {
      final json = Map<String, dynamic>.from(envelope.toJson());
      json[mutation.key] = mutation.value;
      final tampered = RelayEnvelope.fromJson(json);
      await expectLater(
        bobCrypto.decryptMessage(
          contact: _contactFor(alice),
          envelope: tampered,
        ),
        throwsA(anything),
        reason: '${mutation.key} must be authenticated',
      );
    }
  });

  test('v1 pairwise envelopes fail closed before decryption', () async {
    final alice = await _createIdentity(displayName: 'alice');
    final bob = await _createIdentity(displayName: 'bob');
    final crypto = CryptoService(identityProvider: () => bob);
    final legacy = RelayEnvelope(
      protocolVersion: 1,
      kind: 'direct_message',
      messageId: 'legacy-1',
      conversationId: 'conv-1',
      senderAccountId: alice.accountId,
      senderDeviceId: alice.deviceId,
      recipientDeviceId: bob.deviceId,
      createdAt: DateTime.utc(2026, 7, 13),
      nonceBase64: base64Encode(List<int>.filled(12, 0)),
      ciphertextBase64: base64Encode(const <int>[1]),
      macBase64: base64Encode(List<int>.filled(16, 0)),
    );

    await expectLater(
      crypto.decryptMessage(contact: _contactFor(alice), envelope: legacy),
      throwsA(isA<FormatException>()),
    );
  });

  test('sessionKeyFor throws when the contact has no active public key '
      '(pending-verification crypto block)', () async {
    final alice = await _createIdentity(displayName: 'alice');
    final bob = await _createIdentity(displayName: 'bob');
    final crypto = CryptoService(identityProvider: () => alice);
    final pendingBob = _contactFor(bob, overridePublicKey: '');

    await expectLater(crypto.sessionKeyFor(pendingBob), throwsA(isA<Object>()));
  });

  test('decodeDirectMessagePayload accepts version-2 reply envelope, '
      'falls back to plain text for unknown shapes', () async {
    final alice = await _createIdentity(displayName: 'alice');
    final crypto = CryptoService(identityProvider: () => alice);

    final replyShape = crypto.decodeDirectMessagePayload(
      '{"version":2,"body":"hi","replySnippet":"orig"}',
    );
    expect(replyShape.body, 'hi');
    expect(replyShape.replySnippet, 'orig');

    final legacy = crypto.decodeDirectMessagePayload('plain text body');
    expect(legacy.body, 'plain text body');
    expect(legacy.replySnippet, isNull);
  });

  test('deriveSafetyNumber is deterministic and order-independent', () async {
    final alice = await _createIdentity(displayName: 'alice');
    final crypto = CryptoService(identityProvider: () => alice);

    final first = await crypto.deriveSafetyNumber([
      [1, 2, 3],
      [4, 5, 6],
    ]);
    final second = await crypto.deriveSafetyNumber([
      [4, 5, 6],
      [1, 2, 3],
    ]);
    expect(first, second);
    expect(first.contains(' '), isTrue, reason: 'human-readable groups');
  });
}
