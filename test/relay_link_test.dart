import 'dart:convert';

import 'package:conest/src/relay_link.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final key = base64Encode(List<int>.generate(32, (i) => i * 7 % 256));

  test('the installer link parses, with its key intact', () {
    final link = RelayLink.tryParse(
      'conest-relay://relay.example.org:7667?id=relay-0a1b2c3d4e5f6a7b'
      '&key=${Uri.encodeQueryComponent(key)}',
    )!;
    expect(link.host, 'relay.example.org');
    expect(link.port, 7667);
    expect(link.relayId, 'relay-0a1b2c3d4e5f6a7b');
    expect(link.identityKeyBase64, key);
    expect(RelayLink.tryParse(link.toString())!.identityKeyBase64, key);
    // The installer's encoding of + / =.
    final encoded = key
        .replaceAll('+', '%2B')
        .replaceAll('/', '%2F')
        .replaceAll('=', '%3D');
    expect(
      RelayLink.tryParse(
        'conest-relay://1.2.3.4?id=r1&key=$encoded',
      )!.identityKeyBase64,
      key,
    );
  });

  test('anything else is refused', () {
    for (final text in [
      'https://relay.example.org?id=r1&key=$key',
      'conest-relay://?id=r1&key=$key',
      'conest-relay://relay.example.org?key=$key',
      'conest-relay://relay.example.org?id=bad%20id&key=$key',
      'conest-relay://relay.example.org?id=r1&key=c2hvcnQ=',
      'conest-relay://relay.example.org?id=r1&key=not*base64',
      'conest-relay://relay.example.org:0?id=r1&key=$key',
      'conest-relay://relay.example.org?id=r1&key=${'A' * 600}',
    ]) {
      expect(RelayLink.tryParse(text), isNull, reason: text);
    }
  });
}
