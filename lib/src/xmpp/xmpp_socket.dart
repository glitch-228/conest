import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'xmpp_xml.dart';

/// How a connection to an XMPP server is made.
enum XmppEndpointMode {
  /// TLS from the first byte (XEP-0368), on 5223 or on 443 with ALPN
  /// `xmpp-client`.
  directTls,

  /// Plain TCP on 5222 upgraded with STARTTLS before anything else.
  startTls,

  /// WebSocket over HTTPS (RFC 7395).
  webSocket,

  /// No TLS at all: only for a server on this machine (tests, the lab).
  plainLoopback,
}

/// Where and how to reach an XMPP server.
class XmppEndpoint {
  const XmppEndpoint({
    required this.host,
    required this.port,
    required this.mode,
    this.webSocketUrl,
  });

  final String host;
  final int port;
  final XmppEndpointMode mode;

  /// For [XmppEndpointMode.webSocket]: `wss://…` (or `ws://` on loopback).
  final String? webSocketUrl;

  String get label => switch (mode) {
    XmppEndpointMode.directTls => '$host:$port (TLS)',
    XmppEndpointMode.startTls => '$host:$port (STARTTLS)',
    XmppEndpointMode.webSocket => webSocketUrl ?? host,
    XmppEndpointMode.plainLoopback => '$host:$port (local)',
  };

  Map<String, Object?> toJson() => {
    'host': host,
    'port': port,
    'mode': mode.name,
    'ws': ?webSocketUrl,
  };

  static XmppEndpoint? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final host = json['host'];
    final port = json['port'];
    final mode = XmppEndpointMode.values.asNameMap()[json['mode']];
    final ws = json['ws'];
    if (host is! String ||
        host.isEmpty ||
        host.length > 253 ||
        port is! int ||
        port <= 0 ||
        port > 65535 ||
        mode == null) {
      return null;
    }
    if (mode == XmppEndpointMode.plainLoopback && !isLoopbackHost(host)) {
      return null;
    }
    final url = ws is String ? Uri.tryParse(ws) : null;
    if (mode == XmppEndpointMode.webSocket &&
        (url == null ||
            !(url.scheme == 'wss' ||
                (url.scheme == 'ws' && isLoopbackHost(url.host))))) {
      return null;
    }
    return XmppEndpoint(
      host: host,
      port: port,
      mode: mode,
      webSocketUrl: mode == XmppEndpointMode.webSocket ? ws as String : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is XmppEndpoint &&
      other.host == host &&
      other.port == port &&
      other.mode == mode &&
      other.webSocketUrl == webSocketUrl;

  @override
  int get hashCode => Object.hash(host, port, mode, webSocketUrl);
}

/// Whether [host] is this machine, the only place a connection without TLS
/// is allowed.
bool isLoopbackHost(String host) =>
    host == 'localhost' ||
    host == '::1' ||
    host == '[::1]' ||
    RegExp(r'^127\.\d{1,3}\.\d{1,3}\.\d{1,3}$').hasMatch(host);

/// A byte connection to a server; tests substitute an in-memory one.
abstract interface class XmppByteSocket {
  Stream<Uint8List> get input;
  bool get secure;
  void write(List<int> bytes);

