import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:conest/src/models.dart';
import 'package:conest/src/platform_bridge.dart';
import 'package:conest/src/voice_call_service.dart';
import 'package:conest/src/voice_message_service.dart';
import 'package:record/record.dart';

class _CountingRecordPlatform extends RecordPlatform {
  int createCalls = 0;
  int cancelCalls = 0;

  @override
  Future<void> create(String recorderId) async {
    createCalls++;
  }

  @override
  Future<void> cancel(String recorderId) async {
    cancelCalls++;
  }

  @override
  Future<void> dispose(String recorderId) async {}

  @override
  Future<String?> stop(String recorderId) async => null;

  @override
  Future<bool> hasPermission(String recorderId, {bool request = true}) async =>
      true;

  @override
  Future<bool> isEncoderSupported(
    String recorderId,
    AudioEncoder encoder,
  ) async => true;

  @override
  Future<void> start(
    String recorderId,
    RecordConfig config, {
    required String path,
  }) async {}

  @override
  Future<Stream<Uint8List>> startStream(
    String recorderId,
    RecordConfig config,
  ) async => const Stream<Uint8List>.empty();

  @override
  Future<void> pause(String recorderId) async {}

  @override
  Future<void> resume(String recorderId) async {}

  @override
  Future<bool> isRecording(String recorderId) async => false;

  @override
  Future<bool> isPaused(String recorderId) async => false;

  @override
  Future<Amplitude> getAmplitude(String recorderId) async =>
      Amplitude(current: -60, max: -60);

  @override
  Future<List<InputDevice>> listInputDevices(String recorderId) async => [];

  @override
  Stream<RecordState> onStateChanged(String recorderId) =>
      const Stream<RecordState>.empty();
}

class _FakeVoiceCaptureBridge extends PlatformBridge {
  _FakeVoiceCaptureBridge({this.startGate, this.stopGate});

  final Completer<void>? startGate;
  final Completer<void>? stopGate;
  final Completer<void> started = Completer<void>();
  final Completer<void> stopEntered = Completer<void>();
  String? recordingPath;
  int startCalls = 0;
  int stopCalls = 0;
  int cancelCalls = 0;

  @override
  bool get supportsNativeVoiceMessageRecording => true;

  @override
  Future<void> startVoiceMessageRecording(String path) async {
    startCalls++;
    recordingPath = path;
    if (!started.isCompleted) started.complete();
    if (startGate != null) await startGate!.future;
    await File(path).writeAsBytes([0x4f, 0x67, 0x67, 0x53, 0x00]);
  }

  @override
  Future<Map<String, dynamic>> stopVoiceMessageRecording() async {
    stopCalls++;
    if (!stopEntered.isCompleted) stopEntered.complete();
    if (stopGate != null) await stopGate!.future;
    return {
      'waveform': [12, 128, 244],
    };
  }

  @override
  Future<void> cancelVoiceMessageRecording() async {
    cancelCalls++;
    final path = recordingPath;
    if (path != null) {
      final file = File(path);
      if (await file.exists()) await file.delete();
    }
  }
}

