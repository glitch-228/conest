import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../ui/linked_text.dart';
import 'clear_urls.dart';
import 'embed_fixers.dart';

/// How links are cleaned, from Settings → Privacy.
class LinkPolicy {
  const LinkPolicy({
    this.removeTracking = true,
    this.embedFriendly = true,
    this.failedServices = const {},
  });

  static const off = LinkPolicy(removeTracking: false, embedFriendly: false);

  /// Tracking parameters are removed (ClearURLs rules).
  final bool removeTracking;

  /// Links move to an embed-fixing service where their site has one.
  final bool embedFriendly;

  /// Embed-fixing services that failed lately, skipped for now.
  final Set<String> failedServices;

  bool get isOff => !removeTracking && !embedFriendly;
}

/// One link cleaned in a text: where it was, what it was, and what it is.
typedef LinkChange = ({int start, int end, String original, String cleaned});

/// The bundled filter lists, loaded once.
class LinkFilters {
  LinkFilters(this.clearUrls, this.embedFixers);

  factory LinkFilters.fromJson({
    required String clearUrls,
    required String embedFixers,
  }) => LinkFilters(
    ClearUrls.fromJson(jsonDecode(clearUrls) as Map<String, dynamic>),
    EmbedFixers.fromJson(jsonDecode(embedFixers) as Map<String, dynamic>),
  );

  static const clearUrlsAsset = 'assets/filters/clearurls.json';
  static const embedFixersAsset = 'assets/filters/embed_fixers.json';

  /// The loaded lists; null until [load] finishes (links then stay as they
  /// are written).
  static LinkFilters? current;

  static Future<LinkFilters?>? _loading;

  /// Loads the bundled lists into [current] (once).
  static Future<LinkFilters?> load([AssetBundle? bundle]) =>
      _loading ??= _load(bundle ?? rootBundle);

  static Future<LinkFilters?> _load(AssetBundle bundle) async {
    try {
      final clear = await bundle.loadString(clearUrlsAsset, cache: false);
      final fixers = await bundle.loadString(embedFixersAsset, cache: false);
      return current = LinkFilters.fromJson(
        clearUrls: clear,
        embedFixers: fixers,
      );
    } catch (error) {
      debugPrint('Link filters not loaded: $error');
      _loading = null;
      return null;
    }
  }

  final ClearUrls clearUrls;
  final EmbedFixers embedFixers;

  /// At most this many links in one text are cleaned at a time: the rules
  /// are patterns from a third party, run on what the user writes.
  static const maxLinksPerText = 50;

  /// [uri] as it is sent: without tracking, and moved to an embed-fixing
  /// service, as [policy] allows.
  Uri forSending(Uri uri, LinkPolicy policy) {
    final written = uri.toString();
    final cleaned = sendingText(written, policy);
    return cleaned == null ? uri : Uri.parse(cleaned);
  }

  /// [written], an http(s) link, as it is sent (see [forSending]), kept as
  /// written where nothing changes; null when nothing does.
  String? sendingText(String written, LinkPolicy policy) {
    var cleaned = written;
    if (policy.removeTracking) {
      cleaned = clearUrls.cleanText(cleaned) ?? cleaned;
    }
    if (policy.embedFriendly) {
      final uri = Uri.tryParse(cleaned);
      final fixed = uri == null
          ? null
          : embedFixers.fix(uri, failed: policy.failedServices);
      if (fixed != null) cleaned = fixed.toString();
    }
    return cleaned == written ? null : cleaned;
  }

  /// [uri] as it is opened: only without tracking fields. Redirect wrappers
  /// are never followed and the site never changes: where a link someone
  /// sent goes is what it shows.
  Uri forOpening(Uri uri, LinkPolicy policy) => policy.removeTracking
      ? clearUrls.clean(uri, followRedirects: false)
      : uri;

  /// The links in [text] that change when sent ([sendingText]), skipping
  /// those [include] leaves out and those written as one of [exempt].
  List<LinkChange> changesIn(
    String text,
    LinkPolicy policy, {
    bool Function(FoundLink link)? include,
    Set<String> exempt = const {},
  }) {
    if (policy.isOff) return const [];
    final changes = <LinkChange>[];
    var seen = 0;
    for (final link in findLinks(text)) {
      if (link.uri.scheme != 'http' && link.uri.scheme != 'https') continue;
      if (include != null && !include(link)) continue;
      if (++seen > maxLinksPerText) break;
      final original = text.substring(link.start, link.end);
      if (exempt.contains(original)) continue;
      // As written ("www." links get their https:// only if they change).
      final written = original.toLowerCase().startsWith('www.')
          ? 'https://$original'
          : original;
      final cleaned = sendingText(written, policy);
      if (cleaned == null) continue;
      changes.add((
        start: link.start,
        end: link.end,
        original: original,
        cleaned: cleaned,
      ));
    }
    return changes;
  }
}

/// [text] with [changes] (from [LinkFilters.changesIn]) made.
String applyLinkChanges(String text, List<LinkChange> changes) {
  final buffer = StringBuffer();
  var at = 0;
  for (final change in changes) {
    buffer
      ..write(text.substring(at, change.start))
      ..write(change.cleaned);
    at = change.end;
  }
  buffer.write(text.substring(at));
  return buffer.toString();
}
