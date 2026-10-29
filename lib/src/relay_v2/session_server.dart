import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'frames.dart';
import 'noise_nk.dart';
import 'session.dart';

/// Answers one v1-style request on a session.
typedef RelaySessionRequestHandler =
    Future<Map<String, dynamic>> Function(Map<String, dynamic> request);

/// Opens a subscription: the events to push for [mailboxes] (each a map
/// with `mailbox`, `messages` and `lease_id`), until cancelled.
typedef RelaySessionSubscribeHandler =
    Stream<Map<String, dynamic>> Function(
      List<String> mailboxes,
      Map<String, dynamic> request,
    );

/// The relay's side of a v2 session, for the in-app relay (and tests): the
/// same wire format as `native/conest_relay/src/session.rs`, with the same
/// bounds (frame size, streams in flight, an idle limit).
class RelaySessionServer {
  RelaySessionServer({
    required this.staticKeyPair,
    required this.onRequest,
    required this.onSubscribe,
    this.maxFramePayload = 300 * 1024 + 4096,
    this.maxStreams = 32,
    this.maxSubscriptions = 4,
    this.idle = const Duration(seconds: 120),
    this.handshakeTimeout = const Duration(seconds: 10),
  });

  final SimpleKeyPair staticKeyPair;
  final RelaySessionRequestHandler onRequest;
  final RelaySessionSubscribeHandler onSubscribe;
  final int maxFramePayload;
  final int maxStreams;
  final int maxSubscriptions;
  final Duration idle;
  final Duration handshakeTimeout;

  /// Serves one session over [input] (whose first bytes are `CNS2`),
  /// writing to [write]; returns when it ends.
  Future<void> serve({
    required Stream<List<int>> input,
    required void Function(List<int> bytes) write,
    required Future<void> Function() flush,
  }) async {
    final reader = RelayInputReader(input);
    final open = _OpenSession(this, write, flush);
    try {
      final head = await reader.readExact(7).timeout(handshakeTimeout);
      for (var index = 0; index < 4; index++) {
        if (head[index] != relayV2Magic[index]) return;
      }
      if (head[4] != relayV2Version) return;
      final length = (head[5] << 8) | head[6];
      if (length < 48 || length > 2048) return;
      final message1 = await reader.readExact(length).timeout(handshakeTimeout);
      final responder = await NoiseNkResponder.start(
        staticKeyPair: staticKeyPair,
      );
      await responder.readMessage1(message1);
      final hello = utf8.encode(
        jsonEncode({
          'v': relayV2Version,
          'max_frame': maxFramePayload,
          'max_streams': maxStreams,
          'idle_s': idle.inSeconds,
        }),
      );
      final (message2, transport) = await responder.writeMessage2(hello);
      write([message2.length >> 8, message2.length & 0xff, ...message2]);
      await flush();
      open.transport = transport;
      final decoder = RelayV2FrameDecoder(maxFramePayload);
      while (true) {
        final header = await reader.readExact(2).timeout(idle);
        final recordLength = (header[0] << 8) | header[1];
        if (recordLength < relayV2Tag) return;
        final sealed = await reader
            .readExact(recordLength)
            .timeout(handshakeTimeout);
        final plain = await transport.receive.decryptWithAd(const [], sealed);
        decoder.add(plain);
        for (
          var frame = decoder.next();
          frame != null;
          frame = decoder.next()
        ) {
          await open.dispatch(frame);
        }
      }
    } on Object {
      // Closed, idle, broken or hostile: the session ends.
    } finally {
      open.close();
      await reader.cancel();
    }
  }
}

class _OpenSession {
  _OpenSession(this.server, this.write, this.flush);

  final RelaySessionServer server;
  final void Function(List<int> bytes) write;
  final Future<void> Function() flush;
  NoiseNkTransport? transport;
  final Set<int> _inFlight = {};
  final Map<int, StreamSubscription<Map<String, dynamic>>> _subscriptions = {};
  Future<void> _writing = Future<void>.value();
  bool _closed = false;

  void close() {
    _closed = true;
    for (final subscription in _subscriptions.values) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
  }

