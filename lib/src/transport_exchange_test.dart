/// A full transport test with a contact (debug builds, Q6): each side
/// probes every route to the other and reports back over a route that
/// works, so both directions of each route are known.
library;

import 'dart:convert';

import 'route_test.dart';

/// How a route family fares in both directions.
enum RouteDirections {
  /// Probes went and came back both ways.
  twoWay,

  /// Only from this device to them.
  outboundOnly,

  /// Only from them to this device.
  inboundOnly,

  /// Left on a relay or carrier (either way), no answer yet: says nothing.
  stored,

  /// Tried, no answer either way.
  failing,

  /// Only one side has it at all.
  oneSided,
}

/// One side's results, as sent between the devices.
class TransportTestSide {
  const TransportTestSide({
    required this.deviceId,
    required this.results,
    this.inventory = const [],
    this.errors = const [],
  });

  final String deviceId;

  /// Route family (MessageRoute name, or the label when unknown) →
  /// (answered in ms, stored).
  final Map<String, ({int? roundTripMs, bool stored, String label})> results;

  /// What the side has: routes, carriers, settings (lines of text).
  final List<String> inventory;

  /// Its recent errors about the other side.
  final List<String> errors;

  static const int maxLines = 64;
  static const int maxLineChars = 400;

  static TransportTestSide fromReport(
    String deviceId,
    RouteTestReport report, {
    List<String> inventory = const [],
    List<String> errors = const [],
  }) => TransportTestSide(
    deviceId: deviceId,
    results: {
      for (final result in report.results)
        (result.route?.family.name ?? result.label): (
          roundTripMs: result.roundTrip?.inMilliseconds,
          stored: result.stored,
          label: result.label,
        ),
    },
    inventory: inventory,
    errors: errors,
  );

  Map<String, Object?> toJson() => {
    'deviceId': deviceId,
    'results': [
      for (final MapEntry(key: family, value: result) in results.entries)
        {
          'family': family,
          'label': result.label,
          if (result.roundTripMs != null) 'ms': result.roundTripMs,
          if (result.stored) 'stored': true,
        },
    ],
    'inventory': inventory,
    'errors': errors,
  };

  static List<String> _lines(Object? raw) => [
    if (raw is List)
      for (final line in raw.take(maxLines))
        if (line is String)
          line.length > maxLineChars ? line.substring(0, maxLineChars) : line,
  ];

  static TransportTestSide? fromJson(Object? json) {
    if (json is! Map) return null;
    final deviceId = json['deviceId'];
    final raw = json['results'];
    if (deviceId is! String || raw is! List) return null;
    final results = <String, ({int? roundTripMs, bool stored, String label})>{};
    for (final item in raw.take(maxLines)) {
      if (item is! Map) continue;
      final family = item['family'];
      final label = item['label'];
      final ms = item['ms'];
      if (family is! String || family.length > 64 || label is! String) {
        continue;
      }
      results[family] = (
        roundTripMs: ms is int && ms >= 0 ? ms : null,
        stored: item['stored'] == true,
        label: label.length > 160 ? label.substring(0, 160) : label,
      );
    }
    return TransportTestSide(
      deviceId: deviceId,
      results: results,
      inventory: _lines(json['inventory']),
      errors: _lines(json['errors']),
    );
  }
}

/// Both sides of a full transport test.
class TransportExchangeReport {
  const TransportExchangeReport({
    required this.measuredAt,
    required this.local,
    this.remote,
    this.remoteError,
  });

  final DateTime measuredAt;
  final TransportTestSide local;

  /// Their side; null when it did not come back.
  final TransportTestSide? remote;
  final String? remoteError;

  /// Each route family and how it fares.
  Map<String, RouteDirections> get directions {
    final families = {...local.results.keys, ...?remote?.results.keys};
    return {
      for (final family in families)
        family: _directionsOf(local.results[family], remote?.results[family]),
    };
  }

  static RouteDirections _directionsOf(
    ({int? roundTripMs, bool stored, String label})? out,
    ({int? roundTripMs, bool stored, String label})? back,
  ) {
    if (out == null || back == null) return RouteDirections.oneSided;
    final outOk = out.roundTripMs != null;
    final backOk = back.roundTripMs != null;
    if (outOk && backOk) return RouteDirections.twoWay;
    if (outOk) return RouteDirections.outboundOnly;
    if (backOk) return RouteDirections.inboundOnly;
    if (out.stored || back.stored) return RouteDirections.stored;
    return RouteDirections.failing;
  }

  Map<String, Object?> toJson() => {
    'measuredAt': measuredAt.toUtc().toIso8601String(),
    'local': local.toJson(),
    if (remote != null) 'remote': remote!.toJson(),
    if (remoteError != null) 'remoteError': remoteError,
    'directions': {
      for (final MapEntry(key: family, value: how) in directions.entries)
        family: how.name,
    },
  };

  String toText() {
    final lines = <String>[
      'Transport test ${measuredAt.toUtc().toIso8601String()}',
      'this device ${local.deviceId}, them ${remote?.deviceId ?? '(no report)'}',
      if (remoteError != null) 'their side: $remoteError',
      for (final MapEntry(key: family, value: how) in directions.entries)
        '  $family: ${how.name}'
            '${_ms(' out', local.results[family]?.roundTripMs)}'
            '${_ms(' back', remote?.results[family]?.roundTripMs)}',
      if (local.inventory.isNotEmpty) 'this device has:',
      for (final line in local.inventory) '  $line',
      if (remote?.inventory.isNotEmpty ?? false) 'they have:',
      for (final line in remote?.inventory ?? const <String>[]) '  $line',
      if (local.errors.isNotEmpty) 'errors here:',
      for (final line in local.errors) '  $line',
      if (remote?.errors.isNotEmpty ?? false) 'errors there:',
      for (final line in remote?.errors ?? const <String>[]) '  $line',
    ];
    return lines.join('\n');
  }

  static String _ms(String label, int? ms) =>
      ms == null ? '' : '$label ${ms}ms';

  String toJsonText() => const JsonEncoder.withIndent('  ').convert(toJson());
}
