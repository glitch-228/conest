import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

import 'models.dart';

/// Owns pairwise key derivation and envelope encrypt/decrypt for the
/// messenger controller. Lifted out of [MessengerController] so the
/// cryptographic boundary lives in one file.
///
/// The controller passes a current-identity provider; the service never
/// caches the identity itself, so a [resetIdentity] on the controller
/// is reflected on the next call.
class CryptoService {
  CryptoService({required IdentityRecord Function() identityProvider})
    : _identityProvider = identityProvider;

  final IdentityRecord Function() _identityProvider;

  Future<RelayEnvelope> encryptDirectMessage({
    required ContactRecord contact,
    required ChatMessage message,
  }) async {
    final me = _identityProvider();
    return encryptPayloadEnvelope(
      kind: 'direct_message',
      messageId: message.id,
      conversationId: message.conversationId,
      senderAccountId: me.accountId,
      senderDeviceId: me.deviceId,
      recipientDeviceId: contact.deviceId,
      contact: contact,
      plaintext: encodeDirectMessagePayload(message),
      createdAt: message.createdAt,
    );
  }

  Future<RelayEnvelope> encryptGroupMessage({
    required GroupRecord group,
    required ContactRecord contact,
    required ChatMessage message,
  }) async {
    final me = _identityProvider();
    return encryptPayloadEnvelope(
      kind: 'group_message',
      messageId: message.id,
      conversationId: group.groupId,
      senderAccountId: me.accountId,
      senderDeviceId: me.deviceId,
      recipientDeviceId: contact.deviceId,
      contact: contact,
      plaintext: encodeGroupMessagePayload(group: group, message: message),
      createdAt: message.createdAt,
    );
  }

  Future<RelayEnvelope> encryptPayloadEnvelope({
    required String kind,
    required String messageId,
    required String conversationId,
    required String senderAccountId,
    required String senderDeviceId,
    required String recipientDeviceId,
    required ContactRecord contact,
    required String plaintext,
    DateTime? createdAt,
    String? acknowledgedMessageId,
  }) async {
    final secretKey = await sessionKeyFor(contact);
    final cipher = Chacha20.poly1305Aead();
    final nonce = _secureRandomBytes(cipher.nonceLength);
    final secretBox = await cipher.encrypt(
      utf8.encode(plaintext),
      secretKey: secretKey,
      nonce: nonce,
      aad: utf8.encode(messageId),
    );
    return RelayEnvelope(
      kind: kind,
      messageId: messageId,
      conversationId: conversationId,
      senderAccountId: senderAccountId,
      senderDeviceId: senderDeviceId,
      recipientDeviceId: recipientDeviceId,
      createdAt: createdAt ?? DateTime.now().toUtc(),
      nonceBase64: base64Encode(secretBox.nonce),
      ciphertextBase64: base64Encode(secretBox.cipherText),
      macBase64: base64Encode(secretBox.mac.bytes),
      acknowledgedMessageId: acknowledgedMessageId,
    );
  }

  Future<String> decryptMessage({
    required ContactRecord contact,
    required RelayEnvelope envelope,
  }) async {
    final cipher = Chacha20.poly1305Aead();
    final secretKey = await sessionKeyFor(contact);
    final cleartext = await cipher.decrypt(
      SecretBox(
        base64Decode(envelope.ciphertextBase64!),
        nonce: base64Decode(envelope.nonceBase64!),
        mac: Mac(base64Decode(envelope.macBase64!)),
      ),
      secretKey: secretKey,
      aad: utf8.encode(envelope.messageId),
    );
    return utf8.decode(cleartext);
  }

  Future<DecodedDirectMessage> decryptDirectMessage({
    required ContactRecord contact,
    required RelayEnvelope envelope,
  }) async {
    final decrypted = await decryptMessage(
      contact: contact,
      envelope: envelope,
    );
    return decodeDirectMessagePayload(decrypted);
  }

  String encodeDirectMessagePayload(ChatMessage message) {
    if (!message.hasReplyPreview) {
      return message.body;
    }
    return jsonEncode({
      'version': 2,
      'body': message.body,
      'replyToMessageId': message.replyToMessageId,
      'replySnippet': message.replySnippet,
      'replySenderDeviceId': message.replySenderDeviceId,
      'replySenderDisplayName': message.replySenderDisplayName,
    });
  }

  DecodedDirectMessage decodeDirectMessagePayload(String payload) {
    try {
      final decoded = jsonDecode(payload);
      if (decoded is Map<String, dynamic> &&
          decoded['version'] == 2 &&
          decoded['body'] is String) {
        return DecodedDirectMessage(
          body: decoded['body'] as String,
          replyToMessageId: decoded['replyToMessageId'] as String?,
          replySnippet: decoded['replySnippet'] as String?,
          replySenderDeviceId: decoded['replySenderDeviceId'] as String?,
          replySenderDisplayName: decoded['replySenderDisplayName'] as String?,
        );
      }
    } catch (_) {
      // Legacy direct messages are plain-text bodies.
    }
    return DecodedDirectMessage(body: payload);
  }

