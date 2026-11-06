import 'dart:io';

import 'package:conest/src/models.dart';
import 'package:conest/src/net/iroh_hint_book.dart';
import 'package:flutter_test/flutter_test.dart';

PeerEndpoint stored(String host, int port, {PeerRouteProtocol? protocol}) =>
    PeerEndpoint(
      kind: PeerRouteKind.directInternet,
      host: host,
      port: port,
      protocol: protocol ?? PeerRouteProtocol.udp,
    );

void main() {
  late DateTime now;
  late IrohHintBook book;

  setUp(() {
    now = DateTime.utc(2026, 11, 6, 12);
    book = IrohHintBook(now: () => now);
  });

  FreshHost fresh(String host, {int secondsAgo = 0}) =>
      FreshHost(host, now.subtract(Duration(seconds: secondsAgo)));

  group('LinkPorts', () {
    test('parses only sane ports and versions', () {
      final ports = LinkPorts.tryParse({
        'iroh4': 4000,
        'iroh6': 70000,
        'direct': 7667,
        'binary': 1,
      });
      expect(ports!.iroh4, 4000);
      expect(ports.iroh6, isNull);
      expect(ports.direct, 7667);
      expect(ports.binary, 1);
      expect(LinkPorts.tryParse('nope'), isNull);
      expect(LinkPorts.tryParse({'iroh4': 'x'}), isNull);
      expect(LinkPorts.tryParse({'binary': 7})?.binary, isNull);
    });
  });

  group('hintsFor', () {
    test(
      'no fresh data gives exactly the stored hints, udp only, in order',
      () {
        final hints = book.hintsFor(
          deviceId: 'dev-a',
          storedDirect: [
            stored('203.0.113.9', 5000),
            stored('203.0.113.9', 5001, protocol: PeerRouteProtocol.tcp),
            stored('2001:db8::1', 5002),
          ],
          fresh: const [],
        );
        expect(hints, ['203.0.113.9:5000', '[2001:db8::1]:5002']);
      },
    );

    test('fresh hosts come first, newest first, with the peer\'s port', () {
      book.notePorts('dev-a', const LinkPorts(iroh4: 41000));
      final hints = book.hintsFor(
        deviceId: 'dev-a',
        storedDirect: [stored('203.0.113.9', 5000)],
        fresh: [
          fresh('169.254.1.2', secondsAgo: 30),
          fresh('192.168.42.2', secondsAgo: 5),
        ],
      );
      expect(hints, [
        '192.168.42.2:41000',
        '169.254.1.2:41000',
        '203.0.113.9:5000',
      ]);
    });

    test('the total is 8: stored 4 + fresh 4, and stored 2 + fresh 6', () {
      book.notePorts('dev-a', const LinkPorts(iroh4: 41000));
      final many = [
        for (var i = 1; i <= 10; i++) fresh('169.254.1.$i', secondsAgo: i),
      ];
      final four = book.hintsFor(
        deviceId: 'dev-a',
        storedDirect: [
          for (var i = 0; i < 4; i++) stored('203.0.113.$i', 5000),
        ],
        fresh: many,
      );
      expect(four, hasLength(8));
      expect(four.take(4).every((h) => h.startsWith('169.254.')), isTrue);
      expect(four.skip(4).every((h) => h.startsWith('203.0.113.')), isTrue);
      final two = book.hintsFor(
        deviceId: 'dev-a',
        storedDirect: [
          for (var i = 0; i < 2; i++) stored('203.0.113.$i', 5000),
        ],
        fresh: many,
      );
      expect(two, hasLength(8));
      expect(two.take(6).every((h) => h.startsWith('169.254.')), isTrue);
    });

    test('fresh hosts never push stored ones past the 4 kept', () {
      book.notePorts('dev-a', const LinkPorts(iroh4: 41000));
      final hints = book.hintsFor(
        deviceId: 'dev-a',
        storedDirect: [
          for (var i = 0; i < 6; i++) stored('203.0.113.$i', 5000),
        ],
        fresh: [for (var i = 1; i <= 10; i++) fresh('169.254.1.$i')],
      );
      expect(hints, hasLength(8));
      expect(hints.where((h) => h.startsWith('203.0.113.')), hasLength(4));
    });

    test('a fresh host that is also stored is not listed twice', () {
      book.notePorts('dev-a', const LinkPorts(iroh4: 5000));
      final hints = book.hintsFor(
        deviceId: 'dev-a',
        storedDirect: [stored('192.168.42.2', 5000)],
        fresh: [fresh('192.168.42.2')],
      );
      expect(hints, ['192.168.42.2:5000']);
    });

    test('without the peer\'s ports the port of a stored hint of that family '
        'is used; with neither the host is skipped, never guessed', () {
      final withStored = book.hintsFor(
        deviceId: 'dev-a',
        storedDirect: [stored('203.0.113.9', 5000)],
        fresh: [fresh('169.254.1.2')],
      );
      expect(withStored.first, '169.254.1.2:5000');
      final neither = book.hintsFor(
        deviceId: 'dev-b',
        storedDirect: const [],
        fresh: [fresh('169.254.1.2')],
      );
      expect(neither, isEmpty);
    });

    test('a v6 host uses the v6 port and is bracketed', () {
      book.notePorts('dev-a', const LinkPorts(iroh4: 41000, iroh6: 42000));
      final hints = book.hintsFor(
        deviceId: 'dev-a',
        storedDirect: const [],
        fresh: [fresh('fd00::5')],
      );
      expect(hints, ['[fd00::5]:42000']);
    });

    test('entries that cannot be written for Rust are dropped: a zone name, '
        'a non-address, a bad port', () {
      book.notePorts('dev-a', const LinkPorts(iroh4: 41000));
      final hints = book.hintsFor(
        deviceId: 'dev-a',
        storedDirect: [stored('fe80::1%usb0', 5000), stored('not-an-ip', 5000)],
        fresh: [fresh('relay.example'), fresh('fe80::2%usb0')],
      );
      expect(hints, isEmpty);
    });

    test('a zone name that exists on this machine is still dropped: Rust '
        'reads a numeric zone only', () async {
      final interfaces = await NetworkInterface.list(includeLoopback: true);
      final name = interfaces
          .map((interface) => interface.name)
          .firstWhere(
            (name) => InternetAddress.tryParse('fe80::1%$name') != null,
            orElse: () => '',
          );
      if (name.isEmpty) return;
      book.notePorts('dev-a', const LinkPorts(iroh6: 42000));
      final hints = book.hintsFor(
        deviceId: 'dev-a',
        storedDirect: const [],
        fresh: [fresh('fe80::2%$name')],
      );
      expect(hints, isEmpty);
    });

    test('a numeric zone is kept, as Rust reads it', () {
      book.notePorts('dev-a', const LinkPorts(iroh6: 42000));
      final hints = book.hintsFor(
        deviceId: 'dev-a',
        storedDirect: const [],
        fresh: [fresh('fe80::2%3')],
      );
      expect(hints, ['[fe80::2%3]:42000']);
    });
  });

  group('ports', () {
    test('new ports replace the old ones; reset clears', () {
      book.notePorts('dev-a', const LinkPorts(iroh4: 1000));
      book.notePorts('dev-a', const LinkPorts(iroh4: 2000));
      expect(book.portsFor('dev-a')!.iroh4, 2000);
      book.clear();
      expect(book.portsFor('dev-a'), isNull);
    });

    test('at most 64 peers are kept; the longest unheard goes', () {
      for (var i = 0; i < 70; i++) {
        book.notePorts('dev-$i', LinkPorts(iroh4: 1000 + i));
        now = now.add(const Duration(seconds: 1));
      }
      expect(book.peerCount, 64);
      expect(book.portsFor('dev-0'), isNull);
      expect(book.portsFor('dev-69'), isNotNull);
    });

    test('ports expire after an hour unheard, by the injected clock', () {
      book.notePorts('dev-a', const LinkPorts(iroh4: 1000));
      now = now.add(const Duration(minutes: 61));
      expect(book.portsFor('dev-a'), isNull);
    });
  });
}
