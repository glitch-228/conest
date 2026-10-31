import 'package:conest/src/energy_policy.dart';
import 'package:conest/src/models.dart';
import 'package:flutter_test/flutter_test.dart';

class _Source implements PowerStateSource {
  PowerState state = const PowerState(
    hasBattery: true,
    charging: false,
    batteryPercent: 80,
  );
  @override
  Future<PowerState> read() async => state;
}

void main() {
  const net = NetworkCostClass.unmetered;

  Future<EnergyPolicy> policy(
    _Source source,
    EnergyBudgetSetting setting,
  ) async {
    final p = EnergyPolicy(source: source)..setting = setting;
    await p.refresh(force: true);
    return p;
  }

  test(
    'eco drops to the minimum while discharging and restores on charging',
    () async {
      final source = _Source();
      final p = await policy(source, EnergyBudgetSetting.eco);
      final onBattery = p.budgetFor(net);
      expect(onBattery.maxActiveTransports, 3);
      expect(onBattery.maxExtraCopies, 0);
      expect(onBattery.hedgedBlocks, isFalse);
      expect(p.fanoutFor(net, copiesAllowed: true), isA<SingleRouteFanout>());
      source.state = const PowerState(
        hasBattery: true,
        charging: true,
        batteryPercent: 80,
      );
      await p.refresh(force: true);
      final plugged = p.budgetFor(net);
      expect(plugged.maxActiveTransports, isNull);
      expect(plugged.hedgedBlocks, isTrue);
      expect(plugged.maxExtraCopies, greaterThan(0));
      expect(p.fanoutFor(net, copiesAllowed: true), isA<AllRoutesFanout>());
    },
  );

  test('intervals follow the mode', () async {
    final source = _Source();
    final balanced = await policy(source, EnergyBudgetSetting.balanced);
    final eco = await policy(source, EnergyBudgetSetting.eco);
    final fast = await policy(source, EnergyBudgetSetting.fast);
    expect(balanced.budgetFor(net).pollFactor, 2);
    expect(eco.budgetFor(net).pollFactor, greaterThan(2));
    expect(fast.budgetFor(net).pollFactor, 1);
    // Fast on battery copies like mains does.
    expect(fast.fanoutFor(net, copiesAllowed: true), isA<AllRoutesFanout>());
  });

  test('fast lifts the battery limit, never metered or roaming', () async {
    final source = _Source();
    final fast = await policy(source, EnergyBudgetSetting.fast);
    expect(fast.modeFor(net), EnergyMode.unconstrained);
    for (final costly in [
      NetworkCostClass.metered,
      NetworkCostClass.roaming,
    ]) {
      expect(fast.modeFor(costly), EnergyMode.limited, reason: costly.name);
      expect(fast.budgetFor(costly).pollFactor, greaterThan(1));
    }
  });

  test('the setting is read from its source each time', () async {
    var chosen = EnergyBudgetSetting.balanced;
    final p = await policy(_Source(), EnergyBudgetSetting.balanced)
      ..settingSource = () => chosen;
    expect(p.budgetFor(net).pollFactor, 2);
    chosen = EnergyBudgetSetting.fast;
    expect(p.setting, EnergyBudgetSetting.fast);
    expect(p.budgetFor(net).pollFactor, 1);
  });

  test('battery saver stays the strictest whatever the setting', () async {
    final source = _Source()
      ..state = const PowerState(
        hasBattery: true,
        charging: false,
        batteryPercent: 10,
      );
    for (final setting in EnergyBudgetSetting.values) {
      final p = await policy(source, setting);
      final b = p.budgetFor(net);
      expect(b.maxActiveTransports, 2, reason: setting.name);
      expect(b.pollFactor, 8);
      expect(b.hedgedBlocks, isFalse);
    }
  });

  test('the setting persists and old data loads as balanced', () {
    final eco = const GlobalConnectivityPreferences().copyWith(
      energyBudget: EnergyBudgetSetting.eco,
    );
    expect(
      GlobalConnectivityPreferences.fromJson(eco.toJson()).energyBudget,
      EnergyBudgetSetting.eco,
    );
    expect(
      const GlobalConnectivityPreferences().toJson().containsKey(
        'energyBudget',
      ),
      isFalse,
    );
    expect(
      GlobalConnectivityPreferences.fromJson({
        'energyBudget': 'nonsense',
      }).energyBudget,
      EnergyBudgetSetting.balanced,
    );
  });
}
