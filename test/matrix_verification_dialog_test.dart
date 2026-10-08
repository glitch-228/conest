import 'dart:async';

import 'package:conest/src/matrix_service.dart';
import 'package:conest/src/ui/matrix_verification_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Api implements MatrixNativeApi {
  final ops = <String>[];
  final _events = StreamController<Map<String, dynamic>>.broadcast();

  void emit(Map<String, dynamic> event) => _events.add(event);

  @override
  Stream<Map<String, dynamic>> get events => _events.stream;

  @override
  Future<Map<String, dynamic>> request(
    String op, [
    Map<String, Object?> parameters = const {},
    Duration timeout = const Duration(minutes: 2),
  ]) async {
    ops.add(op);
    return const {};
  }
}

void main() {
  late _Api api;
  late MatrixClientService client;

  // Built inside each test: the widget test's fake clock must own the
  // event streams.
  Future<void> show(WidgetTester tester) {
    api = _Api();
    client = MatrixClientService(
      api: api,
      store: () async => (path: '/store', passphrase: 'p'),
      onSession: (_) async {},
    );
    addTearDown(client.dispose);
    return tester.pumpWidget(
      MaterialApp(
        home: MatrixVerificationDialog(
          client: client,
          userId: '@a:x',
          flowId: 'flow',
          weStarted: true,
        ),
      ),
    );
  }

  Map<String, dynamic> state(String value) => {
    'type': 'verification',
    'flowId': 'flow',
    'state': value,
  };

  testWidgets('waits for the other session to start the comparison', (
    tester,
  ) async {
    await show(tester);
    api.emit(state('ready'));
    await tester.pump();
    // Element started it: we follow instead of starting a second one.
    api.emit(state('started'));
    await tester.pump(const Duration(seconds: 3));
    expect(api.ops, isNot(contains('verification_start_sas')));

    api.emit({
      ...state('emojis'),
      'emojis': [
        {'symbol': '🐶', 'description': 'Dog'},
      ],
    });
    await tester.pump();
    expect(find.text('🐶'), findsOneWidget);
    expect(find.text('They match'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('starts the comparison when the other session does not', (
    tester,
  ) async {
    await show(tester);
    api.emit(state('ready'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    expect(api.ops, contains('verification_start_sas'));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('verifying another person names them', (tester) async {
    api = _Api();
    client = MatrixClientService(
      api: api,
      store: () async => (path: '/store', passphrase: 'p'),
      onSession: (_) async {},
    );
    addTearDown(client.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: MatrixVerificationDialog(
          client: client,
          userId: '@bob:x',
          flowId: 'flow',
          weStarted: true,
          otherName: 'Bob',
        ),
      ),
    );
    expect(find.text('Verify Bob'), findsOneWidget);
    expect(find.text('Waiting for Bob…'), findsOneWidget);
    api.emit(state('done'));
    await tester.pump();
    expect(
      find.textContaining('Your chats with Bob show as verified'),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
