import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io' show SocketException;
import 'dart:math';
import 'dart:typed_data';

import 'xmpp_registration.dart';
import 'xmpp_sasl.dart';
import 'xmpp_socket.dart';
import 'xmpp_xml.dart';

/// An error answer to a request (`<iq type='error'>`).
class XmppStanzaError implements Exception {
  const XmppStanzaError(this.condition, [this.text]);

  /// The defined condition, such as `conflict` or `not-allowed`.
  final String condition;
  final String? text;

  @override
  String toString() =>
      'XMPP error: $condition${text == null ? '' : ' ($text)'}';
}

/// The server ended the stream with an error.
class XmppStreamError implements Exception {
  const XmppStreamError(this.condition, [this.text]);
  final String condition;
  final String? text;
  @override
  String toString() =>
      'XMPP stream error: $condition${text == null ? '' : ' ($text)'}';
}

/// The account's name or password is wrong (SASL `not-authorized`).
class XmppAuthException implements Exception {
  const XmppAuthException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// What the server offered once the stream was set up.
class XmppFeatures {
  XmppFeatures(this.element);

  final XmppElement element;

  bool get startTls => element.child('starttls', XmppNs.tls) != null;
  bool get startTlsRequired =>
      element.child('starttls', XmppNs.tls)?.child('required') != null;
  List<String> get mechanisms => [
    for (final mechanism
        in element.child('mechanisms', XmppNs.sasl)?.all('mechanism') ??
            const <XmppElement>[])
      mechanism.text.trim(),
  ];
  bool get bind => element.child('bind', XmppNs.bind) != null;

  /// Session establishment that is not marked optional (old servers).
  bool get sessionRequired {
    final session = element.child('session', XmppNs.session);
    return session != null && session.child('optional') == null;
  }

  bool get streamManagement => element.child('sm', XmppNs.sm) != null;
  bool get csi => element.child('csi', XmppNs.csi) != null;
  bool get register =>
      element.child('register', XmppNs.registerFeature) != null;
}

/// Reads stream events one at a time, with a timeout per read.
class _EventQueue {
  _EventQueue(Stream<XmppStreamEvent> events) {
    _subscription = events.listen(
      (event) {
        if (_waiter case final waiter?) {
          _waiter = null;
          waiter.complete(event);
        } else if (_buffer.length >= _maxBuffered) {
          // Nobody is reading (the user is answering a question) and the
          // server keeps talking: the attempt fails.
          _error ??= const XmppProtocolException('The server sent too much.');
          unawaited(_subscription.cancel());
        } else {
          _buffer.add(event);
        }
      },
      onError: (Object error) {
        _error = error;
        if (_waiter case final waiter?) {
          _waiter = null;
          waiter.completeError(error);
        }
      },
      onDone: () {
        _error ??= const SocketException('Connection closed.');
        if (_waiter case final waiter?) {
          _waiter = null;
          waiter.completeError(_error!);
        }
      },
    );
  }

  /// Most stream events held while nobody reads.
  static const int _maxBuffered = 64;

  late final StreamSubscription<XmppStreamEvent> _subscription;
  final Queue<XmppStreamEvent> _buffer = Queue();
  Completer<XmppStreamEvent>? _waiter;
  Object? _error;

  Future<XmppStreamEvent> next(Duration timeout) {
    if (_buffer.isNotEmpty) return Future.value(_buffer.removeFirst());
    if (_error case final error?) return Future.error(error);
    final waiter = _waiter = Completer<XmppStreamEvent>();
    return waiter.future.timeout(
      timeout,
      onTimeout: () {
        if (identical(_waiter, waiter)) _waiter = null;
        throw TimeoutException('The XMPP server did not answer.');
      },
    );
  }

  /// The next element; a stream error or end becomes an exception.
  Future<XmppElement> element(Duration timeout) async {
    final event = await next(timeout);
    return switch (event) {
      XmppStreamElement(:final element) => _checkStreamError(element),
      XmppStreamOpened() => throw const XmppProtocolException(
        'Unexpected stream header.',
      ),
      XmppStreamClosed() => throw const SocketException(
        'The server closed the stream.',
      ),
    };
  }

  /// Throws what already went wrong with the stream (too much was sent
  /// while nobody was reading, or it closed).
  void ensureHealthy() {
    if (_error case final error?) throw error;
  }

