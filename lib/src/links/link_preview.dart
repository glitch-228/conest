/// Link previews: what a page says about itself (its Open Graph and
/// Twitter-card tags, or its title), fetched by this device.
///
/// A fetch is started by a message someone else wrote, so it is fenced in:
/// http(s) only, on the usual web ports; every host is looked up and
/// refused when any of its addresses is private, local or otherwise not on
/// the public internet, and the connection then goes to the address that
/// was checked (a second lookup cannot point it elsewhere), never through a
/// proxy; at most three redirects, each checked the same way, never from
/// https down to http; 5 s between reads and 10 s in all per request; no
/// compressed answers; at most 512 KB of page and a capped picture, which
/// must be a JPEG, PNG, GIF or WebP of a sane size and is cut down to a
/// small thumbnail by the engine's own decoder (its first frame only).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import 'package:image/image.dart' as img;

import 'link_preview_data.dart';

export 'link_preview_data.dart';

/// What a page's tags say: Open Graph first, then Twitter cards, then its
/// `<title>` and description; the image as a link, relative to [page].
({String? title, String? description, String? siteName, Uri? image})
parseLinkPreviewPage(String text, Uri page) {
  final document = html.parse(text);
  final meta = <String, String>{};
  for (final element in document.getElementsByTagName('meta')) {
    final key = (element.attributes['property'] ?? element.attributes['name'])
        ?.toLowerCase()
        .trim();
    final content = element.attributes['content'];
    if (key == null || content == null || content.trim().isEmpty) continue;
    meta.putIfAbsent(key, () => content);
  }
  String? first(List<String> keys) {
    for (final key in keys) {
      if (meta[key] case final value?) return clipLinkPreviewText(value, 300);
    }
    return null;
  }

  final titleElement = document.getElementsByTagName('title').firstOrNull;
  final imageText = first([
    'og:image:secure_url',
    'og:image',
    'og:image:url',
    'twitter:image',
    'twitter:image:src',
  ]);
  Uri? image;
  if (imageText != null) {
    final resolved = Uri.tryParse(imageText);
    image = resolved == null ? null : page.resolveUri(resolved);
    if (image != null && image.scheme != 'https' && image.scheme != 'http') {
      image = null;
    }
  }
  final pageTitle = _textOf(titleElement).trim();
  return (
    title:
        first(['og:title', 'twitter:title']) ??
        (pageTitle.isEmpty ? null : clipLinkPreviewText(pageTitle, 300)),
    description: first([
      'og:description',
      'twitter:description',
      'description',
    ]),
    siteName: first(['og:site_name', 'application-name']),
    image: image,
  );
}

String _textOf(dom.Element? element) => element?.text ?? '';

/// Whether [address] is on the public internet. Private, loopback,
/// link-local, shared (CGNAT), documentation, benchmarking, multicast and
/// reserved ranges are not; IPv6 addresses carrying an IPv4 one (mapped,
/// NAT64) are judged by that.
bool isPublicAddress(InternetAddress address) {
  final bytes = address.rawAddress;
  if (address.type == InternetAddressType.IPv4 && bytes.length == 4) {
    return _publicV4(bytes);
  }
  if (address.type != InternetAddressType.IPv6 || bytes.length != 16) {
    return false;
  }
  bool prefix(List<int> start) {
    for (var i = 0; i < start.length; i++) {
      if (bytes[i] != start[i]) return false;
    }
    return true;
  }

  // ::ffff:a.b.c.d (mapped) and 64:ff9b::a.b.c.d (NAT64).
  if (prefix([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff]) ||
      prefix([0, 0x64, 0xff, 0x9b, 0, 0, 0, 0, 0, 0, 0, 0])) {
    return _publicV4(bytes.sublist(12));
  }
  if (bytes.every((b) => b == 0)) return false; // ::
  if (prefix(List.filled(15, 0)) && bytes[15] == 1) return false; // ::1
  if (prefix(List.filled(12, 0))) return false; // IPv4-compatible (old)
  final first = bytes[0];
  if (first & 0xfe == 0xfc) return false; // fc00::/7 unique local
  if (first == 0xfe && bytes[1] & 0xc0 == 0x80) return false; // fe80::/10
  if (first == 0xfe && bytes[1] & 0xc0 == 0xc0) return false; // fec0::/10
  if (first == 0xff) return false; // multicast
  if (prefix([0x20, 0x01, 0x0d, 0xb8])) return false; // documentation
  // 2001::/23, the IETF block (Teredo, ORCHID, benchmarking).
  if (first == 0x20 && bytes[1] == 0x01 && bytes[2] < 0x02) return false;
  // 3fff::/20, documentation.
  if (first == 0x3f && bytes[1] == 0xff && bytes[2] & 0xf0 == 0) return false;
  if (prefix([0x01, 0, 0, 0, 0, 0, 0, 0])) return false; // 100::/64 discard
  if (prefix([0x20, 0x02])) {
    // 6to4 carries an IPv4 address in bytes 2–5.
    return _publicV4(bytes.sublist(2, 6));
  }
  return (first & 0xe0) == 0x20; // only 2000::/3 is global unicast
}

