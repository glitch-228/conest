import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:conest/src/models.dart';
import 'package:conest/src/voice_call_service.dart';
import 'package:conest/src/voice_message_service.dart';

void main() {
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
    );
    final restored = VaultSnapshot.fromJson(snapshot.toJson());
    expect(restored.chatFolders.single.name, 'Pinned work');
    expect(restored.scheduledMessages.single.body, 'hello');
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
      await service.onAccepted();
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
      await service.onAccepted();

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
  Future<void> close() async {}
}
