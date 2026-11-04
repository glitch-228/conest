import 'dart:convert';

import 'package:conest/src/account/account_model.dart';
import 'package:conest/src/group_account_member.dart';
import 'package:conest/src/group_accounts.dart';
import 'package:conest/src/group_history_event.dart';
import 'package:conest/src/group_membership_history.dart';
import 'package:conest/src/models.dart';
import 'package:cryptography/cryptography.dart';

/// Every timestamp in these fixtures comes from here, never from the wall
/// clock (Known pitfall 20).
final fixtureEpoch = DateTime.utc(2026, 9, 10);

class TestDevice {
  TestDevice._(
    this.id,
    this.accountId,
    this.signing,
    this.signingPublicKey,
    this.signingPrivateKey,
    this.encryptionPublicKey,
  );

  static Future<TestDevice> create(String id, String accountId) async {
    final pair = await Ed25519().newKeyPair();
    final data = await pair.extract();
    final publicKey = await pair.extractPublicKey();
    final enc = await (await X25519().newKeyPair()).extractPublicKey();
    return TestDevice._(
      id,
      accountId,
      pair,
      base64Encode(publicKey.bytes),
      base64Encode(data.bytes),
      base64Encode(enc.bytes),
    );
  }

  final String id;
  final String accountId;
  final SimpleKeyPair signing;
  final String signingPublicKey;
  final String signingPrivateKey;
  final String encryptionPublicKey;

  String get iroh => signingKeyHex(signingPublicKey);

  GroupMemberProfile profile({bool capable = true}) => GroupMemberProfile(
    accountId: accountId,
    deviceId: id,
    displayName: id,
    bio: '',
    relayCapable: false,
    publicKeyBase64: encryptionPublicKey,
    signingPublicKeyBase64: signingPublicKey,
    irohEndpointId: iroh,
    routeHints: [],
    capabilities: [TransportKind.iroh],
    featureCapabilities: capable
        ? [ApplicationCapability.groupAccountsV1]
        : const [],
  );
}

class TestAccount {
  TestAccount._(this.id, this.keys);

  static Future<TestAccount> create(String id) async =>
      TestAccount._(id, await AccountKeys.generate());

  final String id;
  final AccountKeys keys;

  Future<DeviceCert> cert(TestDevice device, {String? name}) async {
    final proof = await signEd25519(
      DeviceCert.proofBytes(
        accountId: id,
        accountKeyBase64: keys.publicKeyBase64,
        deviceId: device.id,
        encryptionKeyBase64: device.encryptionPublicKey,
        signingKeyBase64: device.signingPublicKey,
        irohEndpointId: device.iroh,
      ),
      publicKeyBase64: device.signingPublicKey,
      privateKeyBase64: device.signingPrivateKey,
    );
    return DeviceCert.issue(
      account: keys,
      accountId: id,
      deviceId: device.id,
      encryptionKeyBase64: device.encryptionPublicKey,
      signingKeyBase64: device.signingPublicKey,
      irohEndpointId: device.iroh,
      name: name ?? device.id,
      linkedAt: fixtureEpoch,
      proofSignatureBase64: proof,
    );
  }

  Future<AccountDeviceList> list(
    int version,
    List<TestDevice> devices, {
    List<String> revoked = const [],
  }) async => AccountDeviceList.issue(
    account: keys,
    accountId: id,
    version: version,
    devices: [for (final device in devices) await cert(device)],
    revoked: {for (final id in revoked) id: fixtureEpoch},
    issuedAt: fixtureEpoch.add(Duration(minutes: version)),
  );

  Future<AccountUpgrade> upgrade(TestDevice device) => AccountUpgrade.create(
    accountId: id,
    deviceId: device.id,
    deviceSigningPublicKeyBase64: device.signingPublicKey,
    deviceSigningPrivateKeyBase64: device.signingPrivateKey,
    account: keys,
    issuedAt: fixtureEpoch,
  );
}

/// One account's place in a record: its pinned list, role and projection.
class AccountSpec {
  AccountSpec(
    this.account,
    this.list,
    this.projected, {
    this.role = GroupAccountRole.member,
    this.approved = const [],
    this.excluded = const [],
    this.upgrade,
    this.admission,
    this.keyOverride,
  });

  final TestAccount account;
  final AccountDeviceList list;
  final List<TestDevice> projected;
  final GroupAccountRole role;
  final List<String> approved;
  final List<String> excluded;
  final AccountUpgrade? upgrade;
  final String? admission;
  final String? keyOverride;
}

class GroupFixture {
  GroupFixture({this.groupId = 'group-acc'});

  final String groupId;
  final lists = PinnedListStore();
  final _previous = <String, GroupHistoryEvent>{};
  var _lamport = 0;

  GroupMembershipHistory history({
    required TestDevice owner,
    PinnedListStore? store,
    DeviceListView? view,
    Future<bool> Function(GroupHistoryEvent, GroupHistoryCheckpoint)? chain,
  }) => GroupMembershipHistory(
    groupId: groupId,
    trustedOwner: owner.profile(),
    lists: store ?? lists,
    view: view,
    chainAdmits: chain,
  );