  Future<void> cancel() => _subscription.cancel();
}

XmppElement _checkStreamError(XmppElement element) {
  if (element.name == 'error' && element.xmlns == XmppNs.stream) {
    final condition = element.children
        .where((child) => child.xmlns == XmppNs.streams && child.name != 'text')
        .firstOrNull
        ?.name;
    throw XmppStreamError(
      condition == null ? 'undefined-condition' : serverText(condition, 64),
      _bounded(element.childText('text', XmppNs.streams)),
    );
  }
  return element;
}

String? _bounded(String? text) => text == null ? null : serverText(text);

/// The condition of an error stanza.
XmppStanzaError stanzaErrorOf(XmppElement stanza) {
  final error = stanza.child('error');
  final condition = error?.children
      .where((child) => child.xmlns == XmppNs.stanzas && child.name != 'text')
      .firstOrNull
      ?.name;
  return XmppStanzaError(
    condition == null ? 'undefined-condition' : serverText(condition, 64),
    _bounded(error?.childText('text', XmppNs.stanzas)),
  );
}

/// Opens a wire to [endpoint].
Future<XmppWire> openXmppWire(
  XmppEndpoint endpoint, {
  XmppSocketConnector connector = connectXmppSocket,
  XmppWebSocketConnector webSocketConnector = connectXmppWebSocket,
}) async {
  switch (endpoint.mode) {
    case XmppEndpointMode.directTls:
      return XmppTcpWire(
        await connector(
          endpoint.host,
          endpoint.port,
          tls: true,
          alpn: 'xmpp-client',
        ),
      );
    case XmppEndpointMode.startTls:
      return XmppTcpWire(
        await connector(endpoint.host, endpoint.port, tls: false),
      );
    case XmppEndpointMode.plainLoopback:
      if (!isLoopbackHost(endpoint.host)) {
        throw const XmppProtocolException('No TLS is only for this machine.');
      }
      return XmppTcpWire(
        await connector(endpoint.host, endpoint.port, tls: false),
      );
    case XmppEndpointMode.webSocket:
      return XmppWebSocketWire(
        await webSocketConnector(Uri.parse(endpoint.webSocketUrl!)),
      );
  }
}

const Duration _answerTimeout = Duration(seconds: 30);
const Duration _registrationDeadline = Duration(seconds: 60);
const int _maxUnrelated = 32;

/// Opens the stream and upgrades it with STARTTLS when it is not secure;
/// returns the features of the (secure) stream. Without TLS, only a
/// loopback endpoint may go on.
Future<XmppFeatures> _openSecureStream(
  XmppWire wire,
  _EventQueue queue,
  String domain,
  XmppEndpoint endpoint,
) async {
  Future<XmppFeatures> open() async {
    wire.openStream(domain);
    final header = await queue.next(_answerTimeout);
    if (header is! XmppStreamOpened) {
      if (header is XmppStreamElement) _checkStreamError(header.element);
      throw const XmppProtocolException('No stream header.');
    }
    final features = await queue.element(_answerTimeout);
    if (features.name != 'features' || features.xmlns != XmppNs.stream) {
      throw const XmppProtocolException('No stream features.');
    }
    return XmppFeatures(features);
  }

  var features = await open();
  if (!wire.secure) {
    // A local lab server (plain loopback) is used as it is, even when it
    // offers STARTTLS with a certificate nobody could check.
    if (features.startTls &&
        wire.canStartTls &&
        endpoint.mode != XmppEndpointMode.plainLoopback) {
      wire.send(XmppElement('starttls', xmlns: XmppNs.tls));
      final answer = await queue.element(_answerTimeout);
      if (answer.name != 'proceed') {
        throw const XmppProtocolException('The server refused STARTTLS.');
      }
      await wire.startTls(endpoint.host);
      features = await open();
    } else if (endpoint.mode != XmppEndpointMode.plainLoopback) {
      throw const XmppProtocolException(
        'The server does not offer TLS; Conest never signs in without it.',
      );
    }
  }
  return features;
}

/// Signs in with SASL; returns once the server accepted.
Future<void> _authenticate(
  XmppWire wire,
  _EventQueue queue,
  XmppFeatures features,
  String username,
  String password,
) async {
  final mechanism = chooseSaslMechanism(
    features.mechanisms,
    secure: wire.secure,
  );
  if (mechanism == null) {
    throw const XmppAuthException(
      'The server offers no sign-in method Conest accepts.',
    );
  }
  ScramClient? scram;
  final Uint8List initial;
  if (mechanism == 'PLAIN') {
    initial = plainInitialResponse(username, password);
  } else {
    scram = ScramClient(
      mechanism: mechanism,
      username: username,
      password: password,
    );
    initial = scram.first();
  }
  wire.send(
    XmppElement(
      'auth',
      xmlns: XmppNs.sasl,
      attributes: {'mechanism': mechanism},
      text: base64.encode(initial),
    ),
  );
  var rounds = 0;
  while (true) {
    final answer = await queue.element(_answerTimeout);
    if (answer.xmlns != XmppNs.sasl) {
      throw const XmppProtocolException('Unexpected answer to sign-in.');
    }
    Uint8List payload() {
      final text = answer.text.trim();
      if (text.isEmpty || text == '=') return Uint8List(0);
      try {
        return base64.decode(text);
      } on FormatException {
        throw const XmppSaslException('malformed SASL data');
      }
    }

    switch (answer.name) {
      case 'challenge':
        if (scram == null || ++rounds > 1) {
          throw const XmppSaslException('unexpected challenge');
        }
        wire.send(
          XmppElement(
            'response',
            xmlns: XmppNs.sasl,
            text: base64.encode(scram.respond(payload())),
          ),
        );
      case 'success':
        // SCRAM's proof that the server knows the password.
        if (scram != null) {
          if (rounds == 0) {
            throw const XmppSaslException('success without a challenge');
          }
          scram.verify(payload());
        }
        return;
      case 'failure':
        final condition = answer.children.firstOrNull?.name ?? 'not-authorized';
        if (condition == 'not-authorized' ||
            condition == 'account-disabled' ||
            condition == 'credentials-expired') {
          throw XmppAuthException(
            'The server refused the account name or password ($condition).',
          );
        }
        throw XmppSaslException(condition);
      default:
        throw const XmppProtocolException('Unexpected answer to sign-in.');
    }
  }
}

/// In-band registration (XEP-0077) of [username] with [password] on the
/// server behind [endpoint]. Throws [XmppStanzaError] (`conflict` when the
/// name is taken, `not-allowed` or `forbidden` when sign-up is closed),
/// [XmppRegistrationRedirect] when the server registers on its web page,
/// [XmppCaptchaRequired] when it asks for a CAPTCHA and [captchaSolver] gave
/// no answer, or [XmppRegistrationNeedsMore] when it needs more than that.
Future<void> registerXmppAccount({
  required XmppEndpoint endpoint,
  required String domain,
  required String username,
  required String password,
  XmppSocketConnector connector = connectXmppSocket,
  XmppWebSocketConnector webSocketConnector = connectXmppWebSocket,
  XmppCaptchaSolver? captchaSolver,
}) async {
  final wire = await openXmppWire(
    endpoint,
    connector: connector,
    webSocketConnector: webSocketConnector,
  );
  final queue = _EventQueue(wire.events);
  try {
    final features = await _openSecureStream(wire, queue, domain, endpoint);
    if (!features.register) {
      throw const XmppStanzaError(
        'not-allowed',
        'The server does not offer in-band registration.',
      );
    }
    Future<XmppElement> iq(String type, XmppElement query, String id) async {
      wire.send(
        XmppElement(
          'iq',
          attributes: {'type': type, 'id': id},
          children: [query],
        ),
      );
      // One answer in 30 s at most 60 s in all (the user's time at a
      // CAPTCHA is not part of it), and a few unrelated stanzas.
      final deadline = DateTime.now().add(_registrationDeadline);
      var others = 0;
      while (true) {
        final left = deadline.difference(DateTime.now());
        if (left <= Duration.zero || ++others > _maxUnrelated) {
          throw TimeoutException('The XMPP server did not answer.');
        }
        final answer = await queue.element(
          left < _answerTimeout ? left : _answerTimeout,
        );
        if (answer.name != 'iq' || answer.attr('id') != id) continue;
        if (answer.attr('type') == 'error') throw stanzaErrorOf(answer);
        return answer;
      }
    }

    final answer = await iq(
      'get',
      XmppElement('query', xmlns: XmppNs.register),
      'reg1',
    );
    final query = answer.child('query', XmppNs.register);
    if (query == null) {
      throw const XmppProtocolException(
        'The server needs more than a name and password to register.',
      );
    }
    final form = parseRegistrationForm(query);
    if (!form.hasNameAndPassword) {
      // Signing up happens on a web page.
      if (form.redirect case final url?) throw XmppRegistrationRedirect(url);
      throw const XmppProtocolException(
        'The server needs more than a name and password to register.',
      );
    }
    // More required fields (an email address, an invite) cannot be filled
    // in automatically.
    if (form.unsupported.isNotEmpty) {
      throw XmppRegistrationNeedsMore(form.unsupported);
    }
    String? captchaAnswer;
    if (form.captcha case final challenge?) {
      if (captchaSolver == null) throw const XmppCaptchaRequired();
      captchaAnswer = (await captchaSolver(
        challenge.forDomain(domain),
      ))?.trim();
      // No answer is the user giving up: setup stops.
      if (captchaAnswer == null) throw const XmppRegistrationCancelled();
      if (captchaAnswer.isEmpty) throw const XmppCaptchaRequired();
      // Nothing is sent to a server that misbehaved meanwhile.
      queue.ensureHealthy();
    }
    await iq(
      'set',
      registrationSubmission(
        form,
        username: username,
        password: password,
        answer: captchaAnswer,
      ),
      'reg2',
    );
  } finally {
    await queue.cancel();
    await wire.close();
  }
}

/// Connects to [endpoint] far enough to read the stream features over TLS
/// (no sign-in), for probing which servers answer here. Returns the
/// features, or throws.
Future<XmppFeatures> probeXmppEndpoint({
  required XmppEndpoint endpoint,
  required String domain,
  XmppSocketConnector connector = connectXmppSocket,
  XmppWebSocketConnector webSocketConnector = connectXmppWebSocket,
}) async {
  final wire = await openXmppWire(
    endpoint,
    connector: connector,
    webSocketConnector: webSocketConnector,
  );
  final queue = _EventQueue(wire.events);
  try {
    return await _openSecureStream(wire, queue, domain, endpoint);
  } finally {
    await queue.cancel();
    await wire.close();
  }
}

enum XmppSessionState { stopped, connecting, connected, failed }

/// A stanza waiting for the server's acknowledgement (XEP-0198).
class _Outgoing {
  _Outgoing(this.stanza) {
    // Stanzas nobody waits for (presence, replies) fail quietly on stop.
    done.future.ignore();
  }

