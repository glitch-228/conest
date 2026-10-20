/// The ClearURLs rules (assets/filters/clearurls.json): tracking parts of
/// links are removed the way the ClearURLs browser extension removes them.
/// Only cleaning: a provider that would block a site (`completeProvider`)
/// is ignored.
class ClearUrls {
  ClearUrls._(this._providers);

  /// Reads the rules file (`{"providers": {name: provider}}`). A provider
  /// whose patterns this platform cannot compile is skipped.
  factory ClearUrls.fromJson(Map<String, dynamic> json) {
    final providers = <_Provider>[];
    final raw = json['providers'];
    if (raw is Map) {
      for (final entry in raw.entries) {
        if (entry.value is! Map) continue;
        final provider = _Provider.tryParse(
          entry.key.toString(),
          (entry.value as Map).cast<String, dynamic>(),
        );
        if (provider != null) providers.add(provider);
      }
    }
    return ClearUrls._(providers);
  }

  /// Longer links are left alone: cleaning runs on every message, and the
  /// rules' patterns are not written for megabytes of input.
  static const maxLength = 4096;

  final List<_Provider> _providers;

  int get providerCount => _providers.length;

  /// [uri] without its tracking parameters, and, with [followRedirects],
  /// with redirect wrappers (such as google.com/url?q=…) opened; [uri]
  /// itself when nothing is removed.
  Uri clean(Uri uri, {bool followRedirects = true}) {
    final cleaned = cleanText(uri.toString(), followRedirects: followRedirects);
    return cleaned == null ? uri : Uri.parse(cleaned);
  }

  /// [url], an http(s) link as written, without its tracking parameters
  /// (the rest kept exactly as written), and, with [followRedirects], with
  /// redirect wrappers opened. Null when nothing is removed, or the result
  /// would not be an http(s) link.
  ///
  /// Following redirects is for links the user is sending, and sees
  /// change: the target is whatever the wrapper names, so a link someone
  /// else sent is never opened that way.
  String? cleanText(String url, {bool followRedirects = true}) {
    if (url.length > maxLength || !_isWebText(url)) return null;
    var current = url;
    // As the extension does: again until nothing changes (a redirect can
    // reveal a link with its own tracking), with a bound here.
    for (var pass = 0; pass < 5; pass++) {
      final next = _pass(current, followRedirects);
      if (next == current) break;
      current = next;
    }
    return current == url || !_isWebText(current) ? null : current;
  }

  String _pass(String url, bool followRedirects) {
    var current = url;
    for (final provider in _providers) {
      if (!provider.matches(current)) continue;
      final result = provider.apply(current, followRedirects);
      if (result.redirect) return result.url;
      current = result.url;
    }
    return current;
  }

  static bool _isWebText(String url) {
    final uri = Uri.tryParse(url);
    return uri != null && _isWeb(uri) && uri.host.isNotEmpty;
  }

  static bool _isWeb(Uri uri) => uri.scheme == 'http' || uri.scheme == 'https';
}

class _Provider {
  _Provider({
    required this.name,
    required this.urlPattern,
    required this.exceptions,
    required this.redirections,
    required this.rules,
    required this.rawRules,
  });

  static _Provider? tryParse(String name, Map<String, dynamic> json) {
    List<String> strings(String key) => [
      for (final value in json[key] as List? ?? const []) ?value as String?,
    ];
    final pattern = json['urlPattern'];
    if (pattern is! String) return null;
    try {
      return _Provider(
        name: name,
        urlPattern: _regex(pattern),
        exceptions: strings('exceptions').map(_regex).toList(),
        redirections: strings('redirections').map(_regex).toList(),
        // Referral marketing goes too, as with the extension's default.
        rules: [
          ...strings('rules'),
          ...strings('referralMarketing'),
        ].map((rule) => _regex('^$rule\$')).toList(),
        rawRules: strings('rawRules').map(_regex).toList(),
      );
    } on FormatException {
      return null;
    }
  }

  static RegExp _regex(String pattern) => RegExp(pattern, caseSensitive: false);

  final String name;
  final RegExp urlPattern;
  final List<RegExp> exceptions;
  final List<RegExp> redirections;
  final List<RegExp> rules;
  final List<RegExp> rawRules;

  bool matches(String url) =>
      urlPattern.hasMatch(url) &&
      !exceptions.any((exception) => exception.hasMatch(url));

  ({String url, bool redirect}) apply(String url, bool followRedirects) {
    var current = url;
    // Redirections first, as the extension does.
    for (final redirection in followRedirects ? redirections : const []) {
      final match = redirection.firstMatch(current);
      if (match == null || match.groupCount < 1) continue;
      final target = match.group(1);
      if (target == null || target.isEmpty) continue;
      String decoded;
      try {
        decoded = Uri.decodeComponent(target);
      } on ArgumentError {
        continue;
      }
      final parsed = Uri.tryParse(decoded);
      if (parsed != null &&
          (parsed.scheme == 'http' || parsed.scheme == 'https') &&
          parsed.host.isNotEmpty) {
        // Normalised, as the extension's `new URL(…).href` does: a space or
        // line break decoded from the wrapper must not split the link.
        return (url: parsed.toString(), redirect: true);
      }
    }
    for (final raw in rawRules) {
      current = current.replaceAll(raw, '');
    }
    if (rules.isEmpty) return (url: current, redirect: false);
    return (url: _withoutFields(current), redirect: false);
  }

  /// [url] without the query and fragment fields a rule names. The other
  /// fields, and [url] itself when none goes, stay as they were written.
  String _withoutFields(String url) {
    var rest = url;
    String? fragment;
    final hash = rest.indexOf('#');
    if (hash >= 0) {
      fragment = rest.substring(hash + 1);
      rest = rest.substring(0, hash);
    }
    String? query;
    final question = rest.indexOf('?');
    if (question >= 0) {
      query = rest.substring(question + 1);
      rest = rest.substring(0, question);
    }
    final keptQuery = query == null ? null : _keptFields(query);
    // A fragment of fields (#a=1&b=2) is cleaned like a query; a plain
    // anchor (#section) stays.
    final keptFragment = fragment == null || !fragment.contains('=')
        ? null
        : _keptFields(fragment);
    if (keptQuery == null && keptFragment == null) return url;
    final buffer = StringBuffer(rest);
    if (query != null) {
      final kept = keptQuery ?? query;
      if (kept.isNotEmpty) buffer.write('?$kept');
    }
    if (fragment != null) {
      final kept = keptFragment ?? fragment;
      if (kept.isNotEmpty) buffer.write('#$kept');
    }
    return buffer.toString();
  }

  /// [fields] without those a rule names; null when none of them goes.
  String? _keptFields(String fields) {
    final all = fields.split('&');
    final kept = all.where((field) => !_isTracking(field)).toList();
    return kept.length == all.length
        ? null
        : kept.where((field) => field.isNotEmpty).join('&');
  }

  bool _isTracking(String field) {
    if (field.isEmpty) return false;
    final equals = field.indexOf('=');
    var key = equals < 0 ? field : field.substring(0, equals);
    try {
      key = Uri.decodeQueryComponent(key);
    } on ArgumentError {
      // Left as written.
    }
    return rules.any((rule) => rule.hasMatch(key));
  }
}
