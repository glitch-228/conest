import 'dart:convert';

import 'package:conest/src/account/account_model.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

Future<({String publicKey, String privateKey})> _deviceKeys() async {
  final pair = await Ed25519().newKeyPair();
  return (
    publicKey: base64Encode((await pair.extractPublicKey()).bytes),
    privateKey: base64Encode(await pair.extractPrivateKeyBytes()),
  );
}

String _key(int fill) => base64Encode(List<int>.filled(32, fill));

void main() {
  final now = DateTime.utc(2026, 10, 14, 12);

  Future<DeviceCert> cert(
    AccountKeys account,
    String deviceId, {
    String accountId = 'acc-1',
    DateTime? linkedAt,
    String name = 'Pixel 8',
  }) => DeviceCert.issue(
    account: account,
    accountId: accountId,
    deviceId: deviceId,
    encryptionKeyBase64: _key(1),
    signingKeyBase64: _key(2),
    irohEndpointId: 'iroh-$deviceId',
    name: name,
    linkedAt: linkedAt ?? now,
  );

  group('upgrade', () {
    test(
      'both keys sign it, and only the pinned device key is accepted',
      () async {
        final device = await _deviceKeys();
        final account = await AccountKeys.generate();
        final upgrade = await AccountUpgrade.create(
          accountId: 'acc-1',
          deviceId: 'dev-1',
          deviceSigningPublicKeyBase64: device.publicKey,
          deviceSigningPrivateKeyBase64: device.privateKey,
          account: account,
          issuedAt: now,
        );
        expect(
          await upgrade.verify(
            accountId: 'acc-1',
            deviceId: 'dev-1',
            pinnedDeviceSigningKeyBase64: device.publicKey,
          ),
          isTrue,
        );
        // A contact who pinned another key for that device refuses it.
        final other = await _deviceKeys();
        expect(
          await upgrade.verify(
            accountId: 'acc-1',
            deviceId: 'dev-1',
            pinnedDeviceSigningKeyBase64: other.publicKey,
          ),
          isFalse,
        );
        // Someone else's account key swapped in breaks both signatures.
        final mallory = await AccountKeys.generate();
        final swapped = AccountUpgrade.fromJson({
          ...upgrade.toJson(),
          'accountKey': mallory.publicKeyBase64,
        })!;
        expect(
          await swapped.verify(
            accountId: 'acc-1',
            deviceId: 'dev-1',
            pinnedDeviceSigningKeyBase64: device.publicKey,
          ),
          isFalse,
        );
        // Survives a round trip.
        final restored = AccountUpgrade.fromJson(
          jsonDecode(jsonEncode(upgrade.toJson())),
        )!;
        expect(
          await restored.verify(
            accountId: 'acc-1',
            deviceId: 'dev-1',
            pinnedDeviceSigningKeyBase64: device.publicKey,
          ),
          isTrue,
        );
      },
    );

    test('an upgrade signed only by the account key is refused', () async {
      final device = await _deviceKeys();
      final account = await AccountKeys.generate();
      final upgrade = await AccountUpgrade.create(
        accountId: 'acc-1',
        deviceId: 'dev-1',
        deviceSigningPublicKeyBase64: device.publicKey,
        deviceSigningPrivateKeyBase64: device.privateKey,
        account: account,
        issuedAt: now,
      );
      final forged = AccountUpgrade.fromJson({
        ...upgrade.toJson(),
        'deviceSignature': upgrade.accountSignatureBase64,
      })!;
      expect(
        await forged.verify(
          accountId: 'acc-1',
          deviceId: 'dev-1',
          pinnedDeviceSigningKeyBase64: device.publicKey,
        ),
        isFalse,
      );
    });
  });

  group('device certificates', () {
    test(
      'hold for their account key only, and any change breaks them',
      () async {
        final account = await AccountKeys.generate();
        final other = await AccountKeys.generate();
        final device = await cert(account, 'dev-2');
        expect(await device.verify(account.publicKeyBase64), isTrue);
        expect(await device.verify(other.publicKeyBase64), isFalse);
        final renamed = DeviceCert.fromJson({
          ...device.toJson(),
          'name': 'Attacker phone',
        })!;
        expect(await renamed.verify(account.publicKeyBase64), isFalse);
        final rekeyed = DeviceCert.fromJson({
          ...device.toJson(),
          'encryptionKey': _key(9),
        })!;
        expect(await rekeyed.verify(account.publicKeyBase64), isFalse);
      },
    );

    test('a new device waits a day before managing others', () async {
      final account = await AccountKeys.generate();
      final device = await cert(account, 'dev-2');
      expect(device.mayManageDevicesAt(now), isFalse);
      expect(
        device.mayManageDevicesAt(now.add(const Duration(hours: 23))),
        isFalse,
      );
      expect(
        device.mayManageDevicesAt(now.add(const Duration(hours: 24))),
        isTrue,
      );
    });

    test(
      'a signature over a certificate is no signature over a list',
      () async {
        final account = await AccountKeys.generate();
        final device = await cert(account, 'dev-2');
        final list = AccountDeviceList(
          accountId: 'acc-1',
          version: 1,
          devices: [device],
          revoked: const {},
          issuedAt: now,
          signatureBase64: device.signatureBase64,
        );
        expect(await list.verify(account.publicKeyBase64), isFalse);
      },
    );
  });

  group('device lists', () {
    test('verify only when every device is the account\'s own', () async {
      final account = await AccountKeys.generate();
      final good = await AccountDeviceList.issue(
        account: account,
        accountId: 'acc-1',
        version: 1,
        devices: [await cert(account, 'dev-1'), await cert(account, 'dev-2')],
        issuedAt: now,
      );
      expect(await good.verify(account.publicKeyBase64), isTrue);
      expect(good.deviceFor('dev-2')?.name, 'Pixel 8');

      // A device certified for another account, signed into this list.
      final stranger = await AccountDeviceList.issue(
        account: account,
        accountId: 'acc-1',
        version: 2,
        devices: [await cert(account, 'dev-3', accountId: 'acc-2')],
        issuedAt: now,
      );
      expect(await stranger.verify(account.publicKeyBase64), isFalse);

      final twice = await AccountDeviceList.issue(
        account: account,
        accountId: 'acc-1',
        version: 2,
        devices: [await cert(account, 'dev-1'), await cert(account, 'dev-1')],
        issuedAt: now,
      );
      expect(await twice.verify(account.publicKeyBase64), isFalse);

      final revokedButListed = await AccountDeviceList.issue(
        account: account,
        accountId: 'acc-1',
        version: 2,
        devices: [await cert(account, 'dev-1')],
        revoked: {'dev-1': now},
        issuedAt: now,
      );
      expect(await revokedButListed.verify(account.publicKeyBase64), isFalse);

      // Tampering with the version breaks the signature.
      final bumped = AccountDeviceList.fromJson({
        ...good.toJson(),
        'version': 9,
      })!;
      expect(await bumped.verify(account.publicKeyBase64), isFalse);
    });

    test(
      'newer lists replace older ones; revoked devices never return',
      () async {
        final account = await AccountKeys.generate();
        final one = await cert(account, 'dev-1');
        final two = await cert(account, 'dev-2');
        final v1 = await AccountDeviceList.issue(
          account: account,
          accountId: 'acc-1',
          version: 1,
          devices: [one, two],
          issuedAt: now,
        );
        final v2 = await AccountDeviceList.issue(
          account: account,
          accountId: 'acc-1',
          version: 2,
          devices: [one],
          revoked: {'dev-2': now},
          issuedAt: now,
        );
        expect(v2.supersedes(v1), isTrue);
        expect(v2.deviceFor('dev-2'), isNull);
        expect(v1.supersedes(v2), isFalse, reason: 'no rollback');
        expect(v2.supersedes(v2), isFalse, reason: 'same version');
        // A later list that forgets the revocation brings dev-2 back: refused.
        final v3 = await AccountDeviceList.issue(
          account: account,
          accountId: 'acc-1',
          version: 3,
          devices: [one, two],
          issuedAt: now,
        );
        expect(v3.supersedes(v2), isFalse);
        // A list of another account never replaces this one.
        final foreign = await AccountDeviceList.issue(
          account: account,
          accountId: 'acc-9',
          version: 5,
          devices: const [],
          issuedAt: now,
        );
        expect(foreign.supersedes(v2), isFalse);
      },
    );

    test('round-trips, and refuses oversized input', () async {
      final account = await AccountKeys.generate();
      final list = await AccountDeviceList.issue(
        account: account,
        accountId: 'acc-1',
        version: 4,
        devices: [await cert(account, 'dev-1')],
        revoked: {'dev-0': now},
        issuedAt: now,
      );
      final restored = AccountDeviceList.fromJson(
        jsonDecode(jsonEncode(list.toJson())),
      )!;
      expect(await restored.verify(account.publicKeyBase64), isTrue);
      expect(restored.version, 4);
      expect(restored.revoked.keys, ['dev-0']);

      final big = list.toJson()
        ..['devices'] = List.filled(
          maxAccountDevices + 1,
          (list.toJson()['devices']! as List).first,
        );
      expect(AccountDeviceList.fromJson(big), isNull);
      expect(AccountDeviceList.fromJson({'version': 'one'}), isNull);
      expect(
        () => AccountDeviceList.issue(
          account: account,
          accountId: 'acc-1',
          version: 1,
          devices: List.filled(maxAccountDevices + 1, list.devices.first),
          issuedAt: now,
        ),
        throwsArgumentError,
      );
    });
  });
}
