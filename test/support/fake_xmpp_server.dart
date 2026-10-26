import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException;
import 'dart:math';
import 'dart:typed_data';

import 'package:conest/src/xmpp/xmpp_sasl.dart';
import 'package:conest/src/xmpp/xmpp_socket.dart';
import 'package:conest/src/xmpp/xmpp_xml.dart';
import 'package:crypto/crypto.dart';

/// An in-memory XMPP server for tests: stream negotiation with STARTTLS,
/// SASL (SCRAM-SHA-1/256 and PLAIN), in-band registration, resource
/// binding, stream management with resumption, offline storage, rosters
/// with presence subscriptions, message routing, pings and WebSockets.
class FakeXmppServer {
  FakeXmppServer({
    this.domain = 'xmpp.test',
    this.allowRegistration = true,
    this.streamManagement = true,
    this.offerStartTls = true,
    this.mechanisms = const ['SCRAM-SHA-256', 'SCRAM-SHA-1', 'PLAIN'],
  });

  final String domain;
  bool allowRegistration;
  bool streamManagement;
  bool offerStartTls;
  List<String> mechanisms;

  /// Accounts: local part to password.
  final Map<String, String> passwords = {};

  /// Every stanza clients sent, as received (for assertions).
  final List<XmppElement> received = [];

  /// Messages stored for accounts with no available resource.
  final Map<String, List<XmppElement>> offline = {};

  /// Rosters: account bare JID to contact bare JID to subscription.
  final Map<String, Map<String, String>> rosters = {};

  /// Hosts that do not answer (a blocked network).
  final Set<String> unreachableHosts = {};

  /// Bare JIDs whose messages the server drops (anti-spam).
  final Set<String> droppedSenders = {};

  /// Connections made, by endpoint mode.
  final List<XmppEndpointMode> connections = [];

  /// When false, acknowledgement requests get no answer.
  bool answerAcks = true;

  /// Group chats on `conference.<domain>`, by room JID.
  final Map<String, FakeRoom> rooms = {};

  /// Message archives (MAM), by account.
  final Map<String, List<FakeArchived>> archives = {};

  /// Blocked addresses, by account.
  final Map<String, Set<String>> blocklists = {};

  /// Upload slots handed out: the get URL and the file name.
  final List<(String, String)> uploads = [];
  int _nextArchiveId = 0;

  String get mucDomain => 'conference.$domain';
  String get uploadDomain => 'upload.$domain';

  final List<_FakeConnection> _connections = [];
  final Map<String, _SmSession> _smSessions = {};
  int _nextSm = 0;

  void addAccount(String local, String password) => passwords[local] = password;

  /// Bare JIDs with a connected resource.
  Set<String> get online => {
    for (final connection in _connections)
      if (connection.fullJid case final full?) bareJid(full)!,
  };

  /// The full JIDs connected now.
  Set<String> get boundResources => {
    for (final connection in _connections) ?connection.fullJid,
  };

  /// A connector for [XmppSession]: every host and port reaches this
  /// server (unless the host is in [unreachableHosts]).
  Future<XmppByteSocket> connect(
    String host,
    int port, {
    required bool tls,
    String? alpn,
  }) async {
    if (unreachableHosts.contains(host)) {
      throw const SocketException('unreachable');
    }
    connections.add(
      tls ? XmppEndpointMode.directTls : XmppEndpointMode.startTls,
    );
    final pipe = _Pipe(secure: tls);
    _connections.add(_FakeConnection(this, pipe, framed: false));
    return pipe.client;
  }

  /// A WebSocket connector.
  Future<XmppWebSocket> connectWebSocket(Uri url) async {
    if (unreachableHosts.contains(url.host)) {
      throw const SocketException('unreachable');
    }
    connections.add(XmppEndpointMode.webSocket);
    final socket = _FakeWebSocket();
    _connections.add(_FakeConnection(this, socket.serverSide, framed: true));
    return socket;
  }

  /// Cuts every connection without a goodbye (a dropped network).
  void dropAll() {
    for (final connection in List.of(_connections)) {
      connection.drop();
    }
  }

  /// Sends a stanza to [to] as the server would route it.
  void inject(XmppElement stanza) => _route(stanza);

