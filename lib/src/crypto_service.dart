import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'beam_protocol.dart';
import 'models.dart';
import 'group_file_crypto.dart';
import 'ratchet.dart';

/// Envelope kinds that travel in forward-secret Olm sessions (protocol
/// version 3) once a session with the recipient exists. Bootstrap, debug and
/// high-volume transfer kinds keep the static pairwise key: transfer content
/// is already encrypted under per-transfer keys carried by ratcheted kinds.
const Set<String> ratchetedEnvelopeKinds = <String>{
  'ratchet_hello',
  'ratchet_bulk_key',
  'direct_message',
  'group_message',
  'group_history',
  'group_membership',
  'group_membership_ack',
  'group_leave',
  'ack',
  'contact_remove',
  'route_update',
  'attachment_offer',
  'attachment_complete',
  'attachment_cancel',
  'attachment_pause_control',
  'message_edit',
  'message_delete',
  'message_reaction',
  'voice_call_signal',
};

/// Ratchet state is keyed by device id and static key together, so a device
/// id claimed by a different static key (for example a forged group member
/// profile) can never reach another identity's sessions.
String ratchetPeerId(ContactRecord peer) =>
    '${peer.deviceId}|${peer.publicKeyBase64}';

/// A static-key envelope of a ratcheted kind from a peer already known to
/// use the ratchet.
class RatchetDowngradeException implements Exception {
  const RatchetDowngradeException();

