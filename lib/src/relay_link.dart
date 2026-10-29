import 'dart:convert';

/// A relay as its installer prints it:
/// `conest-relay://host:port?id=<relay id>&key=<identity key, base64>`.
/// Adding a relay from one pins its key at once, instead of trusting the
/// first answer (tool/install_relay.sh).
class RelayLink {
  const RelayLink({
    required this.host,
    required this.port,
    required this.relayId,
    required this.identityKeyBase64,
    this.hiddenAddress,
  });

  static const scheme = 'conest-relay';
  static const defaultPort = 7667;

  final String host;
  final int port;
  final String relayId;
  final String identityKeyBase64;

  /// The relay's hidden address, `wss://host[:port]/<secret path>` (M38-A),
  /// when its operator shares it: the app prefers it.
  final String? hiddenAddress;

  static final _relayId = RegExp(r'^[A-Za-z0-9-]{1,64}$');

  static RelayLink? tryParse(String text) {
    final trimmed = text.trim();
    if (trimmed.length > 512) return null;
    final Uri uri;
    try {
      uri = Uri.parse(trimmed);
    } on FormatException {
      return null;
    }
    if (uri.scheme != scheme || uri.host.isEmpty) return null;
    final port = uri.hasPort ? uri.port : defaultPort;
    if (port < 1 || port > 65535) return null;
    final id = uri.queryParameters['id'];
    final key = uri.queryParameters['key'];
    if (id == null || !_relayId.hasMatch(id) || key == null) return null;
    try {
      if (base64Decode(key).length != 32) return null;
    } on FormatException {
      return null;
    }
    final hidden = uri.queryParameters['wss'];
    String? hiddenAddress;
    if (hidden != null) {
      final parsed = Uri.tryParse(hidden);
      if (parsed == null ||
          parsed.scheme != 'wss' ||
          parsed.host.isEmpty ||
          !RegExp(r'^/[A-Za-z0-9_-]{8,64}$').hasMatch(parsed.path)) {
        return null;
      }
      hiddenAddress = hidden;
    }
    return RelayLink(
      host: uri.host,
      port: port,
      relayId: id,
      identityKeyBase64: key,
      hiddenAddress: hiddenAddress,
    );
  }

  @override
  String toString() =>
      '$scheme://$host:$port?id=$relayId&key=${Uri.encodeQueryComponent(identityKeyBase64)}'
      '${hiddenAddress == null ? '' : '&wss=${Uri.encodeQueryComponent(hiddenAddress!)}'}';
}
