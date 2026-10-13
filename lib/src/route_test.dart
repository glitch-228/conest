/// A route test with a contact: a small probe on each route in turn, which
/// the contact answers, timed.
library;

import 'models.dart';

/// One route's outcome in a route test.
class RouteTestResult {
  const RouteTestResult({
    required this.label,
    required this.route,
    this.roundTrip,
    this.stored = false,
  });

  /// The route as the route list names it.
  final String label;
  final MessageRoute? route;

  /// Out and back; null when no answer came in time.
  final Duration? roundTrip;

  /// Left on a relay or carrier: the answer comes once they fetch it, so
  /// silence here says nothing about the route.
  final bool stored;

  bool get answered => roundTrip != null;
}

/// The last route test with a contact.
class RouteTestReport {
  const RouteTestReport({required this.measuredAt, required this.results});

  final DateTime measuredAt;
  final List<RouteTestResult> results;
}
