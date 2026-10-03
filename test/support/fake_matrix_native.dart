import 'dart:async';

import 'package:conest/src/matrix_service.dart';

/// Connects fake native Matrix clients: a to-device send on one arrives as a
/// `to_device` event on the addressed device.
class FakeMatrixHub {
  final Map<String, FakeMatrixNative> _devices = {};
  final List<({String from, String to, Map<String, Object?> content})> sent =
      [];
}

class FakeMatrixNative implements MatrixNativeApi {
  FakeMatrixNative(this.hub);

  final FakeMatrixHub hub;
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  final List<String> ops = [];
  Map<String, dynamic>? _session;

  @override
  Stream<Map<String, dynamic>> get events => _events.stream;

  @override
  Future<Map<String, dynamic>> request(
    String op, [
    Map<String, Object?> parameters = const {},
    Duration timeout = const Duration(minutes: 2),
  ]) async {
    ops.add(op);
    switch (op) {
      case 'login_password':
        final user = parameters['user'] as String;
        final userId = user.startsWith('@') ? user : '@$user:fake.test';
        return _signIn({
          'homeserver': parameters['homeserver'],
          'userId': userId,
          'deviceId': parameters['deviceId'] ?? 'FAKEDEVICE',
          'accessToken': 'token-$userId',
        });
      case 'restore':
        return _signIn(Map<String, dynamic>.from(parameters['session'] as Map));
      case 'rooms':
        return {'rooms': const []};
      case 'logout':
        final session = _session;
        if (session != null) {
          hub._devices.remove('${session['userId']}|${session['deviceId']}');
        }
        _session = null;
        return const {};
      case 'send_to_device':
        final session = _session!;
        final target =
            hub._devices['${parameters['userId']}|${parameters['deviceId']}'];
        final content = Map<String, Object?>.from(parameters['content'] as Map);
        hub.sent.add((
          from: session['userId'] as String,
          to: '${parameters['userId']}|${parameters['deviceId']}',
          content: content,
        ));
        target?._events.add({
          'type': 'to_device',
          'event': {
            'type': parameters['type'],
            'sender': session['userId'],
            'content': content,
          },
        });
        return const {};
      default:
        return const {};
    }
  }

  Map<String, dynamic> _signIn(Map<String, dynamic> session) {
    _session = session;
    hub._devices['${session['userId']}|${session['deviceId']}'] = this;
    return session;
  }
}
