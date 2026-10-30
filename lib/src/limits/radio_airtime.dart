/// Airtime budgets for LoRa radios (Meshtastic, MeshCore, Reticulum over
/// RNode). A radio shares one narrow channel with everyone in range, and
/// some regions cap how long a device may transmit (the duty cycle), so a
/// radio gets a byte budget per minute and its frames are paced within it.
library;

import '../transport_models.dart';
import 'network_limiter.dart';

abstract final class RadioAirtime {
  /// Used when the radio's region and preset are not known: about what
  /// Meshtastic LongFast (roughly 1 kbit/s raw) can carry at a 10 % duty
  /// cycle (the strictest common limit, EU 868 MHz sub-band g3), with half
  /// kept for other users of the channel: 1000 bits/s * 60 s / 8 * 10 % * 50 %
  /// is under 400, rounded up so a short message still fits.
  static const int defaultBytesPerMinute = 450;

  /// How long the registry lets one radio send run: the largest sealed
  /// envelope (4 KiB) takes nine minutes of the default budget, plus the
  /// wait for a frame's first turn and the pause between frames.
  static const Duration sendAttemptTimeout = Duration(minutes: 14);

  /// The most radio frames waiting for their turn.
  static const int maxQueue = 16;

  /// The budget for a radio with a raw [bitsPerSecond] rate and a regional
  /// [dutyCycle] (0 to 1; 1 where there is no cap). Half the permitted
  /// airtime is kept for other users of the channel.
  static LimiterBudget forRate({
    required String name,
    required int bitsPerSecond,
    double dutyCycle = 1,
  }) {
    final duty = dutyCycle.clamp(0.01, 1.0);
    final bytes = (bitsPerSecond / 8 * 60 * duty * 0.5).floor();
    return _budget(name, bytes < 100 ? 100 : bytes);
  }

  /// Conservative budget for [name] where nothing is known of the radio.
  static LimiterBudget conservative(String name) =>
      _budget(name, defaultBytesPerMinute);

  static LimiterBudget _budget(String name, int bytesPerMinute) =>
      LimiterBudget(
        name: name,
        costInBytes: true,
        quota: bytesPerMinute,
        window: const Duration(minutes: 1),
        maxQueue: maxQueue,
        // A queued frame may wait a few minutes for airtime.
        maxWait: const Duration(minutes: 3),
        comfortWait: const Duration(seconds: 20),
      );

  /// The budget for the carrier on [kind], null for other transports.
  ///
  /// Reticulum has an airtime budget only over a radio ([radio]); over TCP
  /// (rnsd) it is an ordinary network link.
  static LimiterBudget? forKind(TransportKind kind, {bool radio = true}) =>
      switch (kind) {
        TransportKind.meshtastic => conservative('Meshtastic'),
        TransportKind.meshCore => conservative('MeshCore'),
        TransportKind.reticulum when radio => conservative('Reticulum radio'),
        _ => null,
      };

  /// Whether a spare copy may go by radio: only while most of the budget is
  /// still free.
  static bool allowsExtraCopy(NetworkLimiter? limiter) =>
      limiter == null || (!limiter.isResting && limiter.usedShare < 0.5);
}
