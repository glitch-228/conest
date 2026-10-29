import 'dart:convert';

import 'package:flutter/services.dart' show AssetBundle, rootBundle;

/// A public XMPP server where an account can be created.
class XmppServerEntry {
  const XmppServerEntry(this.domain, {this.captcha = false, this.web});

  final String domain;

  /// Its in-band sign-up asks for a CAPTCHA.
  final bool captcha;

  /// Sign-up is on this web page (https) and not in the app.
  final String? web;
}

final RegExp _domain = RegExp(
  r'^(?=.{4,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$',
);

/// The most servers taken from the list.
const int maxXmppServers = 200;

/// Reads the list file (assets/xmpp/servers.json, made by
/// `tool/update_xmpp_servers.py`). What is not a plausible domain, or is a
/// duplicate, is skipped; the bounds hold for any input.
List<XmppServerEntry> parseXmppServers(String json) {
  final Object? decoded;
  try {
    decoded = jsonDecode(json);
  } on FormatException {
    return const [];
  }
  final list = decoded is Map ? decoded['servers'] : null;
  if (list is! List) return const [];
  final seen = <String>{};
  final servers = <XmppServerEntry>[];
  for (final entry in list.take(maxXmppServers * 2)) {
    if (entry is! Map) continue;
    final domain = entry['domain'];
    if (domain is! String || !_domain.hasMatch(domain) || !seen.add(domain)) {
      continue;
    }
    final web = entry['web'];
    servers.add(
      XmppServerEntry(
        domain,
        captcha: entry['captcha'] == true,
        web: web is String && _isHttps(web) ? web : null,
      ),
    );
    if (servers.length >= maxXmppServers) break;
  }
  return List.unmodifiable(servers);
}

bool _isHttps(String url) {
  final uri = Uri.tryParse(url);
  return url.length <= 512 &&
      uri != null &&
      uri.scheme == 'https' &&
      uri.host.isNotEmpty &&
      uri.userInfo.isEmpty;
}

/// The bundled list; null when it cannot be read.
Future<List<XmppServerEntry>?> loadXmppServers({AssetBundle? bundle}) async {
  try {
    final text = await (bundle ?? rootBundle).loadString(
      'assets/xmpp/servers.json',
    );
    final servers = parseXmppServers(text);
    return servers.isEmpty ? null : servers;
  } catch (_) {
    return null;
  }
}