  void _route(XmppElement stanza) {
    final to = stanza.attr('to');
    if (to == null) return;
    final bare = bareJid(to);
    if (bare == null) return;
    final resource = jidResource(to);
    final targets = _connections.where(
      (connection) =>
          connection.fullJid != null &&
          bareJid(connection.fullJid) == bare &&
          (resource == null || connection.fullJid == to),
    );
    if (stanza.name == 'message') {
      final sender = bareJid(stanza.attr('from'));
      if (sender != null && droppedSenders.contains(sender)) return;
      if (sender != null && (blocklists[bare]?.contains(sender) ?? false)) {
        return;
      }
      final type = stanza.attr('type') ?? 'normal';
      final archived =
          (type == 'chat' || type == 'normal') &&
          stanza.child('body') != null &&
          stanza.child('result', XmppNs.mam) == null;
      if (archived) {
        final id = 'a${_nextArchiveId++}';
        stanza.add(
          XmppElement(
            'stanza-id',
            xmlns: XmppNs.stanzaId,
            attributes: {'by': bare, 'id': id},
          ),
        );
        for (final account in {?sender, bare}) {
          (archives[account] ??= []).add(
            FakeArchived(id, stanza, DateTime.now().toUtc()),
          );
        }
        // The sender's other clients get a copy.
        if (sender != null && stanza.child('private', XmppNs.carbons) == null) {
          for (final connection in _connections) {
            if (connection.carbons &&
                connection.fullJid != stanza.attr('from') &&
                bareJid(connection.fullJid) == sender) {
              connection.deliver(_carbon('sent', connection.fullJid!, stanza));
            }
          }
        }
      }
      var list = targets.toList();
      if (list.isEmpty && resource != null) {
        // A full JID that is offline: treated as the bare JID.
        list = _connections
            .where(
              (connection) =>
                  connection.fullJid != null &&
                  bareJid(connection.fullJid) == bare &&
                  connection.priority >= 0,
            )
            .toList();
      }
      if (list.isEmpty) {
        if (passwords.containsKey(bare.split('@').first) &&
            bare.endsWith('@$domain')) {
          (offline[bare] ??= []).add(stanza);
        }
        return;
      }
      for (final connection in list) {
        connection.deliver(stanza);
      }
      // A message to one resource: the account's other clients get a copy.
      if (archived && resource != null) {
        for (final connection in _connections) {
          if (connection.carbons &&
              bareJid(connection.fullJid) == bare &&
              !list.contains(connection)) {
            connection.deliver(
              _carbon('received', connection.fullJid!, stanza),
            );
          }
        }
      }
      return;
    }
    for (final connection in targets) {
      connection.deliver(stanza);
    }
  }

  void _remove(_FakeConnection connection) => _connections.remove(connection);

  XmppElement _carbon(String kind, String to, XmppElement message) =>
      XmppElement(
        'message',
        attributes: {'from': bareJid(to)!, 'to': to, 'type': 'chat'},
        children: [
          XmppElement(
            kind,
            xmlns: XmppNs.carbons,
            children: [
              XmppElement(
                'forwarded',
                xmlns: XmppNs.forward,
                children: [message],
              ),
            ],
          ),
        ],
      );

  /// Sends what a room says to every occupant.
  void _roomBroadcast(FakeRoom room, XmppElement stanza) {
    for (final full in room.occupants.values) {
      for (final connection in _connections) {
        if (connection.fullJid == full) {
          connection.deliver(
            XmppElement(
              stanza.name,
              xmlns: stanza.xmlns,
              attributes: {...stanza.attributes, 'to': full},
              children: stanza.children,
              text: stanza.text,
            ),
          );
        }
      }
    }
  }
}

/// A message kept in an archive.
class FakeArchived {
  FakeArchived(this.id, this.message, this.at);
  final String id;
  final XmppElement message;
  final DateTime at;
}

/// A group chat (MUC) on the fake server.
class FakeRoom {
  FakeRoom(this.jid);
  final String jid;
  String subject = '';

  /// Nickname to the occupant's full JID.
  final Map<String, String> occupants = {};
  final List<FakeArchived> archive = [];
}

class _SmSession {
  _SmSession(this.fullJid);
  final String fullJid;
  int inbound = 0;
  int outbound = 0;
  final List<XmppElement> unacked = [];
}