  Future<void> send(int type, int stream, List<int> payload) {
    final keys = transport;
    if (_closed || keys == null) return Future<void>.value();
    final next = _writing.then((_) async {
      if (_closed) return;
      final plain = encodeRelayV2Frame(type, stream, payload);
      final out = BytesBuilder(copy: false);
      for (
        var offset = 0;
        offset < plain.length;
        offset += relayV2MaxRecordPlaintext
      ) {
        final end = min(offset + relayV2MaxRecordPlaintext, plain.length);
        final sealed = await keys.send.encryptWithAd(
          const [],
          Uint8List.sublistView(plain, offset, end),
        );
        out
          ..addByte(sealed.length >> 8)
          ..addByte(sealed.length & 0xff)
          ..add(sealed);
      }
      write(out.takeBytes());
      await flush();
    });
    _writing = next.catchError((Object _) {
      _closed = true;
    });
    return next;
  }

  Future<void> respond(int stream, Map<String, dynamic> body) =>
      send(RelayV2FrameType.response, stream, utf8.encode(jsonEncode(body)));

  static Map<String, dynamic> error(String message) => {
    'ok': false,
    'stored': false,
    'messages': const [],
    'error': message,
    'stats': null,
  };

  Future<void> dispatch(RelayV2Frame frame) async {
    switch (frame.type) {
      case RelayV2FrameType.request:
        await _start(frame.stream, frame.payload);
      case RelayV2FrameType.cancel:
        await _subscriptions.remove(frame.stream)?.cancel();
        _inFlight.remove(frame.stream);
      case RelayV2FrameType.ping:
        await send(RelayV2FrameType.pong, frame.stream, frame.payload);
      case RelayV2FrameType.pong || RelayV2FrameType.pad:
        break;
      default:
        if (frame.stream != 0) {
          await respond(frame.stream, error('unsupported'));
        }
    }
  }

  Future<void> _start(int stream, Uint8List payload) async {
    if (stream == 0) {
      await respond(stream, error('stream 0 is reserved'));
      return;
    }
    if (_inFlight.contains(stream)) {
      await respond(stream, error('stream already in use'));
      return;
    }
    if (_inFlight.length >= server.maxStreams) {
      await respond(stream, error('too many requests in flight'));
      return;
    }
    Map<String, dynamic> request;
    try {
      final decoded = jsonDecode(utf8.decode(payload));
      if (decoded is! Map<String, dynamic>) throw const FormatException();
      request = decoded;
    } on FormatException {
      await respond(stream, error('invalid request'));
      return;
    }
    _inFlight.add(stream);
    if (request['action'] == 'subscribe') {
      await _subscribe(stream, request);
      return;
    }
    unawaited(() async {
      Map<String, dynamic> response;
      try {
        response = await server.onRequest(request);
      } on Object catch (failure) {
        response = error(failure.toString());
      }
      if (_inFlight.remove(stream)) await respond(stream, response);
    }());
  }

  Future<void> _subscribe(int stream, Map<String, dynamic> request) async {
    final list = request['mailboxes'];
    if (list is! List ||
        list.isEmpty ||
        list.length > 8 ||
        list.any((item) => item is! String)) {
      _inFlight.remove(stream);
      await respond(stream, error('subscribe needs 1..8 mailboxes'));
      return;
    }
    if (_subscriptions.length >= server.maxSubscriptions) {
      _inFlight.remove(stream);
      await respond(stream, error('too many subscriptions'));
      return;
    }
    final mailboxes = list.cast<String>().toSet().toList();
    await send(
      RelayV2FrameType.event,
      stream,
      utf8.encode(jsonEncode({'ok': true, 'subscribed': mailboxes})),
    );
    _subscriptions[stream] = server
        .onSubscribe(mailboxes, request)
        .listen(
          (event) => unawaited(
            send(
              RelayV2FrameType.event,
              stream,
              utf8.encode(jsonEncode({'ok': true, ...event})),
            ),
          ),
          onError: (Object failure) {
            _subscriptions.remove(stream);
            if (_inFlight.remove(stream)) {
              unawaited(respond(stream, error(failure.toString())));
            }
          },
          onDone: () {
            _subscriptions.remove(stream);
            if (_inFlight.remove(stream)) {
              unawaited(respond(stream, error('subscription ended')));
            }
          },
        );
  }
}
