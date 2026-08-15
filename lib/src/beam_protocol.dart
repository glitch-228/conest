import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'models.dart';

const int conestBeamMaximumPayloadBytes = 64 * 1024 * 1024;
const int conestBeamDefaultBlockSize = 768;
const String conestBeamFramePrefix = 'cb1:';

enum BeamMode { public, contactEncrypted, contactInvite }

class BeamEncryptedPayload {
  const BeamEncryptedPayload({
    required this.ciphertext,
    required this.metadataBase64,
  });

  final Uint8List ciphertext;
  final String metadataBase64;
}

class BeamManifest {
  const BeamManifest({
    required this.transferId,
    required this.mode,
    required this.fileName,
    required this.mimeType,
    required this.sizeBytes,
    required this.sha256Base64,
    required this.createdAt,
    this.senderFingerprint,
    this.senderSigningPublicKeyBase64,
    this.signatureBase64,
    this.encryptionMetadataBase64,
  });

  final String transferId;
  final BeamMode mode;
  final String fileName;
  final String mimeType;
  final int sizeBytes;
  final String sha256Base64;
  final DateTime createdAt;
  final String? senderFingerprint;
  final String? senderSigningPublicKeyBase64;
  final String? signatureBase64;
  final String? encryptionMetadataBase64;

  Map<String, dynamic> toJson({bool includeSignature = true}) => {
    'version': 1,
    'transferId': transferId,
    'mode': mode.name,
    'fileName': fileName,
    'mimeType': mimeType,
    'sizeBytes': sizeBytes,
    'sha256Base64': sha256Base64,
    'createdAt': createdAt.toUtc().toIso8601String(),
    if (senderFingerprint != null) 'senderFingerprint': senderFingerprint,
    if (senderSigningPublicKeyBase64 != null)
      'senderSigningPublicKeyBase64': senderSigningPublicKeyBase64,
    if (includeSignature && signatureBase64 != null)
      'signatureBase64': signatureBase64,
    if (encryptionMetadataBase64 != null)
      'encryptionMetadataBase64': encryptionMetadataBase64,
  };

  Uint8List canonicalBytes() => Uint8List.fromList(
    utf8.encode(jsonEncode(toJson(includeSignature: false))),
  );

  BeamManifest copyWithSignature(String signature) => BeamManifest(
    transferId: transferId,
    mode: mode,
    fileName: fileName,
    mimeType: mimeType,
    sizeBytes: sizeBytes,
    sha256Base64: sha256Base64,
    createdAt: createdAt,
    senderFingerprint: senderFingerprint,
    senderSigningPublicKeyBase64: senderSigningPublicKeyBase64,
    signatureBase64: signature,
    encryptionMetadataBase64: encryptionMetadataBase64,
  );

  factory BeamManifest.fromJson(Map<String, dynamic> json) {
    if (json['version'] != 1) {
      throw const FormatException('Unsupported Beam manifest version.');
    }
    final mode = BeamMode.values
        .where((entry) => entry.name == json['mode'])
        .firstOrNull;
    final fileName = json['fileName'] as String? ?? '';
    final mimeType = json['mimeType'] as String? ?? '';
    final sizeBytes = (json['sizeBytes'] as num?)?.toInt() ?? -1;
    if (mode == null ||
        fileName.isEmpty ||
        fileName.length > 255 ||
        mimeType.isEmpty ||
        mimeType.length > 160 ||
        sizeBytes < 0 ||
        sizeBytes > conestBeamMaximumPayloadBytes) {
      throw const FormatException('Beam manifest fields are out of range.');
    }
    return BeamManifest(
      transferId: json['transferId'] as String,
      mode: mode,
      fileName: fileName,
      mimeType: mimeType,
      sizeBytes: sizeBytes,
      sha256Base64: json['sha256Base64'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String).toUtc(),
      senderFingerprint: json['senderFingerprint'] as String?,
      senderSigningPublicKeyBase64:
          json['senderSigningPublicKeyBase64'] as String?,
      signatureBase64: json['signatureBase64'] as String?,
      encryptionMetadataBase64: json['encryptionMetadataBase64'] as String?,
    );
  }
}

/// A complete outbound Beam prepared by the controller. The encoder owns the
/// fountain-stream cursor; callers may keep calling [BeamEncoder.nextFrame]
/// until the receiver confirms completion or the user stops the transfer.
class PreparedBeamTransfer {
  const PreparedBeamTransfer({
    required this.package,
    required this.encoder,
    this.recipientDeviceId,
  });

  final BeamPackage package;
  final BeamEncoder encoder;
  final String? recipientDeviceId;
}

