import 'dart:async';
import 'dart:typed_data';

import 'package:conest/src/ui/clipboard_image.dart';
import 'package:flutter/foundation.dart' show ValueChanged;
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:super_clipboard/super_clipboard.dart';

/// How a fake clipboard answers a read of one format.
enum _Answer { file, noFile, error }

class _FakeProgress implements ReadProgress {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeFile implements DataReaderFile {
  _FakeFile(this.bytes);
  final Uint8List bytes;

  @override
  Stream<Uint8List> getStream() => Stream.value(bytes);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeReader implements DataReader {
  _FakeReader(this.offers);

  /// Format → how it is answered, and its bytes.
  final Map<FileFormat, (_Answer, Uint8List)> offers;

  @override
  bool canProvide(DataFormat format) => offers.containsKey(format);

  @override
  List<PlatformFormat> get platformFormats => [
    for (final format in offers.keys) '$format',
  ];

  @override
  ReadProgress? getFile(
    FileFormat? format,
    AsyncValueChanged<DataReaderFile> onFile, {
    ValueChanged<Object>? onError,
    bool allowVirtualFiles = true,
    bool synthesizeFilesFromURIs = true,
  }) {
    final (answer, bytes) = offers[format]!;
    switch (answer) {
      case _Answer.noFile:
        // As the library: no progress, and no callback ever.
        return null;
      case _Answer.error:
        scheduleMicrotask(() => onError?.call(StateError('busy')));
      case _Answer.file:
        scheduleMicrotask(() => onFile(_FakeFile(bytes)));
    }
    return _FakeProgress();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  final png = Uint8List.fromList(img.encodePng(img.Image(width: 2, height: 2)));
  final jpeg = Uint8List.fromList(
    img.encodeJpg(img.Image(width: 2, height: 2)),
  );

  test('a format with no file does not hold the paste up', () async {
    final lines = <String>[];
    final bytes = await readClipboardImage(
      _FakeReader({Formats.png: (_Answer.noFile, png)}),
      log: lines.add,
    ).timeout(const Duration(seconds: 3));
    expect(bytes, isNull);
    expect(lines.join('\n'), contains('no file'));
  });

  test('a format that fails to read gives way to the next', () async {
    final lines = <String>[];
    final bytes = await readClipboardImage(
      _FakeReader({
        Formats.png: (_Answer.error, png),
        Formats.jpeg: (_Answer.file, jpeg),
      }),
      log: lines.add,
    ).timeout(const Duration(seconds: 3));
    expect(bytes, jpeg);
    expect(lines.join('\n'), contains('could not be read'));
  });

  test('a bitmap is pasted as PNG', () async {
    final bmp = Uint8List.fromList(
      img.encodeBmp(img.Image(width: 3, height: 2)),
    );
    final bytes = await readClipboardImage(
      _FakeReader({Formats.bmp: (_Answer.file, bmp)}),
      log: (_) {},
    );
    expect(bytes, isNotNull);
    final decoded = img.decodePng(bytes!);
    expect((decoded!.width, decoded.height), (3, 2));
  });
}
