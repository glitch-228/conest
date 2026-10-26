import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'models.dart';
import 'relay_v2/frames.dart';
import 'relay_v2/session_server.dart';

const int _defaultMaxQueuePerMailbox = 512;
const int _defaultMaxFetchLimit = 128;
const int _defaultMaxEnvelopeBytes = 256 * 1024;
const int _defaultMaxLineBytes = 300 * 1024;
const int _defaultMaxRequestsPerMinute = 240;

class LocalRelayNode {
  LocalRelayNode({
    this.ttl = const Duration(days: 7),
    this.maxQueuePerMailbox = _defaultMaxQueuePerMailbox,
    this.maxFetchLimit = _defaultMaxFetchLimit,
    this.maxEnvelopeBytes = _defaultMaxEnvelopeBytes,
    this.maxLineBytes = _defaultMaxLineBytes,
    this.maxRequestsPerMinute = _defaultMaxRequestsPerMinute,
    String? relayId,
    DateTime Function()? nowProvider,
    List<int>? identitySeed,
  }) : relayId = relayId ?? 'local-${DateTime.now().microsecondsSinceEpoch}',
       _nowProvider = nowProvider ?? DateTime.now,
       _identitySeed = identitySeed == null
           ? null
           : List<int>.unmodifiable(identitySeed) {
    if (maxQueuePerMailbox <= 0) {
      throw ArgumentError('maxQueuePerMailbox must be greater than zero.');
    }
    if (maxFetchLimit <= 0) {
      throw ArgumentError('maxFetchLimit must be greater than zero.');
    }
    if (maxEnvelopeBytes <= 0 || maxLineBytes < maxEnvelopeBytes) {
      throw ArgumentError('maxLineBytes must be at least maxEnvelopeBytes.');
    }
    if (maxRequestsPerMinute <= 0) {
      throw ArgumentError('maxRequestsPerMinute must be greater than zero.');
    }
  }

  final Duration ttl;
  final int maxQueuePerMailbox;
  final int maxFetchLimit;
  final int maxEnvelopeBytes;
  final int maxLineBytes;
  final int maxRequestsPerMinute;
  final String relayId;
  final DateTime Function() _nowProvider;

  /// With a seed, this relay has an identity like a standalone one: it
  /// signs its answers, publishes a session key and serves v2 sessions
  /// (the same seed derives the same keys as `conest_relay`).
  final List<int>? _identitySeed;
  Future<_LocalRelayIdentity>? _identity;

  Future<_LocalRelayIdentity>? get _identityKeys {
    final seed = _identitySeed;
    if (seed == null) return null;
    return _identity ??= _LocalRelayIdentity.fromSeed(seed).then((identity) {
      _readyIdentity = identity;
      return identity;
    });
  }

  /// Subscriptions waiting on each mailbox (v2 sessions).
  final Map<String, Set<_LocalWatcher>> _watchers = {};

  /// Mailboxes a v2 subscription is waiting on (diagnostics and tests).
  Set<String> get subscribedMailboxes => _watchers.keys.toSet();

  /// v2 sessions this relay has taken (diagnostics and tests).
  int get sessionsServed => _sessionsServed;
  int _sessionsServed = 0;
  void Function(String recipientDeviceId, RelayEnvelope envelope)?
  onEnvelopeStored;

  /// The address that stored the envelope [onEnvelopeStored] is reporting,
  /// while it runs (null when this device stored it itself).
  String? get storingPeer => _storingPeer;
  String? _storingPeer;
  final Map<String, Queue<_QueueEntry>> _queues = {};
  final Map<String, _RateBucket> _rateBuckets = {};
  ServerSocket? _server;
  RawDatagramSocket? _udpSocket;
  StreamSubscription<RawSocketEvent>? _udpSubscription;
  int? _port;

  // Direct HTTP traffic shares the existing LAN port. The destination is
  // always our own bounded attachment server, never a caller-selected host.
  int? attachmentHttpPort;
  int? get attachmentIngressPort =>
      attachmentHttpPort == null ? null : _server?.port;
  final Set<Socket> _attachmentSockets = {};

  bool get isRunning => _server != null || _udpSocket != null;
  int? get port => _port;

  /// Start and stop run one at a time: two overlapping starts (a poll and
  /// Check Paths, say) would otherwise both bind the port, and the second
  /// bind fails.
  Future<void> _lifecycle = Future<void>.value();

