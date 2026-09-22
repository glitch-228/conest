import 'dart:async';
import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import 'group_history_event.dart';
import 'group_file_manifest.dart';
import 'group_history_journal.dart';
import 'group_history_sync.dart';
import 'group_history_wire.dart';
import 'group_membership_history.dart';
import 'group_message_projection.dart';
import 'models.dart';
import 'storage.dart';

/// Application bridge for the durable history protocol. All signing writes for
/// a group are serialized so concurrent sends cannot reuse an author sequence.
class GroupHistoryCoordinator {
  GroupHistoryCoordinator({
    required this.vault,
    required this.identity,
    required this.group,
    required this.send,
    required this.onMessage,
    required this.retainedMessages,
    this.onAttachment,
  });

  final VaultStore vault;
  final IdentityRecord Function() identity;
  final GroupRecord Function(String groupId) group;
  final Future<void> Function(
    String groupId,
    String peer,
    Map<String, Object?> payload,
  )
  send;
  final void Function(String groupId, GroupMessageProjection projection)
  onMessage;
  final Iterable<ChatMessage> Function(String groupId) retainedMessages;
  final void Function(
    String groupId,
    GroupHistoryEvent event,
    GroupFileManifest manifest,
  )?
  onAttachment;

  /// Persist original authorship before advertising a file. The signed event ID
  /// is the transfer identity; provider identities never replace its author.
  Future<GroupHistoryEvent> publishFile(
    GroupRecord snapshot,
    GroupFileManifest manifest,
  ) async {
    await prepareMembership(snapshot);
    return _write(snapshot.groupId, () async {
      final current = group(snapshot.groupId);
      if (current.localRemovedAt != null ||
          !current.hasActiveMember(identity().deviceId)) {
        throw StateError('You are no longer a member of this group.');
      }
      final replica = await _replica(snapshot.groupId);
      final membership = replica.membership.current;
      if (membership == null) {
        throw StateError('Waiting for signed membership history.');
      }
      final event = await _sign(
        replica.journal,
        groupId: snapshot.groupId,
        membershipId: membership.id,
        kind: GroupEventKind.attachment,
        payload: manifest.toPayload(),
      );
      await replica.importEvent(event, carrierDeviceId: identity().deviceId);
      return event;
    });
  }

  /// Resolve a transfer only through retained, authenticated history. This gate
  /// applies to availability requests and every piece served, including partial
  /// files. An approved private contact alone is insufficient authorization.
  Future<GroupFileManifest?> fileForPeer(
    String id,
    String eventId,
    String peer,
  ) async {
    final snapshot = group(id);
    if (_closed ||
        snapshot.localRemovedAt != null ||
        !snapshot.hasActiveMember(identity().deviceId) ||
        !snapshot.hasActiveMember(peer)) {
      return null;
    }
    final replica = await _replica(id);
    final events = await replica.journal.readEvents([eventId]);
    if (events.isEmpty || events.single.kind != GroupEventKind.attachment) {
      return null;
    }
    final event = events.single;
    if (!await replica.membership.canForward(
      event,
      carrierDeviceId: identity().deviceId,
      recipientDeviceId: peer,
    )) {
      return null;
    }
    final latest = group(id);
    if (_closed ||
        latest.localRemovedAt != null ||
        !latest.hasActiveMember(peer) ||
        !latest.hasActiveMember(identity().deviceId)) {
      return null;
    }
    try {
      return GroupFileManifest.fromEvent(event);
    } on FormatException {
      return null;
    }
  }

  Future<GroupHistoryEvent?> fileEventForPeer(
    String id,
    String eventId,
    String peer,
  ) async {
    if (await fileForPeer(id, eventId, peer) == null) return null;
    final events = await (await _replica(id)).journal.readEvents([eventId]);
    return events.isEmpty ? null : events.single;
  }

  bool? supportsMessageMutations(String groupId, String peer) =>
      _wires[groupId]?.supportsMessageMutations(peer);
  final _replicas = <String, Future<GroupHistoryReplica>>{};
  final _writes = <String, Future<void>>{};
  final _wires = <String, GroupHistoryWire>{};
  final _pulls = <String, Future<int>>{};
  bool _closed = false;

