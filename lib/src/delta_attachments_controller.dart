part of 'messenger_controller.dart';

/// Delta files share Conest's descriptor, cache, privacy settings and voice
/// service. No file bytes are persisted inside the chat vault.
extension DeltaAttachmentsController on MessengerController {
  bool deltaAttachmentAvailableLocally(AttachmentDescriptor descriptor) {
    final stored = _deltaAttachmentDescriptorFor(descriptor.id);
    return stored != null &&
        jsonEncode(stored.toJson()) == jsonEncode(descriptor.toJson()) &&
        attachmentAvailableLocally(descriptor.id);
  }

  Iterable<AttachmentDescriptor> get _deltaAttachments sync* {
    for (final chat in deltaChats.chats.values) {
      for (final message in chat.messages) {
        yield* message.attachments;
      }
    }
  }

  AttachmentDescriptor? _deltaAttachmentDescriptorFor(String id) {
    final chats = deltaChats;
    if (!identical(chats, _deltaIndexedChats)) {
      _deltaDescriptorIndex = {for (final a in _deltaAttachments) a.id: a};
      _deltaIdsByCacheName = {};
      for (final a in _deltaDescriptorIndex.values) {
        _deltaIdsByCacheName
            .putIfAbsent(
              'delta-${attachmentStorageKey('sha256:${a.fileHashBase64}')}',
              () => <String>{},
            )
            .add(a.id);
      }
      _deltaIndexedChats = chats;
    }
    return _deltaDescriptorIndex[id];
  }

  // Snapshot lists are immutable. Delta-only saves reuse this ownership index,
  // including archives, without rescanning Conest history for each reference.
  AttachmentDescriptor? _conestDescriptorForDeltaCache(String id) {
    if (!identical(_deltaConestConversationsFrom, _snapshot.conversations) ||
        !identical(_deltaConestArchivesFrom, _snapshot.linkArchives)) {
      _deltaConestDescriptors = {
        for (final conversation in _snapshot.conversations)
          for (final message in conversation.messages)
            ?message.attachment?.id: message.attachment!,
        for (final message in _archivedMessages)
          ?message.attachment?.id: message.attachment!,
      };
      _deltaConestConversationsFrom = _snapshot.conversations;
      _deltaConestArchivesFrom = _snapshot.linkArchives;
    }
    return _deltaConestDescriptors[id];
  }

  Future<DeltaAttachmentCache> _openDeltaFileCache() => _deltaFileCache ??=
      () async {
        final root = await _attachmentRoot();
        final directory = Directory(p.join(root.path, 'cache'));
        await directory.create(recursive: true);
        _deltaAttachmentDescriptorFor(''); // refresh the content index once
        final shared = {
          for (final message in _archivedMessages)
            if (message.attachment != null)
              attachmentStorageKey(
                'sha256:${message.attachment!.fileHashBase64}',
              ),
          for (final conversation in _snapshot.conversations)
            for (final message in conversation.messages)
              if (message.attachment != null)
                attachmentStorageKey(
                  'sha256:${message.attachment!.fileHashBase64}',
                ),
        };
        // Upgrade the old shared names once, preserving copies used by Conest.
        for (final name in _deltaIdsByCacheName.keys) {
          final oldName = name.substring('delta-'.length);
          final old = File(p.join(directory.path, oldName));
          final target = File(p.join(directory.path, name));
          if (!await target.exists() && await old.exists()) {
            try {
              if (shared.contains(oldName)) {
                final capacity = await _storageCapacityProvider(root.path);
                final size = await old.length();
                if (!_canAllocateStorage(capacity, size)) continue;
                await old.copy(target.path);
              } else {
                await old.rename(target.path);
              }
            } on FileSystemException {
              // Old cache paths remain usable when migration cannot allocate.
            }
          }
        }
        final cache = DeltaAttachmentCache(
          directory,
          maxBytes: deltaAttachmentCacheLimitBytes,
          onEvicted: (name) {
            _deltaAttachmentDescriptorFor('');
            for (final id in _deltaIdsByCacheName[name] ?? const <String>{}) {
              _locallyAvailableAttachments.remove(id);
              _assembledAttachments.remove(id);
            }
          },
        );
        await cache.load(_deltaIdsByCacheName.keys);
        await cache.reserve('', 0, _protectedDeltaCacheKeys);
        return cache;
      }().catchError((Object error, StackTrace stack) {
        _deltaFileCache = null;
        Error.throwWithStackTrace(error, stack);
      });

