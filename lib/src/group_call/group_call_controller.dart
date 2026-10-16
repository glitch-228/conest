part of '../messenger_controller.dart';

extension GroupCallController on MessengerController {
  /// A device that [accountId]'s list, as some contact of that account sent
  /// it, revoked.
  bool _isRevokedAccountDevice(String deviceId, String accountId) =>
      _snapshot.contacts.any(
        (contact) =>
            !contact.isHiddenDevice &&
            contact.accountId == accountId &&
            contact.accountRevokedDeviceIds.contains(deviceId),
      );

  bool _isRevokedGroupMember(GroupRecord group, String deviceId) {
    bool revoked(String? accountId) =>
        accountId != null &&
        (_isRevokedAccountDevice(deviceId, accountId) ||
            (identity?.accountId == accountId &&
                accountDevices?.revoked.containsKey(deviceId) == true));
    // A signed revocation names an account's devices; it cannot revoke an
    // unrelated member merely by putting that member's public ID in a list.
    return revoked(_contactByDeviceId(deviceId)?.accountId) ||
        revoked(group.memberProfileFor(deviceId)?.accountId);
  }

  GroupCallService? get groupCallService => _groupCallService;
  bool get groupVoiceCallsAvailable =>
      conestActive &&
      identity?.experimentalVoiceCallsEnabled == true &&
      (_groupCallMediaOverride?.available ??
          _platformBridge.supportsVoiceCallMedia) &&
      _transportRegistry?.adapterFor(TransportKind.iroh)
          is IrohCallMediaAdapter &&
      _ratchet != null;

  List<GroupCallSummary> groupCallSummariesFor(String groupId) =>
      _snapshot.groupCallSummaries.where((s) => s.groupId == groupId).toList();

  List<GroupCallMember> groupCallMembersFor(String groupId) {
    final group = _groupById(groupId);
    final me = identity;
    if (group == null ||
        me == null ||
        group.localRemovedAt != null ||
        !group.hasActiveMember(me.deviceId)) {
      return const [];
    }
    return group.activeMemberDeviceIds
        .take(groupCallMaxParticipants)
        .map((id) {
          if (id == me.deviceId) {
            return GroupCallMember(
              deviceId: id,
              name: me.displayName,
              canJoin:
                  me.experimentalVoiceCallsEnabled &&
                  (_groupCallMediaOverride?.available ??
                      _platformBridge.supportsVoiceCallMedia),
              directRoute:
                  _transportRegistry?.adapterFor(TransportKind.iroh)
                      is IrohCallMediaAdapter,
            );
          }
          final peer = _groupMemberContact(group, id);
          return GroupCallMember(
            deviceId: id,
            name: peer?.alias ?? 'Group member',
            canJoin:
                peer?.canSendOutbound == true &&
                peer?.featureCapabilityVersion != 0 &&
                peer!.featureCapabilities.contains(
                  ApplicationCapability.groupVoiceCallsV1,
                ),
            directRoute:
                peer?.hasPinnedIrohIdentity == true &&
                _canUseIrohForContact(peer!),
          );
        })
        .toList(growable: false);
  }

