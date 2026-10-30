import '../models.dart';

/// What a device held before it joined an account with "Replace": the chats
/// it gave up, the full records of their contacts and the state of the
/// groups that were replaced. It lives in the vault (so it is encrypted and
/// is restored with it), its attachments stay referenced, and it is shown
/// read-only. Only an explicit export writes it out as plain text.
class LinkArchive {
  LinkArchive({
    required this.id,
    required this.createdAt,
    required this.contacts,
    required this.conversations,
    required this.groups,
  });

  final String id;
  final DateTime createdAt;
  final List<ContactRecord> contacts;
  final List<ConversationRecord> conversations;
  final List<GroupRecord> groups;

  /// The name of a contact in this archive (its alias then, or the id).
  String nameOf(String deviceId) {
    for (final contact in contacts) {
      if (contact.deviceId == deviceId) return contact.alias;
    }
    for (final group in groups) {
      if (group.groupId == deviceId) return group.title;
    }
    return deviceId;
  }

  int get messageCount =>
      conversations.fold(0, (sum, c) => sum + c.messages.length);

  Map<String, dynamic> toJson() => {
    'id': id,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'contacts': [for (final c in contacts) c.toJson()],
    'conversations': [for (final c in conversations) c.toJson()],
    'groups': [for (final g in groups) g.toJson()],
  };

  /// The archive for the export file: contacts with their names, public keys
  /// and addresses only, and no secret or key material (not the inbox
  /// secrets, route secrets, or the keys that open files). Anything named
  /// like a secret is dropped wherever it is.
  Map<String, dynamic> toExportJson() => _scrub({
    'id': id,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'contacts': [for (final c in contacts) _exportContact(c.toJson())],
    'conversations': [for (final c in conversations) c.toJson()],
    'groups': [for (final g in groups) g.toJson()],
  });

  static const _contactExportKeys = {
    'accountId',
    'deviceId',
    'alias',
    'displayName',
    'bio',
    'publicKeyBase64',
    'signingPublicKeyBase64',
    'accountKey',
    'safetyNumber',
    'irohEndpointId',
    'matrixAddress',
    'carrierAddresses',
    'trustedAt',
  };

  static Map<String, dynamic> _exportContact(Map<String, dynamic> json) => {
    for (final entry in json.entries)
      if (_contactExportKeys.contains(entry.key)) entry.key: entry.value,
  };

  static final _secretName = RegExp(
    r'secret|private|encryptionkey|token|password|seed',
    caseSensitive: false,
  );

  static dynamic _scrub(dynamic value) {
    if (value is Map) {
      return {
        for (final entry in value.entries)
          if (!_secretName.hasMatch('${entry.key}'))
            '${entry.key}': _scrub(entry.value),
      };
    }
    if (value is List) return [for (final item in value) _scrub(item)];
    return value;
  }

  /// Null when [json] is not an archive this version can read.
  static LinkArchive? tryParse(Map<String, dynamic> json) {
    try {
      final id = json['id'];
      final at = DateTime.tryParse(json['createdAt'] as String? ?? '');
      if (id is! String || at == null) return null;
      return LinkArchive(
        id: id,
        createdAt: at.toUtc(),
        contacts: [
          for (final item in json['contacts'] as List<dynamic>? ?? const [])
            if (item is Map<String, dynamic>) ContactRecord.fromJson(item),
        ],
        conversations: [
          for (final item
              in json['conversations'] as List<dynamic>? ?? const [])
            if (item is Map<String, dynamic>) ConversationRecord.fromJson(item),
        ],
        groups: [
          for (final item in json['groups'] as List<dynamic>? ?? const [])
            if (item is Map<String, dynamic>) GroupRecord.fromJson(item),
        ],
      );
    } catch (_) {
      return null;
    }
  }
}
