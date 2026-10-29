import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'doh_resolver.dart';

/// Where the server name sits in a TLS ClientHello record: the offset of
/// its first byte and its length (null: not a ClientHello with one).
({int offset, int length})? findClientHelloSni(List<int> record) {
  // Record: type 22 (handshake), version, length; handshake type 1.
  if (record.length < 5 + 4 + 2 + 32 + 1 ||
      record[0] != 0x16 ||
      record[1] != 0x03 ||
      record[5] != 0x01) {
    return null;
  }
  var offset = 5 + 4 + 2 + 32;
  int? read16(int at) =>
      at + 1 < record.length ? (record[at] << 8) | record[at + 1] : null;
  final sessionLength = record[offset];
  offset += 1 + sessionLength;
  final ciphers = read16(offset);
  if (ciphers == null) return null;
  offset += 2 + ciphers;
  if (offset >= record.length) return null;
  final compression = record[offset];
  offset += 1 + compression;
  final extensionsLength = read16(offset);
  if (extensionsLength == null) return null;
  offset += 2;
  final end = min(offset + extensionsLength, record.length);
  while (offset + 4 <= end) {
    final type = read16(offset)!;
    final length = read16(offset + 2)!;
    final data = offset + 4;
    if (type == 0 && data + 5 <= end) {
      // server_name: list length, name type (0), name length, name.
      final nameLength = read16(data + 3);
      if (nameLength == null || data + 5 + nameLength > record.length) {
        return null;
      }
      return (offset: data + 5, length: nameLength);
    }
    offset = data + length;
  }
  return null;
}

/// Splits a ClientHello [record] so no piece holds the whole server name:
/// two TLS records (the handshake split across them, which TLS allows),
/// each to go in its own TCP segment. Anything else comes back whole.
List<Uint8List> splitClientHello(Uint8List record) {
  final sni = findClientHelloSni(record);
  final recordLength = record.length >= 5 ? (record[3] << 8) | record[4] : 0;
  if (sni == null || record.length < 5 + recordLength || sni.length < 2) {
    return [record];
  }
  final cut = sni.offset + sni.length ~/ 2;
  final firstBody = record.sublist(5, cut);
  final secondBody = record.sublist(cut, 5 + recordLength);
  Uint8List wrap(List<int> body) => Uint8List.fromList([
    record[0],
    record[1],
    record[2],
    body.length >> 8,
    body.length & 0xff,
    ...body,
  ]);
  return [
    wrap(firstBody),
    wrap(secondBody),
    if (record.length > 5 + recordLength)
      Uint8List.fromList(record.sublist(5 + recordLength)),
  ];
}

/// A CONNECT proxy on the loopback interface, for this app only (it asks
/// for a random token), that does what DPI-evading tools do on the client
/// side: looks names up over DoH, and sends a TLS ClientHello in pieces
/// that cut through its server name, each its own TCP segment, so a
/// filter reading the first segment does not see the name.
///
/// A loopback forwarder rather than a native connector: Dart's TLS writes
/// the ClientHello itself and gives no hook between it and the socket,
/// while a forwarder needs no native build and serves every connector
/// (sockets, HttpClient through a proxy setting, and native clients that
/// take a proxy).
class FragmentingProxy {
  FragmentingProxy({
    required this.resolve,
    this.fragment = true,
    this.segmentGap = const Duration(milliseconds: 10),
    this.connectTimeout = const Duration(seconds: 8),
  });

  /// How names are looked up (DoH, or the system's).
  final Future<List<InternetAddress>> Function(String host) resolve;

  /// Whether to split ClientHellos (off: the proxy only resolves).
  bool fragment;
  final Duration segmentGap;
  final Duration connectTimeout;
  final String _token = base64Url
      .encode(List<int>.generate(24, (_) => Random.secure().nextInt(256)))
      .replaceAll('=', '');
  ServerSocket? _server;
  final Set<Socket> _open = {};

  static const int _maxConnections = 128;

  int? get port => _server?.port;

  /// `Proxy-Authorization` for this proxy.
  String get authorization =>
      'Basic ${base64Encode(utf8.encode('conest:$_token'))}';

  /// The proxy for [HttpClient.findProxy].
  String get proxyDirective =>
      'PROXY conest:$_token@127.0.0.1:${_server!.port}';

  Future<void> start() async {
    if (_server != null) return;
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.listen((client) => unawaited(_serve(client)));
  }

  Future<void> stop() async {
    await _server?.close();
    _server = null;
    for (final socket in _open.toList()) {
      socket.destroy();
    }
    _open.clear();
  }

  /// Dials waiting for their first bytes, by the client's local port
  /// (in this process only: nothing else can register one).
  final Map<int, ({String host, int port, DateTime until})> _dials = {};

