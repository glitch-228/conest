import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'group_call_crypto.dart';
import 'group_call_media.dart';
import 'group_call_models.dart';
import 'group_call_policy.dart';
import 'group_call_topology.dart';

abstract interface class GroupCallTransport {
  /// A single pairwise authenticated envelope, including for group-only peers.
  Future<void> sendSignal(GroupCallSignal signal, String recipientDeviceId);
  Future<void> sendDatagram(
    String groupId,
    String recipientDeviceId,
    Uint8List bytes,
  );
}

class GroupCallRoom {
  GroupCallRoom({
    required this.groupId,
    required this.callId,
    required this.startedBy,
    required this.startedAt,
    required this.coordinator,
    required this.cipher,
  });
  final String groupId;
  final String callId;
  final String startedBy;
  final DateTime startedAt;
  String coordinator;
  final GroupCallCipher cipher;
  List<GroupCallParticipant> participants = [];
  final Set<String> allParticipants = {};
  final Map<String, GroupCallLinkStats> stats = {};
  final Map<String, DateTime> seen = {};
  final Map<String, DateTime> statsIssued = {};
  final Map<String, GroupCallRateLimit> signalRates = {};
  final Map<String, GroupCallRateLimit> frameRates = {};
  final Map<String, int> audioSequences = {};
  int version = 0;
  int epoch = 0;
  bool joined = false;
  bool muted = false;
  bool pushToTalk = false;
  bool holdingToTalk = false;
  bool ended = false;
  String? forwarder;
  String? previousForwarder;
  DateTime? overlapUntil;
  DateTime? poorSince;
  int topologyVersion = 0;
  int outgoingAudioSequence = 0;
  int measuredRttMs = 0;
  double measuredLoss = 0;
  DateTime? lastStatsSent;
  DateTime? lastPingAt;
  int? pendingPing;
  final Map<String, DateTime> mediaSeen = {};
  final Map<String, DateTime> failedForwarders = {};
  final Map<String, int> rtts = {};
  DateTime? lastTopologySent;
  DateTime? lastJoinSent;
  bool get connected =>
      joined &&
      cipher.epoch == epoch &&
      participants.any((p) => p.deviceId == cipher.localDeviceId);
  bool get microphoneMuted => muted || (pushToTalk && !holdingToTalk);
}

/// Bounded foreground call actor. Roster/key authority belongs to the starter
/// until it leaves; only that authority may commit a new roster and epoch.
/// All network entry points independently check current group membership.
class GroupCallService {
  GroupCallService({
    required this.localDeviceId,
    required this.transport,
    required this.media,
    required this.members,
    required this.sign,
    required this.verify,
    required this.policy,
    DateTime Function()? now,
    this.noiseSuppressionEnabled = true,
    this.canOpenMedia,
    this.onIncoming,
    this.onSummary,
    Iterable<String> terminalCallIds = const [],
    bool autoTick = true,
  }) : now = now ?? DateTime.now {
    _terminal.addAll(terminalCallIds.take(128));
    if (autoTick) {
      _timer = Timer.periodic(const Duration(milliseconds: 500), (_) {
        unawaited(tick().catchError((Object _) {}));
      });
    }
  }
  final bool Function()? canOpenMedia;
  final String localDeviceId;
  final GroupCallTransport transport;
  final GroupCallMediaEngine media;
  final List<GroupCallMember> Function(String groupId) members;
  final GroupCallSign sign;
  final GroupCallVerify verify;
  final GroupCallLinkPolicy policy;
  final DateTime Function() now;
  final Future<void> Function(GroupCallRoom room)? onIncoming;
  final Future<void> Function(GroupCallSummary summary)? onSummary;
  bool noiseSuppressionEnabled;
  final _rooms = <String, GroupCallRoom>{};
  final _terminal = <String>{};
  final _changes = StreamController<void>.broadcast();
  Future<void> _operation = Future.value();
  Timer? _timer;
  String? _activeGroup;
  bool _disposed = false;
  Future<void>? _pendingMediaClose;
  bool get mediaBusy => _activeGroup != null || _pendingMediaClose != null;
  int _outboundFrames = 0;
  int _inboundFrames = 0;
  int _controlJobs = 0;
  Future<void>? _tickJob;
  final Map<String, int> _datagramJobs = {};
  Stream<void> get changes => _changes.stream;
  List<GroupCallRoom> get rooms =>
      List.unmodifiable(_rooms.values.where((r) => !r.ended));
  GroupCallRoom? roomFor(String groupId) =>
      _rooms[groupId]?.ended == false ? _rooms[groupId] : null;
  GroupCallRoom? get active =>
      _activeGroup == null ? null : roomFor(_activeGroup!);

