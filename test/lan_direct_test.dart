import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:conest/src/lan_direct.dart';

void main() {
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
      final oversizedLength = 2 * 1024 * 1024 + 1;
      request.contentLength = oversizedLength;
      request.add(Uint8List(oversizedLength));
      final response = await request.close().timeout(
        const Duration(seconds: 5),
      );
      await response.drain<void>();

      expect(response.statusCode, HttpStatus.requestEntityTooLarge);
    },
  );
}
