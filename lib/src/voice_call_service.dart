import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'models.dart';
import 'platform_bridge.dart';

/// Signaling remains on the authenticated messaging transport. Media engines
/// are intentionally separate so voice frames never enter the message queue.
class VoiceCallSignal {
  const VoiceCallSignal({
    required this.callId,
    required this.action,
    required this.senderDeviceId,
    required this.recipientDeviceId,
    required this.issuedAt,
  });

  final String callId;
  final String action;
  final String senderDeviceId;
  final String recipientDeviceId;
  final DateTime issuedAt;

  Map<String, dynamic> toJson() => {
    'version': 1,
    'callId': callId,
    'action': action,
    'senderDeviceId': senderDeviceId,
    'recipientDeviceId': recipientDeviceId,
    'issuedAt': issuedAt.toUtc().toIso8601String(),
  };

  String encode() => jsonEncode(toJson());

  factory VoiceCallSignal.fromJson(Map<String, dynamic> json) {
    const actions = {
      'invite',
      'accept',
      'busy',
      'cancel',
      'reject',
      'hangup',
      'mute',
      'unmute',
    };
    if (json['version'] != 1 ||
        json['callId'] is! String ||
        json['action'] is! String ||
        json['senderDeviceId'] is! String ||
        json['recipientDeviceId'] is! String) {
      throw const FormatException('Invalid voice call signal.');
    }
    final callId = json['callId'] as String;
    final action = json['action'] as String;
    if (callId.isEmpty || callId.length > 160 || !actions.contains(action)) {
      throw const FormatException('Invalid voice call signal fields.');
    }
    final issuedAt = DateTime.tryParse(json['issuedAt'] as String? ?? '');
    if (issuedAt == null) {
      throw const FormatException('Invalid call timestamp.');
    }
    return VoiceCallSignal(
      callId: json['callId'] as String,
      action: json['action'] as String,
      senderDeviceId: json['senderDeviceId'] as String,
      recipientDeviceId: json['recipientDeviceId'] as String,
      issuedAt: issuedAt.toUtc(),
    );
  }
}

abstract interface class VoiceCallMediaEngine {
  bool get available;
  Future<void> prepare();
  Future<void> open({required String peerDeviceId, required bool outgoing});
  Future<void> setMuted(bool muted);
  Future<bool> setSpeakerphoneEnabled(bool enabled);
  Future<List<String>> availableOutputDevices();
  Future<void> selectOutputDevice(String name);
  Future<void> close();
}

class UnavailableVoiceCallMediaEngine implements VoiceCallMediaEngine {
  const UnavailableVoiceCallMediaEngine();

  @override
  bool get available => false;

  @override
  Future<void> prepare() =>
      Future.error(StateError('Native voice media is unavailable.'));

  @override
  Future<void> open({required String peerDeviceId, required bool outgoing}) =>
      Future.error(StateError('Native voice media is unavailable.'));

  @override
  Future<void> setMuted(bool muted) async {}

  @override
  Future<bool> setSpeakerphoneEnabled(bool enabled) async => false;

  @override
  Future<List<String>> availableOutputDevices() async => const [];

  @override
  Future<void> selectOutputDevice(String name) =>
      Future.error(StateError('Manual audio output selection is unavailable.'));

  @override
  Future<void> close() async {}
}

/// Adapter used by the controller. Native implementations may expose
/// capture/Opus/datagrams behind the same bounded platform interface; a
/// missing handler remains an explicit, safe media-unavailable state.
class PlatformVoiceCallMediaEngine implements VoiceCallMediaEngine {
  const PlatformVoiceCallMediaEngine(this.bridge);

  final PlatformBridge bridge;

  @override
  bool get available => bridge.supportsVoiceCallMedia;

  @override
  Future<void> prepare() => bridge.prepareVoiceCallMedia();

  @override
  Future<void> open({
    required String peerDeviceId,
    required bool outgoing,
  }) async {
    if (!await bridge.openVoiceCallMedia(
      peerDeviceId: peerDeviceId,
      outgoing: outgoing,
    )) {
      throw StateError('Native voice media is unavailable.');
    }
  }