/// A byte pipe between the client and the fake server.
class _Pipe {
  _Pipe({required bool secure}) : _secure = secure {
    client = _PipeClient(this);
  }

  bool _secure;
  late _PipeClient client;
  final StreamController<Uint8List> toClient = StreamController.broadcast();
  final StreamController<Uint8List> toServer = StreamController();
  bool closed = false;

  void close() {
    if (closed) return;
    closed = true;
    unawaited(toClient.close());
    unawaited(toServer.close());
  }
}

class _PipeClient implements XmppByteSocket {
  _PipeClient(this._pipe, {Stream<Uint8List>? input})
    : input = input ?? _pipe.toClient.stream;

  final _Pipe _pipe;

  @override
  final Stream<Uint8List> input;

  @override
  bool get secure => _pipe._secure;

  @override
  void write(List<int> bytes) {
    if (_pipe.closed) throw const SocketException('closed');
    _pipe.toServer.add(Uint8List.fromList(bytes));
  }

  @override
  Future<XmppByteSocket> startTls(String host) async {
    // The same pipe, now "secure"; the client keeps reading the same
    // controller through a fresh wrapper.
    _pipe._secure = true;
    _pipe.client = _PipeClient(_pipe, input: input);
    return _pipe.client;
  }

  @override
  Future<void> close() async => _pipe.close();
}

class _FakeWebSocket implements XmppWebSocket {
  final StreamController<String> _toClient = StreamController();
  final StreamController<String> _toServer = StreamController();
  bool _closed = false;

  @override
  Stream<String> get messages => _toClient.stream;

  @override
  void send(String message) {
    if (_closed) throw const SocketException('closed');
    _toServer.add(message);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    unawaited(_toClient.close());
    unawaited(_toServer.close());
  }

  late final _ServerSide serverSide = _ServerSide(this);
}

/// What the server side of a connection reads and writes.
abstract class _ServerTransport {
  Stream<Object> get incoming;
  void write(String text);
  void close();
  bool get secure;
}

class _ServerSide implements _ServerTransport {
  _ServerSide(this._socket);
  final _FakeWebSocket _socket;
  @override
  Stream<Object> get incoming => _socket._toServer.stream;
  @override
  void write(String text) {
    if (!_socket._closed) _socket._toClient.add(text);
  }

  @override
  void close() => unawaited(_socket.close());
  @override
  bool get secure => true;
}

class _PipeServer implements _ServerTransport {
  _PipeServer(this._pipe);
  final _Pipe _pipe;
  @override
  Stream<Object> get incoming => _pipe.toServer.stream;
  @override
  void write(String text) {
    if (!_pipe.closed) {
      _pipe.toClient.add(Uint8List.fromList(utf8.encode(text)));
    }
  }

  @override
  void close() => _pipe.close();
  @override
  bool get secure => _pipe._secure;
}

class _FakeConnection {
  _FakeConnection(this.server, Object transport, {required this.framed})
    : _transport = transport is _Pipe
          ? _PipeServer(transport)
          : transport as _ServerTransport {
    _parser = XmppStreamParser(framed: framed);
    _subscription = _transport.incoming.listen(
      _onData,
      onDone: _closed,
      onError: (Object _) => _closed(),
    );
  }

  final FakeXmppServer server;
  final bool framed;
  final _ServerTransport _transport;
  late XmppStreamParser _parser;
  late final StreamSubscription<Object> _subscription;

  bool _authenticated = false;
  String? _user;
  String? fullJid;
  int priority = 0;
  bool carbons = false;
  bool _available = false;
  _SmSession? _sm;
  _ScramServer? _scram;

  void _onData(Object data) {
    try {
      final events = data is String
          ? (XmppStreamParser(framed: true)..reset()).addText(data)
          : _parser.addBytes(data as Uint8List);
      for (final event in events) {
        switch (event) {
          case XmppStreamOpened():
            _openStream();
          case XmppStreamElement(:final element):
            _onElement(element);
          case XmppStreamClosed():
            drop();
        }
      }
    } catch (error) {
      drop();
    }
  }

  void _write(String text) => _transport.write(text);

  void _send(XmppElement element) => _write(
    framed
        ? XmppElement(
            element.name,
            xmlns: element.xmlns ?? XmppNs.client,
            attributes: element.attributes,
            children: element.children,
            text: element.text,
          ).toXml(parentNamespace: null)
        : element.toXml(parentNamespace: XmppNs.client),
  );