  final XmppElement stanza;
  final Completer<void> done = Completer();
}

/// One signed-in XMPP connection that keeps itself up: it reconnects with
/// backoff, resumes with stream management when the server allows (so no
/// stanza is lost across a dropped connection), answers pings and
/// acknowledgement requests, and refuses unknown requests politely.
class XmppSession {
  XmppSession({
    required this.jid,
    required this.password,
    required this.resource,
    required List<XmppEndpoint> endpoints,
    this.connector = connectXmppSocket,
    this.webSocketConnector = connectXmppWebSocket,
    int priority = 0,
    this.carbons = false,
    this.onStanza,
    this.onStateChanged,
    this.onConnected,
    this.onEndpoint,
    this.log,
    this.keepAlive = const Duration(seconds: 90),
    this.maxQueued = 512,
    this.retryDelay = const Duration(seconds: 2),
    DateTime Function()? now,
  }) : _priority = priority,
       _endpoints = List.of(endpoints),
       _now = now ?? DateTime.now;

  /// The account, `local@domain`.
  final String jid;
  final String password;
  final String resource;
  final XmppSocketConnector connector;
  final XmppWebSocketConnector webSocketConnector;

  /// Presence priority: negative keeps the account's ordinary chats away
  /// from this resource (the user's own account).
  int get priority => _priority;
  int _priority;