  @override
  Future<void> setMuted(bool muted) => bridge.setVoiceCallMuted(muted);

  @override
  Future<bool> setSpeakerphoneEnabled(bool enabled) =>
      bridge.setVoiceCallSpeakerphoneEnabled(enabled);

  @override
  Future<List<String>> availableOutputDevices() =>
      bridge.voiceCallOutputDevices();

  @override
  Future<void> selectOutputDevice(String name) =>
      bridge.selectVoiceCallOutputDevice(name);

  @override
  Future<void> close() => bridge.closeVoiceCallMedia();
}

abstract interface class VoiceCallSignalTransport {
  Future<void> send(VoiceCallSignal signal);
}

/// Foreground call state machine. It deliberately owns no audio buffers and
/// requires the caller to authenticate the peer before passing signals here.
class VoiceCallService {
  VoiceCallService({
    required this.localDeviceId,
    required this.transport,
    VoiceCallMediaEngine? media,
    DateTime Function()? now,
    Duration connectionTimeout = const Duration(seconds: 15),
    Duration mediaInactivityTimeout = const Duration(seconds: 5),
    Iterable<String> terminalCallIds = const <String>[],
    Future<void> Function(VoiceCallSummary summary)? onTerminal,
  }) : media = media ?? const UnavailableVoiceCallMediaEngine(),
       _now = now ?? DateTime.now,
       _connectionTimeout = connectionTimeout,
       _mediaInactivityTimeout = mediaInactivityTimeout,
       _terminalCallIds = LinkedHashSet<String>.of(terminalCallIds.take(128)),
       _onTerminal = onTerminal;

  final String localDeviceId;
  final VoiceCallSignalTransport transport;
  final VoiceCallMediaEngine media;
  final DateTime Function() _now;
  final Duration _connectionTimeout;
  final Duration _mediaInactivityTimeout;
  final StreamController<VoiceCallSession?> _changes =
      StreamController<VoiceCallSession?>.broadcast();
  final LinkedHashSet<String> _terminalCallIds;
  final Future<void> Function(VoiceCallSummary summary)? _onTerminal;
  VoiceCallSession? _active;
  Timer? _ringTimer;
  Timer? _reconnectTimer;
  Timer? _mediaInactivityTimer;
  Future<void>? _terminalTransition;
  int _outboundMediaFailures = 0;
  int _outgoingCallSequence = 0;

  VoiceCallSession? get active => _active;
  Stream<VoiceCallSession?> get changes => _changes.stream;

  Future<VoiceCallSession> startOutgoing(String peerDeviceId) async {
    final terminalTransition = _terminalTransition;
    if (terminalTransition != null) await terminalTransition;
    if (_active != null && _active!.state != VoiceCallState.ended) {
      throw StateError('Only one voice call can be active on this device.');
    }
    if (!media.available) {
      throw StateError('Voice calls are not available on this build yet.');
    }
    await media.prepare().timeout(_connectionTimeout);
    final callId =
        '$localDeviceId:${_now().microsecondsSinceEpoch}:${++_outgoingCallSequence}';
    final session = VoiceCallSession(
      callId: callId,
      peerDeviceId: peerDeviceId,
      outgoing: true,
      startedAt: _now().toUtc(),
    );
    _set(session);
    _startRingExpiry(session, issuedAt: session.startedAt);
    try {
      await transport
          .send(_signal(session, 'invite'))
          .timeout(const Duration(seconds: 45));
      if (_active?.callId != session.callId ||
          _active?.state == VoiceCallState.ended) {
        throw StateError('The call invitation expired before it was sent.');
      }
    } catch (error) {
      if (_active?.callId == session.callId &&
          _active?.state != VoiceCallState.ended) {
        _ringTimer?.cancel();
        _set(
          session.copyWith(
            state: VoiceCallState.ended,
            failureReason: 'Could not send the call invitation: $error',
          ),
        );
        final summarySaved = _recordTerminalSummary(
          _active!,
          priorState: session.state,
        );
        try {
          await media.close();
        } catch (_) {
          // A failed invitation must release any media resources prepared
          // before transport or capability validation completed.
        }
        await summarySaved;
      }
      rethrow;
    }
    return _active ?? session;
  }

