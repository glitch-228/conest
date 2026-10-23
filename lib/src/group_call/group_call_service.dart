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
    this.term = 0,
    this.startSignature = '',
  });
  final String groupId;
  final String callId;
  final String startedBy;
  final DateTime startedAt;
  String coordinator;
  GroupCallCipher cipher;
  int term;
  final String startSignature;
  Uint8List? distributionKey;
  String? admission;
  final Map<String, String> admissions = {};
  // Recovery witnesses are not roster/media/summary membership. One bounded
  // record per device also orders fresh admissions against delayed controls.
  final Map<String, (String, DateTime)> joinIntents = {};
  DateTime? lastJoinIssued;
  bool needsAdmission = false;
  bool leaving = false;
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
  DateTime? lastStartSent;
  bool get connected =>
      joined &&
      !leaving &&
      !needsAdmission &&
      cipher.epoch == epoch &&
      participants.any((p) => p.deviceId == cipher.localDeviceId);
  bool get microphoneMuted => muted || (pushToTalk && !holdingToTalk);
}

/// Bounded foreground call actor. Roster/key authority belongs to the starter
/// until it leaves or fails. Authenticated terms reconcile asymmetric outages.
/// All network entry points independently check current group membership.
class GroupCallService {
  GroupCallService({
    required this.localDeviceId,
    required this.transport,
    required this.media,
    required this.members,
    required this.sign,
    required this.verify,
    this.verifyStart,
    required this.policy,
    DateTime Function()? now,
    this.noiseSuppressionEnabled = true,
    this.canOpenMedia,
    this.onIncoming,
    this.onSummary,
    Iterable<(String, String)> terminalCalls = const [],
    bool autoTick = true,
  }) : now = now ?? DateTime.now,
       _autoTick = autoTick {
    _terminal.addAll(
      terminalCalls.take(128).map((c) => _callIdentity(c.$1, c.$2)),
    );
  }