  Future<T> _serial<T>(Future<T> Function() work) {
    final result = _operation.then((_) => work());
    _operation = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }

  List<GroupCallMember> _members(String groupId) =>
      members(groupId).take(groupCallMaxParticipants).toList();
  GroupCallMember? _member(String groupId, String id) =>
      _members(groupId).where((m) => m.deviceId == id).firstOrNull;
  GroupCallCipher _cipher(String groupId, String callId) => GroupCallCipher(
    groupId: groupId,
    callId: callId,
    localDeviceId: localDeviceId,
    sign: sign,
    verify: verify,
    now: now,
  );

  GroupCallSignal _signal(
    GroupCallRoom room,
    String action, [
    Map<String, dynamic> payload = const {},
  ]) => GroupCallSignal(
    groupId: room.groupId,
    callId: room.callId,
    senderDeviceId: localDeviceId,
    action: action,
    issuedAt: now().toUtc(),
    payload: payload,
  );

  Future<void> _fanout(
    GroupCallRoom room,
    String action, [
    Map<String, dynamic> payload = const {},
  ]) async {
    final signal = _signal(room, action, payload);
    await Future.wait(
      _members(room.groupId)
          .where((peer) => peer.deviceId != localDeviceId && peer.canJoin)
          .map((peer) async {
            try {
              await transport
                  .sendSignal(signal, peer.deviceId)
                  .timeout(const Duration(seconds: 3));
            } catch (_) {
              /* Repeated live controls recover a lost route. */
            }
          }),
    );
  }

  Map<String, dynamic> _rosterPayload(GroupCallRoom room) => {
    'version': room.version,
    'epoch': room.epoch,
    'coordinator': room.coordinator,
    'participants': room.participants.map((p) => p.toJson()).toList(),
  };

  Future<GroupCallRoom> start(String groupId) => _serial(() async {
    if (_disposed ||
        _member(groupId, localDeviceId)?.canJoin != true ||
        !media.available) {
      throw StateError('Group calls are unavailable.');
    }
    if (active != null) throw StateError('Leave the current call first.');
    if (roomFor(groupId) != null) return _join(groupId);
    final id =
        'gcall_${base64UrlEncode(GroupCallCipher.randomKey().take(16).toList()).replaceAll('=', '')}';
    final room = GroupCallRoom(
      groupId: groupId,
      callId: id,
      startedBy: localDeviceId,
      startedAt: now(),
      coordinator: localDeviceId,
      cipher: _cipher(groupId, id),
    );
    _reserveRoom(room);
    try {
      await _open(room);
      room.participants = [GroupCallParticipant(localDeviceId, 0)];
      room.seen[localDeviceId] = now();
      await _rotate(room, announce: false);
      await _fanout(room, 'start', {
        ..._rosterPayload(room),
        'startedAt': room.startedAt.toUtc().toIso8601String(),
      });
      _notify();
      return room;
    } catch (_) {
      await _finish(room);
      rethrow;
    }
  });

  void _reserveRoom(GroupCallRoom room) {
    _rooms.removeWhere((_, r) => r.ended);
    if (_rooms.length >= 8) {
      final idle = _rooms.values.where((r) => !r.joined).firstOrNull;
      if (idle == null) throw StateError('Too many incoming calls.');
      idle.cipher.close();
      _rooms.remove(idle.groupId);
    }
    _rooms[room.groupId] = room;
  }

  Future<void> _open(GroupCallRoom room) async {
    if (mediaBusy || !media.available || canOpenMedia?.call() == false) {
      throw StateError('Another call is active.');
    }
    _activeGroup = room.groupId;
    try {
      // Serialize through a late open too: a timed-out engine cannot become
      // the owner of a later call's microphone.
      final opening = media.open(room.groupId);
      try {
        await opening.timeout(const Duration(seconds: 10));
      } catch (_) {
        final cleanup = opening.then(
          (_) => media.close(),
          onError: (Object _) {},
        );
        _pendingMediaClose = cleanup;
        unawaited(
          cleanup.whenComplete(() {
            if (identical(_pendingMediaClose, cleanup)) {
              _pendingMediaClose = null;
            }
          }),
        );
        rethrow;
      }
      await media.setNoiseSuppression(noiseSuppressionEnabled);
      room.joined = true;
      await media.setMuted(room.microphoneMuted);
      _syncMedia(room, const []);
    } catch (_) {
      _activeGroup = null;
      await media.close();
      rethrow;
    }
  }