void main() {
  test(
    'voice interruption during native startup keeps an unsent preview',
    () async {
      final support = await Directory.systemTemp.createTemp('conest-voice-');
      addTearDown(() => support.delete(recursive: true));
      final startGate = Completer<void>();
      final bridge = _FakeVoiceCaptureBridge(startGate: startGate);
      var now = DateTime.utc(2026, 9, 23, 12);
      final service = VoiceMessageService(
        platformBridge: bridge,
        applicationSupportDirectory: () async => support,
        now: () => now,
      );
      addTearDown(service.dispose);

      final starting = service.start(destinationKey: 'direct:peer');
      await bridge.started.future;
      await service.stopForInterruption();
      now = now.add(const Duration(seconds: 2));
      startGate.complete();
      await starting;

      expect(service.state, VoiceRecordingState.preview);
      expect(service.previewDestinationKey, 'direct:peer');
      expect(service.preview?.metadata.durationMs, 2000);
      expect(bridge.stopCalls, 1);
      expect(bridge.cancelCalls, 0);
      expect(await File(bridge.recordingPath!).exists(), isTrue);

      await service.completePreview();
      expect(service.state, VoiceRecordingState.idle);
      expect(await File(bridge.recordingPath!).exists(), isFalse);
    },
  );

  test(
    'cancel during native startup never invokes the plugin recorder',
    () async {
      final support = await Directory.systemTemp.createTemp('conest-voice-');
      addTearDown(() => support.delete(recursive: true));
      final previousRecordPlatform = RecordPlatform.instance;
      final recordPlatform = _CountingRecordPlatform();
      RecordPlatform.instance = recordPlatform;
      final startGate = Completer<void>();
      final bridge = _FakeVoiceCaptureBridge(startGate: startGate);
      final service = VoiceMessageService(
        platformBridge: bridge,
        applicationSupportDirectory: () async => support,
        now: () => DateTime.utc(2026, 9, 23, 12),
      );
      addTearDown(() async {
        await service.dispose();
        RecordPlatform.instance = previousRecordPlatform;
      });

      final starting = service.start(destinationKey: 'direct:peer');
      await bridge.started.future;
      await service.cancel();
      startGate.complete();
      await expectLater(starting, throwsA(isA<StateError>()));

      expect(bridge.cancelCalls, 1);
      expect(recordPlatform.createCalls, 0);
      expect(recordPlatform.cancelCalls, 0);
      expect(service.state, VoiceRecordingState.idle);
      expect(await File(bridge.recordingPath!).exists(), isFalse);
    },
  );

  test(
    'overlapping voice stop interruption and cancel stop native capture once',
    () async {
      final support = await Directory.systemTemp.createTemp('conest-voice-');
      addTearDown(() => support.delete(recursive: true));
      final stopGate = Completer<void>();
      final bridge = _FakeVoiceCaptureBridge(stopGate: stopGate);
      var now = DateTime.utc(2026, 9, 23, 13);
      final service = VoiceMessageService(
        platformBridge: bridge,
        applicationSupportDirectory: () async => support,
        now: () => now,
      );
      addTearDown(service.dispose);

      await service.start(destinationKey: 'group:chat');
      final stopping = service.stop();
      await bridge.stopEntered.future;
      final interrupted = service.stopForInterruption();
      final canceled = service.cancel();
      now = now.add(const Duration(seconds: 2));
      stopGate.complete();
      final preview = await stopping;
      await interrupted;
      await canceled;

      expect(preview.metadata.durationMs, 2000);
      expect(bridge.stopCalls, 1);
      expect(bridge.cancelCalls, 0);
      expect(service.state, VoiceRecordingState.idle);
      expect(service.preview, isNull);
      expect(await File(preview.path).exists(), isFalse);
    },
  );

  test('voice disposal waits for startup cancellation and prevents reuse', () async {
    final support = await Directory.systemTemp.createTemp('conest-voice-');
    addTearDown(() => support.delete(recursive: true));
    final gate = Completer<void>();
    final bridge = _FakeVoiceCaptureBridge(startGate: gate);
    final service = VoiceMessageService(
      platformBridge: bridge,
      applicationSupportDirectory: () async => support,
    );
    final starting = service.start(destinationKey: 'direct:peer');
    final failedStart = expectLater(starting, throwsStateError);
    await bridge.started.future;
    var disposed = false;
    final disposing = service.dispose().then((_) => disposed = true);
    await Future<void>.delayed(Duration.zero);
    expect(disposed, isFalse);
    gate.complete();
    await failedStart;
    await disposing;
    expect(bridge.cancelCalls, 1);
    expect(await File(bridge.recordingPath!).exists(), isFalse);
    expect(service.state, VoiceRecordingState.idle);
    await expectLater(
      service.start(destinationKey: 'direct:peer'),
      throwsStateError,
    );
    await service.dispose();
    expect(bridge.cancelCalls, 1);
  });

  test('outgoing microphone setup reserves its call slot and cannot revive', () async {
    final media = _GatedPrepareMedia();
    final signals = <VoiceCallSignal>[];
    final service = VoiceCallService(
      localDeviceId: 'me',
      transport: _TestCallTransport(signals),
      media: media,
    );
    final starting = service.startOutgoing('peer');
    final failedStart = expectLater(starting, throwsStateError);
    await media.entered.future;
    await expectLater(service.startOutgoing('other'), throwsStateError);
    await service.dispose();
    media.gate.complete();
    await failedStart;
    expect(service.active?.state, VoiceCallState.ended);
    expect(signals.where((signal) => signal.action == 'invite'), isEmpty);
    await expectLater(service.startOutgoing('peer'), throwsStateError);
  });

  test('delayed mute cannot revive a call after hangup', () async {
    final media = _GatedMuteMedia();
    final signals = <VoiceCallSignal>[];
    final service = VoiceCallService(
      localDeviceId: 'me',
      transport: _TestCallTransport(signals),
      media: media,
    );
    await service.startOutgoing('peer');
    final muting = service.toggleMute();
    await media.entered.future;
    await service.end();
    media.gate.complete();
    await muting;
    expect(service.active?.state, VoiceCallState.ended);
    expect(signals.where((signal) => signal.action == 'mute'), isEmpty);
    await service.dispose();
  });

  test('voice startup cleanup removes only abandoned recordings', () async {
    final directory = await Directory.systemTemp.createTemp('conest-voice-');
    addTearDown(() => directory.delete(recursive: true));
    final abandoned = File('${directory.path}/voice-12345.ogg');
    final unrelated = File('${directory.path}/keep.ogg');
    await abandoned.writeAsString('partial recording');
    await unrelated.writeAsString('user data');

    await VoiceMessageService.cleanupAbandonedRecordings(directory: directory);

    expect(await abandoned.exists(), isFalse);
    expect(await unrelated.readAsString(), 'user data');
  });

  test('folders and scheduled messages round trip with UTC instants', () {
    final now = DateTime.utc(2026, 9, 22, 18);
    final folder = ChatFolder(
      id: 'folder-1',
      name: 'Work',
      conversationIds: ['a', 'a', 'b'],
      createdAt: now,
      updatedAt: now,
    );
    expect(ChatFolder.fromJson(folder.toJson()).conversationIds, ['a', 'b']);
    final scheduled = ScheduledMessage(
      id: 'scheduled-1',
      conversationId: 'peer',
      conversationKind: 'direct',
      body: 'later',
      scheduledAtUtc: now.add(const Duration(hours: 2)),
      createdAt: now,
    );
    expect(
      ScheduledMessage.fromJson(scheduled.toJson()).scheduledAtUtc,
      now.add(const Duration(hours: 2)),
    );
    expect(scheduled.copyWith(body: 'edited').body, 'edited');
  });

  test('poll projection uses latest vote per authenticated device', () {
    final poll = PollDefinition(
      id: 'poll-1',
      question: 'Pick',
      options: ['a', 'b'],
      mode: PollChoiceMode.single,
      creatorDeviceId: 'owner',
      createdAt: DateTime.utc(2026, 1, 1),
    );
    final first = PollVote(
      pollId: poll.id,
      voterDeviceId: 'voter',
      optionIndexes: ['0'],
      changedAt: DateTime.utc(2026, 1, 1, 0, 1),
    );
    final second = PollVote(
      pollId: poll.id,
      voterDeviceId: 'voter',
      optionIndexes: ['1'],
      changedAt: DateTime.utc(2026, 1, 1, 0, 2),
    );
    final projection = PollProjection(
      definition: poll,
      votes: {second.voterDeviceId: second},
    );
    expect(projection.counts(), [0, 1]);
    expect(first.changedAt.isBefore(second.changedAt), isTrue);
  });

  test('poll payload decoding rejects malformed choices and versions', () {
    final poll = PollDefinition(
      id: 'poll-1',
      question: 'Choose',
      options: ['one', 'two'],
      mode: PollChoiceMode.single,
      creatorDeviceId: 'owner',
      createdAt: DateTime.utc(2026, 1, 1),
    );
    expect(PollDefinition.fromJson(poll.toJson()).options, ['one', 'two']);
    expect(
      () => PollDefinition.fromJson({
        ...poll.toJson(),
        'options': ['one'],
      }),
      throwsFormatException,
    );
    expect(
      () => PollDefinition.fromJson({...poll.toJson(), 'version': 2}),
      throwsFormatException,
    );
    expect(
      () => PollVote.fromJson({
        'pollId': 'poll-1',
        'voterDeviceId': 'voter',
        'optionIndexes': ['10'],
        'changedAt': DateTime.utc(2026, 1, 1).toIso8601String(),
      }),
      throwsFormatException,
    );
  });

  test('vault snapshots preserve folders and scheduled entries', () {
    final now = DateTime.utc(2026, 1, 1);
    final snapshot = VaultSnapshot.empty().copyWith(
      chatFolders: [
        ChatFolder(
          id: 'f',
          name: 'Pinned work',
          conversationIds: ['peer'],
          createdAt: now,
          updatedAt: now,
        ),
      ],
      scheduledMessages: [
        ScheduledMessage(
          id: 's',
          conversationId: 'peer',
          conversationKind: ConversationKind.direct.name,
          body: 'hello',
          scheduledAtUtc: now.add(const Duration(minutes: 5)),
          createdAt: now,
        ),
      ],
      voiceCallSummaries: [
        VoiceCallSummary(
          callId: 'call-1',
          peerDeviceId: 'peer',
          outgoing: false,
          startedAt: now,
          endedAt: now.add(const Duration(minutes: 2)),
          outcome: 'completed',
        ),
      ],
    );
    final restored = VaultSnapshot.fromJson(snapshot.toJson());
    expect(restored.chatFolders.single.name, 'Pinned work');
    expect(restored.scheduledMessages.single.body, 'hello');
    expect(restored.voiceCallSummaries.single.callId, 'call-1');
    expect(restored.voiceCallSummaries.single.outcome, 'completed');
  });

  test(
    'voice call service enforces one active call and expires signals',
    () async {
      final signals = <VoiceCallSignal>[];
      final transport = _TestCallTransport(signals);
      final service = VoiceCallService(
        localDeviceId: 'me',
        transport: transport,
        media: const _WorkingMedia(),
        now: () => DateTime.utc(2026, 1, 1),
      );
      final session = await service.startOutgoing('peer');
      expect(session.state, VoiceCallState.ringing);
      expect(signals.single.action, 'invite');
      expect(() => service.startOutgoing('other'), throwsStateError);
      await service.onAccepted(callId: session.callId);
      expect(service.active!.state, VoiceCallState.connected);
      await service.toggleMute();
      expect(service.active!.muted, isTrue);
      await service.toggleSpeakerphone();
      expect(service.active!.speakerphoneEnabled, isTrue);
      await service.end();
      expect(service.active!.state, VoiceCallState.ended);
      await service.dispose();
    },
  );

  test(
    'connected calls are not replaced by a late simultaneous invite',
    () async {
      final signals = <VoiceCallSignal>[];
      final service = VoiceCallService(
        localDeviceId: 'z-device',
        transport: _TestCallTransport(signals),
        media: const _WorkingMedia(),
        now: () => DateTime.utc(2026, 1, 1),
      );
      final outgoing = await service.startOutgoing('peer');
      await service.onAccepted(callId: outgoing.callId);

      final accepted = await service.receiveInvite(
        VoiceCallSignal(
          callId: 'a-device:simultaneous',
          action: 'invite',
          senderDeviceId: 'peer',
          recipientDeviceId: 'z-device',
          issuedAt: DateTime.utc(2026, 1, 1),
        ),
      );

      expect(accepted, isFalse);
      expect(service.active?.callId, outgoing.callId);
      expect(service.active?.state, VoiceCallState.connected);
      expect(signals.last.action, 'busy');
      await service.end();
      await service.dispose();
    },
  );

  test(
    'ringing cancellation and rejection use terminal call signals',
    () async {
      final outgoingSignals = <VoiceCallSignal>[];
      final outgoing = VoiceCallService(
        localDeviceId: 'me',
        transport: _TestCallTransport(outgoingSignals),
        media: const _WorkingMedia(),
        now: () => DateTime.utc(2026, 1, 1),
      );
      await outgoing.startOutgoing('peer');
      await outgoing.end(reason: 'Canceled by user.');
      expect(outgoingSignals.map((signal) => signal.action), [
        'invite',
        'cancel',
      ]);
      await outgoing.dispose();

      final incomingSignals = <VoiceCallSignal>[];
      final incoming = VoiceCallService(
        localDeviceId: 'me',
        transport: _TestCallTransport(incomingSignals),
        media: const _WorkingMedia(),
        now: () => DateTime.utc(2026, 1, 1),
      );
      await incoming.receiveInvite(
        VoiceCallSignal(
          callId: 'peer:incoming',
          action: 'invite',
          senderDeviceId: 'peer',
          recipientDeviceId: 'me',
          issuedAt: DateTime.utc(2026, 1, 1),
        ),
      );
      await incoming.end(reason: 'Rejected by user.');
      expect(incomingSignals.single.action, 'reject');
      await incoming.dispose();
    },
  );

  test(
    'ended call IDs cannot ring again or revive on a delayed accept',
    () async {
      final signals = <VoiceCallSignal>[];
      final service = VoiceCallService(
        localDeviceId: 'me',
        transport: _TestCallTransport(signals),
        media: const _WorkingMedia(),
        now: () => DateTime.utc(2026, 1, 1),
      );
      final outgoing = await service.startOutgoing('peer');
      await service.end(reason: 'User rejected retry.', signalAction: 'cancel');

      await service.onAccepted(callId: outgoing.callId);
      final replayedInvite = await service.receiveInvite(
        VoiceCallSignal(
          callId: outgoing.callId,
          action: 'invite',
          senderDeviceId: 'peer',
          recipientDeviceId: 'me',
          issuedAt: DateTime.utc(2026, 1, 1),
        ),
      );

      expect(replayedInvite, isFalse);
      expect(service.active?.state, VoiceCallState.ended);
      expect(signals.map((signal) => signal.action), ['invite', 'cancel']);
      await service.dispose();
    },
  );

  test(
    'terminal call summary persists replay protection across restart',
    () async {
      final signals = <VoiceCallSignal>[];
      final summaries = <VoiceCallSummary>[];
      final now = DateTime.utc(2026, 1, 1);
      final service = VoiceCallService(
        localDeviceId: 'me',
        transport: _TestCallTransport(signals),
        media: const _WorkingMedia(),
        now: () => now,
        onTerminal: (summary) async {
          summaries.add(summary);
        },
      );
      final invite = VoiceCallSignal(
        callId: 'peer:persisted-call',
        action: 'invite',
        senderDeviceId: 'peer',
        recipientDeviceId: 'me',
        issuedAt: now,
      );
      expect(await service.receiveInvite(invite), isTrue);
      await service.end(reason: 'Rejected by user.');
      expect(summaries.single.outcome, 'rejected');
      await service.dispose();

      final restarted = VoiceCallService(
        localDeviceId: 'me',
        transport: _TestCallTransport(<VoiceCallSignal>[]),
        media: const _WorkingMedia(),
        now: () => now,
        terminalCallIds: summaries.map((summary) => summary.callId),
      );
      expect(await restarted.receiveInvite(invite), isFalse);
      await restarted.dispose();
    },
  );

  test(
    'media silence and repeated send errors enter reconnecting safely',
    () async {
      final signals = <VoiceCallSignal>[];
      final service = VoiceCallService(
        localDeviceId: 'me',
        transport: _TestCallTransport(signals),
        media: const _WorkingMedia(),
        now: () => DateTime.utc(2026, 1, 1),
        mediaInactivityTimeout: const Duration(milliseconds: 30),
      );
      await service.receiveInvite(
        VoiceCallSignal(
          callId: 'peer:media-watchdog',
          action: 'invite',
          senderDeviceId: 'peer',
          recipientDeviceId: 'me',
          issuedAt: DateTime.utc(2026, 1, 1),
        ),
      );
      await service.accept();
      expect(service.active?.state, VoiceCallState.connected);

      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(service.active?.state, VoiceCallState.reconnecting);
      service.noteMediaReceived('peer:media-watchdog');
      expect(service.active?.state, VoiceCallState.connected);

      service.noteMediaSendFailed('peer:media-watchdog');
      service.noteMediaSendFailed('peer:media-watchdog');
      service.noteMediaSendFailed('peer:media-watchdog');
      await Future<void>.delayed(Duration.zero);
      expect(service.active?.state, VoiceCallState.reconnecting);
      service.noteMediaReceived('peer:media-watchdog');
      expect(service.active?.state, VoiceCallState.connected);
      await service.end();
      await service.dispose();
    },
  );

  test('unavailable call media does not send an unusable invitation', () async {
    final signals = <VoiceCallSignal>[];
    final service = VoiceCallService(
      localDeviceId: 'me',
      transport: _TestCallTransport(signals),
      media: const UnavailableVoiceCallMediaEngine(),
      now: () => DateTime.utc(2026, 1, 1),
    );
    await expectLater(service.startOutgoing('peer'), throwsStateError);
    expect(signals, isEmpty);
    await service.dispose();
  });

  test(
    'incoming call setup expires if microphone permission never resolves',
    () async {
      final signals = <VoiceCallSignal>[];
      final service = VoiceCallService(
        localDeviceId: 'me',
        transport: _TestCallTransport(signals),
        media: const _HangingPrepareMedia(),
        now: () => DateTime.utc(2026, 1, 1),
        connectionTimeout: const Duration(milliseconds: 10),
      );
      await service.receiveInvite(
        VoiceCallSignal(
          callId: 'peer:incoming',
          action: 'invite',
          senderDeviceId: 'peer',
          recipientDeviceId: 'me',
          issuedAt: DateTime.utc(2026, 1, 1),
        ),
      );

      await service.accept().timeout(const Duration(seconds: 1));

      expect(service.active?.state, VoiceCallState.ended);
      expect(service.active?.failureReason, contains('timed out'));
      expect(signals.map((signal) => signal.action), ['hangup']);
      await service.dispose();
    },
  );

  test(
    'expired and future call invitations cannot start a ring timer',
    () async {
      final signals = <VoiceCallSignal>[];
      final now = DateTime.utc(2026, 1, 1);
      final service = VoiceCallService(
        localDeviceId: 'me',
        transport: _TestCallTransport(signals),
        media: const _WorkingMedia(),
        now: () => now,
      );
      final accepted = await service.receiveInvite(
        VoiceCallSignal(
          callId: 'peer:old-call',
          action: 'invite',
          senderDeviceId: 'peer',
          recipientDeviceId: 'me',
          issuedAt: now.subtract(const Duration(seconds: 46)),
        ),
      );

      expect(accepted, isFalse);
      expect(service.active, isNull);
      expect(signals, isEmpty);

      final futureAccepted = await service.receiveInvite(
        VoiceCallSignal(
          callId: 'peer:future-call',
          action: 'invite',
          senderDeviceId: 'peer',
          recipientDeviceId: 'me',
          issuedAt: now.add(const Duration(seconds: 6)),
        ),
      );
      expect(futureAccepted, isFalse);
      expect(service.active, isNull);
      expect(signals, isEmpty);
      await service.dispose();
    },
  );

  test(
    'background call preference persists and defaults off for old vaults',
    () {
      final identity = IdentityRecord(
        accountId: 'account',
        deviceId: 'device',
        displayName: 'me',
        bio: '',
        pairingNonce: 'nonce',
        pairingEpochMs: 1,
        publicKeyBase64: 'public',
        privateKeyBase64: 'private',
        configuredRelays: const [],
        localRelayPort: 7667,
        relayModeEnabled: false,
        autoUseContactRelays: true,
        notificationsEnabled: true,
        androidBackgroundRuntimeEnabled: false,
        androidBackgroundCallsEnabled: true,
        experimentalVoiceCallsEnabled: true,
        suppressReadReceipts: false,
        lanAddresses: const [],
        safetyNumber: 'safety',
        createdAt: DateTime.utc(2026),
      );
      expect(
        IdentityRecord.fromJson(
          identity.toJson(),
        ).androidBackgroundCallsEnabled,
        isTrue,
      );
      expect(
        IdentityRecord.fromJson(identity.toJson()).experimentalVoiceCallsEnabled,
        isTrue,
      );
      final legacy = Map<String, dynamic>.from(identity.toJson())
        ..remove('androidBackgroundCallsEnabled')
        ..remove('experimentalVoiceCallsEnabled');
      expect(
        IdentityRecord.fromJson(legacy).androidBackgroundCallsEnabled,
        isFalse,
      );
      expect(
        IdentityRecord.fromJson(legacy).experimentalVoiceCallsEnabled,
        isFalse,
      );
      expect(
        identity
            .copyWith(androidBackgroundCallsEnabled: false)
            .androidBackgroundCallsEnabled,
        isFalse,
      );
    },
  );
}

