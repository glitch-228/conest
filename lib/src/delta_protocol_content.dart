part of 'delta_protocol.dart';

extension DeltaProtocolContent on DeltaProtocol {
  DeltaStep? _receiveControl(
    DeltaChats chats,
    DeltaIncoming read,
    PgpPublicKey signer,
    String chatKey,
  ) {
    final edit = read.header('chat-edit');
    final deletion = read.header('chat-delete');
    if (!read.reaction && edit == null && deletion == null) return null;
    final chat = chats.chats[chatKey];
    final author = signer.fingerprintHex;
    if (chat == null || chat.left || !chat.members.contains(author)) {
      return DeltaStep(chats, consumed: true);
    }
    var next = chats;
    final date = _clamp(read.date);
    if (read.reaction) {
      final target = deltaMessageId(read.header('in-reply-to'));
      if (target != null)
        next = next.updateMessage(chatKey, target, (m) {
          final prior = m.reactionDates[author];
          if (m.info || m.deleted || (prior != null && date.isBefore(prior)))
            return m;
          if (!m.reactions.containsKey(author) &&
              m.reactions.length >= DeltaLimits.members)
            return m;
          return m.copyWith(
            reactions: {...m.reactions, author: read.reactionText},
            reactionDates: {...m.reactionDates, author: date},
          );
        });
    } else if (edit != null) {
      final target = deltaMessageId(edit);
      if (target != null)
        next = next.updateMessage(chatKey, target, (m) {
          if (m.info ||
              m.deleted ||
              m.author != author ||
              (m.editedAt != null && date.isBefore(m.editedAt!)))
            return m;
          var text = read.text;
          if (text.startsWith('>')) {
            final lines = text.split('\n');
            while (lines.isNotEmpty && lines.first.startsWith('>')) {
              lines.removeAt(0);
            }
            while (lines.isNotEmpty && lines.first.trim().isEmpty) {
              lines.removeAt(0);
            }
            text = lines.join('\n');
          }
          if (text.startsWith('✏️')) text = text.substring('✏️'.length);
          return m.copyWith(text: _boundedText(text), editedAt: date);
        });
    } else {
      for (final raw in deletion!.split(RegExp(r'\s+')).take(100)) {
        final target = deltaMessageId(raw);
        if (target != null)
          next = next.updateMessage(
            chatKey,
            target,
            (m) => m.author != author || m.info
                ? m
                : m.copyWith(
                    deleted: true,
                    text: '',
                    attachments: const [],
                    clearPending: true,
                    reactions: const {},
                    reactionDates: const {},
                    wantsReceipt: false,
                  ),
          );
      }
    }
    return DeltaStep(next, consumed: true, chatKey: chatKey);
  }

  String _boundedText(String text) => text.length > DeltaProtocol.maxTextChars
      ? '${String.fromCharCodes(text.runes.take(DeltaProtocol.maxTextChars))}…'
      : text;

