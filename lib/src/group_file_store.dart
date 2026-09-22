import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'group_file_manifest.dart';

/// App-owned piece cache. Authorization and receive/storage policy belong to
/// the caller and must be rechecked before every read/write. Never use a remote
/// filename as a path. Completed pieces are published by atomic rename only
/// after hash verification and flush; recovery derives availability from bytes.
class GroupFileStore {
  GroupFileStore({required Directory root, required this.manifest})
    : directory = Directory(
        '${root.path}/${sha256.convert(utf8.encode(jsonEncode(manifest.toPayload())))}',
      );

  final Directory directory;
  final GroupFileManifest manifest;
  Future<void> _tail = Future.value();
  int _queuedWrites = 0;

  Future<T> _serialize<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  /// Returns only verified durable piece indices. Incomplete staging files are
  /// ignored. A damaged piece is treated as missing and can be replaced.
  Future<Set<int>> recover() =>
      _serialize(() => _recover(directory.path, manifest));

  Future<void> writePiece(int index, Uint8List bytes) {
    if (bytes.length != manifest.lengthOf(index)) {
      return Future.error(const FormatException('Invalid group piece length.'));
    }
    if (_queuedWrites >= 4) {
      return Future.error(StateError('Group file write queue is full.'));
    }
    _queuedWrites++;
    // Own the buffer before yielding; transport buffers may be reused.
    final owned = Uint8List.fromList(bytes);
    return _serialize(
      () => _write(directory.path, manifest, index, owned),
    ).whenComplete(() => _queuedWrites--);
  }

  /// Verify again before serving: cached files may have been evicted or damaged
  /// since their last availability announcement.
  Future<Uint8List?> readPiece(int index) {
    manifest.lengthOf(index);
    // Reads use independent file handles inside their worker isolates. Wait
    // for writes already queued, then allow verified pieces to be served in
    // parallel; routing every read through [_serialize] serialized the
    // provider's four-piece window and throttled group transfers.
    final pendingWrites = _tail;
    return pendingWrites.then((_) => _read(directory.path, manifest, index));
  }

  /// Assemble only into an app-owned path, and publish only after a separate
  /// whole-file hash check. Inconsistent signed manifests never produce a file.
  Future<File> assemble() =>
      _serialize(() async => File(await _assemble(directory.path, manifest)));
}

Future<Set<int>> _recover(String path, GroupFileManifest description) =>
    Isolate.run(() async {
      final verified = <int>{};
      for (var piece = 0; piece < description.pieceHashes.length; piece++) {
        if (await _readVerified(path, description, piece) != null) {
          verified.add(piece);
        }
      }
      return verified;
    });

Future<void> _write(
  String path,
  GroupFileManifest description,
  int index,
  Uint8List bytes,
) => Isolate.run(() async {
  if (!description.verifyPiece(index, bytes)) {
    throw const FormatException('Group file piece failed verification.');
  }
  await Directory(path).create(recursive: true);
  final staged = File('$path/$index.pending');
  await staged.writeAsBytes(bytes, flush: true);
  await staged.rename('$path/$index.piece');
});

Future<Uint8List?> _read(
  String path,
  GroupFileManifest description,
  int index,
) => Isolate.run(() => _readVerified(path, description, index));

Future<String> _assemble(String path, GroupFileManifest description) =>
    Isolate.run(() async {
      await Directory(path).create(recursive: true);
      final staged = File('$path/complete.pending');
      final output = await staged.open(mode: FileMode.writeOnly);
      try {
        for (var index = 0; index < description.pieceHashes.length; index++) {
          final bytes = await _readVerified(path, description, index);
          if (bytes == null) {
            throw StateError('Waiting for missing file pieces.');
          }
          await output.writeFrom(bytes);
        }
        await output.flush();
      } finally {
        await output.close();
      }
      final digest = await sha256.bind(staged.openRead()).first;
      if (digest.toString() != description.fileHash) {
        await staged.delete();
        throw const FormatException(
          'Group file failed whole-file verification.',
        );
      }
      return (await staged.rename('$path/complete')).path;
    });

Future<Uint8List?> _readVerified(
  String path,
  GroupFileManifest manifest,
  int index,
) async {
  final file = File('$path/$index.piece');
  try {
    if (await file.length() != manifest.lengthOf(index)) return null;
    final bytes = await file.readAsBytes();
    return manifest.verifyPiece(index, bytes) ? bytes : null;
  } on FileSystemException {
    return null;
  }
}