  void _openStream() {
    if (framed) {
      _write(
        '<open xmlns="${XmppNs.framing}" from="${server.domain}" '
        'id="${Random().nextInt(1 << 30)}" version="1.0"/>',
      );
    } else {
      _write(
        "<?xml version='1.0'?><stream:stream xmlns='jabber:client' "
        "xmlns:stream='http://etherx.jabber.org/streams' "
        "from='${server.domain}' id='s${Random().nextInt(1 << 30)}' "
        "version='1.0'>",
      );
    }
    final features = XmppElement('features', xmlns: XmppNs.stream);
    if (!_transport.secure && server.offerStartTls) {
      features.add(XmppElement('starttls', xmlns: XmppNs.tls));
    } else if (!_authenticated) {
      features.add(
        XmppElement(
          'mechanisms',
          xmlns: XmppNs.sasl,
          children: [
            for (final mechanism in server.mechanisms)
              XmppElement('mechanism', text: mechanism),
          ],
        ),
      );
      if (server.allowRegistration) {
        features.add(XmppElement('register', xmlns: XmppNs.registerFeature));
      }
    } else {
      features.add(XmppElement('bind', xmlns: XmppNs.bind));
      if (server.streamManagement) {
        features.add(XmppElement('sm', xmlns: XmppNs.sm));
      }
      features.add(XmppElement('csi', xmlns: XmppNs.csi));
    }
    // The features go out with the namespace prefix servers use.
    final xml = features.toXml(parentNamespace: XmppNs.client);
    _write(
      framed
          ? xml
                .replaceFirst(
                  '<features xmlns="${XmppNs.stream}"',
                  '<stream:features xmlns:stream="${XmppNs.stream}"',
                )
                .replaceFirst(RegExp(r'</features>$'), '</stream:features>')
          : xml
                .replaceFirst(
                  '<features xmlns="${XmppNs.stream}"',
                  '<stream:features',
                )
                .replaceFirst(RegExp(r'</features>$'), '</stream:features>'),
    );
  }

  void _onElement(XmppElement element) {
    server.received.add(element);
    switch ((element.xmlns, element.name)) {
      case (XmppNs.tls, 'starttls'):
        _write('<proceed xmlns="${XmppNs.tls}"/>');
        if (_transport case final _PipeServer pipe) pipe._pipe._secure = true;
        _parser = XmppStreamParser();
      case (XmppNs.sasl, 'auth'):
        _auth(element);
      case (XmppNs.sasl, 'response'):
        _saslResponse(element);
      case (XmppNs.sm, 'enable'):
        if (fullJid == null) return;
        final id = 'sm${server._nextSm++}';
        final session = _sm = _SmSession(fullJid!);
        server._smSessions[id] = session;
        _write('<enabled xmlns="${XmppNs.sm}" id="$id" resume="true"/>');
      case (XmppNs.sm, 'resume'):
        _resume(element);
      case (XmppNs.sm, 'r'):
        if (_sm case final sm? when server.answerAcks) {
          _write('<a xmlns="${XmppNs.sm}" h="${sm.inbound}"/>');
        }
      case (XmppNs.sm, 'a'):
        final sm = _sm;
        final h = int.tryParse(element.attr('h') ?? '');
        if (sm == null || h == null) return;
        final acked = h - (sm.outbound - sm.unacked.length);
        if (acked > 0) sm.unacked.removeRange(0, min(acked, sm.unacked.length));
      case (XmppNs.csi, _):
        break;
      case (XmppNs.client, 'iq'):
        _countIn();
        _iq(element);
      case (XmppNs.client, 'presence'):
        _countIn();
        _presence(element);
      case (XmppNs.client, 'message'):
        _countIn();
        if (fullJid == null) return;
        final to = bareJid(element.attr('to'));
        if (to != null && to.endsWith('@${server.mucDomain}')) {
          _roomMessage(to, element);
          return;
        }
        element.attributes['from'] = fullJid!;
        server._route(element);
    }
  }

  void _countIn() {
    if (_sm case final sm?) sm.inbound++;
  }

