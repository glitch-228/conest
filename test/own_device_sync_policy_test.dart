import 'package:conest/src/models.dart';
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
}
