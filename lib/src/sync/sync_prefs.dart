/// What this device wants to sync with the account's other devices (M33):
/// a mode, an amount per category, how far back, and whether media and
/// files may use mobile data. Persisted by name, append only; a name this
/// build does not know is never guessed at: an amount that is not known is
/// off.
library;

/// How a device syncs as a whole. `custom` is what any edit of a category
/// makes of a preset. Persisted by name: append only.
enum OwnDeviceSyncMode { full, contactsOnly, independent, custom }

/// What is synced. Saved is its own category, so it can be synced in full
/// while contacts stay limited. Persisted by name: append only.
enum SyncCategory { messages, media, files, contacts, settings, saved }

/// How much of a category. `recent` is the last window of days (and a few
/// hundred per chat); for media and files it means bytes fetched by
/// themselves inside the window. `off` for media and files still shows the
/// details of a file. Persisted by name: append only.
enum SyncAmount { off, recent, all }

class OwnDeviceSyncPrefs {
  OwnDeviceSyncPrefs({
    required this.mode,
    required Map<SyncCategory, SyncAmount> categories,
    this.windowDays = defaultWindowDays,
    this.mobileData = false,
  }) : categories = Map.unmodifiable({
         for (final category in SyncCategory.values)
           category: categories[category] ?? SyncAmount.off,
       });

  /// The windows on offer: the last week, month or three months.
  static const List<int> windowChoices = [7, 30, 90];
  static const int defaultWindowDays = 30;

  final OwnDeviceSyncMode mode;
  final Map<SyncCategory, SyncAmount> categories;
  final int windowDays;

  /// Media and files may use a metered network (messages always may).
  final bool mobileData;

  /// What a vault without the field means: what the app did before: the
  /// last 30 days of chats and all of Saved, no bytes of files fetched by
  /// themselves, and the other devices' contacts and settings as the
  /// account's own switches say.
  static final OwnDeviceSyncPrefs legacy = OwnDeviceSyncPrefs(
    mode: OwnDeviceSyncMode.custom,
    categories: const {
      SyncCategory.messages: SyncAmount.recent,
      SyncCategory.contacts: SyncAmount.all,
      SyncCategory.settings: SyncAmount.all,
      SyncCategory.saved: SyncAmount.all,
    },
  );

  factory OwnDeviceSyncPrefs.forMode(OwnDeviceSyncMode mode) => switch (mode) {
    OwnDeviceSyncMode.full => OwnDeviceSyncPrefs(
      mode: mode,
      categories: const {
        SyncCategory.messages: SyncAmount.recent,
        SyncCategory.media: SyncAmount.recent,
        SyncCategory.files: SyncAmount.recent,
        SyncCategory.contacts: SyncAmount.all,
        SyncCategory.settings: SyncAmount.all,
        SyncCategory.saved: SyncAmount.all,
      },
    ),
    OwnDeviceSyncMode.contactsOnly => OwnDeviceSyncPrefs(
      mode: mode,
      categories: const {
        SyncCategory.contacts: SyncAmount.all,
        SyncCategory.settings: SyncAmount.all,
      },
    ),
    OwnDeviceSyncMode.independent => OwnDeviceSyncPrefs(
      mode: mode,
      categories: const {},
    ),
    OwnDeviceSyncMode.custom => legacy,
  };

  SyncAmount amount(SyncCategory category) =>
      categories[category] ?? SyncAmount.off;

  bool allows(SyncCategory category) => amount(category) != SyncAmount.off;

  OwnDeviceSyncPrefs withMode(OwnDeviceSyncMode next) => next == mode
      ? this
      : next == OwnDeviceSyncMode.custom
      ? OwnDeviceSyncPrefs(
          mode: next,
          categories: categories,
          windowDays: windowDays,
          mobileData: mobileData,
        )
      : OwnDeviceSyncPrefs(
          mode: next,
          categories: OwnDeviceSyncPrefs.forMode(next).categories,
          windowDays: windowDays,
          mobileData: mobileData,
        );

  /// Any change to one category leaves the presets: the mode is custom.
  OwnDeviceSyncPrefs withCategory(SyncCategory category, SyncAmount amount) =>
      OwnDeviceSyncPrefs(
        mode: OwnDeviceSyncMode.custom,
        categories: {...categories, category: amount},
        windowDays: windowDays,
        mobileData: mobileData,
      );

  OwnDeviceSyncPrefs withWindowDays(int days) => OwnDeviceSyncPrefs(
    mode: mode,
    categories: categories,
    windowDays: _nearestWindow(days),
    mobileData: mobileData,
  );

