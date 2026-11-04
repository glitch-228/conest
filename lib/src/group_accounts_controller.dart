part of 'messenger_controller.dart';

/// Groups by account (M29): the controller side. Device lists seen in a
/// group, the resolved group (member accounts' effective devices), the
/// owner's automatic membership records, and the announcements between
/// devices.
///
/// What a membership record means is decided by the signed history
/// (`group_membership_history.dart`), from the record and the lists its
/// digests name. Nothing here decides that. This file keeps this device's
/// view of the lists, applies it to the group the rest of the app reads, and
/// writes the records only the owner's app writes.
extension GroupAccountsController on MessengerController {
  static const int _maxListsPerMessage = 16;
  static const int _maxCutoffsPerMessage = 64;
  static const Duration _newAdminDeviceDelay = Duration(hours: 24);

  /// Tests shorten the wait before the owner's app writes a record.
  @visibleForTesting
  void setOwnerWriterDelayForTesting(Duration delay) {
    _ownerWriterDelay = delay;
    _ownerRecordWindow = delay;
  }

  // ---- State ----------------------------------------------------------

  void _loadGroupAccountState() {
    _pinnedLists = PinnedListStore.fromJson(_snapshot.pinnedDeviceLists);
    _deviceListViews.clear();
    _siblingAnnounces.clear();
    _deviceFirstSeenStore
      ..clear()
      ..addAll({
        for (final entry in _snapshot.groupDeviceFirstSeen.entries)
          if (DateTime.tryParse(entry.value) case final at?)
            entry.key: at.toUtc(),
      });
  }

  /// Verified lists only enter a view: those stored are checked again
  /// against the key the group's signed record holds for the account.
  Future<void> _rebuildDeviceListViews() async {
    for (final group in List.of(_snapshot.groups)) {
      if (group.memberAccounts.isEmpty) continue;
      final view = _viewOf(group.groupId);
      for (final entry in group.memberAccounts) {
        for (final digest in _pinnedLists.digests.take(512).toList()) {
          final list = _pinnedLists.get(digest);
          if (list == null || list.accountId != entry.accountId) continue;
          if (!_pinnedLists.isVerified(digest, entry.accountKeyBase64)) {
            if (!await list.verify(entry.accountKeyBase64)) continue;
            _pinnedLists.markVerified(digest, entry.accountKeyBase64);
          }
          view.offerVerified(list, accountKey: entry.accountKeyBase64);
        }
      }
    }
    _resolveAllGroups();
  }

  void _resolveAllGroups() {
    final groups = [
      for (final group in _snapshot.groups) _resolveAccountsIn(group),
    ];
    _snapshot = _snapshot.copyWith(groups: groups);
  }

  DeviceListView _viewOf(String groupId) => _deviceListViews.putIfAbsent(
    groupId,
    () => DeviceListView(groupId: groupId),
  );

  static const Duration _pendingLifetime = Duration(days: 7);

  /// Pending upgrades and announced profiles expire; what is still true is
  /// announced again by the devices themselves.
  void _expireGroupAccountState() {
    final cutoff = _now().toUtc().subtract(_pendingLifetime);
    for (final pending in _pendingUpgrades.values) {
      pending.removeWhere((_, value) => value.$3.isBefore(cutoff));
    }
    _pendingUpgrades.removeWhere((_, value) => value.isEmpty);
    for (final entry in _siblingAnnounceAt.entries.toList()) {
      if (entry.value.isAfter(cutoff)) continue;
      _siblingAnnounceAt.remove(entry.key);
      final parts = entry.key.split('|');
      _siblingAnnounces[parts.first]?.remove(parts.last);
    }
    _siblingAnnounces.removeWhere((_, value) => value.isEmpty);
    final groups = {for (final g in _snapshot.groups) g.groupId};
    _pendingUpgrades.removeWhere((id, _) => !groups.contains(id));
    _siblingAnnounces.removeWhere((id, _) => !groups.contains(id));
    _siblingAnnounceAt.removeWhere(
      (key, _) => !groups.contains(key.split('|').first),
    );
  }

  void _persistPinnedLists() {
    _expireGroupAccountState();
    _pinnedLists.evictUnpinned();
    // Times of devices of groups that are gone are dropped; the rest is
    // bounded.
    final groups = {for (final g in _snapshot.groups) g.groupId};
    _deviceFirstSeenStore.removeWhere(
      (key, _) => !groups.contains(key.split('|').first),
    );
    while (_deviceFirstSeenStore.length > 512) {
      _deviceFirstSeenStore.remove(_deviceFirstSeenStore.keys.first);
    }
    _snapshot = _snapshot.copyWith(
      pinnedDeviceLists: _pinnedLists.toJson(),
      groupDeviceFirstSeen: {
        for (final entry in _deviceFirstSeenStore.entries)
          entry.key: entry.value.toIso8601String(),
      },
    );
  }

