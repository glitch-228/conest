/// How a device that already has data joins an account (chosen on the new
/// device after both codes match).
enum LinkMode {
  /// Both sides become the account's; conflicts keep this device's names
  /// unless the user picks the account's (the default).
  merge,

  /// Like [merge], with this device's names and settings winning.
  bringMine,

  /// This device takes the account's data; its own chats are archived to a
  /// file first and removed only after a second confirmation.
  replace,

  /// Needs several accounts on one device; not available yet.
  separateProfile,
}

/// Which settings the device ends up with.
enum LinkSettingsChoice { keepMine, takeAccount }

/// One thing that exists on both sides under different names, or in both.
class LinkConflict {
  const LinkConflict.contact({
    required this.id,
    required this.thisName,
    required this.accountName,
  }) : isGroup = false;

  const LinkConflict.group({required this.id, required this.thisName})
    : isGroup = true,
      accountName = thisName;

  final String id;
  final bool isGroup;
  final String thisName;
  final String accountName;
}

/// Counts on both sides, and the conflicts, shown before the choice.
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
}