  Future<T> _write<T>(String id, Future<T> Function() action) {
    final result = (_writes[id] ?? Future<void>.value()).then((_) {
      if (_closed) throw StateError('Group history is closed.');
      return action();
    });
    _writes[id] = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<GroupHistoryReplica> _replica(String id) async {
    final existing = _replicas[id];
    if (existing != null) return existing;
    final opening = _openReplica(id);
    _replicas[id] = opening;
    try {
      return await opening;
    } catch (_) {
      if (identical(_replicas[id], opening)) _replicas.remove(id);
      rethrow;
    }
  }

  Future<GroupHistoryReplica> _openReplica(String id) async {
    final snapshot = group(id);
    final journal = await vault.openGroupHistory(id);
    final retainedRoot = await journal.readMembershipPage(limit: 1);
    // A retained root is authenticated by this vault's encryption and was
    // validated at import. New groups anchor to their approved owner profile.
    final owner = retainedRoot.isEmpty
        ? snapshot.memberProfileFor(snapshot.ownerDeviceId)
        : GroupMembershipRecord.fromEvent(
            retainedRoot.single,
          ).group.memberProfileFor(
            GroupMembershipRecord.fromEvent(
              retainedRoot.single,
            ).group.ownerDeviceId,
          );
    if (owner?.signingPublicKeyBase64 == null) {
      throw StateError(
        'The group owner needs a signed identity before history can synchronize.',
      );
    }
    return GroupHistoryReplica.restore(
      journal: journal,
      groupId: id,
      localDeviceId: identity().deviceId,
      trustedOwner: owner!,
    );
  }

  Future<GroupHistoryEvent> _sign(
    GroupHistoryJournal journal, {
    required String groupId,
    required String membershipId,
    required GroupEventKind kind,
    required Map<String, Object?> payload,
  }) async {
    final me = identity();
    final previous = await journal.authorHead(me.deviceId);
    final latest = await journal.readPage(limit: 1);
    if (me.signingPublicKeyBase64 == null ||
        me.signingPrivateKeyBase64 == null) {
      throw StateError('Signing identity is unavailable.');
    }
    return GroupHistoryEvent.sign(
      groupId: groupId,
      authorAccountId: me.accountId,
      authorDeviceId: me.deviceId,
      keyPair: SimpleKeyPairData(
        base64Decode(me.signingPrivateKeyBase64!),
        publicKey: SimplePublicKey(
          base64Decode(me.signingPublicKeyBase64!),
          type: KeyPairType.ed25519,
        ),
        type: KeyPairType.ed25519,
      ),
      sequence: (previous?.sequence ?? 0) + 1,
      previousEventId: previous?.eventId,
      lamport: (latest.isEmpty ? 0 : latest.first.lamport) + 1,
      membershipId: membershipId,
      kind: kind,
      payload: payload,
    );
  }

  Future<GroupHistoryVisibility> historyVisibility(String id) async =>
      (await _replica(id)).membership.current?.historyVisibility ??
      GroupHistoryVisibility.allRetained;

  Future<GroupHistoryEvent?> prepareMembership(
    GroupRecord snapshot, {
    GroupHistoryVisibility? visibility,
  }) => _write(snapshot.groupId, () async {
    final replica = await _replica(snapshot.groupId);
    final history = replica.membership;
    final current = history.current;
    final me = identity();
    if (history.hasConflict) {
      throw StateError('Group membership conflict needs owner resolution.');
    }
    if (visibility != null && snapshot.ownerDeviceId != me.deviceId) {
      throw StateError('Only the group owner can change history visibility.');
    }
    if (current != null &&
        current.group.membershipVersion == snapshot.membershipVersion) {
      return current.proof;
    }
    if (current == null && snapshot.ownerDeviceId != me.deviceId) return null;
    final parents = history.heads;
    final checkpoints = <String, GroupHistoryCheckpoint>{};
    // Capture retained event boundaries for new admissions, including authors
    // no longer active. Wall clocks are not admission boundaries.
    if (snapshot.activeMemberDeviceIds.any(
      (device) => current?.admissions[device] == null,
    )) {
      String? afterAuthor;
      while (true) {
        final authors = await replica.journal.authors(after: afterAuthor);
        if (authors.isEmpty) break;
        for (final author in authors) {
          final head = await replica.journal.authorHead(author);
          if (head != null) {
            checkpoints[author] = GroupHistoryCheckpoint(
              sequence: head.sequence,
              eventId: head.eventId,
            );
          }
        }
        afterAuthor = authors.last;
      }
    }
    final proof = await _sign(
      replica.journal,
      groupId: snapshot.groupId,
      membershipId: parents.isEmpty
          ? GroupMembershipRecord.rootReference(
              snapshot.groupId,
              me.signingPublicKeyBase64!,
            )
          : parents.first,
      kind: GroupEventKind.membership,
      payload: GroupMembershipRecord.payload(
        group: snapshot,
        parents: parents,
        historyVisibility:
            visibility ??
            current?.historyVisibility ??
            GroupHistoryVisibility.allRetained,
        admissions: {
          for (final device in snapshot.activeMemberDeviceIds)
            device: current?.admissions[device],
        },
        checkpoints: checkpoints,
      ),
    );
    await replica.importMembership(proof);
    return proof;
  });

  Future<void> importMembership(String id, String encoded) =>
      _write(id, () async {
        final proof = GroupHistoryEvent.decode(encoded);
        final replica = await _replica(id);
        if (await replica.importMembership(proof) ==
            GroupMembershipImport.missingParents) {
          throw StateError('Group history needs earlier membership records.');
        }
      });

  Future<GroupHistoryEvent?> recordOutgoing(
    GroupRecord snapshot,
    ChatMessage message,
  ) async {
    await prepareMembership(snapshot);
    return _write(snapshot.groupId, () async {
      final replica = await _replica(snapshot.groupId);
      final membership = replica.membership.current;
      if (membership == null) {
        throw StateError('Waiting for the owner’s signed membership history.');
      }
      final existing = await replica.journal.sourceMessage(
        message.senderDeviceId,
        message.id,
      );
      if (existing != null) {
        return existing;
      }
      if (!message.outbound ||
          message.senderDeviceId != identity().deviceId ||
          message.attachment != null ||
          message.groupFile != null) {
        return null;
      }
      final event = await _sign(
        replica.journal,
        groupId: snapshot.groupId,
        membershipId: membership.id,
        kind: GroupEventKind.message,
        payload: {
          'messageId': message.id,
          'body': message.body,
          'createdAt': message.createdAt.toUtc().toIso8601String(),
          'senderDisplayName': message.senderDisplayName,
          'replyToMessageId': message.replyToMessageId,
          'replySnippet': message.replySnippet,
          'replySenderDeviceId': message.replySenderDeviceId,
          'replySenderDisplayName': message.replySenderDisplayName,
        },
      );
      await replica.importEvent(event, carrierDeviceId: identity().deviceId);
      return event;
    });
  }

  /// Searches the worker-owned journal and projects only events the current
  /// member is still allowed to receive. Mutation hits resolve to their
  /// original message, so edited text remains searchable without exposing an
  /// unauthorized historical record.
  Future<void> searchAndProject(
    String id,
    String query, {
    int limit = 64,
  }) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return;
    final snapshot = group(id);
    if (_closed || snapshot.localRemovedAt != null) return;
    final replica = await _replica(id);
    final events = await replica.journal.search(trimmed, limit: limit);
    for (final event in events) {
      if (event.kind == GroupEventKind.attachment) {
        final manifest = await fileForPeer(
          id,
          event.eventId,
          identity().deviceId,
        );
        if (manifest != null) onAttachment?.call(id, event, manifest);
        continue;
      }
      if (event.kind != GroupEventKind.message) continue;
      await _projectOriginal(id, replica, event);
    }
  }

