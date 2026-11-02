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

  test('the setting persists, and old data loads as automatic', () {
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
      EnergyBudgetSetting.automatic,
    );
    // A chosen Balanced is stored as such; Automatic is the default.
    final balanced = const GlobalConnectivityPreferences().copyWith(
      energyBudget: EnergyBudgetSetting.balanced,
    );
    expect(
      GlobalConnectivityPreferences.fromJson(balanced.toJson()).energyBudget,
      EnergyBudgetSetting.balanced,
    );
    expect(balanced.toJson()['energyBudget'], 'balanced');
  });

  group('Automatic', () {
    EnergyPolicy policy(PowerState power, {required bool phone}) {
      final p = EnergyPolicy(source: _Source()..state = power, isPhone: phone)
        ..setting = EnergyBudgetSetting.automatic;
      return p;
    }

    test(
      'is cold on phones, on laptops on battery, balanced on mains',
      () async {
        final phone = policy(
          const PowerState(hasBattery: true, charging: true),
          phone: true,
        );
        await phone.refresh();
        expect(phone.isCold, isTrue);
        final laptop = policy(
          const PowerState(hasBattery: true, charging: false),
          phone: false,
        );
        await laptop.refresh();
        expect(laptop.isCold, isTrue);
        expect(laptop.budgetFor(NetworkCostClass.unmetered).maxExtraCopies, 0);
        final plugged = policy(
          const PowerState(hasBattery: true, charging: true),
          phone: false,
        );
        await plugged.refresh();
        expect(plugged.isCold, isFalse);
        expect(plugged.effectiveSetting, EnergyBudgetSetting.balanced);
        final desktop = policy(
          const PowerState(hasBattery: false),
          phone: false,
        );
        await desktop.refresh();
        expect(desktop.isCold, isFalse);
      },
    );

    test('an explicit choice wins on every device', () async {
      final phone = policy(
        const PowerState(hasBattery: true, charging: false),
        phone: true,
      )..setting = EnergyBudgetSetting.balanced;
      await phone.refresh();
      expect(phone.isCold, isFalse);
      phone.setting = EnergyBudgetSetting.cold;
      expect(phone.isCold, isTrue);
      final desktop = policy(const PowerState(hasBattery: false), phone: false)
        ..setting = EnergyBudgetSetting.cold;
      expect(desktop.isCold, isTrue);
    });

    test('a policy with a fixed mode (tests) never goes cold alone', () {
      final fixed = EnergyPolicy.fixed(EnergyMode.limited);
      expect(fixed.setting, EnergyBudgetSetting.automatic);
      expect(fixed.isCold, isFalse);
    });
  });
}
