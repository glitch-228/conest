import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Routing metadata is untrusted until [decryptGroupFileBinary] succeeds.
/// Membership/admission must additionally authorize the group/event identity.
class GroupFileBinaryHeader {
  const GroupFileBinaryHeader({
    required this.groupId,
    required this.eventId,
    required this.requestId,
    required this.sender,
    required this.recipient,
  });
  final String groupId;
  final String eventId;
  final String requestId;
  final String sender;
  final String recipient;

  Map<String, Object?> toJson() => {
    'version': 1,
    'groupId': groupId,
    'eventId': eventId,
    'requestId': requestId,
    'sender': sender,
    'recipient': recipient,
  };

  static GroupFileBinaryHeader decode(Map<String, dynamic> json) {
    if (json.length != 6 ||
        json['version'] != 1 ||
        !['groupId', 'sender', 'recipient'].every(
          (field) =>
              json[field] is String &&
              (json[field] as String).isNotEmpty &&
              (json[field] as String).length <= 128,
        ) ||
        json['eventId'] is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(json['eventId']) ||
        json['requestId'] is! String ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(json['requestId'])) {
      throw const FormatException('Invalid group binary identity.');
    }
    return GroupFileBinaryHeader(
      groupId: json['groupId'],
      eventId: json['eventId'],
      requestId: json['requestId'],
      sender: json['sender'],
      recipient: json['recipient'],
    );
  }
}

const _maxClearBytes = 4 * 1024 * 1024 + 8196;
const _maxHeaderBytes = 1024;
const _magic = [0x43, 0x47, 0x46, 0x01];

bool isGroupFileBinary(Uint8List bytes) =>
    bytes.length >= 4 &&
    List.generate(4, (i) => i).every((i) => bytes[i] == _magic[i]);

int _headerEnd(Uint8List bytes) {
  if (!isGroupFileBinary(bytes) ||
      bytes.length < 8 + 28 ||
      bytes.length > 8 + _maxHeaderBytes + 28 + _maxClearBytes) {
    throw const FormatException('Invalid group binary frame length.');
  }
  final length = ByteData.sublistView(bytes).getUint32(4);
  if (length == 0 ||
      length > _maxHeaderBytes ||
      length + 8 + 28 > bytes.length) {
    throw const FormatException('Invalid group binary header length.');
  }
  return 8 + length;
}

GroupFileBinaryHeader peekGroupFileBinary(Uint8List bytes) {
  final end = _headerEnd(bytes);
  final decoded = jsonDecode(utf8.decode(bytes.sublist(8, end)));
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('Invalid group binary header.');
  }
  return GroupFileBinaryHeader.decode(decoded);
}

/// Domain-separated key and authenticated routing header prevent substituting
/// another file/group/recipient or reinterpreting a direct-message ciphertext.
Future<Uint8List> encryptGroupFileBinary({
  required List<int> pairwiseKey,
  required GroupFileBinaryHeader header,
  required Uint8List cleartext,
}) {
  GroupFileBinaryHeader.decode(header.toJson());
  if (cleartext.isEmpty || cleartext.length > _maxClearBytes) {
    throw const FormatException('Invalid group file payload length.');
  }
  return _encrypt(pairwiseKey, header, Uint8List.fromList(cleartext));
}

Future<SecretKey> _key(List<int> pairwiseKey) =>
    Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
      secretKey: SecretKey(pairwiseKey),
      nonce: const [],
      info: utf8.encode('conest.group-file.binary.v1'),
    );

Future<Uint8List> _encrypt(
  List<int> pairwiseKey,
  GroupFileBinaryHeader header,
  Uint8List cleartext,
) => Isolate.run(() async {
  final metadata = utf8.encode(jsonEncode(header.toJson()));
  final aad = Uint8List(8 + metadata.length)..setRange(0, 4, _magic);
  ByteData.sublistView(aad).setUint32(4, metadata.length);
  aad.setRange(8, aad.length, metadata);
  final box = await Chacha20.poly1305Aead().encrypt(
    cleartext,
    secretKey: await _key(pairwiseKey),
    aad: aad,
  );
  final result = Uint8List(aad.length + 12 + box.cipherText.length + 16);
  result.setRange(0, aad.length, aad);
  result.setRange(aad.length, aad.length + 12, box.nonce);
  result.setRange(aad.length + 12, result.length - 16, box.cipherText);
  result.setRange(result.length - 16, result.length, box.mac.bytes);
  return result;
});

Future<Uint8List> decryptGroupFileBinary({
  required List<int> pairwiseKey,
  required GroupFileBinaryHeader expected,
  required Uint8List frame,
}) {
  final header = peekGroupFileBinary(frame);
  if (jsonEncode(header.toJson()) != jsonEncode(expected.toJson())) {
    throw const FormatException('Group binary identity mismatch.');
  }
  return _decrypt(pairwiseKey, Uint8List.fromList(frame));
}

Future<Uint8List> _decrypt(List<int> pairwiseKey, Uint8List frame) =>
    Isolate.run(() async {
      final end = _headerEnd(frame);
      final clear = await Chacha20.poly1305Aead().decrypt(
        SecretBox(
          Uint8List.sublistView(frame, end + 12, frame.length - 16),
          nonce: Uint8List.sublistView(frame, end, end + 12),
          mac: Mac(Uint8List.sublistView(frame, frame.length - 16)),
        ),
        secretKey: await _key(pairwiseKey),
        aad: Uint8List.sublistView(frame, 0, end),
      );
      if (clear.isEmpty || clear.length > _maxClearBytes) {
        throw const FormatException('Invalid decrypted group file length.');
      }
      return Uint8List.fromList(clear);
    });
