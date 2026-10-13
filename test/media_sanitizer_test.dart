import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:conest/src/media_sanitizer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

bool has(List<int> haystack, String needle) {
  final bytes = latin1.encode(needle);
  outer:
  for (var index = 0; index + bytes.length <= haystack.length; index++) {
    for (var at = 0; at < bytes.length; at++) {
      if (haystack[index + at] != bytes[at]) continue outer;
    }
    return true;
  }
  return false;
}

List<int> box(String type, List<int> content) {
  final size = content.length + 8;
  return [
    (size >> 24) & 0xff,
    (size >> 16) & 0xff,
    (size >> 8) & 0xff,
    size & 0xff,
    ...latin1.encode(type),
    ...content,
  ];
}

img.Image picture() {
  final image = img.Image(width: 16, height: 8);
  for (var y = 0; y < 8; y++) {
    for (var x = 0; x < 16; x++) {
      image.setPixelRgb(x, y, x * 15, y * 30, 128);
    }
  }
  return image;
}

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('conest-sanitize');
  });

  tearDown(() => temp.delete(recursive: true));

  Future<(SanitizeStatus, Uint8List)> run(List<int> data) async {
    final file = File('${temp.path}/f')..writeAsBytesSync(data);
    final status = await MediaSanitizer.sanitizeFile(file.path);
    return (status, file.readAsBytesSync());
  }

  test(
    'JPEG: EXIF with GPS, XMP, IPTC and comments go, orientation stays',
    () async {
      final jpeg = img.encodeJpg(picture());
      // An EXIF block (little-endian) with Orientation 6 and a GPS marker.
      final tiff = [
        0x49, 0x49, 0x2a, 0x00, 0x08, 0x00, 0x00, 0x00, //
        0x01, 0x00, // one entry
        0x12, 0x01, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00, 0x06, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        ...latin1.encode('GPSLatitude 52.5200'),
      ];
      List<int> segment(int marker, List<int> body) => [
        0xff,
        marker,
        (body.length + 2) >> 8,
        (body.length + 2) & 0xff,
        ...body,
      ];
      final dirty = [
        0xff,
        0xd8,
        ...segment(0xe1, [...latin1.encode('Exif\u0000\u0000'), ...tiff]),
        ...segment(
          0xe1,
          latin1.encode(
            'http://ns.adobe.com/xap/1.0/\u0000<x:xmpmeta>Jane</x:xmpmeta>',
          ),
        ),
        ...segment(0xed, latin1.encode('Photoshop 3.0\u0000IPTC Jane')),
        ...segment(0xfe, latin1.encode('taken at home')),
        ...jpeg.sublist(2),
        ...latin1.encode('appended thumbnail Exif GPS'),
      ];
      final (status, cleaned) = await run(dirty);
      expect(status, SanitizeStatus.cleaned);
      for (final text in ['GPSLatitude', 'Jane', 'taken at home', 'appended']) {
        expect(has(cleaned, text), isFalse, reason: text);
      }
      expect(has(cleaned, 'Exif'), isTrue, reason: 'orientation kept');
      // The picture data is untouched: the same bytes from the scan on.
      int scan(List<int> data) {
        for (var index = 0; index + 1 < data.length; index++) {
          if (data[index] == 0xff && data[index + 1] == 0xda) return index;
        }
        return -1;
      }

      final end = jpeg.length;
      expect(cleaned.sublist(scan(cleaned)), jpeg.sublist(scan(jpeg), end));
      expect(img.decodeJpgExif(cleaned)!.imageIfd.orientation, 6);
      final decoded = img.decodeJpg(cleaned)!;
      expect(decoded.width, 8, reason: 'shown turned, as the camera meant');
      // Clean already: left as it is.
      final (again, same) = await run(jpeg);
      expect(again, SanitizeStatus.clean);
      expect(same, jpeg);
    },
  );

  test('PNG: text, EXIF and time chunks go', () async {
    final png = img.encodePng(picture());
    List<int> chunk(String type, List<int> data) {
      final typed = [...latin1.encode(type), ...data];
      final crc = getCrc32(typed);
      return [
        ...[
          (data.length >> 24) & 0xff,
          (data.length >> 16) & 0xff,
          (data.length >> 8) & 0xff,
          data.length & 0xff,
        ],
        ...typed,
        (crc >> 24) & 0xff,
        (crc >> 16) & 0xff,
        (crc >> 8) & 0xff,
        crc & 0xff,
      ];
    }

    final ihdrEnd = 8 + 25;
    final dirty = [
      ...png.sublist(0, ihdrEnd),
      ...chunk('tEXt', latin1.encode('Author\u0000Jane')),
      ...chunk('eXIf', latin1.encode('MM GPS')),
      ...chunk('tIME', [7, 234, 10, 13, 9, 0, 0]),
      ...png.sublist(ihdrEnd),
    ];
    final (status, cleaned) = await run(dirty);
    expect(status, SanitizeStatus.cleaned);
    expect(has(cleaned, 'Jane'), isFalse);
    expect(has(cleaned, 'GPS'), isFalse);
    expect(cleaned, png);
  });

  test('GIF: comments and unknown application blocks go', () async {
    final gif = img.encodeGif(picture());
    final screenEnd =
        13 + ((gif[10] & 0x80) != 0 ? 3 * (1 << ((gif[10] & 7) + 1)) : 0);
    final comment = [0x21, 0xfe, 4, ...latin1.encode('Jane'), 0];
    final xmp = [
      0x21,
      0xff,
      11,
      ...latin1.encode('XMP DataXMP'),
      4,
      ...latin1.encode('Jane'),
      0,
    ];
    final dirty = [
      ...gif.sublist(0, screenEnd),
      ...comment,
      ...xmp,
      ...gif.sublist(screenEnd),
    ];
    final (status, cleaned) = await run(dirty);
    expect(status, SanitizeStatus.cleaned);
    expect(has(cleaned, 'Jane'), isFalse);
    expect(cleaned, gif);
  });

  test('WebP: EXIF and XMP chunks go, and VP8X no longer names them', () async {
    List<int> chunk(String type, List<int> data) => [
      ...latin1.encode(type),
      data.length & 0xff,
      (data.length >> 8) & 0xff,
      0,
      0,
      ...data,
      if (data.length.isOdd) 0,
    ];
    final body = [
      ...chunk('VP8X', [0x0c, 0, 0, 0, 15, 0, 0, 7, 0, 0]),
      ...chunk('VP8L', [1, 2, 3, 4, 5]),
      ...chunk('EXIF', latin1.encode('GPS 52.52')),
      ...chunk('XMP ', latin1.encode('<x>Jane</x>')),
    ];
    final size = body.length + 4;
    final dirty = [
      ...latin1.encode('RIFF'),
      size & 0xff,
      (size >> 8) & 0xff,
      0,
      0,
      ...latin1.encode('WEBP'),
      ...body,
    ];
    final (status, cleaned) = await run(dirty);
    expect(status, SanitizeStatus.cleaned);
    expect(has(cleaned, 'GPS'), isFalse);
    expect(has(cleaned, 'Jane'), isFalse);
    expect(cleaned[20] & 0x0c, 0, reason: 'VP8X flags');
    final riff = ByteData.sublistView(
      cleaned,
      4,
      8,
    ).getUint32(0, Endian.little);
    expect(riff, cleaned.length - 8);
  });

  test('MP4: location and times go, the same size, media untouched', () async {
    final mvhd = box('mvhd', [
      0,
      0,
      0,
      0,
      0xde,
      0xad,
      0xbe,
      0xef,
      0xca,
      0xfe,
      0xba,
      0xbe,
      0,
      0,
      3,
      0xe8,
      0,
      0,
      0,
      10,
    ]);
    final udta = box('udta', box('©xyz', latin1.encode('+52.5200+013.4050/')));
    final appleMeta = box('meta', [
      0,
      0,
      0,
      0,
      ...box('keys', latin1.encode('com.apple.quicktime.location.ISO6709')),
    ]);
    final trak = box('trak', [
      ...box('tkhd', [
        0,
        0,
        0,
        3,
        0x11,
        0x22,
        0x33,
        0x44,
        0x55,
        0x66,
        0x77,
        0x88,
        0,
        0,
        0,
        1,
      ]),
      ...box('udta', latin1.encode('Jane phone')),
      ...box(
        'mdia',
        box('mdhd', [
          0,
          0,
          0,
          0,
          0x12,
          0x34,
          0x56,
          0x78,
          0x9a,
          0xbc,
          0xde,
          0xf0,
        ]),
      ),
    ]);
    final media = latin1.encode('MEDIA-FRAMES-12345');
    final dirty = [
      ...box('ftyp', latin1.encode('isom\u0000\u0000\u0002\u0000isom')),
      ...box('moov', [...mvhd, ...udta, ...trak, ...appleMeta]),
      ...box('mdat', media),
    ];
    final (status, cleaned) = await run(dirty);
    expect(status, SanitizeStatus.cleaned);
    expect(cleaned.length, dirty.length);
    for (final text in ['+52.5200', 'Jane', 'ISO6709', 'udta']) {
      expect(has(cleaned, text), isFalse, reason: text);
    }
    expect(has(cleaned, 'MEDIA-FRAMES-12345'), isTrue);
    expect(has(cleaned, 'moov'), isTrue);
    for (final stamp in [
      [0xde, 0xad],
      [0x11, 0x22],
      [0x12, 0x34],
    ]) {
      expect(has(cleaned, latin1.decode(stamp)), isFalse);
    }
  });

  test('HEIC: the Exif item is blanked, the image item kept', () async {
    final image = latin1.encode('IMAGE-DATA');
    final exif = latin1.encode('EXIF-GPS-52.52');
    List<int> infe(int id, String type) =>
        box('infe', [2, 0, 0, 0, 0, id, 0, 0, ...latin1.encode(type), 0]);
    final iinf = box('iinf', [
      0,
      0,
      0,
      0,
      0,
      2,
      ...infe(1, 'hvc1'),
      ...infe(2, 'Exif'),
    ]);
    final ftyp = box(
      'ftyp',
      latin1.encode('heic\u0000\u0000\u0000\u0000mif1heic'),
    );
    // iloc v0: offsets and lengths of 4 bytes, no base; filled in below.
    List<int> iloc(int imageAt, int exifAt) => box('iloc', [
      0,
      0,
      0,
      0,
      0x44,
      0x00,
      0,
      2,
      0,
      1,
      0,
      0,
      0,
      1,
      ..._u32(imageAt),
      ..._u32(image.length),
      0,
      2,
      0,
      0,
      0,
      1,
      ..._u32(exifAt),
      ..._u32(exif.length),
    ]);
    List<int> build(int imageAt, int exifAt) => [
      ...ftyp,
      ...box('meta', [
        0,
        0,
        0,
        0,
        ...box('hdlr', [0, 0, 0, 0, 0, 0, 0, 0, ...latin1.encode('pict')]),
        ...iinf,
        ...iloc(imageAt, exifAt),
      ]),
      ...box('mdat', [...image, ...exif]),
    ];
    final draft = build(0, 0);
    final mdatData = draft.length - image.length - exif.length;
    final dirty = build(mdatData, mdatData + image.length);
    final (status, cleaned) = await run(dirty);
    expect(status, SanitizeStatus.cleaned);
    expect(has(cleaned, 'EXIF-GPS'), isFalse);
    expect(has(cleaned, 'IMAGE-DATA'), isTrue);
    expect(has(cleaned, 'meta'), isTrue, reason: 'HEIF needs its meta');
  });

  test('Office and OpenDocument files lose authors, keep content', () async {
    final docx = Archive()
      ..addFile(
        ArchiveFile.bytes('[Content_Types].xml', utf8.encode('<Types/>')),
      )
      ..addFile(
        ArchiveFile.bytes(
          'word/document.xml',
          utf8.encode('<w:document>Hello</w:document>'),
        ),
      )
      ..addFile(
        ArchiveFile.bytes(
          'docProps/core.xml',
          utf8.encode(
            '<cp:coreProperties><dc:creator>Jane Doe</dc:creator><cp:lastModifiedBy>Jane</cp:lastModifiedBy><dcterms:created xsi:type="dcterms:W3CDTF">2026-01-01</dcterms:created></cp:coreProperties>',
          ),
        ),
      )
      ..addFile(
        ArchiveFile.bytes(
          'docProps/app.xml',
          utf8.encode(
            '<Properties><Company>Acme</Company><Pages>1</Pages></Properties>',
          ),
        ),
      );
    final (status, cleaned) = await run(ZipEncoder().encodeBytes(docx));
    expect(status, SanitizeStatus.cleaned);
    final read = ZipDecoder().decodeBytes(cleaned);
    String text(String name) => utf8.decode(read.findFile(name)!.readBytes()!);
    expect(text('docProps/core.xml'), isNot(contains('Jane')));
    expect(text('docProps/core.xml'), isNot(contains('2026')));
    expect(text('docProps/app.xml'), isNot(contains('Acme')));
    expect(text('docProps/app.xml'), contains('<Pages>1</Pages>'));
    expect(text('word/document.xml'), contains('Hello'));

    final odt = Archive()
      ..addFile(
        ArchiveFile.noCompress(
          'mimetype',
          39,
          utf8.encode('application/vnd.oasis.opendocument.text'),
        ),
      )
      ..addFile(
        ArchiveFile.bytes(
          'content.xml',
          utf8.encode('<office:document-content>Hi</office:document-content>'),
        ),
      )
      ..addFile(
        ArchiveFile.bytes(
          'meta.xml',
          utf8.encode(
            '<office:document-meta><office:meta><meta:initial-creator>Jane</meta:initial-creator></office:meta></office:document-meta>',
          ),
        ),
      );
    final (odtStatus, odtCleaned) = await run(ZipEncoder().encodeBytes(odt));
    expect(odtStatus, SanitizeStatus.cleaned);
    final odtRead = ZipDecoder().decodeBytes(odtCleaned);
    expect(odtRead.files.first.name, 'mimetype');
    expect(
      utf8.decode(odtRead.findFile('meta.xml')!.readBytes()!),
      isNot(contains('Jane')),
    );

    // Other zips are not touched.
    final plain = Archive()
      ..addFile(ArchiveFile.bytes('a.txt', utf8.encode('x')));
    expect(
      (await run(ZipEncoder().encodeBytes(plain))).$1,
      SanitizeStatus.unsupported,
    );
  });

  test('PDF: information strings and XMP are blanked in place', () async {
    const pdf =
        '%PDF-1.4\n1 0 obj\n<< /Author (Jane \\(J\\) Doe) /Producer <4A616E65> '
        '/Title (Plan) >>\nendobj\n2 0 obj\n<< /Type /Metadata >>\nstream\n'
        '<x:xmpmeta xmlns:x="adobe:ns:meta/">Jane</x:xmpmeta>\nendstream\nendobj\n%%EOF\n';
    final (status, cleaned) = await run(latin1.encode(pdf));
    expect(status, SanitizeStatus.cleaned);
    expect(cleaned.length, pdf.length);
    final text = latin1.decode(cleaned);
    expect(text, isNot(contains('Jane')));
    expect(text, isNot(contains('4A616E65')));
    expect(text, contains('/Author ('));
    expect(text, contains('endstream'));
  });

  test('damaged files report a failure instead of throwing', () async {
    // A HEIF with an Exif item whose locations are cut short.
    final brokenHeic = [
      ...box('ftyp', latin1.encode('heic\u0000\u0000\u0000\u0000mif1heic')),
      ...box('meta', [
        0,
        0,
        0,
        0,
        ...box('iinf', [
          0,
          0,
          0,
          0,
          0,
          1,
          ...box('infe', [2, 0, 0, 0, 0, 1, 0, 0, ...latin1.encode('Exif'), 0]),
        ]),
        ...box('iloc', [0, 0, 0, 0, 0x44, 0x00, 0, 1, 0, 1]),
      ]),
    ];
    expect((await run(brokenHeic)).$1, SanitizeStatus.failed);
    final brokenZip = [0x50, 0x4b, 0x03, 0x04, ...List.filled(40, 7)];
    // Not even a readable zip: whatever it is, nothing was cleaned.
    expect(
      (await run(brokenZip)).$1,
      isIn([SanitizeStatus.failed, SanitizeStatus.unsupported]),
    );
    // A JPEG whose first segment claims more than there is.
    final brokenJpeg = [0xff, 0xd8, 0xff, 0xe1, 0x00, 0x40, 0x45, 0x78];
    expect((await run(brokenJpeg)).$1, SanitizeStatus.failed);
  });

  test('unknown files are left alone', () async {
    final data = utf8.encode('just some text');
    final (status, same) = await run(data);
    expect(status, SanitizeStatus.unsupported);
    expect(same, data);
  });
}

List<int> _u32(int value) => [
  (value >> 24) & 0xff,
  (value >> 16) & 0xff,
  (value >> 8) & 0xff,
  value & 0xff,
];
