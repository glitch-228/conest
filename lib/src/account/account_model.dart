/// Multi-device accounts (M29): one account key certifies each of the
/// account's devices. Contacts accept any device the account key vouches
/// for, and refuse revoked ones.
///
/// Everything signed here is domain separated ("conest/account/v1/<type>")
/// and canonical (JSON with sorted keys), so a signature for one kind of
/// statement can never be read as another.
library;

import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import '../native_ed25519.dart';

/// Highest device list version accepted (no overflow, no absurd jumps).
const int maxDeviceListVersion = 1 << 30;

/// Most devices one account lists (and certificates one list carries).
const int maxAccountDevices = 16;

/// Most revoked devices one list remembers (they are never forgotten
/// while the list grows; older ones fall off past this).
const int maxRevokedDevices = 1024;

/// A device linked less than this long ago may not add or remove others.
const Duration newDeviceManagementDelay = Duration(hours: 24);

const int _maxIdLength = 128;
const int _maxNameLength = 64;

/// The bytes signed for a statement of [type]: domain separated and
/// canonical.
List<int> accountSigningBytes(String type, Map<String, Object?> fields) =>
    utf8.encode('conest/account/v1/$type\n${_canonicalJson(fields)}');

String _canonicalJson(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((key) => key as String).toList()..sort();
    return '{${[for (final key in keys) '${jsonEncode(key)}:${_canonicalJson(value[key])}'].join(',')}}';
  }
  if (value is List) {
    return '[${value.map(_canonicalJson).join(',')}]';
  }
  return jsonEncode(value);
}

bool _isKey(Object? value) {
  if (value is! String || value.length > 64) return false;
  try {
    return base64Decode(value).length == 32;
  } on FormatException {
    return false;
  }
}

bool _isSignature(Object? value) {
  if (value is! String || value.length > 128) return false;
  try {
    return base64Decode(value).length == 64;
  } on FormatException {
    return false;
  }
}

bool _isId(Object? value) =>
    value is String && value.isNotEmpty && value.length <= _maxIdLength;

DateTime? _time(Object? value) => value is String && value.length <= 40
    ? DateTime.tryParse(value)?.toUtc()
    : null;

/// Checks an Ed25519 [signatureBase64] over [bytes] by [publicKeyBase64].
Future<bool> verifyEd25519(
  List<int> bytes, {
  required String signatureBase64,
  required String publicKeyBase64,
}) async {
  try {
    return await verifyEd25519Signature(
      publicKey: base64Decode(publicKeyBase64),
      message: bytes,
      signature: base64Decode(signatureBase64),
    );
  } on FormatException {
    return false;
  }
}

/// Signs [bytes] with an Ed25519 key pair.
Future<String> signEd25519(
  List<int> bytes, {
  required String publicKeyBase64,
  required String privateKeyBase64,
}) async {
  final signature = await Ed25519().sign(
    bytes,
    keyPair: SimpleKeyPairData(
      base64Decode(privateKeyBase64),
      publicKey: SimplePublicKey(
        base64Decode(publicKeyBase64),
        type: KeyPairType.ed25519,
      ),
      type: KeyPairType.ed25519,
    ),
  );
  return base64Encode(signature.bytes);
}

/// The account's own Ed25519 key. Every linked device holds it.
class AccountKeys {
  const AccountKeys({
    required this.publicKeyBase64,
    required this.privateKeyBase64,
  });

  final String publicKeyBase64;
  final String privateKeyBase64;

  static Future<AccountKeys> generate() async {
    final pair = await Ed25519().newKeyPair();
    final data = await pair.extract();
    final publicKey = await pair.extractPublicKey();
    return AccountKeys(
      publicKeyBase64: base64Encode(publicKey.bytes),
      privateKeyBase64: base64Encode(data.bytes),
    );
  }

  Future<String> sign(List<int> bytes) => signEd25519(
    bytes,
    publicKeyBase64: publicKeyBase64,
    privateKeyBase64: privateKeyBase64,
  );
}

