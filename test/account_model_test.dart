import 'dart:convert';

import 'package:conest/src/account/account_contacts.dart';
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

/// The device's own proof for its certificate, signed with [keys].
Future<String> _proof(
  ({String publicKey, String privateKey}) keys, {
  required String accountId,
  required String accountKey,
  required String deviceId,
  required String encryptionKey,
  required String signingKey,
  String? iroh,
}) => signEd25519(
  DeviceCert.proofBytes(
    accountId: accountId,
    accountKeyBase64: accountKey,
    deviceId: deviceId,
    encryptionKeyBase64: encryptionKey,
    signingKeyBase64: signingKey,
    irohEndpointId: iroh,
  ),
  publicKeyBase64: keys.publicKey,
  privateKeyBase64: keys.privateKey,
);

void main() {
  final now = DateTime.utc(2026, 10, 14, 12);

  Future<DeviceCert> cert(
    AccountKeys account,
    String deviceId, {
    String accountId = 'acc-1',
    DateTime? linkedAt,
    String name = 'Pixel 8',
    ({String publicKey, String privateKey})? keys,
  }) async {
    final device = keys ?? await _deviceKeys();
    return DeviceCert.issue(
      account: account,
      accountId: accountId,
      deviceId: deviceId,
      encryptionKeyBase64: _key(1),
      signingKeyBase64: device.publicKey,
      irohEndpointId: 'iroh-$deviceId',
      name: name,
      linkedAt: linkedAt ?? now,
      proofSignatureBase64: await _proof(
        device,
        accountId: accountId,
        accountKey: account.publicKeyBase64,
        deviceId: deviceId,
        encryptionKey: _key(1),
        signingKey: device.publicKey,
        iroh: 'iroh-$deviceId',
      ),
    );
  }

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

    test('a certificate needs the device\'s own proof of its keys', () async {
      final account = await AccountKeys.generate();
      final bob = await _deviceKeys();
      final mallory = await _deviceKeys();
      // Mallory certifies Bob's signing key without holding it.
      final squatted = await DeviceCert.issue(
        account: account,
        accountId: 'acc-1',
        deviceId: 'bob-phone',
        encryptionKeyBase64: _key(1),
        signingKeyBase64: bob.publicKey,
        name: 'Bob',
        linkedAt: now,
        proofSignatureBase64: await _proof(
          mallory,
          accountId: 'acc-1',
          accountKey: account.publicKeyBase64,
          deviceId: 'bob-phone',
          encryptionKey: _key(1),
          signingKey: bob.publicKey,
        ),
      );
      expect(await squatted.verify(account.publicKeyBase64), isFalse);
      final real = await cert(account, 'bob-phone', keys: bob);
      expect(await real.verify(account.publicKeyBase64), isTrue);
    });

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

  group('a contact\'s account statement', () {
    Future<
      ({
        AccountKeys account,
        ({String publicKey, String privateKey}) anchor,
        AccountUpgrade upgrade,
        DeviceCert anchorCert,
        DeviceCert second,
      })
    >
    setUp() async {
      final account = await AccountKeys.generate();
      final anchor = await _deviceKeys();
      final upgrade = await AccountUpgrade.create(
        accountId: 'acc-1',
        deviceId: 'dev-1',
        deviceSigningPublicKeyBase64: anchor.publicKey,
        deviceSigningPrivateKeyBase64: anchor.privateKey,
        account: account,
        issuedAt: now,
      );
      final anchorCert = await DeviceCert.issue(
        account: account,
        accountId: 'acc-1',
        deviceId: 'dev-1',
        encryptionKeyBase64: _key(1),
        signingKeyBase64: anchor.publicKey,
        name: 'Laptop',
        linkedAt: now,
        proofSignatureBase64: await _proof(
          anchor,
          accountId: 'acc-1',
          accountKey: account.publicKeyBase64,
          deviceId: 'dev-1',
          encryptionKey: _key(1),
          signingKey: anchor.publicKey,
        ),
      );
      final second = await cert(account, 'dev-2');
      return (
        account: account,
        anchor: anchor,
        upgrade: upgrade,
        anchorCert: anchorCert,
        second: second,
      );
    }

    Future<Map<String, Object?>> statement(
      AccountKeys account,
      AccountUpgrade? upgrade,
      List<DeviceCert> devices, {
      int version = 1,
      Map<String, DateTime> revoked = const {},
    }) async => {
      if (upgrade != null) 'upgrade': upgrade.toJson(),
      'devices': (await AccountDeviceList.issue(
        account: account,
        accountId: 'acc-1',
        version: version,
        devices: devices,
        revoked: revoked,
        issuedAt: now,
      )).toJson(),
    };

    test('a new account key is learned from the pinned device key', () async {
      final s = await setUp();
      final update = await verifyAccountDevices(
        accountId: 'acc-1',
        anchorDeviceId: 'dev-1',
        anchorSigningKeyBase64: s.anchor.publicKey,
        knownAccountKeyBase64: null,
        knownVersion: 0,
        knownRevoked: const [],
        fromAnchor: false,
        payload: await statement(s.account, s.upgrade, [
          s.anchorCert,
          s.second,
        ]),
      );
      expect(update?.accountKeyBase64, s.account.publicKeyBase64);
      expect(update?.list.deviceFor('dev-2')?.name, 'Pixel 8');
    });

    test('a stranger\'s account key is never learned', () async {
      final s = await setUp();
      final mallory = await AccountKeys.generate();
      final malloryDevice = await _deviceKeys();
      // Mallory signs an upgrade with her own device key and account key.
      final forged = await AccountUpgrade.create(
        accountId: 'acc-1',
        deviceId: 'dev-1',
        deviceSigningPublicKeyBase64: malloryDevice.publicKey,
        deviceSigningPrivateKeyBase64: malloryDevice.privateKey,
        account: mallory,
        issuedAt: now,
      );
      final malloryAnchor = await DeviceCert.issue(
        account: mallory,
        accountId: 'acc-1',
        deviceId: 'dev-1',
        encryptionKeyBase64: _key(1),
        signingKeyBase64: s.anchor.publicKey,
        name: 'Laptop',
        linkedAt: now,
        proofSignatureBase64: await _proof(
          malloryDevice,
          accountId: 'acc-1',
          accountKey: mallory.publicKeyBase64,
          deviceId: 'dev-1',
          encryptionKey: _key(1),
          signingKey: s.anchor.publicKey,
        ),
      );
      expect(
        await verifyAccountDevices(
          accountId: 'acc-1',
          anchorDeviceId: 'dev-1',
          anchorSigningKeyBase64: s.anchor.publicKey,
          knownAccountKeyBase64: null,
          knownVersion: 0,
          knownRevoked: const [],
          fromAnchor: false,
          payload: await statement(mallory, forged, [
            malloryAnchor,
            await cert(mallory, 'dev-evil'),
          ]),
        ),
        isNull,
      );
    });

    test('once learned, the account key does not change', () async {
      final s = await setUp();
      final mallory = await AccountKeys.generate();
      expect(
        await verifyAccountDevices(
          accountId: 'acc-1',
          anchorDeviceId: 'dev-1',
          anchorSigningKeyBase64: s.anchor.publicKey,
          knownAccountKeyBase64: s.account.publicKeyBase64,
          knownVersion: 1,
          knownRevoked: const [],
          fromAnchor: true,
          payload: await statement(mallory, null, [
            await DeviceCert.issue(
              account: mallory,
              accountId: 'acc-1',
              deviceId: 'dev-1',
              encryptionKeyBase64: _key(1),
              signingKeyBase64: s.anchor.publicKey,
              name: 'Laptop',
              linkedAt: now,
              proofSignatureBase64: await _proof(
                s.anchor,
                accountId: 'acc-1',
                accountKey: mallory.publicKeyBase64,
                deviceId: 'dev-1',
                encryptionKey: _key(1),
                signingKey: s.anchor.publicKey,
              ),
            ),
          ], version: 2),
        ),
        isNull,
      );
    });

    test(
      'old lists, lost revocations and a missing main device are ignored',
      () async {
        final s = await setUp();
        Future<AccountDevicesUpdate?> check(
          Map<String, Object?> payload, {
          int knownVersion = 2,
          List<String> knownRevoked = const ['dev-0'],
        }) => verifyAccountDevices(
          accountId: 'acc-1',
          anchorDeviceId: 'dev-1',
          anchorSigningKeyBase64: s.anchor.publicKey,
          knownAccountKeyBase64: s.account.publicKeyBase64,
          knownVersion: knownVersion,
          knownRevoked: knownRevoked,
          fromAnchor: true,
          payload: payload,
        );
        expect(
          await check(
            await statement(
              s.account,
              null,
              [s.anchorCert],
              version: 2,
              revoked: {'dev-0': now},
            ),
          ),
          isNull,
          reason: 'not newer',
        );
        expect(
          await check(
            await statement(s.account, null, [s.anchorCert], version: 3),
          ),
          isNotNull,
          reason: 'a list need not repeat known revocations: they merge',
        );
        expect(
          await check(
            await statement(
              s.account,
              null,
              [s.second],
              version: 3,
              revoked: {'dev-0': now},
            ),
          ),
          isNull,
          reason: 'the main device must be listed',
        );
        expect(
          await check(
            await statement(
              s.account,
              null,
              [s.anchorCert, s.second],
              version: 3,
              revoked: {'dev-0': now},
            ),
          ),
          isNotNull,
        );
      },
    );

    test('versions cannot jump far ahead, and revocations always get '
        'through', () async {
      final s = await setUp();
      Future<AccountDevicesUpdate?> check(
        Map<String, Object?> payload, {
        int knownVersion = 5,
        List<String> knownRevoked = const [],
      }) => verifyAccountDevices(
        accountId: 'acc-1',
        anchorDeviceId: 'dev-1',
        anchorSigningKeyBase64: s.anchor.publicKey,
        knownAccountKeyBase64: s.account.publicKeyBase64,
        knownVersion: knownVersion,
        knownRevoked: knownRevoked,
        fromAnchor: true,
        payload: payload,
      );
      // A stolen device racing far ahead so the owner can never catch up.
      expect(
        await check(
          await statement(s.account, null, [s.anchorCert], version: 5000),
        ),
        isNull,
      );
      expect(
        await check(
          await statement(s.account, null, [s.anchorCert], version: 21),
        ),
        isNotNull,
      );
      // Too far ahead, but revoking something: the revocation still counts,
      // and only that.
      final far = await check(
        await statement(
          s.account,
          null,
          [s.anchorCert],
          version: 5000,
          revoked: {'dev-stolen': now},
        ),
      );
      expect(far?.revocationsOnly, isTrue);
      expect(far?.list.revoked.keys, ['dev-stolen']);
      // The owner revokes it with a lower version: still applied, as a
      // revocation only.
      final revocation = await check(
        await statement(
          s.account,
          null,
          [s.anchorCert],
          version: 3,
          revoked: {'dev-stolen': now},
        ),
        knownVersion: 20,
      );
      expect(revocation?.revocationsOnly, isTrue);
      expect(revocation?.list.revoked.keys, ['dev-stolen']);
      // A lower version that revokes nothing new is ignored.
      expect(
        await check(
          await statement(
            s.account,
            null,
            [s.anchorCert],
            version: 3,
            revoked: {'dev-stolen': now},
          ),
          knownVersion: 20,
          knownRevoked: const ['dev-stolen'],
        ),
        isNull,
      );
      // Learned for the first time, any current version is fine.
      expect(
        await verifyAccountDevices(
          accountId: 'acc-1',
          anchorDeviceId: 'dev-1',
          anchorSigningKeyBase64: s.anchor.publicKey,
          knownAccountKeyBase64: null,
          knownVersion: 0,
          knownRevoked: const [],
          fromAnchor: true,
          payload: await statement(s.account, s.upgrade, [
            s.anchorCert,
          ], version: 300),
        ),
        isNotNull,
      );
    });

    test(
      'without a pinned key, only the main device may introduce it',
      () async {
        final s = await setUp();
        final payload = await statement(s.account, s.upgrade, [s.anchorCert]);
        Future<AccountDevicesUpdate?> check({required bool fromAnchor}) =>
            verifyAccountDevices(
              accountId: 'acc-1',
              anchorDeviceId: 'dev-1',
              anchorSigningKeyBase64: null,
              knownAccountKeyBase64: null,
              knownVersion: 0,
              knownRevoked: const [],
              fromAnchor: fromAnchor,
              payload: payload,
            );
        expect(await check(fromAnchor: false), isNull);
        expect(await check(fromAnchor: true), isNotNull);
      },
    );
  });
}
