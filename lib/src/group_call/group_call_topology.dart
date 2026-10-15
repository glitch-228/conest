import 'group_call_models.dart';
import 'group_call_policy.dart';

/// All clients use the same bounded stats snapshot. The coordinator publishes
/// the snapshot and result together; receivers recompute the result before
/// accepting it, so arrival order of individual stats cannot split election.
String? electGroupCallForwarder(
  List<GroupCallParticipant> participants,
  Map<String, GroupCallLinkStats> stats,
) {
  if (participants.isEmpty) return null;
  const unknown = GroupCallLinkStats(
    desktop: false,
    mains: false,
    metered: true,
    rttMs: 60000,
    loss: 1,
  );
  final ids = participants.map((p) => p.deviceId).toList();
  // Exclude degraded links when a healthy alternative exists.
  final healthy = ids.where((id) => !(stats[id] ?? unknown).poor).toList();
  final candidates = healthy.isEmpty ? ids : healthy;
  candidates.sort((a, b) {
    final x = stats[a] ?? unknown;
    final y = stats[b] ?? unknown;
    for (final order in [
      (y.desktop ? 1 : 0).compareTo(x.desktop ? 1 : 0),
      (y.mains ? 1 : 0).compareTo(x.mains ? 1 : 0),
      (x.metered ? 1 : 0).compareTo(y.metered ? 1 : 0),
      x.rttMs.compareTo(y.rttMs),
      x.loss.compareTo(y.loss),
      a.compareTo(b),
    ]) {
      if (order != 0) return order;
    }
    return 0;
  });
  return candidates.first;
}

Map<String, GroupCallLinkStats> parseGroupCallStatsSnapshot(
  Object? json,
  List<GroupCallParticipant> participants,
) {
  if (json is! Map || json.length > groupCallMaxParticipants) {
    throw const FormatException('Invalid call stats snapshot.');
  }
  final result = <String, GroupCallLinkStats>{};
  for (final entry in json.entries) {
    if (entry.key is! String ||
        !participants.any((p) => p.deviceId == entry.key)) {
      throw const FormatException('Unknown call stats participant.');
    }
    result[entry.key as String] = GroupCallLinkStats.fromJson(entry.value);
  }
  return result;
}