/// An existing single-device identity joining an account key: signed by
/// both the device's signing key (which contacts already pinned) and the
/// new account key, so contacts can trust the account key from what they
/// already know.
class AccountUpgrade {
  const AccountUpgrade({
    required this.accountId,
    required this.deviceId,
    required this.deviceSigningKeyBase64,
    required this.accountKeyBase64,
    required this.issuedAt,
    required this.deviceSignatureBase64,
    required this.accountSignatureBase64,
  });

  final String accountId;
  final String deviceId;
  final String deviceSigningKeyBase64;
  final String accountKeyBase64;
  final DateTime issuedAt;
  final String deviceSignatureBase64;
  final String accountSignatureBase64;

  static Map<String, Object?> _fields({
    required String accountId,
    required String deviceId,
    required String deviceSigningKeyBase64,
    required String accountKeyBase64,
    required DateTime issuedAt,
  }) => {
    'accountId': accountId,
    'deviceId': deviceId,
    'deviceSigningKey': deviceSigningKeyBase64,
    'accountKey': accountKeyBase64,
    'issuedAt': issuedAt.toUtc().toIso8601String(),
  };

  List<int> get signingBytes => accountSigningBytes(
    'upgrade',
    _fields(
      accountId: accountId,
      deviceId: deviceId,
      deviceSigningKeyBase64: deviceSigningKeyBase64,
      accountKeyBase64: accountKeyBase64,
      issuedAt: issuedAt,
    ),
  );

  static Future<AccountUpgrade> create({
    required String accountId,
    required String deviceId,
    required String deviceSigningPublicKeyBase64,
    required String deviceSigningPrivateKeyBase64,
    required AccountKeys account,
    required DateTime issuedAt,
  }) async {
    final bytes = accountSigningBytes(
      'upgrade',
      _fields(
        accountId: accountId,
        deviceId: deviceId,
        deviceSigningKeyBase64: deviceSigningPublicKeyBase64,
        accountKeyBase64: account.publicKeyBase64,
        issuedAt: issuedAt,
      ),
    );
    return AccountUpgrade(
      accountId: accountId,
      deviceId: deviceId,
      deviceSigningKeyBase64: deviceSigningPublicKeyBase64,
      accountKeyBase64: account.publicKeyBase64,
      issuedAt: issuedAt.toUtc(),
      deviceSignatureBase64: await signEd25519(
        bytes,
        publicKeyBase64: deviceSigningPublicKeyBase64,
        privateKeyBase64: deviceSigningPrivateKeyBase64,
      ),
      accountSignatureBase64: await account.sign(bytes),
    );
  }

  /// True when both signatures hold and the device key is the one this
  /// contact pinned for [deviceId] of [accountId].
  Future<bool> verify({
    required String accountId,
    required String deviceId,
    required String pinnedDeviceSigningKeyBase64,
  }) async {
    if (this.accountId != accountId ||
        this.deviceId != deviceId ||
        deviceSigningKeyBase64 != pinnedDeviceSigningKeyBase64) {
      return false;
    }
    final bytes = signingBytes;
    return await verifyEd25519(
          bytes,
          signatureBase64: deviceSignatureBase64,
          publicKeyBase64: deviceSigningKeyBase64,
        ) &&
        await verifyEd25519(
          bytes,
          signatureBase64: accountSignatureBase64,
          publicKeyBase64: accountKeyBase64,
        );
  }

  Map<String, Object?> toJson() => {
    ..._fields(
      accountId: accountId,
      deviceId: deviceId,
      deviceSigningKeyBase64: deviceSigningKeyBase64,
      accountKeyBase64: accountKeyBase64,
      issuedAt: issuedAt,
    ),
    'deviceSignature': deviceSignatureBase64,
    'accountSignature': accountSignatureBase64,
  };

