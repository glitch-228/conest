/// Groups by account (M29): pure rules for device lists pinned in a group.
///
/// Two stores, kept apart on purpose:
/// - [PinnedListStore] holds device lists by content digest. A signed
///   membership record names the digest of the list it admits; nothing here
///   decides whether a record is accepted except that the content behind a
///   digest is fixed.
/// - [DeviceListView] is a local, per group view of the lists seen so far.
///   It depends on what has arrived, so it is used only to decide message
///   events and to build the resolved group the UI and delivery read. It
///   never decides whether a membership record is accepted.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart' as hashes;

import 'account/account_model.dart';
import 'group_account_member.dart';
import 'models.dart';
import 'native_ed25519.dart';

String _canonical(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((key) => key as String).toList()..sort();
    return '{${[for (final key in keys) '${jsonEncode(key)}:${_canonical(value[key])}'].join(',')}}';
  }
  if (value is List) return '[${value.map(_canonical).join(',')}]';
  return jsonEncode(value);
}

/// Canonical JSON of [value] (sorted keys), as group records sign it.
String canonicalGroupJson(Object? value) => _canonical(value);

/// The content address of a device list: sha256 of its canonical JSON,
/// signature included.
String deviceListDigest(AccountDeviceList list) => hashes.sha256
    .convert(utf8.encode(_canonical(list.toJson())))
    .toString();

String signingKeyHex(String signingKeyBase64) => base64Decode(
  signingKeyBase64,
).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

/// What the device lists seen for one account say about its devices.
///
/// "Compromised" is the fork signal: some list lists a device that another
/// list revokes although the revoking list is not newer than the listing
/// one (an honest chain always revokes with a higher version than any list
/// that still listed the device), or the revoked set reached its cap. Every
/// linked device holds the account key, so a fork means that someone else
/// holds it too; the account then has no effective device (fail closed).
class AccountFacts {
  const AccountFacts._(
    this.listed,
    this.revokeMin,
    this.revoked,
    this.compromised,
  );

  static const AccountFacts empty = AccountFacts._({}, {}, {}, false);

  /// Device -> highest version of a list that lists it.
  final Map<String, int> listed;

  /// Device -> lowest version of a list that revokes it.
  final Map<String, int> revokeMin;
  final Set<String> revoked;
  final bool compromised;

  static bool _violates(Map<String, int> listed, Map<String, int> revokeMin) {
    for (final entry in revokeMin.entries) {
      final listing = listed[entry.key];
      if (listing != null && entry.value <= listing) return true;
    }
    return false;
  }

  AccountFacts withList(AccountDeviceList list) {
    var changed = false;
    final nextListed = Map<String, int>.of(listed);
    final nextRevokeMin = Map<String, int>.of(revokeMin);
    final nextRevoked = Set<String>.of(revoked);
    for (final device in list.devices) {
      final known = nextListed[device.deviceId];
      if (known == null || known < list.version) {
        nextListed[device.deviceId] = list.version;
        changed = true;
      }
    }
    for (final id in list.revoked.keys) {
      final known = nextRevokeMin[id];
      if (known == null || known > list.version) {
        nextRevokeMin[id] = list.version;
        changed = true;
      }
      if (nextRevoked.add(id)) changed = true;
    }
    if (!changed) return this;
    return AccountFacts._(
      nextListed,
      nextRevokeMin,
      nextRevoked,
      compromised ||
          list.revoked.length >= maxRevokedDevices ||
          _violates(nextListed, nextRevokeMin),
    );
  }

  AccountFacts merge(AccountFacts other) {
    if (identical(this, other) || other == empty) return this;
    if (this == empty) return other;
    final nextListed = Map<String, int>.of(listed);
    for (final entry in other.listed.entries) {
      final known = nextListed[entry.key];
      if (known == null || known < entry.value) {
        nextListed[entry.key] = entry.value;
      }
    }
    final nextRevokeMin = Map<String, int>.of(revokeMin);
    for (final entry in other.revokeMin.entries) {
      final known = nextRevokeMin[entry.key];
      if (known == null || known > entry.value) {
        nextRevokeMin[entry.key] = entry.value;
      }
    }
    return AccountFacts._(
      nextListed,
      nextRevokeMin,
      {...revoked, ...other.revoked},
      compromised ||
          other.compromised ||
          _violates(nextListed, nextRevokeMin),
    );
  }
}

/// Lists by content digest. A list becomes *pinned* when an accepted
/// membership record names its digest; pinned lists are kept unconditionally:
/// a local byte cap must never be the reason a signed record cannot be
/// rebuilt or accepted (it would split this member off). The cap evicts only
/// lists no accepted record pins (offered but never used), oldest first.
class PinnedListStore {
  PinnedListStore();