  Future<T> _serialized<T>(Future<T> Function() action) {
    final next = _lifecycle.then((_) => action());
    _lifecycle = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }

  Future<void> start(int port) => _serialized(() async {
    if (_server != null && _port == port) {
      return;
    }
    await _stopNow();
    ServerSocket? server;
    try {
      server = await ServerSocket.bind(InternetAddress.anyIPv4, port);
      final udpSocket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        port,
      );
      _server = server;
      _udpSocket = udpSocket;
    } catch (_) {
      // Never left half bound: a TCP socket without its UDP twin would
      // block every later start on this port.
      await server?.close();
      rethrow;
    }
    _port = port;
    unawaited(_acceptLoop(_server!));
    _udpSubscription = _udpSocket!.listen(_handleUdpEvent);
  });

  Future<void> stop() => _serialized(_stopNow);

  Future<void> _stopNow() async {
    final server = _server;
    _server = null;
    final udpSocket = _udpSocket;
    final udpSubscription = _udpSubscription;
    _udpSocket = null;
    _udpSubscription = null;
    _port = null;
    if (server != null) {
      await server.close();
    }
    if (udpSubscription != null) {
      await udpSubscription.cancel();
    }
    udpSocket?.close();
    for (final socket in _attachmentSockets.toList()) {
      socket.destroy();
    }
    _attachmentSockets.clear();
  }

  Future<void> _acceptLoop(ServerSocket server) async {
    await for (final socket in server) {
      unawaited(_handleClient(socket));
    }
  }

  Future<void> _handleClient(Socket socket) async {
    var isHttp = false;
    final input = StreamIterator<List<int>>(socket);
    try {
      final prefix = BytesBuilder(copy: false);
      while (prefix.length < 4) {
        if (!await input.moveNext().timeout(const Duration(seconds: 4))) break;
        prefix.add(input.current);
      }
      final initial = prefix.takeBytes();
      final incoming = _remainingInput(initial, input);
      final keys = _identityKeys;
      if (keys != null &&
          initial.length >= 4 &&
          initial[0] == relayV2Magic[0] &&
          initial[1] == relayV2Magic[1] &&
          initial[2] == relayV2Magic[2] &&
          initial[3] == relayV2Magic[3]) {
        await _serveSession(socket, incoming, await keys);
        return;
      }
      final directPort = attachmentHttpPort;
      if (directPort != null &&
          initial.length >= 4 &&
          initial[0] == 80 &&
          initial[1] == 85 &&
          initial[2] == 84 &&
          initial[3] == 32) {
        await _forwardAttachmentHttp(socket, incoming, directPort);
        return;
      }
      final wireRequest = await _readWireRequest(incoming);
      isHttp = wireRequest.isHttp;
      // Health carries the identity once it is derived.
      await _identityKeys;
      final response = await _signed(
        wireRequest.request,
        _handleRequest(wireRequest.request, peer: socket.remoteAddress.address),
      );
      if (isHttp) {
        _writeHttpResponse(socket, response);
      } else {
        socket.writeln(jsonEncode(response));
      }
      await socket.flush();
    } catch (error) {
      final response = {
        'ok': false,
        'stored': false,
        'messages': const [],
        'error': error.toString(),
      };
      try {
        if (isHttp) {
          _writeHttpResponse(socket, response, statusCode: 400);
        } else {
          socket.writeln(jsonEncode(response));
        }
        await socket.flush();
      } catch (_) {
        // The peer may have disconnected before its error response.
      }
    } finally {
      await input.cancel();
      socket.destroy();
    }
  }

  Stream<List<int>> _remainingInput(
    List<int> first,
    StreamIterator<List<int>> input,
  ) async* {
    if (first.isNotEmpty) yield first;
    while (await input.moveNext()) {
      yield input.current;
    }
  }

  Future<void> _forwardAttachmentHttp(
    Socket client,
    Stream<List<int>> incoming,
    int port,
  ) async {
    if (_attachmentSockets.length >= 64) return;
    _attachmentSockets.add(client);
    Socket? destination;
    try {
      destination = await Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
        timeout: const Duration(seconds: 2),
      );
      _attachmentSockets.add(destination);
      final target = destination;
      await Future.wait([
        target.addStream(incoming).whenComplete(target.close),
        client.addStream(target).whenComplete(client.close),
      ], eagerError: true);
    } catch (_) {
      // A closed peer or bounded HTTP rejection simply ends this connection.
    } finally {
      destination?.destroy();
      client.destroy();
      _attachmentSockets.remove(destination);
      _attachmentSockets.remove(client);
    }
  }

  Future<_RelayWireRequest> _readWireRequest(Stream<List<int>> incoming) {
    final completer = Completer<_RelayWireRequest>();
    final buffer = BytesBuilder(copy: false);
    StreamSubscription<List<int>>? subscription;
    Timer? timer;

    void completeWithError(Object error) {
      if (completer.isCompleted) {
        return;
      }
      timer?.cancel();
      unawaited(subscription?.cancel());
      completer.completeError(error);
    }

    void tryComplete() {
      if (completer.isCompleted) {
        return;
      }
      final bytes = buffer.toBytes();
      final int? completion;
      try {
        completion = _wireRequestCompletion(bytes);
      } catch (error) {
        completeWithError(error);
        return;
      }
      if (completion == null) {
        return;
      }
      try {
        final request = _parseWireRequest(bytes.take(completion).toList());
        timer?.cancel();
        unawaited(subscription?.cancel());
        completer.complete(request);
      } catch (error) {
        completeWithError(error);
      }
    }

    timer = Timer(
      const Duration(seconds: 4),
      () => completeWithError(TimeoutException('Relay request timed out.')),
    );
    subscription = incoming.listen(
      (chunk) {
        buffer.add(chunk);
        if (buffer.length > maxLineBytes) {
          completeWithError(
            const FormatException('Relay request exceeded max size.'),
          );
          return;
        }
        tryComplete();
      },
      onError: completeWithError,
      onDone: () {
        if (!completer.isCompleted) {
          tryComplete();
        }
        if (!completer.isCompleted) {
          completeWithError(
            const FormatException('Relay request ended early.'),
          );
        }
      },
      cancelOnError: true,
    );
    return completer.future;
  }

  int? _wireRequestCompletion(List<int> bytes) {
    if (bytes.isEmpty) {
      return null;
    }
    final previewLength = bytes.length < 16 ? bytes.length : 16;
    final preview = latin1.decode(
      bytes.take(previewLength).toList(),
      allowInvalid: true,
    );
    final isHttp =
        preview.startsWith('GET ') ||
        preview.startsWith('POST ') ||
        preview.startsWith('OPTIONS ');
    if (!isHttp) {
      final newline = bytes.indexOf(10);
      if (newline > maxLineBytes) {
        throw const FormatException('Relay request line too large.');
      }
      return newline == -1 ? null : newline + 1;
    }

    final headerEnd = _httpHeaderEnd(bytes);
    if (headerEnd == null) {
      if (bytes.length > maxLineBytes) {
        throw const FormatException('HTTP relay headers too large.');
      }
      return null;
    }
    final headerText = latin1.decode(
      bytes.take(headerEnd.headerBytes).toList(),
      allowInvalid: true,
    );
    final contentLength = _httpContentLength(headerText);
    if (contentLength > maxLineBytes) {
      throw const FormatException('HTTP relay POST body too large.');
    }
    return bytes.length >= headerEnd.totalHeaderBytes + contentLength
        ? headerEnd.totalHeaderBytes + contentLength
        : null;
  }

  _HttpHeaderEnd? _httpHeaderEnd(List<int> bytes) {
    for (var index = 0; index <= bytes.length - 4; index++) {
      if (bytes[index] == 13 &&
          bytes[index + 1] == 10 &&
          bytes[index + 2] == 13 &&
          bytes[index + 3] == 10) {
        return _HttpHeaderEnd(headerBytes: index, totalHeaderBytes: index + 4);
      }
    }
    for (var index = 0; index <= bytes.length - 2; index++) {
      if (bytes[index] == 10 && bytes[index + 1] == 10) {
        return _HttpHeaderEnd(headerBytes: index, totalHeaderBytes: index + 2);
      }
    }
    return null;
  }

  int _httpContentLength(String headerText) {
    for (final line in const LineSplitter().convert(headerText)) {
      final separator = line.indexOf(':');
      if (separator <= 0) {
        continue;
      }
      final name = line.substring(0, separator).trim().toLowerCase();
      if (name != 'content-length') {
        continue;
      }
      final value = int.tryParse(line.substring(separator + 1).trim());
      if (value == null || value < 0) {
        throw const FormatException('Invalid HTTP content-length.');
      }
      return value;
    }
    return 0;
  }

  _RelayWireRequest _parseWireRequest(List<int> bytes) {
    final text = utf8.decode(bytes, allowMalformed: true);
    if (text.startsWith('GET ') ||
        text.startsWith('POST ') ||
        text.startsWith('OPTIONS ')) {
      final headerEnd = _httpHeaderEnd(bytes);
      if (headerEnd == null) {
        throw const FormatException('HTTP relay request has no headers.');
      }
      final firstLine = text.split(RegExp(r'\r?\n')).first;
      final parts = firstLine.split(' ');
      final method = parts.isEmpty ? '' : parts.first.toUpperCase();
      if (method == 'GET' || method == 'OPTIONS') {
        return const _RelayWireRequest(
          isHttp: true,
          request: {'action': 'health'},
        );
      }
      if (method != 'POST') {
        throw FormatException('Unsupported HTTP relay method: $method');
      }
      final bodyBytes = bytes.sublist(headerEnd.totalHeaderBytes);
      final request = jsonDecode(utf8.decode(bodyBytes));
      if (request is! Map<String, dynamic>) {
        throw const FormatException('HTTP relay body must be a JSON object.');
      }
      return _RelayWireRequest(isHttp: true, request: request);
    }

    final firstLine = text.split(RegExp(r'\r?\n')).first;
    final request = jsonDecode(firstLine);
    if (request is! Map<String, dynamic>) {
      throw const FormatException('TCP relay line must be a JSON object.');
    }
    return _RelayWireRequest(isHttp: false, request: request);
  }

  void _writeHttpResponse(
    Socket socket,
    Map<String, dynamic> response, {
    int statusCode = 200,
  }) {
    final body = utf8.encode(jsonEncode(response));
    final statusText = statusCode == 200 ? 'OK' : 'Bad Request';
    socket.add(
      utf8.encode(
        'HTTP/1.1 $statusCode $statusText\r\n'
        'Content-Type: application/json\r\n'
        'Content-Length: ${body.length}\r\n'
        'Cache-Control: no-store\r\n'
        'Access-Control-Allow-Origin: *\r\n'
        'Access-Control-Allow-Headers: content-type\r\n'
        'Connection: close\r\n'
        '\r\n',
      ),
    );
    socket.add(body);
  }

  void _handleUdpEvent(RawSocketEvent event) {
    final socket = _udpSocket;
    if (socket == null || event != RawSocketEvent.read) {
      return;
    }
    Datagram? datagram;
    while ((datagram = socket.receive()) != null) {
      final response = _handleUdpDatagram(datagram!);
      try {
        socket.send(
          utf8.encode(jsonEncode(response)),
          datagram.address,
          datagram.port,
        );
      } on SocketException {
        // The answer is lost, as UDP can be anyway: Android refuses sends
        // ("Operation not permitted") while it blocks a backgrounded app's
        // network, and an uncaught throw here ended in the crash log.
      }
    }
  }

  Map<String, dynamic> _handleUdpDatagram(Datagram datagram) {
    try {
      if (datagram.data.length > maxLineBytes) {
        throw const FormatException('UDP relay request too large.');
      }
      final request = jsonDecode(utf8.decode(datagram.data));
      if (request is! Map<String, dynamic>) {
        throw const FormatException('UDP relay request must be a JSON object.');
      }
      return _handleRequest(request, peer: datagram.address.address);
    } catch (error) {
      return {
        'ok': false,
        'stored': false,
        'messages': const [],
        'error': error.toString(),
      };
    }
  }

  Map<String, dynamic> _handleRequest(
    Map<String, dynamic> request, {
    required String peer,
  }) {
    _cleanup();
    if (!_allowRequest(peer)) {
      return {
        'ok': false,
        'stored': false,
        'messages': const [],
        'error': 'rate limit exceeded',
      };
    }
    final action = request['action'] as String?;
    try {
      switch (action) {
        case 'store':
          final recipientDeviceId = request['recipient_device_id'] as String;
          final envelope = RelayEnvelope.fromJson(
            request['envelope'] as Map<String, dynamic>,
          );
          _storingPeer = peer;
          try {
            _store(recipientDeviceId, envelope);
          } finally {
            _storingPeer = null;
          }
          return {'ok': true, 'stored': true, 'messages': const []};
        case 'fetch':
          final recipientDeviceId = request['recipient_device_id'] as String;
          final limit = request['limit'] as int? ?? maxFetchLimit;
          final messages = _fetch(
            recipientDeviceId,
            limit,
          ).map((envelope) => envelope.toJson()).toList(growable: false);
          return {'ok': true, 'stored': false, 'messages': messages};
        case 'fetch_leased':
          final recipientDeviceId = request['recipient_device_id'] as String;
          final limit = request['limit'] as int? ?? maxFetchLimit;
          final leaseMs = (request['lease_ms'] as int? ?? 30000).clamp(
            5000,
            300000,
          );
          final (messages, leaseId) = _fetchLeased(
            recipientDeviceId,
            limit,
            Duration(milliseconds: leaseMs),
          );
          return {
            'ok': true,
            'stored': false,
            'messages': [for (final envelope in messages) envelope.toJson()],
            'lease_id': ?leaseId,
          };
        case 'ack_lease':
          _acknowledge(
            request['recipient_device_id'] as String,
            request['lease_id'] as String,
          );
          return {'ok': true, 'stored': false, 'messages': const []};
        case 'health':
          final identity = _readyIdentity;
          return {
            'ok': true,
            'stored': false,
            'messages': const [],
            'stats': {
              'relay_id': relayId,
              'queue_count': _queues.length,
              'queued_envelope_count': _queues.values.fold<int>(
                0,
                (count, queue) => count + queue.length,
              ),
              'ttl_seconds': ttl.inSeconds,
              'max_queue_per_mailbox': maxQueuePerMailbox,
              'max_fetch_limit': maxFetchLimit,
              if (identity != null) ...{
                'identity_public_key': identity.publicKeyBase64,
                'v2': identity.v2Info,
              },
            },
          };
        default:
          return {
            'ok': false,
            'stored': false,
            'messages': const [],
            'error': 'Unsupported action: $action',
          };
      }
    } catch (error) {
      return {
        'ok': false,
        'stored': false,
        'messages': const [],
        'error': error.toString(),
      };
    }
  }

  void _store(String recipientDeviceId, RelayEnvelope envelope) {
    _validateMailboxId(recipientDeviceId);
    final envelopeBytes = utf8.encode(jsonEncode(envelope.toJson()));
    if (envelopeBytes.length > maxEnvelopeBytes) {
      throw StateError(
        'envelope too large: ${envelopeBytes.length} bytes > $maxEnvelopeBytes',
      );
    }
    final queue = _queues.putIfAbsent(recipientDeviceId, Queue.new);
    if (envelope.kind == 'pairing_announcement') {
      final retained = queue
          .where(
            (entry) =>
                entry.envelope.kind != 'pairing_announcement' ||
                entry.envelope.senderDeviceId != envelope.senderDeviceId,
          )
          .toList(growable: false);
      queue
        ..clear()
        ..addAll(retained);
    }
    while (queue.length >= maxQueuePerMailbox) {
      final entries = queue.toList(growable: false);
      final dropIndex = entries.indexWhere(
        (entry) => entry.envelope.kind != 'pairing_announcement',
      );
      if (dropIndex <= 0) {
        queue.removeFirst();
      } else {
        queue
          ..clear()
          ..addAll([
            ...entries.take(dropIndex),
            ...entries.skip(dropIndex + 1),
          ]);
      }
    }
    queue.add(
      _QueueEntry(queuedAt: _nowProvider().toUtc(), envelope: envelope),
    );
    onEnvelopeStored?.call(recipientDeviceId, envelope);
    final watchers = _watchers[recipientDeviceId];
    if (watchers != null && watchers.isNotEmpty) {
      // A subscription takes it (one of them, as a fetch would).
      scheduleMicrotask(() => _pushTo(watchers.first, recipientDeviceId));
    }
  }

  /// The identity, once derived (health is answered synchronously; a
  /// session or a signed answer derives it first).
  _LocalRelayIdentity? _readyIdentity;

  /// [response] to [request], signed as the standalone relay signs it when
  /// the request asks (`nonce` with `sig_mode` detached) and this relay has
  /// an identity.
  Future<Map<String, dynamic>> _signed(
    Map<String, dynamic> request,
    Map<String, dynamic> response,
  ) async {
    final keys = _identityKeys;
    final nonce = request['nonce'];
    if (keys == null || nonce is! String || request['sig_mode'] != 'detached') {
      return response;
    }
    final identity = await keys;
    final List<int> nonceBytes;
    try {
      nonceBytes = base64Decode(nonce);
    } on FormatException {
      return response;
    }
    final body = jsonEncode(response);
    final action = request['action'] as String? ?? '';
    final signature = await Ed25519().sign([
      ...utf8.encode(action),
      ...nonceBytes,
      ...utf8.encode(body),
    ], keyPair: identity.signing);
    return {
      'sig_v': 2,
      'body': body,
      'nonce_echo': nonce,
      'signature': base64Encode(signature.bytes),
    };
  }

  Future<void> _serveSession(
    Socket socket,
    Stream<List<int>> incoming,
    _LocalRelayIdentity identity,
  ) async {
    _sessionsServed++;
    final server = RelaySessionServer(
      staticKeyPair: identity.noise,
      maxFramePayload: maxLineBytes + 4096,
      onRequest: (request) async =>
          _handleRequest(request, peer: socket.remoteAddress.address),
      onSubscribe: _subscribeLocal,
    );
    await server.serve(input: incoming, write: socket.add, flush: socket.flush);
  }

  Stream<Map<String, dynamic>> _subscribeLocal(
    List<String> mailboxes,
    Map<String, dynamic> request,
  ) {
    try {
      for (final mailbox in mailboxes) {
        _validateMailboxId(mailbox);
      }
    } on ArgumentError catch (error) {
      return Stream.error(StateError(error.message.toString()));
    }
    final leaseMs = request['lease_ms'];
    final leaseFor = Duration(
      milliseconds: (leaseMs is int ? leaseMs : 30000).clamp(5000, 300000),
    );
    late final _LocalWatcher watcher;
    final controller = StreamController<Map<String, dynamic>>(
      onListen: () {
        for (final mailbox in mailboxes) {
          _watchers.putIfAbsent(mailbox, () => <_LocalWatcher>{}).add(watcher);
          _pushTo(watcher, mailbox);
        }
        // Leases that ran out come back this way.
        watcher.recheck = Timer.periodic(const Duration(seconds: 20), (_) {
          for (final mailbox in mailboxes) {
            _pushTo(watcher, mailbox);
          }
        });
      },
      onCancel: () {
        watcher.recheck?.cancel();
        for (final mailbox in mailboxes) {
          final set = _watchers[mailbox];
          set?.remove(watcher);
          if (set != null && set.isEmpty) _watchers.remove(mailbox);
        }
      },
    );
    watcher = _LocalWatcher(controller, leaseFor);
    return controller.stream;
  }

  void _pushTo(_LocalWatcher watcher, String mailbox) {
    if (watcher.controller.isClosed) return;
    final fresh = <Map<String, dynamic>>[];
    final (envelopes, leaseId) = _fetchLeased(
      mailbox,
      maxFetchLimit,
      watcher.leaseFor,
    );
    for (final envelope in envelopes) {
      if (envelope.kind == 'pairing_announcement') {
        // They stay queued: pushed once each.
        final key = '${envelope.senderDeviceId}/${envelope.messageId}';
        if (!watcher.pushedPairing.add(key)) continue;
        if (watcher.pushedPairing.length > 64) {
          watcher.pushedPairing.remove(watcher.pushedPairing.first);
        }
      }
      fresh.add(envelope.toJson());
    }
    if (fresh.isEmpty) return;
    watcher.controller.add({
      'mailbox': mailbox,
      'messages': fresh,
      'lease_id': leaseId,
    });
  }

  List<RelayEnvelope> _fetch(String recipientDeviceId, int requestedLimit) {
    _validateMailboxId(recipientDeviceId);
    final limit = requestedLimit.clamp(1, maxFetchLimit);
    final queue = _queues.putIfAbsent(recipientDeviceId, Queue.new);
    final messages = <RelayEnvelope>[];
    final entries = queue.toList(growable: false);
    queue.clear();
    _releaseExpiredLeases(entries);
    for (final entry in entries) {
      if (entry.leaseId == null && messages.length < limit) {
        messages.add(entry.envelope);
        if (entry.envelope.kind == 'pairing_announcement') {
          queue.add(entry);
        }
      } else {
        queue.add(entry);
      }
    }
    return messages;
  }

  void _releaseExpiredLeases(Iterable<_QueueEntry> entries) {
    final now = _nowProvider().toUtc();
    for (final entry in entries) {
      final until = entry.leaseUntil;
      if (until != null && !now.isBefore(until)) {
        entry
          ..leaseId = null
          ..leaseUntil = null;
      }
    }
  }

  /// The durable fetch (as the standalone relay's `fetch_leased`): what is
  /// returned stays queued, hidden, until [_acknowledge] or its lease ends.
  (List<RelayEnvelope>, String?) _fetchLeased(
    String recipientDeviceId,
    int requestedLimit,
    Duration leaseFor,
  ) {
    _validateMailboxId(recipientDeviceId);
    final limit = requestedLimit.clamp(1, maxFetchLimit);
    final queue = _queues.putIfAbsent(recipientDeviceId, Queue.new);
    _releaseExpiredLeases(queue);
    final random = Random.secure();
    final leaseId = base64Encode(
      List<int>.generate(18, (_) => random.nextInt(256)),
    );
    final until = _nowProvider().toUtc().add(leaseFor);
    final messages = <RelayEnvelope>[];
    var leased = false;
    for (final entry in queue) {
      if (entry.leaseId != null || messages.length >= limit) continue;
      messages.add(entry.envelope);
      if (entry.envelope.kind != 'pairing_announcement') {
        entry
          ..leaseId = leaseId
          ..leaseUntil = until;
        leased = true;
      }
    }
    return (messages, leased ? leaseId : null);
  }

  void _acknowledge(String recipientDeviceId, String leaseId) {
    _validateMailboxId(recipientDeviceId);
    if (leaseId.length < 16 || leaseId.length > 128) {
      throw ArgumentError('lease id has an invalid length');
    }
    _queues[recipientDeviceId]?.removeWhere(
      (entry) => entry.leaseId == leaseId,
    );
  }

  bool _allowRequest(String peer) {
    final now = _nowProvider().toUtc();
    _rateBuckets.removeWhere(
      (_, bucket) =>
          now.difference(bucket.windowStarted) >= const Duration(minutes: 2),
    );
    final bucket = _rateBuckets.putIfAbsent(
      peer,
      () => _RateBucket(windowStarted: now),
    );
    if (now.difference(bucket.windowStarted) >= const Duration(minutes: 1)) {
      bucket.windowStarted = now;
      bucket.count = 0;
    }
    if (bucket.count >= maxRequestsPerMinute) {
      return false;
    }
    bucket.count++;
    return true;
  }

  void _validateMailboxId(String value) {
    if (value.isEmpty || value.length > 160) {
      throw ArgumentError('mailbox id must be 1..160 characters');
    }
    for (final codeUnit in value.codeUnits) {
      final isAlphaNumeric =
          (codeUnit >= 48 && codeUnit <= 57) ||
          (codeUnit >= 65 && codeUnit <= 90) ||
          (codeUnit >= 97 && codeUnit <= 122);
      final isAllowedSymbol =
          codeUnit == 45 || codeUnit == 95 || codeUnit == 46 || codeUnit == 58;
      if (!isAlphaNumeric && !isAllowedSymbol) {
        throw ArgumentError('mailbox id contains unsupported characters');
      }
    }
  }

  void _cleanup() {
    final cutoff = _nowProvider().toUtc().subtract(ttl);
    final recipients = _queues.keys.toList(growable: false);
    for (final recipient in recipients) {
      final queue = _queues[recipient];
      if (queue == null) {
        continue;
      }
      while (queue.isNotEmpty && queue.first.queuedAt.isBefore(cutoff)) {
        queue.removeFirst();
      }
      if (queue.isEmpty) {
        _queues.remove(recipient);
      }
    }
  }
}