  Future<bool> receiveInvite(VoiceCallSignal signal) async {
    final signalAge = _now().toUtc().difference(signal.issuedAt.toUtc());
    if (signal.recipientDeviceId != localDeviceId ||
        signalAge > const Duration(seconds: 45) ||
        signalAge < const Duration(seconds: -5) ||
        _terminalCallIds.contains(signal.callId)) {
      return false;
    }
    final terminalTransition = _terminalTransition;
    if (terminalTransition != null) await terminalTransition;
    final refreshedAge = _now().toUtc().difference(signal.issuedAt.toUtc());
    if (refreshedAge > const Duration(seconds: 45) ||
        refreshedAge < const Duration(seconds: -5) ||
        _terminalCallIds.contains(signal.callId)) {
      return false;
    }
    if (!media.available) {
      await transport.send(
        VoiceCallSignal(
          callId: signal.callId,
          action: 'busy',
          senderDeviceId: localDeviceId,
          recipientDeviceId: signal.senderDeviceId,
          issuedAt: _now().toUtc(),
        ),
      );
      return false;
    }
    final active = _active;
    if (active != null && active.state != VoiceCallState.ended) {
      final simultaneousRinging =
          active.outgoing && active.state == VoiceCallState.ringing;
      if (simultaneousRinging && active.callId.compareTo(signal.callId) > 0) {
        await end(
          reason: 'Replaced by simultaneous incoming call.',
          signalAction: 'cancel',
        );
      } else {
        await transport.send(
          VoiceCallSignal(
            callId: signal.callId,
            action: 'busy',
            senderDeviceId: localDeviceId,
            recipientDeviceId: signal.senderDeviceId,
            issuedAt: _now().toUtc(),
          ),
        );
        return false;
      }
    }
    final session = VoiceCallSession(
      callId: signal.callId,
      peerDeviceId: signal.senderDeviceId,
      outgoing: false,
      startedAt: signal.issuedAt,
    );
    _set(session);
    _startRingExpiry(session, issuedAt: signal.issuedAt);
    return true;
  }

  Future<void> accept() async {
    final session = _active;
    if (session == null ||
        session.outgoing ||
        session.state != VoiceCallState.ringing) {
      return;
    }
    final connecting = session.copyWith(state: VoiceCallState.connecting);
    _ringTimer?.cancel();
    _set(connecting);
    _startConnectionExpiry(connecting, reason: 'Voice connection timed out.');
    try {
      await media.prepare().timeout(_connectionTimeout);
      if (!_isConnecting(connecting.callId)) return;
      await transport
          .send(_signal(connecting, 'accept'))
          .timeout(_connectionTimeout);
      if (!_isConnecting(connecting.callId)) return;
      await media
          .open(peerDeviceId: session.peerDeviceId, outgoing: false)
          .timeout(_connectionTimeout);
      if (!_isConnecting(connecting.callId)) return;
      _markConnected(connecting.callId);
    } catch (error) {
      await end(reason: 'Could not establish voice media: $error');
    }
  }

  Future<void> onAccepted({required String callId}) async {
    final session = _active;
    if (session == null ||
        session.callId != callId ||
        session.state == VoiceCallState.ended ||
        !session.outgoing ||
        session.state != VoiceCallState.ringing) {
      return;
    }
    _ringTimer?.cancel();
    final connecting = session.copyWith(state: VoiceCallState.connecting);
    _set(connecting);
    _startConnectionExpiry(connecting, reason: 'Voice connection timed out.');
    try {
      await media
          .open(peerDeviceId: session.peerDeviceId, outgoing: true)
          .timeout(_connectionTimeout);
      if (!_isConnecting(connecting.callId)) return;
      _markConnected(connecting.callId);
    } catch (error) {
      await end(reason: 'Could not establish voice media: $error');
    }
  }

  Future<void> toggleMute() async {
    final session = _requireActive();
    final muted = !session.muted;
    await media.setMuted(muted);
    _set(session.copyWith(muted: muted));
    await transport.send(_signal(_requireActive(), muted ? 'mute' : 'unmute'));
  }

