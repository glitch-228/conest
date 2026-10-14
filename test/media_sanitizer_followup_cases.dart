import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:conest/src/media_sanitizer.dart';
import 'package:conest/src/iso_media_sanitizer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'support/file_privacy_fixtures.dart';

void registerFilePrivacyFollowupTests() {
  group('Q4b privacy', () {
    late Directory root;
    setUp(() async { root = await Directory.systemTemp.createTemp('q4b-'); });
    tearDown(() => root.delete(recursive: true));
    Future<({SanitizeStatus status, Uint8List bytes})> clean(List<int> bytes) async {
      final file = await File('${root.path}/input').writeAsBytes(bytes);
      final status = await MediaSanitizer.sanitizeFile(file.path);
      return (status: status, bytes: await file.readAsBytes());
    }

    for (final handler in ['meta', 'text']) {
      for (final entry in ['gpmd', 'mebx', 'camm']) {
        test('MP4 $handler/$entry clears metadata, UUID and Samsung trailer', () async {
          final fixture = timedMp4(handler: handler, entry: entry);
          final result = await clean(fixture.bytes);
          expect(result.status, SanitizeStatus.cleaned);
          expect(result.bytes.length, fixture.bytes.length);
          expect(result.bytes.sublist(fixture.videoAt, fixture.metadataAt),
              fixture.bytes.sublist(fixture.videoAt, fixture.metadataAt));
          expect(result.bytes.sublist(fixture.metadataAt, fixture.mediaEnd),
              everyElement(0));
          expect(result.bytes.sublist(fixture.mediaEnd), everyElement(0));
          for (final marker in ['XMP-Alice', 'Samsung-location', 'GPS52.52']) {
            expect(latin1.decode(result.bytes), isNot(contains(marker)));
          }
          // stco offsets and each box length/header stay valid.
          for (var at = 0; at < fixture.mediaEnd;) {
            final size = ByteData.sublistView(result.bytes).getUint32(at);
            expect(size, greaterThanOrEqualTo(8));
            expect(size, ByteData.sublistView(fixture.bytes).getUint32(at));
            at += size;
            expect(at, lessThanOrEqualTo(fixture.mediaEnd));
          }
        });
      }
    }
    test('MP4 compact stz2 and co64 tables locate the metadata sample', () async {
      final fixture = timedMp4(compact: true, wide: true);
      final result = await clean(fixture.bytes);
      expect(result.status, SanitizeStatus.cleaned);
      expect(result.bytes.sublist(fixture.metadataAt, fixture.mediaEnd), everyElement(0));
      expect(result.bytes.sublist(fixture.videoAt, fixture.metadataAt),
          fixture.bytes.sublist(fixture.videoAt, fixture.metadataAt));
    });
    test('MP4 hostile metadata offsets cannot erase a video sample', () async {
      final fixture = timedMp4(overlap: true);
      final result = await clean(fixture.bytes);
      expect(result.status, SanitizeStatus.failed);
      expect(result.bytes, fixture.bytes, reason: 'validate before every write');
    });
    test('MP4 non-GPS text samples are kept', () async {
      final fixture = timedMp4(handler: 'text', entry: 'tx3g');
      final result = await clean(fixture.bytes);
      expect(result.status, SanitizeStatus.cleaned);
      expect(result.bytes.sublist(fixture.videoAt, fixture.mediaEnd),
          fixture.bytes.sublist(fixture.videoAt, fixture.mediaEnd));
    });
    test('MP4 duplicate alternative tables fail without changing the video', () async {
      final fixture = timedMp4(ambiguousTables: true);
      final result = await clean(fixture.bytes);
      expect(result.status, SanitizeStatus.failed);
      expect(result.bytes, fixture.bytes);
    });
    test('MP4 repeated metadata offsets are patched only once', () async {
      final fixture = timedMp4(repeatedSamples: 1000);
      final file = _CountingIsoFile(Uint8List.fromList(fixture.bytes), fixture.metadataAt);
      expect(await IsoMediaSanitizer(file, fixture.bytes.length).clean(), isTrue);
      expect(file.sampleReads, 1);
      expect(file.data.sublist(fixture.videoAt, fixture.metadataAt),
          fixture.bytes.sublist(fixture.videoAt, fixture.metadataAt));
    });
    for (final entry in [
      ('duplicate item ID', privacyHeif(duplicate: true)),
      ('missing metadata location', privacyHeif(missing: true)),
      ('overflowing image extent', privacyHeif(wideLength: true, overflow: true)),
    ]) {
      test('HEIF ${entry.$1} fails before rewriting any pixels', () async {
        final result = await clean(entry.$2);
        expect(result.status, SanitizeStatus.failed);
        expect(result.bytes, entry.$2);
      });
    }
    test('HEIF metadata in idat is cleared while image bytes remain intact', () async {
      final input = privacyHeif(inIdat: true);
      final result = await clean(input);
      expect(result.status, SanitizeStatus.cleaned);
      expect(latin1.decode(result.bytes), contains('IMAGE123'));
      expect(latin1.decode(result.bytes), isNot(contains('EXIF-GPS')));
      expect(result.bytes.length, input.length);
    });

    test('DOCX tracked changes, comments, people and embedded GPS are cleaned', () async {
      final bytes = officeZip({
        '[Content_Types].xml': utf8.encode('<Types/>'),
        'word/document.xml': utf8.encode('<w:document xmlns:w="urn:w"><w:ins '
            'w:author="Alice" w:date="2026-10-14"><w:r>Hello</w:r></w:ins>'
            '<w:rPrChange w:author="Alice" w:initials="AA"/></w:document>'),
        'word/comments.xml': utf8.encode('<w:comments xmlns:w="urn:w">'
            '<w:comment w:id="0" w:author="Alice" w:initials="AA" '
            'w:date="2026-10-14">Comment body</w:comment></w:comments>'),
        'word/people.xml': utf8.encode('<w:people xmlns:w="urn:w"><w:person '
            'w:author="Alice"><w:presenceInfo w:userId="Alice@example.test" '
            'w:providerId="provider"/></w:person></w:people>'),
        'word/media/photo.jpg': privacyJpeg(),
      });
      final result = await clean(bytes);
      expect(result.status, SanitizeStatus.cleaned);
      final archive = ZipDecoder().decodeBytes(result.bytes, verify: true);
      for (final file in archive.files) {
        final text = latin1.decode(file.readBytes()!);
        expect(text, isNot(contains('Alice')), reason: file.name);
        expect(text, isNot(contains('2026')), reason: file.name);
        expect(text, isNot(contains('GPSLatitude')), reason: file.name);
      }
      expect(utf8.decode(archive.findFile('word/document.xml')!.readBytes()!), contains('Hello'));
      final image = archive.findFile('word/media/photo.jpg')!.readBytes()!;
      expect(img.decodeJpgExif(image)!.imageIfd.orientation, 6);
    });
    for (final parts in [
      {'xl/comments1.xml': '<comments><authors><author>Alice</author></authors>'
          '<comment authorId="0">Keep comment</comment></comments>',
       'xl/persons/person.xml': '<persons><person id="1" displayName="Alice" '
          'userId="Alice@example.test" providerId="provider"/></persons>'},
      {'ppt/commentAuthors.xml': '<cmAuthorLst><cmAuthor id="0" name="Alice" '
          'initials="AA"/></cmAuthorLst>',
       'ppt/comments/comment1.xml': '<cmLst><cm authorId="0" dt="2026-10-14">'
          '<text>Keep comment</text></cm></cmLst>'},
    ]) {
      test('${parts.keys.first.split('/').first} comment identities and dates are cleaned', () async {
        final result = await clean(officeZip({
          '[Content_Types].xml': utf8.encode('<Types/>'),
          for (final part in parts.entries) part.key: utf8.encode(part.value),
        }));
        expect(result.status, SanitizeStatus.cleaned);
        final archive = ZipDecoder().decodeBytes(result.bytes, verify: true);
        for (final file in archive.files) {
          final text = utf8.decode(file.readBytes()!);
          expect(text, isNot(contains('Alice')));
          expect(text, isNot(contains('2026')));
        }
      });
    }
    test('ODF change-info and annotation identities go, document content stays', () async {
      final result = await clean(officeZip({
        'mimetype': utf8.encode('application/vnd.oasis.opendocument.text'),
        'content.xml': utf8.encode('<office:document-content xmlns:office="urn:o" '
            'xmlns:dc="urn:dc"><office:change-info><dc:creator>Alice</dc:creator>'
            '<dc:date>2026-10-14</dc:date></office:change-info><office:annotation>'
            '<dc:creator>Alice</dc:creator><dc:date>2026-10-14</dc:date>'
            '<p>Keep comment</p></office:annotation><p>Keep body</p></office:document-content>'),
        'Pictures/photo.jpg': privacyJpeg(),
      }));
      expect(result.status, SanitizeStatus.cleaned);
      final archive = ZipDecoder().decodeBytes(result.bytes, verify: true);
      final text = utf8.decode(archive.findFile('content.xml')!.readBytes()!);
      expect(text, isNot(contains('Alice')));
      expect(text, isNot(contains('2026')));
      expect(text, contains('Keep comment'));
      expect(text, contains('Keep body'));
      expect(archive.files.first.name, 'mimetype');
      expect(latin1.decode(archive.findFile('Pictures/photo.jpg')!.readBytes()!),
          isNot(contains('GPSLatitude')));
    });
    test('Office embedded ISO images cannot silently retain GPS', () async {
      final input = officeZip({
        '[Content_Types].xml': utf8.encode('<Types/>'),
        'word/media/photo.heic': privacyHeif(),
      });
      final result = await clean(input);
      expect(result.status, SanitizeStatus.failed);
      expect(result.bytes, input);
    });

    test('PDF cleans only Info and Metadata streams, retaining page strings', () async {
      final page = latin1.encode('/Author (Alice in page content) <x:xmpmeta>Keep</x:xmpmeta>');
      final xmp = latin1.encode('<x:xmpmeta>Alice GPS</x:xmpmeta>');
      final input = pdfObjects([
        '1 0 obj\n<< /Author (Alice) /Producer <416C696365> /Custom (Private) >>\nendobj',
        pdfStream(2, '/Type /Metadata /Subtype /XML', xmp),
        pdfStream(3, '', page),
        '4 0 obj\n<< /Title (Visible page title) >>\nendobj',
      ], trailer: '/Info 1 0 R');
      final result = await clean(input);
      expect(result.status, SanitizeStatus.cleaned);
      expect(result.bytes.length, input.length);
      final text = latin1.decode(result.bytes);
      expect(text, isNot(contains('/Author (Alice)')));
      expect(text, isNot(contains('416C696365')));
      expect(text, isNot(contains('Private')));
      expect(text, contains(latin1.decode(page)));
      expect(text, contains('Visible page title'));
      expect(text, isNot(contains(latin1.decode(xmp))));
    });
    test('PDF JPEG APP1 payload is zeroed without changing any stream offset', () async {
      final jpeg = privacyJpeg();
      final input = pdfObjects([pdfStream(1, '/Subtype /Image /Filter /DCTDecode', jpeg)]);
      final result = await clean(input);
      expect(result.status, SanitizeStatus.cleaned);
      expect(result.bytes.length, input.length);
      final start = latin1.decode(input).indexOf('stream\n') + 7;
      final end = start + 4 + ((jpeg[4] << 8) | jpeg[5]);
      expect(result.bytes.sublist(start + 6, end), everyElement(0));
      expect(result.bytes.sublist(0, start + 6), input.sublist(0, start + 6));
      expect(result.bytes.sublist(end), input.sublist(end));
    });
    test('PDF compressed object metadata requires partial consent', () async {
      final result = await clean(partialPdf());
      expect(result.status, SanitizeStatus.partial);
      final safe = pdfObjects([pdfStream(1, '/Type /ObjStm /Filter /FlateDecode',
          zlib.encode(latin1.encode('2 0 << /Count 1 >>')))]);
      expect((await clean(safe)).status, SanitizeStatus.clean);
    });
    test('PDF escaped metadata names and XMP in object streams require partial consent', () async {
      for (final text in ['/Auth#6fr (Alice)', '<?xpacket begin=""?> GPS']) {
        final input = pdfObjects([pdfStream(1, '/Type /ObjStm /Filter /FlateDecode',
            zlib.encode(latin1.encode(text)))]);
        expect((await clean(input)).status, SanitizeStatus.partial);
      }
    });
    test('PDF inflate output cap fails closed', () async {
      final input = pdfObjects([pdfStream(1, '/Type /ObjStm /Filter /FlateDecode',
          zlib.encode(List.filled(8 * 1024 * 1024 + 1, 32)))]);
      expect((await clean(input)).status, SanitizeStatus.failed);
    });
    test('PDF incremental revisions remove each old Info and XMP version', () async {
      final old = pdfObjects([
        '1 0 obj\n<< /Author (Alice-old) >>\nendobj',
        pdfStream(2, '/Type /Metadata', latin1.encode('Alice-XMP-old')),
      ], trailer: '/Info 1 0 R');
      final appended = latin1.encode('\n1 0 obj\n<< /Author (Bob-new) >>\nendobj\n'
          '${pdfStream(2, '/Type /Metadata', latin1.encode('Bob-XMP-new'))}\n'
          'trailer\n<< /Info 1 0 R >>\n%%EOF\n');
      final result = await clean([...old, ...appended]);
      expect(result.status, SanitizeStatus.cleaned);
      expect(result.bytes.length, old.length + appended.length);
      expect(latin1.decode(result.bytes), isNot(contains('Alice')));
      expect(latin1.decode(result.bytes), isNot(contains('Bob')));
    });
    test('PDF indirect stream Type and Filter are resolved before cleaning', () async {
      final input = pdfObjects([
        pdfStream(1, '/Filter 3 0 R', privacyJpeg()),
        pdfStream(2, '/Type 4 0 R', latin1.encode('Alice-XMP')),
        '3 0 obj\n/DCTDecode\nendobj',
        '4 0 obj\n/Metadata\nendobj',
      ]);
      final result = await clean(input);
      expect(result.status, SanitizeStatus.cleaned);
      expect(result.bytes.length, input.length);
      expect(latin1.decode(result.bytes), isNot(contains('GPSLatitude')));
      expect(latin1.decode(result.bytes), isNot(contains('Alice-XMP')));
    });
    test('PDF changed indirect stream parameters fail instead of hiding an old JPEG', () async {
      final old = pdfObjects([
        pdfStream(1, '/Filter 5 0 R', privacyJpeg()),
        '5 0 obj\n/DCTDecode\nendobj',
      ]);
      final input = [...old, ...latin1.encode(
          '\n${pdfStream(1, '/Filter 5 0 R', zlib.encode([1, 2, 3]))}\n'
          '5 0 obj\n/FlateDecode\nendobj\ntrailer\n<< >>\n%%EOF\n')];
      final result = await clean(input);
      expect(result.status, SanitizeStatus.failed);
      expect(result.bytes, input);
    });
    test('PDF custom Info name and numeric values are removed in place', () async {
      final input = pdfObjects([
        '1 0 obj\n<< /PrivatePlace /Berlin /Latitude 52.52 /Flags [ /Alice 123 ] >>\nendobj',
      ], trailer: '/Info 1 0 R');
      final result = await clean(input);
      expect(result.status, SanitizeStatus.cleaned);
      expect(result.bytes.length, input.length);
      for (final marker in ['Berlin', '52.52', 'Alice', '123']) {
        expect(latin1.decode(result.bytes), isNot(contains(marker)));
      }
    });
    test('PDF Info shared with page resources requires consent without altering the font', () async {
      final input = pdfObjects([
        '1 0 obj\n<< /Type /Page /Resources << /Font << /F1 3 0 R >> >> >>\nendobj',
        '3 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Author (Alice) >>\nendobj',
      ], trailer: '/Info 3 0 R');
      final result = await clean(input);
      expect(result.status, SanitizeStatus.partial);
      expect(result.bytes, input);
    });
    test('PDF indirect Info aliases require consent without altering a shared target', () async {
      final input = pdfObjects([
        '1 0 obj\n3 0 R\nendobj',
        '3 0 obj\n<< /Differences [65 /A /B] >>\nendobj',
        '4 0 obj\n<< /Encoding 3 0 R >>\nendobj',
      ], trailer: '/Info 1 0 R');
      final result = await clean(input);
      expect(result.status, SanitizeStatus.partial);
      expect(result.bytes, input);
    });
    for (final reference in ['003 00 R', '3 % comment\n0 R', '3\x000\x00R', '+3 +0 R', '3 -0 R']) {
      test('PDF compressed shared encoding reference ${reference.codeUnits} requires consent', () async {
        final input = pdfObjects([
          '3 0 obj\n<< /Differences [65 /A /B] >>\nendobj',
          pdfStream(4, '/Type /ObjStm /Filter /FlateDecode',
              zlib.encode(latin1.encode('5 0 << /Encoding $reference >>'))),
        ], trailer: '/Info 3 0 R');
        final result = await clean(input);
        expect(result.status, SanitizeStatus.partial);
        expect(result.bytes, input);
      });
    }
    test('PDF indirect parameter graph is bounded even with repeated references', () async {
      final input = pdfObjects([
        pdfStream(50, '/Filter 1 0 R', [1, 2, 3]),
        for (var i = 1; i < 20; i++)
          '$i 0 obj\n[ ${List.filled(8, '${i + 1} 0 R').join(' ')} ]\nendobj',
        '20 0 obj\n/DCTDecode\nendobj',
      ]);
      expect((await clean(input)).status, SanitizeStatus.failed);
    }, timeout: const Timeout(Duration(seconds: 5)));
    test('PDF oversized name token fails quickly', () async {
      final input = pdfObjects([
        '1 0 obj\n<< /${List.filled(5000, 'A').join()} 1 >>\nendobj',
      ]);
      expect((await clean(input)).status, SanitizeStatus.failed);
    });

    test('PNG removes caBX and all bytes after IEND, even without other metadata', () async {
      final png = img.encodePng(img.Image(width: 2, height: 2));
      final payload = latin1.encode('C2PA-Alice');
      final type = latin1.encode('caBX');
      final chunk = [...u32(payload.length), ...type, ...payload, ...u32(getCrc32([...type, ...payload]))];
      final end = png.length - 12;
      final input = [...png.sublist(0, end), ...chunk, ...png.sublist(end), ...latin1.encode('GPS-after-IEND')];
      expect((await clean(input)).bytes, png);
      final trailing = await clean([...png, ...latin1.encode('GPS')]);
      expect(trailing.status, SanitizeStatus.cleaned);
      expect(trailing.bytes, png);
    });
    test('JPEG removes both thumbnail forms while preserving orientation, ICC and scan', () async {
      final jpeg = privacyJpeg();
      final jfif = [...latin1.encode('JFIF\x00'), 1, 2, 0, 0, 1, 0, 1, 1, 1, 11, 22, 33];
      final jfxx = latin1.encode('JFXX\x00THUMB-Alice');
      final icc = latin1.encode('ICC_PROFILE\x00Profile123');
      final result = await clean([255, 216,
        ...jpegSegment(0xe0, jfif), ...jpegSegment(0xe0, jfxx),
        ...jpegSegment(0xe2, icc), ...jpeg.sublist(2),
      ]);
      expect(result.status, SanitizeStatus.cleaned);
      expect(latin1.decode(result.bytes), isNot(contains('JFXX')));
      expect(latin1.decode(result.bytes), contains('ICC_PROFILE\x00Profile123'));
      expect(result.bytes.sublist(18, 20), [0, 0]);
      expect(result.bytes.sublist(4, 6), [0, 16]);
      expect(img.decodeJpgExif(result.bytes)!.imageIfd.orientation, 6);
      int scan(List<int> bytes) {
        for (var at = 0; at + 1 < bytes.length; at++) {
          if (bytes[at] == 255 && bytes[at + 1] == 0xda) { return at; }
        }
        return -1;
      }
      expect(result.bytes.sublist(scan(result.bytes)), jpeg.sublist(scan(jpeg)));
    });
    test('ZIP expansion ratio and entry count caps fail closed', () async {
      final bomb = officeZip({
        '[Content_Types].xml': utf8.encode('<Types/>'),
        'word/document.xml': utf8.encode('<document><p>${List.filled(1024 * 1024, 'A').join()}</p></document>'),
      });
      expect((await clean(bomb)).status, SanitizeStatus.failed);
      final entries = officeZip({
        '[Content_Types].xml': utf8.encode('<Types/>'),
        for (var i = 0; i < 2048; i++) 'file-$i': [1],
      });
      expect((await clean(entries)).status, SanitizeStatus.failed);
    });
    test('ISO nesting, global box count and truncated layouts fail closed', () async {
      var nested = isoBox('moov', []);
      for (var i = 0; i < 33; i++) {
        nested = isoBox('moov', nested);
      }
      expect((await clean(nested)).status, SanitizeStatus.failed);
      final many = [
        ...isoBox('ftyp', latin1.encode('isom')),
        for (var i = 0; i < 20000; i++) ...isoBox('free', []),
      ];
      expect((await clean(many)).status, SanitizeStatus.failed);
      expect((await clean([...isoBox('ftyp', latin1.encode('isom')), 1, 2])).status,
          SanitizeStatus.failed);
    });
    test('sanitizeFile never throws on a missing path or directory', () async {
      expect(await MediaSanitizer.sanitizeFile('${root.path}/missing'), SanitizeStatus.failed);
      expect(await MediaSanitizer.sanitizeFile(root.path), SanitizeStatus.failed);
    });
  });
}

class _CountingIsoFile implements RandomAccessFile {
  _CountingIsoFile(this.data, this.sampleAt);
  final Uint8List data;
  final int sampleAt;
  var at = 0;
  var sampleReads = 0;

  @override
  Future<RandomAccessFile> setPosition(int position) async { at = position; return this; }

  @override
  Future<int> position() async => at;

  @override
  Future<Uint8List> read(int count) async {
    if (at == sampleAt) { sampleReads++; }
    final bytes = Uint8List.fromList(data.sublist(at, at + count));
    at += count;
    return bytes;
  }

  @override
  Future<RandomAccessFile> writeFrom(List<int> buffer, [int start = 0, int? end]) async {
    final bytes = buffer.sublist(start, end);
    data.setAll(at, bytes);
    at += bytes.length;
    return this;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
