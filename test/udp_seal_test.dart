import 'dart:convert';

import 'package:conest/src/relay_client.dart';
import 'package:conest/src/relay_v2/udp_seal.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final request = utf8.encode(
    jsonEncode({
      'action': 'store',
      'recipient_device_id': 'dev-b',
      'nonce': 'AAAAAAAAAAAAAAAAAAAAAA==',
      'sig_mode': 'detached',
    }),
  );

  Future<List<int>> relayKey() async {
    final pair = await X25519().newKeyPair();
    return (await pair.extractPublicKey()).bytes;
  }

  test(
    'a sealed datagram shows nothing of the request and varies in size',
    () async {
      final key = await relayKey();
      final sizes = <int>{};
      for (var i = 0; i < 20; i++) {
        final (datagram, _) = await UdpSeal.seal(
          relayPublic: key,
          request: request,
          padding: UdpSeal.paddingFor(request.length, cookieRequest: true),
        );
        sizes.add(datagram.length);
        final text = latin1.decode(datagram);
        for (final tell in [
          'action',
          'recipient_device_id',
          'nonce',
          'sig_mode',
        ]) {
          expect(text.contains(tell), isFalse, reason: tell);
        }
        expect(datagram[0], isNot(0x7b), reason: 'not the cleartext form');
        expect(datagram.length, greaterThanOrEqualTo(128));
      }
      expect(sizes.length, greaterThan(5));
    },
  );

  test(
    'an answer opens only for its own exchange, and only untouched',
    () async {
      final key = await relayKey();
      final (_, mine) = await UdpSeal.seal(relayPublic: key, request: request);
      final (_, other) = await UdpSeal.seal(relayPublic: key, request: request);
      // A relay's answer is built from the same derivation; here a forged one
      // (random bytes of a plausible size) must not open.
      final forged = List<int>.generate(80, (i) => (i * 37 + 11) & 0xff);
      expect(await mine.open(forged), isNull);
      expect(await other.open(forged), isNull);
      expect(await mine.open(const []), isNull);
      expect(await mine.open(List<int>.filled(10, 1)), isNull);
    },
  );

  test('padding grows a cookie request to the length the relay needs', () {
    for (var i = 0; i < 50; i++) {
      final pad = UdpSeal.paddingFor(40, cookieRequest: true);
      expect(UdpSeal.overhead + 40 + pad, greaterThanOrEqualTo(128));
    }
  });

  test(
    'a relay that follows the spec opens the request and its answer opens',
    () async {
      final x = X25519();
      final relay = await x.newKeyPair();
      final relayPublic = (await relay.extractPublicKey()).bytes;
      final (datagram, reply) = await UdpSeal.seal(
        relayPublic: relayPublic,
        request: request,
        padding: 25,
      );
      // The relay's side, written from the format description.
      final ephemeral = datagram.sublist(0, 32);
      final shared = await (await x.sharedSecretKey(
        keyPair: relay,
        remotePublicKey: SimplePublicKey(ephemeral, type: KeyPairType.x25519),
      )).extractBytes();
      Future<List<int>> derive(String direction) async => (await Sha256().hash([
        ...utf8.encode('conest-relay-udp-v2'),
        ...utf8.encode(direction),
        ...shared,
        ...ephemeral,
        ...relayPublic,
      ])).bytes;
      final aead = Chacha20.poly1305Aead();
      final framed = await aead.decrypt(
        SecretBox(
          datagram.sublist(44, datagram.length - 16),
          nonce: datagram.sublist(32, 44),
          mac: Mac(datagram.sublist(datagram.length - 16)),
        ),
        secretKey: SecretKey(await derive('|request')),
        aad: ephemeral,
      );
      final length = (framed[0] << 8) | framed[1];
      expect(framed.sublist(2, 2 + length), request);
      expect(framed.length, 2 + length + 25);
      // Its answer, sealed back.
      final answer = utf8.encode('{"ok":true}');
      final nonce = List<int>.generate(12, (i) => i + 1);
      final box = await aead.encrypt(
        [0, answer.length, ...answer, 0, 0, 0],
        secretKey: SecretKey(await derive('|response')),
        nonce: nonce,
      );
      final sealed = [...nonce, ...box.cipherText, ...box.mac.bytes];
      expect(utf8.decode((await reply.open(sealed))!), '{"ok":true}');
      // One bit flipped, and it no longer opens.
      final damaged = List<int>.of(sealed)..[20] ^= 1;
      expect(await reply.open(damaged), isNull);
    },
  );

  test('the tunnel headers go only to tunnels', () {
    expect(RelayClient.tunnelHeadersFor('relay.example.org'), isEmpty);
    expect(RelayClient.tunnelHeadersFor('192.0.2.10'), isEmpty);
    expect(RelayClient.tunnelHeadersFor('evilngrok.io'), isEmpty);
    expect(
      RelayClient.tunnelHeadersFor('abc.ngrok-free.app'),
      contains('ngrok-skip-browser-warning'),
    );
    expect(
      RelayClient.tunnelHeadersFor('Abc.loca.lt'),
      contains('bypass-tunnel-reminder'),
    );
  });
}
