import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import 'metadata_limits.dart';

/// ZIP directory and actual inflate limits are checked before rewriting.
abstract final class OfficeMetadataSanitizer {
  static const maxEntries = 2048;
  static const maxExpandedBytes = 128 * 1024 * 1024;
  static const maxEntryBytes = 32 * 1024 * 1024;
  static const maxExpansionRatio = 100;
  static const maxXmlBytes = 4 * 1024 * 1024;
  static const epoch = '1970-01-01T00:00:00Z';

  /// Classify oversized ZIPs from a bounded directory, without inflation.
  static Future<bool> isDocumentFile(RandomAccessFile file, int length) async {
    final tailSize = length.clamp(0, 65557);
    await file.setPosition(length - tailSize);
    final tail = await file.read(tailSize);
    final view = ByteData.sublistView(tail);
    var end = -1;
    for (var at = tail.length - 22; at >= 0; at--) {
      if (view.getUint32(at, Endian.little) == 0x06054b50 &&
          at + 22 + view.getUint16(at + 20, Endian.little) == tail.length) {
        end = at;
        break;
      }
    }
    if (end < 0) {
      throw const FormatException('ZIP directory missing.');
    }
    final size = view.getUint32(end + 12, Endian.little);
    final offset = view.getUint32(end + 16, Endian.little);
    if (size > maxXmlBytes || offset + size != length - tailSize + end) {
      throw const FormatException('ZIP directory cap.');
    }
    await file.setPosition(offset);
    final directory = await file.read(size);
    final eocd = Uint8List.fromList(tail.sublist(end));
    ByteData.sublistView(eocd).setUint32(16, 0, Endian.little);
    final entries = _directory(
      Uint8List.fromList([...directory, ...eocd]),
      checkExpansion: false,
    );
    final names = entries.map((entry) => entry.name).toSet();
    return names.any(
      (name) =>
          name == '[Content_Types].xml' ||
          name == 'meta.xml' ||
          name == 'mimetype' ||
          name.startsWith('docProps/') ||
          name.startsWith('word/') ||
          name.startsWith('xl/') ||
          name.startsWith('ppt/'),
    );
  }

  /// Null means an ordinary ZIP; malformed or over-cap inputs throw.
  static Uint8List? clean(
    Uint8List data,
    Uint8List? Function(Uint8List) cleanImage,
  ) {
    final members = _directory(data);
    final names = members.map((entry) => entry.name).toSet();
    final office = names.contains('[Content_Types].xml');
    final odf =
        names.contains('mimetype') &&
        (names.contains('meta.xml') || names.contains('content.xml'));
    if (!office && !odf) {
      return null;
    }
    final archive = Archive();
    var changed = false;
    var total = 0;
    for (final member in members) {
      final source = member.read(data);
      total += source.length;
      if (total > maxExpandedBytes) {
        throw const FormatException('ZIP expansion cap.');
      }
      var content = source;
      final name = member.name;
      final xmlPart =
          office &&
          (name.startsWith('docProps/') ||
              name.startsWith('word/') ||
              name.startsWith('xl/comments') ||
              name.startsWith('xl/persons/') ||
              name == 'ppt/commentAuthors.xml' ||
              name.startsWith('ppt/comments/')) &&
          name.endsWith('.xml');
      if (xmlPart || odf && (name == 'meta.xml' || name == 'content.xml')) {
        content = _xml(source, name, odf: odf);
      } else if (name.startsWith('word/media/') ||
          name.startsWith('ppt/media/') ||
          name.startsWith('xl/media/') ||
          odf && name.startsWith('Pictures/')) {
        // Only recognized image types are passed in; an unsupported image
        // is retained, while a damaged supported image fails closed.
        content = cleanImage(source) ?? source;
      }
      if (!identical(content, source)) {
        changed = true;
      }
      final file = name == 'mimetype'
          ? ArchiveFile.noCompress(name, content.length, content)
          : ArchiveFile.bytes(name, content);
      file.isFile = !name.endsWith('/');
      archive.addFile(file);
    }
    return changed ? ZipEncoder().encodeBytes(archive) : data;
  }

