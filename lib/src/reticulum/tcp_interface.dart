import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../radio/byte_link.dart';
import 'endpoint.dart';
import 'framing.dart';

/// A TCP connection to a Reticulum node (rnsd's TCP server interface),
/// HDLC-framed. One connection; the owner reconnects.
class RnsTcpInterface implements RnsInterface {
  RnsTcpInterface._(this._socket) {
    _socket.done.catchError((Object _) {});
    _socket.listen(
      (bytes) {
        for (final frame in _deframer.add(bytes)) {
          _packets.add(frame);
        }
      },
      onError: (Object error) => _close(error),
      onDone: () => _close(null),
      cancelOnError: true,
    );
  }

  static Future<RnsTcpInterface> connect(
    String host,
    int port, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final socket = await Socket.connect(host, port, timeout: timeout);
    socket.setOption(SocketOption.tcpNoDelay, true);
    enableTcpKeepalive(socket);
    return RnsTcpInterface._(socket);
  }

  final Socket _socket;
  final HdlcDeframer _deframer = HdlcDeframer();
  final WriteQueue _queue = WriteQueue();
  final _packets = StreamController<Uint8List>.broadcast();
  final _closed = Completer<Object?>();

  @override
  Stream<Uint8List> get packets => _packets.stream;

  @override
  Future<Object?> get closed => _closed.future;

  @override
  Future<void> send(Uint8List packet) async {
    if (_closed.isCompleted) {
      throw const SocketException('Reticulum link closed.');
    }
    // Announces, path requests and frames of several envelopes overlap;
    // the socket takes one flush at a time.
    await _queue.run(() async {
      _socket.add(HdlcFraming.frame(packet));
      await _socket.flush();
    });
  }

  @override
  Future<void> close() async {
    _socket.destroy();
    _close(null);
  }

  void _close(Object? error) {
    if (_closed.isCompleted) return;
    _closed.complete(error);
    unawaited(_packets.close());
  }
}