/// The keys an in-app relay with an identity seed derives (as the
/// standalone relay does: the same seed, the same keys).
class _LocalRelayIdentity {
  _LocalRelayIdentity({
    required this.signing,
    required this.publicKeyBase64,
    required this.noise,
    required this.v2Info,
  });

  final SimpleKeyPair signing;
  final String publicKeyBase64;
  final SimpleKeyPair noise;
  final Map<String, dynamic> v2Info;

  static Future<_LocalRelayIdentity> fromSeed(List<int> seed) async {
    final ed25519 = Ed25519();
    final signing = await ed25519.newKeyPairFromSeed(seed);
    final publicKey = (await signing.extractPublicKey()).bytes;
    final noiseSeed = (await Sha256().hash([
      ...utf8.encode('conest-relay-noise-static-v1'),
      ...seed,
    ])).bytes;
    final noise = await X25519().newKeyPairFromSeed(noiseSeed);
    final noisePublic = (await noise.extractPublicKey()).bytes;
    final binding = await ed25519.sign([
      ...utf8.encode('conest-relay-noise-key-v1'),
      ...noisePublic,
    ], keyPair: signing);
    return _LocalRelayIdentity(
      signing: signing,
      publicKeyBase64: base64Encode(publicKey),
      noise: noise,
      v2Info: {
        'sessions': 1,
        'noise': 'Noise_NK_25519_ChaChaPoly_SHA256',
        'noise_key': base64Encode(noisePublic),
        'noise_key_sig': base64Encode(binding.bytes),
      },
    );
  }
}

