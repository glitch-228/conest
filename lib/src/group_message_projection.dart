import 'group_history_event.dart';

/// Reducer for events already verified against signed membership history.
/// Signature verification alone does not authorize changing someone else's
/// message. Mutations name the signed event digest, never a legacy message ID.
class GroupMessageProjection {
  const GroupMessageProjection({
    required this.original,
    required this.body,
    this.edit,
    this.deletion,
  });

  final GroupHistoryEvent original;
  final String body;
  final GroupHistoryEvent? edit;
  final GroupHistoryEvent? deletion;

  bool get deleted => deletion != null;
  DateTime? get editedAt => edit == null
      ? null
      : DateTime.parse(edit!.payload['changedAt'] as String);

  static GroupMessageProjection? reduce(
    GroupHistoryEvent original,
    Iterable<GroupHistoryEvent> mutations,
  ) {
    if (original.kind != GroupEventKind.message ||
        original.payload['body'] is! String) {
      return null;
    }
    GroupHistoryEvent? edit;
    GroupHistoryEvent? deletion;
    for (final event in mutations) {
      if (!canMutate(original, event)) continue;
      if (event.kind == GroupEventKind.deletion) {
        if (deletion == null ||
            GroupHistoryEvent.compare(event, deletion) > 0) {
          deletion = event;
        }
      } else if (edit == null || GroupHistoryEvent.compare(event, edit) > 0) {
        edit = event;
      }
    }
    return GroupMessageProjection(
      original: original,
      // Deletion is terminal even if an older/offline device later edits it.
      body: deletion != null
          ? ''
          : (edit?.payload['body'] ?? original.payload['body']) as String,
      edit: edit,
      deletion: deletion,
    );
  }

  static bool canMutate(GroupHistoryEvent original, GroupHistoryEvent event) =>
      original.kind == GroupEventKind.message &&
      isMutation(event) &&
      event.payload['targetEventId'] == original.eventId &&
      event.groupId == original.groupId &&
      event.authorAccountId == original.authorAccountId &&
      event.authorDeviceId == original.authorDeviceId &&
      event.signingPublicKeyBase64 == original.signingPublicKeyBase64 &&
      event.sequence > original.sequence &&
      event.lamport > original.lamport;

  /// Shape checking is also used when rebuilding journal indexes. Malformed
  /// later records must not shadow a usable edit or tombstone.
  static bool isMutation(GroupHistoryEvent event) {
    final editing = event.kind == GroupEventKind.edit;
    if (!editing && event.kind != GroupEventKind.deletion) return false;
    final payload = event.payload;
    final target = payload['targetEventId'];
    final changedAt = payload['changedAt'];
    if (payload.length != (editing ? 3 : 2) ||
        target is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(target) ||
        changedAt is! String ||
        changedAt.length > 40 ||
        !changedAt.endsWith('Z') ||
        DateTime.tryParse(changedAt) == null) {
      return false;
    }
    if (!editing) return true;
    final body = payload['body'];
    return body is String && body.trim().isNotEmpty;
  }
}