  /// Changes the presence priority (chats turned on for the account
  /// Conest also carries through), telling the server at once.
  void setPriority(int priority) {
    if (_priority == priority) return;
    _priority = priority;
    if (_state == XmppSessionState.connected) {
      _writeNow(
        XmppElement(
          'presence',
          children: [XmppElement('priority', text: '$_priority')],
        ),
      );
    }
  }

  final List<void Function(XmppElement stanza)> _stanzaListeners = [];
  final List<void Function(bool resumed)> _connectedListeners = [];

  /// Another user of this connection (the chats sharing the carrier's
  /// account) hears every stanza and every (re)connection too.
  void addListener({
    void Function(XmppElement stanza)? onStanza,
    void Function(bool resumed)? onConnected,
  }) {
    if (onStanza != null) _stanzaListeners.add(onStanza);
    if (onConnected != null) _connectedListeners.add(onConnected);
  }

  void removeListener({
    void Function(XmppElement stanza)? onStanza,
    void Function(bool resumed)? onConnected,
  }) {
    _stanzaListeners.remove(onStanza);
    _connectedListeners.remove(onConnected);
  }

  void _emitStanza(XmppElement stanza) {
    onStanza?.call(stanza);
    for (final listener in List.of(_stanzaListeners)) {
      listener(stanza);
    }
  }

  /// Asks for copies of this account's messages on other clients (XEP-0280).
  final bool carbons;

  /// Every stanza received (messages, presence, requests not answered here).
  final void Function(XmppElement stanza)? onStanza;
  final void Function()? onStateChanged;

  /// Called each time the session is (re)established; [resumed] when no
  /// stanza was lost.
  final void Function(bool resumed)? onConnected;