bool _publicV4(List<int> b) {
  final a = b[0], c = b[1];
  if (a == 0 || a == 10 || a == 127) return false;
  if (a == 100 && c >= 64 && c <= 127) return false; // CGNAT
  if (a == 169 && c == 254) return false;
  if (a == 172 && c >= 16 && c <= 31) return false;
  if (a == 192 && c == 168) return false;
  if (a == 192 && c == 0 && (b[2] == 0 || b[2] == 2)) return false;
  if (a == 198 && (c == 18 || c == 19)) return false;
  if (a == 198 && c == 51 && b[2] == 100) return false;
  if (a == 203 && c == 0 && b[2] == 113) return false;
  if (a >= 224) return false; // multicast, reserved, broadcast
  return true;
}

/// Why a preview could not be fetched (the reason is for logs).
class LinkPreviewException implements Exception {
  const LinkPreviewException(this.message, {this.down = false});
  final String message;

  /// The site did not answer properly (no connection, a timeout, a server
  /// error), as opposed to answering with nothing to show.
  final bool down;
  @override
  String toString() => 'LinkPreviewException: $message';
}

/// Fetches previews within the limits above.
class LinkPreviewFetcher {
  LinkPreviewFetcher({
    Future<List<InternetAddress>> Function(String host)? lookup,
    bool Function(InternetAddress address)? isAllowed,
    this.timeout = const Duration(seconds: 5),
    this.totalTimeout = const Duration(seconds: 10),
    this.allowedPorts = const {80, 443, 8080, 8443},
    SecurityContext? securityContext,
  }) : _lookup = lookup ?? InternetAddress.lookup,
       _isAllowed = isAllowed ?? isPublicAddress,
       _securityContext = securityContext;

  static const maxRedirects = 3;
  static const maxPageBytes = 512 * 1024;
  static const maxImageBytes = 2 * 1024 * 1024;
  static const maxThumbnailBytes = maxLinkPreviewImageBytes;

  /// A picture larger than this (per side, or in all) is not decoded.
  static const maxPictureSide = 8192;

  /// (PNGs and animated pictures decode at full size before scaling.)
  static const maxPicturePixels = 4 * 1024 * 1024;

  /// Embed-fixing services answer bots that preview links (as chat apps
  /// do) with the post, and browsers with a redirect to the site.
  /// (Only what they look for: nothing that names Conest to every site.)
  static const userAgent =
      'Mozilla/5.0 (compatible) TelegramBot (like TwitterBot)';

  final Future<List<InternetAddress>> Function(String host) _lookup;
  final bool Function(InternetAddress address) _isAllowed;

  /// Between reads.
  final Duration timeout;

  /// For a whole request (each redirect is another).
  final Duration totalTimeout;

  /// Ports a link may name; null allows any (tests).
  final Set<int>? allowedPorts;
  final SecurityContext? _securityContext;

  /// The preview of [url]; null when the page has nothing to show. Throws
  /// [LinkPreviewException] when it may not or could not be fetched.
  Future<LinkPreview?> fetch(
    Uri url, {
    int maxImage = maxImageBytes,
    DateTime Function() now = DateTime.now,
  }) async {
    final page = await _get(url, accept: _isHtml, maxBytes: maxPageBytes);
    // Off the UI thread: half a megabyte of markup can take a while.
    final tags = await compute(_parseInBackground, (
      page.body,
      page.url.toString(),
    ));
    Uint8List? thumbnail;
    if (tags.image case final image?) {
      try {
        final picture = await _get(
          Uri.parse(image),
          accept: (type) => type.startsWith('image/'),
          maxBytes: maxImage,
        );
        thumbnail = await makeLinkPreviewThumbnail(picture.body);
      } catch (_) {
        // A page without its picture is still a preview.
      }
    }
    final preview = LinkPreview(
      url: page.url,
      fetchedAt: now().toUtc(),
      title: tags.title,
      description: tags.description,
      siteName: tags.siteName ?? page.url.host,
      image: thumbnail,
    );
    return preview.isEmpty ? null : preview;
  }

