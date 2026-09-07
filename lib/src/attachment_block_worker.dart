import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'native_attachment_crypto.dart';

typedef EncryptedAttachmentBlock = ({Uint8List ciphertext, Uint8List hash});

/// Reuses two worker isolates for bounded blocks. Native FFI is synchronous,
/// so even the accelerated path must stay off Flutter's rendering isolate.
class AttachmentBlockWorker {
  final _events = ReceivePort();
  final _isolates = <Isolate>[];
  final _ports = <SendPort>[];
  final _pending = <int, Completer<List<Object?>>>{};
  final _ready = Completer<void>();
  Future<void>? _starting;
  bool _closed = false;
  int _sequence = 0;

  Future<void> _start() async {
    _ready.future.ignore();
    _events.listen((event) {
      if (event is SendPort) {
        _ports.add(event);
        if (_ports.length == 2 && !_ready.isCompleted) _ready.complete();
      } else if (event is List && event.firstOrNull is int) {
        final result = List<Object?>.from(event);
        final completer = _pending.remove(result[0]);
        if (result[1] is String) {
          completer?.completeError(StateError(result[1] as String));
        } else {
          completer?.complete(result);
        }
      } else {
        close();
      }
    });
    try {
      for (var i = 0; i < 2; i++) {
        final isolate = await Isolate.spawn(
          _runBlockWorker,
          _events.sendPort,
          onError: _events.sendPort,
          onExit: _events.sendPort,
        );
        if (_closed) {
          isolate.kill(priority: Isolate.immediate);
          throw StateError('Attachment worker closed.');
        }
        _isolates.add(isolate);
      }
      await _ready.future;
    } catch (_) {
      close();
      rethrow;
    }
  }

  Future<List<Object?>> _run(
    bool encrypt,
    Uint8List key,
    Uint8List nonce,
    Uint8List aad,
    Uint8List bytes,
    Uint8List? hash,
  ) async {
    if (_closed) throw StateError('Attachment worker closed.');
    await (_starting ??= _start());
    if (_closed) throw StateError('Attachment worker closed.');
    final id = _sequence++;
    final result = Completer<List<Object?>>();
    _pending[id] = result;
    _ports[id % _ports.length].send([
      id,
      encrypt,
      key,
      nonce,
      aad,
      TransferableTypedData.fromList([bytes]),
      hash,
    ]);
    return result.future;
  }

  Future<EncryptedAttachmentBlock> encrypt({
    required Uint8List key,
    required Uint8List nonce,
    required Uint8List aad,
    required Uint8List plaintext,
  }) async {
    final result = await _run(true, key, nonce, aad, plaintext, null);
    return (
      ciphertext: (result[1] as TransferableTypedData)
          .materialize()
          .asUint8List(),
      hash: result[2] as Uint8List,
    );
  }

  Future<Uint8List> decrypt({
    required Uint8List key,
    required Uint8List nonce,
    required Uint8List aad,
    required Uint8List ciphertext,
    required Uint8List expectedHash,
  }) async {
    final result = await _run(false, key, nonce, aad, ciphertext, expectedHash);
    return (result[1] as TransferableTypedData).materialize().asUint8List();
  }

  void close() {
    if (_closed) return;
    _closed = true;
    final error = StateError('Attachment worker closed.');
    if (!_ready.isCompleted && _starting != null) _ready.completeError(error);
    for (final pending in _pending.values) {
      pending.completeError(error);
    }
    _pending.clear();
    for (final isolate in _isolates) {
      isolate.kill(priority: Isolate.immediate);
    }
    _events.close();
  }
}

Future<void> _runBlockWorker(SendPort replies) async {
  final requests = ReceivePort();
  final native = NativeAttachmentCrypto.tryCreate();
  final cipher = Xchacha20.poly1305Aead();
  replies.send(requests.sendPort);
  await for (final event in requests) {
    final request = event as List;
    final id = request[0] as int;
    try {
      final encrypt = request[1] as bool;
      final key = request[2] as Uint8List;
      final nonce = request[3] as Uint8List;
      final aad = request[4] as Uint8List;
      final bytes = (request[5] as TransferableTypedData)
          .materialize()
          .asUint8List();
      Uint8List output;
      Uint8List hash;
      if (encrypt) {
        if (native != null) {
          final result = native.encrypt(
            key: key,
            nonce: nonce,
            aad: aad,
            plaintext: bytes,
          );
          output = result.ciphertext;
          hash = result.plaintextSha256;
        } else {
          final result = await cipher.encrypt(
            bytes,
            secretKey: SecretKey(key),
            nonce: nonce,
            aad: aad,
          );
          output = Uint8List.fromList([
            ...result.cipherText,
            ...result.mac.bytes,
          ]);
          hash = Uint8List.fromList((await Sha256().hash(bytes)).bytes);
        }
      } else {
        hash = request[6] as Uint8List;
        if (native != null) {
          output = native.decrypt(
            key: key,
            nonce: nonce,
            aad: aad,
            ciphertext: bytes,
            expectedPlaintextSha256: hash,
          );
        } else {
          final tagStart = bytes.length - 16;
          output = Uint8List.fromList(
            await cipher.decrypt(
              SecretBox(
                Uint8List.sublistView(bytes, 0, tagStart),
                nonce: nonce,
                mac: Mac(Uint8List.sublistView(bytes, tagStart)),
              ),
              secretKey: SecretKey(key),
              aad: aad,
            ),
          );
          final actual = (await Sha256().hash(output)).bytes;
          var difference = actual.length ^ hash.length;
          for (var i = 0; i < actual.length && i < hash.length; i++) {
            difference |= actual[i] ^ hash[i];
          }
          if (difference != 0) {
            throw const FormatException('Attachment block digest mismatch.');
          }
        }
      }
      replies.send([
        id,
        TransferableTypedData.fromList([output]),
        hash,
      ]);
    } catch (error) {
      replies.send([id, error.toString()]);
    }
  }
}
