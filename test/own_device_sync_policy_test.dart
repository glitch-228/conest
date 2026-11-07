import 'package:conest/src/models.dart';
import 'package:conest/src/transfer/own_device_serve_gate.dart';
import 'package:conest/src/transfer/own_device_sync_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const policy = OwnDeviceSyncPolicy();

  test('steady is capped and limited to two paths', () {
    final p = policy.permit(const SyncConditions(batteryPercent: 80));
    expect(p.allowed, isTrue);
    expect(p.bytesPerSecond, 256 * 1024);
    expect(p.maxPaths, 2);
  });

  test('steady stops on a low battery or in battery saver until charging', () {
    expect(
      policy.permit(const SyncConditions(batteryPercent: 19)).allowed,
      isFalse,
    );
    expect(
      policy.permit(const SyncConditions(batterySaver: true)).allowed,
      isFalse,
    );
    expect(
      policy
          .permit(const SyncConditions(batteryPercent: 5, charging: true))
          .allowed,
      isTrue,
    );
    // No battery (a desktop): never held up by it.
    expect(policy.permit(const SyncConditions()).allowed, isTrue);
  });

  test('fast needs a confirmation and gives way on a metered network', () {
    final asked = policy.copyWith(speed: SyncSpeed.fast);
    final unconfirmed = asked.permit(const SyncConditions());
    expect(unconfirmed.speed, SyncSpeed.steady);
    expect(unconfirmed.bytesPerSecond, isNotNull);
    final confirmed = asked.copyWith(fastConfirmed: true);
    final fast = confirmed.permit(const SyncConditions());
    expect(fast.speed, SyncSpeed.fast);
    expect(fast.bytesPerSecond, isNull);
    expect(fast.maxPaths, greaterThan(2));
    final metered = confirmed.permit(const SyncConditions(metered: true));
    expect(metered.speed, SyncSpeed.steady);
    expect(metered.bytesPerSecond, 256 * 1024);
  });

  test('paused syncs nothing', () {
    expect(
      policy
          .copyWith(speed: SyncSpeed.paused)
          .permit(const SyncConditions())
          .allowed,
      isFalse,
    );
  });

  test('fast is offered for a big backlog on a free network only', () {
    const free = SyncConditions();
    const metered = SyncConditions(metered: true);
    expect(
      policy.shouldOfferFast(
        backlogBytes: 300 * 1024 * 1024,
        backlogMessages: 0,
        now: free,
      ),
      isTrue,
    );
    expect(
      policy.shouldOfferFast(backlogBytes: 0, backlogMessages: 6000, now: free),
      isTrue,
    );
    expect(
      policy.shouldOfferFast(
        backlogBytes: 1024,
        backlogMessages: 10,
        now: free,
      ),
      isFalse,
    );
    expect(
      policy.shouldOfferFast(
        backlogBytes: 300 * 1024 * 1024,
        backlogMessages: 0,
        now: metered,
      ),
      isFalse,
    );
    expect(
      policy.shouldOfferFast(
        backlogBytes: 300 * 1024 * 1024,
        backlogMessages: 0,
        now: metered,
        onMains: true,
      ),
      isTrue,
    );
  });

  test('the pacer spaces sends to the cap and not at all without one', () {
    var now = DateTime.utc(2026);
    final pacer = SyncPacer(now: () => now);
    expect(pacer.reserve(256 * 1024, 256 * 1024), Duration.zero);
    expect(pacer.reserve(256 * 1024, 256 * 1024), const Duration(seconds: 1));
    expect(pacer.reserve(256 * 1024, 256 * 1024), const Duration(seconds: 2));
    now = now.add(const Duration(seconds: 10));
    expect(pacer.reserve(256 * 1024, 256 * 1024), Duration.zero);
    expect(pacer.reserve(1 << 30, null), Duration.zero);
  });

  test('digests agree on the same ids in any order, and differ otherwise', () {
    final a = ChatDigest.of(['m1', 'm2', 'm3']);
    expect(ChatDigest.of(['m3', 'm1', 'm2', 'm1']), a);
    expect(ChatDigest.of(['m1', 'm2']), isNot(a));
    expect(ChatDigest.of(['m1', 'm2', 'm4']), isNot(a));
    expect(ChatDigest.fromJson(a.toJson()), a);
    expect(ChatDigest.fromJson([1]), isNull);
    expect(ChatDigest.fromJson([-1, 'a' * 16]), isNull);
    expect(ChatDigest.fromJson([1, 'short']), isNull);
  });

  test('only chats the other holds differently are asked for', () {
    final same = ChatDigest.of(['a']);
    final mine = {
      'x': same,
      'y': ChatDigest.of(['b']),
      'z': same,
    };
    final theirs = {
      'x': same,
      'y': ChatDigest.of(['b', 'c']),
      'w': ChatDigest.of(['q']),
      'empty': ChatDigest.of([]),
    };
    expect(chatsToAsk(mine, theirs), ['y', 'w']);
  });

  test('the chosen speed is kept, and older vaults read as steady', () {
    const prefs = GlobalConnectivityPreferences(syncSpeed: SyncSpeed.paused);
    expect(
      GlobalConnectivityPreferences.fromJson(prefs.toJson()).syncSpeed,
      SyncSpeed.paused,
    );
    expect(
      GlobalConnectivityPreferences.fromJson(
        const GlobalConnectivityPreferences().toJson()..remove('syncSpeed'),
      ).syncSpeed,
      SyncSpeed.steady,
    );
    expect(
      const GlobalConnectivityPreferences().toJson().containsKey('syncSpeed'),
      isFalse,
    );
  });

  group('what each kind of traffic may do (M33 P0)', () {
    const confirmed = OwnDeviceSyncPolicy(fastConfirmed: true);
    const bg = SyncConditions(foreground: false);

    test('paused holds live events and stops everything else', () {
      final paused = policy.copyWith(speed: SyncSpeed.paused);
      final live = paused.permitFor(SyncTraffic.live, const SyncConditions());
      expect(live.allowed, isFalse);
      expect(live.hold, isTrue, reason: 'kept queued, not dropped');
      for (final traffic in [SyncTraffic.bulk, SyncTraffic.files]) {
        final p = paused.permitFor(traffic, const SyncConditions());
        expect(p.allowed, isFalse, reason: traffic.name);
        expect(p.hold, isFalse, reason: 'bulk is not kept for later');
      }
    });

    test('live events go through a low battery, saver, cold and metered', () {
      for (final now in const [
        SyncConditions(batteryPercent: 5),
        SyncConditions(batterySaver: true),
        SyncConditions(cold: true, foreground: false),
        SyncConditions(metered: true),
      ]) {
        final p = policy.permitFor(SyncTraffic.live, now);
        expect(p.allowed, isTrue);
        expect(p.hold, isFalse);
        expect(p.bytesPerSecond, isNull, reason: 'one small event, no pacing');
      }
    });

    test('bulk and files wait for a low battery and for saver', () {
      for (final traffic in [SyncTraffic.bulk, SyncTraffic.files]) {
        expect(
          policy.permitFor(traffic, const SyncConditions(batteryPercent: 19)),
          isA<SyncPermission>().having((p) => p.allowed, 'allowed', isFalse),
        );
        expect(
          policy
              .permitFor(traffic, const SyncConditions(batterySaver: true))
              .allowed,
          isFalse,
        );
        expect(
          policy
              .permitFor(
                traffic,
                const SyncConditions(batteryPercent: 5, charging: true),
              )
              .allowed,
          isTrue,
        );
      }
    });

    test('cold mode: bulk only with the app open, or charging unmetered', () {
      const cold = SyncConditions(cold: true, foreground: false);
      for (final traffic in [SyncTraffic.bulk, SyncTraffic.files]) {
        final p = policy.permitFor(traffic, cold);
        expect(p.allowed, isFalse, reason: traffic.name);
        expect(p.reason, contains('Cold'));
        expect(
          policy
              .permitFor(
                traffic,
                const SyncConditions(cold: true, foreground: true),
              )
              .allowed,
          isTrue,
          reason: 'the app is open',
        );
        expect(
          policy
              .permitFor(
                traffic,
                const SyncConditions(
                  cold: true,
                  foreground: false,
                  charging: true,
                ),
              )
              .allowed,
          isTrue,
          reason: 'charging on an unmetered network',
        );
        expect(
          policy
              .permitFor(
                traffic,
                const SyncConditions(
                  cold: true,
                  foreground: false,
                  charging: true,
                  metered: true,
                ),
              )
              .allowed,
          isFalse,
          reason: 'charging is not enough on a metered network',
        );
      }
      // Not cold: the app in the background changes nothing.
      expect(policy.permitFor(SyncTraffic.bulk, bg).allowed, isTrue);
    });

    test('files wait for an unmetered network; text pages need not', () {
      const metered = SyncConditions(metered: true);
      expect(policy.permitFor(SyncTraffic.bulk, metered).allowed, isTrue);
      final files = policy.permitFor(SyncTraffic.files, metered);
      expect(files.allowed, isFalse);
      expect(files.reason, contains('unmetered'));
      // Fast gives way on metered, and so do its files.
      expect(confirmed.permitFor(SyncTraffic.files, metered).allowed, isFalse);
    });

    test('the old permit is the bulk answer', () {
      for (final now in const [
        SyncConditions(),
        SyncConditions(batteryPercent: 10),
        SyncConditions(metered: true),
      ]) {
        final a = policy.permit(now);
        final b = policy.permitFor(SyncTraffic.bulk, now);
        expect((a.allowed, a.bytesPerSecond, a.maxPaths, a.speed), (
          b.allowed,
          b.bytesPerSecond,
          b.maxPaths,
          b.speed,
        ));
      }
    });

    test('steady files carry the cap and two paths; fast files neither', () {
      final steady = policy.permitFor(SyncTraffic.files, const SyncConditions());
      expect(steady.bytesPerSecond, 256 * 1024);
      expect(steady.maxPaths, 2);
      final fast = confirmed
          .copyWith(speed: SyncSpeed.fast)
          .permitFor(SyncTraffic.files, const SyncConditions());
      expect(fast.speed, SyncSpeed.fast);
      expect(fast.bytesPerSecond, isNull);
      expect(fast.maxPaths, greaterThan(2));
    });
  });

  group('serving blocks to an own device (M33 P0)', () {
    const allowed = SyncPermission(allowed: true, bytesPerSecond: 256 * 1024);
    const denied = SyncPermission(allowed: false, reason: 'Sync is paused.');
    const block = 256 * 1024;

    test('a denied permission serves nothing and spends nothing', () {
      var now = DateTime.utc(2026);
      final gate = OwnDeviceServeGate(now: () => now);
      expect(gate.admit('phone', block, denied), isNull);
      // Nothing was reserved: the first block after it goes at once.
      expect(gate.admit('phone', block, allowed), Duration.zero);
    });

    test('blocks are spaced to the cap, per device', () {
      final gate = OwnDeviceServeGate(now: () => DateTime.utc(2026));
      expect(gate.admit('phone', block, allowed), Duration.zero);
      expect(gate.admit('phone', block, allowed), const Duration(seconds: 1));
      expect(gate.admit('phone', block, allowed), const Duration(seconds: 2));
      // Another device has its own pace.
      expect(gate.admit('tablet', block, allowed), Duration.zero);
    });

    test('no cap serves at once, however much', () {
      final gate = OwnDeviceServeGate(now: () => DateTime.utc(2026));
      const fast = SyncPermission(allowed: true, maxPaths: 8);
      for (var i = 0; i < 50; i++) {
        expect(gate.admit('phone', 4 << 20, fast), Duration.zero);
      }
    });

    test('a block too far ahead is refused and does not push the others', () {
      var now = DateTime.utc(2026);
      final gate = OwnDeviceServeGate(
        now: () => now,
        maxWait: const Duration(seconds: 3),
      );
      expect(gate.admit('phone', block, allowed), Duration.zero);
      expect(gate.admit('phone', block, allowed), const Duration(seconds: 1));
      expect(gate.admit('phone', block, allowed), const Duration(seconds: 2));
      expect(gate.admit('phone', block, allowed), const Duration(seconds: 3));
      expect(gate.admit('phone', block, allowed), isNull);
      expect(gate.admit('phone', block, allowed), isNull);
      // The refusals reserved nothing: once the four admitted blocks have
      // gone (4 s), the next is not held up by them.
      now = now.add(const Duration(seconds: 4));
      expect(gate.admit('phone', block, allowed), Duration.zero);
    });

    test('it is bounded in devices, and forgets one on request', () {
      final gate = OwnDeviceServeGate(
        now: () => DateTime.utc(2026),
        maxDevices: 3,
      );
      for (var i = 0; i < 10; i++) {
        gate.admit('d$i', block, allowed);
      }
      expect(gate.length, 3);
      gate.forget('d9');
      expect(gate.length, 2);
      gate.clear();
      expect(gate.length, 0);
    });
  });
}