  /// The endpoint that worked, to try first next time.
  final void Function(XmppEndpoint endpoint)? onEndpoint;
  final void Function(String line)? log;
  final Duration keepAlive;

  /// Most stanzas waiting to go out or for acknowledgement.
  final int maxQueued;

  /// The first wait before reconnecting; it doubles up to 5 minutes.
  final Duration retryDelay;
  final DateTime Function() _now;
  final List<XmppEndpoint> _endpoints;

  String get domain => jid.substring(jid.indexOf('@') + 1);
  String get _local => jid.substring(0, jid.indexOf('@'));

  XmppSessionState _state = XmppSessionState.stopped;
  XmppSessionState get state => _state;
  String? _lastError;
  String? get lastError => _lastError;

  /// The server refused the name or password; the session stopped trying.
  bool get authFailed => _authFailed;
  bool _authFailed = false;

  /// The full JID the server bound, once connected.
  String? get boundJid => _boundJid;
  String? _boundJid;

  /// The endpoint now in use.
  XmppEndpoint? get endpoint => _endpoint;
  XmppEndpoint? _endpoint;

  bool _started = false;
  int _generation = 0;
  XmppWire? _wire;
  _EventQueue? _queue;
  Timer? _keepAliveTimer;
  DateTime _lastInbound = DateTime.fromMillisecondsSinceEpoch(0);
  bool _active = true;

  // Stream management.
  String? _smId;
  bool _smEnabled = false;
  int _inboundCount = 0;
  int _ackedOut = 0;
  final Queue<_Outgoing> _unacked = Queue();
  final Queue<_Outgoing> _waiting = Queue();

  final Map<String, (Completer<XmppElement>, String?)> _requests = {};
  int _nextId = 0;
  final String _idPrefix = () {
    final random = Random.secure();
    return List.generate(
      6,
      (_) => 'abcdefghijklmnopqrstuvwxyz0123456789'[random.nextInt(36)],
    ).join();
  }();

  /// A fresh stanza id.
  String newId() => '$_idPrefix${_nextId++}';

  void start() {
    if (_started) return;
    _started = true;
    _authFailed = false;
    unawaited(_run(++_generation));
  }

  Future<void> stop() async {
    _started = false;
    _generation++;
    _keepAliveTimer?.cancel();
    final wire = _wire;
    _wire = null;
    await _queue?.cancel();
    _queue = null;
    if (wire != null) {
      // Unavailable presence first, so contacts see this resource leave.
      try {
        wire.send(XmppElement('presence', attributes: {'type': 'unavailable'}));
      } catch (_) {}
      await wire.close().catchError((Object _) {});
    }
    _smId = null;
    _smEnabled = false;
    for (final pending in [..._unacked, ..._waiting]) {
      if (!pending.done.isCompleted) {
        pending.done.completeError(StateError('XMPP stopped.'));
      }
    }
    _unacked.clear();
    _waiting.clear();
    _failRequests(StateError('XMPP stopped.'));
    _setState(XmppSessionState.stopped);
  }

  /// Sends [stanza]; completes once the server acknowledged it (with stream
  /// management) or wrote it. While disconnected it waits in a bounded
  /// queue and goes out after reconnecting.
  Future<void> send(XmppElement stanza) {
    if (!_started) return Future.error(StateError('XMPP is not running.'));
    if (_unacked.length + _waiting.length >= maxQueued) {
      return Future.error(StateError('Too many XMPP stanzas waiting.'));
    }
    final outgoing = _Outgoing(stanza);
    if (_state == XmppSessionState.connected && _wire != null) {
      _write(outgoing);
    } else {
      _waiting.add(outgoing);
    }
    return outgoing.done.future;
  }

  /// Sends a request (`iq` get or set) and returns the result; an error
  /// answer throws [XmppStanzaError]. Only an answer from the address the
  /// request went to counts (or the server or this account for requests
  /// without one), so others cannot answer in its name.
  Future<XmppElement> request(
    XmppElement iq, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final id = iq.attributes['id'] ??= newId();
    if (_requests.length >= 256) {
      throw StateError('Too many XMPP requests waiting.');
    }
    final completer = Completer<XmppElement>();
    _requests[id] = (completer, iq.attr('to'));
    unawaited(
      send(iq).catchError((Object error) {
        if (!completer.isCompleted) completer.completeError(error);
      }),
    );
    try {
      final answer = await completer.future.timeout(timeout);
      if (answer.attr('type') == 'error') throw stanzaErrorOf(answer);
      return answer;
    } finally {
      _requests.remove(id);
    }
  }

