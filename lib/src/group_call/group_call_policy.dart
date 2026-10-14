import 'group_call_models.dart';

class GroupCallLinkStats {
  const GroupCallLinkStats({
    required this.desktop,
    required this.mains,
    required this.metered,
    this.rttMs = 0,
    this.loss = 0,
  });
  final bool desktop;
  final bool mains;
  final bool metered;
  final int rttMs;
  final double loss;
  bool get poor => rttMs > 350 || loss > 0.10;
  Map<String, dynamic> toJson() => {
    'desktop': desktop,
    'mains': mains,
    'metered': metered,
    'rttMs': rttMs,
    'loss': loss,
  };
  factory GroupCallLinkStats.fromJson(Object? json) {
    if (json is! Map ||
        json['desktop'] is! bool ||
        json['mains'] is! bool ||
        json['metered'] is! bool ||
        json['rttMs'] is! int ||
        (json['rttMs'] as int) < 0 ||
        (json['rttMs'] as int) > 60000 ||
        json['loss'] is! num ||
        !(json['loss'] as num).isFinite ||
        (json['loss'] as num) < 0 ||
        (json['loss'] as num) > 1) {
      throw const FormatException('Invalid call link stats.');
    }
    return GroupCallLinkStats(
      desktop: json['desktop'] as bool,
      mains: json['mains'] as bool,
      metered: json['metered'] as bool,
      rttMs: json['rttMs'] as int,
      loss: (json['loss'] as num).toDouble(),
    );
  }
}

/// M25 can supply real power/network policy without changing the call protocol.
abstract interface class GroupCallLinkPolicy {
  GroupCallLinkStats localStats({
    required int measuredRttMs,
    required double measuredLoss,
  });
  int get meshLimit;
}

class DefaultGroupCallLinkPolicy implements GroupCallLinkPolicy {
  const DefaultGroupCallLinkPolicy({required this.desktop});
  final bool desktop;
  @override
  int get meshLimit => groupCallMeshLimit;
  @override
  GroupCallLinkStats localStats({
    required int measuredRttMs,
    required double measuredLoss,
  }) => GroupCallLinkStats(
    desktop: desktop,
    mains: desktop,
    metered: !desktop,
    rttMs: measuredRttMs,
    loss: measuredLoss,
  );
}