  Future<DeltaStep> _receiveContent(
    DeltaChats chats,
    DeltaIncoming read,
    PgpPublicKey signer,
    String chatKey,
    DeltaChat Function() create,
  ) async {
    final chat = chats.chats[chatKey] ?? create();
    final postId = read.postMessageId;
    final id = postId ?? read.messageId;
    final existing = chat.messages
        .where((m) => m.id == id || m.preMessageId == id)
        .firstOrNull;
    if (existing != null &&
        (existing.author != signer.fingerprintHex || existing.deleted)) {
      return DeltaStep(chats, consumed: true);
    }
    if (postId != null && existing != null) {
      // A post can arrive first. Only its signed author can fill the caption.
      return DeltaStep(
        chats.updateMessage(
          chatKey,
          id,
          (m) => m.copyWith(
            text: m.text.isEmpty ? _boundedText(read.text) : null,
            preMessageId: read.messageId,
          ),
        ),
        consumed: true,
        chatKey: chatKey,
      );
    }
    if (existing != null && existing.pending == null) {
      return DeltaStep(chats, consumed: true);
    }
    if (chats.deleted[chatKey] case final deletedAt?) {
      if (!_clamp(read.date).isAfter(deletedAt))
        return DeltaStep(chats, consumed: true);
    }
    final files = <AttachmentDescriptor>[];
    var text = _boundedText(read.text);
    var index = 0;
    for (final file in read.files) {
      if (file.name.toLowerCase().endsWith('.xdc')) {
        text = '${text.isEmpty ? '' : '$text\n'}app (not supported)';
        continue;
      }
      if (saveFile == null) return DeltaStep(chats, chatKey: chatKey);
      try {
        files.add(await saveFile!(file, chatKey, id, index++));
      } catch (_) {
        return DeltaStep(chats, chatKey: chatKey);
      }
    }
    if (read.header('chat-content') == 'call') text = 'Call (not supported)';
    if (existing != null) {
      if (files.isEmpty) return DeltaStep(chats, consumed: true);
      return DeltaStep(
        chats.updateMessage(
          chatKey,
          id,
          (m) => m.copyWith(
            attachments: files,
            clearPending: true,
            text: m.text.isEmpty ? text : null,
          ),
        ),
        consumed: true,
        chatKey: chatKey,
      );
    }
    final pending = postId == null
        ? null
        : read.pending ??
              const DeltaPendingFile(name: 'File', size: 0, viewtype: 'File');
    final message = DeltaChatMessage(
      id: id,
      author: signer.fingerprintHex,
      text: text,
      at: _clamp(read.date),
      wantsReceipt: read.header('chat-disposition-notification-to') != null,
      attachments: files,
      pending: pending,
      pendingUntil: pending == null
          ? null
          : _now().toUtc().add(DeltaLimits.pendingLifetime),
      preMessageId: postId == null ? null : read.messageId,
    );
    return DeltaStep(
      chats.add(chatKey, message, create: create),
      consumed: true,
      chatKey: chatKey,
    );
  }

  DeltaChat _mergeMembers(
    DeltaChats chats,
    DeltaChat? existing,
    DeltaIncoming read,
    PgpPublicKey signer,
    DateTime stamp,
  ) {
    final groupId = read.header('chat-group-id')!;
    final base =
        existing ??
        DeltaChat(
          key: DeltaChat.groupKey(groupId),
          groupId: groupId,
          members: const [],
        );
    final additions = {...base.additionDates};
    final removals = {...base.memberRemoved};
    final addresses = {...base.pastAddresses};
    final epoch = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    final past = [
      for (final value in splitAddressList(
        read.header('chat-group-past-members') ?? '',
      ))
        ?parseMailAddress(value),
    ];
    if (read.to.length > DeltaLimits.members ||
        past.length > DeltaLimits.members)
      return base;
    final ids = (read.header('chat-group-member-fpr') ?? '').split(
      RegExp(r'\s+'),
    );
    final clocks = (read.header('chat-group-member-timestamps') ?? '')
        .trim()
        .split(RegExp(r'\s+'));
    final all = [...read.to, ...past];
    final hasClocks =
        clocks.length == all.length &&
        clocks.every((v) => int.tryParse(v) != null);
    String? who(String addr, int index) {
      if (addr == self) return fingerprint;
      if (addr == read.from) return signer.fingerprintHex;
      final named =
          index < ids.length &&
              RegExp(r'^[0-9a-fA-F]{40}$').hasMatch(ids[index])
          ? ids[index].toUpperCase()
          : null;
      final gossip = read.gossip[addr];
      if (gossip != null) {
        if (named != null && named != gossip.fingerprintHex) return null;
        return gossip.fingerprintHex;
      }
      final known = chats.peers.values.where((p) => p.addr == addr);
      if (known.length == 1) {
        if (named != null && named != known.single.fingerprint) return null;
        return known.single.fingerprint;
      }
      return named;
    }

    for (final (i, addr) in all.indexed) {
      final member = who(addr, i);
      if (member == null) continue;
      if (!additions.containsKey(member) &&
          !removals.containsKey(member) &&
          {...additions.keys, ...removals.keys}.length >=
              DeltaLimits.members * 2)
        continue;
      // Unknown timestamps are zero; omission never removes a member.
      final seconds = hasClocks
          ? int.parse(clocks[i]).clamp(0, _now().millisecondsSinceEpoch ~/ 1000)
          : 0;
      final date = DateTime.fromMillisecondsSinceEpoch(
        seconds * 1000,
        isUtc: true,
      );
      if (i < read.to.length) {
        final prior = additions[member];
        if ((prior == null || date.isAfter(prior)) &&
            !date.isBefore(removals[member] ?? epoch)) {
          additions[member] = date;
        }
      } else if (hasClocks) {
        if (date.isAfter(removals[member] ?? epoch) &&
            date.isAfter(additions[member] ?? epoch)) {
          removals[member] = date;
          addresses[member] = addr;
        }
      }
    }
    additions.putIfAbsent(
      signer.fingerprintHex,
      () => existing == null ? stamp : epoch,
    );
    if (existing == null) additions.putIfAbsent(fingerprint, () => epoch);
    // Legacy member changes are explicit; an older list must not erase additions.
    final removedAddr = parseMailAddress(
      read.header('chat-group-member-removed'),
    );
    final removedId = read
        .header('chat-group-member-removed-fpr')
        ?.trim()
        .toUpperCase();
    final removed = removedAddr == self
        ? fingerprint
        : removedId != null && RegExp(r'^[0-9A-F]{40}$').hasMatch(removedId)
        ? removedId
        : chats.peers.values
              .where((p) => p.addr == removedAddr)
              .firstOrNull
              ?.fingerprint;
    if (removed != null &&
        !hasClocks &&
        (base.membersAt == null || !stamp.isBefore(base.membersAt!))) {
      final addition = additions[removed] ?? epoch;
      final date = stamp.isAfter(addition)
          ? stamp
          : addition.add(const Duration(seconds: 1));
      if (date.isAfter(removals[removed] ?? epoch)) removals[removed] = date;
      if (removedAddr != null) addresses[removed] = removedAddr;
    }
    return base.copyWith(
      members: [
        for (final e in additions.entries)
          if (e.key != fingerprint &&
              !e.value.isBefore(removals[e.key] ?? epoch))
            e.key,
      ].take(DeltaLimits.members - 1).toList()..sort(),
      memberAdded: additions,
      memberRemoved: removals,
      pastAddresses: addresses,
    );
  }