  String encodeGroupMessagePayload({
    required GroupRecord group,
    required ChatMessage message,
  }) {
    return jsonEncode({
      'version': 1,
      'groupId': group.groupId,
      'groupTitle': group.title,
      'membershipVersion': group.membershipVersion,
      'body': message.body,
      'senderDisplayName': message.senderDisplayName,
      'replyToMessageId': message.replyToMessageId,
      'replySnippet': message.replySnippet,
      'replySenderDeviceId': message.replySenderDeviceId,
      'replySenderDisplayName': message.replySenderDisplayName,
    });
  }

  DecodedGroupMessage decodeGroupMessagePayload(String payload) {
    final decoded = jsonDecode(payload);
    if (decoded is! Map<String, dynamic> ||
        decoded['version'] != 1 ||
        decoded['groupId'] is! String ||
        decoded['body'] is! String) {
      throw const FormatException('Invalid group message payload.');
    }
    return DecodedGroupMessage(
      groupId: decoded['groupId'] as String,
      membershipVersion: decoded['membershipVersion'] as int? ?? 1,
      body: decoded['body'] as String,
      senderDisplayName: decoded['senderDisplayName'] as String?,
      replyToMessageId: decoded['replyToMessageId'] as String?,
      replySnippet: decoded['replySnippet'] as String?,
      replySenderDeviceId: decoded['replySenderDeviceId'] as String?,
      replySenderDisplayName: decoded['replySenderDisplayName'] as String?,
    );
  }

  /// Derives the pairwise session key with X25519 + HKDF-SHA256.
  ///
  /// A pending-verification contact has [ContactRecord.publicKeyBase64]
  /// empty, so this call throws at the crypto layer rather than producing
  /// a key — which is the v0.3.1 cryptographic block on impersonation.
  Future<SecretKey> sessionKeyFor(ContactRecord contact) async {
    final me = _identityProvider();
    final algorithm = X25519();
    final myKeyPair = SimpleKeyPairData(
      base64Decode(me.privateKeyBase64),
      publicKey: SimplePublicKey(
        base64Decode(me.publicKeyBase64),
        type: KeyPairType.x25519,
      ),
      type: KeyPairType.x25519,
    );
    final shared = await algorithm.sharedSecretKey(
      keyPair: myKeyPair,
      remotePublicKey: SimplePublicKey(
        base64Decode(contact.publicKeyBase64),
        type: KeyPairType.x25519,
      ),
    );
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    return hkdf.deriveKey(
      secretKey: shared,
      nonce: utf8.encode(conversationIdFor(contact.deviceId)),
      info: utf8.encode('conest.direct.v1'),
    );
  }

  String conversationIdFor(String peerDeviceId) {
    final me = _identityProvider();
    final ordered = [me.deviceId, peerDeviceId]..sort();
    return 'conv-${ordered.join('-')}';
  }

  Future<String> deriveSafetyNumber(List<List<int>> values) async {
    final sorted = values.map(base64Encode).toList()..sort();
    final digest = await Sha256().hash(utf8.encode(sorted.join(':')));
    final hex = digest.bytes
        .take(18)
        .map((value) => value.toRadixString(16).padLeft(2, '0'))
        .join();
    final groups = <String>[];
    for (var index = 0; index < hex.length; index += 4) {
      final next = index + 4 > hex.length ? hex.length : index + 4;
      groups.add(hex.substring(index, next));
    }
    return groups.join(' ');
  }
}

List<int> _secureRandomBytes(int length) {
  final random = Random.secure();
  return List<int>.generate(length, (_) => random.nextInt(256));
}

class DecodedDirectMessage {
  const DecodedDirectMessage({
    required this.body,
    this.replyToMessageId,
    this.replySnippet,
    this.replySenderDeviceId,
    this.replySenderDisplayName,
  });

  final String body;
  final String? replyToMessageId;
  final String? replySnippet;
  final String? replySenderDeviceId;
  final String? replySenderDisplayName;
}

class DecodedGroupMessage {
  const DecodedGroupMessage({
    required this.groupId,
    required this.membershipVersion,
    required this.body,
    this.senderDisplayName,
    this.replyToMessageId,
    this.replySnippet,
    this.replySenderDeviceId,
    this.replySenderDisplayName,
  });

  final String groupId;
  final int membershipVersion;
  final String body;
  final String? senderDisplayName;
  final String? replyToMessageId;
  final String? replySnippet;
  final String? replySenderDeviceId;
  final String? replySenderDisplayName;
}