  /// Give pre-journal outgoing text an authenticated event without inventing
  /// proofs for messages authored by another device. Re-running this is safe:
  /// [recordOutgoing] skips source messages already retained in the journal.
  Future<int> migrateLegacyOutgoing(
    GroupRecord snapshot,
    Iterable<ChatMessage> messages,
  ) async {
    var migrated = 0;
    for (final message in messages) {
      if (!message.outbound ||
          message.senderDeviceId != identity().deviceId ||
          message.body.trim().isEmpty ||
          message.attachment != null ||
          message.groupFile != null) {
        continue;
      }
      final before = await (await _replica(
        snapshot.groupId,
      )).journal.sourceMessage(message.senderDeviceId, message.id);
      await recordOutgoing(snapshot, message);
      if (before == null) migrated++;
    }
    return migrated;
  }

  GroupHistoryWire _wire(String id) => _wires.putIfAbsent(
    id,
    () => GroupHistoryWire(
      groupId: id,
      localExchange: () => _replica(id),
      send: (peer, payload) => send(id, peer, payload),
    ),
  );

  Future<void> mutateMessage(
    GroupRecord snapshot,
    ChatMessage message, {
    String? body,
    required bool delete,
  }) async {
    if (snapshot.localRemovedAt != null ||
        !snapshot.hasActiveMember(identity().deviceId) ||
        message.conversationId != snapshot.groupId ||
        message.senderDeviceId != identity().deviceId ||
        !message.outbound ||
        message.hasAttachment ||
        message.groupFile != null ||
        message.deleted) {
      throw StateError(
        'Only your own active group text messages can be changed.',
      );
    }
    if (!delete && (body == null || body.trim().isEmpty)) {
      throw ArgumentError('The edited message cannot be empty.');
    }
    // Only the original author may sign retained pre-upgrade outgoing text.
    await recordOutgoing(snapshot, message);
    await _write(snapshot.groupId, () async {
      final current = group(snapshot.groupId);
      if (current.localRemovedAt != null ||
          !current.hasActiveMember(identity().deviceId)) {
        throw StateError('You are no longer a member of this group.');
      }
      final replica = await _replica(snapshot.groupId);
      final original = await replica.journal.sourceMessage(
        message.senderDeviceId,
        message.id,
      );
      final membership = replica.membership.current;
      if (original == null || membership == null) {
        throw StateError('Waiting for signed group history.');
      }
      final projected = GroupMessageProjection.reduce(
        original,
        await replica.journal.messageMutations(original),
      );
      if (projected == null || projected.deleted) {
        throw StateError('This message has already been deleted.');
      }
      final mutation = await _sign(
        replica.journal,
        groupId: snapshot.groupId,
        membershipId: membership.id,
        kind: delete ? GroupEventKind.deletion : GroupEventKind.edit,
        payload: {
          'targetEventId': original.eventId,
          'changedAt': DateTime.now().toUtc().toIso8601String(),
          if (!delete) 'body': body!.trim(),
        },
      );
      await replica.importEvent(mutation, carrierDeviceId: identity().deviceId);
    });
    await projectPage(snapshot.groupId);
  }

