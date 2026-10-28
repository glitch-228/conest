import 'dart:convert';

import 'package:conest/src/telegram/td_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