  Future<GroupCallRoom> join(String groupId) => _serial(() => _join(groupId));
  Future<GroupCallRoom> _join(String groupId) async {
    final room = roomFor(groupId);
    if (_disposed ||
        room == null ||
        _member(groupId, localDeviceId)?.canJoin != true) {
      throw StateError('This group call is unavailable.');
    }
    if (room.joined) return room;
    await _open(room);
    await _fanout(room, 'join');
    room.lastJoinSent = now();
    _notify();
    return room;
  }

  void _syncMedia(GroupCallRoom room, List<GroupCallParticipant> previous) {
    if (!room.joined) return;
    for (final peer in previous) {
      if (!room.participants.any(
        (p) => p.deviceId == peer.deviceId && p.index == peer.index,
      )) {
        media.setParticipant(peer.index, false);
      }
    }
    for (final peer in room.participants) {
      if (peer.deviceId != localDeviceId) {
        media.setParticipant(peer.index, true);
      }
    }
  }

  Future<void> _rotate(GroupCallRoom room, {bool announce = true}) async {
    if (room.coordinator != localDeviceId) return;
    room.version++;
    room.epoch++;
    final key = GroupCallCipher.randomKey();
    try {
      await room.cipher.install(room.epoch, key, room.participants);
      room.allParticipants.addAll(
        room.participants
            .map((p) => p.deviceId)
            .where((id) => !room.allParticipants.contains(id))
            .take(128 - room.allParticipants.length),
      );
      final payload = _rosterPayload(room);
      if (announce) await _fanout(room, 'roster', payload);
      // The key is addressed individually, never published as a group event.
      for (final peer in room.participants) {
        if (peer.deviceId == localDeviceId ||
            _member(room.groupId, peer.deviceId)?.canJoin != true) {
          continue;
        }
        try {
          await transport
              .sendSignal(
                _signal(room, 'key', {
                  ...payload,
                  'recipient': peer.deviceId,
                  'key': base64Encode(key),
                }),
                peer.deviceId,
              )
              .timeout(const Duration(seconds: 3));
        } catch (_) {
          /* A repeated join requests a fresh epoch/key. */
        }
      }
    } finally {
      key.fillRange(0, key.length, 0);
    }
  }

  Future<bool> receiveSignal(
    GroupCallSignal signal, {
    required String authenticatedSender,
  }) {
    if (_disposed || _controlJobs >= 32) return Future.value(false);
    _controlJobs++;
    return _receiveSignal(
      signal,
      authenticatedSender: authenticatedSender,
    ).whenComplete(() {
      _controlJobs--;
    });
  }