  final _lists = <String, AccountDeviceList>{};
  final _sizes = <String, int>{};
  final _pinned = <String>{};
  final _verified = <String>{};
  int _bytes = 0;

  /// Bounds what unpinned lists may take (pinned ones are exempt).
  static const int defaultMaxUnpinnedBytes = 1024 * 1024;

  int get bytes => _bytes;
  int get length => _lists.length;
  Iterable<String> get digests => _lists.keys;
  Set<String> get pinnedDigests => Set.unmodifiable(_pinned);
  bool isPinned(String digest) => _pinned.contains(digest);

  AccountDeviceList? get(String digest) => _lists[digest];

  /// Stores [list] and returns its digest. Never refuses.
  String put(AccountDeviceList list) {
    final digest = deviceListDigest(list);
    if (!_lists.containsKey(digest)) {
      final size = jsonEncode(list.toJson()).length;
      _lists[digest] = list;
      _sizes[digest] = size;
      _bytes += size;
    }
    return digest;
  }

  /// Keeps the list at [digest] for good: an accepted record pins it.
  void markPinned(String digest) {
    if (_lists.containsKey(digest)) _pinned.add(digest);
  }

  /// Whether the list at [digest] was checked against [accountKeyBase64].
  bool isVerified(String digest, String accountKeyBase64) =>
      _verified.contains('$digest|$accountKeyBase64');

  void markVerified(String digest, String accountKeyBase64) {
    if (_verified.length > 4096) _verified.clear();
    _verified.add('$digest|$accountKeyBase64');
  }

  /// Drops unpinned lists, oldest first, until they fit
  /// [maxUnpinnedBytes]. Pinned lists are never touched.
  int evictUnpinned({int maxUnpinnedBytes = defaultMaxUnpinnedBytes}) {
    var unpinned = 0;
    for (final entry in _sizes.entries) {
      if (!_pinned.contains(entry.key)) unpinned += entry.value;
    }
    var dropped = 0;
    for (final digest in _lists.keys.toList()) {
      if (unpinned <= maxUnpinnedBytes) break;
      if (_pinned.contains(digest)) continue;
      unpinned -= _sizes[digest]!;
      _bytes -= _sizes[digest]!;
      _lists.remove(digest);
      _sizes.remove(digest);
      dropped++;
    }
    return dropped;
  }

  void clear() {
    _lists.clear();
    _sizes.clear();
    _pinned.clear();
    _verified.clear();
    _bytes = 0;
  }

  List<Map<String, Object?>> toJson() => [
    for (final entry in _lists.entries)
      {'list': entry.value.toJson(), if (_pinned.contains(entry.key)) 'pinned': true},
  ];

  static PinnedListStore fromJson(Object? json) {
    final store = PinnedListStore();
    if (json is List) {
      for (final raw in json) {
        if (raw is! Map) continue;
        final list = AccountDeviceList.fromJson(raw['list']);
        if (list == null) continue;
        final digest = store.put(list);
        if (raw['pinned'] == true) store.markPinned(digest);
      }
    }
    return store;
  }
}

/// A sibling's statement of the last event of a revoked device that still
/// counts. Used only for devices no signed record ever projected; for the
/// others the record that removed the device carries the checkpoint.
class AccountCutoff {
  const AccountCutoff({
    required this.groupId,
    required this.accountId,
    required this.deviceId,
    required this.sequence,
    required this.eventId,
    required this.signerDeviceId,
    required this.signatureBase64,
  });

  final String groupId;
  final String accountId;
  final String deviceId;
  final int sequence;
  final String eventId;
  final String signerDeviceId;
  final String signatureBase64;

  static Map<String, Object?> _fields({
    required String groupId,
    required String accountId,
    required String deviceId,
    required int sequence,
    required String eventId,
    required String signerDeviceId,
  }) => {
    'groupId': groupId,
    'accountId': accountId,
    'deviceId': deviceId,
    'sequence': sequence,
    'eventId': eventId,
    'signerDeviceId': signerDeviceId,
  };

  List<int> get signingBytes => utf8.encode(
    'conest.group-device-cutoff.v1\n${_canonical(_fields(groupId: groupId, accountId: accountId, deviceId: deviceId, sequence: sequence, eventId: eventId, signerDeviceId: signerDeviceId))}',
  );

