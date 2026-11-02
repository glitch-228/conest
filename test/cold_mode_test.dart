import 'package:conest/src/cold_mode.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late List<String> log;
  late Map<String, ColdTransportMode> modes;

  ColdHandle handle(String id, {bool exempt = false}) => ColdHandle(
    id: id,
    exempt: exempt,
    start: () async => log.add('start $id'),
    stop: () async => log.add('stop $id'),
  );

  ColdMode make({int fetches = 0}) {
    final cold = ColdMode(
      lingerAfterSend: const Duration(milliseconds: 150),
      holdAfterWake: const Duration(milliseconds: 150),
      wakeEvery: (minutes) => Duration(milliseconds: 100 * minutes),
      fetch: () async => log.add('fetch'),
    )..modeOf = (id) => modes[id] ?? ColdTransportMode.cold;
    cold.setHandles([
      handle('iroh'),
      handle('nostr'),
      handle('lan'),
      handle('telegram', exempt: true),
    ]);
    addTearDown(cold.dispose);
    return cold;
  }

  Future<void> settle([int ms = 40]) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  setUp(() {
    log = [];
    modes = {};
  });

  test('idle transports are stopped, chat networks are not touched', () async {
    final cold = make();
    await cold.configure(active: true, wakeMinutes: 0);
    expect(log.toSet(), {'stop iroh', 'stop nostr', 'stop lan'});
    expect(cold.upIds, {'telegram'});
  });

  test('the timer wakes them, fetches, and stops them again', () async {
    final cold = make();
    await cold.configure(active: true, wakeMinutes: 5); // 500 ms here
    log.clear();
    await settle(560);
    expect(log, containsAll(['start iroh', 'start nostr', 'start lan']));
    expect(log, contains('fetch'));
    expect(cold.lastCheckedAt, isNotNull);
    expect(cold.upIds, containsAll(['iroh', 'nostr', 'lan']));
    // The hold ends: cold again.
    await settle(200);
    expect(cold.upIds, {'telegram'});
    expect(
      log.where((l) => l.startsWith('stop')).length,
      greaterThanOrEqualTo(3),
    );
  });

  test('manual only: nothing wakes by itself, a refresh does', () async {
    final cold = make();
    await cold.configure(active: true, wakeMinutes: 0);
    log.clear();
    await settle(300);
    expect(log, isEmpty);
    expect(cold.nextCheckAt, isNull);
    await cold.refresh();
    expect(log, contains('start iroh'));
    expect(log, contains('fetch'));
    await settle(260);
    expect(cold.upIds, {'telegram'});
  });

  test('a send wakes only the routes it needs and they go cold after the '
      'linger', () async {
    final cold = make();
    await cold.configure(active: true, wakeMinutes: 0);
    log.clear();
    await cold.wakeFor(['nostr', 'telegram']);
    expect(log, ['start nostr']);
    expect(cold.upIds, {'nostr', 'telegram'});
    await settle(60);
    // A second send extends the stay.
    await cold.wakeFor(['nostr']);
    await settle(120);
    expect(cold.upIds, contains('nostr'));
    await settle(150);
    expect(cold.upIds, {'telegram'});
  });

  test('a transport set to always on stays up, off never starts', () async {
    modes = {
      'iroh': ColdTransportMode.alwaysOn,
      'nostr': ColdTransportMode.off,
    };
    final cold = make();
    await cold.configure(active: true, wakeMinutes: 0);
    expect(cold.upIds, {'iroh', 'telegram'});
    log.clear();
    await cold.wakeFor(['nostr']);
    await cold.refresh();
    expect(log.where((l) => l == 'start nostr'), isEmpty);
    expect(log.where((l) => l == 'stop iroh'), isEmpty);
  });

  test('leaving cold mode starts everything again', () async {
    final cold = make();
    await cold.configure(active: true, wakeMinutes: 0);
    log.clear();
    await cold.configure(active: false, wakeMinutes: 0);
    expect(cold.upIds, {'iroh', 'nostr', 'lan', 'telegram'});
    expect(cold.active, isFalse);
  });

  test('a route in use (a call, a transfer) is not stopped when its stay '
      'ends, and is once it is free', () async {
    final cold = make();
    var callOverIroh = true;
    cold.inUseRecheck = const Duration(milliseconds: 60);
    cold.inUse = (id) => id == 'iroh' && callOverIroh;
    await cold.configure(active: true, wakeMinutes: 0);
    await cold.wakeFor(['iroh', 'nostr']);
    await settle(260); // The 150 ms stay is over.
    expect(cold.upIds, contains('iroh'));
    expect(cold.upIds, isNot(contains('nostr')));
    callOverIroh = false;
    await settle(150);
    expect(cold.upIds, isNot(contains('iroh')));
  });

  test('replacing the handles during a stay neither loses the stay nor the '
      'state: the route still stops and starts again', () async {
    final cold = make();
    await cold.configure(active: true, wakeMinutes: 0);
    await cold.wakeFor(['nostr']);
    // The controller syncs on every network change: new handle objects.
    cold.setHandles([
      handle('iroh'),
      handle('nostr'),
      handle('lan'),
      handle('telegram', exempt: true),
    ]);
    expect(cold.upIds, contains('nostr'));
    await settle(260);
    expect(cold.upIds, {'telegram'});
    log.clear();
    await cold.wakeFor(['nostr']);
    expect(log, ['start nostr']);
    expect(cold.isCold('lan'), isTrue);
    expect(cold.isCold('nostr'), isFalse);
    expect(cold.isCold('telegram'), isFalse);
  });

  test('something awaiting a retry wakes cold mode between the checks, '
      'also with checks only on request', () async {
    final cold = make();
    cold.retryEvery = const Duration(milliseconds: 100);
    DateTime? due;
    cold.retryDue = () => due;
    await cold.configure(active: true, wakeMinutes: 0);
    log.clear();
    await settle(250);
    expect(log, isEmpty);
    // A message is waiting for its receipt.
    due = DateTime.now().add(const Duration(milliseconds: 50));
    cold.rearm();
    await settle(300);
    expect(log, containsAll(['start iroh', 'fetch']));
    // Nothing waits any more: no further wakes.
    due = null;
    await settle(250);
    log.clear();
    await settle(300);
    expect(log, isEmpty);
  });

  test('a route in use with nothing moving is let go after the deferral '
      'cap, and does not keep a timer going for ever', () async {
    final cold = make();
    cold.inUseRecheck = const Duration(milliseconds: 40);
    cold.maxDeferral = const Duration(milliseconds: 200);
    cold.inUse = (_) => true; // Stuck: reports in use for ever.
    await cold.configure(active: true, wakeMinutes: 0);
    await cold.wakeFor(['iroh']);
    await settle(150); // Stay over; deferred.
    expect(cold.upIds, contains('iroh'));
    await settle(400);
    expect(cold.upIds, isNot(contains('iroh')));
    log.clear();
    await settle(300);
    expect(log, isEmpty, reason: 'it kept checking');
  });

  test('a retry wake runs the retry and holds no route', () async {
    final cold = make();
    cold.retryEvery = const Duration(milliseconds: 80);
    var retries = 0;
    cold.retryDue = () => DateTime.now();
    cold.retryWake = () async => retries++;
    await cold.configure(active: true, wakeMinutes: 0);
    log.clear();
    await settle(400);
    expect(retries, greaterThanOrEqualTo(2));
    expect(log, isEmpty, reason: 'a retry wake started routes: $log');
    expect(cold.upIds, {'telegram'});
  });

  test('wake minutes are normalized to the choices', () {
    expect(normalizeColdWakeMinutes(30), 30);
    expect(normalizeColdWakeMinutes(0), 0);
    expect(normalizeColdWakeMinutes(7), defaultColdWakeMinutes);
    expect(normalizeColdWakeMinutes(null), defaultColdWakeMinutes);
    expect(ColdTransportMode.parse('nonsense'), ColdTransportMode.cold);
  });
}