class _TestCallTransport implements VoiceCallSignalTransport {
  _TestCallTransport(this.signals);
  final List<VoiceCallSignal> signals;
  @override
  Future<void> send(VoiceCallSignal signal) async => signals.add(signal);
}

class _WorkingMedia implements VoiceCallMediaEngine {
  const _WorkingMedia();
  @override
  bool get available => true;
  @override
  Future<void> prepare() async {}
  @override
  Future<void> open({
    required String peerDeviceId,
    required bool outgoing,
  }) async {}
  @override
  Future<void> setMuted(bool muted) async {}

  @override
  Future<bool> setSpeakerphoneEnabled(bool enabled) async => true;
  @override
  Future<List<String>> availableOutputDevices() async => const ['default'];
  @override
  Future<void> selectOutputDevice(String name) async {}
  @override
  Future<void> close() async {}
}

class _HangingPrepareMedia implements VoiceCallMediaEngine {
  const _HangingPrepareMedia();

  @override
  bool get available => true;

  @override
  Future<void> prepare() => Completer<void>().future;

  @override
  Future<void> open({
    required String peerDeviceId,
    required bool outgoing,
  }) async {}

  @override
  Future<void> setMuted(bool muted) async {}

  @override
  Future<bool> setSpeakerphoneEnabled(bool enabled) async => true;
  @override
  Future<List<String>> availableOutputDevices() async => const [];
  @override
  Future<void> selectOutputDevice(String name) async {}

  @override
  Future<void> close() async {}
}

class _GatedPrepareMedia extends _WorkingMedia {
  final entered = Completer<void>();
  final gate = Completer<void>();

  @override
  Future<void> prepare() async {
    entered.complete();
    await gate.future;
  }
}

class _GatedMuteMedia extends _WorkingMedia {
  final entered = Completer<void>();
  final gate = Completer<void>();

  @override
  Future<void> setMuted(bool muted) async {
    entered.complete();
    await gate.future;
  }
}
