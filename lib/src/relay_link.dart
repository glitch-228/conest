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
  });

  static const scheme = 'conest-relay';
  static const defaultPort = 7667;

  final String host;
  final int port;
  final String relayId;
  final String identityKeyBase64;

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
    return RelayLink(
      host: uri.host,
      port: port,
      relayId: id,
      identityKeyBase64: key,
    );
  }

  @override
  String toString() =>
      '$scheme://$host:$port?id=$relayId&key=${Uri.encodeQueryComponent(identityKeyBase64)}';
}
