import 'dart:convert';

import 'package:crypto/crypto.dart';

/// How well one own device reaches a target (a contact, a group, a radio
/// node), as that device itself reports it to the account's other devices.
class RouteScore {
  const RouteScore({
    this.heardAgo,
    this.direct = false,
    this.rttMs,
    this.mains = false,
    this.desktop = false,
    this.metered = false,
  });

  /// How long ago the target was last heard from through this device;
  /// null when never (or not lately).
  final Duration? heardAgo;

  /// A direct path (LAN, or direct Iroh) is open now.
  final bool direct;
  final double? rttMs;
  final bool mains;
  final bool desktop;
  final bool metered;

  /// Heard from lately enough to count as in reach.
  static const Duration reachWindow = Duration(minutes: 15);

  bool get inReach => heardAgo != null && heardAgo! <= reachWindow;

  Map<String, Object> toJson() => {
    if (heardAgo != null) 'heard': heardAgo!.inSeconds,
    if (direct) 'direct': true,
    if (rttMs != null) 'rtt': rttMs!.round(),
    if (mains) 'mains': true,
    if (desktop) 'desktop': true,
    if (metered) 'metered': true,
  };

  /// Reads a score from another device: bounded, and a lie can only make
  /// that device look better or worse for itself.
  static RouteScore fromJson(Object? json) {
    if (json is! Map) return const RouteScore();
    int? seconds(Object? v) =>
        v is int && v >= 0 && v < 30 * 24 * 3600 ? v : null;
    final heard = seconds(json['heard']);
    final rtt = json['rtt'];
    return RouteScore(
      heardAgo: heard == null ? null : Duration(seconds: heard),
      direct: json['direct'] == true,
      rttMs: rtt is int && rtt >= 0 && rtt < 600000 ? rtt.toDouble() : null,
      mains: json['mains'] == true,
      desktop: json['desktop'] == true,
      metered: json['metered'] == true,
    );
  }
}

/// The own devices best placed to handle [target], best first: those in
/// reach before those not, then a direct path, a quicker one, mains power,
/// a desktop, an unmetered network, and last a hash of the target and the
/// device (so the tie breaks the same on every device, and differently
/// for different targets, spreading the load).
List<String> rankGateways(String target, Map<String, RouteScore> scores) {
  int tie(String id) => sha256
      .convert(utf8.encode('$target|$id'))
      .bytes
      .take(4)
      .fold(0, (a, b) => a << 8 | b);
  final ids = scores.keys.toList()
    ..sort((a, b) {
      final x = scores[a]!;
      final y = scores[b]!;
      for (final order in [
        (y.inReach ? 1 : 0).compareTo(x.inReach ? 1 : 0),
        (y.direct ? 1 : 0).compareTo(x.direct ? 1 : 0),
        (x.rttMs ?? 1e9).compareTo(y.rttMs ?? 1e9),
        (y.mains ? 1 : 0).compareTo(x.mains ? 1 : 0),
        (y.desktop ? 1 : 0).compareTo(x.desktop ? 1 : 0),
        (x.metered ? 1 : 0).compareTo(y.metered ? 1 : 0),
        tie(a).compareTo(tie(b)),
        a.compareTo(b),
      ]) {
        if (order != 0) return order;
      }
      return 0;
    });
  return ids;
}

/// The gateway for [target]: the best ranked, but [current] stays while it
/// is still in reach and no better placed device is *more than* a step
/// ahead (a device in reach never gives way to one that is not; between
/// two in reach, the one on a direct path is not displaced by a mere
/// tie-break), so the choice does not flap.
String? electGateway(
  String target,
  Map<String, RouteScore> scores, {
  String? current,
}) {
  if (scores.isEmpty) return null;
  final ranked = rankGateways(target, scores);
  final best = ranked.first;
  final held = current == null ? null : scores[current];
  if (held == null || current == best) return best;
  final top = scores[best]!;
  // Keep the current one unless the best is better in reach or path.
  final worse =
      (top.inReach && !held.inReach) ||
      (top.direct && !held.direct && top.inReach);
  return worse ? best : current;
}

/// How long [deviceId] waits before passing on a message from [target], by
/// its place in [ranked]: the first at once, each next [step] later, to
/// [cap]. A device that is not ranked waits the longest.
Duration passOnDelay(
  String deviceId,
  List<String> ranked, {
  Duration step = const Duration(seconds: 2),
  Duration cap = const Duration(seconds: 15),
}) {
  final index = ranked.indexOf(deviceId);
  final place = index < 0 ? ranked.length : index;
  final delay = step * place;
  return delay > cap ? cap : delay;
}
