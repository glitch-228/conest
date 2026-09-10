import 'dart:convert';

import 'package:crypto/crypto.dart' as hashes;

import 'group_history_event.dart';
import 'models.dart';

enum GroupHistoryVisibility { allRetained, sinceAdmission }

enum GroupMembershipImport { accepted, duplicate, missingParents }

class GroupHistoryCheckpoint {
  const GroupHistoryCheckpoint({required this.sequence, required this.eventId});

  final int sequence;
  final String eventId;

  Map<String, Object?> toJson() => {'sequence': sequence, 'eventId': eventId};
}

/// Owner/admin-signed membership evidence carried beside historical events.
/// Its enclosing event uses the first parent as its membership reference, or
/// [rootReference] for a root explicitly anchored by the approved group owner.
class GroupMembershipRecord {
  GroupMembershipRecord._(
    this.proof,
    this.parents,
    this.historyVisibility,
    this.admissions,
    this.checkpoints,
  );

  final GroupHistoryEvent proof;
  final List<String> parents;
  final GroupHistoryVisibility historyVisibility;

  /// Resolved admission record IDs. Null wire references mean this record.
  final Map<String, String> admissions;
  final Map<String, GroupHistoryCheckpoint> checkpoints;
  String get id => proof.eventId;

  // Return a fresh snapshot: GroupRecord currently owns mutable lists. The
  // signed event's deeply immutable payload remains the authority.
  GroupRecord get group => GroupRecord.fromJson(
    Map<String, dynamic>.from(proof.payload['group'] as Map),
  );

  static String rootReference(String groupId, String ownerSigningKey) => hashes
      .sha256
      .convert(
        utf8.encode(
          jsonEncode([
            'conest.group-membership-root.v1',
            groupId,
            ownerSigningKey,
          ]),
        ),
      )
      .toString();

  static Map<String, Object?> payload({
    required GroupRecord group,
    required List<String> parents,
    required GroupHistoryVisibility historyVisibility,
    required Map<String, String?> admissions,
    Map<String, GroupHistoryCheckpoint> checkpoints = const {},
  }) {
    final snapshot = group.toJson()..remove('localRemovedAt');
    return {
      'group': snapshot,
      'parents': List<String>.of(parents)..sort(),
      'historyVisibility': historyVisibility.name,
      'admissions': admissions,
      'checkpoints': {
        for (final entry in checkpoints.entries)
          entry.key: entry.value.toJson(),
      },
    };
  }

  factory GroupMembershipRecord.fromEvent(GroupHistoryEvent proof) {
    if (proof.kind != GroupEventKind.membership) {
      throw const FormatException('Expected a signed membership event.');
    }
    try {
      final data = proof.payload;
      final parents = (data['parents'] as List).cast<String>();
      final rawAdmissions = (data['admissions'] as Map).cast<String, String?>();
      final checkpoints = <String, GroupHistoryCheckpoint>{};
      for (final entry in (data['checkpoints'] as Map).entries) {
        final value = entry.value as Map;
        final sequence = value['sequence'] as int;
        final id = value['eventId'] as String;
        if (sequence < 1 || sequence > groupEventMaxCounter || !_digest(id)) {
          throw const FormatException('Invalid admission checkpoint.');
        }
        checkpoints[entry.key as String] = GroupHistoryCheckpoint(
          sequence: sequence,
          eventId: id,
        );
      }
      final record = GroupMembershipRecord._(
        proof,
        List.unmodifiable(parents),
        GroupHistoryVisibility.values.byName(
          data['historyVisibility'] as String,
        ),
        Map.unmodifiable({
          for (final entry in rawAdmissions.entries)
            entry.key: entry.value ?? proof.eventId,
        }),
        Map.unmodifiable(checkpoints),
      );
      final group = record.group;
      final active = group.activeMemberDeviceIds.toSet();
      if (data.length != 5 ||
          parents.length > 16 ||
          parents.toSet().length != parents.length ||
          !parents.every(_digest) ||
          checkpoints.length > 256 ||
          group.groupId != proof.groupId ||
          group.membershipVersion < 1 ||
          group.activeMemberDeviceIds.length > 16 ||
          group.memberProfiles.length > 256 ||
          group.localRemovedAt != null ||
          record.admissions.length != active.length ||
          !active.every(record.admissions.containsKey) ||
          !record.admissions.values.every(_digest)) {
        throw const FormatException('Invalid membership snapshot.');
      }
      for (final device in active) {
        final member = group.memberProfileFor(device);
        if (member == null ||
            member.signingPublicKeyBase64 == null ||
            base64Decode(member.signingPublicKeyBase64!).length != 32 ||
            base64Decode(member.publicKeyBase64).length != 32 ||
            member.irohEndpointId !=
                base64Decode(member.signingPublicKeyBase64!)
                    .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
                    .join()) {
          throw const FormatException(
            'Membership requires pinned signing and transport identities.',
          );
        }
      }
      return record;
    } on TypeError {
      throw const FormatException('Invalid membership fields.');
    } on ArgumentError {
      throw const FormatException('Invalid membership fields.');
    }
  }
}