  /// Client state indication (XEP-0352): the app is in use or not, so the
  /// server can hold back unimportant traffic in the background.
  void setActive(bool active) {
    if (_active == active) return;
    _active = active;
    _sendCsi();
  }

  bool _csiSupported = false;

  void _sendCsi() {
    final wire = _wire;
    if (wire == null ||
        !_csiSupported ||
        _state != XmppSessionState.connected) {
      return;
    }
    try {
      wire.send(
        XmppElement(_active ? 'active' : 'inactive', xmlns: XmppNs.csi),
      );
    } catch (_) {}
  }

  void _write(_Outgoing outgoing) {
    final wire = _wire;
    if (wire == null) {
      _waiting.add(outgoing);
      return;
    }
    try {
      wire.send(outgoing.stanza);
    } catch (error) {
      _waiting.addFirst(outgoing);
      return;
    }
    if (_smEnabled) {
      _unacked.add(outgoing);
      _requestAckSoon();
    } else if (!outgoing.done.isCompleted) {
      outgoing.done.complete();
    }
  }

  bool _ackRequested = false;

  void _requestAckSoon() {
    if (_ackRequested) return;
    _ackRequested = true;
    scheduleMicrotask(() {
      _ackRequested = false;
      try {
        _wire?.send(XmppElement('r', xmlns: XmppNs.sm));
      } catch (_) {}
    });
  }

  void _setState(XmppSessionState state) {
    if (_state == state) return;
    _state = state;
    onStateChanged?.call();
  }

  void _failRequests(Object error) {
    for (final (completer, _) in _requests.values) {
      if (!completer.isCompleted) completer.completeError(error);
    }
    _requests.clear();
  }

  Future<void> _run(int generation) async {
    bool current() => _started && generation == _generation;
    var backoff = retryDelay;
    final random = Random();
    while (current()) {
      try {
        _setState(XmppSessionState.connecting);
        await _connectOnce(generation);
        if (!current()) return;
        backoff = retryDelay;
        await _readLoop(generation);
      } on XmppAuthException catch (error) {
        // A wrong password is not retried: servers lock accounts that keep
        // trying.
        if (!current()) return;
        _lastError = error.message;
        _authFailed = true;
        log?.call('XMPP: ${error.message}');
        await _dropWire();
        _setState(XmppSessionState.failed);
        _started = false;
        return;
      } catch (error) {
        if (!current()) return;
        _lastError = '$error';
        log?.call('XMPP connection to $domain: $error');
        await _dropWire();
        _setState(XmppSessionState.failed);
      }
      if (!current()) return;
      final jitter = Duration(
        milliseconds: random.nextInt(backoff.inMilliseconds ~/ 2 + 1),
      );
      await Future<void>.delayed(backoff + jitter);
      backoff = backoff * 2 > const Duration(minutes: 5)
          ? const Duration(minutes: 5)
          : backoff * 2;
    }
  }

  Future<void> _dropWire() async {
    _keepAliveTimer?.cancel();
    final wire = _wire;
    _wire = null;
    await _queue?.cancel();
    _queue = null;
    if (wire != null) await wire.close().catchError((Object _) {});
    _failRequests(const SocketException('XMPP connection lost.'));
    // Stanzas sent but not acknowledged wait for the resume (or resend).
    if (!_smEnabled) return;
    _smEnabled = false;
  }

  Future<void> _connectOnce(int generation) async {
    Object? lastError;
    for (final endpoint in List.of(_endpoints)) {
      if (!_started || generation != _generation) return;
      try {
        await _connectTo(endpoint, generation);
        if (_endpoints.first != endpoint) {
          _endpoints
            ..remove(endpoint)
            ..insert(0, endpoint);
        }
        onEndpoint?.call(endpoint);
        return;
      } on XmppAuthException {
        rethrow;
      } catch (error) {
        lastError = error;
        log?.call('XMPP: ${endpoint.label} failed: $error');
        await _dropWire();
      }
    }
    throw lastError ?? StateError('No XMPP server address.');
  }

