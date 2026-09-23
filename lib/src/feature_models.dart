import 'dart:convert';

/// Application protocol support advertised independently from transport
/// routes. Unknown/absent values are treated as unsupported by new features.
enum ApplicationCapability {
  groupPollsV1,
  voiceMessageAttachmentsV1,
  voiceCallsV1,
  groupFileCaptionsV2,
}

List<ApplicationCapability> applicationCapabilitiesFromJson(Object? value) {
  if (value is! List || value.length > ApplicationCapability.values.length) {
    return const <ApplicationCapability>[];
  }
  final result = <ApplicationCapability>{};
  for (final name in value.whereType<String>()) {
    for (final capability in ApplicationCapability.values) {
      if (capability.name == name) result.add(capability);
    }
  }
  return ApplicationCapability.values
      .where(result.contains)
      .toList(growable: false);
}

/// A local conversation collection. Folder membership is deliberately local
/// in the first version; deleting a folder never deletes its conversations.
class ChatFolder {
  ChatFolder({
    required this.id,
    required this.name,
    required Iterable<String> conversationIds,
    required this.createdAt,
    required this.updatedAt,
  }) : conversationIds = _uniqueIds(conversationIds);

  final String id;
  final String name;
  final List<String> conversationIds;
  final DateTime createdAt;
  final DateTime updatedAt;

  ChatFolder copyWith({
    String? name,
    Iterable<String>? conversationIds,
    DateTime? updatedAt,
  }) => ChatFolder(
    id: id,
    name: name ?? this.name,
    conversationIds: conversationIds ?? this.conversationIds,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  Map<String, dynamic> toJson() => {
    'version': 1,
    'id': id,
    'name': name,
    'conversationIds': conversationIds,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
  };

  factory ChatFolder.fromJson(Map<String, dynamic> json) => ChatFolder(
    id: json['id'] as String,
    name: (json['name'] as String? ?? '').trim(),
    conversationIds: (json['conversationIds'] as List<dynamic>? ?? const [])
        .whereType<String>(),
    createdAt:
        DateTime.tryParse(json['createdAt'] as String? ?? '')?.toUtc() ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    updatedAt:
        DateTime.tryParse(json['updatedAt'] as String? ?? '')?.toUtc() ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
  );
}

List<String> _uniqueIds(Iterable<String> values) {
  final seen = <String>{};
  return [
    for (final value in values)
      if (value.trim().isNotEmpty && seen.add(value.trim())) value.trim(),
  ];
}

enum ScheduledMessageState { waiting, sending, sent, canceled, blocked }

/// A durable local outbox entry. [scheduledAtUtc] is the chosen instant, so a
/// later timezone change only changes presentation, never delivery time.
class ScheduledMessage {
  ScheduledMessage({
    required this.id,
    required this.conversationId,
    required this.conversationKind,
    required this.body,
    required this.scheduledAtUtc,
    required this.createdAt,
    this.attachmentId,
    this.attachmentPath,
    this.attachmentFileName,
    this.attachmentMimeType,
    this.attachmentSizeBytes,
    this.state = ScheduledMessageState.waiting,
    this.outgoingMessageId,
    this.failureReason,
  });

  final String id;
  final String conversationId;
  final String conversationKind;
  final String body;
  final DateTime scheduledAtUtc;
  final DateTime createdAt;
  final String? attachmentId;

  /// App-owned path relative to the attachment root. Keeping this relative
  /// makes the staged file restart-safe without trusting an imported path.
  final String? attachmentPath;
  final String? attachmentFileName;
  final String? attachmentMimeType;
  final int? attachmentSizeBytes;
  final ScheduledMessageState state;
  final String? outgoingMessageId;
  final String? failureReason;

  ScheduledMessage copyWith({
    String? body,
    DateTime? scheduledAtUtc,
    ScheduledMessageState? state,
    String? outgoingMessageId,
    String? failureReason,
    String? attachmentPath,
    bool clearAttachmentPath = false,
    bool clearFailureReason = false,
  }) => ScheduledMessage(
    id: id,
    conversationId: conversationId,
    conversationKind: conversationKind,
    body: body ?? this.body,
    scheduledAtUtc: scheduledAtUtc ?? this.scheduledAtUtc,
    createdAt: createdAt,
    attachmentId: attachmentId,
    attachmentPath: clearAttachmentPath
        ? null
        : (attachmentPath ?? this.attachmentPath),
    attachmentFileName: attachmentFileName,
    attachmentMimeType: attachmentMimeType,
    attachmentSizeBytes: attachmentSizeBytes,
    state: state ?? this.state,
    outgoingMessageId: outgoingMessageId ?? this.outgoingMessageId,
    failureReason: clearFailureReason
        ? null
        : (failureReason ?? this.failureReason),
  );