/// Authenticated membership DAG. Missing dependencies are retriable; competing
/// heads freeze history serving until the owner of their common ancestor signs
/// a resolution. An ordinary carrier cannot grant itself membership.
///
/// Persist proofs in the journal before advertising them as durable. Rebuild
/// this index by importing retained proofs in dependency order on restart.
class GroupMembershipHistory {
  GroupMembershipHistory({required this.groupId, required this.trustedOwner});

  final String groupId;
  final GroupMemberProfile trustedOwner;
  final _records = <String, GroupMembershipRecord>{};
  final _heads = <String>{};
  final _identities = <String, GroupMemberProfile>{};
  Future<void> _tail = Future.value();

  bool get hasConflict => _heads.length > 1;
  List<String> get heads => _heads.toList()..sort();
  GroupMembershipRecord? get current =>
      _heads.length == 1 ? _records[_heads.single] : null;
  GroupMembershipRecord? record(String id) => _records[id];

  Future<GroupMembershipImport> import(GroupMembershipRecord record) {
    final result = _tail.then((_) => _import(record));
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<GroupMembershipImport> _import(GroupMembershipRecord incoming) async {
    if (incoming.proof.groupId != groupId) {
      throw const FormatException('Membership belongs to another group.');
    }
    if (_records.containsKey(incoming.id)) {
      return GroupMembershipImport.duplicate;
    }
    final group = incoming.group;
    if (incoming.parents.any((id) => !_records.containsKey(id))) {
      return GroupMembershipImport.missingParents;
    }
    final parents = incoming.parents.map((id) => _records[id]!).toList();
    GroupMemberProfile? actor;
    if (parents.isEmpty) {
      if (_records.isNotEmpty ||
          group.ownerDeviceId != trustedOwner.deviceId ||
          group.isDissolved ||
          incoming.proof.membershipId !=
              GroupMembershipRecord.rootReference(
                groupId,
                trustedOwner.signingPublicKeyBase64 ?? '',
              )) {
        throw const FormatException(
          'Membership root is not anchored to the approved owner.',
        );
      }
      actor = trustedOwner;
    } else {
      if (incoming.proof.membershipId != incoming.parents.first ||
          parents.any((parent) => parent.group.isDissolved) ||
          group.membershipVersion !=
              parents
                      .map((parent) => parent.group.membershipVersion)
                      .reduce((a, b) => a > b ? a : b) +
                  1) {
        throw const FormatException('Invalid membership parent/version.');
      }
      final authority = parents.length == 1
          ? parents.single
          : _resolutionAuthority(parents);
      actor = authority.group.memberProfileFor(incoming.proof.authorDeviceId);
      final ownerAction =
          incoming.proof.authorDeviceId == authority.group.ownerDeviceId;
      if (parents.length > 1 && !ownerAction) {
        throw const FormatException(
          'Conflicting membership requires an owner-signed resolution.',
        );
      }
      if (!ownerAction && !_adminUpdateAllowed(authority, incoming)) {
        throw const FormatException('Unauthorized membership change.');
      }
      if (group.ownerDeviceId != authority.group.ownerDeviceId &&
          !parents.any(
            (parent) => parent.group.hasActiveMember(group.ownerDeviceId),
          )) {
        throw const FormatException(
          'Ownership may only pass to an existing member.',
        );
      }
      // A resolution must merge genuinely competing branches, not list an
      // ancestor next to its descendant to circumvent normal admin rules.
      for (final parent in parents) {
        if (parents.any(
          (other) => other.id != parent.id && _isAncestor(parent.id, other.id),
        )) {
          throw const FormatException(
            'Redundant membership resolution parent.',
          );
        }
      }
    }
    if (actor == null ||
        actor.signingPublicKeyBase64 == null ||
        !await incoming.proof.verify(
          expectedGroupId: groupId,
          expectedAccountId: actor.accountId,
          expectedDeviceId: actor.deviceId,
          expectedSigningKeyBase64: actor.signingPublicKeyBase64!,
        )) {
      throw const FormatException('Invalid membership author signature.');
    }
    for (final device in group.activeMemberDeviceIds) {
      final profile = group.memberProfileFor(device)!;
      final pinned = device == trustedOwner.deviceId
          ? trustedOwner
          : _identities[device];
      if (pinned != null && !_sameIdentity(pinned, profile)) {
        throw const FormatException(
          'Membership cannot replace a pinned identity.',
        );
      }
      final priorAdmissions = parents
          .map((parent) => parent.admissions[device])
          .toSet();
      final continuouslyAdmitted =
          parents.isNotEmpty &&
          !priorAdmissions.contains(null) &&
          priorAdmissions.length == 1;
      final expectedAdmission = continuouslyAdmitted
          ? priorAdmissions.single
          : incoming.id;
      if (incoming.admissions[device] != expectedAdmission) {
        throw const FormatException(
          'An admission boundary cannot change for an existing member.',
        );
      }
    }
    _records[incoming.id] = incoming;
    _heads.removeAll(incoming.parents);
    _heads.add(incoming.id);
    for (final device in group.activeMemberDeviceIds) {
      _identities[device] = group.memberProfileFor(device)!;
    }
    return GroupMembershipImport.accepted;
  }

  bool _adminUpdateAllowed(
    GroupMembershipRecord before,
    GroupMembershipRecord after,
  ) {
    final previous = before.group;
    final next = after.group;
    if (previous.roleFor(after.proof.authorDeviceId) != GroupMemberRole.admin ||
        next.ownerDeviceId != previous.ownerDeviceId ||
        next.title != previous.title ||
        next.isDissolved ||
        after.historyVisibility != before.historyVisibility) {
      return false;
    }
    for (final device in previous.activeMemberDeviceIds) {
      if (!next.hasActiveMember(device)) {
        if (!previous.canRemoveMember(
          actorDeviceId: after.proof.authorDeviceId,
          memberDeviceId: device,
        )) {
          return false;
        }
      } else if (previous.roleFor(device) != next.roleFor(device)) {
        return false;
      }
    }
    return next.activeMemberDeviceIds.every(
      (device) =>
          previous.hasActiveMember(device) ||
          next.roleFor(device) == GroupMemberRole.member,
    );
  }

  GroupMembershipRecord _resolutionAuthority(
    List<GroupMembershipRecord> parents,
  ) {
    var common = _ancestors(parents.first.id);
    for (final parent in parents.skip(1)) {
      common = common.intersection(_ancestors(parent.id));
    }
    final newest = common
        .where(
          (id) => !common.any((other) => other != id && _isAncestor(id, other)),
        )
        .toList();
    if (newest.length != 1) {
      throw const FormatException('Ambiguous membership resolution authority.');
    }
    return _records[newest.single]!;
  }

  Set<String> _ancestors(String id) {
    final result = <String>{};
    final pending = [id];
    while (pending.isNotEmpty) {
      final next = pending.removeLast();
      if (result.add(next)) pending.addAll(_records[next]?.parents ?? const []);
    }
    return result;
  }

  bool _isAncestor(String ancestor, String descendant) =>
      _ancestors(descendant).contains(ancestor);

  /// Current membership gates the recipient; the referenced historical record
  /// gates the original author. This permits legitimate older membership epochs
  /// without letting removed recipients request further history. Payload rules
  /// such as edit ownership and receipt recipients belong to the projection
  /// layer; this check establishes membership and authorship only.
  Future<bool> canReceive(
    GroupHistoryEvent event, {
    required String recipientDeviceId,
  }) async {
    final head = current;
    final membership = _records[event.membershipId];
    if (head == null ||
        membership == null ||
        event.kind == GroupEventKind.membership ||
        !head.group.hasActiveMember(recipientDeviceId) ||
        !_isAncestor(membership.id, head.id) ||
        !membership.group.hasActiveMember(event.authorDeviceId)) {
      return false;
    }
    final author = membership.group.memberProfileFor(event.authorDeviceId)!;
    final admission = _records[head.admissions[recipientDeviceId]];
    if (admission == null) return false;
    if (admission.historyVisibility == GroupHistoryVisibility.sinceAdmission) {
      if (!_isAncestor(admission.id, membership.id) ||
          event.sequence <=
              (admission.checkpoints[event.authorDeviceId]?.sequence ?? 0)) {
        return false;
      }
    }
    final verified = await event.verify(
      expectedGroupId: groupId,
      expectedAccountId: author.accountId,
      expectedDeviceId: author.deviceId,
      expectedSigningKeyBase64: author.signingPublicKeyBase64!,
    );
    // A removal or conflict may arrive while signature verification yields.
    return verified && current?.id == head.id;
  }

  /// A carrier needs current group authorization too. This permission never
  /// authorizes a private conversation with either endpoint.
  Future<bool> canForward(
    GroupHistoryEvent event, {
    required String carrierDeviceId,
    required String recipientDeviceId,
  }) async {
    final head = current;
    return head?.group.hasActiveMember(carrierDeviceId) == true &&
        await canReceive(event, recipientDeviceId: carrierDeviceId) &&
        await canReceive(event, recipientDeviceId: recipientDeviceId) &&
        current?.id == head!.id;
  }
}

bool _sameIdentity(GroupMemberProfile a, GroupMemberProfile b) =>
    a.accountId == b.accountId &&
    a.deviceId == b.deviceId &&
    a.publicKeyBase64 == b.publicKeyBase64 &&
    a.signingPublicKeyBase64 == b.signingPublicKeyBase64 &&
    a.irohEndpointId == b.irohEndpointId;

bool _digest(String value) => RegExp(r'^[0-9a-f]{64}$').hasMatch(value);
