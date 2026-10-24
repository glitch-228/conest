import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../carrier.dart';
import '../transport_models.dart';
import 'xmpp_session.dart';
import 'xmpp_socket.dart';
import 'xmpp_xml.dart';

/// Public servers where Conest can create an account by itself: in-band
/// registration with only a name and a password, no CAPTCHA (checked
/// October 2026). Servers close registration from time to time, so setup
/// tries them in the order they answer and falls back to "use my account".
const List<String> defaultXmppServers = [
  'trashserver.net',
  'yax.im',
  'jabber.de',
  'xmpp.earth',
];

/// Frames of up to 24 KiB sealed (32 KiB in base64), well under the
/// 64–256 KiB stanza limits of common servers, and at most 8 per envelope:
/// servers also limit how fast one account may send.
const CarrierFraming xmppFraming = CarrierFraming(
  maxSealedBytes: 192 * 1024,
  chunkBytes: 24 * 1024,
);

/// A device's address on the XMPP carrier: the account and the resource
/// Conest uses on it, `local@domain|resource`. The account alone names the
/// sender ([carrierSenderIdentity]).
class XmppCarrierAddress {
  const XmppCarrierAddress(this.jid, this.resource);

  final String jid;
  final String resource;

  String encode() => '$jid|$resource';

  /// The full JID frames go to.
  String get fullJid => '$jid/$resource';

  static XmppCarrierAddress? tryParse(String value) {
    if (value.length > 1024) return null;
    final split = value.indexOf('|');
    if (split <= 0) return null;
    final jid = value.substring(0, split);
    final resource = value.substring(split + 1);
    if (!isValidBareJid(jid) ||
        jid != jid.toLowerCase() ||
        !isValidXmppResource(resource)) {
      return null;
    }
    return XmppCarrierAddress(jid, resource);
  }
}

/// A resource Conest would use: short, printable, no separators.
bool isValidXmppResource(String resource) =>
    resource.isNotEmpty &&
    resource.length <= 64 &&
    RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(resource);

/// A fresh resource for Conest on an account, `conest-` and 8 random
/// characters (nothing that links it to the device).
String newXmppResource([Random? random]) {
  final source = random ?? Random.secure();
  return 'conest-${List.generate(8, (_) => 'abcdefghijklmnopqrstuvwxyz0123456789'[source.nextInt(36)]).join()}';
}

bool isValidXmppCarrierAddress(String address) =>
    XmppCarrierAddress.tryParse(address) != null;

/// The saved XMPP carrier account.
class XmppCarrierConfig {
  const XmppCarrierConfig({
    required this.jid,
    required this.password,
    required this.resource,
    this.endpoints = const [],
    this.created = false,
  });

  /// A random name and password for a new account on [domain].
  factory XmppCarrierConfig.newAccount(
    String domain, {
    required String resource,
    List<XmppEndpoint> endpoints = const [],
    Random? random,
  }) {
    final source = random ?? Random.secure();
    String token(String alphabet, int length) => List.generate(
      length,
      (_) => alphabet[source.nextInt(alphabet.length)],
    ).join();
    return XmppCarrierConfig(
      jid:
          '${token('abcdefghijklmnopqrstuvwxyz', 1)}'
          '${token('abcdefghijklmnopqrstuvwxyz0123456789', 11)}@$domain',
      password: token(
        'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789',
        32,
      ),
      resource: resource,
      endpoints: endpoints,
      created: true,
    );
  }

  /// `local@domain`, lower case.
  final String jid;
  final String password;

  /// `conest-<device>`: Conest's own resource on the account.
  final String resource;

  /// Where the server answered, best first; empty means the standard ports.
  final List<XmppEndpoint> endpoints;

  /// Conest created the account (in-band registration); otherwise it is
  /// the user's own, and Conest stays out of the way of their other apps.
  final bool created;

  String get domain => jid.substring(jid.indexOf('@') + 1);

  XmppCarrierAddress get address => XmppCarrierAddress(jid, resource);

  /// The endpoints to try: the saved ones, then the standard ports.
  List<XmppEndpoint> get connectEndpoints => [
    ...endpoints,
    for (final candidate in xmppEndpointCandidates(domain))
      if (!endpoints.contains(candidate)) candidate,
  ];