  Map<String, dynamic> toJson() => {
    'version': 1,
    'id': id,
    'conversationId': conversationId,
    'conversationKind': conversationKind,
    'body': body,
    'scheduledAtUtc': scheduledAtUtc.toUtc().toIso8601String(),
    'createdAt': createdAt.toUtc().toIso8601String(),
    if (attachmentId != null) 'attachmentId': attachmentId,
    if (attachmentPath != null) 'attachmentPath': attachmentPath,
    if (attachmentFileName != null) 'attachmentFileName': attachmentFileName,
    if (attachmentMimeType != null) 'attachmentMimeType': attachmentMimeType,
    if (attachmentSizeBytes != null) 'attachmentSizeBytes': attachmentSizeBytes,
    'state': state.name,
    if (outgoingMessageId != null) 'outgoingMessageId': outgoingMessageId,
    if (failureReason != null) 'failureReason': failureReason,
  };

  factory ScheduledMessage.fromJson(Map<String, dynamic> json) =>
      ScheduledMessage(
        id: json['id'] as String,
        conversationId: json['conversationId'] as String,
        conversationKind: json['conversationKind'] as String? ?? 'direct',
        body: json['body'] as String? ?? '',
        scheduledAtUtc:
            DateTime.tryParse(
              json['scheduledAtUtc'] as String? ?? '',
            )?.toUtc() ??
            DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
        createdAt:
            DateTime.tryParse(json['createdAt'] as String? ?? '')?.toUtc() ??
            DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
        attachmentId: json['attachmentId'] as String?,
        attachmentPath: json['attachmentPath'] as String?,
        attachmentFileName: json['attachmentFileName'] as String?,
        attachmentMimeType: json['attachmentMimeType'] as String?,
        attachmentSizeBytes: (json['attachmentSizeBytes'] as num?)?.toInt(),
        state: ScheduledMessageState.values.firstWhere(
          (value) => value.name == json['state'],
          orElse: () => ScheduledMessageState.waiting,
        ),
        outgoingMessageId: json['outgoingMessageId'] as String?,
        failureReason: json['failureReason'] as String?,
      );
}

enum PollChoiceMode { single, multiple }

class PollDefinition {
  PollDefinition({
    required this.id,
    required this.question,
    required Iterable<String> options,
    required this.mode,
    required this.creatorDeviceId,
    required this.createdAt,
    this.closedAt,
  }) : options = options
           .map((value) => value.trim())
           .where((value) => value.isNotEmpty)
           .toSet()
           .toList(growable: false);

  final String id;
  final String question;
  final List<String> options;
  final PollChoiceMode mode;
  final String creatorDeviceId;
  final DateTime createdAt;
  final DateTime? closedAt;

  bool get isClosed => closedAt != null;

  Map<String, dynamic> toJson() => {
    'version': 1,
    'id': id,
    'question': question,
    'options': options,
    'mode': mode.name,
    'creatorDeviceId': creatorDeviceId,
    'createdAt': createdAt.toUtc().toIso8601String(),
    if (closedAt != null) 'closedAt': closedAt!.toUtc().toIso8601String(),
  };

  bool get hasValidShape =>
      id.isNotEmpty &&
      id.length <= 160 &&
      question.trim().isNotEmpty &&
      question.trim().length <= 512 &&
      options.length >= 2 &&
      options.length <= 10 &&
      options.every((value) => value.isNotEmpty && value.length <= 128) &&
      creatorDeviceId.isNotEmpty &&
      creatorDeviceId.length <= 160;