  Future<DeltaStep> sendFiles(
    DeltaChats chats,
    String chatKey,
    String text,
    List<DeltaFile> files,
    List<AttachmentDescriptor> localFiles,
  ) async {
    final chat = chats.chats[chatKey];
    if (chat == null || chat.left)
      throw StateError('Not a chat you can write in.');
    if (files.isEmpty ||
        files.length != localFiles.length ||
        files.length > DeltaLimits.attachments ||
        files.fold<int>(0, (s, f) => s + f.bytes.length) >
            DeltaLimits.fileBytes) {
      throw ArgumentError('Delta Chat files must be at most 21 MiB.');
    }
    if (text.length > DeltaProtocol.maxTextChars)
      throw ArgumentError('Message is too long.');
    final recipients = await _recipients(chats, chat);
    if (recipients.isEmpty)
      throw StateError('Waiting for the invite to be answered.');
    final id = _newMessageId();
    final date = _now().toUtc();
    final headers = [
      if (chat.isGroup) ..._groupHeaders(chat, recipients),
      if (files.first.voice) ('Chat-Voice-Message', '1'),
      if (files.first.durationMs > 0)
        ('Chat-Duration', '${files.first.durationMs}'),
      if (files.first.sticker) ('Chat-Content', 'sticker'),
    ];
    final split =
        files.length == 1 && files.single.bytes.length > DeltaLimits.splitBytes;
    final mails = <DeltaOutgoingMail>[];
    if (split) {
      final f = files.single;
      mails.add(
        DeltaOutgoingMail(
          to: [for (final r in recipients) r.addr],
          chatKey: chatKey,
          messageId: id,
          mail: await DeltaMail.build(
            key: key,
            from: self,
            fromName: selfName,
            to: recipients,
            gossip: chat.isGroup ? recipients : const [],
            text: text,
            messageId: _newMessageId(),
            date: date,
            random: _random,
            requestReadReceipt: true,
            extraHeaders: [
              ...headers,
              ('Chat-Post-Message-ID', '<$id>'),
              (
                'Chat-Post-Message-Metadata',
                '{"size":${f.bytes.length},"viewtype":"${f.viewtype}","filename":${jsonEncode(f.name)}${f.durationMs > 0 ? ',"duration":${f.durationMs}' : ''}}',
              ),
            ],
          ),
        ),
      );
    }
    mails.add(
      DeltaOutgoingMail(
        to: [for (final r in recipients) r.addr],
        chatKey: chatKey,
        messageId: id,
        mail: await DeltaMail.build(
          key: key,
          from: self,
          fromName: selfName,
          to: recipients,
          gossip: chat.isGroup ? recipients : const [],
          text: split ? '' : text,
          messageId: id,
          date: date,
          random: _random,
          files: files,
          postMessage: split,
          extraHeaders: headers,
          requestReadReceipt: !split,
        ),
      ),
    );
    return DeltaStep(
      chats.add(
        chatKey,
        DeltaChatMessage(
          id: id,
          author: fingerprint,
          text: text,
          at: date,
          outgoing: true,
          attachments: localFiles,
        ),
        create: () => chat,
      ),
      mails: mails,
      chatKey: chatKey,
    );
  }

