import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:conest/src/app_storage.dart';
import 'package:conest/src/models.dart';
import 'package:conest/src/storage.dart';

void main() {
  Future<Directory> createTempRoot(String prefix) async {
    final directory = await Directory.systemTemp.createTemp(prefix);
    addTearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });
    return directory;
  }

  test(
    'secure-storage vault key provider preserves existing behavior',
    () async {
      final secureStorageValues = <String, String>{};
      FlutterSecureStorage.setMockInitialValues(secureStorageValues);

      final provider = SecureStorageVaultKeyProvider(
        secureStorage: const FlutterSecureStorage(),
      );
      final first = await provider.readOrCreateKey();
      final second = await provider.readOrCreateKey();

      expect(first, hasLength(32));
      expect(second, first);
      expect(secureStorageValues['conest.vault_key'], base64Encode(first));

      await provider.clear();

      expect(secureStorageValues, isEmpty);
    },
  );

  test('file vault key provider creates and reloads key material', () async {
    final root = await createTempRoot('conest_file_key_');
    final keyFile = File(p.join(root.path, 'conest_vault_key.json'));
    final provider = FileVaultKeyProvider(fileProvider: () async => keyFile);

    final first = await provider.readOrCreateKey();
    final reloaded = await FileVaultKeyProvider(
      fileProvider: () async => keyFile,
    ).readOrCreateKey();

    expect(first, hasLength(32));
    expect(reloaded, first);
    expect(await keyFile.exists(), isTrue);

    await provider.clear();

    expect(await keyFile.exists(), isFalse);
  });

  test(
    'passphrase vault provider decrypts only with the correct passphrase',
    () async {
      final root = await createTempRoot('conest_passphrase_vault_');
      final vaultFile = File(p.join(root.path, 'conest.vault'));
      final kdf = PassphraseKdfConfig(
        saltBase64: base64Encode(List<int>.generate(16, (index) => index + 1)),
        memory: 64,
        iterations: 1,
        parallelism: 1,
      );
      final snapshot = VaultSnapshot.empty().copyWith(
        seenEnvelopeIds: const ['seen-a'],
      );

      await VaultStore(
        vaultFileProvider: () async => vaultFile,
        keyProvider: PassphraseVaultKeyProvider(
          passphrase: 'correct horse battery staple',
          config: kdf,
        ),
      ).save(snapshot);

      final loaded = await VaultStore(
        vaultFileProvider: () async => vaultFile,
        keyProvider: PassphraseVaultKeyProvider(
          passphrase: 'correct horse battery staple',
          config: kdf,
        ),
      ).load();
      expect(loaded.seenEnvelopeIds, const ['seen-a']);

      expect(
        () => VaultStore(
          vaultFileProvider: () async => vaultFile,
          keyProvider: PassphraseVaultKeyProvider(
            passphrase: 'wrong passphrase',
            config: kdf,
          ),
        ).load(),
        throwsA(anything),
      );
    },
  );
}