/// A cryptographically checked Beam import. Public data is still untrusted:
/// [senderVerified] only means its self-contained signature is internally
/// valid. It becomes contact-trusted only when [senderDeviceId] is populated.
class BeamImportResult {
  const BeamImportResult({
    required this.manifest,
    required this.bytes,
    required this.senderVerified,
    required this.contactTrusted,
    this.senderDeviceId,
    this.invite,
  });

  final BeamManifest manifest;
  final Uint8List bytes;
  final bool senderVerified;
  final bool contactTrusted;
  final String? senderDeviceId;
  final ContactInvite? invite;

  bool get requiresPublicAcceptance =>
      manifest.mode == BeamMode.public && !contactTrusted;
}

class BeamPackage {
  const BeamPackage({required this.manifest, required this.payload});

  final BeamManifest manifest;
  final Uint8List payload;

  Uint8List encode() {
    if (payload.length > conestBeamMaximumPayloadBytes ||
        manifest.sizeBytes != payload.length) {
      throw ArgumentError('Beam payload size does not match its manifest.');
    }
    final actualHash = base64Encode(sha256.convert(payload).bytes);
    if (actualHash != manifest.sha256Base64) {
      throw ArgumentError('Beam payload hash does not match its manifest.');
    }
    final manifestBytes = utf8.encode(jsonEncode(manifest.toJson()));
    if (manifestBytes.length > 64 * 1024) {
      throw ArgumentError('Beam manifest is too large.');
    }
    final result = Uint8List(4 + manifestBytes.length + payload.length);
    ByteData.sublistView(result).setUint32(0, manifestBytes.length, Endian.big);
    result.setRange(4, 4 + manifestBytes.length, manifestBytes);
    result.setRange(4 + manifestBytes.length, result.length, payload);
    return result;
  }

  factory BeamPackage.decode(Uint8List bytes) {
    if (bytes.length < 4) {
      throw const FormatException('Beam package is truncated.');
    }
    final manifestLength = ByteData.sublistView(bytes).getUint32(0, Endian.big);
    if (manifestLength <= 0 ||
        manifestLength > 64 * 1024 ||
        4 + manifestLength > bytes.length) {
      throw const FormatException('Beam manifest length is invalid.');
    }
    final manifestValue = jsonDecode(
      utf8.decode(bytes.sublist(4, 4 + manifestLength)),
    );
    if (manifestValue is! Map<String, dynamic>) {
      throw const FormatException('Beam manifest must be an object.');
    }
    final manifest = BeamManifest.fromJson(manifestValue);
    final payload = Uint8List.fromList(bytes.sublist(4 + manifestLength));
    if (payload.length != manifest.sizeBytes ||
        base64Encode(sha256.convert(payload).bytes) != manifest.sha256Base64) {
      throw const FormatException(
        'Beam payload failed size or hash verification.',
      );
    }
    return BeamPackage(manifest: manifest, payload: payload);
  }
}

class BeamFrame {
  const BeamFrame({
    required this.mode,
    required this.transferIdBytes,
    required this.originalLength,
    required this.blockSize,
    required this.sourceBlockCount,
    required this.seed,
    required this.degree,
    required this.systematic,
    required this.payload,
  });

  static const int _headerLength = 50;
  static const List<int> _magic = [0x43, 0x42, 0x4d, 0x31];

  final BeamMode mode;
  final Uint8List transferIdBytes;
  final int originalLength;
  final int blockSize;
  final int sourceBlockCount;
  final int seed;
  final int degree;
  final bool systematic;
  final Uint8List payload;

  String get transferId => _hex(transferIdBytes);

  Uint8List encodeBytes() {
    if (transferIdBytes.length != 16 ||
        originalLength <= 0 ||
        originalLength > conestBeamMaximumPayloadBytes + 64 * 1024 + 4 ||
        blockSize <= 0 ||
        blockSize > 2048 ||
        sourceBlockCount <= 0 ||
        degree <= 0 ||
        degree > sourceBlockCount ||
        payload.length != blockSize) {
      throw ArgumentError('Beam frame fields are out of range.');
    }
    final bytes = Uint8List(_headerLength + payload.length);
    bytes.setRange(0, 4, _magic);
    final data = ByteData.sublistView(bytes);
    data.setUint8(4, 1);
    data.setUint8(5, mode.index);
    data.setUint8(6, systematic ? 1 : 0);
    data.setUint8(7, 0);
    bytes.setRange(8, 24, transferIdBytes);
    data.setUint64(24, originalLength, Endian.big);
    data.setUint16(32, blockSize, Endian.big);
    data.setUint32(34, sourceBlockCount, Endian.big);
    data.setUint32(38, seed, Endian.big);
    data.setUint16(42, degree, Endian.big);
    data.setUint16(44, payload.length, Endian.big);
    data.setUint32(46, 0, Endian.big);
    bytes.setRange(_headerLength, bytes.length, payload);
    data.setUint32(46, _crc32c(bytes), Endian.big);
    return bytes;
  }