  XmppCarrierConfig copyWith({List<XmppEndpoint>? endpoints}) =>
      XmppCarrierConfig(
        jid: jid,
        password: password,
        resource: resource,
        endpoints: endpoints ?? this.endpoints,
        created: created,
      );

  Map<String, Object?> toJson() => {
    'jid': jid,
    'password': password,
    'resource': resource,
    if (endpoints.isNotEmpty)
      'endpoints': [for (final endpoint in endpoints) endpoint.toJson()],
    if (created) 'created': true,
  };

  static XmppCarrierConfig? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final jid = json['jid'];
    final password = json['password'];
    final resource = json['resource'];
    if (jid is! String ||
        !isValidBareJid(jid) ||
        password is! String ||
        password.isEmpty ||
        resource is! String ||
        !isValidXmppResource(resource)) {
      return null;
    }
    final endpoints = json['endpoints'];
    return XmppCarrierConfig(
      jid: jid.toLowerCase(),
      password: password,
      resource: resource,
      endpoints: [
        if (endpoints is List)
          for (final endpoint in endpoints.take(8))
            ?XmppEndpoint.fromJson(endpoint),
      ],
      created: json['created'] == true,
    );
  }
}

/// The standard ways into [domain]'s server without DNS SRV records:
/// STARTTLS on 5222, direct TLS on 5223, and direct TLS on 443 (ALPN
/// `xmpp-client`) for networks that only let HTTPS through.
List<XmppEndpoint> xmppEndpointCandidates(String domain) => [
  XmppEndpoint(host: domain, port: 5222, mode: XmppEndpointMode.startTls),
  XmppEndpoint(host: domain, port: 5223, mode: XmppEndpointMode.directTls),
  XmppEndpoint(host: domain, port: 443, mode: XmppEndpointMode.directTls),
];

/// Finds [domain]'s XMPP WebSocket through its host-meta file (XEP-0156),
/// over HTTPS only. Null when it has none.
Future<String?> lookupXmppWebSocket(String domain) async {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10)
    ..userAgent = null;
  try {
    final request = await client
        .getUrl(Uri.https(domain, '/.well-known/host-meta.json'))
        .timeout(const Duration(seconds: 15));
    request.followRedirects = false;
    final response = await request.close().timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      await response.drain<void>();
      return null;
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.timeout(const Duration(seconds: 15))) {
      bytes.add(chunk);
      if (bytes.length > 64 * 1024) return null;
    }
    return parseHostMetaWebSocket(utf8.decode(bytes.takeBytes()));
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}

/// The `wss://` WebSocket link of a host-meta JSON document.
String? parseHostMetaWebSocket(String json) {
  try {
    final decoded = jsonDecode(json);
    if (decoded is! Map<String, dynamic>) return null;
    final links = decoded['links'];
    if (links is! List) return null;
    for (final link in links.take(32)) {
      if (link is Map<String, dynamic> &&
          link['rel'] == 'urn:xmpp:alt-connections:websocket' &&
          link['href'] is String) {
        final url = Uri.tryParse(link['href'] as String);
        if (url != null && url.scheme == 'wss' && url.host.isNotEmpty) {
          return url.toString();
        }
      }
    }
  } on FormatException {
    return null;
  }
  return null;
}

/// A server that answered the probe: where, and whether it lets Conest
/// create an account.
class XmppServerProbe {
  const XmppServerProbe(this.domain, this.endpoint, {required this.register});
  final String domain;
  final XmppEndpoint endpoint;
  final bool register;
}