  final bool _autoTick;
  final bool Function()? canOpenMedia;
  final String localDeviceId;
  final GroupCallTransport transport;
  final GroupCallMediaEngine media;
  final List<GroupCallMember> Function(String groupId) members;
  final GroupCallSign sign;
  final GroupCallVerify verify;
  final Future<bool> Function(
    String groupId,
    String sender,
    Uint8List bytes,
    Uint8List signature,
  )?
  verifyStart;
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
  bool _disposing = false;
  Future<void>? _pendingMediaClose;
  bool get mediaBusy => _activeGroup != null || _pendingMediaClose != null;
  int _outboundFrames = 0;
  int _inboundFrames = 0;
  int _controlJobs = 0;
  Future<void>? _tickJob;
  final Map<String, int> _datagramJobs = {};
  final Map<String, int> _signalJobs = {};
  final _startRate = GroupCallRateLimit();
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
    _syncTicking();
    if (!_changes.isClosed) _changes.add(null);
  }

  /// The upkeep timer runs only while there is a call to keep up: with
  /// none it would wake the device (and every listener) twice a second.
  void _syncTicking() {
    if (!_autoTick) return;
    final live = !_disposed && _rooms.values.any((room) => !room.ended);
    if (live && _timer == null) {
      _timer = Timer.periodic(const Duration(milliseconds: 500), (_) {
        unawaited(tick().catchError((Object _) {}));
      });
    } else if (!live) {
      _timer?.cancel();
      _timer = null;
    }
  }

  /// Members as of this moment: looked up once per synchronous step (one
  /// audio frame asks several times, and each lookup walks every contact),
  /// never kept past it, so a removal counts at once.
  List<GroupCallMember> _members(String groupId) {
    final cached = _memberCache[groupId];
    if (cached != null) return cached;
    final list = members(groupId).take(groupCallMaxParticipants).toList();
    if (_memberCache.isEmpty) scheduleMicrotask(_memberCache.clear);
    _memberCache[groupId] = list;
    return list;
  }

  final Map<String, List<GroupCallMember>> _memberCache = {};
  GroupCallMember? _member(String groupId, String id) =>
      _members(groupId).where((m) => m.deviceId == id).firstOrNull;
  static String _callIdentity(String groupId, String callId) =>
      jsonEncode([groupId, callId]);
  GroupCallCipher _cipher(
    String groupId,
    String callId, {
    int term = 0,
    String? coordinator,
  }) => GroupCallCipher(
    groupId: groupId,
    callId: callId,
    localDeviceId: localDeviceId,
    sign: sign,
    verify: verify,
    now: now,
    authority: term == 0 ? '' : jsonEncode([term, coordinator]),
  );

  GroupCallSignal _signal(
    GroupCallRoom room,
    String action, [
    Map<String, dynamic> payload = const {},
  ]) {
    var issuedAt = now().toUtc();
    if (action == 'join') {
      final previous = room.lastJoinIssued;
      if (previous != null && !issuedAt.isAfter(previous)) {
        issuedAt = previous.add(const Duration(microseconds: 1));
      }
      room.lastJoinIssued = issuedAt;
    }
    return GroupCallSignal(
      groupId: room.groupId,
      callId: room.callId,
      senderDeviceId: localDeviceId,
      action: action,
      issuedAt: issuedAt,
      payload: {'term': room.term, ...payload},
    );
  }

  Future<void> _fanout(
    GroupCallRoom room,
    String action, [
    Map<String, dynamic> payload = const {},
    // Upkeep that only those in the call use: members who stay out of it
    // are not woken for it.
    bool participantsOnly = false,
  ]) async {
    final signal = _signal(room, action, payload);
    final inCall = {for (final p in room.participants) p.deviceId};
    for (final peer in _members(room.groupId)) {
      if (peer.deviceId != localDeviceId &&
          peer.canJoin &&
          (!participantsOnly || inCall.contains(peer.deviceId))) {
        _dispatchSignal(signal, peer.deviceId);
      }
    }
  }

  void _dispatchSignal(GroupCallSignal signal, String recipient) {
    final count = _signalJobs[recipient] ?? 0;
    if (_disposed ||
        count >= 4 ||
        (count == 0 && _signalJobs.length >= groupCallMaxParticipants)) {
      return;
    }
    _signalJobs[recipient] = count + 1;
    void release() {
      final remaining = (_signalJobs[recipient] ?? 1) - 1;
      remaining == 0
          ? _signalJobs.remove(recipient)
          : _signalJobs[recipient] = remaining;
    }

    // Keep each slot until the actual send finishes. Hung routes cannot hold
    // the call actor or build an unlimited timed-out backlog.
    try {
      unawaited(
        transport
            .sendSignal(signal, recipient)
            .then((_) => release(), onError: (Object _) => release()),
      );
    } catch (_) {
      release();
    }
  }

  Map<String, dynamic> _rosterPayload(GroupCallRoom room) => {
    'version': room.version,
    'epoch': room.epoch,
    'coordinator': room.coordinator,
    'term': room.term,
    'participants': room.participants.map((p) => p.toJson()).toList(),
  };

  Future<void> _announceStart(GroupCallRoom room) async {
    if (room.coordinator != localDeviceId || !room.connected) return;
    await _fanout(room, 'start', {
      ..._rosterPayload(room),
      'startedBy': room.startedBy,
      'startedAt': room.startedAt.toUtc().toIso8601String(),
      'startSignature': room.startSignature,
    });
    room.lastStartSent = now();
  }

  Map<String, dynamic> _joinPayload(GroupCallRoom room) => {
    'admission': room.admission,
    'rosterVersion': room.version,
    'epoch': room.cipher.epoch,
  };

  bool _considerAuthority(GroupCallRoom room, GroupCallSignal signal) {
    final term = signal.payload['term'] ?? 0;
    if (term is! int || term < 0 || term > 0x7fffffff) return false;
    final sender = signal.senderDeviceId;
    if (term == room.term && sender == room.coordinator) return true;
    final wins =
        term > room.term ||
        (term == room.term &&
            term > 0 &&
            sender.compareTo(room.coordinator) < 0);
    if (!wins ||
        term > room.term + 128 ||
        !(room.participants.any((p) => p.deviceId == sender) ||
            room.allParticipants.contains(sender) ||
            room.joinIntents.containsKey(sender)) ||
        !_validRoster(room, signal.payload, coordinator: sender)) {
      return false;
    }
    _adoptAuthority(room, term, sender);
    return true;
  }

  void _adoptAuthority(GroupCallRoom room, int term, String coordinator) {
    room.cipher.close();
    room.distributionKey?.fillRange(0, room.distributionKey!.length, 0);
    room.distributionKey = null;
    room.term = term;
    room.coordinator = coordinator;
    room.cipher = _cipher(
      room.groupId,
      room.callId,
      term: term,
      coordinator: coordinator,
    );
    room.version = 0;
    room.epoch = 0;
    room.topologyVersion = 0;
    room.needsAdmission = room.joined && coordinator != localDeviceId;
    room.lastJoinSent = null;
    room.lastTopologySent = null;
    room.lastStartSent = null;
    _setForwarder(room, null);
  }

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
    final startedAt = now();
    final room = GroupCallRoom(
      groupId: groupId,
      callId: id,
      startedBy: localDeviceId,
      startedAt: startedAt,
      coordinator: localDeviceId,
      cipher: _cipher(groupId, id),
      startSignature: base64Encode(
        await sign(groupCallStartBytes(groupId, id, localDeviceId, startedAt)),
      ),
    );
    _reserveRoom(room);
    try {
      await _open(room);
      room.participants = [GroupCallParticipant(localDeviceId, 0)];
      room.admissions[localDeviceId] = room.admission!;
      room.seen[localDeviceId] = now();
      await _rotate(room, announce: false);
      await _announceStart(room);
      _notify();
      return room;
    } catch (_) {
      await _finish(room);
      rethrow;
    }
  });

  void _reserveRoom(GroupCallRoom room) {
    _rooms.removeWhere((_, r) => r.ended);
    scheduleMicrotask(_syncTicking);
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
    room.admission = base64UrlEncode(
      GroupCallCipher.randomKey().take(16).toList(),
    ).replaceAll('=', '');
    room.needsAdmission = true;
    room.leaving = false;
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
      if (room.leaving) throw StateError('Call cancelled.');
      room.joined = true;
      await media.setMuted(room.microphoneMuted);
      _syncMedia(room, const []);
    } catch (_) {
      await media.close();
      _activeGroup = null;
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
    await _fanout(room, 'join', _joinPayload(room));
    room.lastJoinSent = now();
    _notify();
    return room;
  }

  /// The audio device went away mid-call: opens the current one, keeping
  /// the call, its mute, noise suppression and who is heard.
  Future<void> reopenMedia() => _serial(() async {
    final room = active;
    if (_disposed || room == null || !room.joined || room.ended) {
      throw StateError('No joined call to move.');
    }
    await media.close();
    await media.open(room.groupId).timeout(const Duration(seconds: 10));
    await media.setNoiseSuppression(noiseSuppressionEnabled);
    await media.setMuted(room.microphoneMuted);
    _syncMedia(room, const []);
  });

  void _syncMedia(GroupCallRoom room, List<GroupCallParticipant> previous) {
    if (!room.joined) return;
    for (final peer in previous) {
      if (!room.participants.any(
        (p) =>
            p.deviceId == peer.deviceId &&
            p.index == peer.index &&
            p.version == peer.version,
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
      room.distributionKey?.fillRange(0, room.distributionKey!.length, 0);
      room.distributionKey = Uint8List.fromList(key);
      room.needsAdmission = false;
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
        _sendKey(room, peer.deviceId);
      }
    } finally {
      key.fillRange(0, key.length, 0);
    }
  }

  void _sendKey(GroupCallRoom room, String recipient) {
    final key = room.distributionKey;
    final admission =
        room.admissions[recipient] ?? room.joinIntents[recipient]?.$1;
    if (key == null ||
        admission == null ||
        !room.participants.any((p) => p.deviceId == recipient)) {
      return;
    }
    room.admissions[recipient] = admission;
    _dispatchSignal(
      _signal(room, 'key', {
        ..._rosterPayload(room),
        'recipient': recipient,
        'admission': admission,
        'key': base64Encode(key),
      }),
      recipient,
    );
  }

  /// Why the last signal was not taken (the debug log reads it).
  String? lastRefusal;

  bool _refuse(String why) {
    lastRefusal = why;
    return false;
  }

  Future<bool> receiveSignal(
    GroupCallSignal signal, {
    required String authenticatedSender,
  }) {
    if (_disposed || _controlJobs >= 32) {
      lastRefusal = _disposed ? 'disposed' : 'busy';
      return Future.value(false);
    }
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
    final refused = _disposed
        ? 'disposed'
        : signal.senderDeviceId != authenticatedSender
        ? 'not its sender'
        : authenticatedSender == localDeviceId
        ? 'own'
        : _member(signal.groupId, localDeviceId)?.canJoin != true
        ? 'this device cannot join'
        : _member(signal.groupId, authenticatedSender)?.canJoin != true
        ? 'sender cannot join'
        : now().difference(signal.issuedAt).abs() > const Duration(seconds: 15)
        ? 'too old (${now().difference(signal.issuedAt).inSeconds} s)'
        : signal.issuedAt.isAfter(now().add(const Duration(seconds: 2)))
        ? 'from the future'
        : _terminal.contains(_callIdentity(signal.groupId, signal.callId))
        ? 'call over'
        : null;
    if (refused != null) return _refuse(refused);
    var room = roomFor(signal.groupId);
    try {
      if (signal.action == 'start') {
        // Count before allocation or existing-room early returns. Evicting an
        // idle room cannot reset this global discovery/notification budget.
        if (!_startRate.accept(now(), 8)) return _refuse('L594');
        if (room != null && room.callId != signal.callId) {
          return _refuse('L595');
        }
        final started = DateTime.tryParse(
          signal.payload['startedAt'] as String? ?? '',
        );
        final startedBy = signal.payload['startedBy'];
        final signature = signal.payload['startSignature'];
        final term = signal.payload['term'] ?? 0;
        if (started == null ||
            now().difference(started) > const Duration(hours: 24) ||
            started.isAfter(now().add(const Duration(seconds: 2))) ||
            !validGroupCallId(startedBy) ||
            signature is! String ||
            signature.length != 88 ||
            term is! int ||
            term < 0 ||
            term > 0x7fffffff ||
            signal.payload['coordinator'] != authenticatedSender ||
            (room != null &&
                (room.startedBy != startedBy ||
                    room.startedAt != started ||
                    room.startSignature != signature))) {
          return _refuse('L608');
        }
        if (room == null) {
          final proof = base64Decode(signature);
          final bytes = groupCallStartBytes(
            signal.groupId,
            signal.callId,
            startedBy as String,
            started,
          );
          if (proof.length != 64 ||
              !(await (verifyStart == null
                  ? verify(startedBy, bytes, proof)
                  : verifyStart!(signal.groupId, startedBy, bytes, proof)))) {
            return _refuse('L622');
          }
          room = GroupCallRoom(
            groupId: signal.groupId,
            callId: signal.callId,
            startedBy: startedBy,
            startedAt: started,
            coordinator: authenticatedSender,
            term: term,
            startSignature: signature,
            cipher: _cipher(
              signal.groupId,
              signal.callId,
              term: term,
              coordinator: authenticatedSender,
            ),
          );
          if (!_applyRoster(room, signal.payload)) return _refuse('L647');
          _reserveRoom(room);
          room.seen[authenticatedSender] = now();
          _notify();
          await onIncoming?.call(room);
          return true;
        }
        if (!_considerAuthority(room, signal) ||
            !_applyRoster(room, signal.payload, allowSame: true)) {
          return _refuse('L648');
        }
        room.seen[authenticatedSender] = now();
        if (room.joined && !room.connected) room.lastJoinSent = null;
        _notify();
        return true;
      }
      if (room == null || room.callId != signal.callId) return _refuse('L663');
      if (!room.signalRates
          .putIfAbsent(authenticatedSender, GroupCallRateLimit.new)
          .accept(now(), authenticatedSender == room.coordinator ? 48 : 12)) {
        return _refuse('L659');
      }
      if (signal.action != 'join' &&
          signal.action != 'roster' &&
          signal.action != 'key' &&
          (signal.payload['term'] ?? 0) != room.term) {
        return _refuse('L665');
      }
      if (room.participants.any((p) => p.deviceId == authenticatedSender)) {
        room.seen[authenticatedSender] = now();
      }
      switch (signal.action) {
        case 'join':
          final admission = signal.payload['admission'];
          final term = signal.payload['term'] ?? 0;
          if (admission is! String ||
              !RegExp(r'^[A-Za-z0-9_-]{22}$').hasMatch(admission) ||
              term is! int ||
              term < 0 ||
              term > 0x7fffffff) {
            return _refuse('L679');
          }
          final intent = room.joinIntents[authenticatedSender];
          if (intent != null &&
              (signal.issuedAt.isBefore(intent.$2) ||
                  (signal.issuedAt == intent.$2 && admission != intent.$1))) {
            return _refuse('L685');
          }
          if (intent == null && room.joinIntents.length >= 128) {
            final oldest = room.joinIntents.entries.reduce(
              (a, b) => a.value.$2.isBefore(b.value.$2) ? a : b,
            );
            room.joinIntents.remove(oldest.key);
          }
          room.joinIntents[authenticatedSender] = (admission, signal.issuedAt);
          final existing = room.participants
              .where((p) => p.deviceId == authenticatedSender)
              .firstOrNull;
          final previousAdmission = room.admissions[authenticatedSender];
          if (existing != null || room.coordinator == localDeviceId) {
            room.admissions[authenticatedSender] = admission;
          }
          if (room.coordinator != localDeviceId || !room.joined) return true;
          if (existing != null && previousAdmission == admission) {
            if (term == room.term &&
                signal.payload['rosterVersion'] == room.version &&
                signal.payload['epoch'] == room.epoch) {
              return true;
            }
            _dispatchSignal(
              _signal(room, 'roster', _rosterPayload(room)),
              authenticatedSender,
            );
            _sendKey(room, authenticatedSender);
            return true;
          }
          final old = List<GroupCallParticipant>.of(room.participants);
          if (existing == null) {
            if (room.participants.length >= groupCallMaxParticipants) {
              return _refuse('L718');
            }
            final index = List.generate(
              groupCallMaxParticipants,
              (i) => i,
            ).firstWhere((i) => !room!.participants.any((p) => p.index == i));
            room.participants = [
              ...room.participants,
              GroupCallParticipant(authenticatedSender, index),
            ];
          } else {
            if (existing.version >= 0x7fffffff) return _refuse('L737');
            room.participants = room.participants
                .map(
                  (p) => p.deviceId == authenticatedSender
                      ? GroupCallParticipant(p.deviceId, p.index, p.version + 1)
                      : p,
                )
                .toList();
          }
          room.seen[authenticatedSender] = now();
          _syncMedia(room, old);
          await _rotate(room);
        case 'leave':
          if (!room.participants.any(
            (p) => p.deviceId == authenticatedSender,
          )) {
            return _refuse('L745');
          }
          if (signal.payload['epoch'] != room.epoch) return _refuse('L755');
          await _remove(room, authenticatedSender);
        case 'roster':
        case 'key':
          if (signal.action == 'key') {
            if (!room.joined ||
                signal.payload['recipient'] != localDeviceId ||
                room.admission == null ||
                signal.payload['admission'] != room.admission ||
                signal.payload['key'] is! String ||
                (signal.payload['key'] as String).length != 44) {
              return _refuse('L758');
            }
            final key = base64Decode(signal.payload['key'] as String);
            try {
              if (key.length != 32 ||
                  !_validRoster(
                    room,
                    signal.payload,
                    coordinator: authenticatedSender,
                  ) ||
                  ((signal.payload['term'] ?? 0) == room.term &&
                      authenticatedSender == room.coordinator &&
                      signal.payload['epoch'] as int <= room.cipher.epoch) ||
                  !GroupCallParticipant.parse(
                    signal.payload['participants'],
                  ).any((p) => p.deviceId == localDeviceId)) {
                return _refuse('L774');
              }
              // Rejected key messages must not close the current cipher or
              // advance leadership. Validate the entire key action first.
              if (!_considerAuthority(room, signal)) return _refuse('L786');
              if (!_applyRoster(room, signal.payload, allowSame: true)) {
                return _refuse('L780');
              }
              await room.cipher.install(room.epoch, key, room.participants);
              room.needsAdmission = false;
            } finally {
              key.fillRange(0, key.length, 0);
            }
          } else {
            if (!_considerAuthority(room, signal)) return _refuse('L796');
            if (!_applyRoster(room, signal.payload)) return _refuse('L797');
            if (room.joined &&
                !room.participants.any((p) => p.deviceId == localDeviceId)) {
              room.needsAdmission = true;
              room.lastJoinSent = null;
            }
          }
        case 'stats':
          if (!room.participants.any(
            (p) => p.deviceId == authenticatedSender,
          )) {
            return _refuse('L800');
          }
          final stats = GroupCallLinkStats.fromJson(signal.payload);
          if (room.statsIssued[authenticatedSender]?.isAfter(signal.issuedAt) ==
              true) {
            return _refuse('L805');
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
            return _refuse('L818');
          }
          final revision = signal.payload['version'];
          if (revision is! int ||
              revision <= room.topologyVersion ||
              revision > 0x7fffffff) {
            return _refuse('L824');
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
            return _refuse('L841');
          }
          if (forwarder == null &&
              room.participants.length > policy.meshLimit) {
            return _refuse('L845');
          }
          room.topologyVersion = revision;
          _setForwarder(room, forwarder as String?);
          room.stats.addAll(snapshot);
        default:
          return _refuse('L851');
      }
      _notify();
      return true;
    } on FormatException {
      return _refuse('L856');
    } on TypeError {
      return _refuse('L858');
    } on StateError {
      return _refuse('L860');
    }
  });

  bool _validRoster(
    GroupCallRoom room,
    Map<String, dynamic> payload, {
    String? coordinator,
  }) {
    final version = payload['version'];
    final epoch = payload['epoch'];
    if (version is! int ||
        version < 1 ||
        version > 0x7fffffff ||
        epoch is! int ||
        epoch < 1 ||
        epoch > 0xffffffff ||
        payload['coordinator'] != (coordinator ?? room.coordinator)) {
      return false;
    }
    final roster = GroupCallParticipant.parse(payload['participants']);
    return roster.every(
          (p) => _member(room.groupId, p.deviceId)?.canJoin == true,
        ) &&
        roster.any((p) => p.deviceId == (coordinator ?? room.coordinator));
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
    bool resetStream(String id) =>
        gone(id) ||
        previous.any(
          (p) =>
              p.deviceId == id &&
              roster.any(
                (n) =>
                    n.deviceId == id &&
                    (n.version != p.version || n.index != p.index),
              ),
        );
    room.audioSequences.removeWhere((id, _) => resetStream(id));
    room.admissions.removeWhere((id, _) => gone(id));
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
    room.admissions.remove(sender);
    _syncMedia(room, previous);
    if (room.participants.isEmpty) {
      await _finish(room);
      return;
    }
    if (room.coordinator == sender) {
      final coordinator =
          (room.participants.map((p) => p.deviceId).toList()..sort()).first;
      if (room.term >= 0x7fffffff) {
        await _finish(room);
        return;
      }
      _adoptAuthority(room, room.term + 1, coordinator);
    }
    if (room.coordinator == localDeviceId) {
      await _rotate(room);
      await _updateTopology(room);
    }
  }

  Future<void> leave() {
    final requested = active;
    if (requested != null) {
      requested.leaving = true;
      requested.muted = true;
      requested.holdingToTalk = false;
      unawaited(media.setMuted(true).catchError((Object _) {}));
      _notify();
    }
    return _serial(() async {
      final room = requested;
      if (room == null || room.ended) return;
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
          term: room.term + (room.coordinator == localDeviceId ? 1 : 0),
          startSignature: room.startSignature,
          cipher: _cipher(
            room.groupId,
            room.callId,
            term: room.term + (room.coordinator == localDeviceId ? 1 : 0),
            coordinator: coordinator,
          ),
        );
        idle.participants = remaining;
        idle.version = room.coordinator == localDeviceId ? 0 : room.version;
        idle.epoch = room.coordinator == localDeviceId ? 0 : room.epoch;
        idle.allParticipants.addAll(room.allParticipants);
        idle.joinIntents.addAll(room.joinIntents);
        idle.lastJoinIssued = room.lastJoinIssued;
        idle.seen.addAll(room.seen);
        idle.admissions.addAll(room.admissions);
        idle.admissions.remove(localDeviceId);
        idle.outgoingAudioSequence = room.outgoingAudioSequence;
        _rooms[room.groupId] = idle;
      }
      _notify();
    });
  }

  Future<void> _finish(GroupCallRoom room, {bool terminal = true}) async {
    if (room.ended) return;
    final wasJoined = room.joined;
    room.ended = true;
    room.joined = false;
    room.cipher.close();
    room.distributionKey?.fillRange(0, room.distributionKey!.length, 0);
    room.distributionKey = null;
    if (terminal) _terminal.add(_callIdentity(room.groupId, room.callId));
    while (_terminal.length > 128) {
      _terminal.remove(_terminal.first);
    }
    if (_activeGroup == room.groupId) {
      await media.close();
      _activeGroup = null;
    }
    if (wasJoined ||
        (terminal && room.allParticipants.contains(localDeviceId))) {
      await onSummary?.call(
        GroupCallSummary(
          groupId: room.groupId,
          callId: room.callId,
          startedBy: room.startedBy,
          startedAt: room.startedAt,
          endedAt: now(),
          participants: (room.allParticipants.toList()..sort())
              .take(128)
              .toList(),
          callEnded: terminal,
        ),
      );
    }
  }

  Future<void> setMuted(bool value) async {
    final room = active;
    if (room == null) return;
    room.muted = value;
    _notify();
    await media.setMuted(room.microphoneMuted);
  }

  Future<void> setPushToTalk(bool enabled, {bool held = false}) =>
      _setPushToTalk(enabled, held);
  Future<void> _setPushToTalk(bool enabled, bool held) async {
    final room = active;
    if (room == null) return;
    room.pushToTalk = enabled;
    room.holdingToTalk = enabled && held;
    _notify();
    await media.setMuted(room.microphoneMuted);
  }

  Future<void> setNoiseSuppression(bool enabled) async {
    noiseSuppressionEnabled = enabled;
    _notify();
    if (active != null) await media.setNoiseSuppression(enabled);
  }

  Future<void> sendAudio(Uint8List opus) async {
    final room = active;
    if (_disposed ||
        room == null ||
        !room.connected ||
        room.microphoneMuted ||
        _member(room.groupId, localDeviceId)?.canJoin != true ||
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
      if (frame == null ||
          room.ended ||
          !room.connected ||
          !identical(active, room) ||
          (payload[0] == 0 && room.microphoneMuted) ||
          _member(room.groupId, localDeviceId)?.canJoin != true) {
        return;
      }
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
        _member(groupId, localDeviceId)?.canJoin != true ||
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
          !room.connected ||
          !identical(active, room) ||
          _member(groupId, localDeviceId)?.canJoin != true ||
          _member(groupId, frame.sender)?.canJoin != true) {
        return;
      }
      if (!room.participants.any(
        (p) =>
            p.deviceId == frame.sender &&
            p.index == frame.index &&
            p.version == frame.version,
      )) {
        return;
      }
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
    // On a change, and otherwise now and then (pings carry liveness).
    if (room.forwarder != selected ||
        room.lastTopologySent == null ||
        now().difference(room.lastTopologySent!) >=
            const Duration(seconds: 5)) {
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
      }, true);
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
    final live = List<GroupCallRoom>.of(rooms);
    if (live.isEmpty) {
      _syncTicking();
      return;
    }
    for (final room in live) {
      if (_member(room.groupId, localDeviceId)?.canJoin != true) {
        await _finish(
          room,
          terminal: room.participants.every((p) => p.deviceId == localDeviceId),
        );
        continue;
      }
      // An observer has no media heartbeat and no authority to lead a call.
      // Forget stale discovery locally; a fresh signed beacon can recreate it.
      if (!room.joined) {
        if (now().difference(room.seen[room.coordinator] ?? room.startedAt) >
            const Duration(seconds: 15)) {
          await _finish(room, terminal: false);
        }
        continue;
      }
      // Only an authenticated roster admission gives this device authority to
      // remove silent peers. An admitted device retains it while a rotated key
      // is pending; an initial join must wait for the coordinator's roster.
      final admitted = room.participants.any(
        (p) => p.deviceId == localDeviceId,
      );
      final currentForwarder = room.forwarder;
      if (admitted &&
          currentForwarder != null &&
          currentForwarder != localDeviceId &&
          now().difference(room.mediaSeen[currentForwarder] ?? room.startedAt) >
              const Duration(milliseconds: 1500)) {
        room.failedForwarders[currentForwarder] = now().add(
          const Duration(seconds: 5),
        );
        room.lastStatsSent = null;
      }
      final silent = admitted
          ? room.participants
                .where(
                  (p) =>
                      p.deviceId != localDeviceId &&
                      now().difference(
                            room.seen[p.deviceId] ?? room.startedAt,
                          ) >
                          Duration(
                            milliseconds:
                                p.deviceId == room.coordinator ||
                                    p.deviceId == room.forwarder
                                ? 1500
                                : 5000,
                          ),
                )
                .toList()
          : const <GroupCallParticipant>[];
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
      // Asking to join goes to every member until the coordinator admits
      // this device; then only to the call's own members (it lets them
      // notice a roster they missed).
      if (room.lastJoinSent == null ||
          now().difference(room.lastJoinSent!) >= const Duration(seconds: 2)) {
        await _fanout(room, 'join', _joinPayload(room), admitted);
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
        }, true);
        room.lastStatsSent = now();
      }
      await _ping(room);
      await _updateTopology(room);
      if (room.lastStartSent == null ||
          now().difference(room.lastStartSent!) >= const Duration(seconds: 5)) {
        await _announceStart(room);
      }
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
    if (_disposing) return;
    _disposing = true;
    _timer?.cancel();
    // Leaving waits behind earlier operations; one that hangs (a
    // notification, a save) must not keep 1:1 calls blocked until restart.
    // The hardware close below is still waited for.
    try {
      // (No timer at all with no call: nothing can be stuck then.)
      _rooms.isEmpty
          ? await leave()
          : await leave().timeout(const Duration(seconds: 5));
    } catch (_) {
      if (_activeGroup != null) {
        try {
          await media.close().timeout(const Duration(seconds: 5));
        } catch (_) {}
      }
    }
    _disposed = true;
    await _pendingMediaClose;
    for (final room in _rooms.values) {
      room.cipher.close();
      room.distributionKey?.fillRange(0, room.distributionKey!.length, 0);
    }
    _rooms.clear();
    await _changes.close();
  }
}
