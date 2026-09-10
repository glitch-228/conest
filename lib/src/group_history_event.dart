import 'dart:convert';

import 'package:crypto/crypto.dart' as hashes;
import 'package:cryptography/cryptography.dart';

/// Wire limits also bound journal records and work done by a history worker.
const groupEventMaxBytes = 128 * 1024;
const groupEventMaxCounter = 9007199254740991;

enum GroupEventKind { message, edit, deletion, reaction, attachment, receipt }

/// An original author's proof, independent of the peer carrying the envelope.
///
/// Signature verification establishes authorship only. The caller must resolve
/// [membershipId] to an authenticated membership record and check both the
/// author and the history recipient before importing or forwarding this event.
/// A key supplied by the event itself is never an authorization decision.
class GroupHistoryEvent {
  GroupHistoryEvent._({
    required this.eventId,
    required this.groupId,
    required this.authorAccountId,
    required this.authorDeviceId,
    required this.signingPublicKeyBase64,
    required this.sequence,
    required this.previousEventId,
    required this.lamport,
    required this.membershipId,
    required this.kind,
    required this.payload,
    required this.signatureBase64,
  });

  static const version = 1;
  static const _domain = 'conest.group-event.v1\n';
  static const _fields = {
    'version',
    'groupId',
    'authorAccountId',
    'authorDeviceId',
    'signingPublicKeyBase64',
    'sequence',
    'previousEventId',
    'lamport',
    'membershipId',
    'kind',
    'payload',
    'eventId',
    'signatureBase64',
  };
  final String eventId;
  final String groupId;
  final String authorAccountId;
  final String authorDeviceId;
  final String signingPublicKeyBase64;
  final int sequence;
  final String? previousEventId;
  final int lamport;
  final String membershipId;
  final GroupEventKind kind;
  final Map<String, Object?> payload;
  final String signatureBase64;

  Map<String, Object?> _body() => {
    'version': version,
    'groupId': groupId,
    'authorAccountId': authorAccountId,
    'authorDeviceId': authorDeviceId,
    'signingPublicKeyBase64': signingPublicKeyBase64,
    'sequence': sequence,
    'previousEventId': previousEventId,
    'lamport': lamport,
    'membershipId': membershipId,
    'kind': kind.name,
    'payload': payload,
  };

  List<int> signingBytes() => utf8.encode('$_domain${_canonical(_body())}');

  Map<String, Object?> toJson() => {
    ..._body(),
    'eventId': eventId,
    'signatureBase64': signatureBase64,
  };

  String encode() => _canonical(toJson());

  static Future<GroupHistoryEvent> sign({
    required String groupId,
    required String authorAccountId,
    required String authorDeviceId,
    required SimpleKeyPair keyPair,
    required int sequence,
    required String? previousEventId,
    required int lamport,
    required String membershipId,
    required GroupEventKind kind,
    required Map<String, Object?> payload,
  }) async {
    final publicKey = await keyPair.extractPublicKey();
    if (publicKey.type != KeyPairType.ed25519) {
      throw ArgumentError('Group events require an Ed25519 identity.');
    }
    final draft = GroupHistoryEvent._(
      eventId: '',
      groupId: groupId,
      authorAccountId: authorAccountId,
      authorDeviceId: authorDeviceId,
      signingPublicKeyBase64: base64Encode(publicKey.bytes),
      sequence: sequence,
      previousEventId: previousEventId,
      lamport: lamport,
      membershipId: membershipId,
      kind: kind,
      payload: _freeze(payload, 0) as Map<String, Object?>,
      signatureBase64: '',
    );
    draft._validateBody();
    final bytes = draft.signingBytes();
    if (bytes.length > groupEventMaxBytes) {
      throw const FormatException('Group event is too large.');
    }
    final signature = await Ed25519().sign(bytes, keyPair: keyPair);
    return GroupHistoryEvent.decode(
      jsonEncode({
        ...draft._body(),
        'eventId': hashes.sha256.convert(bytes).toString(),
        'signatureBase64': base64Encode(signature.bytes),
      }),
    );
  }

