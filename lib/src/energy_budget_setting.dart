/// What the user lets the app spend (Settings -> Connectivity). Stored by
/// name; new values are appended.
enum EnergyBudgetSetting {
  /// Today's behaviour: more on mains power, less on battery.
  balanced,

  /// The minimum while discharging; more only while charging or on mains.
  eco,

  /// Treats battery like mains (battery saver still wins).
  fast,

  /// Everything not needed right now is stopped (see cold_mode.dart).
  cold,

  /// The default: cold on phones and on laptops running on battery,
  /// balanced on mains power.
  automatic;

  static EnergyBudgetSetting parse(Object? name) => values.firstWhere(
    (value) => value.name == name,
    orElse: () => EnergyBudgetSetting.automatic,
  );
}
