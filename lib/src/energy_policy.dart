/// How much sending this device can afford right now: on mains power and an
/// unmetered network a message goes out on every route at once; on battery
/// one route more every few seconds until a receipt comes; in battery saver
/// one route at a time, as before.
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'energy_budget_setting.dart';
import 'models.dart';

export 'energy_budget_setting.dart';

enum EnergyMode {
  /// Mains power (or no battery) and an unmetered network.
  unconstrained,

  /// On battery, or on a metered network.
  limited,

  /// Battery saver on, or the battery low and not charging.
  saver,
}

/// The power side of the device. Unknown values are null.
class PowerState {
  const PowerState({
    this.hasBattery,
    this.charging,
    this.batteryPercent,
    this.batterySaver = false,
  });

  /// False on desktops without a battery.
  final bool? hasBattery;

  /// On mains power (charging or full).
  final bool? charging;
  final int? batteryPercent;
  final bool batterySaver;

  static const PowerState unknown = PowerState();
}

/// Where [PowerState] comes from on this platform.
abstract interface class PowerStateSource {
  Future<PowerState> read();
}

/// What the device may do right now, from the setting and the power state.
class EnergyBudget {
  const EnergyBudget({
    required this.maxActiveTransports,
    required this.pollFactor,
    required this.maxExtraCopies,
    required this.hedgedBlocks,
  });

  /// How many transports stay up at once; null for no limit.
  final int? maxActiveTransports;

  /// Poll and keep-alive intervals are this many times the normal ones.
  final int pollFactor;

  /// Extra carriers that copy a message after the first route took it.
  final int maxExtraCopies;

  /// Whether a late file block may also go on a second route.
  final bool hedgedBlocks;

  /// Mains power and the setting does not restrain it.
  static const EnergyBudget full = EnergyBudget(
    maxActiveTransports: null,
    pollFactor: 1,
    maxExtraCopies: 4,
    hedgedBlocks: true,
  );

  /// On battery or a metered network, balanced.
  static const EnergyBudget reduced = EnergyBudget(
    maxActiveTransports: null,
    pollFactor: 2,
    maxExtraCopies: 4,
    hedgedBlocks: true,
  );

  /// Eco while discharging: LAN, Iroh and one relay subscription; carriers
  /// only as fallback (no copies); long intervals; no hedging.
  static const EnergyBudget eco = EnergyBudget(
    maxActiveTransports: 3,
    pollFactor: 6,
    maxExtraCopies: 0,
    hedgedBlocks: false,
  );

  /// Battery saver: the strictest.
  static const EnergyBudget saver = EnergyBudget(
    maxActiveTransports: 2,
    pollFactor: 8,
    maxExtraCopies: 0,
    hedgedBlocks: false,
  );
}

/// How a message goes out on several routes.
sealed class MessageFanout {
  const MessageFanout();
}

/// One route, then the next only when it fails (the old behaviour).
class SingleRouteFanout extends MessageFanout {
  const SingleRouteFanout();
}

/// Every eligible route straight away.
class AllRoutesFanout extends MessageFanout {
  const AllRoutesFanout();
}

/// The best route first, then one more every [interval] while no receipt
/// has come.
class EscalatingFanout extends MessageFanout {
  const EscalatingFanout(this.interval);
  final Duration interval;
}

class EnergyPolicy {
  EnergyPolicy({
    PowerStateSource? source,
    this.escalateInterval = const Duration(milliseconds: 2500),
    this.maxGroupAllAtOnce = 8,
    Duration refreshEvery = const Duration(minutes: 1),
    DateTime Function()? now,
    EnergyMode? fixedMode,
  }) : _source = source ?? platformPowerStateSource(),
       _refreshEvery = refreshEvery,
       _now = now ?? DateTime.now,
       _fixedMode = fixedMode;

  /// A policy that always answers [mode] (tests, and platforms without a
  /// power reading).
  factory EnergyPolicy.fixed(
    EnergyMode mode, {
    Duration escalateInterval = const Duration(milliseconds: 2500),
  }) => EnergyPolicy(
    source: const _FixedPowerSource(),
    fixedMode: mode,
    escalateInterval: escalateInterval,
  );

  final PowerStateSource _source;
  final Duration escalateInterval;

  /// The user's choice. With a [settingSource] (the controller's) it is read
  /// from there every time, so it is never stale.
  EnergyBudgetSetting get setting => settingSource?.call() ?? _setting;
  set setting(EnergyBudgetSetting value) => _setting = value;
  EnergyBudgetSetting _setting = EnergyBudgetSetting.balanced;
  EnergyBudgetSetting Function()? settingSource;