  String encodeText() =>
      '$conestBeamFramePrefix${base64Url.encode(encodeBytes()).replaceAll('=', '')}';

  factory BeamFrame.decodeText(String value) {
    if (!value.startsWith(conestBeamFramePrefix)) {
      throw const FormatException('Not a Conest Beam frame.');
    }
    return BeamFrame.decodeBytes(
      Uint8List.fromList(
        base64Url.decode(
          base64Url.normalize(value.substring(conestBeamFramePrefix.length)),
        ),
      ),
    );
  }

  factory BeamFrame.decodeBytes(Uint8List bytes) {
    if (bytes.length < _headerLength ||
        !_constantListEquals(bytes.sublist(0, 4), _magic)) {
      throw const FormatException('Beam frame header is invalid.');
    }
    final data = ByteData.sublistView(bytes);
    if (data.getUint8(4) != 1) {
      throw const FormatException('Unsupported Beam frame version.');
    }
    final modeIndex = data.getUint8(5);
    final payloadLength = data.getUint16(44, Endian.big);
    if (modeIndex >= BeamMode.values.length ||
        payloadLength <= 0 ||
        bytes.length != _headerLength + payloadLength) {
      throw const FormatException('Beam frame dimensions are invalid.');
    }
    final expectedCrc = data.getUint32(46, Endian.big);
    final copy = Uint8List.fromList(bytes);
    ByteData.sublistView(copy).setUint32(46, 0, Endian.big);
    if (_crc32c(copy) != expectedCrc) {
      throw const FormatException('Beam frame CRC32C mismatch.');
    }
    final frame = BeamFrame(
      mode: BeamMode.values[modeIndex],
      transferIdBytes: Uint8List.fromList(bytes.sublist(8, 24)),
      originalLength: data.getUint64(24, Endian.big),
      blockSize: data.getUint16(32, Endian.big),
      sourceBlockCount: data.getUint32(34, Endian.big),
      seed: data.getUint32(38, Endian.big),
      degree: data.getUint16(42, Endian.big),
      systematic: data.getUint8(6) & 1 == 1,
      payload: Uint8List.fromList(bytes.sublist(_headerLength)),
    );
    if (frame.originalLength <= 0 ||
        frame.originalLength > conestBeamMaximumPayloadBytes + 64 * 1024 + 4 ||
        frame.blockSize <= 0 ||
        frame.blockSize > 2048 ||
        frame.sourceBlockCount <= 0 ||
        frame.degree <= 0 ||
        frame.degree > frame.sourceBlockCount ||
        frame.payload.length != frame.blockSize ||
        (frame.originalLength + frame.blockSize - 1) ~/ frame.blockSize !=
            frame.sourceBlockCount ||
        (frame.systematic &&
            (frame.degree != 1 || frame.seed >= frame.sourceBlockCount))) {
      throw const FormatException('Beam frame fields are out of range.');
    }
    return frame;
  }
}

class BeamEncoder {
  BeamEncoder({
    required BeamPackage package,
    this.blockSize = conestBeamDefaultBlockSize,
    Random? random,
  }) : _packageBytes = package.encode(),
       mode = package.manifest.mode,
       transferIdBytes = _transferIdBytes(package.manifest.transferId),
       _random = random ?? Random.secure() {
    if (blockSize < 256 || blockSize > 2048) {
      throw ArgumentError.value(blockSize, 'blockSize');
    }
    sourceBlockCount = (_packageBytes.length + blockSize - 1) ~/ blockSize;
    _blocks = List.generate(sourceBlockCount, (index) {
      final block = Uint8List(blockSize);
      final start = index * blockSize;
      final end = min(start + blockSize, _packageBytes.length);
      block.setRange(0, end - start, _packageBytes, start);
      return block;
    }, growable: false);
    _degreeCdf = _robustSolitonCdf(sourceBlockCount);
  }

  final Uint8List _packageBytes;
  final BeamMode mode;
  final Uint8List transferIdBytes;
  final int blockSize;
  final Random _random;
  late final int sourceBlockCount;
  late final List<Uint8List> _blocks;
  late final List<double> _degreeCdf;
  int _frameIndex = 0;

  int get frameIndex => _frameIndex;

