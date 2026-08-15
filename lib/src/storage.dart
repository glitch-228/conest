import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import 'app_storage.dart';
import 'models.dart';

List<int> _secureRandomBytes(int length) {
  final random = Random.secure();
  return List<int>.generate(length, (_) => random.nextInt(256));
}

/// Payload for the off-main-isolate vault encryption pass. Only sendable
/// plain data crosses the isolate boundary (the JSON map, raw key bytes,
/// and a pre-generated nonce).
class _VaultEncryptRequest {
  const _VaultEncryptRequest({
    required this.snapshotJson,
    required this.key,
    required this.nonce,
  });

  final Map<String, dynamic> snapshotJson;
  final List<int> key;
  final List<int> nonce;
}

/// Runs in a `compute` isolate: JSON-encodes the full snapshot, encrypts
/// it, and returns the ready-to-write envelope string. The vault grows
/// with the whole message history, so doing this on the UI isolate makes
/// every save jank in proportion to how long the user has used the app.
Future<String> _encodeAndEncryptVault(_VaultEncryptRequest request) async {
  final algorithm = Chacha20.poly1305Aead();
  final secretBox = await algorithm.encrypt(
    utf8.encode(jsonEncode(request.snapshotJson)),
    secretKey: SecretKey(request.key),
    nonce: request.nonce,
    aad: utf8.encode('conest.vault.v1'),
  );
  return jsonEncode(<String, dynamic>{
    'version': 1,
    'nonceBase64': base64Encode(secretBox.nonce),
    'ciphertextBase64': base64Encode(secretBox.cipherText),
    'macBase64': base64Encode(secretBox.mac.bytes),
  });
}

Future<void> _restrictOwnerOnly(File file) async {
  if (!Platform.isLinux && !Platform.isMacOS) {
    return;
  }
  final result = await Process.run('chmod', ['600', file.path]);
  if (result.exitCode != 0) {
    throw FileSystemException(
      'Could not restrict vault key file permissions: ${result.stderr}',
      file.path,
    );
  }
}

class AppInstanceLock {
  AppInstanceLock({Directory? directory}) : _directory = directory;

  final Directory? _directory;
  RandomAccessFile? _lockFile;
  File? _lockFilePath;

  Future<bool> acquire() async {
    final directory = _directory ?? await getApplicationSupportDirectory();
    await directory.create(recursive: true);
    final file = File('${directory.path}/conest.lock');
    _lockFilePath = file;
    // First try.
    if (await _tryAcquire(file)) return true;
    // nightly.11: contended. On Windows the user's "restart and update"
    // flow could leave a stale lock if the old Conest exited before the
    // OS released its lock handle. Steal the lock when the recorded PID
    // is dead; otherwise honour the existing instance.
    final stalePid = await _readRecordedPid(file);
    if (stalePid != null && !_isProcessAlive(stalePid)) {
      try {
        await file.delete();
      } catch (_) {}
      return _tryAcquire(file);
    }
    return false;
  }

  Future<bool> _tryAcquire(File file) async {
    final lockFile = await file.open(mode: FileMode.append);
    try {
      await lockFile.lock(FileLock.exclusive);
    } catch (_) {
      await lockFile.close();
      return false;
    }
    try {
      await lockFile.setPosition(0);
      await lockFile.truncate(0);
      await lockFile.writeString('$pid\n');
      _lockFile = lockFile;
      return true;
    } catch (_) {
      try {
        await lockFile.unlock();
      } catch (_) {}
      await lockFile.close();
      return false;
    }
  }

  Future<int?> _readRecordedPid(File file) async {
    try {
      final raw = await file.readAsString();
      return int.tryParse(raw.trim().split('\n').first.trim());
    } catch (_) {
      return null;
    }
  }

