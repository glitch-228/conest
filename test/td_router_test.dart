import 'dart:async';

import 'dart:convert';

import 'package:conest/src/telegram/td_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  supervisorTests();
  test('objects reach only the client whose @client_id they carry', () {
    final router = TdRouter();
    final a = <Map<String, dynamic>>[];
    final b = <Map<String, dynamic>>[];
    router.register(1, a.add);
    router.register(2, b.add);
    router.dispatch(jsonEncode({'@type': 'x', '@client_id': 1}));
    router.dispatch(jsonEncode({'@type': 'y', '@client_id': 2}));
    expect(a.map((e) => e['@type']), ['x']);
    expect(b.map((e) => e['@type']), ['y']);
  });

  test('a closed client, unknown ids and junk are dropped', () {
    final router = TdRouter();
    final a = <Map<String, dynamic>>[];
    router.register(1, a.add);
    router.unregister(1);
    router.dispatch(jsonEncode({'@type': 'late', '@client_id': 1}));
    router.dispatch(jsonEncode({'@type': 'none'}));
    router.dispatch(jsonEncode({'@type': 'str', '@client_id': '1'}));
    router.dispatch('not json');
    router.dispatch('[1]');
    expect(a, isEmpty);
    expect(router.clients, 0);
  });

  test('a new client with a new id does not receive an old one\'s objects', () {
    final router = TdRouter();
    final old = <Map<String, dynamic>>[];
    final fresh = <Map<String, dynamic>>[];
    router.register(1, old.add);
    router.unregister(1);
    router.register(2, fresh.add);
    router.dispatch(jsonEncode({'@type': 'closed-state', '@client_id': 1}));
    expect(fresh, isEmpty);
  });
}

class _FakeReader {
  _FakeReader() {
    handle = TdReaderHandle(
      exited: exit.future,
      requestStop: () {
        stopRequested = true;
        Future<void>.delayed(const Duration(milliseconds: 20), die);
      },
    );
  }
  final exit = Completer<void>();
  late final TdReaderHandle handle;
  bool stopRequested = false;
  void die() {
    if (!exit.isCompleted) exit.complete();
  }
}

void supervisorTests() {
  group('the reader supervisor', () {
    late List<_FakeReader> readers;
    late int deaths;
    late TdReaderSupervisor supervisor;

    setUp(() {
      readers = [];
      deaths = 0;
      supervisor = TdReaderSupervisor(() async {
        final reader = _FakeReader();
        readers.add(reader);
        return reader.handle;
      }, onDied: () => deaths++);
    });

    test('one reader serves everyone', () async {
      await Future.wait([supervisor.ensure(), supervisor.ensure()]);
      await supervisor.ensure();
      expect(readers, hasLength(1));
    });

    test('a reader that dies is replaced on the next request', () async {
      await supervisor.ensure();
      readers.first.die();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(deaths, 1);
      expect(supervisor.running, isFalse);
      await supervisor.ensure();
      expect(readers, hasLength(2));
    });

    test('the reader stops when no client is left, not before', () async {
      await supervisor.ensure();
      await supervisor.stopIfIdle(1);
      expect(readers.first.stopRequested, isFalse);
      await supervisor.stopIfIdle(0);
      expect(readers.first.stopRequested, isTrue);
      expect(supervisor.running, isFalse);
      expect(deaths, 0);
    });

    test('a request during the stop waits, then gets a fresh reader', () async {
      await supervisor.ensure();
      final stopping = supervisor.stopIfIdle(0);
      final again = supervisor.ensure();
      await Future.wait([stopping, again]);
      expect(readers, hasLength(2));
      expect(readers.first.exit.isCompleted, isTrue);
      expect(readers.last.exit.isCompleted, isFalse);
      expect(supervisor.running, isTrue);
    });

    test('the router fails the requests of a client when told', () {
      final router = TdRouter();
      var lost = 0;
      router.register(1, (_) {}, onLost: () => lost++);
      router.register(2, (_) {});
      router.readerDied();
      expect(lost, 1);
    });
  });
}