  Future<void> toggleSpeakerphone() async {
    final session = _requireActive();
    final enabled = !session.speakerphoneEnabled;
    if (!await media.setSpeakerphoneEnabled(enabled)) {
      throw StateError('Speakerphone routing is unavailable on this device.');
    }
    if (_active?.callId == session.callId &&
        _active?.state != VoiceCallState.ended) {
      _set(session.copyWith(speakerphoneEnabled: enabled));
    }
  }

  Future<List<String>> availableOutputDevices() =>
      media.availableOutputDevices();

  Future<void> selectOutputDevice(String name) =>
      media.selectOutputDevice(name);

  Future<void> reconnecting({required String callId}) async {
    final session = _active;
    if (session == null ||
        session.callId != callId ||
        session.state == VoiceCallState.ended ||
        session.state == VoiceCallState.reconnecting) {
      return;
    }
    _mediaInactivityTimer?.cancel();
    _set(session.copyWith(state: VoiceCallState.reconnecting));
    _startConnectionExpiry(session, reason: 'Voice connection timed out.');
  }

  /// Records authenticated inbound media. A reconnecting call becomes
  /// connected again only after a fresh frame from the same peer arrives.
  void noteMediaReceived(String callId) {
    var session = _active;
    if (session == null ||
        session.callId != callId ||
        (session.state != VoiceCallState.connected &&
            session.state != VoiceCallState.reconnecting)) {
      return;
    }
    _outboundMediaFailures = 0;
    if (session.state == VoiceCallState.reconnecting) {
      _reconnectTimer?.cancel();
      session = session.copyWith(state: VoiceCallState.connected);
      _set(session);
    }
    _armMediaInactivityTimer(session);
  }

  void noteMediaSendSucceeded(String callId) {
    if (_active?.callId == callId) _outboundMediaFailures = 0;
  }

  void noteMediaSendFailed(String callId) {
    final session = _active;
    if (session == null ||
        session.callId != callId ||
        (session.state != VoiceCallState.connected &&
            session.state != VoiceCallState.reconnecting)) {
      return;
    }
    _outboundMediaFailures++;
    if (_outboundMediaFailures >= 3) {
      _outboundMediaFailures = 0;
      unawaited(reconnecting(callId: callId));
    }
  }

  Future<void> end({String reason = 'Call ended', String? signalAction}) =>
      _terminate(reason: reason, signalAction: signalAction, notifyPeer: true);

  /// Closes a session in response to authenticated remote signaling without
  /// echoing another terminal signal back to the caller.
  Future<void> endRemote({required String reason}) =>
      _terminate(reason: reason, notifyPeer: false);

  Future<void> _terminate({
    required String reason,
    String? signalAction,
    required bool notifyPeer,
  }) {
    final pending = _terminalTransition;
    if (pending != null) return pending;
    final session = _active;
    if (session == null || session.state == VoiceCallState.ended) {
      return Future<void>.value();
    }
    final completer = Completer<void>();
    final completion = completer.future;
    _terminalTransition = completion;
    Future<void> finish() async {
      final action =
          signalAction ??
          (session.state == VoiceCallState.ringing
              ? (session.outgoing ? 'cancel' : 'reject')
              : 'hangup');
      _ringTimer?.cancel();
      _reconnectTimer?.cancel();
      _mediaInactivityTimer?.cancel();
      // Publish the terminal state before awaiting platform teardown or disk
      // I/O so a late permission/media completion cannot revive this call.
      final ended = session.copyWith(
        state: VoiceCallState.ended,
        failureReason: reason,
      );
      _set(ended);
      final summarySaved = _recordTerminalSummary(
        ended,
        priorState: session.state,
      );
      try {
        await media.close();
      } catch (_) {}
      await summarySaved;
      if (notifyPeer) {
        try {
          await transport.send(_signal(session, action));
        } catch (_) {
          // Local teardown must finish even when the peer cannot be reached.
        }
      }
    }

    finish().then(
      (_) {
        if (identical(_terminalTransition, completion)) {
          _terminalTransition = null;
        }
        completer.complete();
      },
      onError: (Object error, StackTrace stackTrace) {
        if (identical(_terminalTransition, completion)) {
          _terminalTransition = null;
        }
        completer.completeError(error, stackTrace);
      },
    );
    return completion;
  }

