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
    'file vault key provider creates POSIX key files with 0600 mode',
    () async {
      if (Platform.isWindows) {
        return;
      }
      final root = await createTempRoot('conest_file_key_mode_');
      final keyFile = File(p.join(root.path, 'conest_vault_key.json'));
      final provider = FileVaultKeyProvider(fileProvider: () async => keyFile);

      await provider.readOrCreateKey();

      final mode = (await keyFile.stat()).mode & 0x1ff;
      expect(mode, 0x180);
    },
  );

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

  test(
    'concurrent vault saves serialize and preserve the newest snapshot',
    () async {
      final root = await createTempRoot('conest_vault_concurrent_');
      final vaultFile = File(p.join(root.path, 'conest.vault'));
      final keyFile = File(p.join(root.path, 'conest.key'));
      final store = VaultStore(
        vaultFileProvider: () async => vaultFile,
        keyProvider: FileVaultKeyProvider(fileProvider: () async => keyFile),
      );

      final saves = <Future<void>>[];
      for (var index = 0; index < 12; index++) {
        saves.add(
          store.save(
            VaultSnapshot.empty().copyWith(
              seenEnvelopeIds: <String>['snapshot-$index'],
            ),
          ),
        );
      }
      await Future.wait(saves);

      final loaded = await store.load();
      expect(loaded.seenEnvelopeIds, const <String>['snapshot-11']);
    },
  );

  test(
    'vault recovers the last-good backup after primary corruption',
    () async {
      final root = await createTempRoot('conest_vault_recovery_');
      final vaultFile = File(p.join(root.path, 'conest.vault'));
      final keyFile = File(p.join(root.path, 'conest.key'));
      VaultStore createStore() => VaultStore(
        vaultFileProvider: () async => vaultFile,
        keyProvider: FileVaultKeyProvider(fileProvider: () async => keyFile),
      );
      final store = createStore();
      await store.save(
        VaultSnapshot.empty().copyWith(
          seenEnvelopeIds: const <String>['last-good'],
        ),
      );
      await store.save(
        VaultSnapshot.empty().copyWith(
          seenEnvelopeIds: const <String>['new-primary'],
        ),
      );
      expect(await File('${vaultFile.path}.bak').exists(), isTrue);

      await vaultFile.writeAsString('interrupted write', flush: true);
      final recovered = await createStore().load();

      expect(recovered.seenEnvelopeIds, const <String>['last-good']);
      expect(
        (await createStore().load()).seenEnvelopeIds,
        const <String>['last-good'],
        reason: 'recovery must restore a readable primary atomically',
      );
    },
  );

  test('a corrupt backup never replaces a readable primary', () async {
    final root = await createTempRoot('conest_vault_bad_backup_');
    final vaultFile = File(p.join(root.path, 'conest.vault'));
    final keyFile = File(p.join(root.path, 'conest.key'));
    final store = VaultStore(
      vaultFileProvider: () async => vaultFile,
      keyProvider: FileVaultKeyProvider(fileProvider: () async => keyFile),
    );
    await store.save(
      VaultSnapshot.empty().copyWith(
        seenEnvelopeIds: const <String>['primary'],
      ),
    );
    await File('${vaultFile.path}.bak').writeAsString('corrupt', flush: true);

    expect((await store.load()).seenEnvelopeIds, const <String>['primary']);
  });

  group('nightly.11 AppInstanceLock stale-PID recovery', () {
    test('acquire steals a lock recorded by a long-dead PID', () async {
      final dir = await createTempRoot('conest_lock_test_');
      final lockFile = File(p.join(dir.path, 'conest.lock'));
      // PID 1 always exists on POSIX (init) but PID 999999 doesn't on a
      // freshly booted box. On Windows tasklist similarly returns empty
      // for a very high unallocated PID. Pick something virtually
      // guaranteed to be dead.
      const deadPid = 999999;
      await lockFile.writeAsString('$deadPid\n');
      final lock = AppInstanceLock(directory: dir);
      // Should detect the stale PID and steal the lock.
      expect(await lock.acquire(), isTrue);
      await lock.release();
      // After release the file should be gone.
      expect(await lockFile.exists(), isFalse);
    });

    test(
      'release deletes the lock file so a fresh acquire is unblocked',
      () async {
        final dir = await createTempRoot('conest_lock_test2_');
        final first = AppInstanceLock(directory: dir);
        expect(await first.acquire(), isTrue);
        await first.release();
        expect(await File(p.join(dir.path, 'conest.lock')).exists(), isFalse);
        // Re-acquire on the same dir works.
        final second = AppInstanceLock(directory: dir);
        expect(await second.acquire(), isTrue);
        await second.release();
      },
    );
  });
}
