/// Linking a new device to an account (M29): the QR code the new device
/// shows, the 6-digit code both devices show, and sealing what passes
/// between them.
///
/// The QR code carries a fresh random link secret, so only someone who
/// saw it can talk to the waiting device; the code (from both devices'
/// signing keys and the secret) is compared by the user on both screens
/// before the account's keys are sent, so a photographed QR code used by
/// someone else is caught.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

const String _qrPrefix = 'cl1';

/// Largest sealed link message accepted (the grant carries the contacts).
const int maxLinkMessageBytes = 4 * 1024 * 1024;

/// What the new device's QR code says.
class LinkInvitation {
  const LinkInvitation({
    required this.deviceId,
    required this.encryptionKeyBase64,
    required this.signingKeyBase64,
    required this.linkSecret,
    this.irohEndpointId,
  });

  final String deviceId;
  final String encryptionKeyBase64;
  final String signingKeyBase64;
  final String? irohEndpointId;

  /// 32 random bytes only the QR code carries.
  final Uint8List linkSecret;

  static Uint8List newSecret([Random? random]) {
    final source = random ?? Random.secure();
    return Uint8List.fromList(List.generate(32, (_) => source.nextInt(256)));
  }

  String encode() => [
    _qrPrefix,
    deviceId,
    encryptionKeyBase64,
    signingKeyBase64,
    irohEndpointId ?? '',
    base64UrlEncode(linkSecret),
  ].join('|');

  static LinkInvitation? tryParse(String text) {
    final parts = text.trim().split('|');
    if (parts.length != 6 || parts[0] != _qrPrefix) return null;
    final deviceId = parts[1];
    if (deviceId.isEmpty || deviceId.length > 128) return null;
    Uint8List secret;
    try {
      if (base64Decode(parts[2]).length != 32 ||
          base64Decode(parts[3]).length != 32) {
        return null;
      }
      secret = base64Url.decode(base64Url.normalize(parts[5]));
    } on FormatException {
      return null;
    }
    if (secret.length != 32 || parts[4].length > 128) return null;
    return LinkInvitation(
      deviceId: deviceId,
      encryptionKeyBase64: parts[2],
      signingKeyBase64: parts[3],
      irohEndpointId: parts[4].isEmpty ? null : parts[4],
      linkSecret: secret,
    );
  }
}

/// The 6 digits both devices show: the same only when both have the same
/// pair of devices and the same QR code.
Future<String> linkConfirmationCode({
  required String existingSigningKeyBase64,
  required String newSigningKeyBase64,
  required Uint8List linkSecret,
}) async {
  final digest = await Sha256().hash([
    ...utf8.encode('conest/link/v1/code\n'),
    ...base64Decode(existingSigningKeyBase64),
    ...base64Decode(newSigningKeyBase64),
    ...linkSecret,
  ]);
  final bytes = digest.bytes;
  final value =
      (bytes[0] << 24 | bytes[1] << 16 | bytes[2] << 8 | bytes[3]) & 0x7fffffff;
  return (value % 1000000).toString().padLeft(6, '0');
}

Future<SecretKey> _messageKey({
  required List<int> sharedSecret,
  required Uint8List linkSecret,
  required String purpose,
}) => Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
  secretKey: SecretKey(sharedSecret),
  nonce: linkSecret,
  info: utf8.encode('conest/link/v1/$purpose'),
);

/// Seals [plaintext] for the device whose encryption key is
/// [recipientEncryptionKeyBase64], bound to the link secret: a fresh
/// ephemeral key each time, so each message has its own key.
Future<Map<String, String>> sealLinkMessage({
  required String purpose,
  required List<int> plaintext,
  required String recipientEncryptionKeyBase64,
  required Uint8List linkSecret,
}) async {
  final ephemeral = await X25519().newKeyPair();
  final shared = await X25519().sharedSecretKey(
    keyPair: ephemeral,
    remotePublicKey: SimplePublicKey(
      base64Decode(recipientEncryptionKeyBase64),
      type: KeyPairType.x25519,
    ),
  );
  final key = await _messageKey(
    sharedSecret: await shared.extractBytes(),
    linkSecret: linkSecret,
    purpose: purpose,
  );
  final box = await Chacha20.poly1305Aead().encrypt(
    plaintext,
    secretKey: key,
    aad: utf8.encode(purpose),
  );
  return {
    'purpose': purpose,
    'ephemeralKey': base64Encode((await ephemeral.extractPublicKey()).bytes),
    'nonce': base64Encode(box.nonce),
    'ciphertext': base64Encode(box.cipherText),
    'mac': base64Encode(box.mac.bytes),
  };
}

/// Opens a message [sealLinkMessage] made for this device (its X25519
/// private key [encryptionPrivateKeyBase64]); null when it is not
/// authentic, for another purpose, or too large.
Future<List<int>?> openLinkMessage({
  required String purpose,
  required Object? sealed,
  required String encryptionPublicKeyBase64,
  required String encryptionPrivateKeyBase64,
  required Uint8List linkSecret,
}) async {
  if (sealed is! Map || sealed['purpose'] != purpose) return null;
  try {
    final ciphertext = base64Decode(sealed['ciphertext'] as String);
    if (ciphertext.length > maxLinkMessageBytes) return null;
    final keyPair = SimpleKeyPairData(
      base64Decode(encryptionPrivateKeyBase64),
      publicKey: SimplePublicKey(
        base64Decode(encryptionPublicKeyBase64),
        type: KeyPairType.x25519,
      ),
      type: KeyPairType.x25519,
    );
    final shared = await X25519().sharedSecretKey(
      keyPair: keyPair,
      remotePublicKey: SimplePublicKey(
        base64Decode(sealed['ephemeralKey'] as String),
        type: KeyPairType.x25519,
      ),
    );
    final key = await _messageKey(
      sharedSecret: await shared.extractBytes(),
      linkSecret: linkSecret,
      purpose: purpose,
    );
    return await Chacha20.poly1305Aead().decrypt(
      SecretBox(
        ciphertext,
        nonce: base64Decode(sealed['nonce'] as String),
        mac: Mac(base64Decode(sealed['mac'] as String)),
      ),
      secretKey: key,
      aad: utf8.encode(purpose),
    );
  } catch (_) {
    return null;
  }
}