/// Of [domains], the servers that answer here over TLS, fastest first: all
/// standard ports of a server at once (and its WebSocket when
/// [webSocketLookup] finds one), a few servers at a time with head starts,
/// as the chatmail probe does. Stops once [enough] answered.
Future<List<XmppServerProbe>> reachableXmppServers(
  List<String> domains, {
  XmppSocketConnector connector = connectXmppSocket,
  XmppWebSocketConnector webSocketConnector = connectXmppWebSocket,
  Future<String?> Function(String domain)? webSocketLookup =
      lookupXmppWebSocket,
  Duration timeout = const Duration(seconds: 25),
  int enough = 3,
  int parallel = 3,
  Duration headStart = const Duration(seconds: 4),
  bool needRegistration = false,
  void Function(String line)? log,
}) async {
  if (domains.isEmpty) return const [];
  final answered = <XmppServerProbe>[];
  final done = Completer<void>();
  var pending = domains.length;
  void settle() {
    if (!done.isCompleted && (answered.length >= enough || pending == 0)) {
      done.complete();
    }
  }

  final timers = <Timer>[];
  final queue = Queue.of(domains);
  var slots = parallel;
  void launch() {
    while (slots > 0 && queue.isNotEmpty && !done.isCompleted) {
      slots--;
      final domain = queue.removeFirst();
      final freed = Completer<void>();
      void free() {
        if (!freed.isCompleted) {
          freed.complete();
          slots++;
          launch();
        }
      }

      timers.add(Timer(headStart, free));
      final watch = Stopwatch()..start();
      var won = false;
      var outstanding = 0;
      void attempt(Future<XmppEndpoint?> endpointFuture) {
        outstanding++;
        endpointFuture
            .then((endpoint) async {
              if (endpoint == null) throw StateError('no endpoint');
              final features = await probeXmppEndpoint(
                endpoint: endpoint,
                domain: domain,
                connector: connector,
                webSocketConnector: webSocketConnector,
              );
              return (endpoint, features);
            })
            .then((result) {
              final (endpoint, features) = result;
              log?.call(
                '${endpoint.label} answered in '
                '${watch.elapsedMilliseconds} ms',
              );
              if (won) return;
              if (needRegistration && !features.register) {
                throw StateError('no in-band registration');
              }
              won = true;
              if (!done.isCompleted) {
                answered.add(
                  XmppServerProbe(
                    domain,
                    endpoint,
                    register: features.register,
                  ),
                );
              }
              pending--;
              settle();
              free();
            })
            .catchError((Object error) {
              if (--outstanding == 0 && !won) {
                log?.call('$domain did not answer: $error');
                pending--;
                settle();
                free();
              }
            });
      }

      for (final endpoint in xmppEndpointCandidates(domain)) {
        attempt(Future.value(endpoint));
      }
      if (webSocketLookup != null) {
        attempt(
          webSocketLookup(domain).then(
            (url) => url == null
                ? null
                : XmppEndpoint(
                    host: Uri.parse(url).host,
                    port: 443,
                    mode: XmppEndpointMode.webSocket,
                    webSocketUrl: url,
                  ),
          ),
        );
      }
    }
  }

  launch();
  await done.future.timeout(timeout, onTimeout: () {});
  for (final timer in timers) {
    timer.cancel();
  }
  return List.unmodifiable(answered);
}

/// Creates an account on the first of [servers] that registers one; returns
/// its configuration. A taken name is retried with another.
Future<XmppCarrierConfig> createXmppCarrierAccount(
  List<XmppServerProbe> servers, {
  required String resource,
  XmppSocketConnector connector = connectXmppSocket,
  XmppWebSocketConnector webSocketConnector = connectXmppWebSocket,
  Random? random,
  void Function(String line)? log,
}) async {
  Object? lastError;
  for (final server in servers) {
    if (!server.register) continue;
    for (var attempt = 0; attempt < 3; attempt++) {
      final config = XmppCarrierConfig.newAccount(
        server.domain,
        resource: resource,
        endpoints: [server.endpoint],
        random: random,
      );
      try {
        await registerXmppAccount(
          endpoint: server.endpoint,
          domain: server.domain,
          username: config.jid.split('@').first,
          password: config.password,
          connector: connector,
          webSocketConnector: webSocketConnector,
        );
        log?.call('XMPP: created an account on ${server.domain}');
        return config;
      } on XmppStanzaError catch (error) {
        lastError = error;
        log?.call('XMPP: ${server.domain} did not register: $error');
        if (error.condition != 'conflict') break;
      } catch (error) {
        lastError = error;
        log?.call('XMPP: ${server.domain} did not register: $error');
        break;
      }
    }
  }
  throw StateError(
    'No XMPP server here lets Conest create an account'
    '${lastError == null ? '' : ' ($lastError)'}. Use your own account.',
  );
}