  /// Upgrades to TLS (STARTTLS), checking the certificate for [host]. The
  /// old [input] ends; read the returned socket's from then on.
  Future<XmppByteSocket> startTls(String host);
  Future<void> close();
}

/// A text WebSocket speaking the `xmpp` subprotocol.
abstract interface class XmppWebSocket {
  Stream<String> get messages;
  void send(String message);
  Future<void> close();
}

typedef XmppSocketConnector =
    Future<XmppByteSocket> Function(
      String host,
      int port, {
      required bool tls,
      String? alpn,
    });

typedef XmppWebSocketConnector = Future<XmppWebSocket> Function(Uri url);

const Duration _connectTimeout = Duration(seconds: 20);

/// Opens a TCP connection, with TLS from the first byte when [tls].
Future<XmppByteSocket> connectXmppSocket(
  String host,
  int port, {
  required bool tls,
  String? alpn,
}) async {
  if (!tls) {
    return _IoXmppSocket(
      await Socket.connect(host, port, timeout: _connectTimeout),
    );
  }
  final connecting = SecureSocket.connect(
    host,
    port,
    timeout: _connectTimeout,
    supportedProtocols: alpn == null ? null : [alpn],
  );
  try {
    return _IoXmppSocket(
      await connecting.timeout(_connectTimeout + const Duration(seconds: 10)),
    );
  } on TimeoutException {
    unawaited(connecting.then((late) => late.destroy(), onError: (_) {}));
    rethrow;
  }
}

/// Opens a WebSocket with the `xmpp` subprotocol.
Future<XmppWebSocket> connectXmppWebSocket(Uri url) async {
  final connecting = WebSocket.connect(url.toString(), protocols: ['xmpp']);
  try {
    final socket = await connecting.timeout(_connectTimeout);
    if (socket.protocol != 'xmpp') {
      unawaited(socket.close());
      throw const XmppProtocolException('The WebSocket does not speak XMPP.');
    }
    return _IoXmppWebSocket(socket);
  } on TimeoutException {
    unawaited(connecting.then((late) => late.close(), onError: (_) {}));
    rethrow;
  }
}

class _IoXmppSocket implements XmppByteSocket {
  _IoXmppSocket(this._socket) {
    _socket.done.catchError((Object _) {});
    _subscription = _socket.listen(
      _input.add,
      onError: _input.addError,
      onDone: _input.close,
      cancelOnError: true,
    );
  }

  final Socket _socket;
  final StreamController<Uint8List> _input = StreamController();
  late final StreamSubscription<Uint8List> _subscription;

  @override
  Stream<Uint8List> get input => _input.stream;

  @override
  bool get secure => _socket is SecureSocket;

  @override
  void write(List<int> bytes) => _socket.add(bytes);

  @override
  Future<XmppByteSocket> startTls(String host) async {
    // Paused, as dart:io asks, before the handshake takes the socket over.
    _subscription.pause();
    final upgraded = await SecureSocket.secure(
      _socket,
      host: host,
    ).timeout(_connectTimeout);
    unawaited(_input.close());
    return _IoXmppSocket(upgraded);
  }

  @override
  Future<void> close() async {
    try {
      await _socket.close().timeout(const Duration(seconds: 2));
    } catch (_) {}
    _socket.destroy();
  }
}

class _IoXmppWebSocket implements XmppWebSocket {
  _IoXmppWebSocket(this._socket) {
    _socket.pingInterval = const Duration(seconds: 45);
  }

  final WebSocket _socket;

  @override
  Stream<String> get messages =>
      _socket.where((message) => message is String).cast<String>();

  @override
  void send(String message) => _socket.add(message);

  @override
  Future<void> close() => _socket.close();
}

/// A parsed XMPP stream over TCP or WebSocket.
abstract interface class XmppWire {
  Stream<XmppStreamEvent> get events;
  bool get secure;

  /// Whether STARTTLS can still upgrade this connection.
  bool get canStartTls;

  /// Sends a stream header (or `<open/>`), starting a fresh stream.
  void openStream(String domain);
  void send(XmppElement element);

  /// Sends raw text (whitespace keepalives, `</stream:stream>`).
  void sendRaw(String text);
  Future<void> startTls(String host);
  Future<void> close();
}

/// XMPP over a TCP (or TLS) connection.
class XmppTcpWire implements XmppWire {
  XmppTcpWire(XmppByteSocket socket, {int maxStanzaChars = 512 * 1024})
    : _socket = socket,
      _parser = XmppStreamParser(maxElementChars: maxStanzaChars) {
    _listen();
  }

  XmppByteSocket _socket;
  final XmppStreamParser _parser;
  final StreamController<XmppStreamEvent> _events = StreamController();
  StreamSubscription<Uint8List>? _subscription;
  bool _closed = false;

  void _listen() {
    _subscription = _socket.input.listen(
      (chunk) {
        if (_closed) return;
        try {
          for (final event in _parser.addBytes(chunk)) {
            _events.add(event);
          }
        } catch (error) {
          _fail(error);
        }
      },
      onError: _fail,
      onDone: () {
        if (!_upgrading) _fail(const SocketException('Connection closed.'));
      },
    );
  }

