import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'beam_protocol.dart';
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

  Future<({String publicKeyBase64, String privateKeyBase64})>
  createSigningIdentity() async {
    final keyPair = await Ed25519().newKeyPair();
    final data = await keyPair.extract();
    final publicKey = await keyPair.extractPublicKey();
    return (
      publicKeyBase64: base64Encode(publicKey.bytes),
      privateKeyBase64: base64Encode(data.bytes),
    );
  }

  String irohEndpointIdForSigningKey(String publicKeyBase64) => base64Decode(
    publicKeyBase64,
  ).map((value) => value.toRadixString(16).padLeft(2, '0')).join();

  Future<String> signContactInvite(ContactInvite invite) async {
    final me = _identityProvider();
    final publicKeyBase64 = me.signingPublicKeyBase64;
    final privateKeyBase64 = me.signingPrivateKeyBase64;
    if (publicKeyBase64 == null || privateKeyBase64 == null) {
      throw StateError('The installation signing identity is unavailable.');
    }
    if (invite.signingPublicKeyBase64 != publicKeyBase64) {
      throw StateError('Invite signing key does not match this installation.');
    }
    final pair = SimpleKeyPairData(
      base64Decode(privateKeyBase64),
      publicKey: SimplePublicKey(
        base64Decode(publicKeyBase64),
        type: KeyPairType.ed25519,
      ),
      type: KeyPairType.ed25519,
    );
    final signature = await Ed25519().sign(
      utf8.encode(invite.signingPayload()),
      keyPair: pair,
    );
    return base64Encode(signature.bytes);
  }

  Future<String> signInstallationBytes(List<int> bytes) async {
    final me = _identityProvider();
    final publicKeyBase64 = me.signingPublicKeyBase64;
    final privateKeyBase64 = me.signingPrivateKeyBase64;
    if (publicKeyBase64 == null || privateKeyBase64 == null) {
      throw StateError('The installation signing identity is unavailable.');
    }
    final signature = await Ed25519().sign(
      bytes,
      keyPair: SimpleKeyPairData(
        base64Decode(privateKeyBase64),
        publicKey: SimplePublicKey(
          base64Decode(publicKeyBase64),
          type: KeyPairType.ed25519,
        ),
        type: KeyPairType.ed25519,
      ),
    );
    return base64Encode(signature.bytes);
  }

  Future<bool> verifyInstallationBytes({
    required List<int> bytes,
    required String signatureBase64,
    required String publicKeyBase64,
  }) async {
    try {
      return Ed25519().verify(
        bytes,
        signature: Signature(
          base64Decode(signatureBase64),
          publicKey: SimplePublicKey(
            base64Decode(publicKeyBase64),
            type: KeyPairType.ed25519,
          ),
        ),
      );
    } catch (_) {
      return false;
    }
  }

  Future<BeamManifest> signBeamManifest(BeamManifest manifest) async =>
      manifest.copyWithSignature(
        await signInstallationBytes(manifest.canonicalBytes()),
      );

  Future<bool> verifyBeamManifest({
    required BeamManifest manifest,
    required String signingPublicKeyBase64,
  }) async {
    final signature = manifest.signatureBase64;
    if (signature == null) return false;
    return verifyInstallationBytes(
      bytes: manifest.canonicalBytes(),
      signatureBase64: signature,
      publicKeyBase64: signingPublicKeyBase64,
    );
  }

  Future<BeamEncryptedPayload> encryptBeamPayload({
    required ContactRecord contact,
    required String transferId,
    required Uint8List plaintext,
  }) async {
    final cipher = Chacha20.poly1305Aead();
    final nonce = _secureRandomBytes(cipher.nonceLength);
    final aad = utf8.encode('conest.beam.v1|$transferId|${contact.deviceId}');
    final box = await cipher.encrypt(
      plaintext,
      secretKey: await sessionKeyFor(contact),
      nonce: nonce,
      aad: aad,
    );
    return BeamEncryptedPayload(
      ciphertext: Uint8List.fromList(box.cipherText),
      metadataBase64: base64Url.encode(
        utf8.encode(
          jsonEncode({
            'version': 1,
            'recipientDeviceId': contact.deviceId,
            'nonceBase64': base64Encode(box.nonce),
            'macBase64': base64Encode(box.mac.bytes),
          }),
        ),
      ),
    );
  }

  Future<Uint8List> decryptBeamPayload({
    required ContactRecord contact,
    required String transferId,
    required BeamEncryptedPayload encrypted,
  }) async {
    final metadataValue = jsonDecode(
      utf8.decode(
        base64Url.decode(base64Url.normalize(encrypted.metadataBase64)),
      ),
    );
    if (metadataValue is! Map<String, dynamic> ||
        metadataValue['version'] != 1 ||
        metadataValue['recipientDeviceId'] != _identityProvider().deviceId) {
      throw const FormatException('Beam encryption metadata is invalid.');
    }
    final cleartext = await Chacha20.poly1305Aead().decrypt(
      SecretBox(
        encrypted.ciphertext,
        nonce: base64Decode(metadataValue['nonceBase64'] as String),
        mac: Mac(base64Decode(metadataValue['macBase64'] as String)),
      ),
      secretKey: await sessionKeyFor(contact),
      aad: utf8.encode(
        'conest.beam.v1|$transferId|${_identityProvider().deviceId}',
      ),
    );
    return Uint8List.fromList(cleartext);
  }

  Future<bool> verifyContactInvite(ContactInvite invite) async {
    if (!invite.usesSignedFormat) return invite.version < 6;
    try {
      final signature = Signature(
        base64Decode(invite.signatureBase64!),
        publicKey: SimplePublicKey(
          base64Decode(invite.signingPublicKeyBase64!),
          type: KeyPairType.ed25519,
        ),
      );
      return Ed25519().verify(
        utf8.encode(invite.signingPayload()),
        signature: signature,
      );
    } catch (_) {
      return false;
    }
  }

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
    final effectiveCreatedAt = (createdAt ?? DateTime.now()).toUtc();
    final header = RelayEnvelope(
      protocolVersion: 2,
      kind: kind,
      messageId: messageId,
      conversationId: conversationId,
      senderAccountId: senderAccountId,
      senderDeviceId: senderDeviceId,
      recipientDeviceId: recipientDeviceId,
      createdAt: effectiveCreatedAt,
      acknowledgedMessageId: acknowledgedMessageId,
    );
    final secretBox = await cipher.encrypt(
      utf8.encode(plaintext),
      secretKey: secretKey,
      nonce: nonce,
      aad: header.authenticatedHeaderBytes(),
    );
    return RelayEnvelope(
      protocolVersion: 2,
      kind: kind,
      messageId: messageId,
      conversationId: conversationId,
      senderAccountId: senderAccountId,
      senderDeviceId: senderDeviceId,
      recipientDeviceId: recipientDeviceId,
      createdAt: effectiveCreatedAt,
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
    if (envelope.protocolVersion != 2) {
      throw const FormatException('Legacy unauthenticated envelope rejected.');
    }
    final cipher = Chacha20.poly1305Aead();
    final secretKey = await sessionKeyFor(contact);
    final cleartext = await cipher.decrypt(
      SecretBox(
        base64Decode(envelope.ciphertextBase64!),
        nonce: base64Decode(envelope.nonceBase64!),
        mac: Mac(base64Decode(envelope.macBase64!)),
      ),
      secretKey: secretKey,
      aad: envelope.authenticatedHeaderBytes(),
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
