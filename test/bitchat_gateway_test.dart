import 'dart:convert';
import 'dart:typed_data';

import 'package:conest/src/bitchat/direct.dart';
import 'package:conest/src/bitchat/gateway.dart';
import 'package:conest/src/bitchat/packet.dart';
import 'package:conest/src/bitchat/geo_relays.g.dart';
import 'package:conest/src/nostr/event.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  var clock = DateTime.utc(2026, 10, 8, 12);
  setUp(() => clock = DateTime.utc(2026, 10, 8, 12));
  final authorKey = Uint8List.fromList(List.generate(32, (i) => i + 1));

  NostrEvent chat(
    String text, {
    String geohash = 'u4pruy',
    int kind = bitchatGeohashEventKind,
    Duration age = Duration.zero,
  }) => NostrEvent.sign(
    secretKey: authorKey,
    kind: kind,
    tags: [
      ['g', geohash],
      ['n', 'iphone'],
    ],
    content: text,
    createdAt: clock.subtract(age).millisecondsSinceEpoch ~/ 1000,
  );

  Uint8List deposit(NostrEvent event, {String geohash = 'u4pruy'}) =>
      BitchatNostrCarrier(
        direction: BitchatCarrierDirection.toGateway,
        geohash: geohash,
        eventJson: Uint8List.fromList(utf8.encode(jsonEncode(event))),
      ).encode();

  test('carriers are coded as bitchat codes them', () {
    final event = chat('hello');
    final encoded = deposit(event);
    // Direction TLV, then geohash, then the event, with 2-byte lengths.
    expect(encoded.sublist(0, 4), [0x01, 0x00, 0x01, 0x01]);
    expect(encoded.sublist(4, 7), [0x02, 0x00, 0x06]);
    expect(utf8.decode(encoded.sublist(7, 13)), 'u4pruy');
    expect(encoded[13], 0x03);
    final decoded = BitchatNostrCarrier.decode(encoded)!;
    expect(decoded.direction, BitchatCarrierDirection.toGateway);
    expect(decoded.geohash, 'u4pruy');
    expect(decoded.event()!.id, event.id);
    // Unknown TLVs are skipped; bad geohashes and bridge directions are not
    // taken.
    expect(
      BitchatNostrCarrier.decode(
        Uint8List.fromList([...encoded, 0x09, 0x00, 0x01, 0x00]),
      ),
      isNotNull,
    );
    final badCell = BitchatNostrCarrier(
      direction: BitchatCarrierDirection.toGateway,
      geohash: 'u4pa',
      eventJson: Uint8List.fromList([1]),
    ).encode();
    expect(BitchatNostrCarrier.decode(badCell), isNull);
    final bridge = Uint8List.fromList(encoded)..[3] = 0x03;
    expect(BitchatNostrCarrier.decode(bridge), isNull);
  });

  test('a cell finds the relays bitchat uses for it', () {
    final relays = BitchatGeoRelays.parse(bitchatBundledGeoRelays)!;
    expect(relays.relays.length, greaterThan(100));
    final (lat, lon) = geohashCenter('u4pruydqqvj');
    expect(lat, closeTo(57.64911, 0.0001));
    expect(lon, closeTo(10.40744, 0.0001));
    final picked = relays.closest('u4pruy');
    expect(picked, hasLength(5));
    expect(picked.every((uri) => uri.scheme == 'wss'), isTrue);
    // Everyone with the same list picks the same relays.
    expect(
      BitchatGeoRelays.parse(bitchatBundledGeoRelays)!.closest('u4pruy'),
      picked,
    );
    expect(BitchatGeoRelays.parse('not,a,list\nx,1,2'), isNull);
    // As bitchat checks a list: no IP addresses or local names, one bad row
    // rejects it all, and most of the known relays must still be there.
    final rows = bitchatBundledGeoRelays.trim().split('\n');
    String withRow(String row) => [...rows, row].join('\n');
    for (final bad in [
      '127.0.0.1:6379,1,1',
      '0x7f.1,1,1',
      '10.0.0.0x1,1,1',
      'localhost,1,1',
      '192.168.1.1:80,1,1',
      'ws://router.local,1,1',
      '[::1]:22,1,1',
      'relay.example.com,91,1',
      'relay.example.com,1',
    ]) {
      expect(BitchatGeoRelays.parse(withRow(bad)), isNull, reason: bad);
    }
    expect(
      BitchatGeoRelays.parse(withRow('relay.example.com:443,1,1')),
      isNotNull,
    );
    final mostlyNew = [
      rows.first,
      for (var i = 0; i < 300; i++) 'relay$i.example.com,1,1',
      ...rows.skip(1).take(50),
    ].join('\n');
    expect(BitchatGeoRelays.parse(mostlyNew), isNotNull);
    expect(BitchatGeoRelays.parse(mostlyNew, baseline: relays), isNull);
  });

  group('gateway', () {
    late List<(String, String)> published;
    late List<Uint8List> broadcasts;
    var online = true;
    BitchatGateway gateway() {
      final gateway = BitchatGateway(
        publish: (event, geohash) async {
          published.add((event.id, geohash));
          return true;
        },
        broadcast: (payload) async {
          // Bluetooth takes a moment, as on a phone.
          await Future<void>.delayed(const Duration(milliseconds: 2));
          broadcasts.add(payload);
        },
        relaysConnected: () => online,
        now: () => clock,
      );
      addTearDown(gateway.close);
      return gateway;
    }

    setUp(() {
      published = [];
      broadcasts = [];
      online = true;
    });

    test('a nearby phone\'s event goes to the relays once', () async {
      final subject = gateway();
      final event = chat('from an iPhone without internet');
      await subject.handleCarrier(
        deposit(event),
        from: 'phone',
        directedToUs: true,
      );
      await subject.handleCarrier(
        deposit(event),
        from: 'phone',
        directedToUs: true,
      );
      expect(published, [(event.id, 'u4pruy')]);
      expect(subject.cells, {'u4pruy'});
      // Not addressed to us: nothing.
      await subject.handleCarrier(
        deposit(chat('elsewhere')),
        from: 'phone',
        directedToUs: false,
      );
      expect(published, hasLength(1));
    });

    test('forged, stale, foreign and off-cell events are refused', () async {
      final subject = gateway();
      final good = chat('good');
      final forged = NostrEvent(
        id: good.id,
        pubkey: good.pubkey,
        createdAt: good.createdAt,
        kind: good.kind,
        tags: good.tags,
        content: 'changed',
        sig: good.sig,
      );
      for (final (event, geohash) in [
        (forged, 'u4pruy'),
        (chat('old', age: const Duration(minutes: 20)), 'u4pruy'),
        (chat('not chat', kind: 1), 'u4pruy'),
        (chat('other cell', geohash: 'u4prux'), 'u4pruy'),
      ]) {
        await subject.handleCarrier(
          deposit(event, geohash: geohash),
          from: 'phone',
          directedToUs: true,
        );
      }
      expect(published, isEmpty);
    });

    test('each phone gets a few deposits a minute', () async {
      final subject = gateway();
      for (var i = 0; i < 15; i++) {
        await subject.handleCarrier(
          deposit(chat('message $i')),
          from: 'phone',
          directedToUs: true,
        );
      }
      expect(
        published,
        hasLength(BitchatGateway.depositsPerMinutePerDepositor),
      );
      await subject.handleCarrier(
        deposit(chat('another phone')),
        from: 'other',
        directedToUs: true,
      );
      expect(published, hasLength(11));
    });

    test('deposits wait while the relays are out of reach', () async {
      final subject = gateway();
      online = false;
      for (var i = 0; i < 7; i++) {
        await subject.handleCarrier(
          deposit(chat('queued $i')),
          from: 'phone',
          directedToUs: true,
        );
      }
      expect(published, isEmpty);
      expect(subject.queued, BitchatGateway.maxQueuedPerDepositor);
      online = true;
      await subject.flushQueued();
      expect(published, hasLength(BitchatGateway.maxQueuedPerDepositor));
    });

    test('relay events come down once, within the airtime budget', () async {
      final subject = gateway();
      final events = [for (var i = 0; i < 35; i++) chat('relay $i')];
      for (final event in events) {
        await subject.relayEvent(event, 'u4pruy');
        await subject.relayEvent(event, 'u4pruy');
      }
      expect(broadcasts, hasLength(BitchatGateway.downlinksPerMinute));
      final first = BitchatNostrCarrier.decode(broadcasts.first)!;
      expect(first.direction, BitchatCarrierDirection.fromGateway);
      expect(first.event()!.id, events.first.id);
      expect(subject.pendingDownlinks, 5);
      clock = clock.add(const Duration(seconds: 61));
      await subject.drainDownlinks();
      expect(broadcasts, hasLength(35));
    });

    test('nothing goes round in circles', () async {
      final subject = gateway();
      // Our own deposit comes back from the relays: not sent down again.
      final mine = chat('deposited here');
      await subject.handleCarrier(
        deposit(mine),
        from: 'phone',
        directedToUs: true,
      );
      await subject.relayEvent(mine, 'u4pruy');
      // Another gateway's downlink: never sent up or down from here.
      final theirs = chat('from another gateway');
      await subject.handleCarrier(
        BitchatNostrCarrier(
          direction: BitchatCarrierDirection.fromGateway,
          geohash: 'u4pruy',
          eventJson: Uint8List.fromList(utf8.encode(jsonEncode(theirs))),
        ).encode(),
        from: 'gateway',
        directedToUs: false,
      );
      await subject.relayEvent(theirs, 'u4pruy');
      await subject.handleCarrier(
        deposit(theirs),
        from: 'phone',
        directedToUs: true,
      );
      expect(broadcasts, isEmpty);
      expect(published, [(mine.id, 'u4pruy')]);
    });

    test('events arriving together still go down once each', () async {
      final subject = gateway();
      final events = [for (var i = 0; i < 40; i++) chat('relay $i')];
      // Every event comes from two relays at the same time.
      await Future.wait([
        for (final event in events) ...[
          subject.relayEvent(event, 'u4pruy'),
          subject.relayEvent(event, 'u4pruy'),
        ],
      ]);
      expect(broadcasts, hasLength(BitchatGateway.downlinksPerMinute));
      final ids = {
        for (final payload in broadcasts)
          BitchatNostrCarrier.decode(payload)!.event()!.id,
      };
      expect(ids, hasLength(broadcasts.length));
    });

    test('deposits and new cells are limited for everyone together', () async {
      final subject = gateway();
      // Many made-up phones, each within its own limit.
      for (var phone = 0; phone < 10; phone++) {
        for (var i = 0; i < 5; i++) {
          await subject.handleCarrier(
            deposit(chat('p$phone m$i')),
            from: 'phone$phone',
            directedToUs: true,
          );
        }
      }
      expect(published, hasLength(BitchatGateway.depositsPerMinute));
      // The phones' cell stays, however many strangers write elsewhere.
      clock = clock.add(const Duration(minutes: 2));
      Future<void> depositIn(String cell, String from) => subject.handleCarrier(
        deposit(chat('in $cell from $from', geohash: cell), geohash: cell),
        from: from,
        directedToUs: true,
      );
      published.clear();
      // One phone gets at most two new cells an hour.
      for (final cell in ['gcpvj0', 'dr5reg', '9q8yyk']) {
        await depositIn(cell, 'roamer');
      }
      expect(subject.cells, {'u4pruy', 'gcpvj0', 'dr5reg'});
      // Nothing is published for a cell this gateway does not carry.
      expect(published.map((p) => p.$2), isNot(contains('9q8yyk')));
      await depositIn('xn76ur', 'other');
      expect(subject.cells, hasLength(BitchatGateway.maxCells));
      // Full, and every cell in use: the next is refused, not swapped in.
      await depositIn('r3gx2f', 'third');
      expect(subject.cells, isNot(contains('r3gx2f')));
      expect(subject.cells, contains('u4pruy'));
      // Later, a cell nobody used for a while makes room, up to six new
      // cells an hour in all.
      clock = clock.add(const Duration(minutes: 15));
      await depositIn('u4pruy', 'phone0');
      for (final (index, cell) in ['r3gx2f', 'u33dc0', 'sv8wrq'].indexed) {
        await depositIn(cell, 'later$index');
      }
      expect(subject.cells, contains('u4pruy'));
      expect(subject.cells, contains('r3gx2f'));
      expect(subject.cells, contains('u33dc0'));
      expect(subject.cells, isNot(contains('sv8wrq')));
    });

    test('a deposit that waited too long is not published', () async {
      final subject = gateway();
      online = false;
      await subject.handleCarrier(
        deposit(chat('soon stale')),
        from: 'phone',
        directedToUs: true,
      );
      clock = clock.add(const Duration(minutes: 20));
      online = true;
      await subject.flushQueued();
      expect(published, isEmpty);
    });

    test('another gateway\'s copy must match its id', () async {
      final subject = gateway();
      final real = chat('real');
      final mismatched = NostrEvent(
        id: real.id,
        pubkey: real.pubkey,
        createdAt: real.createdAt,
        kind: real.kind,
        tags: real.tags,
        content: 'not what the id says',
        sig: real.sig,
      );
      await subject.handleCarrier(
        BitchatNostrCarrier(
          direction: BitchatCarrierDirection.fromGateway,
          geohash: 'u4pruy',
          eventJson: Uint8List.fromList(utf8.encode(jsonEncode(mismatched))),
        ).encode(),
        from: 'gateway',
        directedToUs: false,
      );
      // So it cannot keep the real event from being passed on.
      await subject.relayEvent(real, 'u4pruy');
      expect(broadcasts, hasLength(1));
    });
  });

  test('a gateway says so in its announce, still never compressed', () async {
    final alice =
        await BitchatDirect.create(
            nickname: 'a nickname long enough to need cutting',
            noiseSeed: List.filled(32, 1),
            signingSeed: List.filled(32, 101),
            now: () => clock,
          )
          ..capabilities = bitchatGatewayCapability;
    final announce = await alice.announce();
    expect(announce.payload.length, lessThan(bitchatCompressionThreshold));
    final decoded = BitchatAnnouncement.decode(announce.payload)!;
    expect(decoded.capabilities, bitchatGatewayCapability);
    // bitchat's encoding: little-endian, trailing zero bytes dropped.
    expect(announce.payload.sublist(announce.payload.length - 3), [
      0x05,
      0x01,
      0x04,
    ]);
  });
}