  factory GroupHistoryEvent.decode(String encoded) {
    if (encoded.length > groupEventMaxBytes ||
        utf8.encode(encoded).length > groupEventMaxBytes) {
      throw const FormatException('Group event is too large.');
    }
    final json = jsonDecode(encoded);
    if (json is! Map<String, dynamic> ||
        json['version'] is! int ||
        json['version'] != version ||
        json.length != _fields.length ||
        !json.keys.every(_fields.contains)) {
      throw const FormatException('Unsupported group event format.');
    }
    try {
      final event = GroupHistoryEvent._(
        eventId: json['eventId'] as String,
        groupId: json['groupId'] as String,
        authorAccountId: json['authorAccountId'] as String,
        authorDeviceId: json['authorDeviceId'] as String,
        signingPublicKeyBase64: json['signingPublicKeyBase64'] as String,
        sequence: json['sequence'] as int,
        previousEventId: json['previousEventId'] as String?,
        lamport: json['lamport'] as int,
        membershipId: json['membershipId'] as String,
        kind: GroupEventKind.values.byName(json['kind'] as String),
        payload: _freeze(json['payload'], 0) as Map<String, Object?>,
        signatureBase64: json['signatureBase64'] as String,
      );
      event._validateBody();
      if (!_isDigest(event.eventId) ||
          base64Decode(event.signatureBase64).length != 64 ||
          hashes.sha256.convert(event.signingBytes()).toString() !=
              event.eventId) {
        throw const FormatException('Invalid group event digest/signature.');
      }
      return event;
    } on TypeError {
      throw const FormatException('Invalid group event fields.');
    } on ArgumentError {
      throw const FormatException('Invalid group event fields.');
    }
  }

  void _validateBody() {
    for (final id in [groupId, authorAccountId, authorDeviceId]) {
      if (id.isEmpty || id.length > 128 || id.trim() != id) {
        throw const FormatException('Invalid group event identity.');
      }
    }
    if (sequence < 1 ||
        sequence > groupEventMaxCounter ||
        lamport < sequence ||
        lamport > groupEventMaxCounter ||
        (sequence == 1
            ? previousEventId != null
            : !_isDigest(previousEventId)) ||
        !_isDigest(membershipId) ||
        base64Decode(signingPublicKeyBase64).length != 32) {
      throw const FormatException('Invalid group event counter or reference.');
    }
  }

  Future<bool> verify({
    required String expectedGroupId,
    required String expectedAccountId,
    required String expectedDeviceId,
    required String expectedSigningKeyBase64,
  }) async {
    if (groupId != expectedGroupId ||
        authorAccountId != expectedAccountId ||
        authorDeviceId != expectedDeviceId ||
        signingPublicKeyBase64 != expectedSigningKeyBase64) {
      return false;
    }
    try {
      return await Ed25519().verify(
        signingBytes(),
        signature: Signature(
          base64Decode(signatureBase64),
          publicKey: SimplePublicKey(
            base64Decode(expectedSigningKeyBase64),
            type: KeyPairType.ed25519,
          ),
        ),
      );
    } catch (_) {
      return false;
    }
  }

  /// Stable across partitions, arrival order and wall-clock differences.
  static int compare(GroupHistoryEvent a, GroupHistoryEvent b) {
    var result = a.lamport.compareTo(b.lamport);
    if (result != 0) return result;
    result = a.authorDeviceId.compareTo(b.authorDeviceId);
    if (result != 0) return result;
    result = a.sequence.compareTo(b.sequence);
    return result != 0 ? result : a.eventId.compareTo(b.eventId);
  }
}

bool _isDigest(String? value) =>
    value != null && RegExp(r'^[0-9a-f]{64}$').hasMatch(value);

Object? _freeze(Object? value, int depth) {
  if (depth > 16) throw const FormatException('Group payload is too deep.');
  if (value == null || value is String || value is bool) return value;
  if (value is int && value.abs() <= groupEventMaxCounter) return value;
  if (value is List) {
    return List<Object?>.unmodifiable(
      value.map((entry) => _freeze(entry, depth + 1)),
    );
  }
  if (value is Map<String, Object?>) {
    final keys = value.keys.toList()..sort();
    return Map<String, Object?>.unmodifiable({
      for (final key in keys) key: _freeze(value[key], depth + 1),
    });
  }
  throw const FormatException('Group payload must use bounded JSON values.');
}

String _canonical(Map<String, Object?> json) => jsonEncode(_freeze(json, 0));