  static AccountUpgrade? fromJson(Object? json) {
    if (json is! Map) return null;
    final issuedAt = _time(json['issuedAt']);
    if (!_isId(json['accountId']) ||
        !_isId(json['deviceId']) ||
        !_isKey(json['deviceSigningKey']) ||
        !_isKey(json['accountKey']) ||
        issuedAt == null ||
        !_isSignature(json['deviceSignature']) ||
        !_isSignature(json['accountSignature'])) {
      return null;
    }
    return AccountUpgrade(
      accountId: json['accountId'] as String,
      deviceId: json['deviceId'] as String,
      deviceSigningKeyBase64: json['deviceSigningKey'] as String,
      accountKeyBase64: json['accountKey'] as String,
      issuedAt: issuedAt,
      deviceSignatureBase64: json['deviceSignature'] as String,
      accountSignatureBase64: json['accountSignature'] as String,
    );
  }
}

/// One device of an account, as the account key vouches for it.
class DeviceCert {
  const DeviceCert({
    required this.accountId,
    required this.deviceId,
    required this.encryptionKeyBase64,
    required this.signingKeyBase64,
    required this.name,
    required this.linkedAt,
    required this.signatureBase64,
    required this.proofSignatureBase64,
    this.irohEndpointId,
  });

  final String accountId;
  final String deviceId;

  /// The device's own signature (by [signingKeyBase64]) on its keys and
  /// id: proof it holds the key, so nobody can certify another person's
  /// keys or claim a device id that is not theirs.
  final String proofSignatureBase64;

  /// The bytes a device signs to prove its keys ([proofSignatureBase64]).
  static List<int> proofBytes({
    required String accountId,
    // The account key itself: an account id is only a name anyone can
    // claim, the key is not.
    required String accountKeyBase64,
    required String deviceId,
    required String encryptionKeyBase64,
    required String signingKeyBase64,
    String? irohEndpointId,
  }) => accountSigningBytes('device-proof', {
    'accountId': accountId,
    'accountKey': accountKeyBase64,
    'deviceId': deviceId,
    'encryptionKey': encryptionKeyBase64,
    'signingKey': signingKeyBase64,
    'irohEndpointId': irohEndpointId,
  });

  /// The device's X25519 key (what contacts encrypt to).
  final String encryptionKeyBase64;

  /// The device's Ed25519 key (its installation signing key).
  final String signingKeyBase64;
  final String? irohEndpointId;

  /// A name the user gave the device, such as "Pixel 8".
  final String name;

  /// When it joined the account (the 24-hour rule counts from here).
  final DateTime linkedAt;
  final String signatureBase64;

  static Map<String, Object?> _fields({
    required String accountId,
    required String deviceId,
    required String encryptionKeyBase64,
    required String signingKeyBase64,
    required String? irohEndpointId,
    required String name,
    required DateTime linkedAt,
  }) => {
    'accountId': accountId,
    'deviceId': deviceId,
    'encryptionKey': encryptionKeyBase64,
    'signingKey': signingKeyBase64,
    'irohEndpointId': irohEndpointId,
    'name': name,
    'linkedAt': linkedAt.toUtc().toIso8601String(),
  };

  Map<String, Object?> get _signedFields => _fields(
    accountId: accountId,
    deviceId: deviceId,
    encryptionKeyBase64: encryptionKeyBase64,
    signingKeyBase64: signingKeyBase64,
    irohEndpointId: irohEndpointId,
    name: name,
    linkedAt: linkedAt,
  );

  static Future<DeviceCert> issue({
    required AccountKeys account,
    required String accountId,
    required String deviceId,
    required String encryptionKeyBase64,
    required String signingKeyBase64,
    String? irohEndpointId,
    required String name,
    required DateTime linkedAt,
    required String proofSignatureBase64,
  }) async {
    final trimmed = name.trim();
    final fields = _fields(
      accountId: accountId,
      deviceId: deviceId,
      encryptionKeyBase64: encryptionKeyBase64,
      signingKeyBase64: signingKeyBase64,
      irohEndpointId: irohEndpointId,
      name: trimmed.length > _maxNameLength
          ? trimmed.substring(0, _maxNameLength)
          : trimmed,
      linkedAt: linkedAt,
    );
    return DeviceCert(
      accountId: accountId,
      deviceId: deviceId,
      encryptionKeyBase64: encryptionKeyBase64,
      signingKeyBase64: signingKeyBase64,
      irohEndpointId: irohEndpointId,
      name: fields['name']! as String,
      linkedAt: linkedAt.toUtc(),
      signatureBase64: await account.sign(
        accountSigningBytes('device', fields),
      ),
      proofSignatureBase64: proofSignatureBase64,
    );
  }

