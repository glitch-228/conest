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

  test('wake minutes are normalized to the choices', () {
    expect(normalizeColdWakeMinutes(30), 30);
    expect(normalizeColdWakeMinutes(0), 0);
    expect(normalizeColdWakeMinutes(7), defaultColdWakeMinutes);
    expect(normalizeColdWakeMinutes(null), defaultColdWakeMinutes);
    expect(ColdTransportMode.parse('nonsense'), ColdTransportMode.cold);
  });
}
