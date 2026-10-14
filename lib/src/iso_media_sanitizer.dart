import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Plans and validates all writes before touching any media samples.
class IsoMediaSanitizer {
  IsoMediaSanitizer(this.file, this.length);
  final RandomAccessFile file;
  final int length;
  static const maxDepth = 32;
  static const maxBoxes = 20000;
  static const maxTableBytes = 4 * 1024 * 1024;
  static const maxSamples = 250000;
  final _zeros = <(int, int)>[];
  final _freeBoxes = <_Box>[];
  final _samples = <(int, int, bool)>[];
  final _media = <(int, int)>[];
  var _boxCount = 0;
  var _sampleCount = 0;
  var _changed = false;
  var _hasTimedMetadata = false;
  var _unindexedTrack = false;

  Future<bool> clean() async {
    final trailer = await _samsungTrailer();
    final boxes = await _boxes(0, trailer ?? length, 0);
    for (final box in boxes) {
      if (box.type == 'mdat') { _media.add((box.content, box.end)); }
    }
    if (boxes.where((box) => box.type == 'meta').length > 1) {
      throw const FormatException('Ambiguous top-level ISO metadata.');
    }
    await _plan(boxes, top: true);
    if (_hasTimedMetadata && (_unindexedTrack || boxes.any((box) => box.type == 'moof'))) {
      throw const FormatException('Unindexed or fragmented timed metadata.');
    }
    for (final sample in _samples) {
      if (!_insideMedia(sample.$1, sample.$2)) {
        throw const FormatException('Samples outside local mdat.');
      }
    }
    // Metadata tables are untrusted: an overlap must never erase an
    // audio/video sample. Also reject overlapping HEIF metadata extents.
    final protected = _samples.where((sample) => !sample.$3).toList()
      ..sort((a, b) => a.$1.compareTo(b.$1));
    final zeroRanges = [..._zeros,
      for (final sample in _samples.where((sample) => sample.$3))
        (sample.$1, sample.$2),
      if (trailer != null) (trailer, length),
    ]..sort((a, b) => a.$1.compareTo(b.$1));
    var sampleIndex = 0;
    for (final range in zeroRanges) {
      while (sampleIndex < protected.length && protected[sampleIndex].$2 <= range.$1) {
        sampleIndex++;
      }
      if (sampleIndex < protected.length && protected[sampleIndex].$1 < range.$2) {
        throw const FormatException('Metadata overlaps media samples.');
      }
    }
    final merged = <(int, int)>[];
    for (final range in zeroRanges) {
      if (range.$1 < 0 || range.$2 < range.$1 || range.$2 > length) {
        throw const FormatException('Invalid ISO write range.');
      }
      if (merged.isNotEmpty && range.$1 <= merged.last.$2) {
        if (range.$2 > merged.last.$2) { merged[merged.length - 1] = (merged.last.$1, range.$2); }
      } else {
        merged.add(range);
      }
    }
    for (final box in _freeBoxes) {
      await _write(box.start + 4, latin1.encode('free'));
    }
    for (final range in merged) { await _zero(range.$1, range.$2); }
    return _changed;
  }

