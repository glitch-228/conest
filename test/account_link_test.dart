import 'dart:convert';
import 'dart:typed_data';

import 'package:conest/src/account/account_link.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

Future<({String publicKey, String privateKey})> _x25519() async {
  final pair = await X25519().newKeyPair();
  return (
    publicKey: base64Encode((await pair.extractPublicKey()).bytes),
    privateKey: base64Encode(await pair.extractPrivateKeyBytes()),
  );
}

String _key(int fill) => base64Encode(List<int>.filled(32, fill));

void main() {
  test('the QR code round-trips and refuses anything else', () {
    final invitation = LinkInvitation(
      deviceId: 'dev-new',
      encryptionKeyBase64: _key(1),
      signingKeyBase64: _key(2),
      irohEndpointId: 'abc123',
      linkSecret: LinkInvitation.newSecret(),
    );
    final parsed = LinkInvitation.tryParse(invitation.encode())!;
    expect(parsed.deviceId, 'dev-new');
    expect(parsed.irohEndpointId, 'abc123');
    expect(parsed.linkSecret, invitation.linkSecret);
    expect(LinkInvitation.tryParse('ci6|whatever'), isNull);
    expect(
      LinkInvitation.tryParse(invitation.encode().replaceFirst(_key(1), 'xx')),
      isNull,
    );
    expect(LinkInvitation.tryParse('cl1|a|b'), isNull);
  });

  test('both devices show the same code only for the same keys, QR code '
      'and nonce', () async {
    final secret = LinkInvitation.newSecret();
    final nonce = base64Encode(LinkInvitation.newSecret());
    Future<String> code({
      String existingSigning = 'AwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwM=',
      String existingEncryption =
          'BQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQU=',
      String? linkNonce,
    }) => linkConfirmationCode(
      existingSigningKeyBase64: existingSigning,
      existingEncryptionKeyBase64: existingEncryption,
      newSigningKeyBase64: _key(4),
      newEncryptionKeyBase64: _key(6),
      linkSecret: secret,
      nonceBase64: linkNonce ?? nonce,
    );
    final shown = await code();
    expect(shown, matches(RegExp(r'^\d{6}$')));
    expect(await code(), shown);
    // Someone else's device offering instead, or another key, or another
    // nonce: another code.
    expect(await code(existingSigning: _key(9)), isNot(shown));
    expect(await code(existingEncryption: _key(9)), isNot(shown));
    expect(
      await code(linkNonce: base64Encode(LinkInvitation.newSecret())),
      isNot(shown),
    );
  });

  test('the transcript names both devices, the account and the nonce', () {
    final invitation = LinkInvitation(
      deviceId: 'dev-new',
      encryptionKeyBase64: _key(1),
      signingKeyBase64: _key(2),
      linkSecret: LinkInvitation.newSecret(),
    );
    List<int> transcript({String account = 'acc-1', String? nonce}) =>
        linkTranscript(
          step: 'offer',
          invitation: invitation,
          existingDeviceId: 'dev-old',
          existingEncryptionKeyBase64: _key(3),
          existingSigningKeyBase64: _key(4),
          accountId: account,
          nonceBase64: nonce,
        );
    expect(transcript(), transcript());
    expect(transcript(account: 'acc-2'), isNot(transcript()));
    expect(transcript(nonce: 'n'), isNot(transcript()));
    // The secret itself never appears, only its hash.
    expect(
      utf8.decode(transcript()).contains(base64Encode(invitation.linkSecret)),
      isFalse,
    );
  });

  test(
    'sealed messages open only with the device key and the QR secret',
    () async {
      final device = await _x25519();
      final secret = LinkInvitation.newSecret();
      final sealed = await sealLinkMessage(
        purpose: 'grant',
        plaintext: utf8.encode('account keys'),
        recipientEncryptionKeyBase64: device.publicKey,
        linkSecret: secret,
      );
      Future<List<int>?> open({
        String purpose = 'grant',
        Object? message,
        ({String publicKey, String privateKey})? keys,
        Uint8List? linkSecret,
      }) => openLinkMessage(
        purpose: purpose,
        sealed: message ?? sealed,
        encryptionPublicKeyBase64: (keys ?? device).publicKey,
        encryptionPrivateKeyBase64: (keys ?? device).privateKey,
        linkSecret: linkSecret ?? secret,
      );
      expect(utf8.decode((await open())!), 'account keys');
      expect(await open(linkSecret: LinkInvitation.newSecret()), isNull);
      expect(await open(keys: await _x25519()), isNull);
      expect(await open(purpose: 'offer'), isNull);
      final tampered = Map<String, String>.of(sealed)
        ..['ciphertext'] = base64Encode(
          base64Decode(sealed['ciphertext']!)..[0] ^= 1,
        );
      expect(await open(message: tampered), isNull);
      expect(await open(message: 'not a map'), isNull);
    },
  );
}