  /// Larger groups escalate even when the device can afford more: every
  /// copy goes to every member.
  final int maxGroupAllAtOnce;
  final Duration _refreshEvery;
  final DateTime Function() _now;
  final EnergyMode? _fixedMode;

  PowerState _power = PowerState.unknown;
  DateTime? _readAt;
  Future<void>? _reading;

  PowerState get power => _power;

  /// Reads the power state again when the last reading is old.
  Future<void> refresh({bool force = false}) {
    final readAt = _readAt;
    if (!force && readAt != null && _now().difference(readAt) < _refreshEvery) {
      return Future<void>.value();
    }
    return _reading ??= () async {
      try {
        _power = await _source.read().timeout(const Duration(seconds: 2));
      } catch (_) {
        // Keep the last reading.
      } finally {
        _readAt = _now();
        _reading = null;
      }
    }();
  }

  EnergyMode modeFor(NetworkCostClass network) {
    final fixed = _fixedMode;
    final mode = fixed ?? modeOf(_power, network);
    // Fast treats battery like mains; battery saver still wins, and a
    // metered or roaming network stays limited.
    if (setting == EnergyBudgetSetting.fast &&
        mode == EnergyMode.limited &&
        network != NetworkCostClass.metered &&
        network != NetworkCostClass.roaming) {
      return EnergyMode.unconstrained;
    }
    return mode;
  }

  /// What may be spent now. Eco restrains every state but mains power
  /// (charging, or a desktop without a battery, on an unmetered network):
  /// more only while charging.
  EnergyBudget budgetFor(NetworkCostClass network) =>
      switch (modeFor(network)) {
        EnergyMode.saver => EnergyBudget.saver,
        EnergyMode.limited =>
          setting == EnergyBudgetSetting.eco
              ? EnergyBudget.eco
              : EnergyBudget.reduced,
        EnergyMode.unconstrained => EnergyBudget.full,
      };

  /// The mode for a power reading and a network.
  static EnergyMode modeOf(PowerState power, NetworkCostClass network) {
    final percent = power.batteryPercent;
    final onBattery = power.hasBattery != false && power.charging == false;
    if (power.batterySaver || (onBattery && percent != null && percent < 20)) {
      return EnergyMode.saver;
    }
    final metered =
        network == NetworkCostClass.metered ||
        network == NetworkCostClass.roaming;
    if (metered) return EnergyMode.limited;
    // A desktop without a battery, or anything plugged in.
    if (power.hasBattery == false || power.charging == true) {
      return EnergyMode.unconstrained;
    }
    return EnergyMode.limited;
  }

  /// How a message to one contact ([groupSize] null) or to each member of
  /// a group goes out. [copiesAllowed] is false for contacts whose app
  /// cannot yet tell copies of one message apart from new messages.
  MessageFanout fanoutFor(
    NetworkCostClass network, {
    required bool copiesAllowed,
    int? groupSize,
  }) {
    if (!copiesAllowed || budgetFor(network).maxExtraCopies == 0) {
      return const SingleRouteFanout();
    }
    return switch (modeFor(network)) {
      EnergyMode.saver => const SingleRouteFanout(),
      EnergyMode.limited => EscalatingFanout(escalateInterval),
      EnergyMode.unconstrained =>
        groupSize != null && groupSize > maxGroupAllAtOnce
            ? EscalatingFanout(escalateInterval)
            : const AllRoutesFanout(),
    };
  }
}

/// The wait before another copy: no shorter than [base], and long enough
/// for the first route's measured round trip ([latencyMs]) with room to
/// spare; never over 30 s.
Duration escalationInterval(Duration base, double? latencyMs) {
  if (latencyMs == null || latencyMs.isNaN || latencyMs <= 0) return base;
  final wanted = Duration(milliseconds: (latencyMs * 1.5).round());
  const cap = Duration(seconds: 30);
  if (wanted <= base) return base;
  return wanted > cap ? cap : wanted;
}

class _FixedPowerSource implements PowerStateSource {
  const _FixedPowerSource();
  @override
  Future<PowerState> read() async => PowerState.unknown;
}

