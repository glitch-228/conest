import 'dart:convert';

import 'package:crypto/crypto.dart' as hashes;

import 'account/account_model.dart';
import 'group_account_member.dart';
import 'group_accounts.dart';
import 'group_history_event.dart';
import 'models.dart';

enum GroupHistoryVisibility { allRetained, sinceAdmission }

/// [missingDeviceLists]: the record pins a device list this device does not
/// have yet. Retriable like [missingParents]; never a refusal.
enum GroupMembershipImport {
  accepted,
  duplicate,
  missingParents,
  missingDeviceLists,
}

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

  /// The record that admitted [entry]'s account.
  String accountAdmission(GroupAccountMember entry) => entry.admission ?? id;

  // Return a fresh snapshot: GroupRecord currently owns mutable lists. The
  // signed event's deeply immutable payload remains the authority.
  GroupRecord get group => GroupRecord.fromJson(
    Map<String, dynamic>.from(proof.payload['group'] as Map)
      ..remove('mirroredVia'),
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
    final snapshot = group.toJson()
      ..remove('localRemovedAt')
      ..remove('mirroredVia');
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
      final rawGroup = data['group'] as Map;
      final rawAccounts = rawGroup['memberAccounts'];
      final rawConfirm = rawGroup['confirmNewDevices'];
      if (GroupAccountMember.tryParseAll(rawAccounts) == null ||
          (rawAccounts is List ? rawAccounts.length : 0) !=
              group.memberAccounts.length ||
          (rawConfirm != null && rawConfirm is! bool)) {
        throw const FormatException('Invalid account members.');
      }
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
  GroupMembershipHistory({
    required this.groupId,
    required this.trustedOwner,
    PinnedListStore? lists,
    this.view,
    this.chainAdmits,
  }) : lists = lists ?? PinnedListStore();

  final String groupId;
  final GroupMemberProfile trustedOwner;

  /// Device lists by digest. Shared with every fork and (per account) with
  /// the other groups of this device.
  final PinnedListStore lists;

  /// The device lists seen so far. Used only to decide message events; a
  /// membership record is never accepted or refused because of it.
  final DeviceListView? view;

  /// Whether [event], by an author whose events end at [cutoff], is on the
  /// author's `previousEventId` chain below the cutoff event (a revoked
  /// author's backdated fill-ins must not count). Null means unknown, which
  /// fails closed for such authors.
  final Future<bool> Function(
    GroupHistoryEvent event,
    GroupHistoryCheckpoint cutoff,
  )?
  chainAdmits;
  final _records = <String, GroupMembershipRecord>{};
  final _heads = <String>{};
  // What each record's ancestry says about accounts and identities. A pure
  // function of the record and its ancestors, so acceptance never depends on
  // the order records arrived in.
  final _facts = <String, _Facts>{};
  final _groups = <String, GroupRecord>{};
  // A record's parents must be imported before it and never change, so its
  // ancestor set and departures are fixed once computed. canReceive runs per
  // history event, so these avoid re-walking the DAG and re-decoding groups.
  final _ancestorCache = <String, Set<String>>{};
  final _departureCache = <String, Map<String, List<String>>>{};
  final _activeCache = <String, Set<String>>{};
  final _departureCheckpointCache = <String, GroupHistoryCheckpoint?>{};
  Future<void> _tail = Future.value();

  bool get hasConflict => _heads.length > 1;
  List<String> get heads => _heads.toList()..sort();
  GroupMembershipRecord? get current =>
      _heads.length == 1 ? _records[_heads.single] : null;
  GroupMembershipRecord? record(String id) => _records[id];

  /// The decoded group of a record, cached (a record never changes).
  GroupRecord groupOf(GroupMembershipRecord record) =>
      _groups[record.id] ?? record.group;

  /// What the ancestry of [recordId] says about the account with key
  /// [accountKeyBase64]: the lists pinned by that record or any ancestor.
  AccountFacts accountFacts(String recordId, String accountKeyBase64) =>
      _facts[recordId]?.accounts[accountKeyBase64] ?? AccountFacts.empty;

  /// Digests [record] pins that the list store does not hold yet.
  List<String> missingListDigests(GroupMembershipRecord record) => [
    for (final entry in record.group.memberAccounts)
      if (lists.get(entry.listDigest) == null) entry.listDigest,
  ];

  /// Whether [deviceId] takes part in the current membership: a member
  /// device of the head, or an effective sibling of a member account.
  bool isActiveOrSibling(String deviceId) {
    final head = current;
    return head != null && _mayReceive(groupOf(head), deviceId);
  }

  /// Whether [deviceId] is active in every head (during a fork).
  bool activeInEveryHead(String deviceId) =>
      _heads.isNotEmpty &&
      _heads.every((id) => _mayReceive(groupOf(_records[id]!), deviceId));

  /// A candidate index can be validated before its proof is flushed, then
  /// published only after the journal append succeeds.
  GroupMembershipHistory fork() {
    final copy = GroupMembershipHistory(
      groupId: groupId,
      trustedOwner: trustedOwner,
      lists: lists,
      view: view,
      chainAdmits: chainAdmits,
    );
    copy._records.addAll(_records);
    copy._heads.addAll(_heads);
    copy._facts.addAll(_facts);
    copy._groups.addAll(_groups);
    return copy;
  }

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
    // Unknown is retriable, never a refusal: the record pins lists by digest
    // and its meaning is fixed once they are here.
    if (group.memberAccounts.any(
      (entry) => lists.get(entry.listDigest) == null,
    )) {
      return GroupMembershipImport.missingDeviceLists;
    }
    final parents = incoming.parents.map((id) => _records[id]!).toList();
    final parentGroups = [for (final parent in parents) groupOf(parent)];
    final facts = _factsFor(group, parents);
    GroupMemberProfile? actor;
    GroupMembershipRecord? authority;
    GroupRecord? authorityGroup;
    var ownerAction = false;
    var exempt = false;
    if (parents.isEmpty) {
      if (_records.isNotEmpty ||
          group.ownerDeviceId != trustedOwner.deviceId ||
          group.isDissolved ||
          group.memberAccounts.isNotEmpty ||
          group.confirmNewDevices ||
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
          parents.any(
            (parent) => parent.proof.lamport >= incoming.proof.lamport,
          ) ||
          parentGroups.any((parent) => parent.isDissolved) ||
          group.membershipVersion !=
              parentGroups
                      .map((parent) => parent.membershipVersion)
                      .reduce((a, b) => a > b ? a : b) +
                  1) {
        throw const FormatException('Invalid membership parent/version.');
      }
      authority = parents.length == 1
          ? parents.single
          : _resolutionAuthority(parents);
      authorityGroup = groupOf(authority);
      actor = authorityGroup.memberProfileFor(incoming.proof.authorDeviceId);
      // A device revoked by any list pinned in the incoming record's whole
      // ancestry cannot sign, even when the authority record still projects
      // it (a thief owner's resolution must not hand ownership on).
      if (actor != null && _isRevokedAuthor(authorityGroup, actor, facts)) {
        throw const FormatException('Membership author is revoked.');
      }
      ownerAction =
          incoming.proof.authorDeviceId == authorityGroup.ownerDeviceId;
      final handoff =
          !ownerAction &&
          actor != null &&
          _ownerHandoff(parents, authority, incoming, group, actor, facts);
      if (parents.length > 1 && !ownerAction && !handoff) {
        throw const FormatException(
          'Conflicting membership requires an owner-signed resolution.',
        );
      }
      final selfRevocation =
          !ownerAction &&
          !handoff &&
          actor != null &&
          _selfRevocation(authority, incoming, group, actor, facts);
      exempt = handoff || selfRevocation;
      if (!ownerAction &&
          !exempt &&
          !_adminUpdateAllowed(authority, incoming)) {
        throw const FormatException('Unauthorized membership change.');
      }
      if (group.ownerDeviceId != authorityGroup.ownerDeviceId &&
          !parentGroups.any(
            (parent) => parent.hasActiveMember(group.ownerDeviceId),
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
    if (actor == null || actor.signingPublicKeyBase64 == null) {
      throw const FormatException('Invalid membership author signature.');
    }
    // Everything below up to the signature is pure given the record, its
    // ancestors and the lists their digests name.
    await _verifyPinnedLists(group);
    if (authority != null) {
      await _checkAccounts(
        incoming: incoming,
        next: group,
        parents: parents,
        parentGroups: parentGroups,
        prev: authorityGroup!,
        authority: authority,
        ownerAction: ownerAction,
        exempt: exempt,
        facts: facts,
      );
    }
    final identities = _checkIdentities(group, facts);
    if (!await incoming.proof.verify(
      expectedGroupId: groupId,
      expectedAccountId: actor.accountId,
      expectedDeviceId: actor.deviceId,
      expectedSigningKeyBase64: actor.signingPublicKeyBase64!,
    )) {
      throw const FormatException('Invalid membership author signature.');
    }
    for (final device in group.activeMemberDeviceIds) {
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
    for (final entry in group.memberAccounts) {
      lists.markPinned(entry.listDigest);
    }
    _records[incoming.id] = incoming;
    _groups[incoming.id] = group;
    _facts[incoming.id] = facts.withIdentities(identities);
    _heads.removeAll(incoming.parents);
    _heads.add(incoming.id);
    return GroupMembershipImport.accepted;
  }

  // ---- Accounts (M29): pure checks on a record ------------------------

  /// What the incoming record's ancestry says: the union of its parents'
  /// facts, plus the lists the record itself pins.
  _Facts _factsFor(GroupRecord group, List<GroupMembershipRecord> parents) {
    var accounts = const <String, AccountFacts>{};
    var identities = const <String, _Ident>{};
    var banned = const <String>{};
    for (final parent in parents) {
      final theirs = _facts[parent.id];
      if (theirs == null) continue;
      if (accounts.isEmpty) {
        accounts = theirs.accounts;
      } else if (!identical(accounts, theirs.accounts)) {
        final merged = Map<String, AccountFacts>.of(accounts);
        for (final entry in theirs.accounts.entries) {
          merged[entry.key] =
              merged[entry.key]?.merge(entry.value) ?? entry.value;
        }
        accounts = merged;
      }
      if (identities.isEmpty) {
        identities = theirs.identities;
      } else if (!identical(identities, theirs.identities)) {
        identities = {...identities, ...theirs.identities};
      }
    }
    // A key is banned from re-entering once its ancestry shows a fork.
    banned = {
      for (final entry in accounts.entries)
        if (entry.value.compromised) entry.key,
    };
    if (group.memberAccounts.isNotEmpty) {
      final merged = Map<String, AccountFacts>.of(accounts);
      for (final entry in group.memberAccounts) {
        final list = lists.get(entry.listDigest)!;
        merged[entry.accountKeyBase64] =
            (merged[entry.accountKeyBase64] ?? AccountFacts.empty).withList(
              list,
            );
      }
      accounts = merged;
    }
    return _Facts(accounts, identities, banned);
  }

  Set<String> _revokedOf(_Facts facts, GroupAccountMember entry) =>
      facts.accounts[entry.accountKeyBase64]?.revoked ?? const <String>{};

  bool _isRevokedAuthor(
    GroupRecord authority,
    GroupMemberProfile actor,
    _Facts facts,
  ) {
    for (final entry in authority.memberAccounts) {
      if (entry.accountId == actor.accountId &&
          _revokedOf(facts, entry).contains(actor.deviceId)) {
        return true;
      }
    }
    return false;
  }

  bool _capable(GroupRecord group, String deviceId) =>
      group
          .memberProfileFor(deviceId)
          ?.featureCapabilities
          .contains(ApplicationCapability.groupAccountsV1) ==
      true;

  bool _allCapable(GroupRecord group) =>
      group.activeMemberDeviceIds.every((device) => _capable(group, device));

  Future<void> _verifyPinnedLists(GroupRecord group) async {
    for (final entry in group.memberAccounts) {
      final list = lists.get(entry.listDigest)!;
      if (list.accountId != entry.accountId ||
          list.version != entry.listVersion) {
        throw const FormatException('Pinned device list does not match.');
      }
      if (!lists.isVerified(entry.listDigest, entry.accountKeyBase64)) {
        if (!await list.verify(entry.accountKeyBase64)) {
          throw const FormatException('Invalid pinned device list.');
        }
        lists.markVerified(entry.listDigest, entry.accountKeyBase64);
      }
    }
  }

  GroupMemberRole _roleOfEntry(GroupAccountMember entry, bool isOwnerDevice) =>
      switch (entry.role) {
        GroupAccountRole.owner =>
          isOwnerDevice ? GroupMemberRole.owner : GroupMemberRole.admin,
        GroupAccountRole.admin => GroupMemberRole.admin,
        GroupAccountRole.moderator => GroupMemberRole.moderator,
        GroupAccountRole.member => GroupMemberRole.member,
      };

  static GroupAccountRole _entryRoleFor(GroupMemberRole role) => switch (role) {
    GroupMemberRole.owner => GroupAccountRole.owner,
    GroupMemberRole.admin => GroupAccountRole.admin,
    GroupMemberRole.moderator => GroupAccountRole.moderator,
    GroupMemberRole.member => GroupAccountRole.member,
  };

  bool _sameEntry(GroupAccountMember a, GroupAccountMember b) =>
      canonicalGroupJson(a.toJson()) == canonicalGroupJson(b.toJson());

  /// The new owner takes over from an owner device its account revoked
  /// (O1). Evidence is in the DAG: a pinned list of the owner's account
  /// revokes the old owner device; the author is the smallest projected
  /// admin device of that account that is not revoked; every member knows
  /// accounts (an older validator would reject a non-owner ownership change,
  /// so with any older member this is simply not allowed).
  bool _ownerHandoff(
    List<GroupMembershipRecord> parents,
    GroupMembershipRecord authority,
    GroupMembershipRecord incoming,
    GroupRecord next,
    GroupMemberProfile actor,
    _Facts facts,
  ) {
    final prev = groupOf(authority);
    if (next.ownerDeviceId == prev.ownerDeviceId ||
        next.ownerDeviceId != actor.deviceId ||
        !_allCapable(prev)) {
      return false;
    }
    final ownerEntry = prev.memberAccounts
        .where((entry) => entry.role == GroupAccountRole.owner)
        .firstOrNull;
    if (ownerEntry == null || ownerEntry.accountId != actor.accountId) {
      return false;
    }
    final nextEntry = next.memberAccounts
        .where((entry) => entry.accountId == ownerEntry.accountId)
        .firstOrNull;
    if (nextEntry == null ||
        nextEntry.accountKeyBase64 != ownerEntry.accountKeyBase64) {
      return false;
    }
    final revoked = _revokedOf(facts, ownerEntry);
    if (!revoked.contains(prev.ownerDeviceId)) return false;
    final eligible =
        prev.activeMemberDeviceIds
            .where(
              (device) =>
                  device != prev.ownerDeviceId &&
                  prev.memberProfileFor(device)?.accountId ==
                      ownerEntry.accountId &&
                  prev.roleFor(device) == GroupMemberRole.admin &&
                  !revoked.contains(device) &&
                  !ownerEntry.excludedDeviceIds.contains(device),
            )
            .toList()
          ..sort();
    if (eligible.isEmpty || eligible.first != actor.deviceId) return false;
    for (final parent in parents) {
      final theirs = groupOf(parent).memberAccounts
          .where((entry) => entry.accountId == ownerEntry.accountId)
          .firstOrNull;
      if (theirs != null && theirs.listVersion > nextEntry.listVersion) {
        return false;
      }
    }
    // Nothing else may change.
    if (next.title != prev.title ||
        next.isDissolved ||
        next.confirmNewDevices != prev.confirmNewDevices ||
        incoming.historyVisibility != authority.historyVisibility ||
        next.memberAccounts.length != prev.memberAccounts.length) {
      return false;
    }
    for (final entry in prev.memberAccounts) {
      final theirs = next.memberAccounts
          .where((candidate) => candidate.accountId == entry.accountId)
          .firstOrNull;
      if (theirs == null) return false;
      if (entry.accountId == ownerEntry.accountId) {
        if (theirs.role != entry.role ||
            theirs.admission != entry.admission ||
            canonicalGroupJson(theirs.approvedDeviceIds) !=
                canonicalGroupJson(entry.approvedDeviceIds) ||
            canonicalGroupJson(theirs.excludedDeviceIds) !=
                canonicalGroupJson(entry.excludedDeviceIds)) {
          return false;
        }
      } else if (!_sameEntry(entry, theirs)) {
        return false;
      }
    }
    final before = prev.activeMemberDeviceIds.toSet();
    final after = next.activeMemberDeviceIds.toSet();
    final removed = before.difference(after);
    if (!after.every(before.contains) ||
        !removed.contains(prev.ownerDeviceId) ||
        !removed.every(revoked.contains)) {
      return false;
    }
    final admins = {...prev.adminDeviceIds}
      ..remove(actor.deviceId)
      ..removeAll(removed);
    final moderators = {...prev.moderatorDeviceIds}..removeAll(removed);
    return _sameSet(next.adminDeviceIds, admins) &&
        _sameSet(next.moderatorDeviceIds, moderators);
  }

  bool _sameSet(Iterable<String> a, Iterable<String> b) {
    final left = a.toSet();
    final right = b.toSet();
    return left.length == right.length && left.containsAll(right);
  }

  /// A projected, not revoked device of an account pins a newer list of its
  /// own account and drops the devices that list revokes, so a stolen admin
  /// phone loses its power without waiting for the owner. Only where every
  /// member knows accounts (older validators reject an admin removing an
  /// admin).
  bool _selfRevocation(
    GroupMembershipRecord authority,
    GroupMembershipRecord incoming,
    GroupRecord next,
    GroupMemberProfile actor,
    _Facts facts,
  ) {
    final prev = groupOf(authority);
    if (!_allCapable(prev)) return false;
    final entry = prev.memberAccounts
        .where((candidate) => candidate.accountId == actor.accountId)
        .firstOrNull;
    final nextEntry = next.memberAccounts
        .where((candidate) => candidate.accountId == actor.accountId)
        .firstOrNull;
    if (entry == null ||
        nextEntry == null ||
        next.ownerDeviceId != prev.ownerDeviceId ||
        next.title != prev.title ||
        next.isDissolved ||
        next.confirmNewDevices != prev.confirmNewDevices ||
        incoming.historyVisibility != authority.historyVisibility ||
        next.memberAccounts.length != prev.memberAccounts.length ||
        nextEntry.accountKeyBase64 != entry.accountKeyBase64 ||
        nextEntry.role != entry.role ||
        nextEntry.admission != entry.admission ||
        nextEntry.listVersion <= entry.listVersion ||
        canonicalGroupJson(nextEntry.approvedDeviceIds) !=
            canonicalGroupJson(entry.approvedDeviceIds) ||
        canonicalGroupJson(nextEntry.excludedDeviceIds) !=
            canonicalGroupJson(entry.excludedDeviceIds)) {
      return false;
    }
    for (final other in prev.memberAccounts) {
      if (other.accountId == entry.accountId) continue;
      final theirs = next.memberAccounts
          .where((candidate) => candidate.accountId == other.accountId)
          .firstOrNull;
      if (theirs == null || !_sameEntry(other, theirs)) return false;
    }
    final revoked = _revokedOf(facts, entry);
    final before = prev.activeMemberDeviceIds.toSet();
    final after = next.activeMemberDeviceIds.toSet();
    final removed = before.difference(after);
    if (!after.every(before.contains) ||
        removed.isEmpty ||
        !removed.every(
          (device) =>
              revoked.contains(device) &&
              prev.memberProfileFor(device)?.accountId == entry.accountId,
        )) {
      return false;
    }
    return _sameSet(
          next.adminDeviceIds,
          prev.adminDeviceIds.where(after.contains),
        ) &&
        _sameSet(
          next.moderatorDeviceIds,
          prev.moderatorDeviceIds.where(after.contains),
        );
  }

  /// Identity pinning over the whole ancestry: a device id keeps the keys it
  /// first appeared with in any ancestor (member profile or certificate).
  Map<String, _Ident> _checkIdentities(GroupRecord group, _Facts facts) {
    final known = facts.identities;
    var next = known;
    void pin(String deviceId, _Ident ident) {
      final owner = deviceId == trustedOwner.deviceId
          ? _Ident.ofProfile(trustedOwner)
          : null;
      final pinned = owner ?? next[deviceId];
      if (pinned != null && pinned != ident) {
        throw const FormatException(
          'Membership cannot replace a pinned identity.',
        );
      }
      if (pinned == null) {
        if (identical(next, known)) next = Map<String, _Ident>.of(known);
        next[deviceId] = ident;
      }
    }

    for (final device in group.activeMemberDeviceIds) {
      pin(device, _Ident.ofProfile(group.memberProfileFor(device)!));
    }
    for (final entry in group.memberAccounts) {
      final list = lists.get(entry.listDigest)!;
      for (final cert in list.devices) {
        pin(cert.deviceId, _Ident.ofCert(cert));
      }
    }
    return next;
  }

  Future<void> _checkAccounts({
    required GroupMembershipRecord incoming,
    required GroupRecord next,
    required List<GroupMembershipRecord> parents,
    required List<GroupRecord> parentGroups,
    required GroupRecord prev,
    required GroupMembershipRecord authority,
    required bool ownerAction,
    required bool exempt,
    required _Facts facts,
  }) async {
    final before = parentGroups.any((g) => g.memberAccounts.isNotEmpty);
    if (next.memberAccounts.isEmpty &&
        !before &&
        !next.confirmNewDevices &&
        !prev.confirmNewDevices) {
      return;
    }
    final limited = !ownerAction && !exempt;
    if (next.confirmNewDevices != prev.confirmNewDevices && !ownerAction) {
      throw const FormatException('Only the owner changes device approval.');
    }
    if (next.memberAccounts.isNotEmpty) {
      if (!_capable(next, next.ownerDeviceId) ||
          !next.adminDeviceIds.every((device) => _capable(next, device))) {
        throw const FormatException(
          'Account members need an owner and admins that know accounts.',
        );
      }
    }
    final byId = {
      for (final entry in next.memberAccounts) entry.accountId: entry,
    };
    final activeNext = next.activeMemberDeviceIds;
    final projectedBy = <String, List<GroupMemberProfile>>{};
    for (final device in activeNext) {
      final profile = next.memberProfileFor(device)!;
      (projectedBy[profile.accountId] ??= []).add(profile);
    }
    // An account that left takes all its devices with it.
    for (final parentGroup in parentGroups) {
      for (final entry in parentGroup.memberAccounts) {
        if (byId.containsKey(entry.accountId)) continue;
        if (projectedBy.containsKey(entry.accountId)) {
          throw const FormatException('A removed account keeps devices.');
        }
        if (limited &&
            (entry.role == GroupAccountRole.admin ||
                entry.role == GroupAccountRole.owner)) {
          throw const FormatException('Only the owner removes an admin.');
        }
      }
    }
    var ownerEntries = 0;
    for (final entry in next.memberAccounts) {
      final list = lists.get(entry.listDigest)!;
      final accountFacts =
          facts.accounts[entry.accountKeyBase64] ?? AccountFacts.empty;
      final holders = <(GroupMembershipRecord, GroupAccountMember)>[];
      for (var i = 0; i < parents.length; i++) {
        final theirs = parentGroups[i].memberAccounts
            .where((candidate) => candidate.accountId == entry.accountId)
            .firstOrNull;
        if (theirs != null) holders.add((parents[i], theirs));
      }
      final projected = projectedBy[entry.accountId] ?? const [];
      if (entry.role == GroupAccountRole.owner) ownerEntries++;
      if (entry.excludedDeviceIds.length > maxGroupAccountDeviceIds ||
          entry.approvedDeviceIds.length > maxGroupAccountDeviceIds) {
        throw const FormatException('Too many approved or excluded devices.');
      }
      GroupAccountMember? authorityEntry;
      for (final candidate in prev.memberAccounts) {
        if (candidate.accountId == entry.accountId) authorityEntry = candidate;
      }
      if (holders.isNotEmpty) {
        for (final (_, theirs) in holders) {
          if (theirs.accountKeyBase64 != entry.accountKeyBase64) {
            throw const FormatException('An account key cannot change.');
          }
        }
        if (holders.length == parents.length) {
          final admissions = {
            for (final (parent, theirs) in holders)
              parent.accountAdmission(theirs),
          };
          if (admissions.length != 1 || entry.admission != admissions.single) {
            throw const FormatException(
              'An admission boundary cannot change for an existing account.',
            );
          }
        } else if (entry.admission != null) {
          throw const FormatException('Invalid account admission.');
        }
        if (entry.upgrade != null) {
          throw const FormatException('An upgrade proof only folds a member.');
        }
        if (limited && authorityEntry != null) {
          if (entry.role != authorityEntry.role) {
            throw const FormatException('Only the owner changes roles.');
          }
          final pinChanged = entry.listDigest != authorityEntry.listDigest;
          if (entry.role != GroupAccountRole.member &&
              (pinChanged ||
                  canonicalGroupJson(entry.approvedDeviceIds) !=
                      canonicalGroupJson(authorityEntry.approvedDeviceIds) ||
                  canonicalGroupJson(entry.excludedDeviceIds) !=
                      canonicalGroupJson(authorityEntry.excludedDeviceIds))) {
            throw const FormatException(
              'Only the owner changes an admin account.',
            );
          }
          if (pinChanged && entry.listVersion <= authorityEntry.listVersion) {
            throw const FormatException('A device list cannot go back.');
          }
        }
      } else {
        if (facts.banned.contains(entry.accountKeyBase64)) {
          throw const FormatException(
            'An account with a forked device list cannot rejoin.',
          );
        }
        // A device-only member of the previous record that this account
        // takes over: the fold. It needs the account's proof.
        final folded = [
          for (final profile in projected)
            if (prev.hasActiveMember(profile.deviceId)) profile,
        ];
        if (folded.length > 1) {
          throw const FormatException('Only one member folds into an account.');
        }
        if (limited &&
            folded.isEmpty &&
            entry.role != GroupAccountRole.member) {
          throw const FormatException('A new account joins as a member.');
        }
        if (folded.length == 1) {
          await _checkFold(entry, list, folded.single, prev, next, authority);
        } else if (entry.upgrade != null || entry.admission != null) {
          throw const FormatException('Invalid new account entry.');
        }
      }
      // Confirmation lists.
      final listed = {for (final cert in list.devices) cert.deviceId};
      if (!next.confirmNewDevices && entry.approvedDeviceIds.isNotEmpty) {
        throw const FormatException('Approvals need device confirmation.');
      }
      if (!entry.approvedDeviceIds.every(listed.contains)) {
        throw const FormatException('Approved devices must be listed.');
      }
      if (limited && authorityEntry != null && holders.isNotEmpty) {
        final prevApproved = authorityEntry.approvedDeviceIds.where(
          (id) =>
              !accountFacts.revoked.contains(id) &&
              listed.contains(id) &&
              !entry.excludedDeviceIds.contains(id),
        );
        final prevExcluded = authorityEntry.excludedDeviceIds.where(
          (id) => !accountFacts.revoked.contains(id),
        );
        if (!prevApproved.every(entry.approvedDeviceIds.contains) ||
            !prevExcluded.every(entry.excludedDeviceIds.contains)) {
          throw const FormatException('Approvals only grow.');
        }
      }
      // The projection is a subset of what is effective.
      for (final profile in projected) {
        final cert = list.deviceFor(profile.deviceId);
        if (cert == null ||
            accountFacts.compromised ||
            accountFacts.revoked.contains(profile.deviceId) ||
            entry.excludedDeviceIds.contains(profile.deviceId) ||
            (next.confirmNewDevices &&
                !entry.approvedDeviceIds.contains(profile.deviceId)) ||
            _Ident.ofCert(cert) != _Ident.ofProfile(profile)) {
          throw const FormatException(
            'A projected device is not effective for its account.',
          );
        }
        final expected = _roleOfEntry(
          entry,
          profile.deviceId == next.ownerDeviceId,
        );
        if (next.roleFor(profile.deviceId) != expected) {
          throw const FormatException(
            'A projected device must have its account role.',
          );
        }
      }
      if (entry.role == GroupAccountRole.owner &&
          !projected.any((p) => p.deviceId == next.ownerDeviceId)) {
        throw const FormatException(
          'The owner account must project its owner.',
        );
      }
      if (entry.role != GroupAccountRole.owner &&
          projected.any((p) => p.deviceId == next.ownerDeviceId)) {
        throw const FormatException('Only the owner account holds the owner.');
      }
    }
    if (ownerEntries > 1) {
      throw const FormatException('Only one account holds the owner.');
    }
    // Confirmation switch: everything effective is approved at once.
    if (next.confirmNewDevices && !prev.confirmNewDevices) {
      for (final entry in next.memberAccounts) {
        final list = lists.get(entry.listDigest)!;
        final accountFacts =
            facts.accounts[entry.accountKeyBase64] ?? AccountFacts.empty;
        final effective = {
          for (final cert in list.devices)
            if (!accountFacts.revoked.contains(cert.deviceId) &&
                !entry.excludedDeviceIds.contains(cert.deviceId))
              cert.deviceId,
        };
        if (!_sameSet(entry.approvedDeviceIds, effective)) {
          throw const FormatException(
            'Switching on confirmation approves every current device.',
          );
        }
      }
    }
    // A device that is not an account's projected device may not be one of
    // an account's certified devices (a device-only member must not hide in
    // an account's list).
    for (final device in activeNext) {
      final profile = next.memberProfileFor(device)!;
      if (byId.containsKey(profile.accountId)) continue;
      for (final entry in next.memberAccounts) {
        if (lists
            .get(entry.listDigest)!
            .devices
            .any((cert) => cert.deviceId == device)) {
          throw const FormatException(
            'A device-only member appears in an account list.',
          );
        }
      }
    }
  }

  Future<void> _checkFold(
    GroupAccountMember entry,
    AccountDeviceList list,
    GroupMemberProfile folded,
    GroupRecord prev,
    GroupRecord next,
    GroupMembershipRecord authority,
  ) async {
    final upgrade = AccountUpgrade.fromJson(entry.upgrade);
    final before = prev.memberProfileFor(folded.deviceId);
    final cert = list.deviceFor(folded.deviceId);
    final role = prev.roleFor(folded.deviceId);
    if (upgrade == null ||
        before == null ||
        before.signingPublicKeyBase64 == null ||
        cert == null ||
        role == null ||
        upgrade.accountKeyBase64 != entry.accountKeyBase64 ||
        !await upgrade.verify(
          accountId: entry.accountId,
          deviceId: folded.deviceId,
          pinnedDeviceSigningKeyBase64: before.signingPublicKeyBase64!,
        ) ||
        _Ident.ofCert(cert) != _Ident.ofProfile(before) ||
        _Ident.ofProfile(folded) != _Ident.ofProfile(before) ||
        entry.role != _entryRoleFor(role) ||
        entry.admission != authority.admissions[folded.deviceId]) {
      throw const FormatException('Invalid fold of a member into an account.');
    }
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
    final cached = _ancestorCache[id];
    if (cached != null) return cached;
    final result = <String>{};
    final pending = [id];
    while (pending.isNotEmpty) {
      final next = pending.removeLast();
      if (result.add(next)) pending.addAll(_records[next]?.parents ?? const []);
    }
    // Unknown IDs may still arrive later with parents; only cache records.
    if (!_records.containsKey(id)) return result;
    return _ancestorCache[id] = Set.unmodifiable(result);
  }

  /// Devices active in some parent but not in [recordId], each mapped to the
  /// parents in which it was still active.
  Map<String, List<String>> _departures(String recordId) =>
      _departureCache.putIfAbsent(recordId, () {
        final remaining = _active(recordId);
        final result = <String, List<String>>{};
        for (final parentId in _records[recordId]!.parents) {
          for (final device in _active(parentId)) {
            if (!remaining.contains(device)) {
              (result[device] ??= <String>[]).add(parentId);
            }
          }
        }
        return result;
      });

  Set<String> _active(String recordId) => _activeCache.putIfAbsent(
    recordId,
    () => Set.unmodifiable(_records[recordId]!.group.activeMemberDeviceIds),
  );

  /// The signed cutoff for [author]'s departure at [removalId], as seen from
  /// [headId]. Removal records created before departure checkpoints existed
  /// carry none; for those, the earliest later record signed while [author]
  /// stayed departed supplies it. Admission records already capture every
  /// author's journal head, and owners sign a dedicated record otherwise, so
  /// authentic pre-removal history stays retrievable while anything signed
  /// past the cutoff is still rejected.
  GroupHistoryCheckpoint? _departureCheckpoint(
    String removalId,
    String author,
    String headId,
  ) {
    final direct = _records[removalId]!.checkpoints[author];
    if (direct != null) return direct;
    final key = '$headId\n$removalId\n$author';
    if (_departureCheckpointCache.containsKey(key)) {
      return _departureCheckpointCache[key];
    }
    GroupHistoryCheckpoint? earliest;
    for (final id in _ancestors(headId)) {
      if (id == removalId || !_isAncestor(removalId, id)) continue;
      final attested = _records[id]!.checkpoints[author];
      if (attested == null ||
          (earliest != null && attested.sequence >= earliest.sequence)) {
        continue;
      }
      // A cutoff signed after a readmission could cover the later epoch.
      if (_staysDeparted(removalId, author, id)) earliest = attested;
    }
    return _departureCheckpointCache[key] = earliest;
  }

  /// Whether [author] is inactive in every record from [removalId] through
  /// [recordId].
  bool _staysDeparted(String removalId, String author, String recordId) =>
      !_ancestors(recordId).any(
        (id) =>
            id != removalId &&
            _isAncestor(removalId, id) &&
            _active(id).contains(author),
      );

  /// Departed authors whose removal has no signed cutoff from the current
  /// head, and who stayed departed so a new record can still supply one.
  /// Their history from before removal stays rejected until a record carries
  /// a cutoff; group owners sign that record from their own journal.
  Set<String> departuresMissingCheckpoints() {
    final head = current;
    if (head == null) return const <String>{};
    final missing = <String>{};
    for (final recordId in _ancestors(head.id)) {
      for (final author in _departures(recordId).keys) {
        if (_staysDeparted(recordId, author, head.id) &&
            _departureCheckpoint(recordId, author, head.id) == null) {
          missing.add(author);
        }
      }
    }
    return missing;
  }

  Future<bool> _isBeforeRemovalFences(
    GroupHistoryEvent event,
    GroupMembershipRecord head,
  ) async {
    final ancestors = _ancestors(head.id);
    for (final recordId in ancestors) {
      final departedFrom = _departures(recordId)[event.authorDeviceId];
      if (departedFrom != null &&
          _isAncestor(event.membershipId, recordId) &&
          departedFrom.any(
            (parentId) => _isAncestor(event.membershipId, parentId),
          )) {
        final checkpoint = _departureCheckpoint(
          recordId,
          event.authorDeviceId,
          head.id,
        );
        // Without any signed cutoff, reject new-carried events at the removal
        // boundary rather than guessing from time.
        if (checkpoint == null || event.sequence > checkpoint.sequence) {
          return false;
        }
        if (event.sequence == checkpoint.sequence &&
            event.eventId != checkpoint.eventId) {
          return false;
        }
        if (_revokedByDag(head, event.authorAccountId, event.authorDeviceId) &&
            !await _onChain(event, checkpoint)) {
          return false;
        }
      }
    }
    return true;
  }

  /// Whether a list pinned in [head]'s ancestry revokes [deviceId] of the
  /// account [accountId].
  bool _revokedByDag(
    GroupMembershipRecord head,
    String accountId,
    String deviceId,
  ) {
    final facts = _facts[head.id];
    if (facts == null || facts.accounts.isEmpty) return false;
    for (final entry in groupOf(head).memberAccounts) {
      if (entry.accountId == accountId &&
          (facts.accounts[entry.accountKeyBase64]?.revoked.contains(deviceId) ??
              false)) {
        return true;
      }
    }
    return false;
  }

  /// A revoked author's event counts only if it is the cutoff event or
  /// precedes it on the author's own chain. Sequence numbers alone would
  /// let a revoked device fill free numbers below its cutoff.
  Future<bool> _onChain(
    GroupHistoryEvent event,
    GroupHistoryCheckpoint cutoff,
  ) async {
    if (event.sequence > cutoff.sequence) return false;
    if (event.sequence == cutoff.sequence) {
      return event.eventId == cutoff.eventId;
    }
    final oracle = chainAdmits;
    return oracle != null && await oracle(event, cutoff);
  }

  bool _isAncestor(String ancestor, String descendant) =>
      _ancestors(descendant).contains(ancestor);

  /// Revoked authors whose old events count only along their own chain, with
  /// the cutoff event to start the walk from: from the signed records that
  /// removed them, and from the cutoffs siblings signed for devices no
  /// record ever projected. History sync fetches these chains by id.
  Map<String, GroupHistoryCheckpoint> chainTargets() {
    final head = current;
    if (head == null) return const {};
    final targets = <String, GroupHistoryCheckpoint>{};
    for (final recordId in _ancestors(head.id)) {
      for (final author in _departures(recordId).keys) {
        final profile = _records[recordId]!.parents
            .map((id) => groupOf(_records[id]!).memberProfileFor(author))
            .nonNulls
            .firstOrNull;
        if (profile == null ||
            !_revokedByDag(head, profile.accountId, author)) {
          continue;
        }
        final checkpoint = _departureCheckpoint(recordId, author, head.id);
        if (checkpoint != null) targets[author] = checkpoint;
      }
    }
    for (final cutoff in view?.allCutoffs ?? const <AccountCutoff>[]) {
      targets.putIfAbsent(
        cutoff.deviceId,
        () => GroupHistoryCheckpoint(
          sequence: cutoff.sequence,
          eventId: cutoff.eventId,
        ),
      );
    }
    return targets;
  }

  /// A device acting for a member account without being in the signed
  /// projection: effective in the newest list of the first account that
  /// holds it (a later claimant of the same device id is ignored). Message
  /// events only; the signed projection never depends on this.
  GroupMemberProfile? _siblingProfile(GroupRecord group, String deviceId) {
    final lists = view;
    if (lists == null ||
        group.memberAccounts.isEmpty ||
        group.memberDeviceIds.contains(deviceId) ||
        group.removedDeviceIds.contains(deviceId)) {
      return null;
    }
    for (final entry in group.memberAccounts) {
      for (final cert in lists.effectiveCerts(
        entry,
        confirmNewDevices: group.confirmNewDevices,
      )) {
        if (cert.deviceId == deviceId) return profileFromCert(cert);
      }
    }
    return null;
  }

  /// Whether an account listed before [entry] holds [deviceId] effectively.
  bool _claimedByEarlier(
    GroupRecord group,
    GroupAccountMember entry,
    String deviceId,
  ) {
    final lists = view;
    if (lists == null) return false;
    for (final earlier in group.memberAccounts) {
      if (earlier.accountId == entry.accountId) return false;
      if (lists
          .effectiveCerts(earlier, confirmNewDevices: group.confirmNewDevices)
          .any((cert) => cert.deviceId == deviceId)) {
        return true;
      }
    }
    return false;
  }

  /// Whether the view says [deviceId] no longer counts for its account
  /// (revoked, excluded or the account is compromised) at the current head.
  bool _suspended(GroupRecord group, String accountId, String deviceId) {
    final lists = view;
    if (lists == null) return false;
    for (final entry in group.memberAccounts) {
      if (entry.accountId != accountId) continue;
      final facts = lists.factsFor(entry);
      return facts.compromised ||
          facts.revoked.contains(deviceId) ||
          entry.excludedDeviceIds.contains(deviceId);
    }
    return false;
  }

  /// Whether a signed record in the ancestry of the head took [deviceId] out
  /// of the projection: its checkpoint (or the want of one) decides what of
  /// its events still counts, in [_isBeforeRemovalFences].
  bool _departedInDag(GroupMembershipRecord head, String deviceId) {
    for (final recordId in _ancestors(head.id)) {
      if (_departures(recordId).containsKey(deviceId)) return true;
    }
    return false;
  }

  /// The profile of an event's author as the referenced record vouches for
  /// it, or null when the author did not count then. A projected device is
  /// vouched for by the signed projection; any other device by its account's
  /// certificate in a verified list (message events only).
  Future<GroupMemberProfile?> _authorProfile(
    GroupRecord group,
    GroupHistoryEvent event,
    GroupMembershipRecord head,
  ) async {
    final accountId = event.authorAccountId;
    final deviceId = event.authorDeviceId;
    final projected = group.hasActiveMember(deviceId)
        ? group.memberProfileFor(deviceId)
        : null;
    final entry = group.memberAccounts
        .where((candidate) => candidate.accountId == accountId)
        .firstOrNull;
    if (entry == null) return projected;
    final lists = view;
    if (lists != null && lists.factsFor(entry).compromised) return null;
    final suspended = _suspended(group, accountId, deviceId);
    var profile = projected;
    if (profile == null) {
      if (group.memberDeviceIds.contains(deviceId) ||
          group.removedDeviceIds.contains(deviceId) ||
          lists == null ||
          _claimedByEarlier(group, entry, deviceId)) {
        return null;
      }
      // A sibling counts through the account's *effective* devices; a
      // revoked one only through the certificate it had, up to its cutoff.
      final cert = suspended
          ? lists.certFor(
              accountId,
              deviceId,
              accountKey: entry.accountKeyBase64,
            )
          : lists
                .effectiveCerts(
                  entry,
                  confirmNewDevices: group.confirmNewDevices,
                )
                .where((c) => c.deviceId == deviceId)
                .firstOrNull;
      if (cert == null) return null;
      profile = profileFromCert(cert);
    }
    if (profile == null) return null;
    // A device a signed record took out of the projection is held to the
    // checkpoint that record carries (see [_isBeforeRemovalFences]); only a
    // device no record ever listed needs a cutoff a sibling signed.
    if (suspended && !_departedInDag(head, deviceId)) {
      final cutoff = lists?.cutoffFor(accountId, deviceId);
      if (cutoff == null ||
          !await _onChain(
            event,
            GroupHistoryCheckpoint(
              sequence: cutoff.sequence,
              eventId: cutoff.eventId,
            ),
          )) {
        return null;
      }
    }
    return profile;
  }

  /// Whether [deviceId] may receive history now: an active member of the
  /// head (not suspended in the view) or an effective sibling.
  bool _mayReceive(GroupRecord head, String deviceId) {
    final profile = head.memberProfileFor(deviceId);
    if (head.hasActiveMember(deviceId) && profile != null) {
      return !_suspended(head, profile.accountId, deviceId);
    }
    return _siblingProfile(head, deviceId) != null;
  }

  /// The record whose boundary governs what [deviceId] may read: the
  /// account's admission for a device of a member account, else the
  /// device's own.
  GroupMembershipRecord? _admissionFor(
    GroupMembershipRecord head,
    GroupRecord group,
    String deviceId,
  ) {
    final accountId =
        group.memberProfileFor(deviceId)?.accountId ??
        _siblingProfile(group, deviceId)?.accountId;
    if (accountId != null) {
      for (final entry in group.memberAccounts) {
        if (entry.accountId == accountId) {
          return _records[head.accountAdmission(entry)];
        }
      }
    }
    return _records[head.admissions[deviceId]];
  }

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
        !_isAncestor(membership.id, head.id)) {
      return false;
    }
    final epoch = view?.epoch;
    final headGroup = groupOf(head);
    if (!_mayReceive(headGroup, recipientDeviceId)) return false;
    final author = await _authorProfile(groupOf(membership), event, head);
    if (author == null || epoch != view?.epoch) return false;
    final admission = _admissionFor(head, headGroup, recipientDeviceId);
    if (admission == null) return false;
    if (!await _isBeforeRemovalFences(event, head)) return false;
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
    // A removal, conflict or revocation may arrive while signature
    // verification yields.
    return verified && current?.id == head.id && epoch == view?.epoch;
  }

  /// A carrier needs current group authorization too. This permission never
  /// authorizes a private conversation with either endpoint.
  Future<bool> canForward(
    GroupHistoryEvent event, {
    required String carrierDeviceId,
    required String recipientDeviceId,
  }) async {
    final head = current;
    return head != null &&
        _mayReceive(groupOf(head), carrierDeviceId) &&
        await canReceive(event, recipientDeviceId: carrierDeviceId) &&
        await canReceive(event, recipientDeviceId: recipientDeviceId) &&
        current?.id == head.id;
  }
}

/// A device's keys as a record or certificate pins them.
class _Ident {
  const _Ident(this.accountId, this.signingKey, this.encryptionKey, this.iroh);

  factory _Ident.ofProfile(GroupMemberProfile profile) => _Ident(
    profile.accountId,
    profile.signingPublicKeyBase64 ?? '',
    profile.publicKeyBase64,
    profile.irohEndpointId ?? '',
  );

  factory _Ident.ofCert(DeviceCert cert) => _Ident(
    cert.accountId,
    cert.signingKeyBase64,
    cert.encryptionKeyBase64,
    cert.irohEndpointId ?? signingKeyHex(cert.signingKeyBase64),
  );

  final String accountId;
  final String signingKey;
  final String encryptionKey;
  final String iroh;

  @override
  bool operator ==(Object other) =>
      other is _Ident &&
      other.accountId == accountId &&
      other.signingKey == signingKey &&
      other.encryptionKey == encryptionKey &&
      other.iroh == iroh;

  @override
  int get hashCode => Object.hash(accountId, signingKey, encryptionKey, iroh);
}

/// What a record's ancestry fixes, shared between records whenever a record
/// adds nothing.
class _Facts {
  _Facts(this.accounts, this.identities, this.banned);

  /// Account key -> what the lists pinned in the ancestry say.
  final Map<String, AccountFacts> accounts;
  final Map<String, _Ident> identities;

  /// Account keys whose ancestry shows a fork: they cannot rejoin.
  final Set<String> banned;

  _Facts withIdentities(Map<String, _Ident> next) =>
      identical(next, identities) ? this : _Facts(accounts, next, banned);
}

bool _digest(String value) => RegExp(r'^[0-9a-f]{64}$').hasMatch(value);
