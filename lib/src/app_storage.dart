import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

enum AppStorageMode { device, portable }

enum VaultUnlockMode { secureStorage, keyFile, passphrase }

enum AppStorageResolutionStatus { ready, needsSetup, needsPassphrase }

class AppStorageException implements Exception {
  const AppStorageException(this.message);

  final String message;

  @override
  String toString() => message;
}

class PassphraseKdfConfig {
  PassphraseKdfConfig({
    required this.saltBase64,
    required this.memory,
    required this.iterations,
    required this.parallelism,
  });

  factory PassphraseKdfConfig.create() {
    final random = Random.secure();
    final salt = List<int>.generate(16, (_) => random.nextInt(256));
    return PassphraseKdfConfig(
      saltBase64: base64Encode(salt),
      memory: 19 * 1024,
      iterations: 2,
      parallelism: 1,
    );
  }

  final String saltBase64;
  final int memory;
  final int iterations;
  final int parallelism;

  Map<String, dynamic> toJson() {
    return {
      'algorithm': 'argon2id',
      'saltBase64': saltBase64,
      'memory': memory,
      'iterations': iterations,
      'parallelism': parallelism,
      'hashLength': 32,
    };
  }

  factory PassphraseKdfConfig.fromJson(Map<String, dynamic> json) {
    final algorithm = json['algorithm'] as String? ?? 'argon2id';
    if (algorithm != 'argon2id') {
      throw FormatException('Unsupported passphrase KDF: $algorithm.');
    }
    return PassphraseKdfConfig(
      saltBase64: json['saltBase64'] as String,
      memory: (json['memory'] as num).toInt(),
      iterations: (json['iterations'] as num).toInt(),
      parallelism: (json['parallelism'] as num).toInt(),
    );
  }
}

class AppStorageProfile {
  AppStorageProfile({
    required this.mode,
    required this.unlockMode,
    required this.dataRoot,
    this.passphraseKdf,
    bool? automaticStartupChecksEnabled,
  }) : automaticStartupChecksEnabled =
           automaticStartupChecksEnabled ?? mode == AppStorageMode.device;

  static const profileFileName = 'conest_storage_profile.json';

  final AppStorageMode mode;
  final VaultUnlockMode unlockMode;
  final Directory dataRoot;
  final PassphraseKdfConfig? passphraseKdf;
  final bool automaticStartupChecksEnabled;

  bool get requiresPassphrase => unlockMode == VaultUnlockMode.passphrase;
  File get profileFile => File(p.join(dataRoot.path, profileFileName));
  File get vaultFile => File(p.join(dataRoot.path, 'conest.vault'));
  File get keyFile => File(p.join(dataRoot.path, 'conest_vault_key.json'));
  Directory get tempRoot => Directory(p.join(dataRoot.path, 'temp'));

  Map<String, dynamic> toJson() {
    return {
      'version': 1,
      'mode': mode.name,
      'unlockMode': unlockMode.name,
      'automaticStartupChecksEnabled': automaticStartupChecksEnabled,
      if (passphraseKdf != null) 'passphraseKdf': passphraseKdf!.toJson(),
    };
  }

  Future<void> save() async {
    await dataRoot.create(recursive: true);
    await profileFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(toJson()),
      flush: true,
    );
  }

  factory AppStorageProfile.fromJson(
    Map<String, dynamic> json, {
    required Directory dataRoot,
  }) {
    final version = (json['version'] as num?)?.toInt() ?? 0;
    if (version != 1) {
      throw FormatException('Unsupported storage profile version: $version.');
    }
    final unlockMode = VaultUnlockMode.values.byName(
      json['unlockMode'] as String,
    );
    final rawKdf = json['passphraseKdf'];
    final kdf = rawKdf is Map<String, dynamic>
        ? PassphraseKdfConfig.fromJson(rawKdf)
        : null;
    if (unlockMode == VaultUnlockMode.passphrase && kdf == null) {
      throw const FormatException(
        'Passphrase storage profile is missing KDF metadata.',
      );
    }
    return AppStorageProfile(
      mode: AppStorageMode.values.byName(json['mode'] as String),
      unlockMode: unlockMode,
      dataRoot: dataRoot,
      passphraseKdf: kdf,
      automaticStartupChecksEnabled:
          json['automaticStartupChecksEnabled'] as bool?,
    );
  }

  static Future<AppStorageProfile> load(Directory dataRoot) async {
    final file = File(p.join(dataRoot.path, profileFileName));
    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    return AppStorageProfile.fromJson(json, dataRoot: dataRoot);
  }
}

class AppStorageResolution {
  const AppStorageResolution._({required this.status, this.profile});

