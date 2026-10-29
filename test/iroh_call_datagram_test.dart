import 'dart:async';
import 'dart:typed_data';

import 'package:conest/src/iroh_ffi_bridge.dart';
import 'package:conest/src/iroh_transport.dart';
import 'package:conest/src/transport.dart';
import 'package:conest/src/transport_models.dart';
import 'package:flutter_test/flutter_test.dart';

/// Models the native media worker: one datagram at a time, an overlapping
/// one is refused outright, exactly as the FFI bridge does.
class _OneAtATimeBridge implements NativeIrohDatagramBridge {
  _OneAtATimeBridge({this.delay = const Duration(milliseconds: 1)});
  final Duration delay;
  bool busy = false;
  final sent = <String>[];

  @override
  Future<IrohBridgeStatus> start({
    required Uint8List secretKeySeed,
    required bool relayEnabled,
    required List<String> relayUrls,
  }) async => IrohBridgeStatus(
    endpointId: 'me',
    directAddresses: const [],
    relayEnabled: relayEnabled,
  );

  @override
  Future<IrohBridgeReceipt> sendDatagram({
    required String remoteEndpointId,
    required Uint8List bytes,
    required bool allowRelay,
  }) async {
    if (busy) throw StateError('Voice datagram worker is busy.');
    busy = true;
    try {
      await Future<void>.delayed(delay);
      sent.add(remoteEndpointId);
    } finally {
      busy = false;
    }
    return IrohBridgeReceipt(
      endpointId: remoteEndpointId,
      relayed: true,
      accepted: true,
    );
  }

  @override
  Future<IrohBridgeReceipt> sendEnvelope({
    required String remoteEndpointId,
    required Uint8List bytes,
    required bool allowRelay,
    List<String> directAddresses = const <String>[],
  }) => throw UnimplementedError();

  @override
  Stream<IrohBridgeInbound> get inbound => const Stream.empty();
  @override
  Stream<IrohBridgeDatagram> get datagrams => const Stream.empty();
  @override
  Future<void> close() async {}
}

TransportPeer _peer(String id) => TransportPeer(
  deviceId: 'dev-$id',
  transportIdentity: id,
  identityPinned: true,
  allowRelay: true,
);

void main() {
  test('call datagrams to several members at once all get through', () async {
    final bridge = _OneAtATimeBridge();
    final adapter = IrohTransportAdapter(
      bridge: bridge,
      secretKeySeed: Uint8List(32),
      relayEnabled: true,
    );
    await adapter.start();
    final frame = Uint8List.fromList([1, 2, 3]);
    final results = await Future.wait([
      for (final id in ['a', 'b', 'c'])
        adapter.sendCallDatagram(peer: _peer(id), bytes: frame),
    ]);
    expect(
      results.map((r) => r.state),
      everyElement(DeliveryReceiptState.deliveredToPeer),
    );
    expect(bridge.sent, ['a', 'b', 'c']);
  });

  test('the queue of waiting call datagrams is bounded', () async {
    final bridge = _OneAtATimeBridge();
    final adapter = IrohTransportAdapter(
      bridge: bridge,
      secretKeySeed: Uint8List(32),
      relayEnabled: true,
    );
    await adapter.start();
    final frame = Uint8List.fromList([1]);
    var refused = 0;
    await Future.wait([
      for (var i = 0; i < 40; i++)
        adapter
            .sendCallDatagram(peer: _peer('a'), bytes: frame)
            .then(
              (_) {},
              onError: (Object _) {
                refused++;
              },
            ),
    ]);
    // Frames that waited too long expire too; none ever reach the worker
    // beyond the 16 that were allowed to queue.
    expect(bridge.sent.length, lessThanOrEqualTo(16));
    expect(refused, greaterThanOrEqualTo(24));
    expect(bridge.sent.length + refused, 40);
  });

  test('a frame that waited too long for the worker expires unsent', () async {
    final bridge = _OneAtATimeBridge(delay: const Duration(milliseconds: 80));
    final adapter = IrohTransportAdapter(
      bridge: bridge,
      secretKeySeed: Uint8List(32),
      relayEnabled: true,
    );
    await adapter.start();
    final frame = Uint8List.fromList([1]);
    final first = adapter.sendCallDatagram(peer: _peer('a'), bytes: frame);
    final second = adapter.sendCallDatagram(peer: _peer('b'), bytes: frame);
    await first;
    await expectLater(
      second,
      throwsA(
        isA<StateError>().having((e) => e.message, 'message', 'expired frame'),
      ),
    );
    expect(bridge.sent, ['a']);
    // The queue recovers: a fresh frame goes straight out.
    await adapter.sendCallDatagram(peer: _peer('c'), bytes: frame);
    expect(bridge.sent, ['a', 'c']);
  });

  test('a send worker that never answers fails instead of hanging', () async {
    await expectLater(
      spawnIrohSendWorker(
        'unused',
        0,
        entry: _silentWorker,
        timeout: const Duration(milliseconds: 200),
      ),
      throwsA(isA<StateError>()),
    );
  });
}

void _silentWorker(List<Object?> startup) {
  // Never answers on the ready port.
}