  /// The group as this device acts on it: the signed record plus the
  /// effective devices of its member accounts (and minus the projected ones
  /// that stopped being effective). A group without accounts is returned as
  /// it is.
  GroupRecord _resolveAccountsIn(GroupRecord group) {
    if (group.memberAccounts.isEmpty &&
        group.siblingProfiles.isEmpty &&
        group.suppressedDeviceIds.isEmpty) {
      return group;
    }
    final signed = group.signedView;
    final view = _viewOf(signed.groupId);
    for (final entry in signed.memberAccounts) {
      final list = _pinnedLists.get(entry.listDigest);
      if (list != null &&
          _pinnedLists.isVerified(entry.listDigest, entry.accountKeyBase64)) {
        view.absorbPinned(list, accountKey: entry.accountKeyBase64);
      }
    }
    // This device's own account list: known without being told.
    final me = _snapshot.identity;
    final own = accountDevices;
    if (me != null && own != null && me.accountKeyPublicBase64 != null) {
      for (final entry in signed.memberAccounts) {
        if (entry.accountKeyBase64 == me.accountKeyPublicBase64 &&
            entry.accountId == own.accountId) {
          view.offerVerified(own, accountKey: entry.accountKeyBase64);
        }
      }
    }
    final resolution = resolveGroup(
      signed,
      view,
      conflictsWithKnownIdentity: _deviceIdentityConflicts,
      announces: _siblingAnnounces[signed.groupId] ?? const {},
    );
    _groupResolutions[signed.groupId] = resolution;
    return resolution.group;
  }

  /// What the last resolution of [groupId] found: devices ignored as
  /// unverified, devices waiting for approval, accounts without a usable
  /// device. For the group info screens.
  GroupResolution? groupAccountStatus(String groupId) =>
      _groupResolutions[groupId];

  /// A device id this device already knows with other keys: a contact, or
  /// itself. A certificate claiming it is ignored, never merged (device ids
  /// are names anyone can claim).
  bool _deviceIdentityConflicts(String deviceId, DeviceCert cert) {
    final me = _snapshot.identity;
    if (me != null && me.deviceId == deviceId) {
      return me.publicKeyBase64 != cert.encryptionKeyBase64 ||
          me.signingPublicKeyBase64 != cert.signingKeyBase64;
    }
    final contact = _contactByDeviceId(deviceId);
    if (contact == null) return false;
    return contact.publicKeyBase64 != cert.encryptionKeyBase64 ||
        (contact.signingPublicKeyBase64 != null &&
            contact.signingPublicKeyBase64 != cert.signingKeyBase64);
  }

  // ---- Envelopes from devices not introduced yet ----------------------

  static const int _siblingParkEnvelopeBytes = 64 * 1024;
  static const int _siblingParkGroupBytes = 128 * 1024;
  static const int _siblingParkTotalBytes = 512 * 1024;
  static const int _siblingParkGroupCount = 32;
  static const Duration _siblingParkLifetime = Duration(hours: 24);
  static const Set<String> _siblingGatedKinds = {
    'group_message',
    'group_history',
    'group_file_part',
    'group_call_signal',
  };

  /// A group envelope from a device that is not a member yet, in a group with
  /// member accounts: it may be a sibling whose list is on its way.
  bool _isUnknownSibling(RelayEnvelope envelope) {
    if (!_siblingGatedKinds.contains(envelope.kind)) return false;
    final group = _groupById(envelope.conversationId);
    final me = _snapshot.identity;
    return group != null &&
        me != null &&
        group.memberAccounts.isNotEmpty &&
        group.localRemovedAt == null &&
        group.hasActiveMember(me.deviceId) &&
        !group.hasActiveMember(envelope.senderDeviceId) &&
        !group.removedDeviceIds.contains(envelope.senderDeviceId);
  }

  /// Keeps [envelope] on this device (bounded: per group and in all, oldest
  /// first, with a lifetime). Whether it was kept.
  bool _parkSiblingEnvelope(RelayEnvelope envelope) {
    final encoded = jsonEncode(envelope.toJson());
    final size = utf8.encode(encoded).length;
    if (size > _siblingParkEnvelopeBytes) return false;
    final now = _now().toUtc();
    final cutoff = now.subtract(_siblingParkLifetime);
    final kept = [
      for (final entry in _snapshot.parkedSiblingEnvelopes)
        if (entry.receivedAt.isAfter(cutoff) && entry.envelopeJson != encoded)
          entry,
      HeldEnvelope(
        senderDeviceId: envelope.senderDeviceId,
        conversationId: envelope.conversationId,
        envelopeJson: encoded,
        receivedAt: now,
      ),
    ];
    int bytes(Iterable<HeldEnvelope> entries) =>
        entries.fold(0, (sum, entry) => sum + entry.envelopeJson.length);
    Iterable<HeldEnvelope> ofGroup() =>
        kept.where((e) => e.conversationId == envelope.conversationId);
    while (ofGroup().length > _siblingParkGroupCount ||
        bytes(ofGroup()) > _siblingParkGroupBytes) {
      kept.remove(ofGroup().first);
    }
    while (kept.length > 1 && bytes(kept) > _siblingParkTotalBytes) {
      kept.removeAt(0);
    }
    _snapshot = _snapshot.copyWith(parkedSiblingEnvelopes: kept);
    return true;
  }

  @visibleForTesting
  bool isUnknownSiblingForTesting(RelayEnvelope envelope) =>
      _isUnknownSibling(envelope);

  @visibleForTesting
  bool parkSiblingEnvelopeForTesting(RelayEnvelope envelope) =>
      _parkSiblingEnvelope(envelope);