/// The power reading for the platform this runs on.
PowerStateSource platformPowerStateSource() {
  if (Platform.isLinux) return LinuxPowerStateSource();
  if (Platform.isWindows) return WindowsPowerStateSource();
  // Android reads through the platform channel; the controller supplies
  // that source.
  return const _FixedPowerSource();
}

/// Linux: /sys/class/power_supply (batteries and mains adapters).
class LinuxPowerStateSource implements PowerStateSource {
  LinuxPowerStateSource({this.root = '/sys/class/power_supply'});

  final String root;

  @override
  Future<PowerState> read() async {
    final dir = Directory(root);
    if (!await dir.exists()) return PowerState.unknown;
    var hasBattery = false;
    bool? mainsOnline;
    bool? charging;
    int? percent;
    var count = 0;
    await for (final entry in dir.list(followLinks: true)) {
      // A machine has a handful of supplies; peripherals add a few more.
      if (++count > 32) break;
      final type = await _readSmall('${entry.path}/type');
      if (type == null) continue;
      switch (type.trim()) {
        case 'Mains':
        case 'USB':
          final online = await _readSmall('${entry.path}/online');
          if (online?.trim() == '1') {
            mainsOnline = true;
          } else {
            mainsOnline ??= false;
          }
        case 'Battery':
          // Mouse and keyboard batteries say scope=Device.
          final scope = await _readSmall('${entry.path}/scope');
          if (scope?.trim() == 'Device') continue;
          hasBattery = true;
          final status = (await _readSmall('${entry.path}/status'))?.trim();
          if (status == 'Charging' || status == 'Full') charging = true;
          if (status == 'Discharging') charging ??= false;
          final capacity = int.tryParse(
            (await _readSmall('${entry.path}/capacity'))?.trim() ?? '',
          );
          if (capacity != null && capacity >= 0 && capacity <= 100) {
            percent = percent == null ? capacity : (percent + capacity) ~/ 2;
          }
      }
    }
    if (mainsOnline == true) charging = true;
    return PowerState(
      hasBattery: hasBattery,
      charging: hasBattery ? (charging ?? mainsOnline) : true,
      batteryPercent: hasBattery ? percent : null,
    );
  }

  static Future<String?> _readSmall(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      final bytes = await file
          .openRead(0, 64)
          .fold<List<int>>(<int>[], (all, chunk) => all..addAll(chunk));
      return String.fromCharCodes(bytes);
    } catch (_) {
      return null;
    }
  }
}

/// Windows: GetSystemPowerStatus.
class WindowsPowerStateSource implements PowerStateSource {
  @override
  Future<PowerState> read() async {
    if (!Platform.isWindows) return PowerState.unknown;
    try {
      final kernel32 = DynamicLibrary.open('kernel32.dll');
      final getStatus = kernel32
          .lookupFunction<
            Int32 Function(Pointer<_SystemPowerStatus>),
            int Function(Pointer<_SystemPowerStatus>)
          >('GetSystemPowerStatus');
      final status = calloc<_SystemPowerStatus>();
      try {
        if (getStatus(status) == 0) return PowerState.unknown;
        return windowsPowerState(
          acLineStatus: status.ref.acLineStatus,
          batteryFlag: status.ref.batteryFlag,
          batteryLifePercent: status.ref.batteryLifePercent,
          systemStatusFlag: status.ref.systemStatusFlag,
        );
      } finally {
        calloc.free(status);
      }
    } catch (_) {
      return PowerState.unknown;
    }
  }
}

/// SYSTEM_POWER_STATUS as a [PowerState].
PowerState windowsPowerState({
  required int acLineStatus,
  required int batteryFlag,
  required int batteryLifePercent,
  required int systemStatusFlag,
}) {
  // 128: no system battery; 255: unknown.
  final noBattery = batteryFlag != 255 && batteryFlag & 128 != 0;
  return PowerState(
    hasBattery: batteryFlag == 255 ? null : !noBattery,
    charging: switch (acLineStatus) {
      1 => true,
      0 => false,
      _ => null,
    },
    batteryPercent: noBattery || batteryLifePercent > 100
        ? null
        : batteryLifePercent,
    batterySaver: systemStatusFlag == 1,
  );
}

final class _SystemPowerStatus extends Struct {
  @Uint8()
  external int acLineStatus;
  @Uint8()
  external int batteryFlag;
  @Uint8()
  external int batteryLifePercent;
  @Uint8()
  external int systemStatusFlag;
  @Uint32()
  external int batteryLifeTime;
  @Uint32()
  external int batteryFullLifeTime;
}