class _LocalWatcher {
  _LocalWatcher(this.controller, this.leaseFor);

  final StreamController<Map<String, dynamic>> controller;
  final Duration leaseFor;
  Timer? recheck;
  final Set<String> pushedPairing = <String>{};
}

class _RateBucket {
  _RateBucket({required this.windowStarted});

  DateTime windowStarted;
  int count = 0;
}

class _QueueEntry {
  _QueueEntry({required this.queuedAt, required this.envelope});

  final DateTime queuedAt;
  final RelayEnvelope envelope;

  /// Handed out under a lease until acknowledged or [leaseUntil].
  String? leaseId;
  DateTime? leaseUntil;
}

class _RelayWireRequest {
  const _RelayWireRequest({required this.isHttp, required this.request});

  final bool isHttp;
  final Map<String, dynamic> request;
}

class _HttpHeaderEnd {
  const _HttpHeaderEnd({
    required this.headerBytes,
    required this.totalHeaderBytes,
  });

  final int headerBytes;
  final int totalHeaderBytes;
}

Future<List<String>> discoverLanAddresses() async {
  final addresses = <String>{};
  final List<NetworkInterface> interfaces;
  try {
    interfaces = await NetworkInterface.list(
      includeLoopback: false,
      type: InternetAddressType.IPv4,
    );
  } on SocketException {
    return const <String>[];
  } on OSError {
    return const <String>[];
  }
  for (final interface in interfaces) {
    if (isIgnoredLanInterfaceName(interface.name)) {
      continue;
    }
    for (final address in interface.addresses) {
      if (isLanDiscoveryAddress(address.address)) {
        addresses.add(address.address);
      }
    }
  }
  final values = addresses.toList()..sort();
  return values;
}

