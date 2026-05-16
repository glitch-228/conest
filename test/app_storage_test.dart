import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:conest/src/app_storage.dart';

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

  test('portable profile takes precedence over default profile', () async {
    final root = await createTempRoot('conest_storage_profile_');
    final executableDir = Directory(p.join(root.path, 'app'))..createSync();
    final defaultRoot = Directory(p.join(root.path, 'default'))..createSync();
    final portableRoot = Directory(
      p.join(executableDir.path, AppStorageResolver.portableDataDirectoryName),
    )..createSync();

    await AppStorageProfile(
      mode: AppStorageMode.device,
      unlockMode: VaultUnlockMode.secureStorage,
      dataRoot: defaultRoot,
    ).save();
    await AppStorageProfile(
      mode: AppStorageMode.portable,
      unlockMode: VaultUnlockMode.keyFile,
      dataRoot: portableRoot,
    ).save();

    final resolver = AppStorageResolver(
      applicationSupportDirectoryProvider: () async => defaultRoot,
      executableDirectoryProvider: () async => executableDir,
      portableSupportedProvider: () => true,
    );

    final resolution = await resolver.resolve();

    expect(resolution.status, AppStorageResolutionStatus.ready);
    expect(resolution.profile!.mode, AppStorageMode.portable);
    expect(resolution.profile!.unlockMode, VaultUnlockMode.keyFile);
    expect(resolution.profile!.dataRoot.path, portableRoot.path);
  });

  test('legacy default vault without a profile opens unchanged', () async {
    final root = await createTempRoot('conest_storage_legacy_');
    final executableDir = Directory(p.join(root.path, 'app'))..createSync();
    final defaultRoot = Directory(p.join(root.path, 'default'))..createSync();
    File(p.join(defaultRoot.path, 'conest.vault')).writeAsStringSync('{}');

    final resolver = AppStorageResolver(
      applicationSupportDirectoryProvider: () async => defaultRoot,
      executableDirectoryProvider: () async => executableDir,
      portableSupportedProvider: () => true,
    );

    final resolution = await resolver.resolve();

    expect(resolution.status, AppStorageResolutionStatus.ready);
    expect(resolution.profile!.mode, AppStorageMode.device);
    expect(resolution.profile!.unlockMode, VaultUnlockMode.secureStorage);
    expect(resolution.profile!.dataRoot.path, defaultRoot.path);
  });

  test('new install requests first-launch storage setup', () async {
    final root = await createTempRoot('conest_storage_new_');
    final executableDir = Directory(p.join(root.path, 'app'))..createSync();
    final defaultRoot = Directory(p.join(root.path, 'default'))..createSync();

    final resolver = AppStorageResolver(
      applicationSupportDirectoryProvider: () async => defaultRoot,
      executableDirectoryProvider: () async => executableDir,
      portableSupportedProvider: () => true,
    );

    final resolution = await resolver.resolve();

    expect(resolution.status, AppStorageResolutionStatus.needsSetup);
    expect(resolution.profile, isNull);
  });

  test(
    'portable setup fails clearly when app folder is not writable',
    () async {
      final root = await createTempRoot('conest_storage_unwritable_');
      final executableDir = Directory(p.join(root.path, 'app'))..createSync();
      final defaultRoot = Directory(p.join(root.path, 'default'))..createSync();

      final resolver = AppStorageResolver(
        applicationSupportDirectoryProvider: () async => defaultRoot,
        executableDirectoryProvider: () async => executableDir,
        portableSupportedProvider: () => true,
        portableWriteProbe: (_) async => false,
      );

      expect(
        () => resolver.createProfile(
          mode: AppStorageMode.portable,
          unlockMode: VaultUnlockMode.keyFile,
        ),
        throwsA(isA<AppStorageException>()),
      );
    },
  );

  test(
    'Argon2id passphrase metadata round-trips through profile json',
    () async {
      final root = await createTempRoot('conest_storage_passphrase_');
      final profile = AppStorageProfile(
        mode: AppStorageMode.device,
        unlockMode: VaultUnlockMode.passphrase,
        dataRoot: root,
        passphraseKdf: PassphraseKdfConfig(
          saltBase64: base64Encode(List<int>.generate(16, (index) => index)),
          memory: 64,
          iterations: 2,
          parallelism: 1,
        ),
      );

      await profile.save();
      final loaded = await AppStorageProfile.load(root);

      expect(loaded.mode, AppStorageMode.device);
      expect(loaded.unlockMode, VaultUnlockMode.passphrase);
      expect(
        loaded.passphraseKdf!.saltBase64,
        profile.passphraseKdf!.saltBase64,
      );
      expect(loaded.passphraseKdf!.memory, 64);
      expect(loaded.passphraseKdf!.iterations, 2);
      expect(loaded.passphraseKdf!.parallelism, 1);
    },
  );
}