  void _ensureGroupCallService() {
    final me = identity;
    if (me == null || !conestActive) {
      _disposeGroupCalls();
      return;
    }
    if (_groupCallService?.localDeviceId == me.deviceId) {
      return;
    }
    _disposeGroupCalls();
    _groupCallService = GroupCallService(
      localDeviceId: me.deviceId,
      transport: _ControllerGroupCallTransport(this),
      media:
          _groupCallMediaOverride ??
          PlatformGroupCallMediaEngine(_platformBridge),
      members: groupCallMembersFor,
      policy:
          _groupCallLinkPolicy ??
          DefaultGroupCallLinkPolicy(desktop: !kIsWeb && !Platform.isAndroid),
      now: _now,
      noiseSuppressionEnabled: me.voiceNoiseSuppressionEnabled,
      canOpenMedia: () =>
          _groupCallTeardown == null &&
          _voiceCallService?.mediaBusy != true &&
          _retiredVoiceMedia?.mediaBusy != true,
      terminalCalls: _snapshot.groupCallSummaries
          .where((s) => s.callEnded)
          .map((s) => (s.groupId, s.callId)),
      sign: (bytes) async => Uint8List.fromList(
        base64Decode(await _crypto.signInstallationBytes(bytes)),
      ),
      verify: (sender, bytes, signature) async {
        final room = _groupCallService?.active;
        if (room == null) {
          return false;
        }
        final group = _groupById(room.groupId);
        final peer = group == null ? null : _groupMemberContact(group, sender);
        final key = peer?.signingPublicKeyBase64;
        if (peer == null ||
            !peer.canSendOutbound ||
            key == null ||
            !group!.hasActiveMember(sender)) {
          return false;
        }
        return _crypto.verifyInstallationBytes(
          bytes: bytes,
          signatureBase64: base64Encode(signature),
          publicKeyBase64: key,
        );
      },
      verifyStart: (groupId, sender, bytes, signature) async {
        final group = _groupById(groupId);
        final key = group?.memberProfileFor(sender)?.signingPublicKeyBase64;
        if (key == null) return false;
        return _crypto.verifyInstallationBytes(
          bytes: bytes,
          signatureBase64: base64Encode(signature),
          publicKeyBase64: key,
        );
      },
      onIncoming: (room) async {
        final group = _groupById(room.groupId);
        if (group == null || identity?.notificationsEnabled != true) {
          return;
        }
        final sender = _groupMemberContact(group, room.startedBy);
        if (sender == null) {
          return;
        }
        _setTransientStatus('${sender.alias} started a call in ${group.title}');
        if (!_groupConversation(group.groupId).muted) {
          await _platformBridge.showMessageNotification(
            title: group.title,
            body: '${sender.alias} started a call in ${group.title}',
            conversationId: group.groupId,
            senderName: sender.alias,
            selfName: me.displayName,
          );
        }
      },
      onSummary: (summary) async {
        if (_disposed || identity?.deviceId != me.deviceId) {
          return;
        }
        final entries = [
          ..._snapshot.groupCallSummaries.where(
            (s) => s.groupId != summary.groupId || s.callId != summary.callId,
          ),
          summary,
        ];
        _snapshot = _snapshot.copyWith(
          groupCallSummaries: entries.length <= 128
              ? entries
              : entries.sublist(entries.length - 128),
        );
        await _saveSnapshotSilently(notify: true);
      },
    );
    _groupCallChanges = _groupCallService!.changes.listen((_) {
      if (_disposed) {
        return;
      }
      final room = _groupCallService?.active;
      if (room == null && _voiceCallService?.mediaBusy == true) {
        notifyListeners();
        return;
      }
      if (room != null) {
        unawaited(voiceMessageService.stopPlayback());
        unawaited(voiceMessageService.stopForInterruption());
      }
      _updateCallForeground(
        title: room == null ? null : _groupById(room.groupId)?.title,
        state: room == null
            ? 'idle'
            : room.connected
            ? 'connected'
            : 'connecting',
        incoming: false,
      );
      notifyListeners();
    });
  }

  Future<GroupCallRoom> joinOrStartGroupCall(String groupId) async {
    if (!groupVoiceCallsAvailable) {
      throw StateError('Group calls need Iroh and an updated Conest build.');
    }
    _ensureGroupCallService();
    final service = _groupCallService!;
    if (service.roomFor(groupId) == null) {
      return service.start(groupId);
    }
    return service.join(groupId);
  }

  // Group-only call members need pairwise sessions when the key coordinator
  // changes. This permits only the existing ratchet bootstrap/key controls;
  // it never grants the member access to the private-message path.
  ContactRecord? _groupOnlyRatchetPeer(RelayEnvelope envelope) {
    final me = identity;
    final allowedKind =
        (envelope.kind == _ratchetBundleKind &&
            envelope.protocolVersion == 2) ||
        ((envelope.kind == 'ratchet_hello' ||
                envelope.kind == 'ratchet_bulk_key') &&
            envelope.protocolVersion == 3);
    if (_disposed ||
        !conestActive ||
        me == null ||
        _ratchet == null ||
        !allowedKind ||
        !_isValidInboundEnvelope(envelope) ||
        envelope.conversationId !=
            _crypto.conversationIdFor(envelope.senderDeviceId)) {
      return null;
    }
    final peer = _ratchetPeer(envelope.senderDeviceId);
    if (peer == null ||
        !peer.canSendOutbound ||
        peer.accountId != envelope.senderAccountId ||
        !_snapshot.groups.any(
          (group) =>
              group.localRemovedAt == null &&
              group.hasActiveMember(me.deviceId) &&
              group.hasActiveMember(peer.deviceId) &&
              group.memberProfileFor(peer.deviceId)?.publicKeyBase64 ==
                  peer.publicKeyBase64,
        )) {
      return null;
    }
    return peer;
  }