  /// nightly.11: cross-platform "is this PID currently alive?". On
  /// POSIX, sending SIGCONT is a cheap probe — alive PIDs accept it as a
  /// no-op; dead PIDs throw ESRCH. On Windows we shell out to `tasklist`
  /// which is the boring-but-reliable approach (no FFI required).
  bool _isProcessAlive(int candidatePid) {
    if (candidatePid <= 0) return false;
    if (Platform.isWindows) {
      try {
        final result = Process.runSync('tasklist', [
          '/FI',
          'PID eq $candidatePid',
          '/NH',
          '/FO',
          'CSV',
        ], runInShell: false);
        if (result.exitCode != 0) return false;
        return (result.stdout as String).contains('"$candidatePid"');
      } catch (_) {
        // tasklist unavailable — assume alive to be safe (we just won't
        // steal the lock, the user can clear it manually).
        return true;
      }
    }
    try {
      Process.killPid(candidatePid, ProcessSignal.sigcont);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> release() async {
    final lockFile = _lockFile;
    if (lockFile == null) {
      return;
    }
    _lockFile = null;
    try {
      await lockFile.unlock();
    } catch (_) {}
    try {
      await lockFile.close();
    } catch (_) {}
    // nightly.11: explicitly delete the lock file so the next process
    // (especially the post-update relaunch on Windows) doesn't race the
    // OS for the lock-handle teardown. Best-effort — if delete fails the
    // stale-PID check in acquire() will rescue.
    final path = _lockFilePath;
    if (path != null) {
      try {
        await path.delete();
      } catch (_) {}
    }
  }
}

abstract class VaultKeyProvider {
  Future<List<int>> readOrCreateKey();

  Future<void> clear();
}

class SecureStorageVaultKeyProvider implements VaultKeyProvider {
  SecureStorageVaultKeyProvider({FlutterSecureStorage? secureStorage})
    : _secureStorage = secureStorage ?? const FlutterSecureStorage();

  static const vaultKeyName = 'conest.vault_key';

  final FlutterSecureStorage _secureStorage;

  @override
  Future<List<int>> readOrCreateKey() async {
    final existing = await _secureStorage.read(key: vaultKeyName);
    if (existing != null) {
      return base64Decode(existing);
    }
    final created = _secureRandomBytes(32);
    await _secureStorage.write(key: vaultKeyName, value: base64Encode(created));
    return created;
  }

  @override
  Future<void> clear() => _secureStorage.delete(key: vaultKeyName);
}

class FileVaultKeyProvider implements VaultKeyProvider {
  FileVaultKeyProvider({required Future<File> Function() fileProvider})
    : _fileProvider = fileProvider;

  final Future<File> Function() _fileProvider;

  @override
  Future<List<int>> readOrCreateKey() async {
    final file = await _fileProvider();
    if (await file.exists()) {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Vault key file must be a JSON object.');
      }
      final key = base64Decode(decoded['keyBase64'] as String);
      if (key.length != 32) {
        throw const FormatException('Vault key file has an invalid key.');
      }
      return key;
    }
    final created = _secureRandomBytes(32);
    await file.parent.create(recursive: true);
    await file.create();
    await _restrictOwnerOnly(file);
    await file.writeAsString(
      const JsonEncoder.withIndent(
        '  ',
      ).convert({'version': 1, 'keyBase64': base64Encode(created)}),
      flush: true,
    );
    await _restrictOwnerOnly(file);
    return created;
  }

  @override
  Future<void> clear() async {
    final file = await _fileProvider();
    if (await file.exists()) {
      await file.delete();
    }
  }
}

class PassphraseVaultKeyProvider implements VaultKeyProvider {
  PassphraseVaultKeyProvider({required String passphrase, required this.config})
    : _passphrase = passphrase {
    if (passphrase.isEmpty) {
      throw ArgumentError('Passphrase is required.');
    }
  }

  final String _passphrase;
  final PassphraseKdfConfig config;
  List<int>? _cachedKey;

  @override
  Future<List<int>> readOrCreateKey() async {
    final cached = _cachedKey;
    if (cached != null) {
      return cached;
    }
    final algorithm = Argon2id(
      parallelism: config.parallelism,
      memory: config.memory,
      iterations: config.iterations,
      hashLength: 32,
    );
    final key = await algorithm.deriveKey(
      secretKey: SecretKey(utf8.encode(_passphrase)),
      nonce: base64Decode(config.saltBase64),
    );
    final bytes = await key.extractBytes();
    _cachedKey = bytes;
    return bytes;
  }

  @override
  Future<void> clear() async {
    _cachedKey = null;
  }
}

class VaultStore {
  VaultStore({
    FlutterSecureStorage? secureStorage,
    Future<File> Function()? vaultFileProvider,
    VaultKeyProvider? keyProvider,
  }) : _vaultFileProvider = vaultFileProvider,
       _keyProvider =
           keyProvider ??
           SecureStorageVaultKeyProvider(secureStorage: secureStorage);

  final Future<File> Function()? _vaultFileProvider;
  final VaultKeyProvider _keyProvider;
  static const _vaultFileName = 'conest.vault';
  Future<void> _saveTail = Future<void>.value();

  Future<VaultSnapshot> load() async {
    final file = await _vaultFile();
    final backup = File('${file.path}.bak');
    if (!await file.exists() && !await backup.exists()) {
      return VaultSnapshot.empty();
    }
    final key = await _readOrCreateVaultKey();
    Object? primaryError;
    if (await file.exists()) {
      try {
        return await _decodeVaultFile(file, key);
      } catch (error) {
        primaryError = error;
      }
    }
    if (await backup.exists()) {
      try {
        final recovered = await _decodeVaultFile(backup, key);
        final temporary = File('${file.path}.recover.tmp');
        await _copyFlushed(backup, temporary);
        await _atomicReplace(temporary, file);
        return recovered;
      } catch (_) {
        // Surface the primary failure below; a corrupt backup must never
        // replace a readable primary or disguise the original problem.
      }
    }
    throw primaryError ?? const FormatException('Vault backup is corrupt.');
  }