  BeamFrame nextFrame() {
    final current = _frameIndex++;
    if (current < sourceBlockCount) {
      return BeamFrame(
        mode: mode,
        transferIdBytes: transferIdBytes,
        originalLength: _packageBytes.length,
        blockSize: blockSize,
        sourceBlockCount: sourceBlockCount,
        seed: current,
        degree: 1,
        systematic: true,
        payload: Uint8List.fromList(_blocks[current]),
      );
    }
    final seed = _random.nextInt(0x100000000);
    final prng = _XorShift32(seed);
    final degree = _pickDegree(_degreeCdf, prng.nextDouble());
    final indices = _indicesFor(seed, degree, sourceBlockCount);
    final payload = Uint8List(blockSize);
    for (final index in indices) {
      _xorInto(payload, _blocks[index]);
    }
    return BeamFrame(
      mode: mode,
      transferIdBytes: transferIdBytes,
      originalLength: _packageBytes.length,
      blockSize: blockSize,
      sourceBlockCount: sourceBlockCount,
      seed: seed,
      degree: degree,
      systematic: false,
      payload: payload,
    );
  }
}

class BeamDecodeProgress {
  const BeamDecodeProgress({
    required this.solvedBlocks,
    required this.sourceBlockCount,
    required this.distinctFrames,
    required this.complete,
  });

  final int solvedBlocks;
  final int sourceBlockCount;
  final int distinctFrames;
  final bool complete;

  double get fraction =>
      sourceBlockCount == 0 ? 0 : (solvedBlocks / sourceBlockCount).clamp(0, 1);
}

class BeamDecoder {
  String? _transferId;
  BeamMode? _mode;
  int? _originalLength;
  int? _blockSize;
  int? _sourceBlockCount;
  final Map<int, Uint8List> _solved = {};
  final List<_BeamEquation> _equations = [];
  final Set<int> _seenSeeds = {};
  BeamPackage? _package;

  String? get transferId => _transferId;
  BeamMode? get mode => _mode;
  BeamPackage? get package => _package;

  BeamDecodeProgress addFrame(BeamFrame frame) {
    if (_transferId == null) {
      _transferId = frame.transferId;
      _mode = frame.mode;
      _originalLength = frame.originalLength;
      _blockSize = frame.blockSize;
      _sourceBlockCount = frame.sourceBlockCount;
    } else if (_transferId != frame.transferId ||
        _mode != frame.mode ||
        _originalLength != frame.originalLength ||
        _blockSize != frame.blockSize ||
        _sourceBlockCount != frame.sourceBlockCount) {
      throw const FormatException('Beam frame belongs to another transfer.');
    }
    if (_package != null || !_seenSeeds.add(frame.seed)) return progress;
    final indices = frame.systematic
        ? <int>{frame.seed}
        : _indicesFor(frame.seed, frame.degree, frame.sourceBlockCount);
    if (indices.any((index) => index >= frame.sourceBlockCount)) {
      throw const FormatException('Beam frame references an invalid block.');
    }
    final equation = _BeamEquation(
      indices: Set<int>.from(indices),
      bytes: Uint8List.fromList(frame.payload),
    );
    _reduceKnown(equation);
    if (equation.indices.length == 1) {
      _solve(equation.indices.single, equation.bytes);
    } else if (equation.indices.isNotEmpty) {
      _equations.add(equation);
    }
    _drainEquations();
    if (_solved.length == _sourceBlockCount) {
      final assembled = BytesBuilder(copy: false);
      for (var index = 0; index < _sourceBlockCount!; index++) {
        assembled.add(_solved[index]!);
      }
      final bytes = Uint8List.fromList(
        assembled.takeBytes().sublist(0, _originalLength),
      );
      _package = BeamPackage.decode(bytes);
      if (_package!.manifest.transferId.toLowerCase() != _transferId) {
        throw const FormatException('Beam transfer identifier mismatch.');
      }
    }
    return progress;
  }

  BeamDecodeProgress get progress => BeamDecodeProgress(
    solvedBlocks: _solved.length,
    sourceBlockCount: _sourceBlockCount ?? 0,
    distinctFrames: _seenSeeds.length,
    complete: _package != null,
  );

  void _reduceKnown(_BeamEquation equation) {
    for (final index in equation.indices.toList(growable: false)) {
      final known = _solved[index];
      if (known != null) {
        _xorInto(equation.bytes, known);
        equation.indices.remove(index);
      }
    }
  }

  void _solve(int index, Uint8List bytes) {
    final existing = _solved[index];
    if (existing != null) {
      if (!_constantListEquals(existing, bytes)) {
        throw const FormatException('Conflicting Beam source block.');
      }
      return;
    }
    _solved[index] = Uint8List.fromList(bytes);
  }