  Future<bool> _handleGroupOnlyRatchetInbound(
    TransportInboundEnvelope inbound,
    RelayEnvelope envelope,
  ) async {
    if (inbound.bytes.length > _maxBootstrapPayloadBytes * 2) return false;
    final peer = _groupOnlyRatchetPeer(envelope);
    if (peer == null) return false;
    final iroh = inbound.transport == TransportKind.iroh;
    if (iroh) {
      if (!peer.hasPinnedIrohIdentity ||
          peer.irohEndpointId != inbound.senderTransportIdentity ||
          !_canUseIrohForContact(peer) ||
          (inbound.path == TransportPathKind.relayed &&
              !_irohRelayEnabledFor(peer))) {
        return false;
      }
    } else if (!inbound.transport.isCarrier ||
        inbound.senderTransportIdentity != peer.deviceId ||
        !_carrierAllowed(inbound.transport) ||
        peer.routing.effectivePolicy(
              inbound.transport,
              identity!.connectivity,
            ) ==
            TransportPolicy.disabled) {
      return false;
    }
    if (_groupOnlyRatchetJobs >= 16 ||
        !_groupOnlyRatchetRate.accept(_now(), 32)) {
      return false;
    }
    _groupOnlyRatchetJobs++;
    try {
      // The regular dispatch checks seen/in-flight ids before decrypting.
      // Copies must not advance the ratchet twice or trigger a reset.
      await _processEnvelopes(
        [envelope],
        ingressKind: !iroh || inbound.path == TransportPathKind.relayed
            ? PeerRouteKind.relay
            : PeerRouteKind.directInternet,
        route: iroh
            ? MessengerController._irohRoute(inbound.path)
            : MessageRoute.forCarrier(inbound.transport),
      );
      await _saveSnapshotSilently(debounce: true);
      return true;
    } catch (_) {
      return false;
    } finally {
      _groupOnlyRatchetJobs--;
    }
  }

  String _envelopeProcessingError(String kind, Object error) =>
      const {
        _ratchetBundleKind,
        'ratchet_hello',
        'ratchet_bulk_key',
      }.contains(kind)
      ? 'Invalid forward-secret control.'
      : _boundedLogValue(error.toString(), 180);

  Future<void> _handleGroupCallSignal(RelayEnvelope envelope) async {
    final me = identity;
    final group = _groupById(envelope.conversationId);
    if (_disposed ||
        me == null ||
        !conestActive ||
        !me.experimentalVoiceCallsEnabled ||
        group == null ||
        !group.hasActiveMember(me.deviceId) ||
        !group.hasActiveMember(envelope.senderDeviceId) ||
        group.localRemovedAt != null ||
        envelope.recipientDeviceId != me.deviceId) {
      return;
    }
    final sender = _groupMemberContact(group, envelope.senderDeviceId);
    if (sender == null ||
        !sender.canSendOutbound ||
        sender.accountId != envelope.senderAccountId ||
        !sender.featureCapabilities.contains(
          ApplicationCapability.groupVoiceCallsV1,
        )) {
      return;
    }
    try {
      final signal = GroupCallSignal.decode(
        await _crypto.decryptMessage(contact: sender, envelope: envelope),
      );
      if (signal.groupId != group.groupId ||
          signal.senderDeviceId != sender.deviceId ||
          (signal.action == 'key' && envelope.protocolVersion != 3)) {
        return;
      }
      _ensureGroupCallService();
      await _groupCallService?.receiveSignal(
        signal,
        authenticatedSender: sender.deviceId,
      );
    } catch (_) {
      /* Do not log plaintext or key-bearing parse exceptions. */
    }
  }

  Future<void> _handleGroupCallDatagram(IrohMediaDatagram datagram) async {
    final room = _groupCallService?.active;
    final group = room == null ? null : _groupById(room.groupId);
    if (_disposed ||
        room == null ||
        group == null ||
        identity == null ||
        !identity!.experimentalVoiceCallsEnabled ||
        !conestActive ||
        !group.hasActiveMember(identity!.deviceId)) {
      return;
    }
    for (final id in group.activeMemberDeviceIds.take(
      groupCallMaxParticipants,
    )) {
      final peer = _groupMemberContact(group, id);
      if (peer == null ||
          !peer.canSendOutbound ||
          !peer.hasPinnedIrohIdentity ||
          peer.irohEndpointId != datagram.senderEndpointId ||
          !_canUseIrohForContact(peer) ||
          (datagram.path == TransportPathKind.relayed &&
              !_irohRelayEnabledFor(peer))) {
        continue;
      }
      await _groupCallService?.receiveDatagram(
        group.groupId,
        id,
        datagram.bytes,
      );
      return;
    }
  }

