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

  group('borrowed address and no plain port (M38 S1)', () {
    String sni250() => '${'a' * 61}.${'b' * 61}.${'c' * 61}.${'d' * 60}.com';

    test('a borrowed address rides in the link, and in toString', () {
      final text =
          'conest-relay://relay.example.org:7667?id=r1'
          '&key=${Uri.encodeQueryComponent(key)}'
          '&borrowed=${Uri.encodeQueryComponent('borrowed://203.0.113.7:443/www.bing.com')}';
      final link = RelayLink.tryParse(text)!;
      expect(link.borrowedAddress, 'borrowed://203.0.113.7:443/www.bing.com');
      expect(link.hasPlainPort, isTrue);
      final again = RelayLink.tryParse(link.toString())!;
      expect(again.borrowedAddress, link.borrowedAddress);
      expect(again.identityKeyBase64, key);
    });

    test('a link with no plain port needs another address to be one', () {
      final base =
          'conest-relay://relay.example.org:7667?id=r1'
          '&key=${Uri.encodeQueryComponent(key)}';
      expect(RelayLink.tryParse('$base&plain=none'), isNull);
      final borrowed = Uri.encodeQueryComponent(
        'borrowed://203.0.113.7/www.bing.com',
      );
      final link = RelayLink.tryParse(
        '$base&plain=none&borrowed=$borrowed',
      )!;
      expect(link.hasPlainPort, isFalse);
      expect(RelayLink.tryParse(link.toString())!.hasPlainPort, isFalse);
      // Any other word for `plain` leaves the plain port in.
      expect(
        RelayLink.tryParse('$base&plain=maybe')!.hasPlainPort,
        isTrue,
      );
    });

    test('bad borrowed addresses make the link refused', () {
      final base =
          'conest-relay://relay.example.org:7667?id=r1'
          '&key=${Uri.encodeQueryComponent(key)}';
      for (final bad in [
        'wss://203.0.113.7/www.bing.com',
        'borrowed://203.0.113.7',
        'borrowed://203.0.113.7/',
        'borrowed://203.0.113.7/not_a_name',
        'borrowed://203.0.113.7/single',
        'borrowed://203.0.113.7:0/www.bing.com',
        'borrowed:///www.bing.com',
      ]) {
        expect(
          RelayLink.tryParse('$base&borrowed=${Uri.encodeQueryComponent(bad)}'),
          isNull,
          reason: bad,
        );
      }
    });

    test('a 250-character name and an IPv6 literal fit the link, '
        'which the old 512-character cap would have refused', () {
      final borrowed = Uri.encodeQueryComponent(
        'borrowed://[2001:db8::7]:443/${sni250()}',
      );
      final wss = Uri.encodeQueryComponent(
        'wss://relay.example.org/${'p' * 64}',
      );
      final text =
          'conest-relay://relay.example.org:7667?id=relay-0a1b2c3d4e5f6a7b'
          '&key=${Uri.encodeQueryComponent(key)}&wss=$wss&borrowed=$borrowed';
      expect(text.length, greaterThan(512));
      expect(text.length, lessThan(RelayLink.maxLength));
      final link = RelayLink.tryParse(text)!;
      expect(link.borrowedAddress, 'borrowed://[2001:db8::7]:443/${sni250()}');
      expect(link.hiddenAddress, 'wss://relay.example.org/${'p' * 64}');
      // But not without limit.
      expect(RelayLink.tryParse('$text&x=${'y' * 600}'), isNull);
    });

    test('a parameter nobody knows yet is ignored, as an old reader does', () {
      final link = RelayLink.tryParse(
        'conest-relay://relay.example.org?id=r1'
        '&key=${Uri.encodeQueryComponent(key)}&future=1',
      );
      expect(link, isNotNull);
      expect(link!.borrowedAddress, isNull);
    });
  });
}
