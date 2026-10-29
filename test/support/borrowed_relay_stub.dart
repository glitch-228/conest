import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// The relay side of the borrowed handshake, written from the format
/// description in `native/conest_relay/src/borrowed.rs`: forwards records
/// to [site] until a client's marker holds, then echoes tunnel data back.
class BorrowedRelayStub {
  BorrowedRelayStub._(this._server, this.identityPublic, this._secret);

  final ServerSocket _server;
  final List<int> identityPublic;
  final List<int> _secret;

  /// What each tunnel connection sent (decrypted).
  final List<List<int>> tunnelData = [];

  /// Records the site was sent, per connection.
  final List<BytesBuilder> siteReceived = [];

  /// Close the connection right after the first answer (as a relay does
  /// after one v1 line).
  bool closeAfterEcho = false;

  int get port => _server.port;

  static final _x25519 = X25519();
  static final _sha256 = Sha256();
  static final _hmac = Hmac.sha256();
  static final _aead = Chacha20.poly1305Aead();

  static Future<BorrowedRelayStub> start({
    required String siteHost,
    required int sitePort,
    required List<int> seed,
  }) async {
    final digest = (await Sha512().hash(seed)).bytes.sublist(0, 32);
    digest[0] &= 248;
    digest[31] &= 127;
    digest[31] |= 64;
    final identity = await (await Ed25519().newKeyPairFromSeed(
      seed,
    )).extractPublicKey();
    final stub = BorrowedRelayStub._(
      await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
      identity.bytes,
      digest,
    );
    stub._server.listen(
      (client) => unawaited(stub._serve(client, siteHost, sitePort)),
    );
    return stub;
  }

  Future<void> close() => _server.close();

  Future<Uint8List> _mac(List<int> key, List<List<int>> parts) async =>
      Uint8List.fromList(
        (await _hmac.calculateMac([
          for (final part in parts) ...part,
        ], secretKey: SecretKey(key))).bytes,
      );

  static List<int> _record(List<int> payload) => [
    0x17,
    3,
    3,
    payload.length >> 8,
    payload.length & 0xff,
    ...payload,
  ];

  List<List<int>> _take(BytesBuilder pending) {
    final out = <List<int>>[];
    var bytes = pending.takeBytes();
    while (bytes.length >= 5) {
      final length = (bytes[3] << 8) | bytes[4];
      if (bytes.length < 5 + length) break;
      out.add(bytes.sublist(0, 5 + length));
      bytes = bytes.sublist(5 + length);
    }
    if (bytes.isNotEmpty) pending.add(bytes);
    return out;
  }

  Future<void> _serve(Socket client, String siteHost, int sitePort) async {
    final site = await Socket.connect(siteHost, sitePort);
    final received = BytesBuilder();
    siteReceived.add(received);
    var serverRandom = <int>[];
    var tunnel = false;
    var records = 0;
    final fromSite = BytesBuilder(copy: false);
    final fromClient = BytesBuilder(copy: false);
    List<int>? receiveKey;
    List<int>? sendKey;
    var receiveCounter = 0;
    var sendCounter = 0;
    var chain = Future<void>.value();

    site.listen((chunk) {
      if (tunnel) return;
      fromSite.add(chunk);
      for (final record in _take(fromSite)) {
        if (serverRandom.isEmpty &&
            record[0] == 0x16 &&
            record.length >= 43 &&
            record[5] == 2) {
          serverRandom = record.sublist(11, 43);
        }
        client.add(record);
      }
    }, onDone: client.destroy);

    client.listen((chunk) {
      chain = chain.then((_) async {
        fromClient.add(chunk);
        for (final record in _take(fromClient)) {
          if (!tunnel) {
            if (record[0] == 0x17 &&
                ++records <= 8 &&
                serverRandom.isNotEmpty &&
                record.length >= 5 + 48) {
              final ephemeral = record.sublist(5, 37);
              final shared = await (await _x25519.sharedSecretKey(
                keyPair: await _x25519.newKeyPairFromSeed(_secret),
                remotePublicKey: SimplePublicKey(
                  ephemeral,
                  type: KeyPairType.x25519,
                ),
              )).extractBytes();
              final relayPublic = (await (await _x25519.newKeyPairFromSeed(
                _secret,
              )).extractPublicKey()).bytes;
              final exchange = (await _sha256.hash([
                ...utf8.encode('conest-borrowed-v1'),
                ...shared,
                ...ephemeral,
                ...relayPublic,
              ])).bytes;
              final tag = (await _mac(exchange, [
                utf8.encode('client'),
                serverRandom,
              ])).sublist(0, 16);
              final given = record.sublist(37, 53);
              var difference = 0;
              for (var i = 0; i < 16; i++) {
                difference |= tag[i] ^ given[i];
              }
              if (difference == 0) {
                tunnel = true;
                receiveKey = await _mac(exchange, [
                  utf8.encode('tunnel'),
                  utf8.encode('c2s'),
                  serverRandom,
                ]);
                sendKey = await _mac(exchange, [
                  utf8.encode('tunnel'),
                  utf8.encode('s2c'),
                  serverRandom,
                ]);
                final ack = (await _mac(exchange, [
                  utf8.encode('ack'),
                  serverRandom,
                  tag,
                ])).sublist(0, 16);
                unawaited(site.close());
                client.add(_record([...ack, ...List<int>.filled(11, 7)]));
                tunnelData.add([]);
                continue;
              }
            }
            received.add(record);
            site.add(record);
            continue;
          }
          final payload = record.sublist(5);
          final framed = await _aead.decrypt(
            SecretBox(
              payload.sublist(0, payload.length - 16),
              nonce: _nonce(receiveCounter++),
              mac: Mac(payload.sublist(payload.length - 16)),
            ),
            secretKey: SecretKey(receiveKey!),
          );
          final data = framed.sublist(2, 2 + ((framed[0] << 8) | framed[1]));
          tunnelData.last.addAll(data);
          // Echo it reversed.
          final reply = data.reversed.toList();
          final out = Uint8List(2 + reply.length)
            ..[0] = reply.length >> 8
            ..[1] = reply.length & 0xff
            ..setRange(2, 2 + reply.length, reply);
          final box = await _aead.encrypt(
            out,
            secretKey: SecretKey(sendKey!),
            nonce: _nonce(sendCounter++),
          );
          client.add(_record([...box.cipherText, ...box.mac.bytes]));
          if (closeAfterEcho) await client.close();
        }
      });
    }, onDone: site.destroy);
  }

  static Uint8List _nonce(int counter) {
    final nonce = Uint8List(12);
    ByteData.view(nonce.buffer).setUint64(4, counter);
    return nonce;
  }
}
