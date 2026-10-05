import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// A byte stream to a radio: USB or desktop serial, Bluetooth serial, or
/// TCP. Radio protocols (RNode KISS, Meshtastic, MeshCore) run on top.
abstract interface class ByteLink {
  Stream<Uint8List> get input;
  Future<void> write(List<int> bytes);

  /// Completes when the link ends, with the error if there was one.
  Future<Object?> get closed;
  Future<void> close();

  /// What the user sees, such as `/dev/ttyACM0` or `rnode.local:8001`.
  String get label;

  /// Whether the link keeps message boundaries: each write is delivered as
  /// one message and each input event is one message (Bluetooth LE
  /// characteristics), rather than a plain byte stream.
  bool get keepsMessages;
}

/// A serial port on Linux or macOS, set to raw mode with `stty` and read
/// and written as a file.
class UnixSerialLink implements ByteLink {
  UnixSerialLink._(this.label, this._read, this._write) {
    _subscription = _read.listen(
      (bytes) => _input.add(Uint8List.fromList(bytes)),
      onError: (Object error) => _finish(error),
      onDone: () => _finish(null),
      cancelOnError: true,
    );
  }

  static Future<UnixSerialLink> open(String path, {int baud = 115200}) async {
    if (!Platform.isLinux && !Platform.isMacOS) {
      throw UnsupportedError(
        'Serial ports are opened this way on Linux and '
        'macOS only.',
      );
    }
    if (!RegExp(r'^/dev/[A-Za-z0-9._/-]+$').hasMatch(path)) {
      throw ArgumentError('Not a serial device path.');
    }
    final args = Platform.isMacOS
        ? ['-f', path, '$baud', 'raw', '-echo']
        : ['-F', path, '$baud', 'raw', '-echo', '-hupcl'];
    final stty = await Process.run('stty', args);
    if (stty.exitCode != 0) {
      throw FileSystemException('Cannot configure ${stty.stderr}', path);
    }
    final file = File(path);
    final write = await file.open(mode: FileMode.writeOnlyAppend);
    return UnixSerialLink._(path, file.openRead(), write);
  }

  @override
  final String label;

  @override
  bool get keepsMessages => false;
  final Stream<List<int>> _read;
  final RandomAccessFile _write;
  final WriteQueue _queue = WriteQueue();
  late final StreamSubscription<List<int>> _subscription;
  final _input = StreamController<Uint8List>.broadcast();
  final _closed = Completer<Object?>();

  @override
  Stream<Uint8List> get input => _input.stream;

  @override
  Future<Object?> get closed => _closed.future;

  @override
  Future<void> write(List<int> bytes) async {
    if (_closed.isCompleted) throw const FileSystemException('Link closed.');
    await _queue.run(() async {
      await _write.writeFrom(bytes);
      await _write.flush();
    });
  }

  @override
  Future<void> close() async {
    await _subscription.cancel();
    await _write.close().catchError((Object _) => _write);
    _finish(null);
  }

  void _finish(Object? error) {
    if (_closed.isCompleted) return;
    _closed.complete(error);
    unawaited(_input.close());
  }
}

/// A TCP connection to a radio that offers its serial protocol over the
/// network (for example an RNode on Wi-Fi).
class TcpByteLink implements ByteLink {
  TcpByteLink._(this.label, this._socket) {
    _socket.done.catchError((Object _) {});
    _socket.listen(
      _input.add,
      onError: (Object error) => _finish(error),
      onDone: () => _finish(null),
      cancelOnError: true,
    );
  }

  static Future<TcpByteLink> connect(String host, int port) async {
    final socket = await Socket.connect(
      host,
      port,
      timeout: const Duration(seconds: 15),
    );
    socket.setOption(SocketOption.tcpNoDelay, true);
    enableTcpKeepalive(socket);
    return TcpByteLink._('$host:$port', socket);
  }

  @override
  final String label;

  @override
  bool get keepsMessages => false;
  final Socket _socket;
  final WriteQueue _queue = WriteQueue();
  final _input = StreamController<Uint8List>.broadcast();
  final _closed = Completer<Object?>();

  @override
  Stream<Uint8List> get input => _input.stream;

  @override
  Future<Object?> get closed => _closed.future;

  @override
  Future<void> write(List<int> bytes) async {
    if (_closed.isCompleted) throw const SocketException('Link closed.');
    await _queue.run(() async {
      _socket.add(bytes);
      await _socket.flush();
    });
  }

  @override
  Future<void> close() async {
    _socket.destroy();
    _finish(null);
  }

  void _finish(Object? error) {
    if (_closed.isCompleted) return;
    _closed.complete(error);
    unawaited(_input.close());
  }
}

/// Runs writes one after another: a socket or file refuses a write while
/// the previous one is still being flushed.
class WriteQueue {
  Future<void> _tail = Future<void>.value();

  Future<void> run(Future<void> Function() write) {
    final next = _tail.then((_) => write());
    // A failed write fails its caller, not the writes queued after it.
    _tail = next.catchError((Object _) {});
    return next;
  }
}

/// Turns on TCP keepalive (probe after a minute idle) so a connection that
/// silently died, for example after a network change, is noticed.
void enableTcpKeepalive(Socket socket) {
  try {
    if (Platform.isLinux || Platform.isAndroid) {
      // SOL_SOCKET/SO_KEEPALIVE, then IPPROTO_TCP TCP_KEEPIDLE/INTVL/CNT.
      socket.setRawOption(RawSocketOption.fromInt(1, 9, 1));
      socket.setRawOption(RawSocketOption.fromInt(6, 4, 60));
      socket.setRawOption(RawSocketOption.fromInt(6, 5, 15));
      socket.setRawOption(RawSocketOption.fromInt(6, 6, 4));
    } else if (Platform.isMacOS || Platform.isIOS || Platform.isWindows) {
      socket.setRawOption(RawSocketOption.fromInt(0xffff, 0x0008, 1));
    }
  } catch (_) {
    // Keepalive is an improvement, not a requirement.
  }
}

/// A radio device as the user picks it: a serial device path on Linux and
/// macOS (`/dev/ttyACM0`), or an Android USB device (`vendor:product` in
/// hex, or its system path).
bool isRadioDeviceName(String value) =>
    RegExp(r'^/dev/[A-Za-z0-9._/-]+$').hasMatch(value) ||
    RegExp(r'^[0-9a-f]{4}:[0-9a-f]{4}$').hasMatch(value);
