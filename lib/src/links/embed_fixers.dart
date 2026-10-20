/// Embed-fixing services (assets/filters/embed_fixers.json, from the
/// embed-fixer bot's list): links to sites whose previews other apps cannot
/// show (X, Instagram, Reddit, TikTok, …) are moved to a service that shows
/// them, which sends browsers on to the original.
class EmbedFixers {
  EmbedFixers._(this._sites);

  factory EmbedFixers.fromJson(Map<String, dynamic> json) {
    final sites = <_Site>[];
    for (final raw in json['sites'] as List? ?? const []) {
      if (raw is! Map) continue;
      final site = _Site.tryParse(raw.cast<String, dynamic>());
      if (site != null) sites.add(site);
    }
    return EmbedFixers._(sites);
  }

  final List<_Site> _sites;

  int get siteCount => _sites.length;

  /// [uri] moved to its site's first service that is not in [failed]
  /// (service keys, see [serviceOf]); null when its site has none, or
  /// every one failed.
  Uri? fix(Uri uri, {Set<String> failed = const {}}) {
    if (uri.scheme != 'https') return null;
    final url = uri.toString();
    for (final site in _sites) {
      final pattern = site.patternFor(url);
      if (pattern == null) continue;
      for (final service in site.services) {
        if (pattern.skip.contains(service.id)) continue;
        if (failed.contains(site.keyOf(service))) continue;
        final fixed = service.apply(uri);
        if (fixed != null) return fixed;
      }
      return null;
    }
    return null;
  }

  /// The service a link goes through ("twitter:1"), or null when it is not
  /// a link to one.
  String? serviceOf(Uri uri) => _reverse(uri)?.key;

  /// The original link of a link to a service, or null when it is not one.
  Uri? originalOf(Uri uri) => _reverse(uri)?.original;

  /// For a link to a service: its site's other services that have not
  /// [failed], then the original link. Empty for other links.
  List<Uri> alternatesFor(Uri uri, {Set<String> failed = const {}}) {
    final reversed = _reverse(uri);
    if (reversed == null) return const [];
    final original = reversed.original;
    final url = original.toString();
    final pattern = reversed.site.patternFor(url);
    return [
      for (final service in reversed.site.services)
        if (reversed.site.keyOf(service) != reversed.key &&
            !failed.contains(reversed.site.keyOf(service)) &&
            !(pattern?.skip.contains(service.id) ?? false))
          ?service.apply(original),
      original,
    ];
  }

  ({_Site site, String key, Uri original})? _reverse(Uri uri) {
    for (final site in _sites) {
      for (final service in site.services) {
        final original = service.reverse(uri);
        if (original != null) {
          return (site: site, key: site.keyOf(service), original: original);
        }
      }
    }
    return null;
  }
}

class _Site {
  _Site(this.id, this.patterns, this.services);

  static _Site? tryParse(Map<String, dynamic> json) {
    final id = json['id'];
    if (id is! String) return null;
    final patterns = <_Pattern>[];
    for (final raw in json['patterns'] as List? ?? const []) {
      if (raw is! Map || raw['pattern'] is! String) continue;
      try {
        patterns.add(
          _Pattern(RegExp(raw['pattern'] as String), {
            for (final skip in raw['skip'] as List? ?? const [])
              if (skip is int) skip,
          }),
        );
      } on FormatException {
        continue;
      }
    }
    final services = <_Service>[];
    for (final raw in json['services'] as List? ?? const []) {
      if (raw is! Map) continue;
      final service = _Service.tryParse(raw.cast<String, dynamic>());
      if (service != null) services.add(service);
    }
    if (patterns.isEmpty || services.isEmpty) return null;
    return _Site(id, patterns, services);
  }

  final String id;
  final List<_Pattern> patterns;

  /// The default first, then the fallbacks, in the list's order.
  final List<_Service> services;

  String keyOf(_Service service) => '$id:${service.id}';

  /// The pattern [url] starts with (as the bot matches: from the start).
  _Pattern? patternFor(String url) {
    for (final pattern in patterns) {
      if (pattern.regex.matchAsPrefix(url) != null) return pattern;
    }
    return null;
  }
}

class _Pattern {
  _Pattern(this.regex, this.skip);

  final RegExp regex;

  /// Services that cannot show this kind of link.
  final Set<int> skip;
}

class _Service {
  _Service(this.id, this.fixes);

  static _Service? tryParse(Map<String, dynamic> json) {
    final id = json['id'];
    if (id is! int) return null;
    final fixes = <_Fix>[];
    for (final raw in json['fixes'] as List? ?? const []) {
      if (raw is! Map) continue;
      final from = raw['from'];
      final to = raw['to'];
      final wrap = raw['wrap'];
      if (from is String && to is String) {
        fixes.add(_Fix.replace(from, to));
      } else if (wrap is String) {
        fixes.add(_Fix.wrap(wrap));
      }
    }
    return fixes.isEmpty ? null : _Service(id, fixes);
  }

  final int id;
  final List<_Fix> fixes;

  Uri? apply(Uri uri) {
    for (final fix in fixes) {
      final fixed = fix.apply(uri);
      if (fixed != null) return fixed;
    }
    return null;
  }

  Uri? reverse(Uri uri) {
    // The most specific (longest path prefix) first, as the bot does.
    final ordered = [...fixes]
      ..sort((a, b) => b.prefix.length.compareTo(a.prefix.length));
    for (final fix in ordered) {
      final original = fix.reverse(uri);
      if (original != null) return original;
    }
    return null;
  }
}

/// One rewrite: a site's domain replaced by a service's host (and a path
/// prefix, as in "fxtwitch.seria.moe/clip"), or the whole link wrapped as
/// `https://<host/path>?url=<link>`.
class _Fix {
  _Fix.replace(this.from, String to)
    : wrapped = false,
      host = _hostOf(to),
      prefix = _prefixOf(to);

  _Fix.wrap(String to)
    : from = null,
      wrapped = true,
      host = _hostOf(to),
      prefix = _prefixOf(to);

  static String _hostOf(String target) {
    final slash = target.indexOf('/');
    return slash < 0 ? target : target.substring(0, slash);
  }

  static String _prefixOf(String target) {
    final slash = target.indexOf('/');
    return slash < 0 ? '' : target.substring(slash);
  }

  final String? from;
  final bool wrapped;
  final String host;

  /// A path the service puts before the site's path ("/clip").
  final String prefix;

  Uri? apply(Uri uri) {
    if (wrapped) {
      return Uri(
        scheme: 'https',
        host: host,
        path: prefix,
        queryParameters: {'url': uri.toString()},
      );
    }
    final site = from!;
    if (uri.host != site && !uri.host.endsWith('.$site')) return null;
    return uri.replace(host: host, path: '$prefix${uri.path}');
  }

  Uri? reverse(Uri uri) {
    if (uri.host != host) return null;
    if (wrapped) {
      if (uri.path != prefix) return null;
      final original = Uri.tryParse(uri.queryParameters['url'] ?? '');
      return original != null &&
              (original.scheme == 'https' || original.scheme == 'http') &&
              original.host.isNotEmpty
          ? original
          : null;
    }
    if (prefix.isNotEmpty && !uri.path.startsWith(prefix)) return null;
    final path = uri.path.substring(prefix.length);
    return uri.replace(host: from, path: path.isEmpty ? '/' : path);
  }
}