  Set<String> get _protectedDeltaCacheKeys => {
    for (final r in _snapshot.attachmentCacheReferences)
      if ((r.keepOffline || r.explicitlySaved) &&
          _deltaDescriptorIndex.containsKey(r.attachmentId))
        'delta-${attachmentStorageKey('sha256:${r.fileHashBase64}')}',
  };

  Future<AttachmentDescriptor> _saveDeltaAttachment(
    DeltaFile file,
    String chatKey,
    String messageId,
    int index,
  ) async {
    if (file.bytes.length > DeltaLimits.fileBytes) {
      throw StateError('File is too large.');
    }
    final id = 'delta:${attachmentStorageKey('$chatKey/$messageId/$index')}';
    final hash = await deltaFileHash(file.bytes);
    final root = await _attachmentRoot();
    final directory = Directory(p.join(root.path, 'cache'));
    await directory.create(recursive: true);
    final cache = File(
      p.join(directory.path, 'delta-${attachmentStorageKey('sha256:$hash')}'),
    );
    final lru = await _openDeltaFileCache();
    final cacheName = p.basename(cache.path);
    await lru.reserve(cacheName, file.bytes.length, _protectedDeltaCacheKeys);
    if (!await cache.exists()) {
      final capacity = await _storageCapacityProvider(root.path);
      if (!_canAllocateStorage(capacity, file.bytes.length)) {
        throw StateError('Not enough free storage.');
      }
      final temporary = File(
        p.join(directory.path, '${_randomId('delta')}.tmp'),
      );
      try {
        await temporary.create();
        await restrictFileToOwner(temporary);
        await temporary.writeAsBytes(file.bytes, flush: true);
        await temporary.rename(cache.path);
      } finally {
        await MessengerController._deleteQuietly(temporary);
      }
    }
    await lru.record(cacheName, file.bytes.length, _now().toUtc());
    _locallyAvailableAttachments.add(id);
    return AttachmentDescriptor(
      id: id,
      fileName: sanitizeAttachmentFileName(file.name),
      mimeType: file.voice && deltaMimeType(file.bytes) == 'video/mp4'
          ? 'audio/mp4'
          : deltaMimeType(file.bytes),
      sizeBytes: file.bytes.length,
      chunkSize: MessengerController._lanAttachmentChunkSize,
      chunkHashes: const [],
      encryptionKeyBase64: '',
      fileHashBase64: hash,
      createdAt: _now().toUtc(),
      voiceMetadata: file.voice
          ? VoiceMessageMetadata(durationMs: file.durationMs)
          : null,
    );
  }

