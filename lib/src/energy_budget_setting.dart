/// What the user lets the app spend (Settings -> Connectivity). Stored by
/// name; new values are appended.
enum EnergyBudgetSetting {
  /// Today's behaviour: more on mains power, less on battery.
  balanced,

  /// The minimum while discharging; more only while charging or on mains.
  eco,

  /// Treats battery like mains (battery saver still wins).
  fast;

  static EnergyBudgetSetting parse(Object? name) => values.firstWhere(
    (value) => value.name == name,
    orElse: () => EnergyBudgetSetting.balanced,
  );
}
