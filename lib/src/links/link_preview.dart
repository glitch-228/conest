/// Link previews: what a page says about itself (its Open Graph and
/// Twitter-card tags, or its title), fetched by this device.
///
/// A fetch is started by a message someone else wrote, so it is fenced in:
/// http(s) only; every host is looked up and refused when any of its
/// addresses is private, local or otherwise not on the public internet,
/// and the connection then goes to the address that was checked (a second
/// lookup cannot point it elsewhere); at most three redirects, each checked
/// the same way; 5 s per request; at most 512 KB of page and a capped
/// image, cut down to a small thumbnail.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import 'package:image/image.dart' as img;

/// A link's preview.
class LinkPreview {
  const LinkPreview({
    required this.url,
    required this.fetchedAt,
    this.title,
    this.description,
    this.siteName,
    this.image,
  });

  /// The page it describes (after redirects).
  final Uri url;
  final DateTime fetchedAt;
  final String? title;
  final String? description;
  final String? siteName;

  /// A JPEG thumbnail of at most [LinkPreviewFetcher.maxThumbnailBytes].
  final Uint8List? image;

  bool get isEmpty =>
      (title ?? '').isEmpty && (description ?? '').isEmpty && image == null;

  Map<String, Object?> toJson() => {
    'url': url.toString(),
    'at': fetchedAt.toUtc().toIso8601String(),
    'title': ?title,
    'description': ?description,
    'site': ?siteName,
    if (image case final bytes?) 'image': base64Encode(bytes),
  };

  static LinkPreview? fromJson(Object? json) {
    if (json is! Map) return null;
    final url = Uri.tryParse(json['url'] as String? ?? '');
    final at = DateTime.tryParse(json['at'] as String? ?? '');
    if (url == null || at == null) return null;
    Uint8List? image;
    if (json['image'] case final String encoded) {
      try {
        image = base64Decode(encoded);
      } on FormatException {
        image = null;
      }
    }
    String? text(String key) =>
        json[key] is String ? _clip(json[key] as String, 300) : null;
    return LinkPreview(
      url: url,
      fetchedAt: at.toUtc(),
      title: text('title'),
      description: text('description'),
      siteName: text('site'),
      image:
          image != null && image.length <= LinkPreviewFetcher.maxThumbnailBytes
          ? image
          : null,
    );
  }
}

String _clip(String text, int max) {
  final clean = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  return clean.length <= max ? clean : '${clean.substring(0, max - 1)}…';
}

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
      if (meta[key] case final value?) return _clip(value, 300);
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
        (pageTitle.isEmpty ? null : _clip(pageTitle, 300)),
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
  const LinkPreviewException(this.message);
  final String message;
  @override
  String toString() => 'LinkPreviewException: $message';
}

/// Fetches previews within the limits above.
class LinkPreviewFetcher {
  LinkPreviewFetcher({
    Future<List<InternetAddress>> Function(String host)? lookup,
    bool Function(InternetAddress address)? isAllowed,
    this.timeout = const Duration(seconds: 5),
    SecurityContext? securityContext,
  }) : _lookup = lookup ?? InternetAddress.lookup,
       _isAllowed = isAllowed ?? isPublicAddress,
       _securityContext = securityContext;

  static const maxRedirects = 3;
  static const maxPageBytes = 512 * 1024;
  static const maxImageBytes = 2 * 1024 * 1024;
  static const maxThumbnailBytes = 64 * 1024;

  /// Embed-fixing services answer bots that preview links (as chat apps
  /// do) with the post, and browsers with a redirect to the site.
  static const userAgent =
      'Mozilla/5.0 (compatible; Conest/1.0; '
      '+https://github.com/glitch-228/conest) TelegramBot (like TwitterBot)';

  final Future<List<InternetAddress>> Function(String host) _lookup;
  final bool Function(InternetAddress address) _isAllowed;
  final Duration timeout;
  final SecurityContext? _securityContext;

  /// The preview of [url]; null when the page has nothing to show. Throws
  /// [LinkPreviewException] when it may not or could not be fetched.
  Future<LinkPreview?> fetch(
    Uri url, {
    int maxImage = maxImageBytes,
    DateTime Function() now = DateTime.now,
  }) async {
    final page = await _get(url, accept: _isHtml, maxBytes: maxPageBytes);
    final text = utf8.decode(page.body, allowMalformed: true);
    final tags = parseLinkPreviewPage(text, page.url);
    Uint8List? thumbnail;
    if (tags.image case final image?) {
      try {
        final picture = await _get(
          image,
          accept: (type) => type.startsWith('image/'),
          maxBytes: maxImage,
        );
        thumbnail = await compute(makeLinkPreviewThumbnail, picture.body);
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
      final address = await _checkedAddress(current.host);
      final client = HttpClient(context: _securityContext)
        ..connectionTimeout = timeout
        ..idleTimeout = const Duration(seconds: 1)
        ..autoUncompress = true
        ..userAgent = userAgent;
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
          ..headers.set(HttpHeaders.acceptLanguageHeader, 'en;q=0.8, *;q=0.5');
        final response = await request.close().timeout(timeout);
        if (response.isRedirect) {
          final location = response.headers.value(HttpHeaders.locationHeader);
          await response.drain<void>().catchError((_) {});
          if (location == null) {
            throw const LinkPreviewException('bad redirect');
          }
          current = current.resolve(location);
          continue;
        }
        if (response.statusCode != 200) {
          await response.drain<void>().catchError((_) {});
          throw LinkPreviewException('status ${response.statusCode}');
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
        throw const LinkPreviewException('timed out');
      } catch (error) {
        throw LinkPreviewException('$error');
      } finally {
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

/// A JPEG of at most [LinkPreviewFetcher.maxThumbnailBytes] from an
/// image's bytes; null when they are not an image it reads.
Uint8List? makeLinkPreviewThumbnail(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return null;
  var edge = 360;
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
    if (encoded.length <= LinkPreviewFetcher.maxThumbnailBytes) return encoded;
    edge = edge * 3 ~/ 4;
  }
  return null;
}
