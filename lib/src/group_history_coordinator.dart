import 'dart:async';
import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import 'group_history_event.dart';
import 'group_history_journal.dart';
import 'group_history_sync.dart';
import 'group_history_wire.dart';
import 'group_membership_history.dart';
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
  final void Function(String groupId, GroupHistoryEvent event) onMessage;
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

  Future<GroupHistoryEvent?> prepareMembership(GroupRecord snapshot) => _write(
    snapshot.groupId,
    () async {
      final replica = await _replica(snapshot.groupId);
      final history = replica.membership;
      final current = history.current;
      final me = identity();
      if (history.hasConflict) {
        throw StateError('Group membership conflict needs owner resolution.');
      }
      if (current != null &&
          current.group.membershipVersion == snapshot.membershipVersion) {
        return current.proof;
      }
      if (current == null && snapshot.ownerDeviceId != me.deviceId) return null;
      final parents = history.heads;
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
              current?.historyVisibility ?? GroupHistoryVisibility.allRetained,
          admissions: {
            for (final device in snapshot.activeMemberDeviceIds)
              device: current?.admissions[device],
          },
        ),
      );
      await replica.importMembership(proof);
      return proof;
    },
  );

  Future<void> importMembership(String id, String encoded) =>
      _write(id, () async {
        final proof = GroupHistoryEvent.decode(encoded);
        final replica = await _replica(id);
        if (await replica.importMembership(proof) ==
            GroupMembershipImport.missingParents) {
          throw StateError('Group history needs earlier membership records.');
        }
      });

  Future<void> recordOutgoing(GroupRecord snapshot, ChatMessage message) async {
    await prepareMembership(snapshot);
    await _write(snapshot.groupId, () async {
      final replica = await _replica(snapshot.groupId);
      final membership = replica.membership.current;
      if (membership == null) {
        throw StateError('Waiting for the owner’s signed membership history.');
      }
      if (await replica.journal.sourceMessage(
            message.senderDeviceId,
            message.id,
          ) !=
          null) {
        return;
      }
      if (!message.outbound ||
          message.senderDeviceId != identity().deviceId ||
          message.attachment != null) {
        return;
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
    });
  }

  GroupHistoryWire _wire(String id) => _wires.putIfAbsent(
    id,
    () => GroupHistoryWire(
      groupId: id,
      localExchange: () => _replica(id),
      send: (peer, payload) => send(id, peer, payload),
    ),
  );

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
        return count;
      }();
      unawaited(
        result.then<void>(
          (_) {
            _pulls.remove(key);
          },
          onError: (Object _, StackTrace _) {
            _pulls.remove(key);
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
    for (final event in page.reversed) {
      if (event.kind == GroupEventKind.message &&
          await replica.membership.canReceive(
            event,
            recipientDeviceId: identity().deviceId,
          )) {
        onMessage(id, event);
      }
    }
    return page.isEmpty ? null : page.last.eventId;
  }

  Future<void> close() async {
    _closed = true;
    for (final wire in _wires.values) {
      wire.close();
    }
    await Future.wait(_writes.values);
    await vault.closeGroupHistory();
  }
}
