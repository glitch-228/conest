/// How a device that already has data joins an account (chosen on the new
/// device after both codes match and the existing device has told what it
/// holds).
enum LinkMode {
  /// Both sides become the account's. Contacts both know keep the names this
  /// device gave them (when the keys are the same); this device's other
  /// contacts, chats and groups stay (the default).
  merge,

  /// This device takes the account's chats and records of the contacts both
  /// know. Its own chats with those contacts are kept in an encrypted archive
  /// inside the vault first, and removed only after a second confirmation.
  /// Contacts and groups the account lacks stay.
  replace,

  /// Needs several accounts on one device; not available yet.
  separateProfile,
}

/// Which settings the device ends up with.
enum LinkSettingsChoice { keepMine, takeAccount }

/// What the user chose, handed over as one value when the link is completed
/// (nothing about it is held on the controller before that).
class LinkChoice {
  const LinkChoice({
    this.mode = LinkMode.merge,
    this.settings = LinkSettingsChoice.keepMine,
    this.confirmReplace = false,
  });

  final LinkMode mode;
  final LinkSettingsChoice settings;

  /// The second confirmation that replacing needs.
  final bool confirmReplace;
}

/// The settings "take the account's settings" changes, and nothing else.
/// Shown to the user by these names.
enum LinkSharedSetting { autoDownload, storageReserve, irohTransferLimit }

/// One thing that exists on both sides under different names or keys, or in
/// both.
class LinkConflict {
  const LinkConflict.contact({
    required this.id,
    required this.thisName,
    required this.accountName,
  }) : isGroup = false,
       keysDiffer = false,
       thisFingerprint = '',
       accountFingerprint = '';

  const LinkConflict.group({required this.id, required this.thisName})
    : isGroup = true,
      keysDiffer = false,
      accountName = thisName,
      thisFingerprint = '',
      accountFingerprint = '';

  /// The same contact id with other keys on the two sides: this device keeps
  /// its own record, marked for verification.
  const LinkConflict.keys({
    required this.id,
    required this.thisName,
    required this.thisFingerprint,
    required this.accountFingerprint,
  }) : isGroup = false,
       keysDiffer = true,
       accountName = thisName;

  final String id;
  final bool isGroup;
  final bool keysDiffer;
  final String thisName;
  final String accountName;
  final String thisFingerprint;
  final String accountFingerprint;
}

/// Counts on both sides, and the conflicts, shown before the choice. Names
/// and conflicts exist only once the existing device sent its details (after
/// both codes matched): [detailed].
class LinkSummary {
  const LinkSummary({
    required this.thisContacts,
    required this.thisChats,
    required this.thisGroups,
    required this.thisFiles,
    required this.accountContacts,
    required this.accountChats,
    required this.accountGroups,
    required this.accountFiles,
    required this.conflicts,
    this.detailed = false,
  });

  final int thisContacts;
  final int thisChats;
  final int thisGroups;
  final int thisFiles;
  final int accountContacts;
  final int accountChats;
  final int accountGroups;
  final int accountFiles;
  final List<LinkConflict> conflicts;
  final bool detailed;
}

/// A name from another device, safe to show: control and bidirectional
/// formatting characters removed, at most 128 characters.
String cleanLinkName(String raw) {
  final buffer = StringBuffer();
  for (final rune in raw.runes) {
    final control = rune < 0x20 || (rune >= 0x7f && rune <= 0x9f);
    final bidi =
        rune == 0x061c ||
        rune == 0x200e ||
        rune == 0x200f ||
        (rune >= 0x202a && rune <= 0x202e) ||
        (rune >= 0x2066 && rune <= 0x2069) ||
        rune == 0x200b ||
        rune == 0xfeff ||
        rune == 0x2028 ||
        rune == 0x2029;
    if (control || bidi) continue;
    buffer.writeCharCode(rune);
    if (buffer.length >= 128) break;
  }
  return buffer.toString().trim();
}