/// Checks that [config]'s account signs in, without keeping a connection.
Future<void> checkXmppLogin(
  XmppCarrierConfig config, {
  XmppSocketConnector connector = connectXmppSocket,
  XmppWebSocketConnector webSocketConnector = connectXmppWebSocket,
  Duration timeout = const Duration(seconds: 45),
}) async {
  final connected = Completer<void>();
  late final XmppSession session;
  session = XmppSession(
    jid: config.jid,
    password: config.password,
    resource: config.resource,
    endpoints: config.connectEndpoints,
    connector: connector,
    webSocketConnector: webSocketConnector,
    priority: -1,
    onConnected: (_) {
      if (!connected.isCompleted) connected.complete();
    },
    onStateChanged: () {
      // A wrong password stops the session; other failures are retried.
      if (session.authFailed && !connected.isCompleted) {
        connected.completeError(StateError(session.lastError!));
      }
    },
  );
  session.start();
  try {
    await connected.future.timeout(timeout);
  } on TimeoutException {
    throw StateError(
      'The XMPP server did not answer${session.lastError == null ? '' : ': ${session.lastError}'}.',
    );
  } finally {
    await session.stop();
  }
}

enum XmppCarrierState { stopped, connecting, connected, failed }

/// The XMPP side of the carrier: one connection for the account under
/// Conest's own resource. Frames go in `<conest/>` elements of messages
/// without a body, marked private (no carbon copies) and no-copy, so the
/// account's other apps never show them; offline storage keeps them while
/// the other device is away.
class XmppCarrierChannel
    implements ManagedCarrierChannel, PeerAwareCarrierChannel {
  XmppCarrierChannel({
    required this.config,
    required this.onFrame,
    this.connector = connectXmppSocket,
    this.webSocketConnector = connectXmppWebSocket,
    this.onStatusChanged,
    this.onEndpoint,
    this.log,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final XmppCarrierConfig config;
  final void Function(String sender, Uint8List frame) onFrame;
  final XmppSocketConnector connector;
  final XmppWebSocketConnector webSocketConnector;
  final void Function()? onStatusChanged;
  final void Function(XmppEndpoint endpoint)? onEndpoint;
  final void Function(String line)? log;
  final DateTime Function() _now;

  XmppSession? _session;
  Set<String> _peers = const {};
  final Set<String> _subscribed = {};

  /// Contacts whose Conest resource is online now (from presence).
  final Set<String> onlinePeers = {};

  /// Most base64 characters accepted in one frame.
  static final int _maxFrameChars = (xmppFraming.chunkBytes + 16) * 4 ~/ 3 + 8;

  XmppSession? get session => _session;

  XmppCarrierState get state => switch (_session?.state) {
    null || XmppSessionState.stopped => XmppCarrierState.stopped,
    XmppSessionState.connecting => XmppCarrierState.connecting,
    XmppSessionState.connected => XmppCarrierState.connected,
    XmppSessionState.failed => XmppCarrierState.failed,
  };

  String? get lastError => _session?.lastError;

  @override
  String? get localAddress => config.address.encode();

  @override
  String get routeLabel => _session?.endpoint?.host ?? config.domain;

  @override
  void start() {
    if (_session != null) return;
    final session = _session = XmppSession(
      jid: config.jid,
      password: config.password,
      resource: config.resource,
      endpoints: config.connectEndpoints,
      connector: connector,
      webSocketConnector: webSocketConnector,
      // The user's own account: its ordinary chats stay with their apps.
      priority: config.created ? 0 : -1,
      onStanza: _onStanza,
      onStateChanged: onStatusChanged,
      onConnected: (_) => unawaited(_syncRoster()),
      onEndpoint: onEndpoint,
      log: log,
      now: _now,
    );
    session.start();
  }

  @override
  Future<void> stop() async {
    final session = _session;
    _session = null;
    onlinePeers.clear();
    _subscribed.clear();
    await session?.stop();
    onStatusChanged?.call();
  }

  /// The app moved to the foreground ([active]) or the background.
  void setActive(bool active) => _session?.setActive(active);

  @override
  Future<void> sendFrame(String address, Uint8List frame) async {
    final session = _session;
    final target = XmppCarrierAddress.tryParse(address);
    if (session == null) throw StateError('XMPP is not running.');
    if (target == null) throw ArgumentError('Not an XMPP carrier address.');
    await session.send(
      XmppElement(
        'message',
        attributes: {
          'to': target.fullJid,
          'type': 'chat',
          'id': session.newId(),
        },
        children: [
          XmppElement(
            'conest',
            xmlns: XmppNs.conestCarrier,
            text: base64.encode(frame),
          ),
          XmppElement('private', xmlns: XmppNs.carbons),
          XmppElement('no-copy', xmlns: XmppNs.hints),
          XmppElement('store', xmlns: XmppNs.hints),
        ],
      ),
    );
  }

  @override
  void updatePeers(Set<String> addresses) {
    _peers = {
      for (final address in addresses)
        if (XmppCarrierAddress.tryParse(address) case final parsed?) parsed.jid,
    };
    if (_session?.state == XmppSessionState.connected) {
      unawaited(_syncRoster());
    }
  }

  void _onStanza(XmppElement stanza) {
    switch (stanza.name) {
      case 'message':
        _onMessage(stanza);
      case 'presence':
        _onPresence(stanza);
    }
  }

  void _onMessage(XmppElement message) {
    final type = message.attr('type');
    if (type == 'error' || type == 'groupchat' || type == 'headline') return;
    final element = message.child('conest', XmppNs.conestCarrier);
    if (element == null) return;
    final sender = bareJid(message.attr('from'));
    if (sender == null || !sender.contains('@')) return;
    final text = element.text.trim();
    if (text.isEmpty || text.length > _maxFrameChars) return;
    final Uint8List frame;
    try {
      frame = base64.decode(text);
    } on FormatException {
      return;
    }
    onFrame(sender, frame);
  }

  void _onPresence(XmppElement presence) {
    final from = presence.attr('from');
    final sender = bareJid(from);
    if (sender == null || !_peers.contains(sender)) return;
    switch (presence.attr('type')) {
      case 'subscribe':
        // Contacts only: strangers' requests get no answer.
        unawaited(
          _session
              ?.send(
                XmppElement(
                  'presence',
                  attributes: {'to': sender, 'type': 'subscribed'},
                ),
              )
              .catchError((Object _) {}),
        );
      case null:
        if (jidResource(from!)?.startsWith('conest-') ?? false) {
          onlinePeers.add(sender);
        }
      case 'unavailable':
        onlinePeers.remove(sender);
    }
  }

  /// Asks contacts for presence subscriptions (once each per connection),
  /// so their Conest is seen online and servers that hold back strangers'
  /// messages let frames through.
  Future<void> _syncRoster() async {
    final session = _session;
    if (session == null || session.state != XmppSessionState.connected) return;
    final Map<String, String> roster;
    try {
      final result = await session.request(
        XmppElement(
          'iq',
          attributes: {'type': 'get'},
          children: [XmppElement('query', xmlns: XmppNs.roster)],
        ),
      );
      roster = {
        for (final item
            in (result.child('query', XmppNs.roster)?.all('item') ??
                    const <XmppElement>[])
                .take(10000))
          ?bareJid(item.attr('jid')): item.attr('subscription') ?? 'none',
      };
    } catch (error) {
      log?.call('XMPP: roster unavailable: $error');
      return;
    }
    var asked = 0;
    for (final peer in _peers) {
      final subscription = roster[peer];
      if (subscription == 'both' || subscription == 'to') continue;
      if (!_subscribed.add(peer) || asked >= 20) continue;
      asked++;
      unawaited(
        session
            .send(
              XmppElement(
                'presence',
                attributes: {'to': peer, 'type': 'subscribe'},
              ),
            )
            .catchError((Object _) {}),
      );
    }
  }
}

/// An XMPP carrier adapter. Store and forward: the server keeps frames for
/// a device that is away.
CarrierTransportAdapter createXmppCarrierAdapter({
  required CarrierSealer sealer,
  DateTime Function()? now,
}) => CarrierTransportAdapter(
  kind: TransportKind.xmpp,
  sealer: sealer,
  framing: xmppFraming,
  sendAttemptTimeout: const Duration(seconds: 90),
  isValidAddress: isValidXmppCarrierAddress,
  now: now,
);

/// How Conest reaches XMPP servers; tests substitute in-memory ones.
class XmppNetwork {
  const XmppNetwork({
    this.connector = connectXmppSocket,
    this.webSocketConnector = connectXmppWebSocket,
    this.webSocketLookup = lookupXmppWebSocket,
  });

  final XmppSocketConnector connector;
  final XmppWebSocketConnector webSocketConnector;
  final Future<String?> Function(String domain)? webSocketLookup;
}