  static bool _isHtml(String type) =>
      type == 'text/html' || type == 'application/xhtml+xml';

  Future<({Uri url, Uint8List body})> _get(
    Uri url, {
    required bool Function(String mimeType) accept,
    required int maxBytes,
  }) async {
    var current = url;
    for (var hop = 0; hop <= maxRedirects; hop++) {
      if (current.scheme != 'http' && current.scheme != 'https') {
        throw const LinkPreviewException('not an http(s) link');
      }
      if (current.host.isEmpty) throw const LinkPreviewException('no host');
      if (allowedPorts case final ports? when !ports.contains(current.port)) {
        throw LinkPreviewException('port ${current.port} not allowed');
      }
      final address = await _checkedAddress(current.host);
      final client = HttpClient(context: _securityContext)
        ..connectionTimeout = timeout
        ..idleTimeout = const Duration(seconds: 1)
        // Compressed answers could inflate far past the caps first.
        ..autoUncompress = false
        ..userAgent = userAgent
        // A proxy from the environment would get its credentials sent to
        // the site; the connection goes to the checked address anyway.
        ..findProxy = (_) => 'DIRECT';
      // However slowly a site answers, the whole request ends in time.
      var overdue = false;
      final deadline = Timer(totalTimeout, () {
        overdue = true;
        client.close(force: true);
      });
      // To the address that was checked, never a second lookup.
      client.connectionFactory = (uri, proxyHost, proxyPort) async {
        final port = uri.hasPort
            ? uri.port
            : (uri.scheme == 'https' ? 443 : 80);
        final task = await Socket.startConnect(address, port);
        if (uri.scheme != 'https') return task;
        return ConnectionTask.fromSocket(
          task.socket.then(
            (socket) => SecureSocket.secure(
              socket,
              host: uri.host,
              context: _securityContext,
            ),
          ),
          task.cancel,
        );
      };
      try {
        final request = await client.getUrl(current).timeout(timeout);
        request
          ..followRedirects = false
          ..headers.set(HttpHeaders.acceptHeader, 'text/html,image/*;q=0.8')
          ..headers.set(HttpHeaders.acceptEncodingHeader, 'identity')
          ..headers.set(HttpHeaders.acceptLanguageHeader, 'en;q=0.8, *;q=0.5');
        final response = await request.close().timeout(timeout);
        if (response.isRedirect) {
          final location = response.headers.value(HttpHeaders.locationHeader);
          await response.drain<void>().catchError((_) {});
          if (location == null) {
            throw const LinkPreviewException('bad redirect');
          }
          final next = current.resolve(location);
          if (current.scheme == 'https' && next.scheme != 'https') {
            throw const LinkPreviewException('redirect away from https');
          }
          current = next;
          continue;
        }
        if (response.statusCode != 200) {
          await response.drain<void>().catchError((_) {});
          throw LinkPreviewException(
            'status ${response.statusCode}',
            down: response.statusCode >= 500,
          );
        }
        final encoding = response.headers
            .value(HttpHeaders.contentEncodingHeader)
            ?.toLowerCase();
        if (encoding != null && encoding != 'identity') {
          await response.drain<void>().catchError((_) {});
          throw LinkPreviewException('compressed answer ($encoding)');
        }
        final type = response.headers.contentType?.mimeType.toLowerCase() ?? '';
        if (!accept(type)) {
          await response.drain<void>().catchError((_) {});
          throw LinkPreviewException('not wanted: $type');
        }
        final declared = response.contentLength;
        if (declared > maxBytes) {
          await response.drain<void>().catchError((_) {});
          throw const LinkPreviewException('too large');
        }
        final body = BytesBuilder(copy: false);
        await for (final chunk in response.timeout(timeout)) {
          final room = maxBytes - body.length;
          if (room <= 0) break;
          body.add(chunk.length <= room ? chunk : chunk.sublist(0, room));
        }
        return (url: current, body: body.takeBytes());
      } on LinkPreviewException {
        rethrow;
      } on TimeoutException {
        throw const LinkPreviewException('timed out', down: true);
      } catch (error) {
        throw LinkPreviewException(
          overdue ? 'took too long' : '$error',
          down: true,
        );
      } finally {
        deadline.cancel();
        client.close(force: true);
      }
    }
    throw const LinkPreviewException('too many redirects');
  }