  Future<bool> _receiveSignal(
    GroupCallSignal signal, {
    required String authenticatedSender,
  }) => _serial(() async {
    if (_disposed ||
        signal.senderDeviceId != authenticatedSender ||
        authenticatedSender == localDeviceId ||
        _member(signal.groupId, localDeviceId)?.canJoin != true ||
        _member(signal.groupId, authenticatedSender)?.canJoin != true ||
        now().difference(signal.issuedAt).abs() > const Duration(seconds: 15) ||
        signal.issuedAt.isAfter(now().add(const Duration(seconds: 2))) ||
        _terminal.contains(signal.callId)) {
      return false;
    }
    var room = roomFor(signal.groupId);
    try {
      if (signal.action == 'start') {
        if (room != null) return room.callId == signal.callId;
        final started = DateTime.tryParse(
          signal.payload['startedAt'] as String? ?? '',
        );
        if (started == null ||
            now().difference(started).abs() > const Duration(seconds: 15) ||
            signal.payload['coordinator'] != authenticatedSender) {
          return false;
        }
        room = GroupCallRoom(
          groupId: signal.groupId,
          callId: signal.callId,
          startedBy: authenticatedSender,
          startedAt: started,
          coordinator: authenticatedSender,
          cipher: _cipher(signal.groupId, signal.callId),
        );
        if (!_applyRoster(room, signal.payload)) return false;
        if (room.participants.length != 1 ||
            room.participants.single.deviceId != authenticatedSender) {
          return false;
        }
        _reserveRoom(room);
        room.seen[authenticatedSender] = now();
        _notify();
        await onIncoming?.call(room);
        return true;
      }
      if (room == null || room.callId != signal.callId) return false;
      if (!room.signalRates
          .putIfAbsent(authenticatedSender, GroupCallRateLimit.new)
          .accept(now(), authenticatedSender == room.coordinator ? 48 : 12)) {
        return false;
      }
      if (room.participants.any((p) => p.deviceId == authenticatedSender)) {
        room.seen[authenticatedSender] = now();
      }
      switch (signal.action) {
        case 'join':
          if (room.coordinator != localDeviceId || !room.joined) return true;
          final old = List<GroupCallParticipant>.of(room.participants);
          if (!room.participants.any(
            (p) => p.deviceId == authenticatedSender,
          )) {
            if (room.participants.length >= groupCallMaxParticipants) {
              return false;
            }
            final index = List.generate(
              groupCallMaxParticipants,
              (i) => i,
            ).firstWhere((i) => !room!.participants.any((p) => p.index == i));
            room.participants = [
              ...room.participants,
              GroupCallParticipant(authenticatedSender, index),
            ];
          }
          room.seen[authenticatedSender] = now();
          _syncMedia(room, old);
          await _rotate(room);
        case 'leave':
          if (!room.participants.any(
            (p) => p.deviceId == authenticatedSender,
          )) {
            return false;
          }
          if (signal.payload['epoch'] != room.epoch) return false;
          await _remove(room, authenticatedSender);
        case 'roster':
        case 'key':
          if (authenticatedSender != room.coordinator) return false;
          if (signal.action == 'key') {
            if (!room.joined ||
                signal.payload['recipient'] != localDeviceId ||
                signal.payload['key'] is! String ||
                (signal.payload['key'] as String).length != 44) {
              return false;
            }
            final key = base64Decode(signal.payload['key'] as String);
            try {
              if (key.length != 32 ||
                  !_validRoster(room, signal.payload) ||
                  signal.payload['epoch'] as int <= room.cipher.epoch ||
                  !GroupCallParticipant.parse(
                    signal.payload['participants'],
                  ).any((p) => p.deviceId == localDeviceId)) {
                return false;
              }
              if (!_applyRoster(room, signal.payload, allowSame: true)) {
                return false;
              }
              await room.cipher.install(room.epoch, key, room.participants);
            } finally {
              key.fillRange(0, key.length, 0);
            }
          } else {
            if (!_applyRoster(room, signal.payload)) return false;
            if (room.joined &&
                !room.participants.any((p) => p.deviceId == localDeviceId)) {
              await _finish(room);
            }
          }
        case 'stats':
          if (!room.participants.any(
            (p) => p.deviceId == authenticatedSender,
          )) {
            return false;
          }
          final stats = GroupCallLinkStats.fromJson(signal.payload);
          if (room.statsIssued[authenticatedSender]?.isAfter(signal.issuedAt) ==
              true) {
            return false;
          }
          room.stats[authenticatedSender] = stats;
          room.statsIssued[authenticatedSender] = signal.issuedAt;
          final silent = signal.payload['silentForwarder'];
          if (silent is String && silent == room.forwarder) {
            room.failedForwarders[silent] = now().add(
              const Duration(seconds: 5),
            );
          }
        case 'topology':
          if (authenticatedSender != room.coordinator ||
              signal.payload['rosterVersion'] != room.version) {
            return false;
          }
          final revision = signal.payload['version'];
          if (revision is! int ||
              revision <= room.topologyVersion ||
              revision > 0x7fffffff) {
            return false;
          }
          final snapshot = parseGroupCallStatsSnapshot(
            signal.payload['stats'],
            room.participants,
          );
          final excluded = _parseExcluded(room, signal.payload['excluded']);
          final forwarder = signal.payload['forwarder'];
          if (forwarder != null &&
              (forwarder is! String ||
                  forwarder !=
                      electGroupCallForwarder(
                        room.participants
                            .where((p) => !excluded.contains(p.deviceId))
                            .toList(),
                        snapshot,
                      ))) {
            return false;
          }
          if (forwarder == null &&
              room.participants.length > policy.meshLimit) {
            return false;
          }
          room.topologyVersion = revision;
          _setForwarder(room, forwarder as String?);
          room.stats.addAll(snapshot);
        default:
          return false;
      }
      _notify();
      return true;
    } on FormatException {
      return false;
    } on TypeError {
      return false;
    } on StateError {
      return false;
    }
  });

