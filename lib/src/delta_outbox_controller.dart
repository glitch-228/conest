part of 'messenger_controller.dart';

extension DeltaOutboxController on MessengerController {
  List<DeltaControlMail> get _deltaControlOutbox =>
      DeltaControlMail.restore(_deltaConfig?['outbox']);

  List<DeltaControlMail> _stageDeltaControls(List<DeltaOutgoingMail> mails) {
    try {
      return DeltaControlMail.append(_deltaControlOutbox, [
        for (final mail in mails)
          if (mail.chatKey == null || mail.messageId == null)
            DeltaControlMail(_randomId('dmail'), mail.to, mail.mail),
      ]);
    } on StateError {
      _deltaWaitingForOutbox = true;
      rethrow;
    }
  }

  void _retryDeltaControls([Duration after = Duration.zero]) {
    _deltaControlRetry?.cancel();
    _deltaControlRetry = null;
    if (_disposed ||
        !deltaChatEnabled ||
        !conestActive ||
        _emailChannel == null ||
        _emailChannel!.state == EmailCarrierState.stopped ||
        _deltaControlOutbox.isEmpty) {
      return;
    }
    _deltaControlRetry = Timer(after, () {
      _deltaControlRetry = null;
      unawaited(_drainDeltaControls());
    });
  }

  Future<void> _drainDeltaControls() async {
    if (_deltaControlSending) return;
    _deltaControlSending = true;
    final account = _deltaConfig?['addr'];
    try {
      for (var i = 0; i < DeltaControlMail.maxCount; i++) {
        if (_disposed ||
            !conestActive ||
            !deltaChatEnabled ||
            account != _deltaConfig?['addr']) {
          return;
        }
        final channel = _emailChannel;
        // Select only after preceding vault writes have settled. A batch
        // exposes its new in-memory snapshot while its save is still pending.
        final ready = _deltaQueue.then(
          (_) => account == _deltaConfig?['addr']
              ? _deltaControlOutbox.firstOrNull
              : null,
        );
        _deltaQueue = ready.then((_) {}, onError: (Object _) {});
        final mail = await ready;
        if (channel == null || mail == null) return;
        DeltaControlMail? remaining;
        try {
          await channel.sendMail(
            mail.to,
            mail.mail,
            stillWanted: () =>
                !_disposed &&
                conestActive &&
                deltaChatEnabled &&
                account == _deltaConfig?['addr'] &&
                identical(channel, _emailChannel),
          );
        } on SmtpException catch (error) {
          if (!error.permanentRecipientFailure) rethrow;
          final recipients = mail.to
              .where((to) => to != error.recipient)
              .toList();
          if (recipients.isNotEmpty) {
            remaining = DeltaControlMail(mail.id, recipients, mail.mail);
          }
          recordError('delta', 'Email refused a Delta Chat recipient.');
        }
        // Merge the removal with the current state, after any newer batch.
        final saved = _deltaQueue.then((_) async {
          if (_disposed || account != _deltaConfig?['addr']) return;
          await _saveDeltaChats(
            deltaChats,
            outbox: [
              for (final queued in _deltaControlOutbox)
                if (queued.id != mail.id) queued else ?remaining,
            ],
          );
        });
        _deltaQueue = saved.then((_) {}, onError: (Object _) {});
        await saved;
        if (_deltaWaitingForOutbox) {
          _deltaWaitingForOutbox = false;
          _emailChannel?.retryPendingMail();
        }
      }
    } catch (error) {
      // One event-driven wake, honoring the account's quota/server rest.
      final wait = error is LimiterRefused ? error.retryIn : null;
      _retryDeltaControls(
        wait == null || wait < const Duration(seconds: 1)
            ? const Duration(seconds: 30)
            : wait > const Duration(hours: 24)
            ? const Duration(hours: 24)
            : wait,
      );
    } finally {
      _deltaControlSending = false;
      if (_deltaControlRetry == null) _retryDeltaControls();
    }
  }
}
