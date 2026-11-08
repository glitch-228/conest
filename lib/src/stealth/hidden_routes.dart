import '../models.dart';

/// The configured route a hidden address [announced] by a relay replaces
/// (M38 S0): the route of the same kind (wss or borrowed) at the same host
/// and port, pinned to the same identity [identityKey], that names another
/// secret path or site. A route key does not include the path or site name,
/// so without this an operator who rotates the path or changes the borrowed
/// site is never followed: the old name stays in the list to fail. A route
/// pinned to another identity (or to none) is never touched: it is another
/// relay's. Null: nothing to replace.
PeerEndpoint? replacedHiddenRoute({
  required Iterable<PeerEndpoint> relays,
  required PeerEndpoint announced,
  required String identityKey,
  required Map<String, String> pins,
}) {
  for (final relay in relays) {
    if (isHiddenRouteProtocol(relay.protocol) &&
        relay.routeKey == announced.routeKey &&
        relay.path != announced.path &&
        pins[relay.routeKey] == identityKey) {
      return relay;
    }
  }
  return null;
}
