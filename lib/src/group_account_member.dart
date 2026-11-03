/// A member of a group that is an account (M29): its devices come from a
/// device list pinned by digest in the signed membership record.
///
/// Kept in its own file so `models.dart` can hold it in [GroupRecord]
/// without importing the account code.
library;

import 'dart:convert';

const int maxGroupAccounts = 16;
const int maxGroupAccountDeviceIds = 16;
const int _maxIdLength = 128;
const int maxGroupAccountVersion = 1 << 30;

/// Roles belong to the account. `owner` marks the owner's account (the
/// owner itself stays a device, `GroupRecord.ownerDeviceId`).
enum GroupAccountRole { member, moderator, admin, owner }

bool _isId(Object? value) =>
    value is String &&
    value.isNotEmpty &&
    value.length <= _maxIdLength &&
    value.trim() == value;

bool _isDigest(Object? value) =>
    value is String && RegExp(r'^[0-9a-f]{64}$').hasMatch(value);

bool _isKey(Object? value) {
  if (value is! String || value.length > 64) return false;
  try {
    return base64Decode(value).length == 32;
  } on FormatException {
    return false;
  }
}

List<String>? _ids(Object? value) {
  if (value == null) return const [];
  if (value is! List || value.length > maxGroupAccountDeviceIds) return null;
  final seen = <String>{};
  for (final id in value) {
    if (!_isId(id) || !seen.add(id as String)) return null;
  }
  return List.unmodifiable(seen);
}

class GroupAccountMember {
  const GroupAccountMember({
    required this.accountId,
    required this.accountKeyBase64,
    required this.role,
    required this.listVersion,
    required this.listDigest,
    this.admission,
    this.approvedDeviceIds = const [],
    this.excludedDeviceIds = const [],
    this.upgrade,
  });

  final String accountId;
  final String accountKeyBase64;
  final GroupAccountRole role;

  /// The pinned list: [listDigest] is the sha256 of its canonical JSON.
  final int listVersion;
  final String listDigest;

  /// Digest of the record that first admitted the account; null on the wire
  /// and here means "the record that carries this entry".
  final String? admission;

  /// Only in groups that confirm new devices.
  final List<String> approvedDeviceIds;
  final List<String> excludedDeviceIds;

  /// The `AccountUpgrade` JSON, only in the record that folds a device-only
  /// member into this account.
  final Map<String, Object?>? upgrade;

  Map<String, Object?> toJson() => {
    'accountId': accountId,
    'accountKey': accountKeyBase64,
    'role': role.name,
    'listVersion': listVersion,
    'listDigest': listDigest,
    if (admission != null) 'admission': admission,
    if (approvedDeviceIds.isNotEmpty) 'approvedDeviceIds': approvedDeviceIds,
    if (excludedDeviceIds.isNotEmpty) 'excludedDeviceIds': excludedDeviceIds,
    if (upgrade != null) 'upgrade': upgrade,
  };

  GroupAccountMember copyWith({
    GroupAccountRole? role,
    int? listVersion,
    String? listDigest,
    String? admission,
    List<String>? approvedDeviceIds,
    List<String>? excludedDeviceIds,
    Map<String, Object?>? upgrade,
    bool clearUpgrade = false,
  }) => GroupAccountMember(
    accountId: accountId,
    accountKeyBase64: accountKeyBase64,
    role: role ?? this.role,
    listVersion: listVersion ?? this.listVersion,
    listDigest: listDigest ?? this.listDigest,
    admission: admission ?? this.admission,
    approvedDeviceIds: approvedDeviceIds ?? this.approvedDeviceIds,
    excludedDeviceIds: excludedDeviceIds ?? this.excludedDeviceIds,
    upgrade: clearUpgrade ? null : (upgrade ?? this.upgrade),
  );

  /// Null when [json] is not a well formed entry. Strict: nothing is
  /// repaired, because the signed record must mean the same everywhere.
  static GroupAccountMember? tryParse(Object? json) {
    if (json is! Map) return null;
    const known = {
      'accountId',
      'accountKey',
      'role',
      'listVersion',
      'listDigest',
      'admission',
      'approvedDeviceIds',
      'excludedDeviceIds',
      'upgrade',
    };
    if (!json.keys.every((key) => key is String && known.contains(key))) {
      return null;
    }
    final role = GroupAccountRole.values
        .where((value) => value.name == json['role'])
        .firstOrNull;
    final version = json['listVersion'];
    final approved = _ids(json['approvedDeviceIds']);
    final excluded = _ids(json['excludedDeviceIds']);
    final upgrade = json['upgrade'];
    if (!_isId(json['accountId']) ||
        !_isKey(json['accountKey']) ||
        role == null ||
        version is! int ||
        version < 1 ||
        version > maxGroupAccountVersion ||
        !_isDigest(json['listDigest']) ||
        (json['admission'] != null && !_isDigest(json['admission'])) ||
        approved == null ||
        excluded == null ||
        (upgrade != null && (upgrade is! Map || upgrade.length > 16))) {
      return null;
    }
    return GroupAccountMember(
      accountId: json['accountId'] as String,
      accountKeyBase64: json['accountKey'] as String,
      role: role,
      listVersion: version,
      listDigest: json['listDigest'] as String,
      admission: json['admission'] as String?,
      approvedDeviceIds: approved,
      excludedDeviceIds: excluded,
      upgrade: upgrade == null
          ? null
          : Map<String, Object?>.unmodifiable(
              (upgrade as Map).cast<String, Object?>(),
            ),
    );
  }

  /// Parses a whole `memberAccounts` list; null when any entry is bad, ids
  /// or keys repeat, or there are too many.
  static List<GroupAccountMember>? tryParseAll(Object? json) {
    if (json == null) return const [];
    if (json is! List || json.length > maxGroupAccounts) return null;
    final result = <GroupAccountMember>[];
    final ids = <String>{};
    final keys = <String>{};
    for (final raw in json) {
      final entry = tryParse(raw);
      if (entry == null ||
          !ids.add(entry.accountId) ||
          !keys.add(entry.accountKeyBase64)) {
        return null;
      }
      result.add(entry);
    }
    return List.unmodifiable(result);
  }
}
