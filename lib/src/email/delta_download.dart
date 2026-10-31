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
      from: parseMailAddress(headers['from']) ?? '',
      messageId: (headers['message-id'] ?? '').trim(),
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
        id.length > 256)
      return null;
    return DeferredDeltaMail(uid: uid, size: size, from: from, messageId: id);
  }
}

class FetchedDeltaMail {
  const FetchedDeltaMail(this.uid, this.raw);
  final int uid;
  final Uint8List raw;
}