  bool _validRoster(GroupCallRoom room, Map<String, dynamic> payload) {
    final version = payload['version'];
    final epoch = payload['epoch'];
    if (version is! int ||
        version < 1 ||
        version > 0x7fffffff ||
        epoch is! int ||
        epoch < 1 ||
        epoch > 0xffffffff ||
        payload['coordinator'] != room.coordinator) {
      return false;
    }
    final roster = GroupCallParticipant.parse(payload['participants']);
    return roster.every(
          (p) => _member(room.groupId, p.deviceId)?.canJoin == true,
        ) &&
        roster.any((p) => p.deviceId == room.coordinator);
  }

  bool _applyRoster(
    GroupCallRoom room,
    Map<String, dynamic> payload, {
    bool allowSame = false,
  }) {
    if (!_validRoster(room, payload)) return false;
    final version = payload['version'] as int;
    final epoch = payload['epoch'] as int;
    if (version < room.version ||
        epoch < room.epoch ||
        (!allowSame && version == room.version)) {
      return false;
    }
    final roster = GroupCallParticipant.parse(payload['participants']);
    if (version == room.version &&
        jsonEncode(roster.map((p) => p.toJson()).toList()) !=
            jsonEncode(room.participants.map((p) => p.toJson()).toList())) {
      return false;
    }
    if (version > room.version && epoch <= room.epoch) return false;
    final previous = room.participants;
    room.participants = roster;
    room.version = version;
    room.epoch = epoch;
    room.allParticipants.addAll(
      roster
          .map((p) => p.deviceId)
          .where((id) => !room.allParticipants.contains(id))
          .take(128 - room.allParticipants.length),
    );
    bool gone(String id) => !roster.any((p) => p.deviceId == id);
    room.seen.removeWhere((id, _) => gone(id));
    room.stats.removeWhere((id, _) => gone(id));
    room.statsIssued.removeWhere((id, _) => gone(id));
    room.signalRates.removeWhere((id, _) => gone(id));
    room.frameRates.removeWhere((id, _) => gone(id));
    room.audioSequences.removeWhere((id, _) => gone(id));
    room.mediaSeen.removeWhere((id, _) => gone(id));
    room.failedForwarders.removeWhere((id, _) => gone(id));
    room.rtts.removeWhere((id, _) => gone(id));
    for (final peer in roster) {
      room.seen.putIfAbsent(peer.deviceId, now);
    }
    _syncMedia(room, previous);
    return true;
  }

  Future<void> _remove(GroupCallRoom room, String sender) async {
    final previous = room.participants;
    room.participants = previous.where((p) => p.deviceId != sender).toList();
    room.seen.remove(sender);
    room.stats.remove(sender);
    room.statsIssued.remove(sender);
    room.audioSequences.remove(sender);
    room.mediaSeen.remove(sender);
    room.failedForwarders.remove(sender);
    room.rtts.remove(sender);
    room.frameRates.remove(sender);
    room.signalRates.remove(sender);
    _syncMedia(room, previous);
    if (room.participants.isEmpty) {
      await _finish(room);
      return;
    }
    if (room.coordinator == sender) {
      room.coordinator =
          (room.participants.map((p) => p.deviceId).toList()..sort()).first;
    }
    if (room.coordinator == localDeviceId) {
      await _rotate(room);
      await _updateTopology(room);
    }
  }

  Future<void> leave() => _serial(() async {
    final room = active;
    if (room == null) return;
    room.muted = true;
    await media.setMuted(true);
    await _fanout(room, 'leave', {'epoch': room.epoch});
    final remaining = room.participants
        .where((p) => p.deviceId != localDeviceId)
        .toList();
    await _finish(room, terminal: remaining.isEmpty);
    if (remaining.isNotEmpty) {
      final coordinator = room.coordinator == localDeviceId
          ? (remaining.map((p) => p.deviceId).toList()..sort()).first
          : room.coordinator;
      final idle = GroupCallRoom(
        groupId: room.groupId,
        callId: room.callId,
        startedBy: room.startedBy,
        startedAt: room.startedAt,
        coordinator: coordinator,
        cipher: _cipher(room.groupId, room.callId),
      );
      idle.participants = remaining;
      idle.version = room.version;
      idle.epoch = room.epoch;
      idle.allParticipants.addAll(room.allParticipants);
      idle.seen.addAll(room.seen);
      _rooms[room.groupId] = idle;
    }
    _notify();
  });
  Future<void> _finish(GroupCallRoom room, {bool terminal = true}) async {
    if (room.ended) return;
    final wasJoined = room.joined;
    room.ended = true;
    room.joined = false;
    room.cipher.close();
    if (terminal) _terminal.add(room.callId);
    while (_terminal.length > 128) {
      _terminal.remove(_terminal.first);
    }
    if (_activeGroup == room.groupId) {
      _activeGroup = null;
      await media.close();
    }
    if (wasJoined) {
      await onSummary?.call(
        GroupCallSummary(
          groupId: room.groupId,
          callId: room.callId,
          startedBy: room.startedBy,
          startedAt: room.startedAt,
          endedAt: now(),
          participants: (room.allParticipants.toList()..sort())
              .take(groupCallMaxParticipants)
              .toList(),
        ),
      );
    }
  }