  void _drainEquations() {
    var changed = true;
    while (changed) {
      changed = false;
      for (var index = _equations.length - 1; index >= 0; index--) {
        final equation = _equations[index];
        final before = equation.indices.length;
        _reduceKnown(equation);
        if (equation.indices.isEmpty) {
          _equations.removeAt(index);
          changed = true;
        } else if (equation.indices.length == 1) {
          _solve(equation.indices.single, equation.bytes);
          _equations.removeAt(index);
          changed = true;
        } else if (equation.indices.length != before) {
          changed = true;
        }
      }
    }
  }
}

class _BeamEquation {
  _BeamEquation({required this.indices, required this.bytes});

  final Set<int> indices;
  final Uint8List bytes;
}

List<double> _robustSolitonCdf(int count) {
  if (count == 1) return const [1.0];
  const c = 0.1;
  const delta = 0.5;
  final r = c * log(count / delta) * sqrt(count);
  final pivot = max(1, (count / r).floor());
  final weights = List<double>.filled(count, 0);
  var total = 0.0;
  for (var degree = 1; degree <= count; degree++) {
    final ideal = degree == 1 ? 1 / count : 1 / (degree * (degree - 1));
    var robust = 0.0;
    if (degree < pivot) {
      robust = r / (degree * count);
    } else if (degree == pivot) {
      robust = r * log(r / delta) / count;
    }
    final weight = ideal + robust;
    weights[degree - 1] = weight;
    total += weight;
  }
  var cumulative = 0.0;
  for (var index = 0; index < weights.length; index++) {
    cumulative += weights[index] / total;
    weights[index] = cumulative;
  }
  weights[weights.length - 1] = 1;
  return weights;
}

int _pickDegree(List<double> cdf, double value) {
  var low = 0;
  var high = cdf.length - 1;
  while (low < high) {
    final mid = (low + high) >> 1;
    if (value <= cdf[mid]) {
      high = mid;
    } else {
      low = mid + 1;
    }
  }
  return min(low + 1, 1024);
}

Set<int> _indicesFor(int seed, int degree, int count) {
  if (degree <= 0 || degree > count) {
    throw const FormatException('Invalid Beam fountain degree.');
  }
  final result = <int>{};
  final random = _XorShift32(seed ^ 0x9e3779b9);
  while (result.length < degree) {
    result.add(random.nextUint32() % count);
  }
  return result;
}

class _XorShift32 {
  _XorShift32(int seed) : _state = seed & 0xffffffff {
    if (_state == 0) _state = 0x6d2b79f5;
  }

  int _state;

  int nextUint32() {
    var value = _state;
    value ^= (value << 13) & 0xffffffff;
    value ^= value >>> 17;
    value ^= (value << 5) & 0xffffffff;
    _state = value & 0xffffffff;
    return _state;
  }

  double nextDouble() => nextUint32() / 0x100000000;
}

Uint8List _transferIdBytes(String value) {
  final normalized = value.replaceAll('-', '').toLowerCase();
  if (normalized.length != 32 ||
      !RegExp(r'^[0-9a-f]{32}$').hasMatch(normalized)) {
    throw ArgumentError('Beam transferId must contain 16 hexadecimal bytes.');
  }
  return Uint8List.fromList([
    for (var index = 0; index < normalized.length; index += 2)
      int.parse(normalized.substring(index, index + 2), radix: 16),
  ]);
}

String _hex(Iterable<int> bytes) =>
    bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();

void _xorInto(Uint8List target, Uint8List source) {
  if (target.length != source.length) {
    throw ArgumentError('Beam XOR blocks must have equal length.');
  }
  for (var index = 0; index < target.length; index++) {
    target[index] ^= source[index];
  }
}

bool _constantListEquals(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  var difference = 0;
  for (var index = 0; index < left.length; index++) {
    difference |= left[index] ^ right[index];
  }
  return difference == 0;
}

int _crc32c(Uint8List bytes) {
  var crc = 0xffffffff;
  for (final byte in bytes) {
    crc = _crc32cTable[(crc ^ byte) & 0xff] ^ (crc >>> 8);
  }
  return (crc ^ 0xffffffff) & 0xffffffff;
}

final List<int> _crc32cTable = List<int>.generate(256, (index) {
  var value = index;
  for (var bit = 0; bit < 8; bit++) {
    value = value & 1 == 1 ? (value >>> 1) ^ 0x82f63b78 : value >>> 1;
  }
  return value & 0xffffffff;
}, growable: false);
