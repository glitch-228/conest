import 'group_history_event.dart';

/// Reducer for events already verified against signed membership history.
/// Signature verification alone does not authorize changing someone else's
/// message. Mutations name the signed event digest, never a legacy message ID.
class GroupMessageProjection {
  const GroupMessageProjection({
    required this.original,
    required this.body,
    required this.reactions,
    this.edit,
    this.deletion,
  });

  final GroupHistoryEvent original;
  final String body;
  final Map<String, Set<String>> reactions;
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
    final latestReactions = <String, GroupHistoryEvent>{};
    for (final event in mutations) {
      if (event.kind == GroupEventKind.reaction) {
        if (!isMutation(event) || !canReact(original, event)) continue;
        final emoji = event.payload['emoji'] as String;
        final key = '${event.authorDeviceId}\u0000$emoji';
        final previous = latestReactions[key];
        if (previous == null ||
            GroupHistoryEvent.compare(event, previous) > 0) {
          latestReactions[key] = event;
        }
        continue;
      }
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
    final reactions = <String, Set<String>>{};
    for (final event in latestReactions.values) {
      final emoji = event.payload['emoji'] as String;
      final active = event.payload['active'] as bool;
      final users = reactions.putIfAbsent(emoji, () => <String>{});
      if (active) {
        users.add(event.authorDeviceId);
      } else {
        users.remove(event.authorDeviceId);
      }
    }
    reactions.removeWhere((_, users) => users.isEmpty);
    return GroupMessageProjection(
      original: original,
      reactions: {
        for (final entry in reactions.entries)
          entry.key: Set<String>.unmodifiable(entry.value),
      },
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

  static bool canReact(GroupHistoryEvent original, GroupHistoryEvent event) =>
      original.kind == GroupEventKind.message &&
      event.kind == GroupEventKind.reaction &&
      event.payload['targetEventId'] == original.eventId &&
      event.groupId == original.groupId &&
      event.sequence > 0 &&
      event.lamport > original.lamport;

  /// Shape checking is also used when rebuilding journal indexes. Malformed
  /// later records must not shadow a usable edit or tombstone.
  static bool isMutation(GroupHistoryEvent event) {
    final editing = event.kind == GroupEventKind.edit;
    final reacting = event.kind == GroupEventKind.reaction;
    if (!editing && !reacting && event.kind != GroupEventKind.deletion) {
      return false;
    }
    final payload = event.payload;
    final target = payload['targetEventId'];
    final changedAt = payload['changedAt'];
    if (payload.length !=
            (editing
                ? 3
                : reacting
                ? 4
                : 2) ||
        target is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(target) ||
        changedAt is! String ||
        changedAt.length > 40 ||
        !changedAt.endsWith('Z') ||
        DateTime.tryParse(changedAt) == null) {
      return false;
    }
    if (reacting) {
      final emoji = payload['emoji'];
      return emoji is String &&
          emoji.isNotEmpty &&
          emoji.length <= 32 &&
          payload['active'] is bool;
    }
    if (!editing) return true;
    final body = payload['body'];
    return body is String && body.trim().isNotEmpty;
  }
}