  Future<InternetAddress> _checkedAddress(String host) async {
    final literal = InternetAddress.tryParse(
      host.replaceAll(RegExp(r'^\[|\]$'), ''),
    );
    final List<InternetAddress> addresses;
    if (literal != null) {
      addresses = [literal];
    } else {
      try {
        addresses = await _lookup(host).timeout(timeout);
      } catch (_) {
        throw const LinkPreviewException('host not found');
      }
    }
    if (addresses.isEmpty) throw const LinkPreviewException('host not found');
    // Every address must be public: a name that also points inside the
    // network could be steered there.
    if (!addresses.every(_isAllowed)) {
      throw const LinkPreviewException('not a public address');
    }
    return addresses.first;
  }
}

/// [parseLinkPreviewPage] of a page's bytes, for [compute].
({String? title, String? description, String? siteName, String? image})
_parseInBackground((Uint8List, String) page) {
  final tags = parseLinkPreviewPage(
    utf8.decode(page.$1, allowMalformed: true),
    Uri.parse(page.$2),
  );
  return (
    title: tags.title,
    description: tags.description,
    siteName: tags.siteName,
    image: tags.image?.toString(),
  );
}

/// Whether [bytes] start as a JPEG, PNG, GIF or WebP: other formats are
/// not decoded at all.
bool isPreviewPicture(Uint8List bytes) {
  bool startsWith(List<int> magic, [int at = 0]) {
    if (bytes.length < at + magic.length) return false;
    for (var i = 0; i < magic.length; i++) {
      if (bytes[at + i] != magic[i]) return false;
    }
    return true;
  }

  return startsWith([0xff, 0xd8, 0xff]) ||
      startsWith([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) ||
      startsWith(ascii.encode('GIF87a')) ||
      startsWith(ascii.encode('GIF89a')) ||
      (startsWith(ascii.encode('RIFF')) && startsWith(ascii.encode('WEBP'), 8));
}

/// The longest side of a thumbnail.
const _thumbnailEdge = 360;

/// A JPEG of at most [LinkPreviewFetcher.maxThumbnailBytes] from a
/// picture's bytes; null when they are not a picture this reads, or one
/// too large. The size it declares is read first; only then is it decoded,
/// by the engine, straight to thumbnail size, and only its first frame.
Future<Uint8List?> makeLinkPreviewThumbnail(
  Uint8List bytes, {
  int edge = _thumbnailEdge,
  int maxBytes = LinkPreviewFetcher.maxThumbnailBytes,
}) async {
  if (!isPreviewPicture(bytes)) return null;
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  ui.ImageDescriptor? descriptor;
  try {
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    final width = descriptor.width;
    final height = descriptor.height;
    if (width <= 0 ||
        height <= 0 ||
        width > LinkPreviewFetcher.maxPictureSide ||
        height > LinkPreviewFetcher.maxPictureSide ||
        width * height > LinkPreviewFetcher.maxPicturePixels) {
      return null;
    }
    final scale = min(1.0, edge / max(width, height));
    final targetWidth = max(1, (width * scale).round());
    final targetHeight = max(1, (height * scale).round());
    final codec = await descriptor.instantiateCodec(
      targetWidth: targetWidth,
      targetHeight: targetHeight,
    );
    try {
      final frame = await codec.getNextFrame();
      final image = frame.image;
      try {
        // An animated picture ignores the size asked for: never copy out a
        // full-size frame.
        if (image.width > targetWidth || image.height > targetHeight) {
          return null;
        }
        final pixels = await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        if (pixels == null) return null;
        return compute(_encodeThumbnail, (
          image.width,
          image.height,
          pixels.buffer.asUint8List(),
          edge,
          maxBytes,
        ));
      } finally {
        image.dispose();
      }
    } finally {
      codec.dispose();
    }
  } catch (_) {
    return null;
  } finally {
    descriptor?.dispose();
    buffer.dispose();
  }
}

/// RGBA pixels (at most the given edge a side) as a JPEG of at most the
/// given bytes.
Uint8List? _encodeThumbnail((int, int, Uint8List, int, int) pixels) {
  final decoded = img.Image.fromBytes(
    width: pixels.$1,
    height: pixels.$2,
    bytes: pixels.$3.buffer,
    numChannels: 4,
    order: img.ChannelOrder.rgba,
  );
  var edge = pixels.$4;
  for (var quality = 75; quality >= 35; quality -= 20) {
    final scaled = decoded.width >= decoded.height
        ? img.copyResize(
            decoded,
            width: decoded.width < edge ? decoded.width : edge,
          )
        : img.copyResize(
            decoded,
            height: decoded.height < edge ? decoded.height : edge,
          );
    final encoded = img.encodeJpg(scaled, quality: quality);
    if (encoded.length <= pixels.$5) return encoded;
    edge = edge * 3 ~/ 4;
  }
  return null;
}