  /// A TLS connection to [host]:[port] through this proxy (SNI = [host]):
  /// the socket to the proxy is registered for that target before the
  /// first byte goes, so no request header is needed (and Dart's TLS can
  /// take the socket as it is).
  Future<SecureSocket> secureConnect(
    String host,
    int port, {
    Duration timeout = const Duration(seconds: 8),
    bool Function(X509Certificate certificate)? onBadCertificate,
    List<String>? supportedProtocols,
    SecurityContext? context,
  }) async {
    await start();
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      _server!.port,
      timeout: timeout,
    );
    final now = DateTime.now();
    _dials.removeWhere((_, dial) => dial.until.isBefore(now));
    if (_dials.length >= _maxConnections) {
      socket.destroy();
      throw const SocketException('Too many circumvention dials.');
    }
    _dials[socket.port] = (
      host: host,
      port: port,
      until: now.add(timeout + const Duration(seconds: 2)),
    );
    try {
      return await SecureSocket.secure(
        socket,
        host: host,
        context: context,
        onBadCertificate: onBadCertificate,
        supportedProtocols: supportedProtocols,
      ).timeout(timeout);
    } catch (_) {
      _dials.remove(socket.port);
      socket.destroy();
      rethrow;
    }
  }

  Future<void> _serve(Socket client) async {
    if (_open.length >= _maxConnections) {
      client.destroy();
      return;
    }
    _open.add(client);
    Socket? upstream;
    try {
      final input = StreamIterator<Uint8List>(client);
      if (!await input.moveNext().timeout(const Duration(seconds: 10))) {
        return;
      }
      var first = input.current;
      String host;
      int port;
      final dial = client.remoteAddress.isLoopback
          ? _dials.remove(client.remotePort)
          : null;
      if (dial != null) {
        host = dial.host;
        port = dial.port;
      } else {
        // A CONNECT request (HttpClient, native clients), with the token.
        final head = BytesBuilder()..add(first);
        var end = latin1
            .decode(head.toBytes(), allowInvalid: true)
            .indexOf('\r\n\r\n');
        while (end < 0) {
          if (head.length > 8192 ||
              !await input.moveNext().timeout(const Duration(seconds: 10))) {
            return;
          }
          head.add(input.current);
          end = latin1
              .decode(head.toBytes(), allowInvalid: true)
              .indexOf('\r\n\r\n');
        }
        final bytes = head.toBytes();
        final lines = latin1
            .decode(bytes.sublist(0, end), allowInvalid: true)
            .split('\r\n');
        final request = lines.first.split(' ');
        final authorized = lines.any(
          (line) =>
              line.toLowerCase().startsWith('proxy-authorization:') &&
              constantTimeEquals(
                line.substring(line.indexOf(':') + 1).trim(),
                authorization,
              ),
        );
        if (request.length < 2 || request[0] != 'CONNECT' || !authorized) {
          client.add(
            utf8.encode('HTTP/1.1 407 Proxy Authentication Required\r\n\r\n'),
          );
          await client.flush();
          return;
        }
        final target = request[1];
        final colon = target.lastIndexOf(':');
        final parsedPort = int.tryParse(target.substring(colon + 1));
        var parsedHost = colon > 0 ? target.substring(0, colon) : '';
        if (parsedHost.startsWith('[') && parsedHost.endsWith(']')) {
          parsedHost = parsedHost.substring(1, parsedHost.length - 1);
        }
        if (parsedPort == null ||
            parsedPort < 1 ||
            parsedPort > 65535 ||
            parsedHost.isEmpty) {
          client.add(utf8.encode('HTTP/1.1 400 Bad Request\r\n\r\n'));
          await client.flush();
          return;
        }
        host = parsedHost;
        port = parsedPort;
        upstream = await _dial(host, port);
        client.add(utf8.encode('HTTP/1.1 200 Connection established\r\n\r\n'));
        await client.flush();
        // Whatever followed the request is the tunnel's first bytes; if
        // nothing did, they are the next chunk.
        final rest = bytes.sublist(end + 4);
        if (rest.isNotEmpty) {
          first = Uint8List.fromList(rest);
        } else if (await input.moveNext().timeout(
          const Duration(seconds: 30),
        )) {
          first = input.current;
        } else {
          return;
        }
      }
      final remote = upstream ??= await _dial(host, port);
      _open.add(remote);
      try {
        client.setOption(SocketOption.tcpNoDelay, true);
      } on Object {
        // Loopback without the option still works.
      }
      final down = client.addStream(remote).catchError((Object _) {});
      if (fragment) {
        final pieces = splitClientHello(first);
        for (var index = 0; index < pieces.length; index++) {
          remote.add(pieces[index]);
          await remote.flush();
          if (index < pieces.length - 1) {
            await Future<void>.delayed(segmentGap);
          }
        }
      } else {
        remote.add(first);
      }
      while (await input.moveNext()) {
        remote.add(input.current);
      }
      await remote.flush();
      await remote.close();
      await down;
    } on Object {
      // A broken tunnel ends; the app sees its connection fail.
    } finally {
      upstream?.destroy();
      client.destroy();
      _open.remove(client);
      if (upstream != null) _open.remove(upstream);
    }
  }

  /// A TCP connection to [host]:[port], its name looked up by [resolve].
  Future<Socket> _dial(String host, int port) async {
    final addresses = await resolve(host);
    Object? lastError;
    for (final address in addresses.take(3)) {
      try {
        final socket = await Socket.connect(
          address,
          port,
          timeout: connectTimeout,
        );
        socket.setOption(SocketOption.tcpNoDelay, true);
        return socket;
      } on Object catch (error) {
        lastError = error;
      }
    }
    throw lastError ?? SocketException('No address for $host answered.');
  }
}

/// The resolver the proxy uses when DoH is off.
Future<List<InternetAddress>> systemResolve(String host) async {
  final literal = InternetAddress.tryParse(host);
  if (literal != null) return [literal];
  return InternetAddress.lookup(host);
}

/// The resolver the proxy uses when DoH is on.
Future<List<InternetAddress>> Function(String) dohResolve(DohResolver doh) =>
    doh.resolve;

/// Equality that takes the same time wherever the strings differ.
bool constantTimeEquals(String a, String b) {
  var difference = a.length ^ b.length;
  final length = a.length < b.length ? a.length : b.length;
  for (var index = 0; index < length; index++) {
    difference |= a.codeUnitAt(index) ^ b.codeUnitAt(index);
  }
  return difference == 0;
}
