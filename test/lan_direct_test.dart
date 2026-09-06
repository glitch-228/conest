import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:conest/src/lan_direct.dart';
import 'package:conest/src/models.dart';

RelayEnvelope _envelope(int index) => RelayEnvelope(
  kind: 'attachment_chunk',
  messageId: 'chunk-$index',
  conversationId: 'conversation',
  senderAccountId: 'account-a',
  senderDeviceId: 'device-a',
  recipientDeviceId: 'device-b',
  createdAt: DateTime.utc(2026),
  payloadBase64: base64Encode(<int>[index & 0xff]),
);

Future<int> _putRaw(int port, RelayEnvelope envelope, HttpClient client) async {
  final request = await client.putUrl(
    Uri.parse('http://127.0.0.1:$port/v1/chunk'),
  );
  final body = utf8.encode(jsonEncode(envelope.toJson()));
  request.contentLength = body.length;
  request.add(body);
  final response = await request.close();
  await response.drain<void>();
  return response.statusCode;
}

void main() {
  test(
    'timed-out LAN uploads release pooled connections for the next block',
    () async {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      );
      final host = interfaces
          .expand((entry) => entry.addresses)
          .map((address) => address.address)
          .firstWhere(isValidLanDirectHost);
      final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      addTearDown(() => server.close(force: true));
      var hang = true;
      server.listen((request) async {
        try {
          await request.drain<void>();
          if (hang) return;
          request.response.statusCode = HttpStatus.accepted;
          await request.response.close();
        } catch (_) {}
      });
      final channel = HttpLanDirectChannel();
      addTearDown(channel.stop);
      final failed = await Future.wait([
        for (var i = 0; i < 20; i++)
          channel.putEnvelope(
            host: host,
            port: server.port,
            envelope: _envelope(i),
            timeout: const Duration(milliseconds: 300),
          ),
      ]);
      expect(failed, everyElement(isFalse));
      hang = false;
      expect(
        await channel.putEnvelope(
          host: host,
          port: server.port,
          envelope: _envelope(21),
          timeout: const Duration(seconds: 2),
        ),
        isTrue,
        reason: channel.lastPutFailure,
      );
    },
  );

  test('LAN-direct accepts only private or link-local literal addresses', () {
    for (final host in const <String>[
      '10.0.0.1',
      '172.16.0.1',
      '172.31.255.254',
      '192.168.1.5',
      '169.254.1.5',
      'fd00::1',
      'fe80::1',
    ]) {
      expect(isValidLanDirectHost(host), isTrue, reason: host);
    }
    for (final host in const <String>[
      '127.0.0.1',
      '0.0.0.0',
      '8.8.8.8',
      'example.com',
      '::',
      '::1',
      '192.168.1.1.evil',
    ]) {
      expect(isValidLanDirectHost(host), isFalse, reason: host);
    }
  });

  test(
    'LAN-direct server rejects oversized requests before reading a body',
    () async {
      final channel = HttpLanDirectChannel();
      addTearDown(channel.stop);
      final port = await channel.start();
      expect(port, isNotNull);

      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final request = await client.putUrl(
        Uri.parse('http://127.0.0.1:$port/v1/chunk'),
      );
      final oversizedLength = 5 * 1024 * 1024 + 1;
      request.contentLength = oversizedLength;
      request.add(Uint8List(oversizedLength));
      final response = await request.close().timeout(
        const Duration(seconds: 5),
      );
      await response.drain<void>();

      expect(response.statusCode, HttpStatus.requestEntityTooLarge);
    },
  );

  test(
    'LAN-direct accepts a pipelined block window without handler starvation',
    () async {
      final channel = HttpLanDirectChannel();
      addTearDown(channel.stop);
      channel.onEnvelope = (_) async {
        await Future<void>.delayed(const Duration(milliseconds: 150));
      };
      final port = await channel.start();
      expect(port, isNotNull);

      final client = HttpClient()..maxConnectionsPerHost = 64;
      addTearDown(() => client.close(force: true));
      final statuses = await Future.wait(<Future<int>>[
        for (var index = 0; index < 32; index++)
          _putRaw(port!, _envelope(index), client),
      ]).timeout(const Duration(seconds: 5));

      expect(statuses, everyElement(HttpStatus.accepted));
    },
  );

  test(
    'LAN-direct rate ceiling does not cut off a normal block stream',
    () async {
      final channel = HttpLanDirectChannel();
      addTearDown(channel.stop);
      channel.onEnvelope = (_) async {};
      final port = await channel.start();
      expect(port, isNotNull);

      final client = HttpClient()..maxConnectionsPerHost = 32;
      addTearDown(() => client.close(force: true));
      for (var start = 0; start < 256; start += 32) {
        final statuses = await Future.wait(<Future<int>>[
          for (var index = start; index < start + 32; index++)
            _putRaw(port!, _envelope(index), client),
        ]);
        expect(statuses, everyElement(HttpStatus.accepted));
      }
    },
  );
}
