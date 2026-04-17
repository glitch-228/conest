import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import 'models.dart';

List<int> _secureRandomBytes(int length) {
  final random = Random.secure();
  return List<int>.generate(length, (_) => random.nextInt(256));
}

class AppInstanceLock {
  AppInstanceLock({Directory? directory}) : _directory = directory;

  final Directory? _directory;
  RandomAccessFile? _lockFile;

  Future<bool> acquire() async {
    final directory = _directory ?? await getApplicationSupportDirectory();
    await directory.create(recursive: true);
    final file = File('${directory.path}/conest.lock');
    final lockFile = await file.open(mode: FileMode.write);
    try {
      await lockFile.lock(FileLock.exclusive);
      await lockFile.setPosition(0);
      await lockFile.truncate(0);
      await lockFile.writeString('$pid\n');
      _lockFile = lockFile;
      return true;
    } catch (_) {
      await lockFile.close();
      return false;
    }
  }

  Future<void> release() async {
    final lockFile = _lockFile;
    if (lockFile == null) {
      return;
    }
    _lockFile = null;
    await lockFile.unlock();
    await lockFile.close();
  }
}

class VaultStore {
  VaultStore({FlutterSecureStorage? secureStorage})
    : _secureStorage = secureStorage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _secureStorage;
  static const _vaultKeyName = 'conest.vault_key';
  static const _vaultFileName = 'conest.vault';

  Future<VaultSnapshot> load() async {
    final file = await _vaultFile();
    if (!await file.exists()) {
      return VaultSnapshot.empty();
    }

    final envelopeJson =
        jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    final key = await _readOrCreateVaultKey();
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

  Future<void> save(VaultSnapshot snapshot) async {
    final file = await _vaultFile();
    await file.parent.create(recursive: true);
    final key = await _readOrCreateVaultKey();
    final algorithm = Chacha20.poly1305Aead();
    final secretBox = await algorithm.encrypt(
      utf8.encode(jsonEncode(snapshot.toJson())),
      secretKey: SecretKey(key),
      nonce: _secureRandomBytes(algorithm.nonceLength),
      aad: utf8.encode('conest.vault.v1'),
    );
    final envelope = <String, dynamic>{
      'version': 1,
      'nonceBase64': base64Encode(secretBox.nonce),
      'ciphertextBase64': base64Encode(secretBox.cipherText),
      'macBase64': base64Encode(secretBox.mac.bytes),
    };
    await file.writeAsString(jsonEncode(envelope), flush: true);
  }

  Future<void> clear() async {
    final file = await _vaultFile();
    if (await file.exists()) {
      await file.delete();
    }
    await _secureStorage.delete(key: _vaultKeyName);
  }

  Future<List<int>> _readOrCreateVaultKey() async {
    final existing = await _secureStorage.read(key: _vaultKeyName);
    if (existing != null) {
      return base64Decode(existing);
    }
    final created = _secureRandomBytes(32);
    await _secureStorage.write(
      key: _vaultKeyName,
      value: base64Encode(created),
    );
    return created;
  }

  Future<File> _vaultFile() async {
    final directory = await getApplicationSupportDirectory();
    return File('${directory.path}/$_vaultFileName');
  }
}