  factory AppStorageResolution.ready(AppStorageProfile profile) {
    return AppStorageResolution._(
      status: profile.requiresPassphrase
          ? AppStorageResolutionStatus.needsPassphrase
          : AppStorageResolutionStatus.ready,
      profile: profile,
    );
  }

  static const needsSetup = AppStorageResolution._(
    status: AppStorageResolutionStatus.needsSetup,
  );

  final AppStorageResolutionStatus status;
  final AppStorageProfile? profile;
}

class AppStorageResolver {
  AppStorageResolver({
    Future<Directory> Function()? applicationSupportDirectoryProvider,
    Future<Directory> Function()? executableDirectoryProvider,
    bool Function()? portableSupportedProvider,
    Future<bool> Function(Directory portableRoot)? portableWriteProbe,
  }) : _applicationSupportDirectoryProvider =
           applicationSupportDirectoryProvider ??
           getApplicationSupportDirectory,
       _executableDirectoryProvider =
           executableDirectoryProvider ?? _defaultExecutableDirectory,
       _portableSupportedProvider =
           portableSupportedProvider ?? _defaultPortableSupported,
       _portableWriteProbe = portableWriteProbe ?? _defaultPortableWriteProbe;

  static const portableDataDirectoryName = 'conest_data';

  final Future<Directory> Function() _applicationSupportDirectoryProvider;
  final Future<Directory> Function() _executableDirectoryProvider;
  final bool Function() _portableSupportedProvider;
  final Future<bool> Function(Directory portableRoot) _portableWriteProbe;

  bool get portableSupported => _portableSupportedProvider();

  Future<AppStorageResolution> resolve() async {
    final executableDir = await _executableDirectoryProvider();
    final portableRoot = Directory(
      p.join(executableDir.path, portableDataDirectoryName),
    );
    if (await _profileExists(portableRoot)) {
      return AppStorageResolution.ready(
        await AppStorageProfile.load(portableRoot),
      );
    }

    final defaultRoot = await _applicationSupportDirectoryProvider();
    if (await _profileExists(defaultRoot)) {
      return AppStorageResolution.ready(
        await AppStorageProfile.load(defaultRoot),
      );
    }
    if (await File(p.join(defaultRoot.path, 'conest.vault')).exists()) {
      return AppStorageResolution.ready(
        AppStorageProfile(
          mode: AppStorageMode.device,
          unlockMode: VaultUnlockMode.secureStorage,
          dataRoot: defaultRoot,
        ),
      );
    }
    return AppStorageResolution.needsSetup;
  }

  Future<AppStorageProfile> createProfile({
    required AppStorageMode mode,
    required VaultUnlockMode unlockMode,
  }) async {
    if (mode == AppStorageMode.portable &&
        unlockMode == VaultUnlockMode.secureStorage) {
      throw const AppStorageException(
        'Portable storage cannot use this device keychain.',
      );
    }
    final dataRoot = switch (mode) {
      AppStorageMode.device => await _applicationSupportDirectoryProvider(),
      AppStorageMode.portable => await _portableRootForSetup(),
    };
    final profile = AppStorageProfile(
      mode: mode,
      unlockMode: unlockMode,
      dataRoot: dataRoot,
      passphraseKdf: unlockMode == VaultUnlockMode.passphrase
          ? PassphraseKdfConfig.create()
          : null,
      automaticStartupChecksEnabled: mode == AppStorageMode.device,
    );
    await profile.save();
    return profile;
  }

  Future<Directory> _portableRootForSetup() async {
    if (!_portableSupportedProvider()) {
      throw const AppStorageException(
        'Ghost/portable storage is supported on Linux and Windows builds only.',
      );
    }
    final executableDir = await _executableDirectoryProvider();
    final portableRoot = Directory(
      p.join(executableDir.path, portableDataDirectoryName),
    );
    if (!await _portableWriteProbe(portableRoot)) {
      throw AppStorageException(
        'Conest cannot write portable data beside the app at ${portableRoot.path}.',
      );
    }
    return portableRoot;
  }

  Future<bool> _profileExists(Directory dataRoot) {
    return File(
      p.join(dataRoot.path, AppStorageProfile.profileFileName),
    ).exists();
  }

  static Future<Directory> _defaultExecutableDirectory() async {
    return File(Platform.resolvedExecutable).parent;
  }

  static bool _defaultPortableSupported() {
    return !Platform.isAndroid && (Platform.isLinux || Platform.isWindows);
  }

  static Future<bool> _defaultPortableWriteProbe(Directory portableRoot) async {
    try {
      await portableRoot.create(recursive: true);
      final probe = File(p.join(portableRoot.path, '.conest_write_probe'));
      await probe.writeAsString('ok', flush: true);
      await probe.delete();
      return true;
    } catch (_) {
      return false;
    }
  }
}