  bool _upgrading = false;

  void _fail(Object error) {
    if (_closed) return;
    _closed = true;
    _events.addError(error);
    unawaited(_events.close());
    unawaited(_socket.close());
  }

  @override
  Stream<XmppStreamEvent> get events => _events.stream;

  @override
  bool get secure => _socket.secure;

  @override
  bool get canStartTls => !_socket.secure;

  @override
  void openStream(String domain) {
    _parser.reset();
    sendRaw(
      "<?xml version='1.0'?><stream:stream xmlns='jabber:client' "
      "xmlns:stream='http://etherx.jabber.org/streams' "
      "to='${xmppEscape(domain)}' version='1.0' xml:lang='en'>",
    );
  }

  @override
  void send(XmppElement element) =>
      sendRaw(element.toXml(parentNamespace: XmppNs.client));

  @override
  void sendRaw(String text) {
    if (_closed) throw const SocketException('Connection closed.');
    _socket.write(utf8.encode(text));
  }

  @override
  Future<void> startTls(String host) async {
    _upgrading = true;
    try {
      _socket = await _socket.startTls(host);
    } catch (error) {
      _fail(error);
      rethrow;
    } finally {
      _upgrading = false;
    }
    await _subscription?.cancel();
    _parser.reset();
    _listen();
  }

  @override
  Future<void> close() async {
    if (!_closed) {
      try {
        sendRaw('</stream:stream>');
      } catch (_) {}
    }
    _closed = true;
    await _subscription?.cancel();
    await _socket.close();
    if (!_events.isClosed) await _events.close();
  }
}

/// XMPP over a WebSocket (RFC 7395): each message one element.
class XmppWebSocketWire implements XmppWire {
  XmppWebSocketWire(this._socket, {int maxStanzaChars = 512 * 1024})
    : _maxStanzaChars = maxStanzaChars {
    _subscription = _socket.messages.listen(
      (message) {
        if (_closed) return;
        try {
          if (message.length > _maxStanzaChars) {
            throw const XmppProtocolException('A stanza is too large.');
          }
          final parser = XmppStreamParser(
            framed: true,
            maxElementChars: _maxStanzaChars,
          );
          for (final event in parser.addText(message)) {
            _events.add(event);
          }
        } catch (error) {
          _fail(error);
        }
      },
      onError: _fail,
      onDone: () => _fail(const SocketException('Connection closed.')),
    );
  }

  final XmppWebSocket _socket;
  final int _maxStanzaChars;
  final StreamController<XmppStreamEvent> _events = StreamController();
  late final StreamSubscription<String> _subscription;
  bool _closed = false;

  void _fail(Object error) {
    if (_closed) return;
    _closed = true;
    _events.addError(error);
    unawaited(_events.close());
    unawaited(_socket.close());
  }

  @override
  Stream<XmppStreamEvent> get events => _events.stream;

  @override
  bool get secure => true;

  @override
  bool get canStartTls => false;

  @override
  void openStream(String domain) => sendRaw(
    '<open xmlns="${XmppNs.framing}" to="${xmppEscape(domain)}" '
    'version="1.0"/>',
  );

  @override
  void send(XmppElement element) => sendRaw(
    // Without a stream around them, stanzas name their namespace.
    (element.xmlns == null
            ? XmppElement(
                element.name,
                xmlns: XmppNs.client,
                attributes: element.attributes,
                children: element.children,
                text: element.text,
              )
            : element)
        .toXml(parentNamespace: null),
  );

  @override
  void sendRaw(String text) {
    if (_closed) throw const SocketException('Connection closed.');
    // Whitespace keepalives make no sense on a WebSocket.
    if (text.trim().isEmpty) return;
    _socket.send(text);
  }

  @override
  Future<void> startTls(String host) =>
      Future.error(const XmppProtocolException('STARTTLS over WebSocket.'));

  @override
  Future<void> close() async {
    if (!_closed) {
      try {
        sendRaw('<close xmlns="${XmppNs.framing}"/>');
      } catch (_) {}
    }
    _closed = true;
    await _subscription.cancel();
    await _socket.close();
    if (!_events.isClosed) await _events.close();
  }
}