  static Uint8List _xml(Uint8List source, String name, {required bool odf}) {
    if (source.length > maxXmlBytes) {
      throw const FormatException('XML size cap.');
    }
    final text = utf8.decode(source);
    // Reject DTDs/entities; cap the tree before the parser allocates it.
    if (text.contains('<!DOCTYPE') || text.contains('<!ENTITY')) {
      throw const FormatException('XML declarations unsupported.');
    }
    var tags = 0;
    for (final _ in RegExp('<').allMatches(text)) {
      if (++tags > 50000) {
        throw const FormatException('XML node cap.');
      }
    }
    final document = XmlDocument.parse(text);
    final elements = document.descendants.whereType<XmlElement>().toList();
    for (final element in elements) {
      var depth = 0;
      for (
        var parent = element.parent;
        parent != null;
        parent = parent.parent
      ) {
        if (++depth > 128) {
          throw const FormatException('XML nesting cap.');
        }
      }
    }
    var changed = false;
    void remove(XmlElement element) {
      if (element.parent != null) {
        element.parent!.children.remove(element);
        changed = true;
      }
    }

    void clear(XmlElement element, String value) {
      if (element.innerText != value || element.children.length > 1) {
        element.children
          ..clear()
          ..add(XmlText(value));
        changed = true;
      }
    }

    for (final element in elements) {
      final local = element.name.local;
      if (name == 'docProps/core.xml' &&
          const {
            'creator',
            'lastModifiedBy',
            'created',
            'modified',
            'title',
            'subject',
            'description',
            'keywords',
            'identifier',
            'category',
            'contentStatus',
            'lastPrinted',
          }.contains(local)) {
        remove(element);
      } else if (name == 'docProps/app.xml' &&
          const {
            'Company',
            'Manager',
            'HyperlinkBase',
            'Template',
          }.contains(local)) {
        remove(element);
      } else if (name == 'docProps/custom.xml' && local == 'property') {
        remove(element);
      } else if (odf && name == 'meta.xml' && local == 'meta') {
        if (element.children.isNotEmpty) {
          element.children.clear();
          changed = true;
        }
      } else if (odf && name == 'content.xml') {
        final inDetails = element.ancestors.whereType<XmlElement>().any(
          (ancestor) =>
              const {'change-info', 'annotation'}.contains(ancestor.name.local),
        );
        if (inDetails && local == 'creator') {
          clear(element, 'Author');
        }
        if (inDetails && local == 'date') {
          clear(element, epoch);
        }
      } else if (name.startsWith('xl/comments') && local == 'author') {
        clear(element, 'Author');
      }

      if (odf || name.startsWith('docProps/')) {
        continue;
      }
      final people =
          name == 'word/people.xml' ||
          name.startsWith('xl/persons/') ||
          name == 'ppt/commentAuthors.xml';
      for (final attribute in element.attributes) {
        final key = attribute.name.local;
        String? value;
        if (const {'author', 'initials'}.contains(key) ||
            people &&
                const {
                  'name',
                  'displayName',
                  'userId',
                  'providerId',
                  'email',
                  'initial',
                }.contains(key)) {
          value = const {'author', 'name', 'displayName'}.contains(key)
              ? 'Author'
              : '';
        } else if (const {
          'date',
          'dateUtc',
          'dt',
          'created',
          'modified',
        }.contains(key)) {
          value = epoch;
        }
        if (value != null && attribute.value != value) {
          attribute.value = value;
          changed = true;
        }
      }
    }
    return changed
        ? Uint8List.fromList(utf8.encode(document.toXmlString()))
        : source;
  }

