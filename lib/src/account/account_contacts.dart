/// How a contact's account statement (their account key and device list)
/// is checked before this device believes it (M29).
library;

import 'account_model.dart';

/// A statement that passed every check: the account key to keep and the
/// device list to apply.
class AccountDevicesUpdate {
  const AccountDevicesUpdate({
    required this.accountKeyBase64,
    required this.list,
    this.revocationsOnly = false,
  });

  final String accountKeyBase64;
  final AccountDeviceList list;

  /// An older (or equal) version that only adds revocations: apply those,
  /// nothing else. A revocation must get through even when a stolen device
  /// published lists with higher versions first.
  final bool revocationsOnly;
}

/// How far one statement may move the version ahead of what this device
/// knows: a stolen device cannot jump so far that the owner's lists can
/// never catch up.
const int maxDeviceListVersionStep = 16;

/// Checks [payload] ({"upgrade": …, "devices": …}), which came inside an
/// authenticated exchange from one of a contact's devices, against what
/// this device already knows of that contact (its main record).
///
/// - The account key is learned once, from an upgrade signed by the main
///   device's pinned signing key and the account key; after that it never
///   changes here. Without a pinned key the upgrade is believed only from
///   the main device itself ([fromAnchor]).
/// - The list must be the account's, signed by that key, list the main
///   device, be newer than [knownVersion] and keep every revocation.
///
/// Returns null when the statement is to be ignored (stale, or not
/// authentic).
Future<AccountDevicesUpdate?> verifyAccountDevices({
  required String accountId,
  required String anchorDeviceId,
  required String? anchorSigningKeyBase64,
  required String? knownAccountKeyBase64,
  required int knownVersion,
  required List<String> knownRevoked,
  required bool fromAnchor,
  required Object? payload,
}) async {
  if (payload is! Map) return null;
  final list = AccountDeviceList.fromJson(payload['devices']);
  if (list == null ||
      list.accountId != accountId ||
      !knownRevoked.every(list.revoked.containsKey) ||
      list.deviceFor(anchorDeviceId) == null) {
    return null;
  }
  final revocationsOnly = list.version <= knownVersion;
  if (revocationsOnly) {
    // Only worth anything if it revokes something not yet revoked here.
    if (knownAccountKeyBase64 == null ||
        list.revoked.keys.every(knownRevoked.contains)) {
      return null;
    }
  } else if (knownVersion > 0 &&
      list.version > knownVersion + maxDeviceListVersionStep) {
    return null;
  }
  var accountKey = knownAccountKeyBase64;
  if (accountKey == null) {
    final upgrade = AccountUpgrade.fromJson(payload['upgrade']);
    if (upgrade == null) return null;
    final pinned = anchorSigningKeyBase64;
    if (pinned == null && !fromAnchor) return null;
    if (!await upgrade.verify(
      accountId: accountId,
      deviceId: anchorDeviceId,
      pinnedDeviceSigningKeyBase64: pinned ?? upgrade.deviceSigningKeyBase64,
    )) {
      return null;
    }
    accountKey = upgrade.accountKeyBase64;
  }
  // The main device's certificate must carry the keys this contact pinned.
  final anchorCert = list.deviceFor(anchorDeviceId)!;
  if (anchorSigningKeyBase64 != null &&
      anchorCert.signingKeyBase64 != anchorSigningKeyBase64) {
    return null;
  }
  if (!await list.verify(accountKey)) return null;
  return AccountDevicesUpdate(
    accountKeyBase64: accountKey,
    list: list,
    revocationsOnly: revocationsOnly,
  );
}