  Future<DeltaStep> react(
    DeltaChats chats,
    String chatKey,
    String id,
    String emoji,
  ) => _sendControl(chats, chatKey, id, deltaReaction(emoji), reaction: true);

  Future<DeltaStep> edit(
    DeltaChats chats,
    String chatKey,
    String id,
    String text,
  ) => _sendControl(chats, chatKey, id, text, edit: true);

  Future<DeltaStep> deleteMessage(
    DeltaChats chats,
    String chatKey,
    String id,
  ) => _sendControl(chats, chatKey, id, 'Message deleted.', deletion: true);

  Future<DeltaStep> _sendControl(
    DeltaChats chats,
    String chatKey,
    String id,
    String text, {
    bool reaction = false,
    bool edit = false,
    bool deletion = false,
  }) async {
    final chat = chats.chats[chatKey];
    final message = chat?.messages.where((m) => m.id == id).firstOrNull;
    if (chat == null ||
        chat.left ||
        message == null ||
        message.info ||
        message.deleted) {
      throw StateError('No such message.');
    }
    if (!reaction && (!message.outgoing || message.author != fingerprint)) {
      throw StateError('Only your own messages can be changed.');
    }
    if (text.length > DeltaProtocol.maxTextChars)
      throw ArgumentError('Message is too long.');
    final recipients = await _recipients(chats, chat);
    if (recipients.isEmpty) throw StateError('Nobody can be written to yet.');
    final date = _now().toUtc();
    final mail = await DeltaMail.build(
      key: key,
      from: self,
      fromName: selfName,
      to: recipients,
      gossip: chat.isGroup ? recipients : const [],
      text: edit ? '✏️$text' : text,
      messageId: _newMessageId(),
      date: date,
      random: _random,
      reaction: reaction,
      inReplyTo: reaction ? id : null,
      extraHeaders: [
        if (chat.isGroup) ..._groupHeaders(chat, recipients),
        if (edit) ('Chat-Edit', '<$id>'),
        if (deletion) ('Chat-Delete', '<$id>'),
      ],
    );
    final next = chats.updateMessage(
      chatKey,
      id,
      (m) => reaction
          ? m.copyWith(
              reactions: {...m.reactions, fingerprint: text},
              reactionDates: {...m.reactionDates, fingerprint: date},
            )
          : deletion
          ? m.copyWith(
              deleted: true,
              text: '',
              attachments: const [],
              clearPending: true,
              reactions: const {},
              reactionDates: const {},
            )
          : m.copyWith(text: text, editedAt: date),
    );
    return DeltaStep(
      next,
      mails: [
        DeltaOutgoingMail(to: [for (final r in recipients) r.addr], mail: mail),
      ],
      chatKey: chatKey,
    );
  }
}