  Future<void> dispose() async {
    await end(reason: 'Call service disposed');
    await _changes.close();
  }

  VoiceCallSignal _signal(VoiceCallSession session, String action) =>
      VoiceCallSignal(
        callId: session.callId,
        action: action,
        senderDeviceId: localDeviceId,
        recipientDeviceId: session.peerDeviceId,
        issuedAt: _now().toUtc(),
      );

  VoiceCallSession _requireActive() {
    final session = _active;
    if (session == null || session.state == VoiceCallState.ended) {
      throw StateError('No active voice call.');
    }
    return session;
  }

  void _startRingExpiry(
    VoiceCallSession session, {
    required DateTime issuedAt,
  }) {
    _ringTimer?.cancel();
    final remaining = issuedAt
        .toUtc()
        .add(const Duration(seconds: 45))
        .difference(_now().toUtc());
    _ringTimer = Timer(remaining.isNegative ? Duration.zero : remaining, () {
      if (_active?.callId == session.callId &&
          _active?.state == VoiceCallState.ringing) {
        unawaited(end(reason: 'No answer.'));
      }
    });
  }

  bool _isConnecting(String callId) =>
      _active?.callId == callId && _active?.state == VoiceCallState.connecting;

  void _markConnected(String callId) {
    final session = _active;
    if (session == null || session.callId != callId) return;
    if (session.state != VoiceCallState.connecting &&
        session.state != VoiceCallState.reconnecting) {
      return;
    }
    _reconnectTimer?.cancel();
    _outboundMediaFailures = 0;
    final connected = session.copyWith(state: VoiceCallState.connected);
    _set(connected);
    _armMediaInactivityTimer(connected);
  }

  void _armMediaInactivityTimer(VoiceCallSession session) {
    _mediaInactivityTimer?.cancel();
    if (session.state != VoiceCallState.connected) return;
    _mediaInactivityTimer = Timer(_mediaInactivityTimeout, () {
      final active = _active;
      if (active?.callId == session.callId &&
          active?.state == VoiceCallState.connected) {
        unawaited(reconnecting(callId: session.callId));
      }
    });
  }

  void _rememberTerminalCallId(String callId) {
    _terminalCallIds.remove(callId);
    _terminalCallIds.add(callId);
    while (_terminalCallIds.length > 128) {
      _terminalCallIds.remove(_terminalCallIds.first);
    }
  }

  Future<void> _recordTerminalSummary(
    VoiceCallSession ended, {
    required VoiceCallState priorState,
  }) async {
    _rememberTerminalCallId(ended.callId);
    final reason = ended.failureReason;
    final lowerReason = reason?.toLowerCase() ?? '';
    final outcome = priorState == VoiceCallState.ringing
        ? lowerReason == 'no answer.' || lowerReason.contains('remote canceled')
              ? 'missed'
              : lowerReason.contains('busy') || lowerReason.contains('reject')
              ? 'rejected'
              : ended.outgoing
              ? 'canceled'
              : 'rejected'
        : reason == 'Call ended' || reason == 'Remote hang-up'
        ? 'completed'
        : 'failed';
    final now = _now();
    try {
      await _onTerminal?.call(
        VoiceCallSummary(
          callId: ended.callId,
          peerDeviceId: ended.peerDeviceId,
          outgoing: ended.outgoing,
          startedAt: ended.startedAt,
          endedAt: now.isBefore(ended.startedAt) ? ended.startedAt : now,
          outcome: outcome,
          reason: reason == null || reason.length > 256
              ? reason?.substring(0, 256)
              : reason,
        ),
      );
    } catch (_) {
      // Persistence failure must not strand audio resources or block hangup.
    }
  }

  void _startConnectionExpiry(
    VoiceCallSession session, {
    required String reason,
  }) {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(_connectionTimeout, () {
      final active = _active;
      if (active?.callId == session.callId &&
          (active?.state == VoiceCallState.connecting ||
              active?.state == VoiceCallState.reconnecting)) {
        unawaited(end(reason: reason));
      }
    });
  }

  void _set(VoiceCallSession session) {
    _active = session;
    _changes.add(session);
  }
}