  Future<void> setMuted(bool value) => _serial(() async {
    final room = active;
    if (room == null) return;
    await media.setMuted(value || (room.pushToTalk && !room.holdingToTalk));
    room.muted = value;
    _notify();
  });
  Future<void> setPushToTalk(bool enabled, {bool held = false}) =>
      _serial(() async {
        final room = active;
        if (room == null) return;
        room.pushToTalk = enabled;
        room.holdingToTalk = enabled && held;
        await media.setMuted(room.microphoneMuted);
        _notify();
      });
  Future<void> setNoiseSuppression(bool enabled) => _serial(() async {
    if (active != null) await media.setNoiseSuppression(enabled);
    noiseSuppressionEnabled = enabled;
    _notify();
  });

  Future<void> sendAudio(Uint8List opus) async {
    final room = active;
    if (_disposed ||
        room == null ||
        !room.connected ||
        room.microphoneMuted ||
        opus.isEmpty ||
        opus.length > 1096 ||
        _outboundFrames >= 3) {
      return;
    }
    final sequence = ++room.outgoingAudioSequence;
    if (sequence > 0xffffffff) {
      unawaited(leave());
      return;
    }
    final payload = Uint8List(5 + opus.length)
      ..[0] = 0
      ..setRange(5, 5 + opus.length, opus);
    ByteData.sublistView(payload).setUint32(1, sequence, Endian.big);
    await _sendPayload(room, payload);
  }

  Future<void> _sendPayload(GroupCallRoom room, Uint8List payload) async {
    if (_outboundFrames >= 3) return;
    _outboundFrames++;
    try {
      final frame = await room.cipher.encrypt(payload);
      if (frame == null || room.ended || !identical(active, room)) return;
      final overlap = room.overlapUntil?.isAfter(now()) == true;
      final recipients =
          room.forwarder == null || room.forwarder == localDeviceId
          ? room.participants.map((p) => p.deviceId).toSet()
          : {
              room.forwarder!,
              if (overlap && room.previousForwarder != null)
                room.previousForwarder!,
            };
      _dispatchFrame(room, recipients, frame);
    } finally {
      _outboundFrames--;
    }
  }

  void _dispatchFrame(
    GroupCallRoom room,
    Set<String> recipients,
    Uint8List frame,
  ) {
    for (final peer in recipients.take(groupCallMaxParticipants)) {
      if (peer == localDeviceId ||
          _member(room.groupId, peer)?.directRoute != true ||
          !room.participants.any((p) => p.deviceId == peer)) {
        continue;
      }
      final count = _datagramJobs[peer] ?? 0;
      if (count >= 3 ||
          (count == 0 && _datagramJobs.length >= groupCallMaxParticipants)) {
        continue;
      }
      _datagramJobs[peer] = count + 1;
      void release() {
        final remaining = (_datagramJobs[peer] ?? 1) - 1;
        if (remaining == 0) {
          _datagramJobs.remove(peer);
        } else {
          _datagramJobs[peer] = remaining;
        }
      }

      // Even a failed dial owns its slot until its native operation ends.
      // No persistent media queue and no retransmission of old audio.
      try {
        unawaited(
          transport
              .sendDatagram(room.groupId, peer, frame)
              .then((_) => release(), onError: (Object _) => release()),
        );
      } catch (_) {
        release();
      }
    }
  }

