import 'dart:io';

import 'package:conest/src/error_history.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('conest_errors_'));
  tearDown(() => root.deleteSync(recursive: true));
  final key = List<int>.generate(32, (i) => i);

  test('kept across restarts, encrypted, oldest dropped first', () async {
    final file = File('${root.path}/vault.errors');
    final history = ErrorHistory(file: file, key: key, capacity: 3);
    for (var i = 0; i < 5; i++) {
      history.add('error', 'failure $i to Bob');
    }
    await history.close();
    expect(history.entries.map((e) => e.text), [
      'failure 2 to Bob',
      'failure 3 to Bob',
      'failure 4 to Bob',
    ]);
    expect(
      String.fromCharCodes(await file.readAsBytes()).contains('Bob'),
      isFalse,
      reason: 'kept in the clear',
    );
    final again = ErrorHistory(file: file, key: key, capacity: 3);
    await again.load();
    expect(again.entries.map((e) => e.text).last, 'failure 4 to Bob');
    // Another key reads nothing (and does not fail).
    final other = ErrorHistory(
      file: file,
      key: List<int>.filled(32, 7),
      capacity: 3,
    );
    await other.load();
    expect(other.entries, isEmpty);
  });

  test('bounded by size, and exported with a filter', () {
    final history = ErrorHistory(maxBytes: 500);
    for (var i = 0; i < 20; i++) {
      history.add(i.isEven ? 'send' : 'log', 'line $i ${'x' * 40}');
    }
    expect(history.entries.length, lessThan(20));
    final sends = history.exportText(filter: 'send').split('\n');
    expect(sends, everyElement(contains('[send]')));
    expect(history.exportText(), contains('line 19'));
    final roomy = ErrorHistory()..add('error', 'y' * 10000);
    expect(roomy.entries.last.text.length, ErrorHistory.maxEntryChars + 1);
  });
}
