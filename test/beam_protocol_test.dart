import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:conest/src/beam_protocol.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

// Parsed independently by native/conest_native/src/beam.rs as the shared
// Dart/Rust Beam v1 compatibility vector.
const _sharedGoldenFrame =
    'cb1:Q0JNMQEAAQAAESIzRFVmd4iZqrvM3e7_AAAAAAAAASwBAAAAAAIAAAAAAAEBANqb9GIAAQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyAhIiMkJSYnKCkqKywtLi8wMTIzNDU2Nzg5Ojs8PT4_QEFCQ0RFRkdISUpLTE1OT1BRUlNUVVZXWFlaW1xdXl9gYWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXp7fH1-f4CBgoOEhYaHiImKi4yNjo-QkZKTlJWWl5iZmpucnZ6foKGio6SlpqeoqaqrrK2ur7CxsrO0tba3uLm6u7y9vr_AwcLDxMXGx8jJysvMzc7P0NHS09TV1tfY2drb3N3e3-Dh4uPk5ebn6Onq6-zt7u_w8fLz9PX29_j5-vv8_f7_';

BeamPackage _package(Uint8List payload, {BeamMode mode = BeamMode.public}) {
  return BeamPackage(
    manifest: BeamManifest(
      transferId: '00112233445566778899aabbccddeeff',
      mode: mode,
      fileName: 'beam.bin',
      mimeType: 'application/octet-stream',
      sizeBytes: payload.length,
      sha256Base64: base64Encode(sha256.convert(payload).bytes),
      createdAt: DateTime.utc(2026, 8, 15),
      senderFingerprint: '1234-5678',
      signatureBase64: 'signature',
    ),
    payload: payload,
  );
}

void main() {
  test('shared Rust/Dart golden frame remains wire-compatible', () {
    final frame = BeamFrame.decodeText(_sharedGoldenFrame);
    expect(frame.mode, BeamMode.public);
    expect(frame.systematic, isTrue);
    expect(frame.transferId, '00112233445566778899aabbccddeeff');
    expect(frame.originalLength, 300);
    expect(frame.blockSize, 256);
    expect(frame.sourceBlockCount, 2);
    expect(frame.seed, 0);
    expect(frame.degree, 1);
    expect(frame.payload, orderedEquals(List<int>.generate(256, (i) => i)));
    expect(frame.encodeText(), _sharedGoldenFrame);
  });

  test('frame text round-trips and detects corruption', () {
    final encoder = BeamEncoder(
      package: _package(Uint8List.fromList(utf8.encode('hello beam'))),
      blockSize: 256,
      random: Random(1),
    );
    final text = encoder.nextFrame().encodeText();
    final decoded = BeamFrame.decodeText(text);

    expect(decoded.transferId, '00112233445566778899aabbccddeeff');
    expect(decoded.systematic, isTrue);
    expect(decoded.payload, hasLength(256));

    final bytes = decoded.encodeBytes()..[bytesLastIndex(decoded)] ^= 1;
    expect(() => BeamFrame.decodeBytes(bytes), throwsFormatException);
  });

  test('systematic frames reconstruct a package out of order', () {
    final payload = Uint8List.fromList(
      List<int>.generate(4097, (index) => index % 251),
    );
    final encoder = BeamEncoder(
      package: _package(payload),
      blockSize: 256,
      random: Random(2),
    );
    final frames = List.generate(
      encoder.sourceBlockCount,
      (_) => encoder.nextFrame(),
    )..shuffle(Random(3));
    final decoder = BeamDecoder();
    for (final frame in frames) {
      decoder.addFrame(frame);
    }

    expect(decoder.progress.complete, isTrue);
    expect(decoder.package!.payload, payload);
  });

  test('repair frames recover dropped systematic frames', () {
    final payload = Uint8List.fromList(
      List<int>.generate(8192, (index) => (index * 17) & 0xff),
    );
    final encoder = BeamEncoder(
      package: _package(payload, mode: BeamMode.contactEncrypted),
      blockSize: 256,
      random: Random(4),
    );
    final decoder = BeamDecoder();
    final systematic = List.generate(
      encoder.sourceBlockCount,
      (_) => encoder.nextFrame(),
    );
    for (var index = 0; index < systematic.length; index++) {
      if (index % 5 != 0) decoder.addFrame(systematic[index]);
    }
    for (
      var attempts = 0;
      attempts < encoder.sourceBlockCount * 6 && !decoder.progress.complete;
      attempts++
    ) {
      decoder.addFrame(encoder.nextFrame());
    }

    expect(decoder.progress.complete, isTrue);
    expect(decoder.package!.manifest.mode, BeamMode.contactEncrypted);
    expect(decoder.package!.payload, payload);
  });

  test('decoder rejects frames from another transfer', () {
    final first = BeamEncoder(
      package: _package(Uint8List(300)),
      blockSize: 256,
      random: Random(5),
    );
    final otherPackage = BeamPackage(
      manifest: BeamManifest(
        transferId: 'ffeeddccbbaa99887766554433221100',
        mode: BeamMode.public,
        fileName: 'other.bin',
        mimeType: 'application/octet-stream',
        sizeBytes: 300,
        sha256Base64: base64Encode(sha256.convert(Uint8List(300)).bytes),
        createdAt: DateTime.utc(2026, 8, 15),
      ),
      payload: Uint8List(300),
    );
    final second = BeamEncoder(
      package: otherPackage,
      blockSize: 256,
      random: Random(6),
    );
    final decoder = BeamDecoder()..addFrame(first.nextFrame());

    expect(() => decoder.addFrame(second.nextFrame()), throwsFormatException);
  });
}

int bytesLastIndex(BeamFrame frame) => frame.encodeBytes().length - 1;