  bool _insideMedia(int start, int end) {
    if (start < 0 || end < start || end > length) { return false; }
    var low = 0, high = _media.length;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      if (_media[mid].$1 <= start) { low = mid + 1; }
      else { high = mid; }
    }
    return low > 0 && end <= _media[low - 1].$2;
  }

  int _fileOffset(int base, int offset) {
    if (base < 0 || offset < 0 || base > length || offset > length - base) {
      throw const FormatException('ISO offset outside file.');
    }
    return base + offset;
  }

  Future<Uint8List> _read(int at, int count) async {
    if (at < 0 || count < 0 || at + count > length || count > maxTableBytes) {
      throw const FormatException('ISO read cap or invalid range.');
    }
    await file.setPosition(at);
    final bytes = await file.read(count);
    if (bytes.length != count) { throw const FormatException('Short ISO read.'); }
    return bytes;
  }

  Future<void> _write(int at, List<int> bytes) async {
    await file.setPosition(at);
    await file.writeFrom(bytes);
    _changed = true;
  }

  Future<void> _zero(int start, int end) async {
    for (var at = start; at < end; at += 65536) {
      final count = (end - at).clamp(0, 65536);
      final current = await _read(at, count);
      if (current.any((byte) => byte != 0)) { await _write(at, Uint8List(count)); }
    }
  }

  Future<List<_Box>> _boxes(int start, int end, int depth) async {
    if (depth > maxDepth) { throw const FormatException('ISO nesting cap.'); }
    final boxes = <_Box>[];
    var at = start;
    while (at < end) {
      if (end - at < 8 || ++_boxCount > maxBoxes) {
        throw const FormatException('ISO box cap or incomplete box.');
      }
      final header = await _read(at, 8);
      var size = ByteData.sublistView(header).getUint32(0);
      final type = latin1.decode(header.sublist(4));
      var content = at + 8;
      if (size == 1) {
        if (end - at < 16) { throw const FormatException('Short large ISO box.'); }
        size = ByteData.sublistView(await _read(at + 8, 8)).getUint64(0);
        content += 8;
      } else if (size == 0) { size = end - at; }
      if (size < content - at || size > end - at) {
        throw const FormatException('Invalid ISO box size.');
      }
      final box = _Box(type, at, content, at + size);
      if (const {'moov', 'trak', 'mdia', 'minf', 'stbl', 'edts', 'dinf',
          'iprp', 'ipco', 'moof', 'traf', 'mfra'}.contains(type)) {
        box.children = await _boxes(content, box.end, depth + 1);
      } else if (type == 'meta' && depth == 0) {
        if (box.end - content < 4) { throw const FormatException('Short HEIF meta.'); }
        box.children = await _boxes(content + 4, box.end, depth + 1);
      }
      boxes.add(box);
      at += size;
    }
    return boxes;
  }

  Future<void> _plan(List<_Box> boxes, {bool top = false}) async {
    for (final box in boxes) {
      if (const {'udta', 'uuid', 'sefd'}.contains(box.type) ||
          box.type == 'meta' && !top) {
        _freeBoxes.add(box);
        _zeros.add((box.content, box.end));
        continue;
      }
      if (box.type == 'trak') { await _track(box); }
      if (box.type == 'meta' && top) { await _heif(box); }
      if (const {'mvhd', 'tkhd', 'mdhd'}.contains(box.type)) {
        final version = (await _read(box.content, 1))[0];
        if (version > 1 || box.content + 4 + (version == 1 ? 16 : 8) > box.end) {
          throw const FormatException('Invalid ISO timestamp box.');
        }
        _zeros.add((box.content + 4, box.content + 4 + (version == 1 ? 16 : 8)));
      }
      await _plan(box.children);
    }
  }

  Future<Uint8List> _body(_Box box) => _read(box.content, box.end - box.content);

  Future<void> _track(_Box track) async {
    final mdia = track.child('mdia');
    final handler = mdia?.child('hdlr');
    if (handler == null) { _unindexedTrack = true; return; }
    if (handler.end - handler.content < 12) { throw const FormatException('Short handler.'); }
    final type = latin1.decode(await _read(handler.content + 8, 4));
    if (type == 'meta') { _hasTimedMetadata = true; }
    final stbl = mdia?.child('minf')?.child('stbl');
    if (stbl == null) {
      if (type == 'meta') { throw const FormatException('Metadata samples unavailable.'); }
      _unindexedTrack = true;
      return;
    }
    final stsd = stbl.child('stsd');
    final descriptions = <String>[];
    if (stsd != null) {
      final data = await _body(stsd);
      final reader = _Reader(data)..skip(4);
      final count = reader.u32();
      if (count > 256) { throw const FormatException('Sample description cap.'); }
      var offset = 8;
      for (var i = 0; i < count; i++) {
        if (offset + 8 > data.length) { throw const FormatException('Short stsd.'); }
        final size = ByteData.sublistView(data).getUint32(offset);
        if (size < 8 || size > data.length - offset) { throw const FormatException('Bad stsd.'); }
        descriptions.add(latin1.decode(data.sublist(offset + 4, offset + 8)));
        offset += size;
      }
      if (offset != data.length) { throw const FormatException('Bad stsd length.'); }
    }
    bool metadata(int description) => type == 'meta' || type == 'text' &&
        const {'gpmd', 'mebx', 'camm'}.contains(descriptions[description - 1]);
    if (type == 'text' && descriptions.any(
        (entry) => const {'gpmd', 'mebx', 'camm'}.contains(entry))) {
      _hasTimedMetadata = true;
    }
    if (stbl.child('stsz') != null && stbl.child('stz2') != null ||
        stbl.child('stco') != null && stbl.child('co64') != null) {
      throw const FormatException('Ambiguous ISO sample tables.');
    }
    final sizesBox = stbl.child('stsz') ?? stbl.child('stz2');
    final chunksBox = stbl.child('stco') ?? stbl.child('co64');
    final stsc = stbl.child('stsc');
    if (sizesBox == null || chunksBox == null || stsc == null || stsd == null) {
      if (type == 'meta' || type == 'text' && descriptions.any(
          (entry) => const {'gpmd', 'mebx', 'camm'}.contains(entry))) {
        throw const FormatException('Incomplete metadata sample tables.');
      }
      _unindexedTrack = true;
      return;
    }
    final sizes = _Reader(await _body(sizesBox))..skip(4);
    final sampleSizes = <int>[];
    int count;
    if (sizesBox.type == 'stsz') {
      final size = sizes.u32();
      count = sizes.u32();
      _capSamples(count);
      for (var i = 0; i < count; i++) { sampleSizes.add(size == 0 ? sizes.u32() : size); }
    } else {
      sizes.skip(3);
      final bits = sizes.n(1);
      if (!const {4, 8, 16}.contains(bits)) { throw const FormatException('Bad stz2 width.'); }
      count = sizes.u32();
      _capSamples(count);
      var pair = 0;
      for (var i = 0; i < count; i++) {
        if (bits == 4) {
          if (i.isEven) { pair = sizes.n(1); }
          sampleSizes.add(i.isEven ? pair >> 4 : pair & 15);
        } else { sampleSizes.add(sizes.n(bits ~/ 8)); }
      }
    }
    sizes.done();
    final chunks = _Reader(await _body(chunksBox))..skip(4);
    final chunkCount = chunks.u32();
    if (chunkCount > maxSamples) { throw const FormatException('ISO chunk cap.'); }
    final offsets = List.generate(chunkCount,
        (_) => chunks.n(chunksBox.type == 'co64' ? 8 : 4));
    chunks.done();
    final mapping = _Reader(await _body(stsc))..skip(4);
    final mappings = mapping.u32();
    if (mappings > chunkCount) { throw const FormatException('ISO mapping cap.'); }
    final runs = <(int, int, int)>[];
    for (var i = 0; i < mappings; i++) {
      final first = mapping.u32(), samples = mapping.u32(), description = mapping.u32();
      if (first < 1 || first > chunkCount || samples == 0 ||
          description < 1 || description > descriptions.length ||
          i == 0 && first != 1 || i > 0 && first <= runs.last.$1) {
        throw const FormatException('Bad stsc mapping.');
      }
      runs.add((first, samples, description));
    }
    mapping.done();
    if (chunkCount > 0 && runs.isEmpty) { throw const FormatException('No chunk mapping.'); }
    var sampleIndex = 0, run = 0;
    for (var chunk = 1; chunk <= chunkCount; chunk++) {
      if (run + 1 < runs.length && runs[run + 1].$1 == chunk) { run++; }
      var offset = offsets[chunk - 1];
      for (var i = 0; i < runs[run].$2; i++) {
        if (sampleIndex >= count) { throw const FormatException('Too many chunk samples.'); }
        final size = sampleSizes[sampleIndex++];
        if (offset < 0 || size > length - offset) { throw const FormatException('Bad sample range.'); }
        if (size > 0) { _samples.add((offset, offset + size, metadata(runs[run].$3))); }
        offset += size;
      }
    }
    if (sampleIndex != count) { throw const FormatException('Missing chunk samples.'); }
  }

  void _capSamples(int count) {
    _sampleCount += count;
    if (_sampleCount > maxSamples) { throw const FormatException('ISO sample cap.'); }
  }

  Future<void> _heif(_Box meta) async {
    final iinf = meta.child('iinf'), iloc = meta.child('iloc');
    if (iinf == null) { return; }
    final info = _Reader(await _body(iinf));
    final infoVersion = info.n(1);
    info.skip(3);
    if (infoVersion > 1) { throw const FormatException('Unsupported iinf.'); }
    final count = info.n(infoVersion == 0 ? 2 : 4);
    final entries = await _boxes(iinf.content + info.at, iinf.end, 2);
    if (count != entries.length) { throw const FormatException('Bad iinf count.'); }
    final metadata = <int>{};
    final declared = <int>{};
    for (final entry in entries) {
      if (entry.type != 'infe') { continue; }
      final body = await _body(entry);
      final reader = _Reader(body);
      final version = reader.n(1);
      reader.skip(3);
      if (version < 2 || version > 3) { throw const FormatException('Unsupported infe.'); }
      final id = reader.n(version == 2 ? 2 : 4);
      if (!declared.add(id)) { throw const FormatException('Duplicate HEIF item ID.'); }
      reader.skip(2);
      final type = latin1.decode(body.sublist(reader.at, reader.at + 4));
      reader.skip(4);
      final nameEnd = body.indexOf(0, reader.at);
      if (nameEnd < 0) { throw const FormatException('Bad HEIF name.'); }
      var xmp = false;
      if (type == 'mime') {
        final typeEnd = body.indexOf(0, nameEnd + 1);
        if (typeEnd < 0) { throw const FormatException('Bad HEIF mime.'); }
        final mime = latin1.decode(body.sublist(nameEnd + 1, typeEnd));
        xmp = mime.contains('rdf+xml') || mime.contains('xmp');
      }
      if (type == 'Exif' || xmp) { metadata.add(id); }
    }
    if (metadata.isEmpty) { return; }
    if (iloc == null) { throw const FormatException('HEIF metadata locations missing.'); }
    final reader = _Reader(await _body(iloc));
    final version = reader.n(1);
    reader.skip(3);
    if (version > 2) { throw const FormatException('Unsupported iloc.'); }
    final widths = reader.n(1), baseWidths = reader.n(1);
    final offsetSize = widths >> 4, lengthSize = widths & 15;
    final baseSize = baseWidths >> 4, indexSize = version > 0 ? baseWidths & 15 : 0;
    if ([offsetSize, lengthSize, baseSize, indexSize].any((n) => n > 8)) {
      throw const FormatException('Bad iloc widths.');
    }
    final items = reader.n(version < 2 ? 2 : 4);
    if (items > maxSamples) { throw const FormatException('HEIF item cap.'); }
    final idat = meta.child('idat');
    if (idat != null) {
      _media.add((idat.content, idat.end));
      _media.sort((a, b) => a.$1.compareTo(b.$1));
    }
    var extentsTotal = 0;
    final located = <int>{};
    for (var item = 0; item < items; item++) {
      final id = reader.n(version < 2 ? 2 : 4);
      if (!declared.contains(id) || !located.add(id)) {
        throw const FormatException('Unknown or duplicate HEIF location ID.');
      }
      final method = version > 0 ? reader.n(2) & 15 : 0;
      final reference = reader.n(2);
      final base = reader.n(baseSize);
      final extents = reader.n(2);
      if (metadata.contains(id) && extents == 0) {
        throw const FormatException('HEIF metadata has no extents.');
      }
      extentsTotal += extents;
      _capSamples(extents);
      if (extentsTotal > maxSamples) { throw const FormatException('HEIF extent cap.'); }
      for (var extent = 0; extent < extents; extent++) {
        reader.n(indexSize);
        final offset = reader.n(offsetSize), size = reader.n(lengthSize);
        if (reference != 0 || method > 1 || method == 1 && idat == null || size == 0) {
          throw const FormatException('Unsupported HEIF extent.');
        }
        final origin = _fileOffset(method == 1 ? idat!.content : 0,
            _fileOffset(base, offset));
        final stop = _fileOffset(origin, size);
        final contained = method == 1
            ? origin >= idat!.content && stop <= idat.end
            : _insideMedia(origin, stop);
        if (!contained) {
          throw const FormatException('HEIF extent outside sample data.');
        }
        _samples.add((origin, stop, metadata.contains(id)));
      }
    }
    reader.done();
    if (!located.containsAll(metadata)) {
      throw const FormatException('Missing HEIF metadata locations.');
    }
  }

  Future<int?> _samsungTrailer() async {
    if (length < 20) { return null; }
    final tail = await _read(length - 8, 8);
    if (latin1.decode(tail.sublist(4)) != 'SEFT') { return null; }
    final size = ByteData.sublistView(tail).getUint32(0, Endian.little);
    if (size < 12 || size > 65536 || size + 8 > length) {
      throw const FormatException('Bad Samsung trailer.');
    }
    final start = length - 8 - size;
    final directory = await _read(start, size);
    if (latin1.decode(directory.sublist(0, 4)) != 'SEFH') {
      throw const FormatException('Bad Samsung header.');
    }
    final view = ByteData.sublistView(directory);
    final count = view.getUint32(8, Endian.little);
    if (count > 2048 || size != 12 + count * 12) {
      throw const FormatException('Samsung directory cap.');
    }
    var first = start;
    for (var i = 0; i < count; i++) {
      final offset = view.getUint32(12 + i * 12 + 4, Endian.little);
      final bytes = view.getUint32(12 + i * 12 + 8, Endian.little);
      final origin = start - offset;
      if (origin < 0 || origin + bytes > start) {
        throw const FormatException('Bad Samsung data range.');
      }
      if (origin < first) { first = origin; }
    }
    return first;
  }
}

class _Box {
  _Box(this.type, this.start, this.content, this.end);
  final String type;
  final int start, content, end;
  List<_Box> children = [];
  _Box? child(String type) {
    final matches = children.where((box) => box.type == type).toList();
    if (matches.length > 1) { throw const FormatException('Duplicate ISO table.'); }
    return matches.firstOrNull;
  }
}

class _Reader {
  _Reader(this.bytes);
  final Uint8List bytes;
  var at = 0;
  int n(int count) {
    if (count < 0 || at + count > bytes.length) { throw const FormatException('Short ISO table.'); }
    var value = 0;
    for (var i = 0; i < count; i++) { value = value * 256 + bytes[at++]; }
    if (value < 0) { throw const FormatException('ISO integer overflow.'); }
    return value;
  }
  int u32() => n(4);
  void skip(int count) { n(count); }
  void done() {
    if (at != bytes.length) { throw const FormatException('ISO table length mismatch.'); }
  }
}