  void deliver(XmppElement stanza) {
    if (_sm case final sm?) {
      sm.outbound++;
      sm.unacked.add(stanza);
    }
    _send(stanza);
  }

  void _auth(XmppElement element) {
    final mechanism = element.attr('mechanism');
    final data = base64.decode(element.text.trim());
    if (!server.mechanisms.contains(mechanism)) {
      _saslFailure();
      return;
    }
    if (mechanism == 'PLAIN') {
      final parts = utf8.decode(data).split('\u0000');
      if (parts.length == 3 && server.passwords[parts[1]] == parts[2]) {
        _user = parts[1];
        _saslSuccess(null);
      } else {
        _saslFailure();
      }
      return;
    }
    final scram = _scram = _ScramServer(
      mechanism == 'SCRAM-SHA-1' ? sha1 : sha256,
      server.passwords,
    );
    final challenge = scram.first(utf8.decode(data));
    if (challenge == null) {
      _saslFailure();
      return;
    }
    _write(
      '<challenge xmlns="${XmppNs.sasl}">'
      '${base64.encode(utf8.encode(challenge))}</challenge>',
    );
  }

  void _saslResponse(XmppElement element) {
    final scram = _scram;
    if (scram == null) return _saslFailure();
    final result = scram.finish(
      utf8.decode(base64.decode(element.text.trim())),
    );
    if (result == null) return _saslFailure();
    _user = scram.user;
    _saslSuccess(result);
  }

  void _saslSuccess(String? data) {
    _authenticated = true;
    _write(
      '<success xmlns="${XmppNs.sasl}">'
      '${data == null ? '' : base64.encode(utf8.encode(data))}</success>',
    );
    _parser = XmppStreamParser(framed: framed);
  }

  void _saslFailure() =>
      _write('<failure xmlns="${XmppNs.sasl}"><not-authorized/></failure>');

  void _resume(XmppElement element) {
    final session = server._smSessions[element.attr('previd')];
    final h = int.tryParse(element.attr('h') ?? '');
    if (!_authenticated ||
        session == null ||
        h == null ||
        bareJid(session.fullJid) != '$_user@${server.domain}') {
      _write(
        '<failed xmlns="${XmppNs.sm}">'
        '<item-not-found xmlns="${XmppNs.stanzas}"/></failed>',
      );
      return;
    }
    // Another connection still holding the resource is replaced.
    for (final other in List.of(server._connections)) {
      if (!identical(other, this) && other.fullJid == session.fullJid) {
        other.drop();
      }
    }
    fullJid = session.fullJid;
    _available = true;
    _sm = session;
    final acked = h - (session.outbound - session.unacked.length);
    if (acked > 0) {
      session.unacked.removeRange(0, min(acked, session.unacked.length));
    }
    _write(
      '<resumed xmlns="${XmppNs.sm}" previd="${element.attr('previd')}" '
      'h="${session.inbound}"/>',
    );
    final again = List.of(session.unacked);
    session.unacked.clear();
    session.outbound -= again.length;
    for (final stanza in again) {
      deliver(stanza);
    }
  }