  /// True when the account key vouches for this device and the device
  /// proved it holds its signing key.
  Future<bool> verify(String accountKeyBase64) async =>
      await verifyEd25519(
        accountSigningBytes('device', _signedFields),
        signatureBase64: signatureBase64,
        publicKeyBase64: accountKeyBase64,
      ) &&
      await verifyEd25519(
        proofBytes(
          accountId: accountId,
          accountKeyBase64: accountKeyBase64,
          deviceId: deviceId,
          encryptionKeyBase64: encryptionKeyBase64,
          signingKeyBase64: signingKeyBase64,
          irohEndpointId: irohEndpointId,
        ),
        signatureBase64: proofSignatureBase64,
        publicKeyBase64: signingKeyBase64,
      );

  /// Whether this device may add or remove others at [now].
  bool mayManageDevicesAt(DateTime now) =>
      !now.toUtc().isBefore(linkedAt.add(newDeviceManagementDelay));

  Map<String, Object?> toJson() => {
    ..._signedFields,
    'signature': signatureBase64,
    'proof': proofSignatureBase64,
  };

  static DeviceCert? fromJson(Object? json) {
    if (json is! Map) return null;
    final linkedAt = _time(json['linkedAt']);
    final iroh = json['irohEndpointId'];
    final name = json['name'];
    if (!_isId(json['accountId']) ||
        !_isId(json['deviceId']) ||
        !_isKey(json['encryptionKey']) ||
        !_isKey(json['signingKey']) ||
        (iroh != null && !(iroh is String && iroh.length <= 128)) ||
        name is! String ||
        name.length > _maxNameLength ||
        linkedAt == null ||
        !_isSignature(json['signature']) ||
        !_isSignature(json['proof'])) {
      return null;
    }
    return DeviceCert(
      accountId: json['accountId'] as String,
      deviceId: json['deviceId'] as String,
      encryptionKeyBase64: json['encryptionKey'] as String,
      signingKeyBase64: json['signingKey'] as String,
      irohEndpointId: iroh as String?,
      name: name,
      linkedAt: linkedAt,
      signatureBase64: json['signature'] as String,
      proofSignatureBase64: json['proof'] as String,
    );
  }
}

/// The account's devices at one version, signed by the account key.
/// Versions only go up, and a revoked device stays revoked.
class AccountDeviceList {
  const AccountDeviceList({
    required this.accountId,
    required this.version,
    required this.devices,
    required this.revoked,
    required this.issuedAt,
    required this.signatureBase64,
  });

  final String accountId;
  final int version;
  final List<DeviceCert> devices;

  /// Revoked device ids, with when.
  final Map<String, DateTime> revoked;
  final DateTime issuedAt;
  final String signatureBase64;

  static Map<String, Object?> _fields({
    required String accountId,
    required int version,
    required List<DeviceCert> devices,
    required Map<String, DateTime> revoked,
    required DateTime issuedAt,
  }) => {
    'accountId': accountId,
    'version': version,
    'devices': [for (final device in devices) device.toJson()],
    'revoked': {
      for (final entry in revoked.entries)
        entry.key: entry.value.toUtc().toIso8601String(),
    },
    'issuedAt': issuedAt.toUtc().toIso8601String(),
  };

