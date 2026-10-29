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
