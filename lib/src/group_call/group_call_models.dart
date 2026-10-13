import 'dart:convert';
import 'dart:typed_data';

const groupCallMaxParticipants = 16;
const groupCallMeshLimit = 5;

class GroupCallMember {
  const GroupCallMember({
    required this.deviceId,
    required this.name,
    required this.canJoin,
    required this.directRoute,
  });
  final String deviceId;
  final String name;
  final bool canJoin;
  final bool directRoute;
}

class GroupCallParticipant {
  const GroupCallParticipant(this.deviceId, this.index, [this.version = 1]);
  final String deviceId;
  final int index;

  /// A fresh admission resets the receiver's decoder and audio sequence state.
  final int version;
  Map<String, Object> toJson() => {
    'deviceId': deviceId,
    'index': index,
    'version': version,
  };

  static List<GroupCallParticipant> parse(Object? value) {
    if (value is! List ||
        value.isEmpty ||
        value.length > groupCallMaxParticipants) {
      throw const FormatException('Invalid call roster.');
    }
    final ids = <String>{};
    final indices = <int>{};
    return value
        .map((entry) {
          if (entry is! Map ||
              !validGroupCallId(entry['deviceId']) ||
              entry['index'] is! int ||
              (entry['index'] as int) < 0 ||
              (entry['index'] as int) >= groupCallMaxParticipants ||
              (entry['version'] != null &&
                  (entry['version'] is! int ||
                      entry['version'] < 1 ||
                      entry['version'] > 0x7fffffff)) ||
              !ids.add(entry['deviceId'] as String) ||
              !indices.add(entry['index'] as int)) {
            throw const FormatException('Invalid call participant.');
          }
          return GroupCallParticipant(
            entry['deviceId'] as String,
            entry['index'] as int,
            entry['version'] as int? ?? 1,
          );
        })
        .toList(growable: false);
  }
}

Uint8List groupCallStartBytes(
  String groupId,
  String callId,
  String startedBy,
  DateTime startedAt,
) => Uint8List.fromList(
  utf8.encode(
    jsonEncode([
      'conest.group.call.start.v1',
      groupId,
      callId,
      startedBy,
      startedAt.toUtc().toIso8601String(),
    ]),
  ),
);

bool validGroupCallId(Object? id) =>
    id is String &&
    id.isNotEmpty &&
    id.length <= 160 &&
    RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(id);

/// Transport authorship comes from the pairwise encrypted envelope. In
/// particular, the claimed sender here never authorizes an inbound signal.
class GroupCallSignal {
  const GroupCallSignal({
    required this.groupId,
    required this.callId,
    required this.senderDeviceId,
    required this.action,
    required this.issuedAt,
    this.payload = const {},
  });
  static const maxBytes = 16384;
  static const actions = {
    'start',
    'join',
    'leave',
    'roster',
    'key',
    'topology',
    'stats',
  };
  final String groupId;
  final String callId;
  final String senderDeviceId;
  final String action;
  final DateTime issuedAt;
  final Map<String, dynamic> payload;

  String encode() => jsonEncode({
    'version': 1,
    'groupId': groupId,
    'callId': callId,
    'senderDeviceId': senderDeviceId,
    'action': action,
    'issuedAt': issuedAt.toUtc().toIso8601String(),
    'payload': payload,
  });

  factory GroupCallSignal.decode(String wire) {
    if (wire.length > maxBytes || utf8.encode(wire).length > maxBytes) {
      throw const FormatException('Call signal too large.');
    }
    final json = jsonDecode(wire);
    if (json is! Map<String, dynamic> ||
        json['version'] != 1 ||
        !validGroupCallId(json['groupId']) ||
        !validGroupCallId(json['callId']) ||
        !validGroupCallId(json['senderDeviceId']) ||
        !actions.contains(json['action']) ||
        json['issuedAt'] is! String ||
        json['payload'] is! Map<String, dynamic>) {
      throw const FormatException('Invalid call signal.');
    }
    final issuedAt = DateTime.tryParse(json['issuedAt'] as String);
    if (issuedAt == null) {
      throw const FormatException('Invalid call timestamp.');
    }
    return GroupCallSignal(
      groupId: json['groupId'] as String,
      callId: json['callId'] as String,
      senderDeviceId: json['senderDeviceId'] as String,
      action: json['action'] as String,
      issuedAt: issuedAt.toUtc(),
      payload: json['payload'] as Map<String, dynamic>,
    );
  }
}

class GroupCallSummary {
  const GroupCallSummary({
    required this.groupId,
    required this.callId,
    required this.startedBy,
    required this.startedAt,
    required this.endedAt,
    required this.participants,
    this.callEnded = true,
  });
  final String groupId;
  final String callId;
  final String startedBy;
  final DateTime startedAt;
  final DateTime endedAt;
  final List<String> participants;
  final bool callEnded;
  Duration get duration => endedAt.difference(startedAt);
  Map<String, dynamic> toJson() => {
    'groupId': groupId,
    'callId': callId,
    'startedBy': startedBy,
    'startedAt': startedAt.toUtc().toIso8601String(),
    'endedAt': endedAt.toUtc().toIso8601String(),
    'participants': participants,
    'callEnded': callEnded,
  };
  factory GroupCallSummary.fromJson(Map<String, dynamic> json) {
    if (!validGroupCallId(json['groupId']) ||
        !validGroupCallId(json['callId']) ||
        !validGroupCallId(json['startedBy']) ||
        json['participants'] is! List ||
        (json['participants'] as List).length > 128) {
      throw const FormatException('Invalid call summary.');
    }
    return GroupCallSummary(
      groupId: json['groupId'] as String,
      callId: json['callId'] as String,
      startedBy: json['startedBy'] as String,
      startedAt: DateTime.parse(json['startedAt'] as String),
      endedAt: DateTime.parse(json['endedAt'] as String),
      participants: (json['participants'] as List)
          .whereType<String>()
          .where(validGroupCallId)
          .toList(),
      callEnded: json['callEnded'] as bool? ?? true,
    );
  }
}

/// Fixed storage with a one-second rate window; callers keep at most one
/// instance per authenticated current member, never one per network identity.
class GroupCallRateLimit {
  DateTime? _since;
  int _count = 0;
  bool accept(DateTime now, int maximum) {
    if (_since == null ||
        now.difference(_since!) >= const Duration(seconds: 1)) {
      _since = now;
      _count = 0;
    }
    return ++_count <= maximum;
  }
}
