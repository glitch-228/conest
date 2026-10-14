import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:image/image.dart' as img;

List<int> u32(int value, {bool little = false}) {
  final bytes = Uint8List(4);
  ByteData.sublistView(bytes).setUint32(0, value,
      little ? Endian.little : Endian.big);
  return bytes;
}

List<int> isoBox(String type, List<int> data) =>
    [...u32(data.length + 8), ...latin1.encode(type), ...data];

List<int> jpegSegment(int marker, List<int> data) =>
    [255, marker, (data.length + 2) >> 8, (data.length + 2) & 255, ...data];

Uint8List privacyJpeg() => Uint8List.fromList([
  255, 216,
  ...jpegSegment(0xe1, [
    ...latin1.encode('Exif\x00\x00'),
    0x4d, 0x4d, 0, 42, 0, 0, 0, 8,
    0, 1, 1, 0x12, 0, 3, 0, 0, 0, 1, 0, 6, 0, 0, 0, 0, 0, 0,
    ...latin1.encode('GPSLatitude 52.52'),
  ]),
  ...img.encodeJpg(img.Image(width: 4, height: 4)).sublist(2),
]);

Uint8List officeZip(Map<String, List<int>> entries) {
  final archive = Archive();
  for (final entry in entries.entries) {
    archive.addFile(entry.key == 'mimetype'
        ? ArchiveFile.noCompress(entry.key, entry.value.length, entry.value)
        : ArchiveFile.bytes(entry.key, entry.value));
  }
  return ZipEncoder().encodeBytes(archive);
}

Uint8List pdfObjects(List<String> objects, {String trailer = ''}) =>
    Uint8List.fromList(latin1.encode('%PDF-1.5\n${objects.join('\n')}\n'
        'trailer\n<< $trailer >>\nstartxref\n0\n%%EOF\n'));

String pdfStream(int id, String dictionary, List<int> data) =>
    '$id 0 obj\n<< /Length ${data.length} $dictionary >>\nstream\n'
    '${latin1.decode(data)}\nendstream\nendobj';

Uint8List partialPdf() => pdfObjects([
  pdfStream(1, '/Type /ObjStm /N 1 /First 4 /Filter /FlateDecode',
      zlib.encode(latin1.encode('2 0 << /Author (Alice) >>'))),
]);

Uint8List privacyHeif({bool duplicate = false, bool missing = false,
    bool wideLength = false, bool overflow = false, bool inIdat = false}) {
  final image = latin1.encode('IMAGE123');
  final exif = latin1.encode('EXIF-GPS');
  List<int> info(int id, String type) => isoBox('infe', [
    2, 0, 0, 0, 0, id, 0, 0, ...latin1.encode(type), 0,
  ]);
  final iinf = isoBox('iinf', [0, 0, 0, 0, 0, 2,
    ...info(1, 'hvc1'), ...info(duplicate ? 1 : 2, 'Exif'),
  ]);
  List<int> location(int id, int at, int size) => [
    0, id, if (inIdat) ...[0, 1], 0, 0, 0, 1, ...u32(at),
    if (wideLength) ...u32(overflow && id == 1 ? 0x7fffffff : 0),
    ...u32(overflow && id == 1 ? 0xffffffff : size),
  ];
  List<int> build(int imageAt, int exifAt) => [
    ...isoBox('ftyp', latin1.encode('heic\x00\x00\x00\x00mif1')),
    ...isoBox('meta', [0, 0, 0, 0, ...iinf,
      ...isoBox('iloc', [inIdat ? 1 : 0, 0, 0, 0,
        wideLength ? 0x48 : 0x44, 0, 0, missing || duplicate ? 1 : 2,
        ...location(1, imageAt, image.length),
        if (!missing && !duplicate) ...location(2, exifAt, exif.length),
      ]),
      if (inIdat) ...isoBox('idat', [...image, ...exif]),
    ]),
    if (!inIdat) ...isoBox('mdat', [...image, ...exif]),
  ];
  final draft = build(0, 0);
  final at = inIdat ? 0 : draft.length - image.length - exif.length;
  return Uint8List.fromList(build(at, at + image.length));
}

({Uint8List bytes, int videoAt, int metadataAt, int mediaEnd}) timedMp4({
  String handler = 'meta',
  String entry = 'gpmd',
  bool compact = false,
  bool wide = false,
  bool overlap = false,
  bool ambiguousTables = false,
  int repeatedSamples = 1,
}) {
  final video = latin1.encode('VIDEO123');
  final gps = latin1.encode('GPS52.52');
  List<int> track(String handler, String entry, int offset, int size,
      {bool metadata = false}) => isoBox('trak', isoBox('mdia', [
    ...isoBox('hdlr', [0, 0, 0, 0, 0, 0, 0, 0, ...latin1.encode(handler)]),
    ...isoBox('minf', isoBox('stbl', [
      ...isoBox('stsd', [0, 0, 0, 0, ...u32(1), ...isoBox(entry, List.filled(8, 0))]),
      ...isoBox(compact && metadata ? 'stz2' : 'stsz', compact && metadata
          ? [0, 0, 0, 0, 0, 0, 0, 4, ...u32(1), size << 4]
          : metadata && repeatedSamples > 1
              ? [0, 0, 0, 0, ...u32(size), ...u32(repeatedSamples)]
              : [0, 0, 0, 0, ...u32(0), ...u32(1), ...u32(size)]),
      ...isoBox(wide && metadata ? 'co64' : 'stco', [
        0, 0, 0, 0, ...u32(metadata ? repeatedSamples : 1),
        for (var i = 0; i < (metadata ? repeatedSamples : 1); i++) ...[
          if (wide && metadata) ...u32(0), ...u32(offset),
        ],
      ]),
      ...isoBox('stsc', [0, 0, 0, 0, ...u32(1), ...u32(1), ...u32(1), ...u32(1)]),
      if (metadata && ambiguousTables)
        ...isoBox('stz2', [0, 0, 0, 0, 0, 0, 0, 4, ...u32(1), size << 4]),
    ])),
  ]));
  List<int> build(int videoAt, int metadataAt) => [
    ...isoBox('ftyp', latin1.encode('isom\x00\x00\x00\x00')),
    ...isoBox('moov', [
      ...isoBox('uuid', [
        0xbe, 0x7a, 0xcf, 0xcb, 0x97, 0xa9, 0x42, 0xe8,
        0x9c, 0x71, 0x99, 0x94, 0x91, 0xe3, 0xaf, 0xac,
        ...latin1.encode('XMP-Alice'),
      ]),
      ...isoBox('sefd', latin1.encode('Samsung-location')),
      ...track('vide', 'avc1', videoAt, video.length),
      ...track(handler, entry, metadataAt, gps.length, metadata: true),
    ]),
    ...isoBox('mdat', [...video, ...gps]),
  ];
  final draft = build(0, 0);
  final videoAt = draft.length - video.length - gps.length;
  final metadataAt = videoAt + video.length;
  final media = build(videoAt, overlap ? videoAt : metadataAt);
  final trailerData = latin1.encode('Samsung-GPS-Alice');
  final directory = [
    ...latin1.encode('SEFH'), ...u32(101, little: true), ...u32(1, little: true),
    ...u32(1, little: true), ...u32(trailerData.length, little: true),
    ...u32(trailerData.length, little: true),
  ];
  return (bytes: Uint8List.fromList([
    ...media, ...trailerData, ...directory,
    ...u32(directory.length, little: true), ...latin1.encode('SEFT'),
  ]), videoAt: videoAt, metadataAt: metadataAt, mediaEnd: media.length);
}