  /// Stages one file privately before sanitizing and encrypting it. The local
  /// descriptor keeps the real name; only the mail uses a randomized name.
  Future<void> sendDeltaAttachment(
    String chatKey,
    StagedAttachment source, {
    String caption = '',
    bool keepMetadata = false,
    VoiceMessageMetadata? voiceMetadata,
  }) async {
    if (source.sizeBytes > DeltaLimits.fileBytes) {
      throw ArgumentError('Delta Chat files must be at most 21 MiB.');
    }
    await _deltaRequired((protocol, chats) async {
      final chat = chats.chats[chatKey];
      if (chat == null || chat.left) {
        throw StateError('Not a chat you can write in.');
      }
      final attachmentId = _randomId('delta');
      final prepared = await _prepareOutboundAttachmentSource(
        attachmentId: attachmentId,
        source: source,
        cleanMetadata: false,
        allowOriginalFallback: false,
      );
      String? cleaned;
      try {
        if (!keepMetadata) {
          cleaned = await _withoutFileMetadata(prepared.path, source.fileName);
        }
        final path = cleaned ?? prepared.path;
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in File(path).openRead()) {
          if (bytes.length + chunk.length > DeltaLimits.fileBytes) {
            throw ArgumentError('Delta Chat files must be at most 21 MiB.');
          }
          bytes.add(chunk);
        }
        final content = bytes.takeBytes();
        if (content.isEmpty) throw ArgumentError('Cannot send an empty file.');
        final mime = deltaMimeType(content);
        if (voiceMetadata != null &&
            (mime != 'audio/ogg' ||
                voiceMetadata.durationMs < 1000 ||
                voiceMetadata.durationMs > 10 * 60 * 1000)) {
          throw ArgumentError(
            'Voice recordings must use Ogg and last 1 second to 10 minutes.',
          );
        }
        final local = await _saveDeltaAttachment(
          DeltaFile(
            name: source.fileName,
            bytes: content,
            mimeType: mime,
            voice: voiceMetadata != null,
            durationMs: voiceMetadata?.durationMs ?? 0,
          ),
          chatKey,
          attachmentId,
          0,
        );
        return protocol.sendFiles(
          chats,
          chatKey,
          caption,
          [
            DeltaFile(
              name: sanitizeAttachmentFileName(
                _outgoingFileName(source.fileName),
              ),
              bytes: content,
              mimeType: mime,
              voice: voiceMetadata != null,
              durationMs: voiceMetadata?.durationMs ?? 0,
            ),
          ],
          [local],
        );
      } finally {
        if (cleaned != null) {
          await MessengerController._deleteQuietly(File(cleaned));
        }
        await MessengerController._deleteQuietly(File(prepared.path));
      }
    });
  }

  Future<void> sendRecordedDeltaVoiceMessage(String chatKey) async {
    final preview = voiceMessageService.preview;
    if (preview == null ||
        voiceMessageService.previewDestinationKey != 'delta:$chatKey') {
      throw StateError('No voice preview for this chat.');
    }
    await sendDeltaAttachment(
      chatKey,
      StagedAttachment(
        id: _randomId('voice'),
        fileName: 'voice-message.ogg',
        mimeType: 'audio/ogg',
        sizeBytes: preview.sizeBytes,
        filePath: preview.path,
      ),
      keepMetadata: true,
      voiceMetadata: preview.metadata,
    );
    await voiceMessageService.completePreview();
  }

  Future<void> reactDeltaMessage(String key, String id, String emoji) =>
      _deltaRequired((p, c) => p.react(c, key, id, emoji));
  Future<void> editDeltaMessage(String key, String id, String text) =>
      _deltaRequired((p, c) => p.edit(c, key, id, text));
  Future<void> deleteDeltaMessage(String key, String id) =>
      _deltaRequired((p, c) => p.deleteMessage(c, key, id));

  void _recordDeltaCacheReferences() {
    final chats = deltaChats;
    final old = _deltaReferencedChats;
    _deltaAttachmentDescriptorFor('');
    _conestDescriptorForDeltaCache('');
    final references = {
      for (final r in _snapshot.attachmentCacheReferences)
        if (!r.attachmentId.startsWith('delta:') ||
            _deltaDescriptorIndex.containsKey(r.attachmentId) ||
            _deltaConestDescriptors.containsKey(r.attachmentId))
          r.attachmentId: r,
    };
    for (final chat in chats.chats.values) {
      if (identical(chat, old?.chats[chat.key])) continue;
      for (final message in chat.messages) {
        for (final a in message.attachments) {
          references.putIfAbsent(
            a.id,
            () => AttachmentCacheReference(
              attachmentId: a.id,
              fileHashBase64: a.fileHashBase64,
              lastAccessedAt: _now().toUtc(),
            ),
          );
        }
      }
    }
    _snapshot = _snapshot.copyWith(
      attachmentCacheReferences: references.values.toList(),
    );
    _deltaReferencedChats = chats;
  }

  void _addDeltaCacheKeys(Map<String, Set<String>> keys) {
    for (final a in _deltaAttachments) {
      keys
          .putIfAbsent(
            'delta-${attachmentStorageKey('sha256:${a.fileHashBase64}')}',
            () => <String>{},
          )
          .add(a.id);
      keys.putIfAbsent(attachmentStorageKey(a.id), () => <String>{}).add(a.id);
      keys
          .putIfAbsent(
            attachmentStorageKey('sha256:${a.fileHashBase64}'),
            () => <String>{},
          )
          .add(a.id);
    }
  }
}