  @visibleForTesting
  List<HeldEnvelope> get parkedSiblingEnvelopesForTesting =>
      _snapshot.parkedSiblingEnvelopes;

  @visibleForTesting
  int get groupAccountStateSizeForTesting =>
      _pendingUpgrades.length +
      _siblingAnnounces.length +
      _siblingAnnounceAt.length +
      _deviceListViews.length +
      _announcedFor.length;

  @visibleForTesting
  void replaySiblingParkedForTesting(String groupId) =>
      _replaySiblingParked(groupId);

  @visibleForTesting
  Future<void> settleSiblingReplaysForTesting() async {
    while (_replayingSiblings.isNotEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  @visibleForTesting
  int pendingUpgradeCountForTesting(String groupId) =>
      _pendingUpgrades[groupId]?.length ?? 0;

  @visibleForTesting
  void notePendingUpgradeForTesting(
    String groupId,
    AccountUpgrade upgrade,
    AccountDeviceList list,
    DateTime at,
  ) {
    _pendingUpgrades.putIfAbsent(groupId, () => {})[upgrade.deviceId] = (
      upgrade,
      list,
      at,
    );
  }

  @visibleForTesting
  void expireGroupAccountStateForTesting() => _expireGroupAccountState();

  @visibleForTesting
  void noteSiblingAnnounceForTesting(
    String groupId,
    GroupMemberProfile profile,
    DateTime at,
  ) {
    _siblingAnnounces.putIfAbsent(groupId, () => {})[profile.deviceId] =
        profile;
    _siblingAnnounceAt['$groupId|${profile.deviceId}'] = at;
  }

  /// A group's devices changed: parked envelopes whose sender is a member
  /// now are read again (one run at a time per group).
  void _replaySiblingParked(String groupId) {
    if (_disposed || !_replayingSiblings.add(groupId)) return;
    final group = _groupById(groupId);
    final now = _now().toUtc();
    final due = <HeldEnvelope>[];
    final rest = <HeldEnvelope>[];
    for (final entry in _snapshot.parkedSiblingEnvelopes) {
      final expired = now.difference(entry.receivedAt) >= _siblingParkLifetime;
      if (expired) continue;
      if (entry.conversationId == groupId &&
          group != null &&
          group.hasActiveMember(entry.senderDeviceId)) {
        due.add(entry);
      } else {
        rest.add(entry);
      }
    }
    if (due.isEmpty) {
      _replayingSiblings.remove(groupId);
      return;
    }
    _snapshot = _snapshot.copyWith(parkedSiblingEnvelopes: rest);
    unawaited(() async {
      try {
        for (final entry in due) {
          try {
            final envelope = RelayEnvelope.fromJson(
              jsonDecode(entry.envelopeJson) as Map<String, dynamic>,
            );
            await _processEnvelopes([envelope]);
          } catch (_) {}
        }
      } finally {
        _replayingSiblings.remove(groupId);
        if (!_disposed) await _saveSnapshotSilently(notify: false);
      }
    }());
  }

  // ---- Wire -----------------------------------------------------------

  /// The membership fields two copies of a group record must share (the
  /// wire copy and the one the signed proof carries). Member profiles may
  /// differ in routes and addresses (a profile-only refresh), never in the
  /// keys a record pins.
  bool _sameSignedMembership(GroupRecord a, GroupRecord b) {
    bool sameIds(Iterable<String> x, Iterable<String> y) {
      final left = x.toSet();
      final right = y.toSet();
      return left.length == right.length && left.containsAll(right);
    }

    if (a.groupId != b.groupId ||
        a.title != b.title ||
        a.ownerDeviceId != b.ownerDeviceId ||
        a.membershipVersion != b.membershipVersion ||
        a.confirmNewDevices != b.confirmNewDevices ||
        a.dissolvedAt != b.dissolvedAt ||
        !sameIds(a.memberDeviceIds, b.memberDeviceIds) ||
        !sameIds(a.removedDeviceIds, b.removedDeviceIds) ||
        !sameIds(a.adminDeviceIds, b.adminDeviceIds) ||
        !sameIds(a.moderatorDeviceIds, b.moderatorDeviceIds) ||
        a.memberAccounts.length != b.memberAccounts.length) {
      return false;
    }
    for (var i = 0; i < a.memberAccounts.length; i++) {
      if (canonicalGroupJson(a.memberAccounts[i].toJson()) !=
          canonicalGroupJson(b.memberAccounts[i].toJson())) {
        return false;
      }
    }
    for (final profile in a.memberProfiles) {
      final other = b.memberProfileFor(profile.deviceId);
      if (other == null ||
          other.accountId != profile.accountId ||
          other.publicKeyBase64 != profile.publicKeyBase64 ||
          other.signingPublicKeyBase64 != profile.signingPublicKeyBase64 ||
          other.irohEndpointId != profile.irohEndpointId) {
        return false;
      }
    }
    return a.memberProfiles.length == b.memberProfiles.length;
  }

  /// The wire copy of a group carries the account entries exactly as the
  /// signed proof beside it has them (the proof's admission boundaries, no
  /// fold proof once folded).
  GroupRecord _withProofAccounts(GroupRecord group, String? historyProof) {
    if (group.memberAccounts.isEmpty || historyProof == null) return group;
    try {
      return group.copyWith(
        memberAccounts: GroupMembershipRecord.fromEvent(
          GroupHistoryEvent.decode(historyProof),
        ).group.memberAccounts,
      );
    } catch (_) {
      return group;
    }
  }

  /// The pinned lists of [group], to travel beside its signed record.
  List<Map<String, Object?>> _listsPayloadFor(GroupRecord group) => [
    for (final entry in group.memberAccounts.take(maxGroupAccounts))
      if (_pinnedLists.get(entry.listDigest) case final list?) list.toJson(),
  ];

  List<AccountDeviceList> _parseLists(Object? raw) {
    if (raw is! List || raw.length > _maxListsPerMessage) return const [];
    return [
      for (final entry in raw)
        ?AccountDeviceList.fromJson(entry),
    ];
  }

  /// Whether this device is one of the effective devices of an account the
  /// signed [record] admits, given [lists] (not yet trusted for anything
  /// else): a sibling the projection does not name.
  Future<bool> _isEffectiveSibling(
    GroupRecord record,
    List<AccountDeviceList> lists,
  ) async {
    final me = _snapshot.identity;
    if (me == null) return false;
    for (final entry in record.memberAccounts) {
      if (entry.accountId != me.accountId) continue;
      for (final list in lists) {
        if (list.accountId != entry.accountId ||
            deviceListDigest(list) != entry.listDigest) {
          continue;
        }
        final digest = _pinnedLists.put(list);
        if (!_pinnedLists.isVerified(digest, entry.accountKeyBase64)) {
          if (!await list.verify(entry.accountKeyBase64)) continue;
          _pinnedLists.markVerified(digest, entry.accountKeyBase64);
        }
        if (list.deviceFor(me.deviceId) != null &&
            !entry.excludedDeviceIds.contains(me.deviceId) &&
            (!record.confirmNewDevices ||
                entry.approvedDeviceIds.contains(me.deviceId))) {
          return true;
        }
      }
    }
    return false;
  }

  /// A `devices` message of a group member: its account's lists (checked
  /// against the key the signed record holds, never one in the message),
  /// cutoffs for revoked devices, its own profile, and an upgrade proof of a
  /// device-only member.
  Future<void> _handleGroupDevices(
    GroupRecord group,
    ContactRecord sender,
    Map<String, dynamic> message,
  ) async {
    final lists = _parseLists(message['lists']);
    final view = _viewOf(group.groupId);
    var changed = false;
    final newDevices = <String>{};
    for (final list in lists) {
      GroupAccountMember? entry;
      for (final candidate in group.memberAccounts) {
        if (candidate.accountId == list.accountId) entry = candidate;
      }
      if (entry == null) continue;
      final digest = _pinnedLists.put(list);
      if (!_pinnedLists.isVerified(digest, entry.accountKeyBase64)) {
        if (!await list.verify(entry.accountKeyBase64)) continue;
        _pinnedLists.markVerified(digest, entry.accountKeyBase64);
      }
      // The group may have changed while the signature was checked.
      final fresh = _groupById(group.groupId);
      if (_disposed ||
          fresh == null ||
          !fresh.memberAccounts.any(
            (held) =>
                held.accountId == entry!.accountId &&
                held.accountKeyBase64 == entry.accountKeyBase64,
          )) {
        return;
      }
      final before = view.current(list.accountId)?.devices.length;
      if (view.offerVerified(list, accountKey: entry.accountKeyBase64)) {
        changed = true;
        for (final cert in list.devices) {
          if (!group.hasActiveMember(cert.deviceId)) {
            newDevices.add(cert.deviceId);
            _deviceFirstSeen.putIfAbsent(
              '${group.groupId}|${cert.deviceId}',
              () => _now().toUtc(),
            );
          }
        }
      }
      if (before == null) changed = true;
    }
    final cutoffs = message['cutoffs'];
    if (cutoffs is List && cutoffs.length <= _maxCutoffsPerMessage) {
      for (final raw in cutoffs) {
        final cutoff = AccountCutoff.fromJson(raw);
        if (cutoff != null && await view.offerCutoff(cutoff)) changed = true;
      }
    }
    final announcedIds = <String>{};
    final announce = message['announce'];
    if (announce is Map<String, dynamic>) {
      try {
        final profile = GroupMemberProfile.fromJson(announce);
        if (profile.deviceId == sender.deviceId) {
          final held = _siblingAnnounces.putIfAbsent(group.groupId, () => {});
          if ((held.length < 64 || held.containsKey(profile.deviceId)) &&
              canonicalGroupJson(held[profile.deviceId]?.toJson()) !=
                  canonicalGroupJson(profile.toJson())) {
            held[profile.deviceId] = profile;
            _siblingAnnounceAt['${group.groupId}|${profile.deviceId}'] =
                _now().toUtc();
            changed = true;
            announcedIds.add(profile.deviceId);
          }
        }
      } catch (_) {}
    }
    // Routes an effective device knows for its account's other devices.
    final siblings = message['siblings'];
    if (siblings is List && siblings.length <= 8) {
      final held = _siblingAnnounces.putIfAbsent(group.groupId, () => {});
      for (final raw in siblings) {
        if (raw is! Map<String, dynamic>) continue;
        try {
          final profile = GroupMemberProfile.fromJson(raw);
          final cert = view.certFor(sender.accountId, profile.deviceId);
          if (profile.accountId != sender.accountId ||
              profile.deviceId == sender.deviceId ||
              cert == null ||
              held.containsKey(profile.deviceId) ||
              held.length >= 64) {
            continue;
          }
          final merged = profileFromCert(cert, announced: profile);
          if (merged != null && merged.routeHints.isNotEmpty) {
            held[profile.deviceId] = merged;
            _siblingAnnounceAt['${group.groupId}|${profile.deviceId}'] =
                _now().toUtc();
            changed = true;
            announcedIds.add(profile.deviceId);
          }
        } catch (_) {}
      }
    }
    final upgrade = AccountUpgrade.fromJson(message['upgrade']);
    if (upgrade != null && upgrade.deviceId == sender.deviceId) {
      final pending = _pendingUpgrades.putIfAbsent(group.groupId, () => {});
      final list = lists.where((l) => l.accountId == upgrade.accountId);
      if ((pending.length < 16 || pending.containsKey(upgrade.deviceId)) &&
          list.isNotEmpty) {
        pending[upgrade.deviceId] = (upgrade, list.first, _now().toUtc());
        changed = true;
      }
    }
    if (!changed || _disposed) return;
    final fresh = _groupById(group.groupId);
    if (fresh == null) return;
    _upsertGroup(fresh);
    _persistPinnedLists();
    await _persist('Updated the devices of ${fresh.title}.');
    _replaySiblingParked(group.groupId);
    // My own account's new device learns the group from me.
    final me = _snapshot.identity;
    final mine = [
      for (final id in newDevices)
        if (me != null &&
            _groupById(group.groupId)?.memberProfileFor(id)?.accountId ==
                me.accountId)
          id,
    ];
    if (mine.isNotEmpty) {
      unawaited(
        _sendGroupMembershipUpdate(
          _groupById(group.groupId)!,
          targetDeviceIds: mine,
          reason: 'new-device',
        ).catchError((Object _) {}),
      );
    }
    // A device whose routes are now known gets the group it belongs to from
    // the owner (the record named it before anyone could reach it).
    final owner = _snapshot.identity;
    final current = _groupById(group.groupId);
    if (announcedIds.isNotEmpty &&
        owner != null &&
        current != null &&
        current.ownerDeviceId == owner.deviceId) {
      final targets = [
        for (final id in announcedIds)
          if (current.hasActiveMember(id) && id != owner.deviceId) id,
      ];
      if (targets.isNotEmpty) {
        unawaited(
          _sendGroupMembershipUpdate(
            current,
            targetDeviceIds: targets,
            reason: 'new-device',
          ).catchError((Object _) {}),
        );
      }
    }
    _scheduleOwnerWriter(group.groupId);
  }

  /// For a group with member accounts, the stored group follows the signed
  /// membership head: a record that could not be taken when it arrived (it
  /// needed earlier records or lists) is adopted once catch-up has brought
  /// them. Only a head that is newer than what is stored, and only through the
  /// verified history; groups without accounts are left to the old path.
  Future<void> _adoptMembershipHead(String groupId) async {
    final stored = _groupById(groupId);
    if (_disposed || stored == null || stored.localRemovedAt != null) return;
    final head = await _groupHistory.currentMembership(groupId);
    if (head == null) return;
    final signed = head.group;
    if (signed.membershipVersion <= stored.membershipVersion ||
        (signed.memberAccounts.isEmpty && stored.memberAccounts.isEmpty)) {
      return;
    }
    // Keep what this device knows beyond the record (routes, addresses) for
    // members whose keys the record pins.
    final profiles = [
      for (final profile in signed.memberProfiles)
        if (stored.memberProfileFor(profile.deviceId) case final known?
            when known.accountId == profile.accountId &&
                known.publicKeyBase64 == profile.publicKeyBase64 &&
                known.signingPublicKeyBase64 == profile.signingPublicKeyBase64)
          known
        else
          profile,
    ];
    final merged = GroupRecord.fromJson({
      ...signed.copyWith(
        memberProfiles: profiles,
        profileRevision: max(
          signed.profileRevision,
          stored.profileRevision,
        ),
      ).toJson(),
      'localRemovedAt': stored.localRemovedAt?.toIso8601String(),
    });
    for (final entry in merged.memberAccounts) {
      final list = _pinnedLists.get(entry.listDigest);
      if (list != null) {
        _pinnedLists.markVerified(entry.listDigest, entry.accountKeyBase64);
      }
    }
    _upsertGroup(merged);
    _ensureGroupConversation(_groupById(groupId)!);
    _persistPinnedLists();
    await _persist('Updated group ${merged.title}.');
    _scheduleOwnerWriter(groupId);
  }

  /// Offers this device's account list to a group once per list version and
  /// state of the group: after the group is stored, and after the account's
  /// devices change.
  void _announceOnGroupChange(GroupRecord group) {
    final me = _snapshot.identity;
    final list = accountDevices;
    if (me == null || list == null) return;
    final mine = group.memberAccounts.any((e) => e.accountId == me.accountId);
    if (!mine) return;
    final key =
        '${list.version}|${group.membershipVersion}|'
        '${group.memberDeviceIds.contains(me.deviceId)}';
    if (_announcedFor[group.groupId] == key) return;
    _announcedFor[group.groupId] = key;
    _announceOwnDeviceList(onlyGroup: group.groupId);
  }

  // ---- Announcing this account's list ---------------------------------

  /// Tells the groups this account is a member of its current device list
  /// (after a change, and when a new group is joined). One run at a time per
  /// group; sends go through the queue, never on an inbound path.
  void _announceOwnDeviceList({String? onlyGroup}) {
    final me = _snapshot.identity;
    if (_disposed || me == null || me.accountKeyPublicBase64 == null) return;
    for (final group in List.of(_snapshot.groups)) {
      if (onlyGroup != null && group.groupId != onlyGroup) continue;
      if (group.localRemovedAt != null || group.isDissolved) continue;
      final mine = group.memberAccounts.any(
        (entry) => entry.accountId == me.accountId,
      );
      final deviceOnly = !mine && group.hasActiveMember(me.deviceId);
      // A device-only member that became an account offers its upgrade.
      if (!mine && !(deviceOnly && me.accountUpgrade != null)) continue;
      if (!_announcing.add(group.groupId)) continue;
      unawaited(
        _announceDeviceListNow(group.groupId).whenComplete(
          () => _announcing.remove(group.groupId),
        ),
      );
    }
  }

  Future<void> _announceDeviceListNow(String groupId) async {
    try {
      final group = _groupById(groupId);
      final me = _snapshot.identity;
      final list = accountDevices;
      if (group == null || me == null || list == null) return;
      final mine = group.memberAccounts.any((e) => e.accountId == me.accountId);
      final payload = <String, Object?>{
        'version': 1,
        'groupId': groupId,
        'type': 'devices',
        'lists': [list.toJson()],
        'announce': _groupProfileForIdentity(me).toJson(),
        // The account's other devices, with the routes this device knows for
        // them, so a new device is reachable as soon as it is listed.
        'siblings': [
          for (final device in ownDevices.take(8))
            _groupProfileForContact(device).toJson(),
        ],
        if (!mine && me.accountUpgrade != null) 'upgrade': me.accountUpgrade,
      };
      for (final device in group.activeMemberDeviceIds.take(64)) {
        if (_disposed || device == me.deviceId) continue;
        final profile = group.memberProfileFor(device);
        if (profile == null ||
            !profile.featureCapabilities.contains(
              ApplicationCapability.groupAccountsV1,
            )) {
          continue;
        }
        try {
          await _groupHistory.send(groupId, device, payload);
        } catch (error) {
          // Unreachable now: it gets the list with the next announcement.
          appendDebugLog('Device list not sent to $device: $error');
        }
      }
    } catch (error) {
      appendDebugLog('Device list announcement failed: $error');
    }
  }

  // ---- The owner's automatic records ----------------------------------

  /// One writer keeps the signed record in step with the accounts' lists:
  /// the owner's app. Debounced per group; cancelled on dispose.
  void _scheduleOwnerWriter(String groupId, {Duration? after}) {
    final me = _snapshot.identity;
    final group = _groupById(groupId);
    if (_disposed ||
        me == null ||
        group == null ||
        group.ownerDeviceId != me.deviceId ||
        (group.memberAccounts.isEmpty && _pendingUpgrades[groupId] == null)) {
      return;
    }
    _groupWriterTimers[groupId]?.cancel();
    _groupWriterTimers[groupId] = Timer(after ?? _ownerWriterDelay, () {
      _groupWriterTimers.remove(groupId);
      if (_disposed) return;
      unawaited(
        _runOwnerWriter(groupId).catchError((Object error) {
          appendDebugLog('Device record not written: $error');
        }),
      );
    });
  }

  /// Re-arms the writers after a start or a change of mode: the 24 hour
  /// wake for new devices of admin accounts comes from the stored times.
  void _rearmOwnerWriters() {
    for (final group in _snapshot.groups) {
      _scheduleOwnerWriter(group.groupId);
    }
  }

  Future<void> _runOwnerWriter(String groupId) async {
    final me = _snapshot.identity;
    final group = _groupById(groupId);
    if (me == null ||
        group == null ||
        group.ownerDeviceId != me.deviceId ||
        group.localRemovedAt != null ||
        group.isDissolved) {
      return;
    }
    final signed = group.signedView;
    final view = _viewOf(groupId);
    final now = _now().toUtc();
    final capable = _groupAcceptsAccounts(signed);
    var next = signed;
    var changed = false;
    DateTime? wakeAt;
    // Folds first: a device-only member that became an account.
    final folds = <String>[];
    if (capable && !signed.confirmNewDevices) {
      for (final entry in (_pendingUpgrades[groupId] ?? const {}).entries) {
        final (upgrade, list, _) = entry.value;
        final x = signed.memberProfileFor(entry.key);
        if (x == null ||
            !signed.hasActiveMember(entry.key) ||
            signed.memberAccounts.any((a) => a.accountId == upgrade.accountId) ||
            x.accountId != upgrade.accountId ||
            x.signingPublicKeyBase64 == null ||
            !await upgrade.verify(
              accountId: upgrade.accountId,
              deviceId: entry.key,
              pinnedDeviceSigningKeyBase64: x.signingPublicKeyBase64!,
            ) ||
            !await list.verify(upgrade.accountKeyBase64) ||
            list.deviceFor(entry.key) == null) {
          continue;
        }
        final held = await _groupHistory.currentMembership(groupId);
        final admission = held?.admissions[entry.key];
        final role = signed.roleFor(entry.key);
        if (held == null || admission == null || role == null) continue;
        final digest = _pinnedLists.put(list);
        final privileged = role != GroupMemberRole.member;
        final projected = privileged
            ? [x]
            : [
                for (final cert in list.devices.take(8))
                  if (cert.deviceId == entry.key)
                    x
                  else
                    ?profileFromCert(cert),
              ];
        next = next.copyWith(
          memberAccounts: [
            ...next.memberAccounts,
            GroupAccountMember(
              accountId: upgrade.accountId,
              accountKeyBase64: upgrade.accountKeyBase64,
              role: switch (role) {
                GroupMemberRole.owner => GroupAccountRole.owner,
                GroupMemberRole.admin => GroupAccountRole.admin,
                GroupMemberRole.moderator => GroupAccountRole.moderator,
                GroupMemberRole.member => GroupAccountRole.member,
              },
              listVersion: list.version,
              listDigest: digest,
              admission: admission,
              upgrade: upgrade.toJson(),
            ),
          ],
          memberDeviceIds: {
            ...next.memberDeviceIds,
            for (final p in projected) p.deviceId,
          }.toList(),
          memberProfiles: [
            for (final p in next.memberProfiles)
              if (p.deviceId != entry.key) p,
            ...projected,
          ],
        );
        view.offerVerified(list, accountKey: upgrade.accountKeyBase64);
        folds.add(entry.key);
        changed = true;
      }
    }
    // Re-pins: newer lists, revocations, and the 24 hour wake.
    final entries = <GroupAccountMember>[];
    for (final entry in next.memberAccounts) {
      final current = view.current(entry.accountId);
      var updated = entry;
      if (current == null || view.compromised(entry.accountId)) {
        if (view.compromised(entry.accountId)) {
          final drop = next.memberProfiles
              .where((p) => p.accountId == entry.accountId)
              .map((p) => p.deviceId)
              .where((id) => id != next.ownerDeviceId)
              .toSet();
          if (drop.isNotEmpty) {
            next = _withoutDevices(next, drop);
            changed = true;
          }
        }
        entries.add(updated);
        continue;
      }
      final pinned = _pinnedLists.get(entry.listDigest);
      final effective = {
        for (final c in view.effectiveCerts(
          entry,
          confirmNewDevices: next.confirmNewDevices,
        ))
          c.deviceId: c,
      };
      final projectedIds = {
        for (final p in next.memberProfiles)
          if (p.accountId == entry.accountId &&
              next.hasActiveMember(p.deviceId))
            p.deviceId,
      };
      final drop = projectedIds.difference(effective.keys.toSet())
        ..remove(next.ownerDeviceId);
      final add = <DeviceCert>[];
      for (final cert in effective.values) {
        if (projectedIds.contains(cert.deviceId)) continue;
        if (entry.role == GroupAccountRole.member) {
          add.add(cert);
          continue;
        }
        // A new device of an admin account reads and posts at once; the
        // admin projection follows 24 hours after this app first saw it.
        final first = _deviceFirstSeen['$groupId|${cert.deviceId}'];
        final due = first?.add(_newAdminDeviceDelay);
        if (due != null && !due.isAfter(now)) {
          add.add(cert);
        } else if (due != null) {
          wakeAt = wakeAt == null || due.isBefore(wakeAt) ? due : wakeAt;
        }
      }
      final newRevocations = view
          .revoked(entry.accountId)
          .difference(pinned?.revoked.keys.toSet() ?? const <String>{});
      final needsPin =
          current.version > entry.listVersion &&
          (drop.isNotEmpty || add.isNotEmpty || newRevocations.isNotEmpty);
      if (!needsPin) {
        entries.add(updated);
        continue;
      }
      // Revocation and compromise are read again at signing time.
      if (drop.isNotEmpty) next = _withoutDevices(next, drop);
      final room = 16 - next.activeMemberDeviceIds.length;
      final added = add.take(room < 0 ? 0 : room).toList();
      if (added.isNotEmpty) {
        final profiles = [
          for (final cert in added)
            ?profileFromCert(
              cert,
              announced: _siblingAnnounces[groupId]?[cert.deviceId],
            ),
        ];
        next = next.copyWith(
          memberDeviceIds: [
            ...next.memberDeviceIds,
            for (final p in profiles) p.deviceId,
          ],
          memberProfiles: [...next.memberProfiles, ...profiles],
          adminDeviceIds: [
            ...next.adminDeviceIds,
            if (entry.role == GroupAccountRole.admin ||
                entry.role == GroupAccountRole.owner)
              for (final p in profiles) p.deviceId,
          ],
          moderatorDeviceIds: [
            ...next.moderatorDeviceIds,
            if (entry.role == GroupAccountRole.moderator)
              for (final p in profiles) p.deviceId,
          ],
        );
      }
      updated = entry.copyWith(
        listVersion: current.version,
        listDigest: _pinnedLists.put(current),
        approvedDeviceIds: [
          for (final id in entry.approvedDeviceIds)
            if (effective.containsKey(id)) id,
        ],
      );
      entries.add(updated);
      changed = true;
    }
    if (!changed) {
      if (wakeAt != null) {
        _scheduleOwnerWriter(groupId, after: wakeAt.difference(now));
      }
      return;
    }
    // The per account rate limit: at most one record per window.
    final last = _lastOwnerRecordAt[groupId];
    if (last != null && now.difference(last) < _ownerRecordWindow) {
      _scheduleOwnerWriter(groupId, after: _ownerRecordWindow);
      return;
    }
    final fresh = _groupById(groupId);
    if (fresh == null || fresh.membershipVersion != signed.membershipVersion) {
      return;
    }
    _lastOwnerRecordAt[groupId] = now;
    next = next.copyWith(
      memberAccounts: entries,
      membershipVersion: signed.membershipVersion + 1,
      updatedAt: now,
    );
    for (final id in folds) {
      _pendingUpgrades[groupId]?.remove(id);
    }
    _upsertGroup(next);
    _persistPinnedLists();
    await _persist('Updated the devices of ${next.title}.');
    final targets = next.activeMemberDeviceIds
        .followedBy(signed.activeMemberDeviceIds)
        .toSet()
        .where((id) => id != me.deviceId)
        .toList();
    await _sendGroupMembershipUpdate(
      _groupById(groupId)!,
      targetDeviceIds: targets,
      reason: 'devices',
    );
    if (wakeAt != null) {
      _scheduleOwnerWriter(groupId, after: wakeAt.difference(now));
    }
  }

  GroupRecord _withoutDevices(GroupRecord group, Set<String> drop) =>
      group.copyWith(
        memberDeviceIds: [
          for (final id in group.memberDeviceIds)
            if (!drop.contains(id)) id,
        ],
        memberProfiles: [
          for (final p in group.memberProfiles)
            if (!drop.contains(p.deviceId)) p,
        ],
        adminDeviceIds: [
          for (final id in group.adminDeviceIds)
            if (!drop.contains(id)) id,
        ],
        moderatorDeviceIds: [
          for (final id in group.moderatorDeviceIds)
            if (!drop.contains(id)) id,
        ],
      );

  /// A device of a member account left: the account leaves with all its
  /// devices. Only the owner's app writes the record (removal is a signed
  /// membership change); the owner's own account cannot leave this way.
  Future<void> _accountLeft(
    GroupRecord group,
    String deviceId,
    DateTime at,
  ) async {
    final me = _snapshot.identity;
    final entry = group.accountOf(deviceId);
    if (me == null ||
        entry == null ||
        group.ownerDeviceId != me.deviceId ||
        entry.role == GroupAccountRole.owner) {
      return;
    }
    final signed = group.signedView;
    final gone = {
      for (final p in signed.memberProfiles)
        if (p.accountId == entry.accountId) p.deviceId,
    };
    final next = _withoutDevices(signed, gone).copyWith(
      memberAccounts: [
        for (final held in signed.memberAccounts)
          if (held.accountId != entry.accountId) held,
      ],
      removedDeviceIds: [...signed.removedDeviceIds, ...gone],
      membershipVersion: signed.membershipVersion + 1,
      updatedAt: at,
    );
    _upsertGroup(next);
    await _persist('${entry.accountId} left ${next.title}.');
    await _sendGroupMembershipUpdate(
      _groupById(group.groupId)!,
      targetDeviceIds: [
        ...next.activeMemberDeviceIds.where((id) => id != me.deviceId),
        ...gone,
      ],
      reason: 'member_left',
    );
  }

  /// Accounts mode needs an owner and admins that know accounts.
  bool _groupAcceptsAccounts(GroupRecord group) {
    bool capable(String id) =>
        group
            .memberProfileFor(id)
            ?.featureCapabilities
            .contains(ApplicationCapability.groupAccountsV1) ==
        true;
    return capable(group.ownerDeviceId) && group.adminDeviceIds.every(capable);
  }

  /// A group that was stored on the word of a wire copy, and whose signed
  /// record then did not check out, is taken back out.
  Future<void> _dropProvisionalGroup(String groupId) async {
    _snapshot = _snapshot.copyWith(
      groups: [
        for (final group in _snapshot.groups)
          if (group.groupId != groupId) group,
      ],
      conversations: [
        for (final conversation in _snapshot.conversations)
          if (!(conversation.kind == ConversationKind.group &&
              conversation.id == groupId))
            conversation,
      ],
    );
    _deviceListViews.remove(groupId);
    await _persist('Dropped a group whose membership did not check out.');
  }

  void _clearGroupAccountState() {
    for (final timer in _groupWriterTimers.values) {
      timer.cancel();
    }
    _groupWriterTimers.clear();
    _deviceListViews.clear();
    _siblingAnnounces.clear();
    _pendingUpgrades.clear();
    _groupResolutions.clear();
    _lastOwnerRecordAt.clear();
    _announcing.clear();
    _announcedFor.clear();
    _replayingSiblings.clear();
    _siblingAnnounceAt.clear();
    _deviceFirstSeenStore.clear();
    _pinnedLists.clear();
  }
}