  static Future<AccountCutoff> sign({
    required String groupId,
    required String accountId,
    required String deviceId,
    required int sequence,
    required String eventId,
    required String signerDeviceId,
    required String signerPublicKeyBase64,
    required String signerPrivateKeyBase64,
  }) async {
    final draft = AccountCutoff(
      groupId: groupId,
      accountId: accountId,
      deviceId: deviceId,
      sequence: sequence,
      eventId: eventId,
      signerDeviceId: signerDeviceId,
      signatureBase64: '',
    );
    return AccountCutoff(
      groupId: groupId,
      accountId: accountId,
      deviceId: deviceId,
      sequence: sequence,
      eventId: eventId,
      signerDeviceId: signerDeviceId,
      signatureBase64: await signEd25519(
        draft.signingBytes,
        publicKeyBase64: signerPublicKeyBase64,
        privateKeyBase64: signerPrivateKeyBase64,
      ),
    );
  }

  Map<String, Object?> toJson() => {
    ..._fields(
      groupId: groupId,
      accountId: accountId,
      deviceId: deviceId,
      sequence: sequence,
      eventId: eventId,
      signerDeviceId: signerDeviceId,
    ),
    'signature': signatureBase64,
  };

  static AccountCutoff? fromJson(Object? json) {
    if (json is! Map) return null;
    String? text(String key) {
      final value = json[key];
      return value is String && value.isNotEmpty && value.length <= 128
          ? value
          : null;
    }

    final sequence = json['sequence'];
    final signature = json['signature'];
    final groupId = text('groupId');
    final accountId = text('accountId');
    final deviceId = text('deviceId');
    final eventId = text('eventId');
    final signer = text('signerDeviceId');
    if (groupId == null ||
        accountId == null ||
        deviceId == null ||
        eventId == null ||
        signer == null ||
        sequence is! int ||
        sequence < 1 ||
        signature is! String ||
        signature.length > 128) {
      return null;
    }
    return AccountCutoff(
      groupId: groupId,
      accountId: accountId,
      deviceId: deviceId,
      sequence: sequence,
      eventId: eventId,
      signerDeviceId: signer,
      signatureBase64: signature,
    );
  }
}

/// A device that is effective for an account: its certificate.
typedef EffectiveDevice = DeviceCert;

/// The device lists a device has seen for the accounts in one group, as a
/// deterministic function of the *set* of verified lists: highest version
/// is current (ties by smaller digest), revocations are unions. Arrival
/// order cannot change the outcome.
class DeviceListView {
  DeviceListView({required this.groupId});

  final String groupId;
  final _accounts = <String, _AccountState>{};

  /// Bumped whenever the view changes; authorization re-checks it after an
  /// await (a revocation may land while a signature is verified).
  int epoch = 0;

  /// Most accounts kept per group (the group itself allows 16).
  static const int maxAccounts = maxGroupAccounts;
  static const int maxCutoffsPerAccount = 64;

  _AccountState _state(String accountId) =>
      _accounts[accountId] ??= _AccountState();

  Iterable<String> get accountIds => _accounts.keys;

  /// Offers a list whose signature the caller already checked against the
  /// key the group's signed record holds for the account. Returns whether
  /// the view changed.
  bool offerVerified(AccountDeviceList list, {required String accountKey}) {
    if (!_accounts.containsKey(list.accountId) &&
        _accounts.length >= maxAccounts) {
      return false;
    }
    var state = _state(list.accountId);
    if (state.key != null && state.key != accountKey) {
      // The group admitted another key under this id: nothing carries over.
      _accounts[list.accountId] = state = _AccountState();
    }
    state.key = accountKey;
    for (final cert in list.devices) {
      if (state.certs.length < 256 || state.certs.containsKey(cert.deviceId)) {
        state.certs.putIfAbsent(cert.deviceId, () => cert);
      }
    }
    final digest = deviceListDigest(list);
    var changed = false;
    final facts = state.facts.withList(list);
    if (!identical(facts, state.facts)) {
      state.facts = facts;
      changed = true;
    }
    final current = state.current;
    if (current == null ||
        list.version > current.version ||
        (list.version == current.version &&
            digest.compareTo(deviceListDigest(current)) < 0)) {
      state.current = list;
      changed = true;
    }
    if (changed) epoch++;
    return changed;
  }

  /// Revocations pinned by the signed DAG count whether or not this view
  /// saw the list. Feeds the same facts.
  bool absorbPinned(AccountDeviceList list, {required String accountKey}) =>
      offerVerified(list, accountKey: accountKey);

  /// The certificate of [deviceId] in any verified list seen (also a revoked
  /// device's, so its old events can still be checked up to its cutoff).
  DeviceCert? certFor(String accountId, String deviceId) =>
      _accounts[accountId]?.certs[deviceId];

