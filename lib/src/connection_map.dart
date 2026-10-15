/// Who reaches whom (M42): this device's links to the devices it knows,
/// and what other devices report of theirs, for the Connections screen.
library;

/// How a link between two devices fares.
enum LinkStatus {
  /// Both ways, recently.
  twoWay,

  /// Something came from them lately, but nothing went back and forth.
  inboundOnly,

  /// Tried lately, and it failed.
  failing,

  /// Nothing recent either way.
  unknown;

  static LinkStatus? tryParse(Object? value) {
    for (final status in values) {
      if (status.name == value) return status;
    }
    return null;
  }
}

/// One link someone reported.
class ReportedLink {
  const ReportedLink({required this.status, required this.at});

  final LinkStatus status;
  final DateTime at;
}

class ConnectionMap {
  const ConnectionMap({
    required this.self,
    required this.mine,
    required this.reported,
    this.names = const {},
  });

  /// This device's id.
  final String self;

  /// This device → each device it knows.
  final Map<String, LinkStatus> mine;

  /// Reporter → device → how the reporter's link to it fares.
  final Map<String, Map<String, ReportedLink>> reported;

  /// Device id → a name to show.
  final Map<String, String> names;

  String nameOf(String deviceId) =>
      deviceId == self ? 'This device' : names[deviceId] ?? deviceId;

  /// Every device on the map.
  Set<String> get devices => {
    self,
    ...mine.keys,
    ...reported.keys,
    for (final links in reported.values) ...links.keys,
  };
}
