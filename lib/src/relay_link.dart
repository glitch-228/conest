import 'dart:convert';

import 'models.dart' show isValidBorrowedSni;

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
    this.borrowedAddress,
    this.hasPlainPort = true,
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

  /// The relay's borrowed-handshake address, `borrowed://IP[:port]/sni`
  /// (M38 S1), when its operator shares it: the app adds it pinned to the
  /// link's key, so a first contact needs no plain port.
  final String? borrowedAddress;

  /// False for a relay that does not serve its plain port publicly (the
  /// link's `plain=none`): its host and port only name it, and no plain
  /// route is added for them.
  final bool hasPlainPort;

  /// The longest link taken (a QR code still holds one this long).
  static const maxLength = 1024;

  /// `borrowed://HOST[:PORT]/SNI`: an address literal (IPv6 in brackets) or
  /// a name, an optional port, and the site's name.
  static final _borrowedForm = RegExp(
    r'^borrowed://(\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9.-]+)(?::([0-9]{1,5}))?/([^/?#]+)$',
  );

  static final _relayId = RegExp(r'^[A-Za-z0-9-]{1,64}$');

  static RelayLink? tryParse(String text) {
    final trimmed = text.trim();
    if (trimmed.length > maxLength) return null;
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
    final borrowed = uri.queryParameters['borrowed'];
    String? borrowedAddress;
    if (borrowed != null) {
      final form = _borrowedForm.firstMatch(borrowed);
      final borrowedPort = int.tryParse(form?.group(2) ?? '443');
      if (form == null ||
          !isValidBorrowedSni(form.group(3)) ||
          borrowedPort == null ||
          borrowedPort < 1 ||
          borrowedPort > 65535) {
        return null;
      }
      borrowedAddress = borrowed;
    }
    // A relay with no public plain port is reached by its other addresses.
    final hasPlainPort = uri.queryParameters['plain'] != 'none';
    if (!hasPlainPort && hiddenAddress == null && borrowedAddress == null) {
      return null;
    }
    return RelayLink(
      host: uri.host,
      port: port,
      relayId: id,
      identityKeyBase64: key,
      hiddenAddress: hiddenAddress,
      borrowedAddress: borrowedAddress,
      hasPlainPort: hasPlainPort,
    );
  }

  @override
  String toString() =>
      '$scheme://$host:$port?id=$relayId&key=${Uri.encodeQueryComponent(identityKeyBase64)}'
      '${hiddenAddress == null ? '' : '&wss=${Uri.encodeQueryComponent(hiddenAddress!)}'}'
      '${borrowedAddress == null ? '' : '&borrowed=${Uri.encodeQueryComponent(borrowedAddress!)}'}'
      '${hasPlainPort ? '' : '&plain=none'}';
}
