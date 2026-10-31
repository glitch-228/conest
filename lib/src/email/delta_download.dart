import 'dart:convert';
import 'dart:typed_data';

import 'carrier_mail.dart';
import 'mime.dart';

/// Untrusted routing hints for mail whose body has not been fetched. They
/// never establish a peer, group membership, or message authorship.
class DeferredDeltaMail {
  const DeferredDeltaMail({
    required this.uid,
    required this.size,
    this.from = '',
    this.messageId = '',
  });
  static const maxCount = 128;
  final int uid;
  final int size;
  final String from;
  final String messageId;

  static DeferredDeltaMail fromHeaders(int uid, int size, Uint8List raw) {
    final headers = MimeHeaders.parse(latin1.decode(raw));
    return DeferredDeltaMail(
      uid: uid,
      size: size,
      from: _boundedMailHint(parseMailAddress(headers['from']), 320),
      messageId: _boundedMailHint(headers['message-id'], 256),
    );
  }

  Map<String, dynamic> toJson() => {
    'uid': uid,
    'size': size,
    'from': from,
    'messageId': messageId,
  };
  static DeferredDeltaMail? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final uid = json['uid'],
        size = json['size'],
        from = json['from'],
        id = json['messageId'];
    if (uid is! int ||
        uid < 1 ||
        uid > 0xffffffff ||
        size is! int ||
        size < 0 ||
        size > 42 * 1024 * 1024 ||
        from is! String ||
        from.length > 320 ||
        id is! String ||
        id.length > 256) {
      return null;
    }
    return DeferredDeltaMail(uid: uid, size: size, from: from, messageId: id);
  }
}

class FetchedDeltaMail {
  const FetchedDeltaMail(this.uid, this.raw, {this.userRequested = false});
  final int uid;
  final Uint8List raw;
  final bool userRequested;
}

String _boundedMailHint(String? value, int limit) {
  final text = value?.trim() ?? '';
  return text.length <= limit ? text : '';
}

/// Conest carrier envelopes use one exact v4 SKESK (AES-256, iterated SHA-256).
/// A bounded prefix distinguishes them from Delta's public-key and v6 mail
/// without trusting unsigned MIME hints or downloading an attachment body.
bool hasCarrierPacketPrefix(Uint8List prefix) {
  final text = latin1.decode(prefix);
  final begin = text.indexOf('-----BEGIN PGP MESSAGE-----');
  if (begin < 0) return false;
  final lines = text.substring(begin).split('\n');
  for (final line in lines.skip(1)) {
    final body = line.trim();
    if (body.isEmpty || body.contains(':')) continue;
    if (body.length < 24) return false;
    try {
      final bytes = base64.decode(body.substring(0, 24));
      return bytes.length >= 7 &&
          bytes[0] == 0xc3 &&
          bytes[1] == 13 &&
          bytes[2] == 4 &&
          bytes[3] == 9 &&
          bytes[4] == 3 &&
          bytes[5] == 8;
    } on FormatException {
      return false;
    }
  }
  return false;
}