  void _disposeGroupCalls() {
    unawaited(_groupCallChanges?.cancel());
    _groupCallChanges = null;
    final service = _groupCallService;
    _groupCallService = null;
    if (service != null) {
      final previous = _groupCallTeardown;
      final disposal = service.dispose().catchError((Object _) {});
      final cleanup = previous == null
          ? disposal
          : Future.wait<void>([previous, disposal]).then<void>((_) {});
      _groupCallTeardown = cleanup;
      unawaited(
        cleanup
            .whenComplete(() {
              if (identical(_groupCallTeardown, cleanup)) {
                _groupCallTeardown = null;
              }
            })
            .catchError((Object _) {}),
      );
    }
  }
}

class _ControllerGroupCallTransport implements GroupCallTransport {
  _ControllerGroupCallTransport(this.controller);
  final MessengerController controller;
  @override
  Future<void> sendSignal(
    GroupCallSignal signal,
    String recipientDeviceId,
  ) async {
    final group = controller._requireGroup(signal.groupId);
    final me = controller._requireIdentity();
    final peer = controller._groupMemberContact(group, recipientDeviceId);
    if (controller._disposed ||
        !group.hasActiveMember(me.deviceId) ||
        !group.hasActiveMember(recipientDeviceId) ||
        signal.senderDeviceId != me.deviceId ||
        peer == null ||
        !peer.canSendOutbound ||
        !peer.featureCapabilities.contains(
          ApplicationCapability.groupVoiceCallsV1,
        )) {
      throw StateError('Call participant is not authorized.');
    }
    // Call keys require an established forward-secret pairwise session.
    // A missing session never downgrades a call key to the static peer key.
    if (signal.action == 'key' &&
        await controller._ratchet?.hasSession(ratchetPeerId(peer)) != true) {
      await controller._syncRatchetWithCapabilities(peer);
      throw StateError('Call key session is still connecting.');
    }
    final envelope = await controller._crypto.encryptPayloadEnvelope(
      kind: 'group_call_signal',
      messageId: controller._randomId('gcallctl'),
      conversationId: group.groupId,
      senderAccountId: me.accountId,
      senderDeviceId: me.deviceId,
      recipientDeviceId: recipientDeviceId,
      contact: peer,
      plaintext: signal.encode(),
      createdAt: controller._now(),
    );
    if (signal.action == 'key' && envelope.protocolVersion != 3) {
      throw StateError('Call key requires a forward-secret session.');
    }
    // Upkeep repeats every few seconds. To members outside the call it goes
    // only over live routes, never through relays, mail or radio; those in
    // it may need any route (their audio can flow where envelopes don't).
    final inCall =
        controller._groupCallService
            ?.roomFor(signal.groupId)
            ?.participants
            .any((p) => p.deviceId == recipientDeviceId) ??
        false;
    final upkeep =
        !inCall &&
        const {'join', 'stats', 'topology', 'start'}.contains(signal.action);
    await controller._deliverToContact(
      contact: peer,
      recipientDeviceId: peer.deviceId,
      envelope: envelope,
      allowForwarding: false,
      skipLegacyKinds: upkeep
          ? const {PeerRouteKind.relay}
          : const <PeerRouteKind>{},
      allowedUnifiedKinds: upkeep ? const {TransportKind.iroh} : null,
    );
  }

  @override
  Future<void> sendDatagram(
    String groupId,
    String recipientDeviceId,
    Uint8List bytes,
  ) async {
    final group = controller._requireGroup(groupId);
    final me = controller._requireIdentity();
    final peer = controller._groupMemberContact(group, recipientDeviceId);
    final adapter = controller._transportRegistry?.adapterFor(
      TransportKind.iroh,
    );
    if (controller._disposed ||
        bytes.length > GroupCallCipher.maxFrameBytes ||
        !group.hasActiveMember(me.deviceId) ||
        !group.hasActiveMember(recipientDeviceId) ||
        peer == null ||
        !peer.canSendOutbound ||
        !peer.hasPinnedIrohIdentity ||
        !controller._canUseIrohForContact(peer) ||
        adapter is! IrohCallMediaAdapter) {
      throw StateError('No direct call route.');
    }
    await adapter.sendCallDatagram(
      peer: controller._transportPeerForContact(
        peer,
        allowRelay: controller._irohRelayEnabledFor(peer),
      ),
      bytes: bytes,
    );
  }
}