  Future<void> toggleReaction(
    GroupRecord snapshot,
    ChatMessage message, {
    required String emoji,
  }) async {
    final trimmed = emoji.trim();
    if (trimmed.isEmpty || trimmed.length > 32) {
      throw ArgumentError('Invalid reaction.');
    }
    if (snapshot.localRemovedAt != null ||
        !snapshot.hasActiveMember(identity().deviceId) ||
        message.conversationId != snapshot.groupId ||
        message.groupFile != null ||
        message.attachment != null) {
      throw StateError('This group message cannot receive reactions.');
    }
    await recordOutgoing(snapshot, message);
    await _write(snapshot.groupId, () async {
      final current = group(snapshot.groupId);
      if (current.localRemovedAt != null ||
          !current.hasActiveMember(identity().deviceId)) {
        throw StateError('You are no longer a member of this group.');
      }
      final replica = await _replica(snapshot.groupId);
      final original = await replica.journal.sourceMessage(
        message.senderDeviceId,
        message.id,
      );
      final membership = replica.membership.current;
      if (original == null || membership == null) {
        throw StateError('Waiting for signed group history.');
      }
      final projection = GroupMessageProjection.reduce(
        original,
        await replica.journal.messageMutations(original),
      );
      final active =
          projection?.reactions[trimmed]?.contains(identity().deviceId) ??
          false;
      final reaction = await _sign(
        replica.journal,
        groupId: snapshot.groupId,
        membershipId: membership.id,
        kind: GroupEventKind.reaction,
        payload: {
          'targetEventId': original.eventId,
          'changedAt': DateTime.now().toUtc().toIso8601String(),
          'emoji': trimmed,
          'active': !active,
        },
      );
      await replica.importEvent(reaction, carrierDeviceId: identity().deviceId);
    });
    await projectPage(snapshot.groupId);
  }

  Future<void> announceChange(String id, String peer) =>
      send(id, peer, {'version': 1, 'groupId': id, 'type': 'changed'});

  Future<bool> handle(String id, String peer, Map<String, Object?> payload) {
    final snapshot = group(id);
    if (_closed ||
        snapshot.localRemovedAt != null ||
        !snapshot.hasActiveMember(identity().deviceId) ||
        !snapshot.hasActiveMember(peer)) {
      return Future.value(false);
    }
    return _wire(id).handle(peer, payload);
  }