  void _iq(XmppElement iq) {
    final id = iq.attr('id');
    final type = iq.attr('type');
    XmppElement result([List<XmppElement> children = const []]) => XmppElement(
      'iq',
      attributes: {
        'type': 'result',
        'id': ?id,
        'to': ?fullJid,
        'from': ?iq.attr('to'),
      },
      children: children,
    );
    XmppElement error(String condition) => XmppElement(
      'iq',
      attributes: {'type': 'error', 'id': ?id, 'from': ?iq.attr('to')},
      children: [
        XmppElement(
          'error',
          attributes: {'type': 'cancel'},
          children: [XmppElement(condition, xmlns: XmppNs.stanzas)],
        ),
      ],
    );
    final to = iq.attr('to');
    final ownBare = '$_user@${server.domain}';
    if (fullJid != null) {
      if (iq.child('query', XmppNs.mam) case final query?) {
        _mamQuery(iq, query, to == null ? null : bareJid(to), result);
        return;
      }
      if (iq.child('query', XmppNs.discoItems) != null && to == server.domain) {
        _send(
          result([
            XmppElement(
              'query',
              xmlns: XmppNs.discoItems,
              children: [
                XmppElement('item', attributes: {'jid': server.uploadDomain}),
                XmppElement('item', attributes: {'jid': server.mucDomain}),
              ],
            ),
          ]),
        );
        return;
      }
      if (iq.child('query', XmppNs.discoInfo) != null &&
          (to == server.domain ||
              to == server.uploadDomain ||
              to == server.mucDomain)) {
        _send(
          result([
            XmppElement(
              'query',
              xmlns: XmppNs.discoInfo,
              children: [
                if (to == server.uploadDomain)
                  XmppElement(
                    'feature',
                    attributes: {'var': XmppNs.httpUpload},
                  ),
                if (to == server.mucDomain)
                  XmppElement('feature', attributes: {'var': XmppNs.muc}),
              ],
            ),
          ]),
        );
        return;
      }
      if (iq.child('request', XmppNs.httpUpload) case final request?
          when to == server.uploadDomain) {
        final n = server.uploads.length;
        final get =
            'https://${server.uploadDomain}/get/$n/${request.attr('filename')}';
        server.uploads.add((get, request.attr('filename') ?? ''));
        _send(
          result([
            XmppElement(
              'slot',
              xmlns: XmppNs.httpUpload,
              children: [
                XmppElement(
                  'put',
                  attributes: {'url': 'https://${server.uploadDomain}/put/$n'},
                  children: [
                    XmppElement(
                      'header',
                      attributes: {'name': 'Authorization'},
                      text: 'Basic token$n',
                    ),
                    XmppElement(
                      'header',
                      attributes: {'name': 'X-Evil'},
                      text: 'nope',
                    ),
                  ],
                ),
                XmppElement('get', attributes: {'url': get}),
              ],
            ),
          ]),
        );
        return;
      }
      if (iq.child('enable', XmppNs.carbons) != null) {
        carbons = true;
        _send(result());
        return;
      }
      if (iq.child('blocklist', XmppNs.blocking) != null) {
        _send(
          result([
            XmppElement(
              'blocklist',
              xmlns: XmppNs.blocking,
              children: [
                for (final jid
                    in server.blocklists[ownBare] ?? const <String>{})
                  XmppElement('item', attributes: {'jid': jid}),
              ],
            ),
          ]),
        );
        return;
      }
      if (iq.child('block', XmppNs.blocking) case final block?) {
        for (final item in block.all('item')) {
          (server.blocklists[ownBare] ??= {}).add(item.attr('jid')!);
        }
        _send(result());
        return;
      }
    }
    if (to != null &&
        to != server.domain &&
        bareJid(to) != '$_user@${server.domain}' &&
        fullJid != null) {
      // To another account: routed.
      iq.attributes['from'] = fullJid!;
      server._route(iq);
      return;
    }
    if (iq.child('query', XmppNs.register) case final query?) {
      if (!server.allowRegistration || _authenticated) {
        _send(error('not-allowed'));
        return;
      }
      if (type == 'get') {
        _send(
          result([
            XmppElement(
              'query',
              xmlns: XmppNs.register,
              children: [
                XmppElement('instructions', text: 'Choose a name'),
                XmppElement('username'),
                XmppElement('password'),
              ],
            ),
          ]),
        );
        return;
      }
      final user = query.childText('username');
      final password = query.childText('password');
      if (user == null || password == null) {
        _send(error('bad-request'));
      } else if (server.passwords.containsKey(user)) {
        _send(error('conflict'));
      } else {
        server.passwords[user] = password;
        _send(result());
      }
      return;
    }
    if (iq.child('bind', XmppNs.bind) case final bind?) {
      if (!_authenticated) return _send(error('not-authorized'));
      final resource =
          bind.childText('resource') ?? 'r${Random().nextInt(1000)}';
      final full = '$_user@${server.domain}/$resource';
      for (final other in List.of(server._connections)) {
        if (!identical(other, this) && other.fullJid == full) other.drop();
      }
      fullJid = full;
      _send(
        XmppElement(
          'iq',
          attributes: {'type': 'result', 'id': ?id},
          children: [
            XmppElement(
              'bind',
              xmlns: XmppNs.bind,
              children: [XmppElement('jid', text: full)],
            ),
          ],
        ),
      );
      return;
    }
    if (fullJid == null) return _send(error('not-authorized'));
    final own = '$_user@${server.domain}';
    if (iq.child('query', XmppNs.roster) != null) {
      final roster = server.rosters[own] ?? {};
      _send(
        result([
          XmppElement(
            'query',
            xmlns: XmppNs.roster,
            children: [
              for (final MapEntry(:key, :value) in roster.entries)
                XmppElement(
                  'item',
                  attributes: {'jid': key, 'subscription': value},
                ),
            ],
          ),
        ]),
      );
      return;
    }
    if (iq.child('ping', XmppNs.ping) != null) {
      _send(result());
      return;
    }
    _send(error('service-unavailable'));
  }