  Future<void> receiveDatagram(
    String groupId,
    String authenticatedSender,
    Uint8List bytes,
  ) async {
    final room = active;
    if (_disposed ||
        room == null ||
        room.groupId != groupId ||
        !room.connected ||
        bytes.length > GroupCallCipher.maxFrameBytes ||
        _inboundFrames >= 32 ||
        _member(groupId, authenticatedSender)?.directRoute != true) {
      return;
    }
    final claimed = room.cipher.claimedSender(bytes);
    if (claimed == null ||
        (claimed != authenticatedSender &&
            authenticatedSender != room.forwarder &&
            !(authenticatedSender == room.previousForwarder &&
                room.overlapUntil?.isAfter(now()) == true)) ||
        claimed == localDeviceId ||
        _member(groupId, claimed)?.canJoin != true ||
        !room.frameRates
            .putIfAbsent(claimed, GroupCallRateLimit.new)
            .accept(now(), 100)) {
      return;
    }
    _inboundFrames++;
    try {
      final frame = await room.cipher.decrypt(bytes);
      if (frame == null ||
          room.ended ||
          !identical(active, room) ||
          _member(groupId, frame.sender)?.canJoin != true) {
        return;
      }
      if (!room.participants.any((p) => p.deviceId == frame.sender)) return;
      room.seen[frame.sender] = now();
      room.mediaSeen[authenticatedSender] = now();
      room.failedForwarders.remove(authenticatedSender);
      final forwarding =
          room.forwarder == localDeviceId ||
          (room.previousForwarder == localDeviceId &&
              room.overlapUntil?.isAfter(now()) == true);
      if (forwarding && authenticatedSender == frame.sender) {
        // Forward the original authenticated ciphertext without re-encrypting.
        _dispatchFrame(
          room,
          room.participants
              .map((p) => p.deviceId)
              .where((id) => id != frame.sender)
              .toSet(),
          bytes,
        );
      }
      final payload = frame.payload;
      if (payload[0] == 1 && payload.length == 9) {
        final pong = Uint8List(10)
          ..[0] = 2
          ..[1] = frame.index
          ..setRange(2, 10, payload.sublist(1));
        await _sendPayload(room, pong);
        return;
      }
      if (payload[0] == 2 && payload.length == 10) {
        final me = room.participants
            .where((p) => p.deviceId == localDeviceId)
            .firstOrNull;
        final sent = ByteData.sublistView(payload).getUint64(2, Endian.big);
        if (me == null || payload[1] != me.index || sent != room.pendingPing) {
          return;
        }
        final elapsed = now().millisecondsSinceEpoch - sent;
        if (elapsed >= 0 && elapsed <= 60000) {
          room.rtts[frame.sender] = elapsed;
          room.measuredRttMs = room.rtts.values.fold<int>(
            0,
            (a, b) => a > b ? a : b,
          );
        }
        return;
      }
      if (payload.length < 6 || payload[0] != 0) return;
      final sequence = ByteData.sublistView(payload).getUint32(1, Endian.big);
      if (sequence == 0) return;
      final previous = room.audioSequences[frame.sender] ?? 0;
      if (sequence > previous) {
        if (previous > 0) {
          final delta = sequence - previous;
          room.measuredLoss =
              (room.measuredLoss * 0.9 + (delta - 1) / delta * 0.1).clamp(
                0.0,
                1.0,
              );
        }
        room.audioSequences[frame.sender] = sequence;
      }
      media.play(frame.index, sequence, Uint8List.sublistView(payload, 5));
    } finally {
      _inboundFrames--;
    }
  }

  Set<String> _parseExcluded(GroupCallRoom room, Object? value) {
    if (value is! List ||
        value.length > groupCallMaxParticipants ||
        value.any(
          (id) =>
              id is! String || !room.participants.any((p) => p.deviceId == id),
        )) {
      throw const FormatException('Invalid forwarder exclusions.');
    }
    return value.cast<String>().toSet();
  }

  void _setForwarder(GroupCallRoom room, String? forwarder) {
    if (room.forwarder == forwarder) return;
    room.previousForwarder = room.forwarder;
    room.forwarder = forwarder;
    room.overlapUntil = now().add(const Duration(milliseconds: 600));
    if (forwarder != null) room.mediaSeen.putIfAbsent(forwarder, now);
  }