  Future<void> _connectTo(XmppEndpoint endpoint, int generation) async {
    final wire = await openXmppWire(
      endpoint,
      connector: connector,
      webSocketConnector: webSocketConnector,
    );
    if (!_started || generation != _generation) {
      await wire.close();
      return;
    }
    _wire = wire;
    final queue = _queue = _EventQueue(wire.events);
    final features = await _openSecureStream(wire, queue, domain, endpoint);
    await _authenticate(wire, queue, features, _local, password);
    wire.openStream(domain);
    final header = await queue.next(_answerTimeout);
    if (header is! XmppStreamOpened) {
      throw const XmppProtocolException('No stream header after sign-in.');
    }
    final bound = XmppFeatures(await queue.element(_answerTimeout));
    _csiSupported = bound.csi;
    _endpoint = endpoint;
    var resumed = false;
    if (bound.streamManagement && _smId != null) {
      wire.send(
        XmppElement(
          'resume',
          xmlns: XmppNs.sm,
          attributes: {'previd': _smId!, 'h': '$_inboundCount'},
        ),
      );
      final answer = await queue.element(_answerTimeout);
      if (answer.name == 'resumed' && answer.xmlns == XmppNs.sm) {
        _handleAck(int.tryParse(answer.attr('h') ?? ''));
        resumed = true;
        _smEnabled = true;
        _boundJid ??= '$jid/$resource';
      } else {
        // The old session is gone: what it did not acknowledge goes again.
        _smId = null;
      }
    }
    if (!resumed) {
      await _bind(wire, queue, bound);
      final resend = [..._unacked, ..._waiting];
      _unacked.clear();
      _waiting
        ..clear()
        ..addAll(resend);
      _inboundCount = 0;
      _ackedOut = 0;
      if (bound.streamManagement) {
        wire.send(
          XmppElement(
            'enable',
            xmlns: XmppNs.sm,
            attributes: {'resume': 'true'},
          ),
        );
        final answer = await queue.element(_answerTimeout);
        if (answer.name == 'enabled' && answer.xmlns == XmppNs.sm) {
          _smEnabled = true;
          final resumable =
              answer.attr('resume') == 'true' || answer.attr('resume') == '1';
          _smId = resumable ? answer.attr('id') : null;
        }
      }
    } else {
      // What the server did not acknowledge goes again, ahead of new ones.
      final resend = List.of(_unacked);
      _unacked.clear();
      final rest = List.of(_waiting);
      _waiting
        ..clear()
        ..addAll(resend)
        ..addAll(rest);
    }
    _setState(XmppSessionState.connected);
    _lastError = null;
    _lastInbound = _now();
    if (!resumed) {
      if (carbons) {
        unawaited(
          request(
            XmppElement(
              'iq',
              attributes: {'type': 'set'},
              children: [XmppElement('enable', xmlns: XmppNs.carbons)],
            ),
          ).then((_) {}, onError: (Object _) {}),
        );
      }
      _writeNow(
        XmppElement(
          'presence',
          children: [XmppElement('priority', text: '$_priority')],
        ),
      );
    }
    _sendCsi();
    while (_waiting.isNotEmpty && _wire != null) {
      _write(_waiting.removeFirst());
    }
    _startKeepAlive(generation);
    onConnected?.call(resumed);
    for (final listener in List.of(_connectedListeners)) {
      listener(resumed);
    }
  }

  /// Sends a stanza that needs no completion (counted for acknowledgement
  /// like any other).
  void _writeNow(XmppElement stanza) => _write(_Outgoing(stanza));

  Future<void> _bind(
    XmppWire wire,
    _EventQueue queue,
    XmppFeatures features,
  ) async {
    if (!features.bind) {
      throw const XmppProtocolException('The server offers no resource.');
    }
    wire.send(
      XmppElement(
        'iq',
        attributes: {'type': 'set', 'id': 'bind1'},
        children: [
          XmppElement(
            'bind',
            xmlns: XmppNs.bind,
            children: [XmppElement('resource', text: resource)],
          ),
        ],
      ),
    );
    while (true) {
      final answer = await queue.element(_answerTimeout);
      if (answer.name != 'iq' || answer.attr('id') != 'bind1') continue;
      if (answer.attr('type') != 'result') throw stanzaErrorOf(answer);
      final full = answer.child('bind', XmppNs.bind)?.childText('jid')?.trim();
      if (full == null || bareJid(full) != jid.toLowerCase()) {
        throw const XmppProtocolException('The server bound another account.');
      }
      _boundJid = full;
      break;
    }
    if (features.sessionRequired) {
      wire.send(
        XmppElement(
          'iq',
          attributes: {'type': 'set', 'id': 'sess1'},
          children: [XmppElement('session', xmlns: XmppNs.session)],
        ),
      );
      while (true) {
        final answer = await queue.element(_answerTimeout);
        if (answer.name != 'iq' || answer.attr('id') != 'sess1') continue;
        if (answer.attr('type') != 'result') throw stanzaErrorOf(answer);
        break;
      }
    }
  }