  static List<_ZipMember> _directory(
    Uint8List data, {
    bool checkExpansion = true,
  }) {
    final view = ByteData.sublistView(data);
    var end = -1;
    for (
      var at = data.length - 22;
      at >= 0 && at >= data.length - 65557;
      at--
    ) {
      if (view.getUint32(at, Endian.little) == 0x06054b50 &&
          at + 22 + view.getUint16(at + 20, Endian.little) == data.length) {
        end = at;
        break;
      }
    }
    if (end < 0) {
      throw const FormatException('ZIP directory missing.');
    }
    int u16(int at) => view.getUint16(at, Endian.little);
    int u32(int at) => view.getUint32(at, Endian.little);
    final count = u16(end + 10);
    final size = u32(end + 12);
    final start = u32(end + 16);
    if (u16(end + 4) != 0 ||
        u16(end + 6) != 0 ||
        u16(end + 8) != count ||
        count > maxEntries ||
        start + size != end) {
      throw const FormatException('ZIP directory cap or unsupported layout.');
    }
    final entries = <_ZipMember>[];
    final names = <String>{};
    var at = start;
    var total = 0;
    for (var index = 0; index < count; index++) {
      if (at + 46 > end || u32(at) != 0x02014b50) {
        throw const FormatException('Bad ZIP entry.');
      }
      final nameSize = u16(at + 28);
      final next = at + 46 + nameSize + u16(at + 30) + u16(at + 32);
      if (next > end || nameSize > 1024 || u16(at + 34) != 0) {
        throw const FormatException('ZIP entry cap.');
      }
      final flags = u16(at + 8);
      final nameBytes = Uint8List.sublistView(
        data,
        at + 46,
        at + 46 + nameSize,
      );
      final name = flags & 0x800 != 0
          ? utf8.decode(nameBytes)
          : latin1.decode(nameBytes);
      if (!names.add(name) ||
          name.startsWith('/') ||
          name.contains('\\') ||
          name.split('/').contains('..')) {
        throw const FormatException('Ambiguous ZIP names.');
      }
      final compressed = u32(at + 20);
      final expanded = u32(at + 24);
      total += expanded;
      if (checkExpansion &&
          (expanded > maxEntryBytes ||
              total > maxExpandedBytes ||
              expanded >
                  (compressed == 0 ? 1 : compressed) * maxExpansionRatio)) {
        throw const FormatException('ZIP expansion cap.');
      }
      entries.add(
        _ZipMember(
          name,
          nameBytes,
          flags,
          u16(at + 10),
          u32(at + 16),
          compressed,
          expanded,
          u32(at + 42),
          start,
        ),
      );
      at = next;
    }
    if (at != end) {
      throw const FormatException('Bad ZIP directory length.');
    }
    return entries;
  }
}

class _ZipMember {
  _ZipMember(
    this.name,
    this.nameBytes,
    this.flags,
    this.method,
    this.crc,
    this.compressed,
    this.expanded,
    this.offset,
    this.directoryStart,
  );
  final String name;
  final Uint8List nameBytes;
  final int flags, method, crc, compressed, expanded, offset, directoryStart;

  Uint8List read(Uint8List data) {
    final view = ByteData.sublistView(data);
    int u16(int at) => view.getUint16(at, Endian.little);
    if (offset + 30 > directoryStart ||
        view.getUint32(offset, Endian.little) != 0x04034b50 ||
        u16(offset + 6) != flags ||
        u16(offset + 8) != method ||
        flags & 1 != 0 ||
        !const {0, 8}.contains(method) ||
        u16(offset + 26) != nameBytes.length) {
      throw const FormatException('Unsupported ZIP entry.');
    }
    final start = offset + 30 + nameBytes.length + u16(offset + 28);
    if (start + compressed > directoryStart) {
      throw const FormatException('Bad ZIP data length.');
    }
    for (var index = 0; index < nameBytes.length; index++) {
      if (data[offset + 30 + index] != nameBytes[index]) {
        throw const FormatException('ZIP name mismatch.');
      }
    }
    final payload = Uint8List.sublistView(data, start, start + compressed);
    final content = method == 0
        ? payload
        : inflateMetadata(
            payload,
            expanded.clamp(0, OfficeMetadataSanitizer.maxEntryBytes),
            raw: true,
          );
    if (content.length != expanded || getCrc32(content) != crc) {
      throw const FormatException('Bad ZIP content.');
    }
    return content;
  }
}
