import 'dart:io';
import 'dart:typed_data';

/// Bounds apply to actual output, even when an input lies about its size.
Uint8List inflateMetadata(List<int> bytes, int limit, {bool raw = false}) {
  final output = _BoundedBytes(limit);
  final decoder = ZLibDecoder(raw: raw).startChunkedConversion(output);
  // Limit each decoder step as well as retained output. A single large
  // compressed input chunk could otherwise allocate far beyond the cap.
  for (var at = 0; at < bytes.length; at += 1024) {
    decoder.add(bytes.sublist(at, (at + 1024).clamp(0, bytes.length)));
  }
  decoder.close();
  return output.bytes.takeBytes();
}

class _BoundedBytes implements Sink<List<int>> {
  _BoundedBytes(this.limit);
  final int limit;
  final bytes = BytesBuilder();
  var count = 0;

  @override
  void add(List<int> data) {
    count += data.length;
    if (count > limit) { throw const FormatException('Metadata expansion cap.'); }
    bytes.add(data);
  }

  @override
  void close() {}
}