  Future<VaultSnapshot> _decodeVaultFile(File file, List<int> key) async {
    final decodedEnvelope = jsonDecode(await file.readAsString());
    if (decodedEnvelope is! Map<String, dynamic>) {
      throw const FormatException('Vault envelope must be a JSON object.');
    }
    final envelopeJson = decodedEnvelope;
    final algorithm = Chacha20.poly1305Aead();
    final secretBox = SecretBox(
      base64Decode(envelopeJson['ciphertextBase64'] as String),
      nonce: base64Decode(envelopeJson['nonceBase64'] as String),
      mac: Mac(base64Decode(envelopeJson['macBase64'] as String)),
    );
    final cleartext = await algorithm.decrypt(
      secretBox,
      secretKey: SecretKey(key),
      aad: utf8.encode('conest.vault.v1'),
    );
    final snapshotJson =
        jsonDecode(utf8.decode(cleartext)) as Map<String, dynamic>;
    return VaultSnapshot.fromJson(snapshotJson);
  }

  Future<void> save(VaultSnapshot snapshot) {
    final snapshotJson = snapshot.toJson();
    final operation = _saveTail
        .catchError((_) {})
        .then((_) => _saveSnapshotJson(snapshotJson));
    _saveTail = operation;
    return operation;
  }

  Future<void> _saveSnapshotJson(Map<String, dynamic> snapshotJson) async {
    final file = await _vaultFile();
    await file.parent.create(recursive: true);
    final key = await _readOrCreateVaultKey();
    // JSON-encode + encrypt + base64 of the whole history runs off the UI
    // isolate; only the (sendable) snapshot map crosses the boundary. The
    // nonce is generated here so the isolate stays deterministic-in,
    // deterministic-out.
    final envelope = await compute(
      _encodeAndEncryptVault,
      _VaultEncryptRequest(
        snapshotJson: snapshotJson,
        key: key,
        nonce: _secureRandomBytes(Chacha20.poly1305Aead().nonceLength),
      ),
      debugLabel: 'conest-vault-save',
    );
    final temporary = File('${file.path}.tmp');
    await _writeFlushed(temporary, envelope);

    // Preserve only a cryptographically valid last-good primary. A corrupt
    // primary must not overwrite an older usable backup.
    if (await file.exists()) {
      try {
        await _decodeVaultFile(file, key);
        final backupTemporary = File('${file.path}.bak.tmp');
        await _copyFlushed(file, backupTemporary);
        await _atomicReplace(backupTemporary, File('${file.path}.bak'));
      } catch (_) {}
    }
    await _atomicReplace(temporary, file);
  }

  Future<void> clear() async {
    await _saveTail.catchError((_) {});
    final file = await _vaultFile();
    for (final candidate in <File>[
      file,
      File('${file.path}.tmp'),
      File('${file.path}.bak'),
      File('${file.path}.bak.tmp'),
      File('${file.path}.recover.tmp'),
      File('${file.path}.replace-old'),
    ]) {
      if (await candidate.exists()) await candidate.delete();
    }
    await _keyProvider.clear();
  }

  Future<void> _writeFlushed(File file, String contents) async {
    await file.parent.create(recursive: true);
    await file.create();
    await _restrictOwnerOnly(file);
    final handle = await file.open(mode: FileMode.write);
    try {
      await handle.writeString(contents);
      await handle.flush();
    } finally {
      await handle.close();
    }
    await _restrictOwnerOnly(file);
  }

  Future<void> _copyFlushed(File source, File target) async {
    await target.create(recursive: true);
    await _restrictOwnerOnly(target);
    final handle = await target.open(mode: FileMode.write);
    try {
      await for (final chunk in source.openRead()) {
        await handle.writeFrom(chunk);
      }
      await handle.flush();
    } finally {
      await handle.close();
    }
    await _restrictOwnerOnly(target);
  }

  Future<void> _atomicReplace(File source, File target) async {
    try {
      await source.rename(target.path);
      return;
    } on FileSystemException {
      // Windows may refuse rename-over-existing. Keep a rollback name until
      // the new same-directory file has taken the canonical path.
    }
    final rollback = File('${target.path}.replace-old');
    if (await rollback.exists()) await rollback.delete();
    if (await target.exists()) await target.rename(rollback.path);
    try {
      await source.rename(target.path);
      if (await rollback.exists()) await rollback.delete();
    } catch (_) {
      if (await rollback.exists() && !await target.exists()) {
        await rollback.rename(target.path);
      }
      rethrow;
    }
  }

  Future<List<int>> _readOrCreateVaultKey() async {
    return _keyProvider.readOrCreateKey();
  }

  Future<File> _vaultFile() async {
    final provider = _vaultFileProvider;
    if (provider != null) {
      return provider();
    }
    final directory = await getApplicationSupportDirectory();
    return File('${directory.path}/$_vaultFileName');
  }
}
