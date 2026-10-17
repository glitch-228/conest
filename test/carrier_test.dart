import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:conest/src/carrier.dart';
import 'package:conest/src/matrix_carrier.dart';
import 'package:conest/src/models.dart';
import 'package:conest/src/transport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Uint8List pattern(int length) =>
      Uint8List.fromList(List<int>.generate(length, (index) => index % 251));

  group('framing', () {
    test('Matrix frames keep their exact JSON form', () {
      final sealed = pattern(100 * 1024);
      final frames = matrixCarrierFrames('env-1', sealed);
      expect(frames, hasLength(3));
      for (var index = 0; index < 3; index++) {
        final end = min((index + 1) * 40 * 1024, sealed.length);
        expect(
          jsonEncode(frames[index]),
          '{"v":1,"id":"env-1","i":$index,"n":3,"d":'
          '"${base64Encode(sealed.sublist(index * 40 * 1024, end))}"}',
        );
      }
    });

    test('binary frames split and reassemble in any order', () {
      final sealed = pattern(60 * 1024);
      final frames = carrierBinaryFrames(CarrierFraming.nostr, sealed);
      expect(frames, hasLength(3));
      for (final frame in frames) {
        expect(
          frame.length,
          lessThanOrEqualTo(
            CarrierFraming.nostr.chunkBytes + carrierBinaryFrameHeaderBytes,
          ),
        );
        expect(frame[0], carrierBinaryFrameVersion);
      }
      final reassembler = CarrierReassembler(framing: CarrierFraming.nostr);
      Uint8List? result;
      for (final frame in frames.reversed) {
        result = reassembler.addBinary('npub-a', frame);
      }
      expect(result, sealed);
    });

    test('each envelope gets its own frame id', () {
      final sealed = pattern(30 * 1024);
      final first = carrierBinaryFrames(CarrierFraming.nostr, sealed);
      final second = carrierBinaryFrames(CarrierFraming.nostr, sealed);
      expect(first.first.sublist(1, 9), isNot(second.first.sublist(1, 9)));
    });

    test('envelopes over the limit are refused', () {
      for (final framing in [
        CarrierFraming.matrix,
        CarrierFraming.nostr,
        CarrierFraming.email,
        CarrierFraming.bitchat,
      ]) {
        expect(
          () => carrierBinaryFrames(
            framing,
            Uint8List(framing.maxSealedBytes + 1),
          ),
          throwsArgumentError,
        );
        expect(
          carrierBinaryFrames(framing, Uint8List(framing.maxSealedBytes)),
          hasLength(framing.maxFrames),
        );
      }
    });

    test('malformed binary frames are rejected', () {
      final reassembler = CarrierReassembler(framing: CarrierFraming.nostr);
      final id = List<int>.filled(8, 7);
      for (final frame in <List<int>>[
        [],
        [1, ...id, 0, 1],
        [2, ...id, 0, 1, 9],
        [1, ...id, 1, 1, 9],
        [1, ...id, 0, 0, 9],
        // More frames than the largest Nostr envelope needs.
        [1, ...id, 0, CarrierFraming.nostr.maxFrames + 1, 9],
        // A chunk larger than the framing allows.
        [1, ...id, 0, 1, ...List<int>.filled(24 * 1024 + 1, 9)],
      ]) {
        expect(reassembler.addBinary('s', Uint8List.fromList(frame)), isNull);
      }
    });

    test('one sender can only displace its own partial envelopes', () {
      final reassembler = CarrierReassembler(
        framing: CarrierFraming.nostr,
        maxPending: 4,
        maxPendingPerSender: 2,
      );
      List<Uint8List> twoFrames() =>
          carrierBinaryFrames(CarrierFraming.nostr, pattern(30 * 1024));
      final honest = twoFrames();
      expect(reassembler.addBinary('honest', honest.first), isNull);
      for (var flood = 0; flood < 10; flood++) {
        expect(reassembler.addBinary('flooder', twoFrames().first), isNull);
      }
      expect(reassembler.addBinary('honest', honest.last), isNotNull);
    });

    test(
      'a frame of one sender cannot complete another sender\'s envelope',
      () {
        final reassembler = CarrierReassembler(framing: CarrierFraming.nostr);
        final frames = carrierBinaryFrames(
          CarrierFraming.nostr,
          pattern(30 * 1024),
        );
        expect(reassembler.addBinary('a', frames.first), isNull);
        expect(reassembler.addBinary('b', frames.last), isNull);
      },
    );

    test('partial envelopes expire', () {
      var now = DateTime.utc(2026, 10, 4);
      final reassembler = CarrierReassembler(
        framing: CarrierFraming.nostr,
        now: () => now,
      );
      final frames = carrierBinaryFrames(
        CarrierFraming.nostr,
        pattern(30 * 1024),
      );
      expect(reassembler.addBinary('a', frames.first), isNull);
      now = now.add(const Duration(minutes: 11));
      // A fresh entry after expiry: the old first frame is gone.
      expect(reassembler.addBinary('a', frames.last), isNull);
    });
  });

  group('adapter', () {
    late _XorSealer sealer;
    late CarrierTransportAdapter adapter;
    late _RecordingChannel channel;

    setUp(() {
      sealer = _XorSealer();
      channel = _RecordingChannel('npub-me|wss://relay.one');
      adapter = CarrierTransportAdapter(
        kind: TransportKind.nostr,
        sealer: sealer,
        framing: CarrierFraming.nostr,
      )..attach(channel);
    });

    const peer = TransportPeer(
      deviceId: 'dev-bob',
      transportAddresses: {TransportKind.nostr: 'npub-bob|wss://relay.two'},
    );

    test(
      'offers a route only with a ready channel and a peer address',
      () async {
        final routes = await adapter.discoverRoutes(peer);
        expect(routes.single.transport, TransportKind.nostr);
        expect(routes.single.path, TransportPathKind.storeForward);
        expect(routes.single.label, 'Nostr (fake relays)');
        expect(
          await adapter.discoverRoutes(const TransportPeer(deviceId: 'x')),
          isEmpty,
        );
        expect(
          await adapter.discoverRoutes(
            const TransportPeer(
              deviceId: 'x',
              transportAddresses: {TransportKind.nostr: 'bad\naddress'},
            ),
          ),
          isEmpty,
        );
        await adapter.detach();
        expect(await adapter.discoverRoutes(peer), isEmpty);
      },
    );

    test('sends sealed frames and receives them back', () async {
      await adapter.start();
      final inbound = adapter.inboundEnvelopes.first;
      final route = (await adapter.discoverRoutes(peer)).single;
      final envelope = pattern(50 * 1024);
      final receipt = await adapter.sendEnvelope(
        peer: peer,
        route: route,
        envelope: TransportEnvelope(
          id: 'm1',
          recipientDeviceId: 'dev-bob',
          bytes: envelope,
          createdAt: DateTime.utc(2026, 10, 4),
        ),
      );
      expect(receipt.state, DeliveryReceiptState.storedForPeer);
      expect(channel.sent, hasLength(3));
      expect(
        channel.sent.every((s) => s.$1 == 'npub-bob|wss://relay.two'),
        isTrue,
      );
      for (final (_, frame) in channel.sent) {
        adapter.receiveFrame('npub-bob', frame);
      }
      final received = await inbound.timeout(const Duration(seconds: 2));
      expect(received.transport, TransportKind.nostr);
      expect(received.senderTransportIdentity, 'dev-bob');
      expect(received.bytes, envelope);
    });

    test('frames received while stopped wait for the start', () async {
      final sealed = await sealer.seal(
        TransportKind.nostr,
        'dev-bob',
        pattern(10),
      );
      final frame = carrierBinaryFrames(CarrierFraming.nostr, sealed).single;
      adapter.receiveFrame('npub-bob', frame);
      final inbound = adapter.inboundEnvelopes.first;
      await adapter.start();
      expect(
        (await inbound.timeout(const Duration(seconds: 2))).bytes,
        pattern(10),
      );
    });

    test('frames from senders the sealer refuses are not buffered', () async {
      await adapter.start();
      sealer.accepted = false;
      final frames = carrierBinaryFrames(
        CarrierFraming.nostr,
        await sealer.seal(TransportKind.nostr, 'dev-bob', pattern(30 * 1024)),
      );
      var received = false;
      final subscription = adapter.inboundEnvelopes.listen(
        (_) => received = true,
      );
      for (final frame in frames) {
        adapter.receiveFrame('npub-stranger', frame);
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await subscription.cancel();
      expect(received, isFalse);
      expect(sealer.opened, 0);
    });

    test(
      'a first request goes to the inbox under one sender id, alone',
      () async {
        // Two envelopes to one address at once: the first request (sealed for
        // the inbox) and another; the choice is per envelope, not per address.
        final inboxSealer = _InboxSealer();
        final mesh = _InboxChannel('bc1:me');
        final adapter = CarrierTransportAdapter(
          kind: TransportKind.nostr,
          sealer: inboxSealer,
          framing: CarrierFraming.nostr,
          frameSpacing: const Duration(milliseconds: 5),
        )..attach(mesh);
        await adapter.start();
        final route = (await adapter.discoverRoutes(peer)).single;
        Future<void> send(String id, int size) => adapter.sendEnvelope(
          peer: peer,
          route: route,
          envelope: TransportEnvelope(
            id: id,
            recipientDeviceId: 'dev-bob',
            bytes: pattern(size),
            createdAt: DateTime.utc(2026),
          ),
        );
        inboxSealer.inboxSizes.add(40 * 1024);
        await Future.wait([
          send('request', 40 * 1024),
          send('other', 30 * 1024),
        ]);
        expect(mesh.inbox.length, greaterThan(1));
        expect(mesh.inbox.map((frame) => frame.$3).toSet(), hasLength(1));
        expect(mesh.plain, isNotEmpty);
        // Every request frame by the inbox, none of the other envelope's.
        final inboxBytes = mesh.inbox.fold<int>(0, (n, f) => n + f.$2.length);
        final plainBytes = mesh.plain.fold<int>(0, (n, f) => n + f.$2.length);
        expect(inboxBytes, greaterThan(40 * 1024));
        expect(plainBytes, lessThan(inboxBytes));
      },
    );

    test('stopping mid-envelope sends no further frames', () async {
      final slow = CarrierTransportAdapter(
        kind: TransportKind.nostr,
        sealer: sealer,
        framing: CarrierFraming.nostr,
        frameSpacing: const Duration(milliseconds: 100),
      )..attach(channel);
      await slow.start();
      final route = (await slow.discoverRoutes(peer)).single;
      final sending = slow.sendEnvelope(
        peer: peer,
        route: route,
        envelope: TransportEnvelope(
          id: 'm',
          recipientDeviceId: 'dev-bob',
          bytes: pattern(100 * 1024),
          createdAt: DateTime.utc(2026),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await slow.stop();
      await expectLater(sending, throwsStateError);
      expect(channel.sent.length, lessThan(5));
    });

    test('a radio receipt comes once every frame is confirmed', () async {
      final radio = _AckingChannel('npub-me|wss://relay.one');
      final tracked = CarrierTransportAdapter(
        kind: TransportKind.nostr,
        sealer: sealer,
        framing: CarrierFraming.nostr,
      )..attach(radio);
      await tracked.start();
      final receipts = <CarrierDeliveryReceipt>[];
      final subscription = tracked.deliveryReceipts.listen(receipts.add);
      addTearDown(subscription.cancel);
      final route = (await tracked.discoverRoutes(peer)).single;
      Future<void> send(String id) => tracked.sendEnvelope(
        peer: peer,
        route: route,
        envelope: TransportEnvelope(
          id: id,
          recipientDeviceId: 'dev-bob',
          bytes: pattern(50 * 1024),
          createdAt: DateTime.utc(2026),
        ),
      );
      await send('m1');
      final frames = List.of(radio.sentIds);
      expect(frames.length, greaterThan(1));
      for (final id in frames.take(frames.length - 1)) {
        radio.ack(id);
      }
      await Future<void>.delayed(Duration.zero);
      expect(receipts, isEmpty, reason: 'one frame still unconfirmed');
      radio.ack(frames.last);
      await Future<void>.delayed(Duration.zero);
      expect(receipts.single.envelopeId, 'm1');
      expect(receipts.single.deviceId, 'dev-bob');

      // A refused frame never makes a receipt.
      radio.sentIds.clear();
      await send('m2');
      for (final id in radio.sentIds) {
        radio.ack(id, ok: id != radio.sentIds.first);
      }
      await Future<void>.delayed(Duration.zero);
      expect(receipts.length, 1);
    });

    test('a cancelled send puts no more frames on air', () async {
      final slow = CarrierTransportAdapter(
        kind: TransportKind.nostr,
        sealer: sealer,
        framing: CarrierFraming.nostr,
        frameSpacing: const Duration(milliseconds: 100),
      )..attach(channel);
      await slow.start();
      final route = (await slow.discoverRoutes(peer)).single;
      final sending = slow.sendEnvelope(
        peer: peer,
        route: route,
        envelope: TransportEnvelope(
          id: 'm',
          recipientDeviceId: 'dev-bob',
          bytes: pattern(100 * 1024),
          createdAt: DateTime.utc(2026),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 150));
      // Its receipt came by another route.
      await slow.cancel(carrierSendId('dev-bob', 'm'));
      await expectLater(sending, throwsA(isA<TransportSendCancelled>()));
      expect(channel.sent.length, lessThan(4));
      // Another device's copy of the same message still goes.
      channel.sent.clear();
      await slow.cancel(carrierSendId('dev-carol', 'm2'));
      await slow.sendEnvelope(
        peer: peer,
        route: route,
        envelope: TransportEnvelope(
          id: 'm2',
          recipientDeviceId: 'dev-bob',
          bytes: pattern(1024),
          createdAt: DateTime.utc(2026),
        ),
      );
      expect(channel.sent, isNotEmpty);
      // A send of the stopped message started later still goes.
      channel.sent.clear();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await slow.sendEnvelope(
        peer: peer,
        route: route,
        envelope: TransportEnvelope(
          id: 'm',
          recipientDeviceId: 'dev-bob',
          bytes: pattern(1024),
          createdAt: DateTime.utc(2026),
        ),
      );
      expect(channel.sent, isNotEmpty);
    });

    test(
      'confirmations of early frames count while later ones go out',
      () async {
        final radio = _AckingChannel(
          'npub-me|wss://relay.one',
          ackAtOnce: true,
        );
        final tracked = CarrierTransportAdapter(
          kind: TransportKind.nostr,
          sealer: sealer,
          framing: CarrierFraming.nostr,
          frameSpacing: const Duration(milliseconds: 20),
        )..attach(radio);
        await tracked.start();
        final receipts = <CarrierDeliveryReceipt>[];
        final subscription = tracked.deliveryReceipts.listen(receipts.add);
        addTearDown(subscription.cancel);
        final route = (await tracked.discoverRoutes(peer)).single;
        await tracked.sendEnvelope(
          peer: peer,
          route: route,
          envelope: TransportEnvelope(
            id: 'early',
            recipientDeviceId: 'dev-bob',
            bytes: pattern(50 * 1024),
            createdAt: DateTime.utc(2026),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(radio.sentIds.length, greaterThan(1));
        expect(receipts.single.envelopeId, 'early');
      },
    );

    test('a channel that does not confirm frames makes no receipts', () async {
      await adapter.start();
      final receipts = <CarrierDeliveryReceipt>[];
      final subscription = adapter.deliveryReceipts.listen(receipts.add);
      addTearDown(subscription.cancel);
      await adapter.sendEnvelope(
        peer: peer,
        route: (await adapter.discoverRoutes(peer)).single,
        envelope: TransportEnvelope(
          id: 'plain',
          recipientDeviceId: 'dev-bob',
          bytes: pattern(1024),
          createdAt: DateTime.utc(2026),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(receipts, isEmpty);
    });

    test('file streams are refused', () async {
      final route = (await adapter.discoverRoutes(peer)).single;
      final receipt = await adapter.sendAttachmentRange(
        peer: peer,
        route: route,
        range: AttachmentRange(
          attachmentId: 'a',
          offset: 0,
          bytes: Uint8List(1),
          sha256Base64: '',
        ),
      );
      expect(receipt.accepted, isFalse);
    });

    test('the sender identity is the part before the first bar', () {
      expect(carrierSenderIdentity('npub|wss://a,wss://b'), 'npub');
      expect(carrierSenderIdentity('alone'), 'alone');
    });
  });

  group('registry', () {
    test('routes of equal policy and path are ordered by rank', () async {
      final registry = TransportRegistry([
        _StaticAdapter(TransportKind.deltaChat),
        _StaticAdapter(TransportKind.nostr),
        _StaticAdapter(TransportKind.matrix),
      ]);
      final routes = await registry.routesFor(
        const TransportPeer(deviceId: 'x'),
        policies: defaultTransportPolicies(),
      );
      expect(routes.map((route) => route.transport), [
        TransportKind.matrix,
        TransportKind.nostr,
        TransportKind.deltaChat,
      ]);
    });

    test('a slow carrier gets its own attempt timeout', () async {
      final slow = _StaticAdapter(
        TransportKind.nostr,
        delay: const Duration(milliseconds: 300),
        timeout: const Duration(seconds: 5),
      );
      final registry = TransportRegistry([slow]);
      final result = await registry.deliverEnvelope(
        peer: const TransportPeer(deviceId: 'x'),
        policies: defaultTransportPolicies(),
        envelope: TransportEnvelope(
          id: 'm',
          recipientDeviceId: 'x',
          bytes: Uint8List(1),
          createdAt: DateTime.utc(2026),
        ),
      );
      expect(result.receipt.accepted, isTrue);
    });

    test('without one, a slow send falls back after four seconds', () async {
      final slow = _StaticAdapter(
        TransportKind.nostr,
        delay: const Duration(seconds: 6),
      );
      final registry = TransportRegistry([slow]);
      await expectLater(
        registry.deliverEnvelope(
          peer: const TransportPeer(deviceId: 'x'),
          policies: defaultTransportPolicies(),
          envelope: TransportEnvelope(
            id: 'm',
            recipientDeviceId: 'x',
            bytes: Uint8List(1),
            createdAt: DateTime.utc(2026),
          ),
        ),
        throwsStateError,
      );
    });
  });

  group('kinds and policies', () {
    test('Online gates internet carriers only', () {
      const global = GlobalConnectivityPreferences(onlineEnabled: false);
      for (final kind in [
        TransportKind.nostr,
        TransportKind.deltaChat,
        TransportKind.tor,
        TransportKind.matrix,
      ]) {
        expect(
          global.policyFor(kind),
          TransportPolicy.disabled,
          reason: '$kind',
        );
      }
      for (final kind in [
        TransportKind.reticulum,
        TransportKind.meshtastic,
        TransportKind.meshCore,
        TransportKind.bitchat,
      ]) {
        expect(
          global.policyFor(kind),
          TransportPolicy.automatic,
          reason: '$kind',
        );
      }
    });

    test('only bulk transports carry file chunks', () {
      expect(
        TransportKind.values.where((kind) => kind.carriesBulk),
        unorderedEquals([
          TransportKind.lan,
          TransportKind.iroh,
          TransportKind.conestRelay,
          TransportKind.optical,
          TransportKind.localSend,
          TransportKind.tor,
        ]),
      );
    });

    test('each carrier has a route mark', () {
      for (final kind in TransportKind.values.where((k) => k.isCarrier)) {
        final route = MessageRoute.forCarrier(kind);
        expect(route, isNotNull, reason: '$kind');
        expect(route!.carrierKind, kind);
        expect(MessageRoute.fromTransport(kind, null), route);
      }
      expect(MessageRoute.plainMatrix.carrierKind, TransportKind.matrix);
      expect(MessageRoute.irohDirect.carrierKind, isNull);
    });

    test('Email and Reticulum placeholders saved as disabled are reset', () {
      final saved = {
        'transportPolicies': {
          'deltaChat': 'disabled',
          'reticulum': 'disabled',
          'iroh': 'preferred',
        },
      };
      final old = ContactRoutingPreferences.fromJson(saved);
      expect(old.policyFor(TransportKind.deltaChat), TransportPolicy.automatic);
      expect(old.policyFor(TransportKind.reticulum), TransportPolicy.automatic);
      expect(old.policyFor(TransportKind.iroh), TransportPolicy.preferred);
      expect(old.policyFor(TransportKind.nostr), TransportPolicy.automatic);
      final global = GlobalConnectivityPreferences.fromJson(saved);
      expect(
        global.policyFor(TransportKind.deltaChat),
        TransportPolicy.automatic,
      );

      // A choice saved after the reset is kept.
      final chosen = ContactRoutingPreferences.fromJson(
        jsonDecode(
              jsonEncode(
                old
                    .copyWith(
                      transportPolicies: {
                        ...old.transportPolicies,
                        TransportKind.deltaChat: TransportPolicy.disabled,
                      },
                    )
                    .toJson(),
              ),
            )
            as Map<String, dynamic>,
      );
      expect(
        chosen.policyFor(TransportKind.deltaChat),
        TransportPolicy.disabled,
      );
    });
  });

  group('carrier addresses', () {
    final t1 = DateTime.utc(2026, 10, 4, 10);
    final t2 = DateTime.utc(2026, 10, 4, 11);
    final t3 = DateTime.utc(2026, 10, 4, 12);

    test('a newer exchange sets and clears, an older one is ignored', () {
      final set = mergeCarrierAddresses(const {}, {
        TransportKind.nostr: 'npub-a',
      }, at: t2)!;
      expect(set[TransportKind.nostr]!.value, 'npub-a');
      expect(
        mergeCarrierAddresses(set, const {}, at: t1),
        isNull,
        reason: 'a late older exchange cannot clear it',
      );
      final cleared = mergeCarrierAddresses(set, const {}, at: t3)!;
      expect(cleared[TransportKind.nostr]!.value, isNull);
      expect(
        mergeCarrierAddresses(cleared, {TransportKind.nostr: 'npub-a'}, at: t2),
        isNull,
        reason: 'a late older exchange cannot restore it',
      );
    });

    test('an unchanged address takes the newer time', () {
      final set = mergeCarrierAddresses(const {}, {
        TransportKind.nostr: 'npub-a',
      }, at: t1)!;
      final again = mergeCarrierAddresses(set, {
        TransportKind.nostr: 'npub-a',
      }, at: t3)!;
      expect(again[TransportKind.nostr]!.at, t3);
      expect(mergeCarrierAddresses(again, const {}, at: t2), isNull);
    });

    test('Matrix is left to its own field', () {
      expect(
        mergeCarrierAddresses(const {}, {
          TransportKind.matrix: '@a:b|DEV',
        }, at: t1),
        isNull,
      );
    });

    test('contact records keep carrier addresses across a save', () {
      final contact = ContactRecord(
        accountId: 'acct',
        deviceId: 'dev',
        alias: 'Bob',
        displayName: 'Bob',
        bio: '',
        relayCapable: false,
        publicKeyBase64: 'key',
        routeHints: const [],
        safetyNumber: '1',
        trustedAt: t1,
        matrixAddress: '@bob:fake.test|CONEST_bob',
        carrierAddresses: {
          TransportKind.nostr: CarrierAddress(value: 'npub-b|wss://r', at: t2),
          TransportKind.deltaChat: CarrierAddress(value: null, at: t3),
        },
      );
      final restored = ContactRecord.fromJson(
        jsonDecode(jsonEncode(contact.toJson())) as Map<String, dynamic>,
      );
      expect(restored.carrierAddress(TransportKind.nostr), 'npub-b|wss://r');
      expect(restored.carrierAddresses[TransportKind.nostr]!.at, t2);
      expect(restored.carrierAddress(TransportKind.deltaChat), isNull);
      expect(restored.carrierAddresses[TransportKind.deltaChat]!.at, t3);
      expect(
        restored.carrierAddress(TransportKind.matrix),
        '@bob:fake.test|CONEST_bob',
      );
    });
  });
}

/// Test sealer: XORs with a constant and names the peer `dev-bob`.
class _XorSealer implements CarrierSealer {
  bool accepted = true;
  int opened = 0;

  @override
  bool acceptsSender(TransportKind kind, String sender) => accepted;

  @override
  Future<Uint8List> seal(
    TransportKind kind,
    String peerDeviceId,
    Uint8List envelope,
  ) async => Uint8List.fromList([for (final byte in envelope) byte ^ 0x5a]);

  @override
  Future<({String peerDeviceId, Uint8List envelope})?> open(
    TransportKind kind,
    String sender,
    Uint8List sealed,
  ) async {
    opened++;
    return (
      peerDeviceId: 'dev-bob',
      envelope: Uint8List.fromList([for (final byte in sealed) byte ^ 0x5a]),
    );
  }
}

class _AckingChannel implements AcknowledgingCarrierChannel {
  _AckingChannel(this.localAddress, {this.ackAtOnce = false});

  /// The far radio confirms each frame as soon as it is sent.
  final bool ackAtOnce;

  final List<int> sentIds = [];
  final _acks = StreamController<({int frameId, bool ok})>.broadcast();
  var _next = 100;

  @override
  final String localAddress;

  @override
  String get routeLabel => 'fake radio';

  @override
  Future<void> sendFrame(String address, Uint8List frame) =>
      sendTrackedFrame(address, frame);

  @override
  Future<int> sendTrackedFrame(String address, Uint8List frame) async {
    final id = _next++;
    sentIds.add(id);
    if (ackAtOnce) scheduleMicrotask(() => ack(id));
    return id;
  }

  @override
  Stream<({int frameId, bool ok})> get frameAcks => _acks.stream;

  void ack(int id, {bool ok = true}) => _acks.add((frameId: id, ok: ok));
}

class _RecordingChannel implements CarrierChannel {
  _RecordingChannel(this.localAddress);

  final List<(String, Uint8List)> sent = [];

  @override
  final String localAddress;

  @override
  String get routeLabel => 'fake relays';

  @override
  Future<void> sendFrame(String address, Uint8List frame) async =>
      sent.add((address, frame));
}

/// Always offers one store-and-forward route and accepts after [delay].
class _StaticAdapter implements TransportAdapter {
  _StaticAdapter(this.kind, {this.delay = Duration.zero, this.timeout});

  @override
  final TransportKind kind;
  final Duration delay;
  final Duration? timeout;

  @override
  TransportCapabilities get capabilities => TransportCapabilities(
    requiresPeerOnline: false,
    supportsStoreForward: true,
    duplex: true,
    requiresUserAction: false,
    supportsAttachmentStreaming: false,
    reportsPath: true,
    sendAttemptTimeout: timeout,
  );

  RouteCandidate get _route => RouteCandidate(
    transport: kind,
    path: TransportPathKind.storeForward,
    routeId: kind.name,
    label: kind.label,
    trust: TransportTrustState.pinnedTransport,
  );

  @override
  Future<List<RouteCandidate>> discoverRoutes(TransportPeer peer) async => [
    _route,
  ];

  @override
  Future<DeliveryReceipt> sendEnvelope({
    required TransportPeer peer,
    required RouteCandidate route,
    required TransportEnvelope envelope,
  }) async {
    await Future<void>.delayed(delay);
    return DeliveryReceipt(
      state: DeliveryReceiptState.storedForPeer,
      route: route,
      at: DateTime.now().toUtc(),
    );
  }

  @override
  Future<DeliveryReceipt> sendAttachmentRange({
    required TransportPeer peer,
    required RouteCandidate route,
    required AttachmentRange range,
  }) async => throw UnimplementedError();

  @override
  Future<void> cancel(String operationId) async {}

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}

  @override
  Stream<RouteCandidate> get pathChanges => const Stream.empty();

  @override
  Stream<TransportInboundEnvelope> get inboundEnvelopes => const Stream.empty();
}

/// Seals by XOR; envelopes of the sizes in [inboxSizes] are first requests.
class _InboxSealer extends _XorSealer implements InboxCarrierSealer {
  final Set<int> inboxSizes = {};
  final Expando<bool> _marked = Expando();

  @override
  Future<Uint8List> seal(
    TransportKind kind,
    String peerDeviceId,
    Uint8List envelope,
  ) async {
    final sealed = await super.seal(kind, peerDeviceId, envelope);
    if (inboxSizes.contains(envelope.length)) _marked[sealed] = true;
    return sealed;
  }

  @override
  bool sealedForInbox(Uint8List sealed) => _marked[sealed] == true;
}

class _InboxChannel implements InboxCarrierChannel {
  _InboxChannel(this.localAddress);

  final List<(String, Uint8List)> plain = [];
  final List<(String, Uint8List, String)> inbox = [];

  @override
  final String localAddress;

  @override
  String get routeLabel => 'fake mesh';

  @override
  Future<void> sendFrame(String address, Uint8List frame) async =>
      plain.add((address, frame));

  @override
  Future<void> sendInboxFrame(
    String address,
    Uint8List frame,
    Uint8List senderId,
  ) async => inbox.add((address, frame, senderId.join(',')));
}