  void _presence(XmppElement presence) {
    final own = fullJid == null ? null : bareJid(fullJid);
    if (own == null) return;
    final type = presence.attr('type');
    final to = bareJid(presence.attr('to'));
    if (to == null) {
      if (type == null) {
        priority = int.tryParse(presence.childText('priority') ?? '0') ?? 0;
        final first = !_available;
        _available = true;
        // Offline messages once a resource that may take them is up.
        if (first && priority >= 0) {
          final stored = server.offline.remove(own) ?? const [];
          for (final message in stored) {
            deliver(message);
          }
        }
      } else if (type == 'unavailable') {
        _available = false;
      }
      return;
    }
    if (to.endsWith('@${server.mucDomain}')) {
      _roomPresence(to, presence);
      return;
    }
    final mine = server.rosters[own] ??= {};
    final theirs = server.rosters[to] ??= {};
    switch (type) {
      case 'subscribe':
        mine.putIfAbsent(to, () => 'none');
      case 'subscribed':
        theirs[own] = theirs[own] == 'from' ? 'both' : 'to';
        mine[to] = mine[to] == 'to' ? 'both' : 'from';
    }
    presence.attributes['from'] = own;
    server._route(presence);
  }

  void _roomPresence(String roomJid, XmppElement presence) {
    final nick = jidResource(presence.attr('to')!) ?? '';
    final room = server.rooms[roomJid] ??= FakeRoom(roomJid);
    if (presence.attr('type') == 'unavailable') {
      room.occupants.removeWhere((_, full) => full == fullJid);
      return;
    }
    room.occupants[nick] = fullJid!;
    for (final MapEntry(key: other, value: _) in room.occupants.entries) {
      _send(
        XmppElement(
          'presence',
          attributes: {'from': '$roomJid/$other', 'to': fullJid!},
          children: [
            XmppElement(
              'x',
              xmlns: XmppNs.mucUser,
              children: [
                if (other == nick)
                  XmppElement('status', attributes: {'code': '110'}),
              ],
            ),
          ],
        ),
      );
    }
    _send(
      XmppElement(
        'message',
        attributes: {
          'from': roomJid,
          'to': fullJid!,
          'type': 'groupchat',
          'id': 'subj',
        },
        children: [XmppElement('subject', text: room.subject)],
      ),
    );
  }

  void _roomMessage(String roomJid, XmppElement message) {
    final room = server.rooms[roomJid];
    final nick = room?.occupants.entries
        .where((entry) => entry.value == fullJid)
        .firstOrNull
        ?.key;
    if (room == null || nick == null || message.attr('type') != 'groupchat') {
      return;
    }
    final id = 'r${server._nextArchiveId++}';
    final stamped = XmppElement(
      'message',
      attributes: {
        ...message.attributes,
        'from': '$roomJid/$nick',
        'type': 'groupchat',
      },
      children: [
        ...message.children,
        XmppElement(
          'stanza-id',
          xmlns: XmppNs.stanzaId,
          attributes: {'by': roomJid, 'id': id},
        ),
      ],
      text: message.text,
    );
    if (message.child('body') != null) {
      room.archive.add(FakeArchived(id, stamped, DateTime.now().toUtc()));
    }
    server._roomBroadcast(room, stamped);
  }