bool isIgnoredLanInterfaceName(String name) {
  final normalized = name.toLowerCase();
  const ignoredFragments = <String>[
    'br-',
    'bridge',
    'docker',
    'hyper-v',
    'tailscale',
    'tap',
    'tun',
    'vbox',
    'vethernet',
    'virtualbox',
    'vmnet',
    'vmware',
    'vpn',
    'veth',
    'wsl',
    'zerotier',
    // Virtual machine and container bridges (libvirt, LXC/LXD/Incus,
    // Podman, Kubernetes CNI, Waydroid) and WireGuard tunnels.
    'virbr',
    'lxcbr',
    'lxdbr',
    'incusbr',
    'podman',
    'cni',
    'waydroid',
    'wg',
    // Android mobile data (Qualcomm, MediaTek) and its IPv4 translation.
    'rmnet',
    'ccmni',
    'clat',
  ];
  return ignoredFragments.any(normalized.contains);
}

bool isLanDiscoveryAddress(String address) {
  if (address.startsWith('10.') || address.startsWith('192.168.')) {
    return true;
  }
  if (address.startsWith('169.254.')) {
    return true;
  }
  if (address.startsWith('172.')) {
    final parts = address.split('.');
    if (parts.length > 1) {
      final second = int.tryParse(parts[1]);
      if (second != null && second >= 16 && second <= 31) {
        return true;
      }
    }
  }
  return false;
}

/// Whether [address] is on this device or its local network (loopback,
/// link-local, private IPv4 ranges, IPv6 unique local).
bool isLocalNetworkAddress(String address) {
  final parsed = InternetAddress.tryParse(address);
  if (parsed == null) return false;
  if (parsed.isLoopback || parsed.isLinkLocal) return true;
  final bytes = parsed.rawAddress;
  if (parsed.type == InternetAddressType.IPv4) {
    return bytes[0] == 10 ||
        (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] < 32) ||
        (bytes[0] == 192 && bytes[1] == 168);
  }
  return (bytes[0] & 0xfe) == 0xfc;
}