  factory PollDefinition.fromJson(Map<String, dynamic> json) {
    if (json['version'] != 1) {
      throw const FormatException('Unsupported poll definition version.');
    }
    final id = json['id'];
    final question = json['question'];
    final rawOptions = json['options'];
    final creator = json['creatorDeviceId'];
    final modeName = json['mode'];
    final createdAtValue = json['createdAt'];
    if (id is! String ||
        question is! String ||
        rawOptions is! List ||
        creator is! String ||
        modeName is! String ||
        createdAtValue is! String ||
        rawOptions.length < 2 ||
        rawOptions.length > 10 ||
        rawOptions.any((value) => value is! String)) {
      throw const FormatException('Invalid poll definition fields.');
    }
    final options = rawOptions.cast<String>().map((value) => value.trim());
    final optionList = options.toList(growable: false);
    if (optionList.any((value) => value.isEmpty || value.length > 128) ||
        optionList.toSet().length != optionList.length) {
      throw const FormatException('Invalid poll options.');
    }
    final mode = PollChoiceMode.values.where((value) => value.name == modeName);
    if (mode.isEmpty) {
      throw const FormatException('Unsupported poll choice mode.');
    }
    final closedAtValue = json['closedAt'];
    final closedAt = closedAtValue == null
        ? null
        : closedAtValue is String
        ? DateTime.tryParse(closedAtValue)
        : null;
    if (closedAtValue != null && closedAt == null) {
      throw const FormatException('Invalid poll close time.');
    }
    final definition = PollDefinition(
      id: id,
      question: question,
      options: optionList,
      mode: mode.single,
      creatorDeviceId: creator,
      createdAt: DateTime.parse(createdAtValue),
      closedAt: closedAt,
    );
    if (!definition.hasValidShape) {
      throw const FormatException('Invalid poll definition.');
    }
    return definition;
  }
}

class PollVote {
  PollVote({
    required this.pollId,
    required this.voterDeviceId,
    required Iterable<String> optionIndexes,
    required this.changedAt,
  }) : optionIndexes = optionIndexes.toSet().toList()..sort();

  final String pollId;
  final String voterDeviceId;
  final List<String> optionIndexes;
  final DateTime changedAt;

  Map<String, dynamic> toJson() => {
    'version': 1,
    'pollId': pollId,
    'voterDeviceId': voterDeviceId,
    'optionIndexes': optionIndexes,
    'changedAt': changedAt.toUtc().toIso8601String(),
  };

  bool get hasValidShape =>
      pollId.isNotEmpty &&
      pollId.length <= 160 &&
      voterDeviceId.isNotEmpty &&
      voterDeviceId.length <= 160 &&
      optionIndexes.length <= 10 &&
      optionIndexes.every((value) {
        final index = int.tryParse(value);
        return index != null && index >= 0 && index < 10;
      });

  factory PollVote.fromJson(Map<String, dynamic> json) {
    if (json['version'] != null && json['version'] != 1) {
      throw const FormatException('Unsupported poll vote version.');
    }
    final pollId = json['pollId'];
    final voter = json['voterDeviceId'];
    final rawIndexes = json['optionIndexes'];
    final changedAtValue = json['changedAt'];
    if (pollId is! String ||
        voter is! String ||
        rawIndexes is! List ||
        rawIndexes.length > 10 ||
        rawIndexes.any((value) => value is! String) ||
        changedAtValue is! String) {
      throw const FormatException('Invalid poll vote fields.');
    }
    final indexes = rawIndexes.cast<String>();
    if (indexes.toSet().length != indexes.length ||
        indexes.any((value) {
          final index = int.tryParse(value);
          return index == null ||
              index < 0 ||
              index >= 10 ||
              value != index.toString();
        })) {
      throw const FormatException('Invalid poll vote options.');
    }
    final vote = PollVote(
      pollId: pollId,
      voterDeviceId: voter,
      optionIndexes: indexes,
      changedAt: DateTime.parse(changedAtValue),
    );
    if (!vote.hasValidShape) throw const FormatException('Invalid poll vote.');
    return vote;
  }
}

class PollProjection {
  const PollProjection({
    required this.definition,
    required this.votes,
    this.unconfirmedVotes = const <String, PollVote>{},
    this.closedCheckpointEventId,
  });

  final PollDefinition definition;
  final Map<String, PollVote> votes;

  /// Latest votes that arrived after the creator's checkpoint or are not in
  /// the checkpoint. They do not contribute to closed-poll tallies.
  final Map<String, PollVote> unconfirmedVotes;
  final String? closedCheckpointEventId;