  void _mamQuery(
    XmppElement iq,
    XmppElement query,
    String? room,
    XmppElement Function([List<XmppElement>]) result,
  ) {
    final own = '$_user@${server.domain}';
    final archive = room == null
        ? server.archives[own] ?? const <FakeArchived>[]
        : server.rooms[room]?.archive ?? const <FakeArchived>[];
    final set = query.child('set', XmppNs.rsm);
    final max = int.tryParse(set?.childText('max') ?? '') ?? 50;
    final after = set?.childText('after');
    final before = set?.child('before');
    List<FakeArchived> page;
    var complete = true;
    if (after != null) {
      final index = archive.indexWhere((entry) => entry.id == after);
      final rest = archive.sublist(index + 1);
      page = rest.take(max).toList();
      complete = rest.length <= max;
    } else if (before != null) {
      page = archive.length <= max
          ? List.of(archive)
          : archive.sublist(archive.length - max);
      complete = archive.length <= max;
    } else {
      page = archive.take(max).toList();
      complete = archive.length <= max;
    }
    for (final entry in page) {
      _send(
        XmppElement(
          'message',
          attributes: {'to': fullJid!, 'from': room ?? own},
          children: [
            XmppElement(
              'result',
              xmlns: XmppNs.mam,
              attributes: {
                'queryid': query.attr('queryid') ?? '',
                'id': entry.id,
              },
              children: [
                XmppElement(
                  'forwarded',
                  xmlns: XmppNs.forward,
                  children: [
                    XmppElement(
                      'delay',
                      xmlns: XmppNs.delay,
                      attributes: {'stamp': entry.at.toIso8601String()},
                    ),
                    entry.message,
                  ],
                ),
              ],
            ),
          ],
        ),
      );
    }
    final answer = result([
      XmppElement(
        'fin',
        xmlns: XmppNs.mam,
        attributes: {if (complete) 'complete': 'true'},
        children: [
          XmppElement(
            'set',
            xmlns: XmppNs.rsm,
            children: [
              if (page.isNotEmpty) XmppElement('first', text: page.first.id),
              if (page.isNotEmpty) XmppElement('last', text: page.last.id),
            ],
          ),
        ],
      ),
    ]);
    if (room != null) answer.attributes['from'] = room;
    _send(answer);
  }

  void drop() {
    _transport.close();
    _closed();
  }

  void _closed() {
    unawaited(_subscription.cancel());
    server._remove(this);
  }
}

/// The server side of SCRAM.
class _ScramServer {
  _ScramServer(this._hash, this._passwords);

  final Hash _hash;
  final Map<String, String> _passwords;
  String? user;
  late String _clientFirstBare;
  late String _serverFirst;
  late Uint8List _salted;
  late String _nonce;

  String? first(String message) {
    if (!message.startsWith('n,,')) return null;
    _clientFirstBare = message.substring(3);
    final fields = {
      for (final part in _clientFirstBare.split(','))
        if (part.length > 1) part[0]: part.substring(2),
    };
    final name = fields['n'];
    final clientNonce = fields['r'];
    if (name == null || clientNonce == null) return null;
    final password = _passwords[name];
    if (password == null) return null;
    user = name;
    _nonce = '$clientNonce${Random().nextInt(1 << 30)}srv';
    final salt = List<int>.generate(16, (index) => index * 7);
    _salted = pbkdf2(_hash, utf8.encode(password), salt, 4096);
    _serverFirst = 'r=$_nonce,s=${base64.encode(salt)},i=4096';
    return _serverFirst;
  }

  String? finish(String message) {
    final proofAt = message.lastIndexOf(',p=');
    if (proofAt < 0) return null;
    final withoutProof = message.substring(0, proofAt);
    if (withoutProof != 'c=biws,r=$_nonce') return null;
    final proof = base64.decode(message.substring(proofAt + 3));
    final authMessage = '$_clientFirstBare,$_serverFirst,$withoutProof';
    final clientKey = Hmac(
      _hash,
      _salted,
    ).convert(utf8.encode('Client Key')).bytes;
    final storedKey = _hash.convert(clientKey).bytes;
    final signature = Hmac(
      _hash,
      storedKey,
    ).convert(utf8.encode(authMessage)).bytes;
    for (var index = 0; index < clientKey.length; index++) {
      if ((proof[index] ^ signature[index]) != clientKey[index]) return null;
    }
    final serverKey = Hmac(
      _hash,
      _salted,
    ).convert(utf8.encode('Server Key')).bytes;
    final serverSignature = Hmac(
      _hash,
      serverKey,
    ).convert(utf8.encode(authMessage)).bytes;
    return 'v=${base64.encode(serverSignature)}';
  }
}