  Future<int> synchronize(String id, String peer) {
    final key = jsonEncode([id, peer]);
    return _pulls.putIfAbsent(key, () {
      final result = () async {
        final snapshot = group(id);
        if (snapshot.localRemovedAt != null ||
            !snapshot.hasActiveMember(identity().deviceId) ||
            !snapshot.hasActiveMember(peer)) {
          throw StateError('Group history is not available to this peer.');
        }
        await prepareMembership(snapshot);
        final replica = await _replica(id);
        final count = await replica.pullFrom(
          _wire(id).remote(peer),
          carrierDeviceId: peer,
        );
        // Bounded initial projection; older pages are exposed separately below.
        await projectPage(id);
        // A mutation can precede the newest page in a large catch-up. Refresh
        // messages already materialized in the vault without loading all older
        // text history. Each lookup is handled by the journal worker's indexes.
        for (final message in retainedMessages(id).toList()) {
          if (_closed || group(id).localRemovedAt != null) break;
          if (message.deleted) continue;
          var original = await replica.journal.sourceMessage(
            message.senderDeviceId,
            message.id,
          );
          // A legacy ID collision is projected under the signed event digest.
          if (original == null &&
              RegExp(r'^[0-9a-f]{64}$').hasMatch(message.id)) {
            final events = await replica.journal.readEvents([message.id]);
            if (events.isNotEmpty &&
                events.single.authorDeviceId == message.senderDeviceId) {
              original = events.single;
            }
          }
          if (original != null) {
            await _projectOriginal(
              id,
              replica,
              original,
              requireMutation: true,
            );
          }
        }
        return count;
      }();
      unawaited(
        result.then<void>(
          (_) {
            if (identical(_pulls[key], result)) _pulls.remove(key);
          },
          onError: (Object _, StackTrace _) {
            if (identical(_pulls[key], result)) _pulls.remove(key);
          },
        ),
      );
      return result;
    });
  }

  Future<String?> projectPage(String id, {String? beforeEventId}) async {
    if (_closed || group(id).localRemovedAt != null) return null;
    final replica = await _replica(id);
    final page = await replica.journal.readPage(beforeEventId: beforeEventId);
    final projected = <String>{};
    for (final event in page.reversed) {
      if (event.kind == GroupEventKind.attachment) {
        final manifest = await fileForPeer(
          id,
          event.eventId,
          identity().deviceId,
        );
        if (manifest != null) onAttachment?.call(id, event, manifest);
        continue;
      }
      GroupHistoryEvent? original;
      if (event.kind == GroupEventKind.message) {
        original = event;
      } else if (GroupMessageProjection.isMutation(event)) {
        final targets = await replica.journal.readEvents([
          event.payload['targetEventId'] as String,
        ]);
        if (targets.isNotEmpty) original = targets.single;
      }
      if (original == null || !projected.add(original.eventId)) continue;
      await _projectOriginal(id, replica, original);
    }
    return page.isEmpty ? null : page.last.eventId;
  }

  Future<void> _projectOriginal(
    String id,
    GroupHistoryReplica replica,
    GroupHistoryEvent original, {
    bool requireMutation = false,
  }) async {
    final mutations = await replica.journal.messageMutations(original);
    if (requireMutation && mutations.isEmpty) return;
    if (!await replica.membership.canReceive(
      original,
      recipientDeviceId: identity().deviceId,
    )) {
      return;
    }
    final permitted = <GroupHistoryEvent>[];
    for (final mutation in mutations) {
      if (await replica.membership.canReceive(
        mutation,
        recipientDeviceId: identity().deviceId,
      )) {
        permitted.add(mutation);
      }
    }
    // Recheck local removal after asynchronous journal/authorization reads.
    if (_closed || group(id).localRemovedAt != null) return;
    final projection = GroupMessageProjection.reduce(original, permitted);
    if (projection != null) {
      onMessage(id, projection);
    }
  }

  Future<void> close() async {
    _closed = true;
    for (final wire in _wires.values) {
      wire.close();
    }
    await Future.wait(_writes.values);
    await vault.closeGroupHistory();
  }

  void onConnectivityChanged() {
    // Requests accepted by the old transport may never receive a response.
    // Resume from durable cursors using fresh correlation IDs and connections.
    for (final wire in _wires.values) {
      wire.close();
    }
    _wires.clear();
    _pulls.clear();
  }
}