  AccountDeviceList? current(String accountId) => _accounts[accountId]?.current;
  AccountFacts facts(String accountId) =>
      _accounts[accountId]?.facts ?? AccountFacts.empty;
  Set<String> revoked(String accountId) => facts(accountId).revoked;
  bool compromised(String accountId) => facts(accountId).compromised;

  /// The certificates that are effective for [entry] now: in the newest
  /// list, not revoked, not excluded, approved when the group confirms new
  /// devices; none when the account is compromised.
  List<DeviceCert> effectiveCerts(
    GroupAccountMember entry, {
    required bool confirmNewDevices,
  }) {
    final state = _accounts[entry.accountId];
    final list = state?.current;
    if (list == null || state!.facts.compromised) return const [];
    return [
      for (final cert in list.devices)
        if (cert.accountId == entry.accountId &&
            !state.facts.revoked.contains(cert.deviceId) &&
            !entry.excludedDeviceIds.contains(cert.deviceId) &&
            (!confirmNewDevices ||
                entry.approvedDeviceIds.contains(cert.deviceId)))
          cert,
    ];
  }

  /// Devices listed but waiting for approval (confirm mode).
  List<DeviceCert> pendingCerts(GroupAccountMember entry) {
    final state = _accounts[entry.accountId];
    final list = state?.current;
    if (list == null || state!.facts.compromised) return const [];
    return [
      for (final cert in list.devices)
        if (!state.facts.revoked.contains(cert.deviceId) &&
            !entry.excludedDeviceIds.contains(cert.deviceId) &&
            !entry.approvedDeviceIds.contains(cert.deviceId))
          cert,
    ];
  }

  /// Verifies and merges a cutoff for a revoked device. The signer must be a
  /// non-revoked device in the account's current list. The provisional
  /// value is the minimum over such cutoffs (a DAG checkpoint replaces it).
  Future<bool> offerCutoff(AccountCutoff cutoff) async {
    if (cutoff.groupId != groupId) return false;
    final state = _accounts[cutoff.accountId];
    final list = state?.current;
    if (list == null ||
        !state!.facts.revoked.contains(cutoff.deviceId) ||
        state.facts.revoked.contains(cutoff.signerDeviceId)) {
      return false;
    }
    final signer = list.deviceFor(cutoff.signerDeviceId);
    if (signer == null ||
        !await verifyEd25519Signature(
          publicKey: base64Decode(signer.signingKeyBase64),
          message: cutoff.signingBytes,
          signature: base64Decode(cutoff.signatureBase64),
        )) {
      return false;
    }
    final known = state.cutoffs[cutoff.deviceId];
    if (known != null &&
        (known.sequence < cutoff.sequence ||
            (known.sequence == cutoff.sequence &&
                known.eventId.compareTo(cutoff.eventId) <= 0))) {
      return false;
    }
    if (known == null && state.cutoffs.length >= maxCutoffsPerAccount) {
      return false;
    }
    state.cutoffs[cutoff.deviceId] = cutoff;
    epoch++;
    return true;
  }

  AccountCutoff? cutoffFor(String accountId, String deviceId) =>
      _accounts[accountId]?.cutoffs[deviceId];

  Iterable<AccountCutoff> get allCutoffs sync* {
    for (final state in _accounts.values) {
      yield* state.cutoffs.values;
    }
  }

  void clear() {
    _accounts.clear();
    epoch++;
  }
}

class _AccountState {
  String? key;
  final certs = <String, DeviceCert>{};
  AccountDeviceList? current;
  AccountFacts facts = AccountFacts.empty;
  final cutoffs = <String, AccountCutoff>{};
}

/// The group profile of a device as its certificate vouches for it; routes
/// and capabilities come from [announced] when its keys are the certificate's.
/// Null when the certificate's Iroh endpoint is not the hex of its signing key
/// (a membership profile must pin both).
GroupMemberProfile? profileFromCert(
  DeviceCert cert, {
  GroupMemberProfile? announced,
}) {
  final signingKey = cert.signingKeyBase64;
  final iroh = cert.irohEndpointId ?? signingKeyHex(signingKey);
  if (iroh != signingKeyHex(signingKey)) return null;
  final base =
      announced != null &&
          announced.accountId == cert.accountId &&
          announced.deviceId == cert.deviceId &&
          announced.publicKeyBase64 == cert.encryptionKeyBase64 &&
          announced.signingPublicKeyBase64 == signingKey
      ? announced
      : null;
  return GroupMemberProfile(
    accountId: cert.accountId,
    deviceId: cert.deviceId,
    displayName: base?.displayName ?? cert.name,
    bio: base?.bio ?? '',
    relayCapable: base?.relayCapable ?? true,
    publicKeyBase64: cert.encryptionKeyBase64,
    signingPublicKeyBase64: signingKey,
    irohEndpointId: iroh,
    routeHints: base?.routeHints ?? const [],
    capabilities: base?.capabilities ?? const [],
    featureCapabilities: base?.featureCapabilities ?? const [],
    featureCapabilityVersion: base?.featureCapabilityVersion ?? 0,
    carrierAddresses: base?.carrierAddresses ?? const {},
    carrierAddressesKnown: base?.carrierAddressesKnown ?? false,
  );
}