  @override
  String toString() =>
      'RatchetDowngradeException: static-key envelope from a ratchet peer.';
}

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

  /// Forward-secret sessions; null when this build or device has none.
  RatchetSessions? ratchet;

  /// Called when a ratcheted envelope cannot be decrypted, or a ratchet peer
  /// sent static-key traffic ([downgrade]). The controller answers with a
  /// fresh bundle so the peer can start a new session.
  void Function(ContactRecord peer, {required bool downgrade})?
  onRatchetFailure;

  /// Recent ratchet plaintexts by sender and message id. Olm consumes each
  /// message key, so an identical copy arriving again (a second route) must
  /// be answered from here rather than failing as a desync.
  final _ratchetPlaintexts = <String, (String, String, String)>{};

  /// This device's bulk key toward a peer for group-file frames, already
  /// delivered over the ratchet; null keeps the static pairwise key.
  Future<RatchetBulkKey?> Function(ContactRecord peer)? groupFileSendKey;
  static const int _ratchetPlaintextCacheSize = 256;

  Future<Uint8List> encryptGroupFile({
    required ContactRecord peer,
    required String groupId,
    required String eventId,
    required String requestId,
    required Uint8List bytes,
  }) async {
    final bulk = await groupFileSendKey?.call(peer);
    return encryptGroupFileBinary(
      pairwiseKey:
          bulk?.key ?? await (await sessionKeyFor(peer)).extractBytes(),
      header: GroupFileBinaryHeader(
        groupId: groupId,
        eventId: eventId,
        requestId: requestId,
        sender: _identityProvider().deviceId,
        recipient: peer.deviceId,
        epoch: bulk?.id,
      ),
      cleartext: bytes,
    );
  }

  Future<Uint8List> decryptGroupFile({
    required ContactRecord peer,
    required String groupId,
    required String eventId,
    required String requestId,
    required Uint8List bytes,
  }) async {
    final epoch = peekGroupFileBinary(bytes).epoch;
    final List<int> key;
    if (epoch == null) {
      key = await (await sessionKeyFor(peer)).extractBytes();
    } else {
      // The sender delivers a new key just before its first frame, but the
      // two travel separately; give the key a moment to be processed.
      var bulk = await ratchet?.receivedBulkKey(ratchetPeerId(peer), epoch);
      for (var attempt = 0; bulk == null && attempt < 40; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        bulk = await ratchet?.receivedBulkKey(ratchetPeerId(peer), epoch);
      }
      if (bulk == null) {
        throw const FormatException('Unknown or expired group file key.');
      }
      key = bulk;
    }
    return decryptGroupFileBinary(
      pairwiseKey: key,
      expected: GroupFileBinaryHeader(
        groupId: groupId,
        eventId: eventId,
        requestId: requestId,
        sender: peer.deviceId,
        recipient: _identityProvider().deviceId,
        epoch: epoch,
      ),
      frame: bytes,
    );
  }

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
    final effectiveCreatedAt = (createdAt ?? DateTime.now()).toUtc();
    final sessions = ratchet;
    if (sessions != null &&
        ratchetedEnvelopeKinds.contains(kind) &&
        await sessions.hasSession(ratchetPeerId(contact))) {
      final header = RelayEnvelope(
        protocolVersion: 3,
        kind: kind,
        messageId: messageId,
        conversationId: conversationId,
        senderAccountId: senderAccountId,
        senderDeviceId: senderDeviceId,
        recipientDeviceId: recipientDeviceId,
        createdAt: effectiveCreatedAt,
        acknowledgedMessageId: acknowledgedMessageId,
      );
      // Olm has no associated data: bind the header inside the plaintext.
      final message = await sessions.encrypt(
        ratchetPeerId(contact),
        utf8.encode(
          jsonEncode({
            'h': utf8.decode(header.authenticatedHeaderBytes()),
            'p': plaintext,
          }),
        ),
      );
      return RelayEnvelope(
        protocolVersion: 3,
        kind: kind,
        messageId: messageId,
        conversationId: conversationId,
        senderAccountId: senderAccountId,
        senderDeviceId: senderDeviceId,
        recipientDeviceId: recipientDeviceId,
        createdAt: effectiveCreatedAt,
        ciphertextBase64: base64Encode(message.ciphertext),
        ratchetType: message.type,
        acknowledgedMessageId: acknowledgedMessageId,
      );
    }
    final secretKey = await sessionKeyFor(contact);
    final cipher = Chacha20.poly1305Aead();
    final nonce = _secureRandomBytes(cipher.nonceLength);
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

  /// [reportFailure] off: a failure says nothing about the session (a late
  /// copy of a message already received), so no new session is offered.
  Future<String> decryptMessage({
    required ContactRecord contact,
    required RelayEnvelope envelope,
    bool reportFailure = true,
  }) async {
    if (envelope.protocolVersion == 3) {
      return _decryptRatchetMessage(
        contact: contact,
        envelope: envelope,
        reportFailure: reportFailure,
      );
    }
    if (envelope.protocolVersion != 2) {
      throw const FormatException('Legacy unauthenticated envelope rejected.');
    }
    final sessions = ratchet;
    if (sessions != null && ratchetedEnvelopeKinds.contains(envelope.kind)) {
      // Static-key traffic sent before the peer switched is still accepted;
      // anything created after the peer's first ratcheted message is not.
      final confirmedAt = await sessions.confirmedAt(ratchetPeerId(contact));
      if (confirmedAt != null &&
          envelope.createdAt.toUtc().isAfter(confirmedAt)) {
        if (reportFailure) onRatchetFailure?.call(contact, downgrade: true);
        throw const RatchetDowngradeException();
      }
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

  Future<String> _decryptRatchetMessage({
    required ContactRecord contact,
    required RelayEnvelope envelope,
    bool reportFailure = true,
  }) async {
    final sessions = ratchet;
    final ciphertext = envelope.ciphertextBase64;
    final type = envelope.ratchetType;
    if (sessions == null ||
        !ratchetedEnvelopeKinds.contains(envelope.kind) ||
        ciphertext == null ||
        (type != 0 && type != 1)) {
      throw const FormatException('Unsupported ratchet envelope.');
    }
    final header = utf8.decode(envelope.authenticatedHeaderBytes());
    final cacheKey = '${ratchetPeerId(contact)}|${envelope.messageId}';
    final cached = _ratchetPlaintexts[cacheKey];
    if (cached != null && cached.$1 == ciphertext) {
      // The same ciphertext under a rewritten outer header is still forged.
      if (cached.$3 != header) {
        throw const FormatException('Ratchet envelope header mismatch.');
      }
      return cached.$2;
    }
    final List<int> clear;
    try {
      clear = await sessions.decrypt(
        ratchetPeerId(contact),
        RatchetMessage(type: type!, ciphertext: base64Decode(ciphertext)),
      );
    } on RatchetDecryptException {
      if (reportFailure) onRatchetFailure?.call(contact, downgrade: false);
      rethrow;
    }
    final inner = jsonDecode(utf8.decode(clear));
    if (inner is! Map<String, dynamic> ||
        inner['h'] != header ||
        inner['p'] is! String) {
      throw const FormatException('Ratchet envelope header mismatch.');
    }
    final plaintext = inner['p'] as String;
    _ratchetPlaintexts.remove(cacheKey);
    _ratchetPlaintexts[cacheKey] = (ciphertext, plaintext, header);
    if (_ratchetPlaintexts.length > _ratchetPlaintextCacheSize) {
      _ratchetPlaintexts.remove(_ratchetPlaintexts.keys.first);
    }
    return plaintext;
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
      'groupHistoryVersion': 1,
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
