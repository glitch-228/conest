import 'dart:convert';
import 'dart:typed_data';

/// The largest preview picture kept or sent (a JPEG thumbnail).
const maxLinkPreviewImageBytes = 64 * 1024;

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

  /// A JPEG thumbnail of at most [maxLinkPreviewImageBytes].
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
    String? text(String key) => json[key] is String
        ? clipLinkPreviewText(json[key] as String, 300)
        : null;
    return LinkPreview(
      url: url,
      fetchedAt: at.toUtc(),
      title: text('title'),
      description: text('description'),
      siteName: text('site'),
      image: image != null && image.length <= maxLinkPreviewImageBytes
          ? image
          : null,
    );
  }
}

/// [text] with its whitespace runs as single spaces, at most [max] long.
String clipLinkPreviewText(String text, int max) {
  final clean = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  return clean.length <= max ? clean : '${clean.substring(0, max - 1)}…';
}