/// A group with the devices of its member accounts resolved.
class GroupResolution {
  const GroupResolution({
    required this.group,
    required this.unverifiedDeviceIds,
    required this.pendingDeviceIds,
    required this.compromisedAccountIds,
  });

  final GroupRecord group;

  /// Certificates ignored because their device id belongs to another
  /// identity this device knows.
  final List<String> unverifiedDeviceIds;

  /// Devices waiting for approval (confirm mode).
  final List<String> pendingDeviceIds;

  /// Accounts that have no effective device here (fork detected).
  final List<String> compromisedAccountIds;
}

/// Builds the group this device acts on: the signed record plus the effective
/// devices of its member accounts that the record does not project, minus
/// projected devices that are no longer effective (revoked, unlisted,
/// compromised). Pure given its inputs; never read by record validation.
///
/// [conflictsWithKnownIdentity] tells whether a device id belongs to an
/// identity this device already knows with other keys (a contact, itself):
/// such a certificate is ignored, never merged.
GroupResolution resolveGroup(
  GroupRecord signed,
  DeviceListView view, {
  bool Function(String deviceId, DeviceCert cert)? conflictsWithKnownIdentity,
  Map<String, GroupMemberProfile> announces = const {},
}) {
  if (signed.memberAccounts.isEmpty) {
    return GroupResolution(
      group: signed.siblingProfiles.isEmpty &&
              signed.suppressedDeviceIds.isEmpty
          ? signed
          : signed.copyWith(
              siblingProfiles: const [],
              suppressedDeviceIds: const [],
            ),
      unverifiedDeviceIds: const [],
      pendingDeviceIds: const [],
      compromisedAccountIds: const [],
    );
  }
  final projected = signed.memberDeviceIds.toSet();
  final siblings = <GroupMemberProfile>[];
  final suppressed = <String>[];
  final unverified = <String>[];
  final pending = <String>[];
  final compromised = <String>[];
  final claimed = <String, String>{};
  for (final entry in signed.memberAccounts) {
    // Nothing known about this account yet: the signed projection stands.
    if (view.current(entry.accountId) == null) continue;
    final isCompromised = view.compromised(entry.accountId);
    if (isCompromised) compromised.add(entry.accountId);
    final effective = view.effectiveCerts(
      entry,
      confirmNewDevices: signed.confirmNewDevices,
    );
    final effectiveIds = {for (final cert in effective) cert.deviceId};
    // Projected devices of this account that stopped being effective.
    for (final profile in signed.memberProfiles) {
      if (profile.accountId == entry.accountId &&
          !effectiveIds.contains(profile.deviceId)) {
        suppressed.add(profile.deviceId);
      }
    }
    for (final cert in effective) {
      final owner = claimed[cert.deviceId];
      if (owner != null && owner != entry.accountId) {
        // Two accounts claim one device id: effective for neither.
        suppressed.add(cert.deviceId);
        siblings.removeWhere((profile) => profile.deviceId == cert.deviceId);
        continue;
      }
      claimed[cert.deviceId] = entry.accountId;
      if (projected.contains(cert.deviceId)) continue;
      if (conflictsWithKnownIdentity?.call(cert.deviceId, cert) ?? false) {
        unverified.add(cert.deviceId);
        continue;
      }
      final profile = profileFromCert(cert, announced: announces[cert.deviceId]);
      if (profile == null) {
        unverified.add(cert.deviceId);
        continue;
      }
      siblings.add(profile);
    }
    if (signed.confirmNewDevices) {
      for (final cert in view.pendingCerts(entry)) {
        if (!projected.contains(cert.deviceId)) pending.add(cert.deviceId);
      }
    }
  }
  return GroupResolution(
    group: signed.copyWith(
      siblingProfiles: siblings,
      suppressedDeviceIds: suppressed,
    ),
    unverifiedDeviceIds: unverified,
    pendingDeviceIds: pending,
    compromisedAccountIds: compromised,
  );
}