  Future<void> _updateTopology(GroupCallRoom room) async {
    if (room.coordinator != localDeviceId || !room.connected) return;
    room.failedForwarders.removeWhere((_, until) => !until.isAfter(now()));
    final poor = room.stats.values.any((s) => s.poor);
    if (poor) {
      room.poorSince ??= now();
    } else {
      room.poorSince = null;
    }
    final needsForwarder =
        room.participants.length > policy.meshLimit ||
        (room.poorSince != null &&
            now().difference(room.poorSince!) >= const Duration(seconds: 3));
    final selected = needsForwarder
        ? electGroupCallForwarder(
            room.participants
                .where((p) => !room.failedForwarders.containsKey(p.deviceId))
                .toList(),
            room.stats,
          )
        : null;
    if (room.forwarder != selected ||
        room.lastTopologySent == null ||
        now().difference(room.lastTopologySent!) >=
            const Duration(seconds: 1)) {
      _setForwarder(room, selected);
      room.topologyVersion++;
      await _fanout(room, 'topology', {
        'version': room.topologyVersion,
        'rosterVersion': room.version,
        'forwarder': selected,
        'stats': {
          for (final entry in room.stats.entries)
            if (room.participants.any((p) => p.deviceId == entry.key))
              entry.key: entry.value.toJson(),
        },
        'excluded': room.failedForwarders.keys
            .where((id) => room.participants.any((p) => p.deviceId == id))
            .toList(),
      });
      room.lastTopologySent = now();
    }
  }

  Future<void> _ping(GroupCallRoom room) async {
    if (!room.connected ||
        (room.lastPingAt != null &&
            now().difference(room.lastPingAt!) < const Duration(seconds: 1))) {
      return;
    }
    room.lastPingAt = now();
    room.pendingPing = now().millisecondsSinceEpoch;
    final ping = Uint8List(9)..[0] = 1;
    ByteData.sublistView(ping).setUint64(1, room.pendingPing!, Endian.big);
    await _sendPayload(room, ping);
  }

  Future<void> tick() {
    if (_tickJob != null) return _tickJob!;
    final job = _serial(_tick);
    _tickJob = job;
    return job.whenComplete(() {
      if (identical(_tickJob, job)) _tickJob = null;
    });
  }

  Future<void> _tick() async {
    if (_disposed) return;
    for (final room in List<GroupCallRoom>.of(rooms)) {
      if (_member(room.groupId, localDeviceId)?.canJoin != true) {
        await _finish(room);
        continue;
      }
      final currentForwarder = room.forwarder;
      if (currentForwarder != null &&
          currentForwarder != localDeviceId &&
          now().difference(room.mediaSeen[currentForwarder] ?? room.startedAt) >
              const Duration(milliseconds: 1500)) {
        room.failedForwarders[currentForwarder] = now().add(
          const Duration(seconds: 5),
        );
        room.lastStatsSent = null;
      }
      final silent = room.participants
          .where(
            (p) =>
                p.deviceId != localDeviceId &&
                now().difference(room.seen[p.deviceId] ?? room.startedAt) >
                    Duration(
                      milliseconds:
                          p.deviceId == room.coordinator ||
                              p.deviceId == room.forwarder
                          ? 1500
                          : 5000,
                    ),
          )
          .toList();
      for (final peer in silent) {
        await _remove(room, peer.deviceId);
      }
      final removed = room.participants
          .where((p) => _member(room.groupId, p.deviceId)?.canJoin != true)
          .toList();
      for (final peer in removed) {
        await _remove(room, peer.deviceId);
      }
      if (!room.joined || room.ended) continue;
      if (!room.connected &&
          (room.lastJoinSent == null ||
              now().difference(room.lastJoinSent!) >=
                  const Duration(seconds: 2))) {
        await _fanout(room, 'join');
        room.lastJoinSent = now();
      }
      if (room.lastStatsSent == null ||
          now().difference(room.lastStatsSent!) >= const Duration(seconds: 1)) {
        final stats = policy.localStats(
          measuredRttMs: room.measuredRttMs,
          measuredLoss: room.measuredLoss,
        );
        room.stats[localDeviceId] = stats;
        room.seen[localDeviceId] = now();
        await _fanout(room, 'stats', {
          ...stats.toJson(),
          if (currentForwarder != null &&
              room.failedForwarders.containsKey(currentForwarder))
            'silentForwarder': currentForwarder,
        });
        room.lastStatsSent = now();
      }
      await _ping(room);
      await _updateTopology(room);
    }
    _notify();
  }

  double level(String deviceId) {
    final peer = active?.participants
        .where((p) => p.deviceId == deviceId)
        .firstOrNull;
    return peer == null || deviceId == localDeviceId
        ? 0
        : media.level(peer.index);
  }

  Future<void> dispose() async {
    _timer?.cancel();
    await leave();
    _disposed = true;
    await _pendingMediaClose;
    for (final room in _rooms.values) {
      room.cipher.close();
    }
    _rooms.clear();
    await _changes.close();
  }
}