  static Future<AccountDeviceList> issue({
    required AccountKeys account,
    required String accountId,
    required int version,
    required List<DeviceCert> devices,
    Map<String, DateTime> revoked = const {},
    required DateTime issuedAt,
  }) async {
    if (devices.length > maxAccountDevices) {
      throw ArgumentError(
        'An account lists at most $maxAccountDevices devices.',
      );
    }
    final kept = Map.fromEntries(
      (revoked.entries.toList()..sort((a, b) => a.value.compareTo(b.value)))
          .reversed
          .take(maxRevokedDevices),
    );
    final fields = _fields(
      accountId: accountId,
      version: version,
      devices: devices,
      revoked: kept,
      issuedAt: issuedAt,
    );
    return AccountDeviceList(
      accountId: accountId,
      version: version,
      devices: List.unmodifiable(devices),
      revoked: Map.unmodifiable(kept),
      issuedAt: issuedAt.toUtc(),
      signatureBase64: await account.sign(
        accountSigningBytes('devices', fields),
      ),
    );
  }

  /// True when the account key signed this list, every certificate is the
  /// account's own and valid, no device appears twice, and no revoked
  /// device is listed.
  Future<bool> verify(String accountKeyBase64) async {
    if (devices.length > maxAccountDevices ||
        revoked.length > maxRevokedDevices ||
        version < 1) {
      return false;
    }
    final seen = <String>{};
    for (final device in devices) {
      if (device.accountId != accountId ||
          !seen.add(device.deviceId) ||
          revoked.containsKey(device.deviceId)) {
        return false;
      }
    }
    final fields = _fields(
      accountId: accountId,
      version: version,
      devices: devices,
      revoked: revoked,
      issuedAt: issuedAt,
    );
    if (!await verifyEd25519(
      accountSigningBytes('devices', fields),
      signatureBase64: signatureBase64,
      publicKeyBase64: accountKeyBase64,
    )) {
      return false;
    }
    for (final device in devices) {
      if (!await device.verify(accountKeyBase64)) return false;
    }
    return true;
  }

  /// Whether this list may replace [current]: a newer version that keeps
  /// every revocation (a revoked device never comes back).
  bool supersedes(AccountDeviceList? current) {
    if (current == null) return true;
    if (current.accountId != accountId || version <= current.version) {
      return false;
    }
    return current.revoked.keys.every(revoked.containsKey);
  }

  /// The certificate of [deviceId], unless it is missing or revoked.
  DeviceCert? deviceFor(String deviceId) {
    if (revoked.containsKey(deviceId)) return null;
    for (final device in devices) {
      if (device.deviceId == deviceId) return device;
    }
    return null;
  }

  Map<String, Object?> toJson() => {
    ..._fields(
      accountId: accountId,
      version: version,
      devices: devices,
      revoked: revoked,
      issuedAt: issuedAt,
    ),
    'signature': signatureBase64,
  };

  static AccountDeviceList? fromJson(Object? json) {
    if (json is! Map) return null;
    final version = json['version'];
    final rawDevices = json['devices'];
    final rawRevoked = json['revoked'];
    final issuedAt = _time(json['issuedAt']);
    if (!_isId(json['accountId']) ||
        version is! int ||
        version < 1 ||
        version > maxDeviceListVersion ||
        rawDevices is! List ||
        rawDevices.length > maxAccountDevices ||
        rawRevoked is! Map ||
        rawRevoked.length > maxRevokedDevices ||
        issuedAt == null ||
        !_isSignature(json['signature'])) {
      return null;
    }
    final devices = <DeviceCert>[];
    for (final raw in rawDevices) {
      final device = DeviceCert.fromJson(raw);
      if (device == null) return null;
      devices.add(device);
    }
    final revoked = <String, DateTime>{};
    for (final entry in rawRevoked.entries) {
      final at = _time(entry.value);
      if (!_isId(entry.key) || at == null) return null;
      revoked[entry.key as String] = at;
    }
    return AccountDeviceList(
      accountId: json['accountId'] as String,
      version: version,
      devices: List.unmodifiable(devices),
      revoked: Map.unmodifiable(revoked),
      issuedAt: issuedAt,
      signatureBase64: json['signature'] as String,
    );
  }
}
