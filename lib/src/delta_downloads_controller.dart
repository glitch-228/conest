part of 'messenger_controller.dart';

extension DeltaDownloadsController on MessengerController {
  bool _deferDeltaMail(int size) {
    if (!deltaChatEnabled || size <= 64 * 1024) return false;
    if (_networkCostClass != NetworkCostClass.unmetered) return true;
    // Encrypted MIME hides both kind and decoded size. Use the document
    // budget and the larger wire size until the signed content is available.
    return !(_snapshot.identity?.connectivity.autoDownloadPreset ??
            AutoDownloadPreset.medium)
        .allows(
          mimeType: 'application/octet-stream',
          sizeBytes: size,
          network: _networkCostClass,
          verifiedContact: true,
        );
  }

  void _setDeltaMailCursor(EmailCarrierConfig cursor) {
    final current = emailCarrierConfig;
    if (current == null || current.mail != cursor.mail)
      throw const OtherMailRetryException();
    _snapshot = _snapshot.copyWith(
      carrierAccounts: {
        ..._snapshot.carrierAccounts,
        TransportKind.deltaChat.name: current
            .copyWith(
              uidValidity: cursor.uidValidity,
              lastUid: cursor.lastUid,
              deferred: cursor.deferred,
            )
            .toJson(),
      },
    );
  }

  Future<List<bool>> _onDeltaMailBatch(
    List<FetchedDeltaMail> mails,
    EmailCarrierConfig cursor,
  ) async {
    if (!deltaChatEnabled) {
      _setDeltaMailCursor(cursor);
      await _saveSnapshotSilently(notify: false);
      return List.filled(mails.length, false);
    }
    final consumed = <bool>[];
    final step = await _deltaRun(
      (protocol, chats) async {
        var next = chats;
        final outgoing = <DeltaOutgoingMail>[];
        for (final mail in mails) {
          final step = await protocol.receive(next, mail.raw);
          if (step.retry) throw const OtherMailRetryException();
          next = step.chats;
          consumed.add(step.consumed);
          outgoing.addAll(step.mails);
        }
        return DeltaStep(
          next,
          mails: outgoing,
          consumed: consumed.any((value) => value),
        );
      },
      retryMailOnSaveFailure: true,
      mailCursor: cursor,
    );
    if (step == null) throw const OtherMailRetryException();
    return consumed;
  }

  DeltaChats _withDeferredDeltaMails(
    DeltaChats chats,
    EmailCarrierConfig cursor,
  ) {
    final next = {...chats.chats}
      ..removeWhere((key, _) => key.startsWith('deferred:'));
    final pending = <String>{
      for (final chat in next.values)
        for (final message in chat.messages)
          if (message.pending != null && !message.deleted)
            '${chats.peers[message.author]?.addr}/<${message.id}>',
    };
    for (final mail in cursor.deferred) {
      if (pending.contains('${mail.from}/${mail.messageId}')) continue;
      final key = 'deferred:${cursor.uidValidity}/${mail.uid}';
      next[key] = DeltaChat(
        key: key,
        members: const [],
        name: mail.from.isEmpty ? 'Delta Chat' : mail.from,
        left: true,
        messages: [
          DeltaChatMessage(
            id: key,
            author: '',
            text: '',
            at: _now().toUtc(),
            deferredUid: mail.uid,
          ),
        ],
      );
    }
    return chats.copyWith(chats: next);
  }

  DeferredDeltaMail? deferredDeltaMailFor(DeltaChatMessage message) {
    final config = emailCarrierConfig;
    if (config == null || message.deleted) return null;
    for (final mail in config.deferred) {
      if (message.deferredUid == mail.uid ||
          (message.pending != null &&
              mail.messageId == '<${message.id}>' &&
              deltaChats.peers[message.author]?.addr == mail.from)) {
        return mail;
      }
    }
    return null;
  }

  Future<void> downloadDeltaMail(DeltaChatMessage message) async {
    final mail = deferredDeltaMailFor(message);
    final config = emailCarrierConfig;
    final channel = _emailChannel;
    if (mail == null || config?.uidValidity == null || channel == null) {
      throw StateError('This mail is no longer available.');
    }
    await channel.downloadDeferred(config!.uidValidity!, mail.uid);
  }
}