  Future<GroupHistoryEvent> sign({
    required TestDevice author,
    required String membershipId,
    required GroupEventKind kind,
    required Map<String, Object?> payload,
    int? sequence,
    String? previousEventId,
    bool track = true,
  }) async {
    final prior = _previous[author.id];
    final event = await GroupHistoryEvent.sign(
      groupId: groupId,
      authorAccountId: author.accountId,
      authorDeviceId: author.id,
      keyPair: author.signing,
      sequence: sequence ?? (prior?.sequence ?? 0) + 1,
      previousEventId: sequence == null ? prior?.eventId : previousEventId,
      lamport: (++_lamport) > (sequence ?? 0) ? _lamport : sequence!,
      membershipId: membershipId,
      kind: kind,
      payload: payload,
    );
    if (track) _previous[author.id] = event;
    return event;
  }

  Future<GroupHistoryEvent> message(
    GroupMembershipRecord membership,
    TestDevice author,
  ) => sign(
    author: author,
    membershipId: membership.id,
    kind: GroupEventKind.message,
    payload: {'text': 'Hello from ${author.id}'},
  );

  /// A signed membership record. Device-only members are [deviceOnly];
  /// [accounts] bring their projected devices. [admins] lists device-only
  /// admins; account roles come from the spec.
  Future<GroupMembershipRecord> record({
    required TestDevice owner,
    required TestDevice author,
    List<GroupMembershipRecord> parents = const [],
    List<TestDevice> deviceOnly = const [],
    List<AccountSpec> accounts = const [],
    List<String> admins = const [],
    List<String> moderators = const [],
    bool confirmNewDevices = false,
    GroupHistoryVisibility? visibility,
    Map<String, GroupHistoryCheckpoint> checkpoints = const {},
    Map<String, GroupMemberProfile> profileOverrides = const {},
  }) async {
    final parentIds = parents.map((parent) => parent.id).toList()..sort();
    final members = <TestDevice>[owner];
    for (final device in [...deviceOnly, for (final a in accounts) ...a.projected]) {
      if (!members.any((m) => m.id == device.id)) members.add(device);
    }
    final adminIds = [...admins];
    final moderatorIds = [...moderators];
    final entries = <GroupAccountMember>[];
    for (final spec in accounts) {
      final digest = lists.put(spec.list);
      final held = [
        for (final parent in parents)
          parent.group.memberAccounts
              .where((e) => e.accountId == spec.account.id)
              .map((e) => parent.accountAdmission(e))
              .firstOrNull,
      ];
      final admission = spec.admission ??
          (held.isNotEmpty && !held.contains(null) && held.toSet().length == 1
              ? held.first
              : null);
      entries.add(
        GroupAccountMember(
          accountId: spec.account.id,
          accountKeyBase64: spec.keyOverride ?? spec.account.keys.publicKeyBase64,
          role: spec.role,
          listVersion: spec.list.version,
          listDigest: digest,
          admission: admission,
          approvedDeviceIds: spec.approved,
          excludedDeviceIds: spec.excluded,
          upgrade: spec.upgrade?.toJson(),
        ),
      );
      for (final device in spec.projected) {
        if (device.id == owner.id) continue;
        switch (spec.role) {
          case GroupAccountRole.admin:
          case GroupAccountRole.owner:
            adminIds.add(device.id);
          case GroupAccountRole.moderator:
            moderatorIds.add(device.id);
          case GroupAccountRole.member:
            break;
        }
      }
    }
    final automatic = <String, String?>{};
    for (final member in members) {
      final earlier = parents.map((parent) => parent.admissions[member.id]).toSet();
      automatic[member.id] =
          parents.isNotEmpty && earlier.length == 1 && !earlier.contains(null)
          ? earlier.single
          : null;
    }
    final group = GroupRecord(
      groupId: groupId,
      title: 'Group',
      ownerDeviceId: owner.id,
      adminDeviceIds: adminIds,
      moderatorDeviceIds: moderatorIds,
      memberDeviceIds: [for (final m in members) m.id],
      removedDeviceIds: const [],
      memberProfiles: [
        for (final m in members) profileOverrides[m.id] ?? m.profile(),
      ],
      membershipVersion: parents.isEmpty
          ? 1
          : parents
                    .map((parent) => parent.group.membershipVersion)
                    .reduce((a, b) => a > b ? a : b) +
                1,
      createdAt: fixtureEpoch,
      updatedAt: fixtureEpoch,
      memberAccounts: entries,
      confirmNewDevices: confirmNewDevices,
    );
    return GroupMembershipRecord.fromEvent(
      await sign(
        author: author,
        membershipId: parentIds.isEmpty
            ? GroupMembershipRecord.rootReference(
                groupId,
                owner.signingPublicKey,
              )
            : parentIds.first,
        kind: GroupEventKind.membership,
        payload: GroupMembershipRecord.payload(
          group: group,
          parents: parentIds,
          historyVisibility:
              visibility ??
              (parents.isEmpty
                  ? GroupHistoryVisibility.allRetained
                  : parents.first.historyVisibility),
          admissions: automatic,
          checkpoints: checkpoints,
        ),
      ),
    );
  }
}