  List<int> counts() {
    final result = List<int>.filled(definition.options.length, 0);
    for (final vote in votes.values) {
      for (final value in vote.optionIndexes) {
        final index = int.tryParse(value);
        if (index != null && index >= 0 && index < result.length) {
          result[index]++;
        }
      }
    }
    return result;
  }
}

class VoiceMessageMetadata {
  const VoiceMessageMetadata({
    required this.durationMs,
    this.waveform = const <int>[],
    this.codec = 'opus',
    this.container = 'ogg',
  });

  final int durationMs;
  final List<int> waveform;
  final String codec;
  final String container;

  Map<String, dynamic> toJson() => {
    'durationMs': durationMs,
    'waveform': waveform.take(256).toList(growable: false),
    'codec': codec,
    'container': container,
  };

  factory VoiceMessageMetadata.fromJson(Map<String, dynamic> json) =>
      VoiceMessageMetadata(
        durationMs: (json['durationMs'] as num?)?.toInt() ?? 0,
        waveform: (json['waveform'] as List<dynamic>? ?? const [])
            .whereType<num>()
            .map((value) => value.toInt().clamp(0, 255))
            .take(256)
            .toList(growable: false),
        codec: json['codec'] as String? ?? 'opus',
        container: json['container'] as String? ?? 'ogg',
      );
}

class VoiceRecordingResult {
  const VoiceRecordingResult({
    required this.path,
    required this.sizeBytes,
    required this.metadata,
  });

  final String path;
  final int sizeBytes;
  final VoiceMessageMetadata metadata;

  factory VoiceRecordingResult.fromPlatform(Map<String, dynamic> value) {
    final path = value['path'];
    final size = (value['sizeBytes'] as num?)?.toInt();
    if (path is! String || path.trim().isEmpty || size == null || size <= 0) {
      throw const FormatException('Native voice recording result is invalid.');
    }
    final metadata = VoiceMessageMetadata(
      durationMs: (value['durationMs'] as num?)?.toInt() ?? 0,
      waveform: (value['waveform'] as List<dynamic>? ?? const [])
          .whereType<num>()
          .map((item) => item.toInt().clamp(0, 255))
          .take(256)
          .toList(growable: false),
      codec: value['codec'] as String? ?? 'opus',
      container: value['container'] as String? ?? 'ogg',
    );
    if (metadata.durationMs <= 0 ||
        metadata.durationMs > 10 * 60 * 1000 ||
        metadata.codec != 'opus' ||
        metadata.container != 'ogg') {
      throw const FormatException(
        'Native voice recording metadata is invalid.',
      );
    }
    return VoiceRecordingResult(
      path: path,
      sizeBytes: size,
      metadata: metadata,
    );
  }
}

enum VoiceCallState {
  idle,
  ringing,
  connecting,
  connected,
  reconnecting,
  ended,
}

class VoiceCallSession {
  VoiceCallSession({
    required this.callId,
    required this.peerDeviceId,
    required this.outgoing,
    required this.startedAt,
    this.state = VoiceCallState.ringing,
    this.muted = false,
    this.speakerphoneEnabled = false,
    this.failureReason,
  });

  final String callId;
  final String peerDeviceId;
  final bool outgoing;
  final DateTime startedAt;
  final VoiceCallState state;
  final bool muted;
  final bool speakerphoneEnabled;
  final String? failureReason;

  VoiceCallSession copyWith({
    VoiceCallState? state,
    bool? muted,
    bool? speakerphoneEnabled,
    String? failureReason,
  }) => VoiceCallSession(
    callId: callId,
    peerDeviceId: peerDeviceId,
    outgoing: outgoing,
    startedAt: startedAt,
    state: state ?? this.state,
    muted: muted ?? this.muted,
    speakerphoneEnabled: speakerphoneEnabled ?? this.speakerphoneEnabled,
    failureReason: failureReason ?? this.failureReason,
  );

  Map<String, dynamic> toJson() => {
    'callId': callId,
    'peerDeviceId': peerDeviceId,
    'outgoing': outgoing,
    'startedAt': startedAt.toUtc().toIso8601String(),
    'state': state.name,
    'muted': muted,
    'speakerphoneEnabled': speakerphoneEnabled,
    if (failureReason != null) 'failureReason': failureReason,
  };
}

String encodeFeatureJson(Object value) => jsonEncode(value);