  OwnDeviceSyncPrefs withMobileData(bool allowed) => OwnDeviceSyncPrefs(
    mode: mode,
    categories: categories,
    windowDays: windowDays,
    mobileData: allowed,
  );

  static int _nearestWindow(int days) {
    var best = windowChoices.first;
    for (final choice in windowChoices) {
      if ((choice - days).abs() < (best - days).abs()) best = choice;
    }
    return best;
  }

  /// What goes in the vault: null when it is the default, so a vault that
  /// never chose reads and writes as before.
  Map<String, Object?>? toJson() => this == legacy ? null : toWire();

  /// What goes to the other devices (`prefs`).
  Map<String, Object?> toWire() => {
    'mode': mode.name,
    'cats': {
      for (final category in SyncCategory.values)
        category.name: amount(category).name,
    },
    'windowDays': windowDays,
    if (mobileData) 'mobileData': true,
  };

  /// Null for what is not a map of prefs. Names this build does not know
  /// are skipped; a category that is missing or has an amount it does not
  /// know is off.
  static OwnDeviceSyncPrefs? fromJson(Object? json) {
    if (json is! Map) return null;
    final cats = json['cats'];
    if (cats != null && cats is! Map) return null;
    final mode = OwnDeviceSyncMode.values
        .where((value) => value.name == json['mode'])
        .firstOrNull;
    final days = json['windowDays'];
    return OwnDeviceSyncPrefs(
      mode: mode ?? OwnDeviceSyncMode.custom,
      categories: {
        for (final category in SyncCategory.values)
          category:
              SyncAmount.values
                  .where(
                    (value) => cats is Map && value.name == cats[category.name],
                  )
                  .firstOrNull ??
              SyncAmount.off,
      },
      windowDays: days is int ? _nearestWindow(days) : defaultWindowDays,
      mobileData: json['mobileData'] == true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is OwnDeviceSyncPrefs &&
      other.mode == mode &&
      other.windowDays == windowDays &&
      other.mobileData == mobileData &&
      SyncCategory.values.every(
        (category) => other.amount(category) == amount(category),
      );

  @override
  int get hashCode => Object.hash(
    mode,
    windowDays,
    mobileData,
    Object.hashAll([for (final c in SyncCategory.values) amount(c)]),
  );
}

/// What two devices may sync with each other: for each category the
/// smaller of what this device and the other want. A device that has not
/// said what it wants gets what the app did before it could say.
class OwnDeviceScope {
  OwnDeviceScope({required this.mine, OwnDeviceSyncPrefs? theirs})
    : theirs = theirs ?? OwnDeviceSyncPrefs.legacy;

  final OwnDeviceSyncPrefs mine;
  final OwnDeviceSyncPrefs theirs;

  SyncAmount amount(SyncCategory category) {
    final a = mine.amount(category);
    final b = theirs.amount(category);
    return a.index <= b.index ? a : b;
  }

  bool allows(SyncCategory category) => amount(category) != SyncAmount.off;

  /// How far back [category] goes: none at all (zero) when off, no limit
  /// (null) when all on both sides, otherwise the shorter window of the
  /// sides that have one.
  Duration? windowFor(SyncCategory category) {
    switch (amount(category)) {
      case SyncAmount.off:
        return Duration.zero;
      case SyncAmount.all:
        return null;
      case SyncAmount.recent:
        final days = [
          if (mine.amount(category) == SyncAmount.recent) mine.windowDays,
          if (theirs.amount(category) == SyncAmount.recent) theirs.windowDays,
        ];
        return Duration(days: days.reduce((a, b) => a < b ? a : b));
    }
  }
}

/// The category an own-device sync event belongs to, or null for what is
/// bookkeeping and goes whatever the categories say (reach, prefs, who has
/// which file: the categories decide whether bytes are fetched by
/// themselves, not whether devices say what they hold). [chat] is the
/// event's chat, when it has one: Saved is its own.
SyncCategory? categoryOfSyncEvent(String type, Object? chat) {
  switch (type) {
    case 'sent' || 'state' || 'read' || 'history_page' || 'history_wait':
      return chat == 'saved' ? SyncCategory.saved : SyncCategory.messages;
    case 'rx' ||
        'group_state' ||
        'group_message' ||
        'gtx' ||
        'tgx' ||
        'history_req':
      return SyncCategory.messages;
    case 'settings' || 'settings2':
      return SyncCategory.settings;
  }
  return null;
}