  void _startKeepAlive(int generation) {
    _keepAliveTimer?.cancel();
    _keepAliveTimer = Timer.periodic(keepAlive, (_) {
      if (!_started || generation != _generation) return;
      final wire = _wire;
      if (wire == null) return;
      // Silent for two rounds after a ping: the connection is dead.
      if (_now().difference(_lastInbound) > keepAlive * 2) {
        log?.call('XMPP: $domain stopped answering; reconnecting');
        unawaited(wire.close().catchError((Object _) {}));
        return;
      }
      try {
        if (_smEnabled) {
          wire.send(XmppElement('r', xmlns: XmppNs.sm));
        } else {
          unawaited(
            request(
              XmppElement(
                'iq',
                attributes: {'type': 'get', 'to': domain},
                children: [XmppElement('ping', xmlns: XmppNs.ping)],
              ),
            ).then((_) {}, onError: (Object _) {}),
          );
        }
      } catch (_) {}
    });
  }

  Future<void> _readLoop(int generation) async {
    final queue = _queue;
    if (queue == null) return;
    while (_started && generation == _generation) {
      final XmppElement element;
      try {
        element = await queue.element(const Duration(days: 1));
      } on TimeoutException {
        continue;
      }
      _lastInbound = _now();
      _handle(element);
    }
  }

  void _handleAck(int? h) {
    if (h == null || h < 0) return;
    // Counters wrap at 2^32.
    var newlyAcked = (h - _ackedOut) & 0xffffffff;
    if (newlyAcked > _unacked.length) newlyAcked = _unacked.length;
    for (var index = 0; index < newlyAcked; index++) {
      final outgoing = _unacked.removeFirst();
      if (!outgoing.done.isCompleted) outgoing.done.complete();
    }
    _ackedOut = h;
  }

  void _handle(XmppElement element) {
    if (element.xmlns == XmppNs.sm) {
      switch (element.name) {
        case 'r':
          try {
            _wire?.send(
              XmppElement(
                'a',
                xmlns: XmppNs.sm,
                attributes: {'h': '${_inboundCount & 0xffffffff}'},
              ),
            );
          } catch (_) {}
        case 'a':
          _handleAck(int.tryParse(element.attr('h') ?? ''));
      }
      return;
    }
    if (element.xmlns != XmppNs.client) return;
    if (element.name != 'message' &&
        element.name != 'presence' &&
        element.name != 'iq') {
      return;
    }
    if (_smEnabled) _inboundCount = (_inboundCount + 1) & 0xffffffff;
    if (element.name == 'iq') {
      _handleIq(element);
      return;
    }
    _emitStanza(element);
  }

  void _handleIq(XmppElement iq) {
    final type = iq.attr('type');
    final id = iq.attr('id');
    final from = iq.attr('from');
    if (type == 'result' || type == 'error') {
      if (id == null) return;
      final pending = _requests[id];
      if (pending == null) return;
      final (completer, to) = pending;
      if (!_answerFromExpected(from, to)) return;
      if (!completer.isCompleted) completer.complete(iq);
      return;
    }
    if (type != 'get' && type != 'set') return;
    // Only the server and this account may ask things of this resource
    // without a handler deciding otherwise; pings are answered for anyone.
    if (iq.child('ping', XmppNs.ping) != null) {
      _reply(iq, XmppElement('iq', attributes: {'type': 'result'}));
      return;
    }
    if (iq.child('query', XmppNs.roster) != null && type == 'set') {
      // Roster pushes come from this account only.
      final bare = bareJid(from);
      if (from == null || bare == jid.toLowerCase()) {
        _emitStanza(iq);
        _reply(iq, XmppElement('iq', attributes: {'type': 'result'}));
        return;
      }
    }
    _reply(
      iq,
      XmppElement(
        'iq',
        attributes: {'type': 'error'},
        children: [
          XmppElement(
            'error',
            attributes: {'type': 'cancel'},
            children: [
              XmppElement('service-unavailable', xmlns: XmppNs.stanzas),
            ],
          ),
        ],
      ),
    );
  }

  bool _answerFromExpected(String? from, String? to) {
    final own = jid.toLowerCase();
    if (to == null) {
      return from == null ||
          bareJid(from) == own ||
          from.toLowerCase() == domain.toLowerCase() ||
          from == _boundJid;
    }
    if (from == null) return false;
    return from.toLowerCase() == to.toLowerCase() ||
        (bareJid(to) == own && bareJid(from) == own);
  }

  void _reply(XmppElement request, XmppElement answer) {
    final id = request.attr('id');
    if (id != null) answer.attributes['id'] = id;
    final from = request.attr('from');
    if (from != null) answer.attributes['to'] = from;
    _writeNow(answer);
  }
}
